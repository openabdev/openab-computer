#!/bin/bash
# Fails if a tracked text file contains a private identifier: a private host name, the tailnet name,
# a real-looking tailnet or LAN address, a personal email or login, or a token-looking string.
# Use placeholders instead: <host>.<tailnet>.ts.net, 100.64.0.x, 192.0.2.x, 198.51.100.x,
# user@example.com. Intentional exceptions are explicit, one per line, in
# scripts/private-identifiers.allow ("<pattern> <path>  # reason").
# Usage: scripts/check-no-private-identifiers.sh [root]   (root: a git checkout or a plain directory)
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
ALLOW="$ROOT/scripts/private-identifiers.allow"
SELF=scripts/check-no-private-identifiers.sh
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -z "${NO_GIT:-}" ]; then
  git ls-files
else
  find . -type f -not -path "./.git/*" -not -path "./.build/*" -not -path "*/target/*" | sed 's|^\./||'
fi | grep -v -e "^$SELF\$" -e '^scripts/private-identifiers.allow$' -e '^scripts/test-check-no-private-identifiers.sh$' -e 'Cargo.lock$' >"$T/files"

# Matched case-insensitively. Host names are whole words.
HOST='(^|[^A-Za-z0-9_-])(black|rpi1|rpi2|minipc|macmini|lzmacmini|oracle-vm|p1|zsv-01|mbp|pahuds-macbook-neo)([^A-Za-z0-9_-]|$)'
HOSTSSH='(ssh|scp|rsync)( +-[A-Za-z]+( +[^ ]+)?)* +([a-z0-9]+@)?(bl|mini|muse)([: ]|$)|(^|[^A-Za-z0-9_-])(bl|mini|muse)\.(local|lan|tail[0-9a-f]*\.ts\.net)'
TAILNET='tailb836bb'
TSNET='[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net'
CGNAT='(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+'
RFC1918='(^|[^0-9.])(192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)'
EMAIL='[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
LOGIN='pahudnet|/Users/pahud|pahud@'
TOKEN='ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|tskey-(auth|api|client)-[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY'

# Placeholder filters: read the matched text on stdin, print what is NOT a placeholder.
f_tsnet() { awk -F. '{ l = $(NF-2) } l != "tail" && l != "tail1" && l != "tail1234" && l != "t" && l != "example" { print }'; }
f_ip() { grep -vE '^100\.64\.0\.[0-9]$|^100\.64\.0\.0$'; }
f_email() { grep -viE '@(example\.(com|org|invalid)|b\.c|users\.noreply\.github\.com)$'; }

: >"$T/hits"
scan() { # name regex [filter-function]
  local name="$1" re="$2" filt="${3:-cat}" f l n
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -nIiE -- "$re" "$f" 2>/dev/null | while IFS= read -r l; do
      n="${l%%:*}"
      # keep the line only if some match survives the placeholder filter
      printf '%s\n' "${l#*:}" | grep -oiE -- "$re" | sed -E 's/^[^0-9A-Za-z]//' | "$filt" | grep -q . || continue
      echo "$name $f:$n"
    done
  done <"$T/files" >>"$T/hits"
}
scan host "$HOST"
scan host "$HOSTSSH"
scan tailnet "$TAILNET"
scan tsnet "$TSNET" f_tsnet
scan ip "$CGNAT" f_ip
scan ip "$RFC1918"
scan email "$EMAIL" f_email
scan login "$LOGIN"
scan token "$TOKEN"

sort -u "$T/hits" | while read -r name loc; do
  f="${loc%:*}"
  if [ -f "$ALLOW" ] && grep -qE "^$name +$f( |\$)" "$ALLOW"; then continue; fi
  echo "private identifier ($name): $loc"
done >"$T/bad"
if [ -s "$T/bad" ]; then
  cat "$T/bad"
  echo "FAIL: replace with placeholders, or add an explicit line to scripts/private-identifiers.allow" >&2
  exit 1
fi
echo "ok: no private identifiers in $(wc -l <"$T/files" | tr -d ' ') files"
