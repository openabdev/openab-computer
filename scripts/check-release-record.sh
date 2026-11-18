#!/usr/bin/env bash
# The per-release manual record gate (docs/releasing.md "Linux release gates", ADR D16).
#
#   check-release-record.sh VERSION [--report-only] [--dir DIR]
#
# VERSION is the release version without the leading v. The record is
# docs/release-records/linux-VERSION.md, committed before the tag. It passes only when:
#   - the file exists;
#   - no table row still holds the placeholder PENDING;
#   - the V2 and D7 rows exist and neither still says "open, owner decision pending";
#   - each of V1 to V13 has exactly one row of exactly four cells (no "|" inside a cell);
#   - V1, V2 and V7 have a Result of "pass" whatever their Blocking cell says; any other row whose
#     Blocking cell starts with "yes" has "pass", or "n/a, reason". A "fail", an empty cell or any other
#     text blocks the release.
# The script never writes, never fills a cell and never treats V2 or D7 as resolved: those two rows
# stay red until a person records the owner's decision in the row (and in the ADR). Only lines that
# start with `|` (table rows) are read, so the instructions around the tables may quote the words.
# --report-only prints the same findings and exits 0 (a workflow_dispatch run without a tag).
set -u

version=${1:-}
[ -n "$version" ] || { echo "usage: check-release-record.sh VERSION [--report-only] [--dir DIR]" >&2; exit 64; }
shift
report_only=0
dir="$(dirname "$0")/../docs/release-records"
while [ $# -gt 0 ]; do
  case $1 in
    --report-only) report_only=1; shift ;;
    --dir) dir=${2:-}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "VERSION must be MAJOR.MINOR.PATCH, without a leading v" >&2; exit 64 ;;
esac

file="$dir/linux-$version.md"
problems=0
say() { echo "release record: $*"; problems=$((problems + 1)); }

if [ ! -f "$file" ]; then
  say "missing: docs/release-records/linux-$version.md (copy docs/release-records/TEMPLATE.md, run the manual rows, commit it before the tag)"
else
  rows=$(grep '^|' "$file" || true)
  n=$(printf '%s\n' "$rows" | grep -c 'PENDING' || true)
  [ "$n" -eq 0 ] || say "$n table row(s) still contain PENDING"
  for id in V2 D7; do
    row=$(printf '%s\n' "$rows" | grep "^| $id " || true)
    if [ -z "$row" ]; then
      say "the $id row is missing; it may not be removed until the owner's decision is recorded in the ADR"
    elif printf '%s' "$row" | grep -q 'open, owner decision pending'; then
      say "$id is open, owner decision pending: a release stays blocked"
    fi
  done
  # Gate rows: | Gate | Result | Evidence | Blocking |. Exactly one row per gate V1..V13 must exist and
  # have exactly four cells (a "|" inside a cell makes five and is refused, so a row cannot hide from the
  # check). V1, V2 and V7 take only "pass", whatever their Blocking cell says. Another row whose Blocking
  # cell starts with "yes" takes "pass", or "n/a" with a reason.
  bad=$(printf '%s\n' "$rows" | awk -F'|' '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    $2 ~ /^ *V[0-9]+ / {
      id = trim($2); sub(/ .*/, "", id)
      seen[id]++
      if (NF != 6) { print id " (malformed row: " NF - 2 " cells, need 4; no \"|\" inside a cell)"; next }
      r = trim($3)
      strict = (id == "V1" || id == "V2" || id == "V7")
      if (strict) { if (r != "pass") print id " (result: " r ")" }
      else if (trim($5) ~ /^yes/ && r != "pass" && r !~ /^n\/a[ ]*[,:;-][ ]*[^ ]/) print id " (result: " r ")"
    }
    END {
      for (i = 1; i <= 13; i++) {
        k = "V" i
        if (seen[k] == 0) print k " (row missing)"
        else if (seen[k] > 1) print k " (" seen[k] " rows, need exactly one)"
      }
    }')
  if [ -n "$bad" ]; then
    while IFS= read -r line; do
      say "gate row not acceptable: $line; V1 to V13 need one well-formed row each; V1, V2 and V7 need pass; another blocking row needs pass, or n/a with a reason"
    done <<EOF
$bad
EOF
  fi
fi

if [ "$problems" -eq 0 ]; then
  echo "release record: ok ($file)"
  exit 0
fi
if [ "$report_only" -eq 1 ]; then
  echo "release record: $problems finding(s); --report-only, not failing"
  exit 0
fi
exit 1
