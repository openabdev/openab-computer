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
out=$(gate_v2 "$(status_json none)"); expect "V2 none passes the status rule" 0 $?
case $out in "GATE V2 pass"*) ok "V2 pass line" ;; *) bad "V2 pass line: $out" ;; esac
out=$(gate_v2 "$(status_json "$P")"); expect "V2 two private unix sockets pass" 0 $?
case $out in *"unix=2"*"result=pass"*) ok "V2 pass line names the listeners" ;; *) bad "V2 pass line: $out" ;; esac
out=$(gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=1 tmpdir=ok result=fail')"); expect "V2 a unix listener outside the private dir fails" 1 $?
case $out in "GATE V2 fail"*) ok "V2 fail line" ;; *) bad "V2 fail line: $out" ;; esac
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=mode result=fail')" >/dev/null; expect "V2 TMPDIR not 0700 fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=owner result=fail')" >/dev/null; expect "V2 TMPDIR of another uid fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=mode result=pass')" >/dev/null; expect "V2 recomputed: tmpdir=mode fails even if result=pass" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=missing result=pass')" >/dev/null; expect "V2 recomputed: tmpdir=missing fails" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=0 unix_outside=0 tmpdir=mode result=pass')" >/dev/null; expect "V2 a bad TMPDIR fails even with no unix listener" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=0 unix_outside=0 tmpdir=mode result=fail')" >/dev/null; expect "V2 zero listeners with a 0755 TMPDIR fails (status word)" 1 $?
gate_v2 "$(status_json 'tcp=0 udp=0 unix=0 unix_outside=0 tmpdir=owner result=fail')" >/dev/null; expect "V2 zero listeners with a foreign-owned TMPDIR fails (status word)" 1 $?
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

# V2 in a real cell: a loaded page is required, and `listeners=none` alone never passes.
L="$(mktemp -d "${TMPDIR:-/tmp}/oab-l5-test-gate.XXXXXX")"
trap 'rm -rf "$L"' EXIT
printf 'READY ok\n' >"$L/nonav.log"
printf 'READY ok\nNAVIGATE ok\nSNAPSHOT_HAS_TEXT true\n' >"$L/page.log"
gate_real_cell "$L/nonav.log" "$(status_json "$P")" >/dev/null; expect "real cell: no NAVIGATE ok fails even with two private sockets" 1 $?
gate_real_cell "$L/page.log" "$(status_json none)" >/dev/null; expect "real cell: a loaded page with listeners=none alone fails" 1 $?
out=$(gate_real_cell "$L/page.log" "$(status_json none)"); case $out in *"not measured"*) ok "real cell: listeners=none is named" ;; *) bad "real cell none not named: $out" ;; esac
out=$(gate_real_cell "$L/page.log" "$(status_json "$P")"); expect "real cell: a loaded page and two private sockets pass" 0 $?
case $out in "GATE V2 pass"*) ok "real cell: pass line" ;; *) bad "real cell pass line: $out" ;; esac
gate_real_cell "$L/page.log" "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=ok result=fail')" >/dev/null; expect "real cell: result=fail fails" 1 $?
gate_real_cell "$L/page.log" "$(status_json 'tcp=0 udp=0 unix=2 unix_outside=1 tmpdir=ok result=pass')" >/dev/null; expect "real cell: unix_outside=1 fails" 1 $?

