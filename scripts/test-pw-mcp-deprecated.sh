#!/bin/bash
# D14, R7.1: poc/reverse-attach-linux/pw-mcp.sh is deprecated. It must say so once on stderr when it
# starts and still launch Playwright MCP with the same arguments (a binary rollback restores a
# working script). A stub stands in for playwright-mcp: nothing real is started and HOME is a temp
# directory. Usage: scripts/test-pw-mcp-deprecated.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/poc/reverse-attach-linux/pw-mcp.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The header says it is deprecated and where to read more.
head -n 8 "$SCRIPT" | grep -q '^# DEPRECATED' || fail "no DEPRECATED header in the first lines of pw-mcp.sh"
head -n 8 "$SCRIPT" | grep -q 'docs/linux-cutover.md' || fail "the header does not point at docs/linux-cutover.md"

mkdir -p "$T/home/.local/oab-computer/pw-mcp/node_modules/.bin"
STUB="$T/home/.local/oab-computer/pw-mcp/node_modules/.bin/playwright-mcp"
cat >"$STUB" <<'STUBEOF'
#!/bin/bash
echo "STUB-ARGS $*"
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$STUB"

rc=0
run() { # run [VAR=value...]: stdout to $T/out, stderr to $T/err, status in $rc
  rc=0
  env -i HOME="$T/home" PATH="/usr/bin:/bin" PW_CHROMIUM=/opt/test/chromium "$@" \
    bash "$SCRIPT" >"$T/out" 2>"$T/err" || rc=$?
}

run
[ "$rc" = 0 ] || fail "exit status $rc, want 0 (the stub's)"
[ "$(grep -c 'DEPRECATED' "$T/err")" = 1 ] || fail "stderr must carry the deprecation line exactly once: $(cat "$T/err")"
grep -q 'docs/linux-cutover.md' "$T/err" || fail "the warning does not point at docs/linux-cutover.md"
grep -q "oab-computer browser install" "$T/err" || fail "the warning does not name the replacement"
grep -q '127.0.0.1:8794' "$T/err" || fail "the warning does not name the listener"
[ "$(wc -l <"$T/err" | tr -d ' ')" = 1 ] || fail "the warning is one line"
# No URL or token in the notice.
if grep -Eq 'https?://|token|Bearer' "$T/err"; then fail "the warning carries a URL or token"; fi
# The warning stays off stdout.
if grep -q 'DEPRECATED' "$T/out"; then fail "the warning leaked to stdout"; fi

# The launch is unchanged.
want="STUB-ARGS --host 127.0.0.1 --port 8794 --allowed-hosts 127.0.0.1,localhost,127.0.0.1:8794,localhost:8794 --browser chromium --executable-path /opt/test/chromium --user-data-dir $T/home/.local/oab-computer/pw-profile --output-dir $T/home/.local/oab-computer/pw-output --idle-timeout 1800000 --shared-browser-context --caps vision,pdf"
[ "$(cat "$T/out")" = "$want" ] || fail "launch arguments changed:
got:  $(cat "$T/out")
want: $want"

# The stub's exit status passes through exec, and the warning is printed once per start.
run STUB_EXIT=7
[ "$rc" = 7 ] || fail "exit status $rc, want 7"
[ "$(grep -c 'DEPRECATED' "$T/err")" = 1 ] || fail "the warning is printed once per start"

# A config file, when present, is still passed (the optional argument is unchanged).
echo '{}' >"$T/home/.local/oab-computer/pw-config.json"
run
grep -q -- "--config $T/home/.local/oab-computer/pw-config.json" "$T/out" || fail "--config no longer passed"

echo "ok: pw-mcp.sh is marked deprecated, warns once on stderr and launches unchanged"
