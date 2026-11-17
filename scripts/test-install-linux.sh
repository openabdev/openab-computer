#!/bin/bash
# Run scripts/install-linux.sh against a fake HOME with stubbed system tools and check what it
# writes and what it calls (#90, #119 L3). Linux only; touches nothing outside a temp dir:
# systemctl, systemd-run, loginctl, sudo, tailscale, curl, apt-get, the desktop tools and the
# packaged `oab-computer` binary are stubs that only log their arguments.
#
#   scripts/test-install-linux.sh
#
# Checks: each written unit equals its expected text byte for byte (so a stray backtick or $( in
# an unquoted heredoc shows up as a diff); no browser unit and no MCP_UPSTREAM line is written;
# the browser step (prompt, flags, non-interactive default, order of plan, preflight and install);
# root actions are printed and never run without --apply-system-changes, and run in the printed
# order with it; the three upgrade shapes leave old units and drop-ins untouched; the flags in the
# generated docs table are the installer's flags; `systemd-analyze verify` on the units.
# shellcheck disable=SC2016  # stub bodies and expected text are literal on purpose
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# Release-tarball layout: the installer and the binary side by side. The binary is a stub that logs
# its arguments and answers the four `browser` calls the installer makes.
PKG="$T/pkg"; mkdir -p "$PKG"
cp "$HERE/install-linux.sh" "$PKG/"
LOG="$T/calls.log"
cat >"$PKG/oab-computer" <<'STUB'
#!/bin/bash
echo "oab-computer $*" >>"$STUB_LOG"
case "$*" in
  "browser plan") echo "Downloads about 259 MB: STUB PLAN TEXT. Installs to ~/.local/share/oab-computer/playwright.";;
  "browser preflight --root-actions") [ -z "${STUB_ROOT_ACTIONS:-}" ] || printf '%b\n' "$STUB_ROOT_ACTIONS";;
  "browser preflight") echo "preflight: ok";;
  "browser install") exit "${STUB_INSTALL_RC:-0}";;
esac
exit 0
STUB
chmod 755 "$PKG/install-linux.sh" "$PKG/oab-computer"

STUBS="$T/stubs"; mkdir -p "$STUBS"
stub() { # stub NAME [BODY]: logs "NAME args" to $LOG, then runs BODY (default: exit 0)
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" >"$STUBS/$1"
  chmod 755 "$STUBS/$1"
}
# No wlrctl stub on purpose: nothing uses it (#130), so the installer must not require it.
for c in grim wtype sway curl systemd-run apt-get; do stub "$c"; done
# systemctl: is-active / is-enabled answer "yes" only for the units named in $STUB_ACTIVE.
stub systemctl 'case "$2" in is-active|is-enabled) case " ${STUB_ACTIVE:-} " in *" ${@: -1} "*) exit 0;; esac; exit 1;; esac; exit 0'
stub loginctl 'case "$1" in show-user) echo "${STUB_LINGER:-no}";; esac; exit 0'
stub sudo 'exit 0'                       # logs the call and does nothing: no test ever runs a root command
stub fc-list '[ -n "${STUB_NOFONTS:-}" ] || echo "DejaVuSans.ttf: DejaVu Sans:style=Book"'
stub tailscale '[ "$1 $2" = "status --json" ] && echo '"'"'{"Self":{"UserID":7,"DNSName":"node.example.ts.net."},"User":{"7":{"LoginName":"ci-user"}}}'"'"'
exit 0'
# The installer finds the Wayland socket with `ls /run/user/<uid>`; answer for that path only.
REAL_LS="$(command -v ls)"
stub ls 'case "$1" in /run/user/*) printf "wayland-0\nwayland-1\n";; *) exec '"$REAL_LS"' "$@";; esac'

# env that the stubs read; reset by run().
export STUB_LOG="$LOG"

