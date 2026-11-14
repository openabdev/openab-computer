#!/bin/bash
# Name-consistency test: fails when an installer, unit, plist, pkg script, workflow or the Swift
# source refers to a binary, path, label or asset name that the packaging does not produce.
#
#   scripts/test-name-consistency.sh
#
# It runs the real installers in a fake HOME with stub launchctl / systemctl (nothing touches a real
# launchd, systemd, Tailscale or user directory), then parses what they wrote. Every check runs and
# every miss is reported; the exit status is 1 if any failed. The macOS half needs PlistBuddy and is
# skipped elsewhere; the Linux half needs only bash.
# shellcheck disable=SC2016  # stub bodies are literal on purpose
# shellcheck disable=SC2015  # `A && ok || fail`: ok() always succeeds, so this is an if/else
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The single source of truth for this test: the names 0.12.0 ships.
NAME=oab-computer
BUNDLE=dev.openab.computer
PW_LABEL=dev.openab.computer.pw-mcp
PKG_ID=dev.openab.computer.installer
PAYLOAD_DIR='Library/Application Support/OpenAB/computer'
UNIT=oab-computer.service
PW_UNIT=oab-computer-pw-mcp.service

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "ok: $*"; }
eq() { # eq WHAT GOT WANT
  if [ "$2" = "$3" ]; then ok "$1 = $3"; else fail "$1: got '$2', want '$3'"; fi
}
has() { # has WHAT FILE STRING (fixed string)
  if grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1: '$3' not found in ${2#"$ROOT"/}"; fi
}

# ------------------------------------------------------------------ source files agree on names
SW="$ROOT/Sources/InstanceMCPCore"
has "Package.swift product" "$ROOT/Package.swift" ".executable(name: \"$NAME\", targets: [\"$NAME\"])"
has "Package.swift path" "$ROOT/Package.swift" "path: \"Sources/$NAME\""
[ -f "$ROOT/Sources/$NAME/main.swift" ] && ok "Sources/$NAME/main.swift exists" || fail "Sources/$NAME/main.swift missing"
has "MenuModel.ownLabel = bundle id" "$SW/MenuModel.swift" "ownLabel = \"$BUNDLE\""
has "Keychain service" "$SW/GrantStore.swift" "service = \"$BUNDLE.grant\""
has "config directory" "$SW/FirstRunSetup.swift" "home + \"/.config/$NAME\""
has "agent log" "$SW/FirstRunSetup.swift" "home + \"/Library/Logs/$NAME/agent.log\""
has "grants.json" "$SW/FirstRunSetup.swift" "Library/Application Support/$NAME/grants.json"
has "audit.jsonl" "$SW/ProfileAudit.swift" "Library/Application Support/$NAME/audit.jsonl"
has "deploy.sh signs with the bundle id" "$HERE/deploy.sh" "--identifier $BUNDLE"
has "deploy.sh builds the binary" "$HERE/deploy.sh" ".build/release/$NAME"
has "pw-mcp installer label" "$ROOT/poc/pw-mcp/install.sh" "LABEL=$PW_LABEL"
has "release version source" "$HERE/release-version.sh" "Sources/$NAME/main.swift"

# ------------------------------------------------------------------ CI and release workflow
REL="$ROOT/.github/workflows/release.yml"
has "ci runs the built binary" "$ROOT/.github/workflows/ci.yml" ".build/debug/$NAME"
has "release: universal binary" "$REL" "-output \"\$DIST/$NAME\""
has "release: assemble the app" "$REL" "scripts/assemble-app.sh \"\$DIST/$NAME\" \"\$DIST/$NAME.app\""
has "release: app zip" "$REL" "$NAME-\$VERSION-universal.app.zip"
has "release: pkg" "$REL" "$NAME-\$VERSION-universal.pkg"
has "release: linux tarball dir" "$REL" "NAME=\"$NAME-\$VERSION-linux-\${{ matrix.arch }}\""
has "release: linux binary in the tarball" "$REL" "\"\$NAME/$NAME\""
# The binary the Linux installer installs is the file name the release workflow puts in the tarball.
INSTALLED_FROM=$(sed -n 's|^install -m 755 "\$HERE/\([^"]*\)" "\$BASE/\([^"]*\)"$|\1 \2|p' "$HERE/install-linux.sh" | head -1)
eq "install-linux.sh installs the tarball binary" "$INSTALLED_FROM" "$NAME $NAME"
eq "Dockerfile source label" "$(sed -n 's|.*image.source="\([^"]*\)".*|\1|p' "$ROOT/images/toolchain/Dockerfile")" "https://github.com/openabdev/openab-computer"

# ------------------------------------------------------------------ pkg payload layout (no pkgbuild)
APP_IN_PAYLOAD="$PAYLOAD_DIR/$NAME.app"
has "package-pkg.sh identifier" "$HERE/package-pkg.sh" "dev.openab.computer.installer}"
has "package-pkg.sh mkdir" "$HERE/package-pkg.sh" "mkdir -p \"\$PAYLOAD/$PAYLOAD_DIR\""
has "package-pkg.sh ditto" "$HERE/package-pkg.sh" "\"\$PAYLOAD/$APP_IN_PAYLOAD\""
has "package-pkg.sh payload check" "$HERE/package-pkg.sh" "OpenAB/computer/$NAME.app/Contents/MacOS/$NAME\$"
has "postinstall SOURCE" "$HERE/pkg/postinstall" "SOURCE=\"/$APP_IN_PAYLOAD\""
has "verify-release.sh payload check" "$HERE/verify-release.sh" "OpenAB/computer/$NAME.app/Contents/MacOS/$NAME\$"
has "test-packaging.sh payload check" "$HERE/test-packaging.sh" "OpenAB/computer/$NAME.app/Contents/MacOS/$NAME\$"
has "postinstall runs the installer helper" "$HERE/pkg/postinstall" 'HELPER="$SCRIPT_DIR/install-prebuilt.sh"'
PKG_IDENT=$(sed -n 's|^IDENTIFIER="${PKG_IDENTIFIER:-\(.*\)}"$|\1|p' "$HERE/package-pkg.sh")
eq "package-pkg.sh default identifier" "$PKG_IDENT" "$PKG_ID"
# The package scripts directory must hold the installer that postinstall calls (package-pkg.sh copies it).
has "package-pkg.sh ships install-prebuilt.sh" "$HERE/package-pkg.sh" "install-prebuilt.sh"

# ------------------------------------------------------------------ macOS: assemble + install + parse
if [ -x /usr/libexec/PlistBuddy ]; then
  PB=/usr/libexec/PlistBuddy
  printf '#!/bin/sh\necho 0.0.0\n' >"$T/fakebin"; chmod 755 "$T/fakebin"
  APP="$T/$NAME.app"
  if ! "$HERE/assemble-app.sh" "$T/fakebin" "$APP" 0.0.0 >/dev/null 2>&1; then
    fail "assemble-app.sh failed"
  else
    INFO="$APP/Contents/Info.plist"
    eq "app file name" "$(basename "$APP")" "$NAME.app"
    eq "CFBundleIdentifier" "$($PB -c 'Print :CFBundleIdentifier' "$INFO")" "$BUNDLE"
    eq "CFBundleExecutable" "$($PB -c 'Print :CFBundleExecutable' "$INFO")" "$NAME"
    [ -x "$APP/Contents/MacOS/$NAME" ] && ok "Contents/MacOS/$NAME is executable" || fail "Contents/MacOS/$NAME missing"
    eq "localized display name" "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$APP/Contents/Resources/en.lproj/InfoPlist.strings")" "OpenAB Computer"
    [ -x "$APP/Contents/Resources/install-prebuilt.sh" ] && ok "install-prebuilt.sh ships inside the app" || fail "install-prebuilt.sh missing from the app"

    # A stub launchctl that reports nothing loaded and refuses every mutation.
    printf '#!/bin/bash\necho "$*" >>"%s"\n[ "$1" = print ] && exit 1\nexit 99\n' "$T/launchctl.log" >"$T/launchctl"
    chmod 755 "$T/launchctl"
    HOME1="$T/mac-home"; mkdir -p "$HOME1"
    if ! ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 LEGACY_LAUNCHCTL="$T/launchctl" \
         "$APP/Contents/Resources/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >"$T/mac.out" 2>&1; then
      cat "$T/mac.out" >&2; fail "install-prebuilt.sh failed in the fake HOME"
    fi
    PLIST="$HOME1/Library/LaunchAgents/$BUNDLE.plist"
    if [ ! -f "$PLIST" ]; then
      fail "LaunchAgent plist not written at Library/LaunchAgents/$BUNDLE.plist"
    else
      ok "LaunchAgent plist is named $BUNDLE.plist"
      eq "plist Label" "$($PB -c 'Print :Label' "$PLIST")" "$BUNDLE"
      EXE=$($PB -c 'Print :ProgramArguments:0' "$PLIST")
      eq "plist executable" "$EXE" "$HOME1/.local/$NAME/$NAME.app/Contents/MacOS/$NAME"
      [ -x "$EXE" ] && ok "the plist executable exists and is executable" || fail "the plist executable does not exist: $EXE"
      i=1; TOKEN_ARG=""
      while v=$($PB -c "Print :ProgramArguments:$i" "$PLIST" 2>/dev/null); do
        [ "$v" = "--token-file" ] && TOKEN_ARG=$($PB -c "Print :ProgramArguments:$((i + 1))" "$PLIST")
        i=$((i + 1))
      done
      eq "plist --token-file" "$TOKEN_ARG" "$HOME1/.config/$NAME/token"
      [ -s "$TOKEN_ARG" ] && ok "the token file named by the plist exists" || fail "the token file named by the plist does not exist"
      eq "plist StandardOutPath" "$($PB -c 'Print :StandardOutPath' "$PLIST")" "$HOME1/Library/Logs/$NAME/agent.log"
      eq "plist StandardErrorPath" "$($PB -c 'Print :StandardErrorPath' "$PLIST")" "$HOME1/Library/Logs/$NAME/agent.log"
      if /usr/bin/plutil -p "$PLIST" | grep -q 'instance-mcp'; then fail "the plist mentions instance-mcp"; else ok "the plist has no instance-mcp"; fi
    fi
    # The installer's pw-mcp probe names the label poc/pw-mcp/install.sh installs.
    has "installer probes the pw-mcp label" "$HERE/install-prebuilt.sh" "gui/\$UID_/$PW_LABEL"
    if grep -v '^print ' "$T/launchctl.log" 2>/dev/null | grep -q .; then fail "installer called launchctl with a mutating subcommand under SKIP_LAUNCH=1"; fi

    # postinstall chowns exactly the paths the installer created for the console user.
    OWNED=$(sed -n '/^for owned in/,/; do$/p' "$HERE/pkg/postinstall" | sed -n 's|.*"\$HOME_DIR/\([^"]*\)".*|\1|p' | sort | tr '\n' ' ')
    WANT=$(printf '%s\n' ".local/$NAME" ".config/$NAME" "Library/Logs/$NAME" "Library/LaunchAgents/$BUNDLE.plist" | sort | tr '\n' ' ')
    eq "postinstall owned paths" "$OWNED" "$WANT"
    for p in ".local/$NAME" ".config/$NAME" "Library/Logs/$NAME" "Library/LaunchAgents/$BUNDLE.plist"; do
      [ -e "$HOME1/$p" ] && ok "the installer created $p" || fail "postinstall owns $p but the installer did not create it"
    done
  fi
else
  echo "skip: macOS half (no PlistBuddy)"
fi

# ------------------------------------------------------------------ Linux: run the installer, parse the units
PKG="$T/pkg"; mkdir -p "$PKG"
cp "$HERE/install-linux.sh" "$ROOT/poc/reverse-attach-linux/pw-mcp.sh" "$PKG/"
printf '#!/bin/sh\nexit 0\n' >"$PKG/$NAME"
chmod 755 "$PKG/install-linux.sh" "$PKG/pw-mcp.sh" "$PKG/$NAME"
STUBS="$T/stubs"; mkdir -p "$STUBS"
LOG="$T/calls.log"
stub() { printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" >"$STUBS/$1"; chmod 755 "$STUBS/$1"; }
for c in grim wlrctl wtype sway loginctl curl node npm npx chromium; do stub "$c"; done
# systemctl: the is-active / is-enabled queries answer "no" (no old unit present); everything else succeeds.
stub systemctl 'case "$2" in is-active|is-enabled) exit 1;; esac; exit 0'
stub sudo 'exit 1'
stub fc-list 'echo "DejaVuSans.ttf: DejaVu Sans:style=Book"'
stub tailscale '[ "$1 $2" = "status --json" ] && echo '"'"'{"Self":{"UserID":7,"DNSName":"node.example.ts.net."},"User":{"7":{"LoginName":"ci-user"}}}'"'"'
exit 0'
REAL_LS="$(command -v ls)"
stub ls 'case "$1" in /run/user/*) printf "wayland-0\n";; *) exec '"$REAL_LS"' "$@";; esac'
LH="$T/lin-home"
mkdir -p "$LH/.local/$NAME/pw-mcp/node_modules/.bin"
printf '#!/bin/sh\n' >"$LH/.local/$NAME/pw-mcp/node_modules/.bin/playwright-mcp"; chmod 755 "$LH/.local/$NAME/pw-mcp/node_modules/.bin/playwright-mcp"
: >"$LOG"
if ! (cd "$PKG" && HOME="$LH" USER="${USER:-$(id -un)}" PATH="$STUBS:$PATH" ./install-linux.sh) </dev/null >"$T/lin.out" 2>"$T/lin.err"; then
  cat "$T/lin.err" >&2; fail "install-linux.sh failed in the fake HOME"
fi
UD="$LH/.config/systemd/user"
if [ ! -f "$UD/$UNIT" ]; then
  fail "Linux unit $UNIT not written"
else
  ok "Linux unit file is named $UNIT"
  EXECSTART=$(sed -n 's|^ExecStart=||p' "$UD/$UNIT")
  eq "unit ExecStart" "$EXECSTART" "$LH/.local/$NAME/$NAME"
  [ -x "$EXECSTART" ] && ok "the unit's ExecStart file exists and is executable" || fail "the unit's ExecStart file does not exist: $EXECSTART"
  TOK=$(sed -n 's|^Environment=MCP_TOKEN_FILE=||p' "$UD/$UNIT")
  eq "unit MCP_TOKEN_FILE" "$TOK" "$LH/.config/$NAME/token"
  [ -s "$TOK" ] && ok "the token file named by the unit exists" || fail "the token file named by the unit does not exist"
  if [ "$(uname)" = Linux ]; then eq "token mode" "$(stat -c %a "$TOK")" 600; else eq "token mode" "$(stat -f %Lp "$TOK")" 600; fi
fi
if [ ! -f "$UD/$PW_UNIT" ]; then
  fail "Linux unit $PW_UNIT not written"
else
  ok "Linux pw-mcp unit file is named $PW_UNIT"
  PWEXEC=$(sed -n 's|^ExecStart=||p' "$UD/$PW_UNIT")
  eq "pw-mcp unit ExecStart" "$PWEXEC" "$LH/.local/$NAME/pw-mcp.sh"
  [ -x "$PWEXEC" ] && ok "the pw-mcp ExecStart file exists and is executable" || fail "the pw-mcp ExecStart file does not exist"
fi
# The Rust package builds the binary under the shipped name (the release workflow copies it as is).
CARGO_NAME=$(sed -n '/^\[package\]/,/^\[/{s/^name = "\(.*\)"/\1/p;}' "$ROOT/poc/reverse-attach-linux/Cargo.toml" | head -1)
eq "Cargo package (binary) name" "$CARGO_NAME" "$NAME"
has "release.yml copies target/release/$NAME" "$ROOT/.github/workflows/release.yml" "target/release/$NAME \"\$NAME/$NAME\""
has "smoke.sh runs target/release/$NAME" "$ROOT/poc/reverse-attach-linux/smoke.sh" "BIN=./target/release/$NAME"

# The systemctl calls name only units that exist.
# (The read-only is-active / is-enabled queries of the warn-only old-unit check are not installs.)
CALLS="$T/calls.nonquery"; grep -vE '^systemctl --user is-(active|enabled) ' "$LOG" >"$CALLS" || true
while IFS= read -r u; do
  case "$u" in "$UNIT"|"$PW_UNIT"|oab-seat.service) ok "systemctl names $u";; *) fail "systemctl names a unit the installer does not write: $u";; esac
done < <(grep -oE '[A-Za-z0-9_.-]+\.service' "$CALLS" | sort -u)
for u in "$UNIT" "$PW_UNIT"; do
  has "installer enables $u" "$CALLS" "systemctl --user enable --now $u"
done
[ -f "$LH/.local/$NAME/pw-mcp.sh" ] && ok "pw-mcp.sh installed under .local/$NAME" || fail "pw-mcp.sh not installed under .local/$NAME"

# ------------------------------------------------------------------ nothing generated carries the old name
OLD_HITS=$(grep -rlE 'instance-mcp|oab-pw-mcp' "$LH/.config" "$LH/.local" 2>/dev/null | head -5)
[ -z "$OLD_HITS" ] && ok "no generated Linux file mentions the old names" || fail "generated files mention the old names: $OLD_HITS"
[ -z "$(grep -E 'instance-mcp|oab-pw-mcp' "$CALLS" | head -1)" ] && ok "no systemctl/loginctl call mentions the old names" || fail "a stub call mentions the old names"

# ------------------------------------------------------------------ repo-wide: old names only where allowed
# Allowed leftovers in code, scripts and CI: the copy-source token path (and the test fixtures that
# seed it), issue links, and the warn-only legacy detection (the two installers and their tests).
LEFT=$(cd "$ROOT" && grep -rnE --exclude-dir=target --exclude-dir=.build 'oab-instance-mcp|instance-mcp|INSTANCE_MCP|oab-pw-mcp|dev\.openab\.instance' \
    Sources Tests poc scripts .github images Package.swift 2>/dev/null \
  | grep -vE '^scripts/test-(legacy-agent|name-consistency)\.sh:' \
  | grep -vE '\.config/oab-instance-mcp/token|instance-mcp(#[0-9]|/issues/)' \
  | grep -vE '^scripts/test-packaging\.sh:[0-9]+:mkdir -p .*oab-instance-mcp' \
  | grep -vE '^Tests/InstanceMCPCoreTests/FirstRunSetupTests\.swift:[0-9]+:.*contains\("instance-mcp"\)' \
  | grep -vE '^scripts/install-(prebuilt|linux)\.sh:[0-9]+:[[:space:]]*#' \
  | grep -vE '^scripts/install-(prebuilt|linux)\.sh:.*([Ll]egacy|LEGACY|0\.11|oab-instance-mcp\.service|instance-mcp \(|0\.8|old)' || true)
if [ -z "$LEFT" ]; then ok "old names appear only in the allowed places"; else echo "$LEFT" >&2; fail "old names left outside the allowed places (above)"; fi

# The docs must not claim the Linux installer copies nothing while it copies the old token.
if grep -q 'oab-instance-mcp/token' "$ROOT/scripts/install-linux.sh"; then
  if grep -rniE 'copies nothing|generates a new token and copies' "$ROOT/README.md" "$ROOT/docs/releasing.md" "$ROOT/docs/linux-setup.md" 2>/dev/null; then
    fail "docs say the Linux installer copies no token, but install-linux.sh copies the old one"
  else ok "docs agree with the Linux installer's token copy"; fi
fi

if [ "$FAIL" = 0 ]; then echo "name-consistency: all checks passed"; else echo "name-consistency: FAILED" >&2; exit 1; fi