# root_command: the container runs as root with no sudo, so a leading sudo is removed.
if [ "$(root_command 'sudo apt-get install -y libnss3')" = 'apt-get install -y libnss3' ]; then ok "root_command strips a leading sudo"; else bad "root_command strips a leading sudo"; fi
if [ "$(root_command 'apt-get install -y libnss3')" = 'apt-get install -y libnss3' ]; then ok "root_command leaves a line without sudo unchanged"; else bad "root_command leaves a line without sudo unchanged"; fi
if [ "$(root_command 'echo sudo here')" = 'echo sudo here' ]; then ok "root_command does not strip sudo mid-line"; else bad "root_command does not strip sudo mid-line"; fi
# The container path (the in_container body, and the docker run in the workflow) names no sudo.
body=$(sed -n '/^in_container() {/,/^}/p' "$here/release-smoke-linux.sh" | grep -v '^ *#')
case $body in *sudo*) bad "in_container runs sudo" ;; *) ok "in_container body names no sudo" ;; esac
wf="$here/../.github/workflows/linux-release-smoke.yml"
run=$(sed -n '/docker run/,/--in-container/p' "$wf")
case $run in *"docker run"*) ;; *) bad "docker run line not found in the workflow" ;; esac
case $run in *sudo*) bad "docker run passes sudo into the container" ;; *) ok "docker run line names no sudo" ;; esac

# V4: the two systemd modes pass; anything else fails.
gate_v4 systemd >/dev/null; expect "V4 systemd" 0 $?
gate_v4 systemd+mount >/dev/null; expect "V4 systemd+mount" 0 $?
gate_v4 unverified >/dev/null; expect "V4 unverified fails" 1 $?
gate_v4 not_checked >/dev/null; expect "V4 not_checked fails" 1 $?
gate_v4 '' >/dev/null; expect "V4 empty fails" 1 $?

if [ "$(json_field "$(status_json 'tcp=0 udp=0 unix=2')" listeners)" = "tcp=0 udp=0 unix=2" ]; then ok "json_field keeps spaces"; else bad "json_field"; fi

# Survivor check: a process whose executable is below the directory is found, then not once gone.
T=$(mktemp -d "${TMPDIR:-/tmp}/oab-l5-test-smoke.XXXXXX")
trap 'rm -rf "$T" "$L"' EXIT
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

# ---------------------------------------------------------------- the record gate (ADR D16)
#
# The valid record is the template with every PENDING replaced by pass. Each bypass below edits a COPY
# of it and must make check-release-record.sh exit 1; the untouched copy must exit 0. The rows are
# matched by their first cell, so a row is found by its id (V1 .. V13, M1 .. M10) or by its cell name.
# A row inside an HTML comment does not count: the checker refuses any record that contains "<!--".
R="$T/records"
mkdir -p "$R"
C="$here/check-release-record.sh"
TPL="$here/../docs/release-records/TEMPLATE.md"
VALID="$R/valid.md"
REC="$R/linux-9.9.9.md"
sed 's/PENDING/pass/g' "$TPL" >"$VALID"

"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: no record file fails" 1 $?
"$C" 9.9.9 --dir "$R" --report-only >/dev/null 2>&1; expect "record: no record file, --report-only exits 0" 0 $?
"$C" v9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a leading v is a usage error" 64 $?
"$C" abc --dir "$R" >/dev/null 2>&1; expect "record: a non-version is a usage error" 64 $?
cp "$TPL" "$REC"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: the untouched template fails" 1 $?
cp "$VALID" "$REC"
"$C" 9.9.9 --dir "$R" >"$T/valid.out" 2>&1; expect "record: the valid record passes" 0 $?

# reject NAME SED_PROGRAM: the copy edited by SED_PROGRAM must make the checker exit 1, and the name is
# printed for each case.
reject() {
  sed "$2" "$VALID" >"$REC"
  "$C" 9.9.9 --dir "$R" >"$T/out" 2>&1
  code=$?
  if [ "$code" -eq 1 ] && grep -q '^release record: ' "$T/out"; then ok "reject: $1"; else bad "reject: $1 (exit $code, wanted 1 with a finding): $(head -c 300 "$T/out")"; fi
}
# accept NAME SED_PROGRAM: the copy must still pass.
accept() {
  sed "$2" "$VALID" >"$REC"
  "$C" 9.9.9 --dir "$R" >"$T/out" 2>&1
  code=$?
  if [ "$code" -eq 0 ]; then ok "accept: $1"; else bad "accept: $1 (exit $code, wanted 0): $(head -c 300 "$T/out")"; fi
}

