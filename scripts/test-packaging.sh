#!/bin/bash
# No-secret packaging smoke for CI and local development.
# Usage: test-packaging.sh <native oab-instance-mcp binary>
set -euo pipefail

BIN="${1:?usage: test-packaging.sh <binary>}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$("$BIN" --version)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/oab-instance-mcp.app"
HOME1="$TMP/home"
PKG="$TMP/oab-instance-mcp.pkg"

mkdir -p "$HOME1"
"$ROOT/scripts/assemble-app.sh" "$BIN" "$APP" "$VERSION"
[ -x "$APP/Contents/MacOS/oab-instance-mcp" ]
[ -x "$APP/Contents/Resources/install-prebuilt.sh" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = dev.openab.instance-mcp ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$APP/Contents/Info.plist")" = true ]
# Display name only: identity, executable and file name must not move (#63).
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = oab-instance-mcp ]
[ "$(basename "$APP")" = oab-instance-mcp.app ]
# The localized name applies only while the base name equals the file name.
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" = oab-instance-mcp ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSHasLocalizedDisplayName' "$APP/Contents/Info.plist")" = true ]
STRINGS="$APP/Contents/Resources/en.lproj/InfoPlist.strings"
[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$STRINGS")" = "OpenAB Computer" ]
[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$STRINGS")" = "OpenAB Computer" ]
# Ask Foundation for the name Finder shows; it applies the localized-name rule.
display_name() {
  /usr/bin/osascript -l JavaScript \
    -e 'function run(argv) { ObjC.import("Foundation"); return $.NSFileManager.defaultManager.displayNameAtPath(argv[0]).js }' \
    "$1"
}
[ "$(display_name "$APP")" = "OpenAB Computer" ] || {
  echo "packaging test: macOS shows '$(display_name "$APP")', expected 'OpenAB Computer'" >&2
  exit 1
}

# The production installer must reject an unsigned app. Its test seams exercise
# everything after that gate without changing the live user or launchd namespace.
if INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
     "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null 2>&1; then
  echo "packaging test: unsigned app passed the production signature gate" >&2
  exit 1
fi

# A 0.11.0 install keeps its token at the old path. The installer must copy that token, not rotate it. A pre-0.4.0
# token sits beside it: the 0.11.0 token wins, and both old files are left in place.
mkdir -p "$HOME1/.config/oab-instance-mcp" "$HOME1/.config/oab-mac-agent"
openssl rand -hex 32 >"$HOME1/.config/oab-instance-mcp/token"
chmod 644 "$HOME1/.config/oab-instance-mcp/token"
openssl rand -hex 32 >"$HOME1/.config/oab-mac-agent/token"
LEGACY_SEED=$(cat "$HOME1/.config/oab-instance-mcp/token")
OLDEST_SEED=$(cat "$HOME1/.config/oab-mac-agent/token")
[ "$LEGACY_SEED" != "$OLDEST_SEED" ]
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 TEST_WITH_UPSTREAM=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
INSTALLED="$HOME1/.local/oab-instance-mcp/oab-instance-mcp.app"
PLIST="$HOME1/Library/LaunchAgents/dev.openab.instance-mcp.plist"
TOKEN="$HOME1/.config/oab-computer/token"
[ -d "$INSTALLED" ] && [ -f "$PLIST" ] && [ -s "$TOKEN" ]
[ "$(cat "$TOKEN")" = "$LEGACY_SEED" ] # copied from the 0.11.0 path
[ "$(cat "$HOME1/.config/oab-instance-mcp/token")" = "$LEGACY_SEED" ] # the old file is left in place
[ "$(cat "$HOME1/.config/oab-mac-agent/token")" = "$OLDEST_SEED" ] # so is the pre-0.4.0 file, which lost
[ "$(stat -f '%Lp' "$HOME1/.config/oab-computer")" = 700 ]
[ ! -e "$TOKEN.lock" ]
cmp "$APP/Contents/MacOS/oab-instance-mcp" "$INSTALLED/Contents/MacOS/oab-instance-mcp"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist")" = dev.openab.instance-mcp ]
[ "$(display_name "$INSTALLED")" = "OpenAB Computer" ]
[ "$(stat -f '%Lp' "$TOKEN")" = 600 ]
[ "$(wc -c <"$TOKEN" | tr -d ' ')" = 65 ] # 64 hex + newline
/usr/bin/plutil -lint "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -A1 -x ' *--token-file' | grep -qx " *$TOKEN"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q -- '--allow-login'
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q 'test@example.invalid'
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q 'browser=http://127.0.0.1:8794/mcp'

