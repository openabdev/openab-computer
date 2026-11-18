#!/usr/bin/env bash
# Pure tests for scripts/release-smoke-linux.sh and scripts/check-release-record.sh. No network, no
# systemd, no browser: fixture JSON, a temporary directory and a copy of `sleep`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$here/release-smoke-linux.sh"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect() { # name expected-exit actual-exit
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (wanted exit $2, got $3)"; fi
}
status_json() { # listeners
  printf '{"state":"installed","platform":"linux-x64","containment":"not_checked","listeners":"%s","refusal":"none","hardening_mount":"verified"}' "$1"
}

# V2 (decided): no TCP or UDP listener, and every Unix listener inside the verified private TMPDIR.
P='tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=ok result=pass'
out=$(gate_v2 "$(status_json none)"); expect "V2 none passes" 0 $?
case $out in "GATE V2 pass"*) ok "V2 pass line" ;; *) bad "V2 pass line: $out" ;; esac
out=$(gate_v2 "$(status_json "$P")"); expect "V2 two private unix sockets pass" 0 $?
case $out in *"unix=2"*"result=pass"*) ok "V2 pass line names the listeners" ;; *) bad "V2 pass line: $out" ;; esac
out=$(gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=1 tmpdir=ok result=fail')"); expect "V2 a unix listener outside the private dir fails" 1 $?
case $out in "GATE V2 fail"*) ok "V2 fail line" ;; *) bad "V2 fail line: $out" ;; esac
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=mode result=fail')" >/dev/null; expect "V2 TMPDIR not 0700 fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=owner result=fail')" >/dev/null; expect "V2 TMPDIR of another uid fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=mode result=pass')" >/dev/null; expect "V2 recomputed: tmpdir=mode fails even if result=pass" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=missing result=pass')" >/dev/null; expect "V2 recomputed: tmpdir=missing fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=1 tmpdir=ok result=pass')" >/dev/null; expect "V2 recomputed: unix_outside=1 fails even if result=pass" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=ok result=fail')" >/dev/null; expect "V2 result=fail fails" 1 $?
gate_v2 "$(status_json 'tcp=1 udp=0 unix=2 unix_outside=0 tmpdir=ok result=pass')" >/dev/null; expect "V2 tcp=1 fails even with a private dir" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=1 unix=0 unix_outside=0 tmpdir=ok result=pass')" >/dev/null; expect "V2 udp=1 fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2')" >/dev/null; expect "V2 the old word without the verdict fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=x tmpdir=ok result=pass')" >/dev/null; expect "V2 a non-number fails" 1 $?
gate_v2 "$(status_json unknown)" >/dev/null; expect "V2 unknown fails" 1 $?
gate_v2 "$(status_json not_running)" >/dev/null; expect "V2 not_running fails (nothing was measured)" 1 $?
gate_v2 '{"state":"installed"}' >/dev/null; expect "V2 missing field fails" 1 $?
gate_v2 '' >/dev/null; expect "V2 empty output fails" 1 $?

# V4: the two systemd modes pass; anything else fails.
gate_v4 systemd >/dev/null; expect "V4 systemd" 0 $?
gate_v4 systemd+mount >/dev/null; expect "V4 systemd+mount" 0 $?
gate_v4 unverified >/dev/null; expect "V4 unverified fails" 1 $?
gate_v4 not_checked >/dev/null; expect "V4 not_checked fails" 1 $?
gate_v4 '' >/dev/null; expect "V4 empty fails" 1 $?

if [ "$(json_field "$(status_json 'tcp=0 udp=0 unix=2')" listeners)" = "tcp=0 udp=0 unix=2" ]; then ok "json_field keeps spaces"; else bad "json_field"; fi