# run_rc NAME WANT_RC ARGS...: install into a fresh fake HOME at $T/NAME/home (unless it exists, so a
# case can pre-populate it) and require exit status WANT_RC. stdin is /dev/null: not a terminal.
run_rc() {
  local name="$1" want="$2" rc=0; shift 2
  local home="$T/$name/home"
  mkdir -p "$home"
  : >"$LOG"
  (cd "$PKG" && HOME="$home" USER="${USER:-$(id -un)}" PATH="$STUBS:$PATH" ./install-linux.sh "$@") </dev/null >"$T/$name/out" 2>"$T/$name/err" || rc=$?
  cp "$LOG" "$T/$name/calls"
  if [ "$rc" != "$want" ]; then cat "$T/$name/out" "$T/$name/err" >&2; fail "$name: exit $rc, wanted $want"; fi
}
run() { local name="$1"; shift; run_rc "$name" 0 "$@"; }

# expect NAME UNIT LOGIN PORT: diff the written unit against the expected text below.
expect() {
  local name="$1" unit="$2" login="$3" port="$4" home="$T/$1/home"
  local base="$home/.local/oab-computer" cfg="$home/.config/oab-computer"
  local got="$home/.config/systemd/user/$unit"
  [ -f "$got" ] || { fail "$name: $unit not written"; return; }
  sed -e "s|@BASE@|$base|g" -e "s|@CFG@|$cfg|g" -e "s|@LOGIN@|$login|g" -e "s|@PORT@|$port|g" \
      "$T/expected-$unit" >"$T/$name/want-$unit"
  diff -u "$T/$name/want-$unit" "$got" || fail "$name: $unit differs from the expected text"
}
has() { grep -qF -- "$2" "$T/$1/$3" || fail "$1: $3 lacks: $2"; }
lacks() { if grep -qF -- "$2" "$T/$1/$3"; then fail "$1: $3 has: $2"; fi; }
lacks_rm() { if grep -qE '(^|[[:space:]])rm ' "$T/$1/$2"; then fail "$1: $2 tells the user to rm something"; fi; }
line_of() { grep -nF -- "$2" "$T/$1/calls" | head -1 | cut -d: -f1; }
# no_old_browser NAME: the installer wrote neither a browser unit nor an upstream line.
no_old_browser() {
  local d="$T/$1/home/.config/systemd/user"
  [ ! -e "$d/oab-computer-pw-mcp.service" ] || fail "$1: a browser unit was written"
  if grep -rqE 'MCP_UPSTREAM|8794|pw-mcp' "$d"; then fail "$1: a unit mentions MCP_UPSTREAM, 8794 or pw-mcp"; fi
}
no_root_ran() { if grep -q '^sudo ' "$T/$1/calls"; then fail "$1: a root command ran without --apply-system-changes"; fi; }

cat >"$T/expected-oab-computer.service" <<'EOF'
[Unit]
Description=oab-computer (Linux hands node: /mcp + /attach)
After=graphical-session.target

[Service]
ExecStart=@BASE@/oab-computer
Environment=BIND=127.0.0.1:@PORT@
Environment=MCP_TOKEN_FILE=@CFG@/token
Environment=MCP_ALLOW_LOGIN=@LOGIN@
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=always
RestartSec=2
# Apps opened via `bash` belong to the desktop, not to this daemon: a restart must not kill them.
KillMode=process

[Install]
WantedBy=default.target
EOF
cat >"$T/expected-oab-seat.service" <<'EOF'
[Unit]
Description=Headless sway seat for the oab-computer hands node

[Service]
Environment=WLR_BACKENDS=headless
Environment=WLR_LIBINPUT_NO_DEVICES=1
Environment=WLR_RENDERER=pixman
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/usr/bin/sway
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# 1. Defaults, no terminal: units, token, no browser unit, no upstream line, nothing downloaded, the
# root actions printed and not run.
run default --headless-seat
expect default oab-computer.service ci-user 8795
expect default oab-seat.service ci-user 8795
no_old_browser default
for want in "systemctl --user enable --now oab-seat.service" \
            "systemctl --user enable --now oab-computer.service" \
            "systemctl --user restart oab-computer.service"; do
  grep -qF "$want" "$T/default/calls" || fail "default: no call: $want"