# The migration is one-shot: delete the new token and the next install generates a fresh one, never the old one.
rm -f "$TOKEN"
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
[ -s "$TOKEN" ]
[ "$(cat "$TOKEN")" != "$LEGACY_SEED" ] && [ "$(cat "$TOKEN")" != "$OLDEST_SEED" ]
[ "$(stat -f '%Lp' "$TOKEN")" = 600 ]
[ "$(wc -c <"$TOKEN" | tr -d ' ')" = 65 ]
[ "$(cat "$HOME1/.config/oab-instance-mcp/token")" = "$LEGACY_SEED" ]
[ "$(cat "$HOME1/.config/oab-mac-agent/token")" = "$OLDEST_SEED" ]

# Only the pre-0.4.0 token exists: it is copied (not moved), under the lock, into a fresh directory.
HOME3="$TMP/home-oldest"
mkdir -p "$HOME3/.config/oab-mac-agent"
openssl rand -hex 32 >"$HOME3/.config/oab-mac-agent/token"
OLDEST3=$(cat "$HOME3/.config/oab-mac-agent/token")
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME3" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
[ "$(cat "$HOME3/.config/oab-computer/token")" = "$OLDEST3" ]
[ "$(cat "$HOME3/.config/oab-mac-agent/token")" = "$OLDEST3" ]

# A whitespace-only 0.11.0 token is not copied (the app rejects it too): a fresh token is generated.
HOME4="$TMP/home-blank"
mkdir -p "$HOME4/.config/oab-instance-mcp"
printf '  \n' >"$HOME4/.config/oab-instance-mcp/token"
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME4" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
[ "$(wc -c <"$HOME4/.config/oab-computer/token" | tr -d ' ')" = 65 ]
[ "$(stat -f '%Lp' "$HOME4/.config/oab-computer/token")" = 600 ]

# An update preserves the bearer token.
TOKEN_BEFORE=$(cat "$TOKEN")
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
[ "$(cat "$TOKEN")" = "$TOKEN_BEFORE" ]

# Switchboard mode comes from config files and survives an update.
SBC="$HOME1/.config/oab-instance-mcp"
if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q -- '--switchboard'; then
  echo "switchboard args present without config" >&2; exit 1
fi
echo 'wss://sb.example.invalid/vm/attach' >"$SBC/switchboard.url"
echo 'not-a-real-secret' >"$SBC/switchboard.secret"
echo 'owner' >"$SBC/switchboard.profile"
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
SB_ARGS=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST")
echo "$SB_ARGS" | grep -qx ' *--switchboard'
echo "$SB_ARGS" | grep -qx ' *wss://sb.example.invalid/vm/attach'
echo "$SB_ARGS" | grep -qx " *$SBC/switchboard.secret"
echo "$SB_ARGS" | grep -qx ' *owner'
if echo "$SB_ARGS" | grep -q 'not-a-real-secret'; then echo "secret leaked into the plist" >&2; exit 1; fi
# Secure set_value through the switchboard is refused unless the operator opts in.
if echo "$SB_ARGS" | grep -q -- '--switchboard-allow-secure-set-value'; then
  echo "secure set_value allowed without opt-in" >&2; exit 1
fi
echo 'allow' >"$SBC/switchboard.secure-set-value"
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid >/dev/null
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -qx ' *--switchboard-allow-secure-set-value'
echo 'yes' >"$SBC/switchboard.secure-set-value"
SB_ERR=$(ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid 2>&1 >/dev/null)
if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q -- '--switchboard-allow-secure-set-value'; then
  echo "secure set_value allowed by a file that does not say allow" >&2; exit 1
fi
echo "$SB_ERR" | grep -q "switchboard.secure-set-value says 'yes'"
rm -f "$SBC/switchboard.secure-set-value"
# A 0.8.x `desktop` (#59) is written as observe, never owner, with a warning.
echo 'desktop' >"$SBC/switchboard.profile"
SB_ERR=$(ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME1" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" --allow-login test@example.invalid 2>&1 >/dev/null)
SB_ARGS=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST")
echo "$SB_ARGS" | grep -qx ' *observe'
if echo "$SB_ARGS" | grep -qx ' *desktop\| *owner'; then echo "desktop not mapped to observe" >&2; exit 1; fi
echo "$SB_ERR" | grep -q "switchboard.profile says 'desktop'"
[ "$(cat "$SBC/switchboard.profile")" = "desktop" ]
rm -f "$SBC/switchboard.url" "$SBC/switchboard.secret" "$SBC/switchboard.profile"