# Survivor check: a process whose executable is below the directory is found, then not once gone.
T=$(mktemp -d "${TMPDIR:-/tmp}/oab-l5-test-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/install" "$T/other"
if [ ! -e /proc/self/exe ]; then
  echo "SKIP survivor check (no /proc: Linux only; CI runs it)"
else
cp "$(command -v sleep)" "$T/install/sleep"
cp "$(command -v sleep)" "$T/other/sleep"
"$T/install/sleep" 30 & inside=$!
"$T/other/sleep" 30 & outside=$!
sleep 0.3
found=$(survivors_under "$T/install" | tr '\n' ' ')
case " $found" in *" $inside "*) ok "survivor below the directory is found" ;; *) bad "survivor not found: '$found'" ;; esac
case " $found" in *" $outside "*) bad "process outside the directory was reported" ;; *) ok "process outside the directory is not reported" ;; esac
kill "$inside" "$outside" 2>/dev/null
wait "$inside" "$outside" 2>/dev/null
if [ -z "$(survivors_under "$T/install")" ]; then ok "no survivor after the kill"; else bad "survivor after the kill"; fi
fi

# The record gate. A filled record copies the template's rows.
R="$T/records"
mkdir -p "$R"
C="$here/check-release-record.sh"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: missing file fails" 1 $?
"$C" 9.9.9 --dir "$R" --report-only >/dev/null 2>&1; expect "record: missing file, --report-only exits 0" 0 $?
"$C" v9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a leading v is a usage error" 64 $?
cp "$here/../docs/release-records/TEMPLATE.md" "$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: the untouched template fails" 1 $?
fill="$T/filled.md"
sed 's/PENDING/done/g;s/^\(| V[0-9]* [^|]*\)| done |\(.*| yes[^|]*|\)$/\1| pass |\2/;s/^\(| M[0-9]* [^|]*\)| done |/\1| pass |/;s/^\(| Ubuntu [0-9.]* [a-z0-9]* \)| done |/\1| pass |/;s/^\(| Debian 12 container [a-z0-9]* \)| done |/\1| pass |/' "$R/linux-9.9.9.md" >"$fill"
cp "$fill" "$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: all rows filled, V2 and D7 decided, passes" 0 $?
# A row that reopens a decision blocks the release, and the gate names it.
sed 's/^| \(V2 .*\) | pass | /| \1 | open, owner decision pending | /;s/^| \(D7 .*\) | decided, glob kept | /| \1 | open, owner decision pending | /' "$fill" >"$R/linux-9.9.9.md"
out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: V2 and D7 reopened blocks" 1 $?
case $out in *"V2 is open"*"D7 is open"*) ok "record: both open rows are named" ;; *) bad "record: open rows not named: $out" ;; esac
sed 's/^| \(D7 .*\) | decided, glob kept | /| \1 | open, owner decision pending | /' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: D7 reopened alone blocks" 1 $?
grep -v '^| D7 ' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a removed D7 row fails" 1 $?
grep -v '^| V2 ' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a removed V2 row fails" 1 $?
sed 's/^| M3 \(.*\) | pass | done | done | done |$/| M3 \1 | PENDING | done | done | done |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: one PENDING cell fails" 1 $?
sed 's/^| \(V2 .*\) | pass | /| \1 | PENDING | /' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a V2 row without its measurement (PENDING) fails" 1 $?
# A blocking gate (V1, V2, V7) needs exactly pass; n/a (with or without a reason), fail or free text blocks.
for bad_result in fail 'n/a' 'done' 'pass?' ''; do
  sed "s#^| \\(V7 [^|]*\\)| pass |#| \\1| $bad_result |#" "$fill" >"$R/linux-9.9.9.md"
  out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: V7 result '$bad_result' blocks" 1 $?
  case $out in *"gate row not acceptable: V7"*) ok "record: V7 '$bad_result' is named" ;; *) bad "record: V7 '$bad_result' not named: $out" ;; esac
done
sed 's/^| \(V7 [^|]*\)| pass |/| \1| n\/a, no sign-in on this release |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: V7 n/a with a reason blocks" 1 $?
sed 's/^| \(V1 [^|]*\)| pass |/| \1| n\/a, no source yet |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: V1 n/a with a reason blocks" 1 $?
sed 's/^| \(V1 [^|]*\)| pass |/| \1| fail |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: V1 fail blocks" 1 $?
# A strict gate cannot hide: a deleted row, a "|" inside a cell, a Blocking cell edited to "no".
for g in V1 V2 V7 V13; do
  grep -v "^| $g " "$fill" >"$R/linux-9.9.9.md"
  out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: a removed $g row fails" 1 $?
  case $out in *"$g (row missing)"*) ok "record: removed $g row is named" ;; *) bad "record: removed $g row not named: $out" ;; esac
