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
cp "$(command -v sleep)" "$T/install/sleeper"
cp "$(command -v sleep)" "$T/other/sleeper"
"$T/install/sleeper" 30 & inside=$!
"$T/other/sleeper" 30 & outside=$!
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
sed 's/PENDING/done/g' "$R/linux-9.9.9.md" >"$fill"
cp "$fill" "$R/linux-9.9.9.md"
out=$("$C" 9.9.9 --dir "$R" 2>&1); expect "record: V2 and D7 open still blocks after every PENDING is filled" 1 $?
case $out in *"V2 is open"*"D7 is open"*) ok "record: both open rows are named" ;; *) bad "record: open rows not named: $out" ;; esac
case $out in *PENDING*) bad "record: PENDING reported after fill" ;; *) ok "record: no PENDING left after fill" ;; esac
sed 's/open, owner decision pending/decided in the ADR/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: all rows resolved passes" 0 $?
grep -v '^| D7 ' "$fill" | sed 's/open, owner decision pending/decided in the ADR/' >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: a removed D7 row fails" 1 $?
sed 's/open, owner decision pending/decided in the ADR/;s/^| M3 \(.*\) | done | done | done | done |$/| M3 \1 | PENDING | done | done | done |/' "$fill" >"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: one PENDING cell fails" 1 $?
# The instruction text outside the tables may quote the words without tripping the gate.
sed 's/open, owner decision pending/decided in the ADR/' "$fill" >"$R/linux-9.9.9.md"
printf '\nThe words open, owner decision pending and PENDING in prose are not a table row.\n' >>"$R/linux-9.9.9.md"
"$C" 9.9.9 --dir "$R" >/dev/null 2>&1; expect "record: prose outside the tables is ignored" 0 $?

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
