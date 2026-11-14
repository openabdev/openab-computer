#!/bin/bash
# #115: Playwright MCP must stay on loopback. (1) Guard: no `tailscale serve` / `$TS serve` call
# that targets 8794 or 8443 under poc/pw-mcp/. (2) The read-only :8443 check, run against a stub
# CLI (no real tailscale is called). Usage: scripts/test-pw-mcp-check.sh [dir-to-guard]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/poc/pw-mcp}"

# Any `tailscale|$TS|$cli serve ...` call under the dir fails, whatever port or variable it names,
# except the read-only `serve status` and the documented removal `serve --https=8443 off`.
# Backslash continuations are joined first, the allowed forms are cut out of each logical line
# (so they cannot hide a second call on the same line), and comment lines are skipped.
# Scanned: every file except *.md (the README may describe the old mapping).
hits=""
while IFS= read -r f; do
  out=$(awk '/\\$/ { sub(/\\$/, ""); buf = buf $0; next } { print FNR ": " buf $0; buf = "" }' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | sed -e 's/serve status//g' -e 's/serve --https=8443 off//g' \
    | grep -E '(tailscale|Tailscale|\$[{]?[A-Za-z_]+[}]?"?)[[:space:]]+"?serve([[:space:]"]|$)' || true)
  [ -n "$out" ] && hits="$hits$f: $out"$'\n'
done < <(find "$DIR" -type f ! -name '*.md')
if [ -n "$hits" ]; then
  echo "FAIL: tailscale serve call under $DIR (#115):" >&2; printf '%s' "$hits" >&2; exit 1
fi
echo "guard ok: no tailscale serve call under $DIR"
[ -n "${1:-}" ] && exit 0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
stub() { # $1 = mode
  cat >"$T/bin/tailscale" <<STUB
#!/bin/sh
[ "\$TERM_PROGRAM" = oab-pw-mcp-installer ] || exit 9
[ "\$1 \$2" = "serve status" ] || { echo "unexpected: \$*" >&2; exit 8; }
case "$1" in
  present) printf 'https://host.example.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:8794\n\nhttps://host.example.ts.net:8444 (tailnet only)\n|-- / proxy http://127.0.0.1:8795\n' ;;
  absent) printf 'https://host.example.ts.net:8444 (tailnet only)\n|-- / proxy http://127.0.0.1:8795\n\nhttps://host.example.ts.net (tailnet only)\n|-- /x proxy http://127.0.0.1:8794\n' ;;
  unreadable) exit 1 ;;
esac
STUB
  chmod +x "$T/bin/tailscale"
}
# shellcheck source=../poc/pw-mcp/check-legacy-mapping.sh disable=SC2034
. "$ROOT/poc/pw-mcp/check-legacy-mapping.sh"
run() { # $1 = mode, $2 = expected substring
  local out; TS=/nonexistent; rm -f "$T/bin/tailscale"; [ "$1" = missing ] || stub "$1"
  out=$(PATH="$T/bin:$([ "$1" = missing ] && echo /usr/bin:/bin || echo "$PATH")" warn_legacy_8443_mapping)
  echo "--- $1"; echo "$out"
  case "$out" in *"$2"*) ;; *) echo "FAIL: $1: expected '$2'" >&2; exit 1 ;; esac
  case "$out" in *host.example*) echo "FAIL: $1: printed a host name" >&2; exit 1 ;; esac
}
run present "tailscale serve --https=8443 off"
run absent "no mapping"
run unreadable "could not check"
run missing "could not check"
echo "stub tests ok"