done
sed 's/^| \(V1 [^|]*\)| pass | \([^|]*\)|/| \1| fail | ss -lxp | grep chrome |/' "$fill" >"$R/linux-9.9.9.md"
out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: V1 fail with a pipe in Evidence fails" 1 $?
case $out in *"V1 (malformed row"*) ok "record: the malformed V1 row is named" ;; *) bad "record: malformed V1 not named: $out" ;; esac
sed 's/^| \(V7 .*\)| yes[^|]* |$/| \1| no |/;s/^| \(V7 [^|]*\)| pass |/| \1| fail |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: V7 fail with Blocking edited to no still fails" 1 $?
{ cat "$fill"; grep '^| V7 ' "$fill"; } >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a duplicated V7 row fails" 1 $?
# M rows and smoke-cell rows: each exactly once, Result (any case) pass or n/a with a reason.
sed 's/^| \(M3 [^|]*\)| pass |/| \1| fail |/' "$fill" >"$R/linux-9.9.9.md"
out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: an M3 fail blocks" 1 $?
case $out in *"manual or smoke-cell row not acceptable: M3"*) ok "record: M3 fail is named" ;; *) bad "record: M3 not named: $out" ;; esac
sed 's/^| \(Ubuntu 22.04 arm64\) | pass |/| \1 | fail |/' "$fill" >"$R/linux-9.9.9.md"
out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: a smoke-cell fail blocks" 1 $?
case $out in *"not acceptable: Ubuntu 22.04 arm64"*) ok "record: cell fail is named" ;; *) bad "record: cell not named: $out" ;; esac
for bad_result in Fail FAIL red 'not run' 'done' ''; do
  sed "s#^| \\(M5 [^|]*\\)| pass |#| \\1| $bad_result |#" "$fill" >"$R/linux-9.9.9.md"
  out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: M5 result '$bad_result' blocks" 1 $?
  sed "s#^| \\(Debian 12 container arm64\\) | pass |#| \\1 | $bad_result |#" "$fill" >"$R/linux-9.9.9.md"
  out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: a cell result '$bad_result' blocks" 1 $?
done
sed 's/^| \(M5 [^|]*\)| pass |/| \1| PASS |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: M5 PASS (any case) is accepted" 0 $?
sed 's/^| \(M4 [^|]*\)| pass |/| \1| n\/a, no Raspberry Pi in this cycle |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: M4 n/a with a reason is accepted" 0 $?
sed 's/^| \(M4 [^|]*\)| pass |/| \1| n\/a |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: M4 n/a without a reason blocks" 1 $?
# A deleted M row or smoke-cell row cannot hide (no PENDING left to find).
for g in 'M1 ' 'M10 ' 'Ubuntu 22.04 amd64 ' 'Debian 12 container arm64 '; do
  grep -v "^| $g" "$fill" >"$R/linux-9.9.9.md"
  out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: a removed '$g' row fails" 1 $?
  case $out in *"(row missing)"*) ok "record: removed '$g' row is named" ;; *) bad "record: removed '$g' not named: $out" ;; esac
done
{ cat "$fill"; grep '^| M2 ' "$fill"; } >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a duplicated M2 row fails" 1 $?
# A non-blocking row may be anything but PENDING.
sed 's/^| \(V3 [^|]*\)| done |/| \1| fail |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a non-blocking V3 fail does not block" 0 $?
# The instruction text outside the tables may quote the words without tripping the gate.
cp "$fill" "$R/linux-9.9.9.md"
printf '\nThe words open, owner decision pending and PENDING in prose are not a table row.\n' >>"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: prose outside the tables is ignored" 0 $?

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