done
if grep -q '^oab-computer browser' "$T/default/calls"; then fail "default: the binary was asked about the browser with no consent"; fi
has default "To install the browser later: $T/default/home/.local/oab-computer/oab-computer browser install" out
has default "sudo loginctl enable-linger" out
has default "sudo tailscale serve --bg --https=8444 http://127.0.0.1:8795" out
has default "NOT run" out
no_root_ran default
tok="$T/default/home/.config/oab-computer/token"
if [ ! -s "$tok" ] || [ "$(stat -c %a "$tok")" != 600 ]; then fail "default: token missing or not mode 600"; fi
grep -qF '# Apps opened via `bash` belong to the desktop' "$T/default/home/.config/systemd/user/oab-computer.service" || fail "default: KillMode comment mangled"
for t in "$T/default/home/.local/oab-computer"/*; do
  case "$t" in */oab-computer) ;; *) fail "default: unexpected file in the install dir: $t";; esac
done

# 2. --browser managed: the plan text verbatim, then preflight, then install, in that order. An
# explicit port and login. Linger already on: no linger action.
STUB_LINGER=yes run managed --browser managed --allow-login ci-other --port 9000
expect managed oab-computer.service ci-other 9000
no_old_browser managed
has managed "STUB PLAN TEXT. Installs to ~/.local/share/oab-computer/playwright." out
p=$(line_of managed "oab-computer browser plan"); f=$(line_of managed "oab-computer browser preflight"); i=$(line_of managed "oab-computer browser install")
if ! { [ -n "$p" ] && [ -n "$f" ] && [ -n "$i" ] && [ "$p" -lt "$f" ] && [ "$f" -lt "$i" ]; }; then fail "managed: plan, preflight, install not in that order ($p $f $i)"; fi
lacks managed "enable-linger" out
has managed "sudo tailscale serve --bg --https=8444 http://127.0.0.1:9000" out
no_root_ran managed
has managed "Sign in once" out

# 3. --yes behaves like --browser managed.
run yes --yes
p=$(line_of yes "oab-computer browser plan"); i=$(line_of yes "oab-computer browser install")
if ! { [ -n "$p" ] && [ -n "$i" ] && [ "$p" -lt "$i" ]; }; then fail "yes: plan and install not in that order"; fi
no_root_ran yes

# 4. --browser none and --no-browser: no call to the binary about the browser at all.
run none --browser none
run nobrowser --no-browser
for n in none nobrowser; do
  if grep -q '^oab-computer browser' "$T/$n/calls"; then fail "$n: the binary was called about the browser"; fi
  no_old_browser "$n"
  expect "$n" oab-computer.service ci-user 8795
done

# 5. Contradicting flags and bad values exit 64 before anything is written.
for bad in "--no-browser --browser managed" "--no-browser --yes" "--browser none --yes" "--browser maybe" "--browser" "--port x" "--port" "--allow-login a\$b" "--frobnicate"; do
  n="bad-$(echo "$bad" | tr -c 'a-z0-9\n' '_')"
  # shellcheck disable=SC2086  # the words are the arguments on purpose
  run_rc "$n" 64 $bad
  [ ! -e "$T/$n/home/.config/systemd/user/oab-computer.service" ] || fail "$n: a unit was written for bad arguments"
done