# Each row id (with its trailing space, so V1 does not match V10) gets the same set of mutations.
for id in V1 V2 V3 V4 V5 V6 V7 V8 V9 V10 V11 V12 V13; do
  reject "$id row deleted" "/^| $id /d"
  reject "$id row duplicated" "/^| $id /p"
  reject "$id row malformed (five cells)" "/^| $id /s/\$/ extra |/"
  reject "$id result fail" "/^| $id /s#| pass |#| fail |#"
  reject "$id result empty" "/^| $id /s#| pass |#|  |#"
  reject "$id result n/a without a reason" "/^| $id /s#| pass |#| n/a |#"
  reject "$id result n/a with a reason" "/^| $id /s#| pass |#| n/a, no runner in this cycle |#"
  reject "$id result PENDING" "/^| $id /s#| pass |#| PENDING |#"
done
for id in M1 M2 M3 M4 M5 M6 M7 M8 M9 M10; do
  reject "$id row deleted" "/^| $id /d"
  reject "$id row duplicated" "/^| $id /p"
  reject "$id row malformed (extra cell)" "/^| $id /s/\$/ extra |/"
  reject "$id result n/a" "/^| $id /s#| pass |#| n/a |#"
  reject "$id result n/a with a reason" "/^| $id /s#| pass |#| n/a, no Raspberry Pi in this cycle |#"
  reject "$id result fail" "/^| $id /s#| pass |#| fail |#"
  reject "$id result FAIL (upper case)" "/^| $id /s#| pass |#| FAIL |#"
  reject "$id result PENDING" "/^| $id /s#| pass |#| PENDING |#"
done
# Hidden rows: the visible V1 row is deleted and a passing copy is placed inside an HTML comment, and a
# whole valid record is wrapped in one comment. Both must be refused.
reject "V1 row deleted and a passing copy hidden in an HTML comment" "/^| V1 /d
\$a\\
<!--\\
| V1 | pass | hidden | b |\\
-->"
reject "a complete valid record wrapped in one HTML comment" "1i\\
<!--
\$a\\
-->"
# A bare id (the cell is only "M1", with no description) is still that row: a non-pass duplicate of a
# valid M1 row, or an empty result, must be refused.
reject "M1 bare-id duplicate with result fail" "/^| M1 /a\\
| M1 | fail | | | |"
reject "M1 bare-id duplicate with an empty result" "/^| M1 /a\\
| M1 | | | | |"
reject "M1 result empty" "/^| M1 /s#| pass |#|  |#"
reject "V1 unpadded-id duplicate with result fail" "/^| V1 /a\\
|V1|fail|e|b|"
for cell in "Ubuntu 22.04 amd64" "Ubuntu 22.04 arm64" "Ubuntu 24.04 amd64" "Ubuntu 24.04 arm64" "Debian 12 container amd64" "Debian 12 container arm64"; do
  reject "smoke cell '$cell' row deleted" "/^| $cell |/d"
  reject "smoke cell '$cell' row duplicated" "/^| $cell |/p"
  reject "smoke cell '$cell' row malformed" "/^| $cell |/s/\$/ extra |/"
  reject "smoke cell '$cell' result n/a" "/^| $cell |/s#| pass |#| n/a |#"
  reject "smoke cell '$cell' result fail" "/^| $cell |/s#| pass |#| fail |#"
done
reject "V2 row still PENDING" "/^| V2 /s#| pass |#| PENDING |#"
reject "V2 reopened as an owner decision" "/^| V2 /s#| pass |#| open, owner decision pending |#"
reject "D7 reopened as an owner decision" "/^| D7 /s#| decided, glob kept |#| open, owner decision pending |#"
reject "V2 row removed" "/^| V2 /d"
reject "D7 row removed" "/^| D7 /d"
reject "a PENDING cell in a manual row" "/^| M6 /s#| pass |#| PENDING |#"
accept "M5 result in another case (PASS) is pass" "/^| M5 /s#| pass |#| PASS |#"
accept "prose outside the tables may quote the words" "\$a\\
The words open, owner decision pending, n/a and PENDING in prose are not a table row."

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
