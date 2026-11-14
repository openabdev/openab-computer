#!/bin/bash
# The private-identifier check passes on this repo and fails on a temp copy with a forbidden pattern.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc=0
"$ROOT/scripts/check-no-private-identifiers.sh" "$ROOT" || { echo "FAIL: repo has private identifiers"; rc=1; }
mkdir -p "$T/scripts"
cp "$ROOT/scripts/check-no-private-identifiers.sh" "$ROOT/scripts/private-identifiers.allow" "$T/scripts/"
# Each sample is built from pieces so this file itself holds no forbidden literal.
declare -a SAMPLES=(
  "see host mac""mini for details"
  "wss://box.tail""b836bb.ts.net/x"
  "wss://box.tailabc123.ts.net/x"
  "connect to 100.74.""35.49 now"
  "lan 192.168.""0.25"
  "contact pahud""net@gmail.com"
  "key tskey-auth-""abcdef123456"
)
for s in "${SAMPLES[@]}"; do
  rm -rf "$T/repo"; mkdir -p "$T/repo/scripts" "$T/repo/docs"
  cp "$T/scripts/"* "$T/repo/scripts/"
  printf '%s\n' "$s" >"$T/repo/docs/x.md"
  if NO_GIT=1 "$T/repo/scripts/check-no-private-identifiers.sh" "$T/repo" >/dev/null 2>&1; then
    echo "FAIL: not detected: $s"; rc=1
  else echo "ok: detected: ${s%% *}..."; fi
done
rm -rf "$T/repo"; mkdir -p "$T/repo/scripts" "$T/repo/docs"; cp "$T/scripts/"* "$T/repo/scripts/"
printf '%s\n' "wss://<host>.<tailnet>.ts.net 100.64.0.1 192.0.2.5 you@example.com" >"$T/repo/docs/x.md"
if NO_GIT=1 "$T/repo/scripts/check-no-private-identifiers.sh" "$T/repo" >/dev/null 2>&1; then echo "ok: placeholders pass"; else echo "FAIL: placeholders flagged"; rc=1; fi
[ "$rc" = 0 ] && echo "check-no-private-identifiers: all checks passed"
exit "$rc"