# Exercise the real structured Tailscale identity path with an anonymized fixture.
# The fake also records `serve`, so this does not touch the runner's tailnet.
HOME2="$TMP/home-auto"
FAKE_TS="$TMP/tailscale"
TS_LOG="$TMP/tailscale.log"
mkdir -p "$HOME2"
cat >"$FAKE_TS" <<'SH'
#!/bin/bash
case "$1" in
  status)
    if [ "${FAKE_TS_BAD:-0}" = 1 ]; then
      echo '{"Self":{"DNSName":"fixture.tail.example."},"User":{}}'
    else
      echo '{"Self":{"DNSName":"fixture.tail.example.","UserID":12345},"User":{"12345":{"ID":12345,"LoginName":"fixture@example.invalid"}}}'
    fi
    ;;
  serve) printf '%s\n' "$*" >>"$TEST_TS_LOG" ;;
  *) exit 64 ;;
esac
SH
chmod 755 "$FAKE_TS"
ALLOW_UNSIGNED=1 INSTALL_HOME="$HOME2" SKIP_LAUNCH=1 \
  TAILSCALE_CLI="$FAKE_TS" TEST_TS_LOG="$TS_LOG" \
  "$ROOT/scripts/install-prebuilt.sh" "$APP" >/dev/null
AUTO_PLIST="$HOME2/Library/LaunchAgents/dev.openab.instance-mcp.plist"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$AUTO_PLIST" | grep -q 'fixture@example.invalid'
# A fresh install with no old token generates a private 64-hex token and hands exactly that file to the agent.
TOKEN2="$HOME2/.config/oab-computer/token"
[ "$(stat -f '%Lp' "$TOKEN2")" = 600 ]
[ "$(wc -c <"$TOKEN2" | tr -d ' ')" = 65 ]
grep -qE '^[0-9a-f]{64}$' "$TOKEN2"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$AUTO_PLIST" | grep -A1 -x ' *--token-file' | grep -qx " *$TOKEN2"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$AUTO_PLIST" | grep -q 'https://fixture.tail.example:8444/mcp'
grep -q 'serve --bg --https=8444 http://127.0.0.1:8795' "$TS_LOG"
if ALLOW_UNSIGNED=1 INSTALL_HOME="$TMP/home-bad-ts" SKIP_LAUNCH=1 \
     TAILSCALE_CLI="$FAKE_TS" TEST_TS_LOG="$TS_LOG" FAKE_TS_BAD=1 \
     "$ROOT/scripts/install-prebuilt.sh" "$APP" >"$TMP/bad-ts.out" 2>&1; then
  echo "packaging test: malformed Tailscale fixture was accepted" >&2
  exit 1
fi
grep -q 'Tailscale self UserID is empty or missing' "$TMP/bad-ts.out"

# Build and inspect the unsigned package shape. A real release passes both sign
# identities and notarizes; CI cannot access those secrets on a PR.
ALLOW_UNSIGNED=1 "$ROOT/scripts/package-pkg.sh" "$APP" "$PKG" "$VERSION" >/dev/null
/usr/sbin/pkgutil --payload-files "$PKG" | grep -q \
  '^\./Library/Application Support/OpenAB/instance-mcp/oab-instance-mcp.app/Contents/MacOS/oab-instance-mcp$'
/usr/sbin/pkgutil --payload-files "$PKG" | grep -q \
  '^\./Library/Application Support/OpenAB/instance-mcp/oab-instance-mcp.app/Contents/Resources/en.lproj/InfoPlist.strings$'
EXPANDED="$TMP/expanded"
/usr/sbin/pkgutil --expand "$PKG" "$EXPANDED"
[ -x "$EXPANDED/Scripts/postinstall" ]
[ -x "$EXPANDED/Scripts/install-prebuilt.sh" ]
# v0.6.0 could leave a root-owned relocated app in ~/.local. A later package
# must repair only our paths before dropping root, or the user installer cannot
# atomically rename it.
grep -q '/usr/sbin/chown -R' "$EXPANDED/Scripts/postinstall"
grep -q '\.local/oab-instance-mcp' "$EXPANDED/Scripts/postinstall"
# A bundle listed under <relocate> is moved to any existing matching bundle on
# the target Mac; then postinstall's payload path vanishes (the first v0.6.0
# install failed exactly this way). The explicit component plist must remove it.
if /usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$EXPANDED/PackageInfo" | /usr/bin/grep -q '<bundle'; then
  echo "packaging test: app is still marked relocatable" >&2
  exit 1
fi
/bin/bash -n "$EXPANDED/Scripts/postinstall"
/bin/bash -n "$EXPANDED/Scripts/install-prebuilt.sh"

# Signing is mandatory outside the explicit smoke seam.
if "$ROOT/scripts/package-pkg.sh" "$APP" "$TMP/should-not-exist.pkg" "$VERSION" >/dev/null 2>&1; then
  echo "packaging test: unsigned package built without ALLOW_UNSIGNED=1" >&2
  exit 1
fi

echo "packaging smoke: OK ($VERSION)"