# 6. --apply-system-changes: every printed root command runs through sudo, the preflight's actions
# before the install, linger and tailscale serve after it. The preflight is run again after them.
ACT='sudo apparmor_parser -r /etc/apparmor.d/oab-computer-chromium\tprofile for your own data path'
STUB_ROOT_ACTIONS="$ACT" STUB_NOFONTS=1 STUB_LINGER=no run apply --browser managed --apply-system-changes
has apply "running: sudo apparmor_parser -r /etc/apparmor.d/oab-computer-chromium" out
has apply "running: sudo loginctl enable-linger" out
has apply "running: sudo tailscale serve --bg --https=8444 http://127.0.0.1:8795" out
has apply "running: sudo apt-get install -y fonts-dejavu-core" out
a=$(line_of apply "sudo apparmor_parser -r /etc/apparmor.d/oab-computer-chromium"); i=$(line_of apply "oab-computer browser install")
l=$(line_of apply "sudo loginctl enable-linger"); s=$(line_of apply "sudo tailscale serve")
if ! { [ -n "$a" ] && [ -n "$i" ] && [ -n "$l" ] && [ -n "$s" ] && [ "$a" -lt "$i" ] && [ "$i" -lt "$l" ] && [ "$l" -lt "$s" ]; }; then fail "apply: order is not apparmor, install, linger, serve ($a $i $l $s)"; fi
n=$(grep -c '^oab-computer browser preflight$' "$T/apply/calls" || true)
[ "$n" = 2 ] || fail "apply: wanted the preflight twice (before and after the root actions), saw $n"
# Without the flag the same actions are printed and no sudo call is made, and the install still runs.
STUB_ROOT_ACTIONS="$ACT" STUB_NOFONTS=1 run printed --browser managed
has printed "sudo apparmor_parser -r /etc/apparmor.d/oab-computer-chromium" out
has printed "sudo apt-get install -y fonts-dejavu-core" out
has printed "NOT run" out
no_root_ran printed
[ -n "$(line_of printed "oab-computer browser install")" ] || fail "printed: the install did not run"
# A failing root action does not stop the rest, and the exit status says so.
cat >"$STUBS/sudo" <<'EOS'
#!/bin/bash
echo "sudo $*" >>"$STUB_LOG"
case "$*" in *enable-linger*) exit 3;; esac
exit 0
EOS
run_rc applyfail 1 --browser none --apply-system-changes
has applyfail "failed (exit 3): sudo loginctl enable-linger" err
[ -n "$(line_of applyfail "sudo tailscale serve")" ] || fail "applyfail: the later action did not run"
stub sudo 'exit 0'

# 7. The prompt: default yes, and no. A terminal comes from script(1) when it is installed.
if command -v script >/dev/null; then
  cat >"$T/wrap.sh" <<EOF
#!/bin/bash
cd "$PKG" && HOME="\$WRAP_HOME" PATH="$STUBS:\$PATH" STUB_LOG="$LOG" ./install-linux.sh --allow-login ci-user
EOF
  chmod 755 "$T/wrap.sh"
  for ans in yes no; do
    mkdir -p "$T/ask-$ans/home"; : >"$LOG"
    if [ "$ans" = yes ]; then input=$'\n'; else input=$'n\n'; fi
    printf '%s' "$input" | WRAP_HOME="$T/ask-$ans/home" timeout 60 script -qec "$T/wrap.sh" /dev/null >"$T/ask-$ans/out" 2>&1 || fail "ask-$ans: installer exited non-zero"
    cp "$LOG" "$T/ask-$ans/calls"
    has "ask-$ans" "Download and install the browser now? [Y/n]" out
    has "ask-$ans" "STUB PLAN TEXT" out
  done
  [ -n "$(line_of ask-yes "oab-computer browser install")" ] || fail "ask-yes: the default did not install"
  [ -z "$(line_of ask-no "oab-computer browser install")" ] || fail "ask-no: no still installed"
  has ask-no "To install the browser later" out
else
  echo "note: script(1) not installed; skipped the interactive prompt case"
fi

# 8. A failing browser install after --browser managed: exit 1, and the unit and the token stay.
STUB_INSTALL_RC=1 run_rc instfail 1 --browser managed
expect instfail oab-computer.service ci-user 8795
[ -s "$T/instfail/home/.config/oab-computer/token" ] || fail "instfail: token missing"
has instfail "install failed" err
lacks instfail "Sign in once" out
# The same failure when the browser was not asked for does not change the exit status.
STUB_INSTALL_RC=1 run notasked

