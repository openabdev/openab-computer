#!/usr/bin/env bash
# Tests for docs/linux-cutover.md that run the guide's own text, not a copy of it:
#   - every ```sh block parses (bash -n), and no `$OLD` or `OLD=` notation is left;
#   - every literal oab-* unit name on a `systemctl` line is one of the names the guide allows;
#   - the step 5.4 rollback links to the full Rollback section and does not say `browser remove` alone;
#   - the drop-in removal block (step 5.2) removes only the dedicated file, against a fake HOME;
#   - the guide's `grep -nE` for active MCP_UPSTREAM assignments matches single-quoted, double-quoted
#     and bare forms, and not comments or UnsetEnvironment=.
# Nothing here touches a real unit, a real HOME, or a port.
set -u
here=$(cd "$(dirname "$0")" && pwd)
GUIDE="$here/../docs/linux-cutover.md"
pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/oab-l5-test-guide.XXXXXX")
trap 'rm -rf "$T"' EXIT

# Every ```sh fenced block, indented or not, one file per block.
awk -v dir="$T" '
  /^ *```sh$/ { inb = 1; n++; f = dir "/block" n ".sh"; next }
  /^ *```$/ && inb { inb = 0; close(f); next }
  inb { print > f }
' "$GUIDE"
blocks=$(find "$T" -maxdepth 1 -name 'block*.sh' | wc -l | tr -d ' ')
if [ "$blocks" -gt 0 ]; then ok "found $blocks sh blocks"; else bad "no sh blocks found"; fi
syntax_bad=0
for f in "$T"/block*.sh; do
  if ! bash -n "$f" 2>"$T/err"; then syntax_bad=$((syntax_bad + 1)); echo "  syntax: $(basename "$f"): $(head -n 1 "$T/err")"; fi
done
if [ "$syntax_bad" -eq 0 ]; then ok "every sh block parses (bash -n)"; else bad "$syntax_bad sh block(s) do not parse"; fi

# No `$OLD` notation, no `OLD=` assignment.
if grep -nE '[$]OLD|OLD=' "$GUIDE" >"$T/old.txt"; then bad "the guide still uses the OLD notation: $(head -n 1 "$T/old.txt")"; else ok "no \$OLD or OLD= notation"; fi

# Literal oab-* unit names on systemctl lines. Allowed: the old unit of each host class, the daemon
# unit, the instance-mcp unit of 0.11, and the browser wildcard the guide names.
allowed='oab-computer-pw-mcp.service oab-pw-mcp.service oab-computer.service oab-instance-mcp.service oab-browser-*.service'
unit_bad=0
grep -h 'systemctl' "$GUIDE" | grep -oE "oab-[A-Za-z0-9*._-]+\.service" | sort -u >"$T/units.txt"
while IFS= read -r u; do
  case " $allowed " in *" $u "*) ;; *) unit_bad=$((unit_bad + 1)); echo "  unexpected unit name: $u" ;; esac
done <"$T/units.txt"
if [ "$unit_bad" -eq 0 ]; then ok "every literal unit name on a systemctl line is allowed ($(wc -l <"$T/units.txt" | tr -d ' ') distinct)"; else bad "$unit_bad unexpected unit name(s)"; fi

# Step 5.4 rollback: it links to the Rollback section, and no line gives `browser remove` alone.
bt='`'
if grep -qE "^[*][*]Roll back to here[.][*][*] ${bt}browser remove${bt}" "$GUIDE"; then bad "a rollback line says browser remove alone"; else ok "no rollback line says browser remove alone"; fi
sec=$(sed -n '/^### 5\.4 /,/^## Step 6/p' "$GUIDE")
case $sec in *"(#rollback)"*) ok "step 5.4 rollback links to the full Rollback section" ;; *) bad "step 5.4 does not link to #rollback" ;; esac

# The drop-in removal block: the one whose text defines dropin_is_ours. Run it with a fake HOME.
block=$(awk '/^ *```sh$/ { inb = 1; buf = ""; next } /^ *```$/ && inb { if (buf ~ /dropin_is_ours\(\)/) { printf "%s", buf; exit } inb = 0; next } inb { buf = buf $0 "\n" }' "$GUIDE")
if [ -z "$block" ]; then
  bad "the drop-in removal block is not in the guide"
else
  printf '%s\n' "$block" >"$T/dropin.sh"
  dropin_case() { # dropin_case NAME EXPECT(removed|kept) CONTENT [symlink]
    local h="$T/home-$1"
    rm -rf "$h"
    mkdir -p "$h/.config/systemd/user/oab-computer.service.d"
    local f="$h/.config/systemd/user/oab-computer.service.d/upstream.conf"
    if [ "${4:-}" = symlink ]; then
      printf '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n' >"$T/target-$1.conf"
      ln -s "$T/target-$1.conf" "$f"
    else
      printf '%b' "$3" >"$f"
    fi
    HOME="$h" bash "$T/dropin.sh" >"$T/out-$1" 2>&1
    if [ "$2" = removed ]; then
      if [ ! -e "$f" ] && [ ! -L "$f" ]; then ok "drop-in: $1 is removed"; else bad "drop-in: $1 should be removed"; fi
    else
      if [ -e "$f" ] || [ -L "$f" ]; then ok "drop-in: $1 is kept"; else bad "drop-in: $1 should be kept"; fi
    fi
  }
  dropin_case exact removed '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n'
  dropin_case comments_and_blank removed '# written by an installer\n\n[Service]\n\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n'
  dropin_case extra_setting kept '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\nEnvironment=OAB_BROWSER=off\n'
  dropin_case other_url kept '[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8795/mcp\n'
  dropin_case quoted kept "[Service]\nEnvironment='MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp'\n"
  dropin_case double_quoted kept '[Service]\nEnvironment="MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"\n'
  dropin_case two_service_sections kept '[Service]\n[Service]\nEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n'
  dropin_case symlink kept '' symlink
fi

# The guide's own grep -nE, read from the guide, against fixtures.
re=$(grep -E '^grep -nE "' "$GUIDE" | head -n 1 | sed -e 's/^grep -nE "//' -e 's/" \\$//')
re=${re//\\\"/\"}
if [ -z "$re" ]; then
  bad "the guide's grep -nE pattern is not found"
else
  # check NAME yes|no TEXT: the guide's pattern matches TEXT (yes) or does not (no).
  check() {
    local got=no
    if printf '%s\n' "$3" | grep -qE "$re"; then got=yes; fi
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1"; fi
  }
  check "grep: single-quoted assignment matches" yes "Environment='MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp'"
  check "grep: double-quoted assignment matches" yes 'Environment="MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"'
  check "grep: bare assignment matches" yes "Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"
  check "grep: assignment after another setting matches" yes "Environment=OAB_X=1 MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"
  check "grep: a commented line does not match" no "# Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"
  check "grep: UnsetEnvironment= does not match" no "UnsetEnvironment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