# 9. Three host shapes on upgrade: old units, drop-ins and old unit lines are never touched.
UNITD() { echo "$T/$1/home/.config/systemd/user"; }
# 9a. Class N: the new-style browser unit is active and the daemon unit carries the MCP_UPSTREAM line.
mkdir -p "$(UNITD classn)"
printf '[Service]\nExecStart=/old/pw-mcp.sh\n' >"$(UNITD classn)/oab-computer-pw-mcp.service"
printf '[Service]\nExecStart=/old/oab-computer\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n' >"$(UNITD classn)/oab-computer.service"
cp "$(UNITD classn)/oab-computer-pw-mcp.service" "$T/classn.pw"; cp "$(UNITD classn)/oab-computer.service" "$T/classn.d"
STUB_ACTIVE="oab-computer-pw-mcp.service" run classn --browser none
cmp -s "$T/classn.pw" "$(UNITD classn)/oab-computer-pw-mcp.service" || fail "classn: the old browser unit changed"
cmp -s "$T/classn.d" "$(UNITD classn)/oab-computer.service" || fail "classn: the daemon unit with the upstream line was rewritten"
has classn "systemctl --user disable --now oab-computer-pw-mcp.service" err
has classn "8794" err
has classn "MCP_UPSTREAM" err
lacks_rm classn err
if grep -qE 'systemctl --user (disable|stop|mask|kill)' "$T/classn/calls"; then fail "classn: the installer disabled, stopped or removed something"; fi
# 9b. Class O: the old unit plus an upstream drop-in. The daemon unit is written without the line and the drop-in is untouched.
mkdir -p "$(UNITD classo)/oab-computer.service.d" "$(UNITD classo)/oab-instance-mcp.service.d"
printf '[Service]\nExecStart=/old/pw-mcp\n' >"$(UNITD classo)/oab-pw-mcp.service"
printf '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n' >"$(UNITD classo)/oab-computer.service.d/upstream.conf"
printf '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n' >"$(UNITD classo)/oab-instance-mcp.service.d/upstream.conf"
for f in oab-pw-mcp.service oab-computer.service.d/upstream.conf oab-instance-mcp.service.d/upstream.conf; do cp "$(UNITD classo)/$f" "$T/classo.$(basename "$f")$(dirname "$f" | tr / _)"; done
STUB_ACTIVE="oab-pw-mcp.service" run classo --browser none
expect classo oab-computer.service ci-user 8795
for f in oab-pw-mcp.service oab-computer.service.d/upstream.conf oab-instance-mcp.service.d/upstream.conf; do
  cmp -s "$T/classo.$(basename "$f")$(dirname "$f" | tr / _)" "$(UNITD classo)/$f" || fail "classo: $f changed"
done
has classo "systemctl --user disable --now oab-pw-mcp.service" err
has classo "upstream.conf" err
lacks_rm classo err
if grep -qE 'systemctl --user (disable|stop|mask|kill)' "$T/classo/calls"; then fail "classo: the installer disabled, stopped or removed something"; fi
# 9c. The 0.11 unit on port 8795 keeps its warning and the daemon is not probed.
STUB_ACTIVE="oab-instance-mcp.service" run class11 --browser none
has class11 "disable --now oab-instance-mcp.service" err
has class11 "daemon: not checked" err

# 10. The generated docs table lists the installer's flags, no more and no fewer.
doc="$HERE/../docs/linux-setup.md"
if [ -f "$doc" ]; then
  want_flags="$(awk '/BEGIN GENERATED: linux-flags-env/,/END GENERATED: linux-flags-env/' "$doc" \
    | grep '^| `scripts/install-linux.sh`' | sed -E 's/^\| [^|]*\| `(--[a-z-]+)[ `].*/\1/' | sort)"
  have_flags="$(grep -E '^[[:space:]]+--[a-z-]+\)' "$HERE/install-linux.sh" | sed -E 's/^[[:space:]]+(--[a-z-]+)\).*/\1/' | sort)"
  [ -n "$want_flags" ] || fail "docs: no installer rows between the GENERATED markers of docs/linux-setup.md"
  [ "$want_flags" = "$have_flags" ] || { diff <(echo "$want_flags") <(echo "$have_flags") >&2 || true; fail "docs: the flags table and install-linux.sh disagree"; }
else
  fail "docs/linux-setup.md not found"
fi

# 11. systemd's own parser. The seat unit is skipped: its ExecStart (/usr/bin/sway) is not
# installed here, and verify rejects a missing executable.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$T/rt"; chmod 700 "$T/rt"   # a private runtime dir: verify never needs the real user manager
  for name in default managed; do
    if ! out="$(HOME="$T/$name/home" XDG_RUNTIME_DIR="$T/rt" systemd-analyze --user verify "$T/$name/home/.config/systemd/user/oab-computer.service" 2>&1)" || [ -n "$out" ]; then
      echo "$out" >&2; fail "$name: systemd-analyze verify"
    fi
  done
else
  echo "note: systemd-analyze not installed; skipped verify"
fi

[ "$FAIL" = 0 ] || exit 1
echo "install-linux.sh units: ok"
