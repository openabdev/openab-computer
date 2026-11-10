#!/usr/bin/env bash
# Smoke test: reverse-attach hands node (Rust) against mock_runtime.py.
# Runs entirely on loopback of the node. Every step is time-bounded.
set -u
cd "$(dirname "$0")"
BIN=./target/release/reverse-attach
LOG=/tmp/mock-runtime.jsonl
RA_LOG=/tmp/reverse-attach.log
pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }

pkill -x reverse-attach 2>/dev/null; pkill -f mock_runtime.py 2>/dev/null; sleep 0.3
rm -f "$LOG" "$RA_LOG"
# Never touch the real ~/.local/state grants file from a test run.
GRANTS_DIR=$(mktemp -d)
export MCP_GRANTS_FILE="$GRANTS_DIR/grants.json"
export MCP_AUDIT_FILE="$GRANTS_DIR/audit.jsonl"

# 1000 → redial, then 4010 → stop(revoked). Third attach (if any) would be 4010 again.
PORT=18090 ADMIN=admin-secret CLOSES=1000,4010 SECRETS=pre=preminted-xyz,bare=bare-xyz,dsk=dsk-xyz LOG=$LOG \
  python3 mock_runtime.py > /tmp/mock-runtime.out 2>&1 &
MOCK=$!
# Job logs go under XDG_STATE_HOME: keep them in the scratch dir too.
XDG_STATE_HOME=$GRANTS_DIR BIND=127.0.0.1:8790 MCP_INSECURE_LOCAL=1 MCP_UPSTREAM=browser=http://127.0.0.1:1/mcp $BIN > "$RA_LOG" 2>&1 &
RA=$!
sleep 0.5
trap 'kill $MOCK $RA 2>/dev/null; rm -rf "$GRANTS_DIR"' EXIT

C="curl -s -m 5"
state_of() { python3 -c 'import sys,json;print([g["state"] for g in json.load(sys.stdin)["grants"] if g["session"]==sys.argv[1]][0])' "$1"; }
ended_of() { python3 -c 'import sys,json;print([g.get("ended","") for g in json.load(sys.stdin)["grants"] if g["session"]==sys.argv[1]][0])' "$1"; }

echo "== validation =="
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"http://x","session":"a","secret":"s"}')
check "reject non-ws runtime" "[[ '$r' == *'ws://'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"Bad_Session","secret":"s"}')
check "reject bad session" "[[ '$r' == *'session must match'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","secret":"s","admin_credential":"c"}')
check "reject both secret+admin" "[[ '$r' == *'exactly one'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a"}')
check "reject neither secret nor admin" "[[ '$r' == *'exactly one'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","secret":"s","profile":"Sandbox"}')
check "reject unknown profile (no silent widening)" "[[ '$r' == *'profile must be one of [owner, observe]'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","secret":"s","profile":"sandbox"}')
check "reject the old sandbox profile name (#45)" "[[ '$r' == *'profile must be one of [owner, observe]'* ]]"
for p in Desktop OWNER browser; do
  r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","secret":"s","profile":"'$p'"}')
  check "reject profile $p with the shared message (#59)" "[[ '$r' == '{\"error\":\"profile must be one of [owner, observe]\"}' ]]"
done
r=$($C -o /dev/null -w '%{http_code}' -X POST 127.0.0.1:8790/attach -H 'Content-Length: 99999999' -d '{}')
check "oversized Content-Length refused before auth" "[[ '$r' == 000 || '$r' == 4* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","secret":"s","ttl_secs":0}')
check "reject ttl 0" "[[ '$r' == *'ttl_secs'* ]]"
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"a","admin_credential":"WRONG"}')
check "mint with wrong admin → 400 mint failed 401" "[[ '$r' == *'mint failed: mint HTTP 401'* ]]"
r=$($C -o /dev/null -w '%{http_code}' 127.0.0.1:8790/nope)
check "404 on unknown route" "[[ '$r' == 404 ]]"

echo "== admin_credential mint path (session laptop) =="
raw=$($C -w '\n%{http_code}' -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"laptop","profile":"owner","ttl_secs":60,"admin_credential":"admin-secret"}')
code=$(echo "$raw" | tail -1); r=$(echo "$raw" | sed '$d')
echo "$r"
check "POST /attach → 202" "[[ '$code' == 202 ]]"
GID=$(echo "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "Connect grant shape" "echo '$r' | python3 -c 'import sys,json; g=json.load(sys.stdin); assert all(k in g for k in (\"id\",\"runtime\",\"session\",\"profile\",\"principal\",\"state\",\"expires_in_secs\"))'"
check "grant returned" "[[ -n '$GID' ]]"
check "expires_in_secs≈60 forwarded" "echo '$r' | python3 -c 'import sys,json; assert 58 <= json.load(sys.stdin)[\"expires_in_secs\"] <= 60'"
check "mint saw ttl_secs=60" "grep -q '\"ev\": \"mint\", \"session\": \"laptop\", \"status\": 200, \"ttl_secs\": 60' $LOG"

# wait: attach#1 → MCP script → close 1000 → redial after 1s → attach#2 → close 4010 → stop
for i in $(seq 1 30); do grep -q '"code": 4010, "nth": 2' $LOG 2>/dev/null && break; sleep 0.5; done
st=$($C 127.0.0.1:8790/attach)
echo "$st"
check "GET /attach wraps grants" "echo '$st' | python3 -c 'import sys,json; assert isinstance(json.load(sys.stdin)[\"grants\"], list)'"
check "GET /attach/{id}" "[[ \$($C -o /dev/null -w '%{http_code}' 127.0.0.1:8790/attach/$GID) == 200 ]]"
check "two attaches happened (1000 redialed)" "grep -q '\"nth\": 2' $LOG"
check "state ended/revoked after 4010" "[[ \$(echo '$st' | state_of laptop) == ended && \$(echo '$st' | ended_of laptop) == revoked ]]"
code=$($C -o /dev/null -w '%{http_code}' -X DELETE 127.0.0.1:8790/attach/$GID)
check "DELETE /attach/{id} → 204" "[[ '$code' == 204 ]]"
check "deleted grant GET → 404" "[[ \$($C -o /dev/null -w '%{http_code}' 127.0.0.1:8790/attach/$GID) == 404 ]]"

check "close frame echoed by client (both attaches)" "[[ \$(grep -c '\"ev\": \"close_echo\"' $LOG) == 2 ]]"

echo "== MCP surface (from mock's view of attach #1) =="
py() { python3 - "$LOG" "$@" <<'EOF'
import json,sys
log=[json.loads(l) for l in open(sys.argv[1])]
rpcs=[e for e in log if e["ev"]=="rpc"]
def find(m,n=0):
    return [e for e in rpcs if e["method"]==m][n]["reply"]
def byid(i):
    return [e["reply"] for e in rpcs if e["reply"].get("id")==i][0]
q=sys.argv[2]
if q=="init":   print(find("initialize")["result"]["serverInfo"]["name"])
if q=="srvver": print(find("initialize")["result"]["serverInfo"]["version"])
if q=="sysver": print(byid(3)["result"]["structuredContent"]["agent"]["version"])
if q=="tools":  print(",".join(t["name"] for t in find("tools/list")["result"]["tools"]))
if q=="sys":    print(byid(3)["result"]["structuredContent"]["hostname"])
if q=="exec":   print(byid(4)["result"]["structuredContent"]["stdout"].strip().replace("\n"," "))
if q=="timeout":
    sc=byid(7)["result"]["structuredContent"]; print(f'{sc["exit_code"]},{sc["timed_out"] and sc["duration_ms"]<3000}')
if q=="unk":    print(byid(5)["error"]["code"], byid(5)["error"]["message"])
if q=="exec_err": print(byid(4)["error"]["code"], byid(4)["error"]["message"])
if q=="bogus":  print(find("bogus/method")["error"]["code"])
if q=="pong":   print([e for e in log if e["ev"]=="pong"][0]["ok"])
if q=="job":    print(byid(8)["result"]["structuredContent"]["job_id"])
if q=="poll2":
    a=byid(9)["result"]["structuredContent"]; b=byid(10)["result"]["structuredContent"]
    print("tick 1\n" in a["stdout"] and "tick 1\n" not in b["stdout"] and "tick" in b["stdout"]
          and b["stdout_next"] > a["stdout_next"] and b["state"]=="running")
if q=="survived": print(byid(11)["result"]["structuredContent"]["state"])
if q=="killed":
    sc=byid(13)["result"]["structuredContent"]; print(f'{sc["state"]},{sc.get("exit_code")}')
EOF
}
check "initialize → serverInfo instance-mcp-rpi" "[[ \$(py init) == instance-mcp-rpi ]]"
check "owner tools/list = sys_info,screenshot,bash,mouse,key,exec_*" "[[ \$(py tools) == sys_info,screenshot,bash,mouse,key,exec_start,exec_poll,exec_list,exec_cancel ]]"
check "sys_info hostname = $(hostname)" "[[ \$(py sys) == $(hostname) ]]"
# Release builds set OAB_RELEASE_VERSION at compile time and EXPECT_AGENT_VERSION here (#74);
# a plain build must say "-dev", never pass for a release.
if [[ -n "${EXPECT_AGENT_VERSION:-}" ]]; then
  check "sys_info agent.version = $EXPECT_AGENT_VERSION" "[[ \$(py sysver) == '$EXPECT_AGENT_VERSION' ]]"
else
  check "sys_info agent.version is a -dev build" "[[ \$(py sysver) == *-dev ]]"
fi
check "serverInfo.version = sys_info agent.version" "[[ \$(py srvver) == \$(py sysver) ]]"
check "bash ran on node with cwd ~" "[[ \$(py exec) == \"hands-node-$(hostname) $HOME\" ]]"
check "bash timeout → 137 + group killed" "[[ \$(py timeout) == 137,True ]]"
check "unknown tool → -32602" "[[ \$(py unk) == -32602* ]]"
check "unknown method → -32601" "[[ \$(py bogus) == -32601 ]]"
check "ping → pong" "[[ \$(py pong) == True ]]"
JOB=$(py job)
check "exec_start → job_id" "[[ '$JOB' == job-* ]]"
check "exec_poll by offset returns only new output" "[[ \$(py poll2) == True ]]"
check "job log tee'd under XDG_STATE_HOME" "[[ -s '$GRANTS_DIR/oab-instance-mcp/jobs/$JOB.out' ]]"
check "job survived the attach drop (polled on attach 2)" "[[ \$(py survived) == running ]]"
check "exec_cancel → killed with exit code" "[[ \$(py killed) == killed,137 ]]"

echo "== pre-minted secret path + owner profile (session pre) =="
: > $LOG
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"pre","profile":"owner","ttl_secs":30,"secret":"preminted-xyz"}')
echo "$r"
check "grant reports profile owner" "[[ '$r' == *'\"profile\":\"owner\"'* && '$r' == *'\"requested_profile\":\"owner\"'* && '$r' != *'warning'* ]]"
for i in $(seq 1 20); do grep -q '"ev": "closed"' $LOG 2>/dev/null && break; sleep 0.5; done
check "no mint call for secret path" "! grep -q '\"ev\": \"mint\"' $LOG"
check "owner tools/list on the secret path = every local tool" "[[ \$(py tools) == sys_info,screenshot,bash,mouse,key,exec_start,exec_poll,exec_list,exec_cancel ]]"
check "owner bash ran on node" "[[ \$(py exec) == \"hands-node-$(hostname) $HOME\" ]]"
check "no sleep leaked after timeout" "! pgrep -f 'sleep 30' >/dev/null"
check "close frame echoed (owner attach)" "grep -q '\"ev\": \"close_echo\"' $LOG"
st=$($C 127.0.0.1:8790/attach); echo "$st"
check "owner grant ended/revoked (CLOSES tail=4010)" "[[ \$(echo '$st' | state_of pre) == ended && \$(echo '$st' | ended_of pre) == revoked ]]"

echo "== bare attach (no profile) → observe surface (#59) =="
: > $LOG
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"bare","ttl_secs":30,"secret":"bare-xyz"}')
echo "$r"
check "bare grant reports profile observe" "[[ '$r' == *'\"profile\":\"observe\"'* && '$r' == *'\"requested_profile\":\"observe\"'* && '$r' != *'warning'* ]]"
for i in $(seq 1 20); do grep -q '"ev": "closed"' $LOG 2>/dev/null && break; sleep 0.5; done
check "bare tools/list = sys_info,screenshot" "[[ \$(py tools) == sys_info,screenshot ]]"

echo "== desktop request → observe with a warning (#59) =="
: > $LOG
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"dsk","profile":"desktop","ttl_secs":30,"secret":"dsk-xyz"}')
echo "$r"
check "desktop grant runs as observe, never owner" "[[ '$r' == *'\"profile\":\"observe\"'* && '$r' != *'\"profile\":\"owner\"'* ]]"
check "desktop grant reports requested_profile desktop" "[[ '$r' == *'\"requested_profile\":\"desktop\"'* ]]"
check "desktop grant carries the warning" "[[ '$r' == *'\"warning\":\"The \`desktop\` profile was removed (openab-computer#59).'* ]]"
for i in $(seq 1 20); do grep -q '"ev": "closed"' $LOG 2>/dev/null && break; sleep 0.5; done
check "desktop tools/list = sys_info,screenshot" "[[ \$(py tools) == sys_info,screenshot ]]"
check "desktop bash is an unknown tool" "[[ \$(py exec_err) == -32602* ]]"
check "daemon logged the mapping" "grep -q 'profile desktop -> observe' $RA_LOG"
check "the mapping is in the audit file (#59)" "grep -q '\"source\":\"attach\"' \"$MCP_AUDIT_FILE\" && grep -q '\"session\":\"dsk\"' \"$MCP_AUDIT_FILE\""
check "audit file is mode 600" "[[ \$(stat -c %a \"$MCP_AUDIT_FILE\" 2>/dev/null || stat -f %Lp \"$MCP_AUDIT_FILE\") == 600 ]]"

echo "== wrong secret → handshake 401 → stop =="
: > $LOG
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"pre","ttl_secs":30,"secret":"WRONG"}')
sleep 1.5
st=$($C 127.0.0.1:8790/attach)
check "401 handshake → ended/handshake_rejected_401" "[[ \$(echo '$st' | state_of pre) == ended && \$(echo '$st' | ended_of pre) == handshake_rejected_401 ]]"
check "no redial storm on 401 (exactly one attach attempt)" "[[ \$(grep -c '\"ev\": \"attach\", \"session\": \"pre\", \"status\": 401' $LOG) == 1 ]]"

echo "== runtime unreachable → redial with backoff until deadline =="
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:1","session":"dead","ttl_secs":4,"secret":"s"}')
sleep 5.5
st=$($C 127.0.0.1:8790/attach)
check "unreachable runtime ends at deadline" "[[ \$(echo '$st' | state_of dead) == ended && \$(echo '$st' | ended_of dead) == deadline ]]"


echo "== grants survive a restart (#12) =="
kill $RA $MOCK 2>/dev/null; wait $RA $MOCK 2>/dev/null
rm -f "$MCP_GRANTS_FILE" "$LOG"
# CLOSES=1000: the mock closes after each scripted turn and the node redials, so the
# grant stays live and every (re)attach shows up as a new "attach" event.
PORT=18090 ADMIN=admin-secret CLOSES=1000 SECRETS=keep=k1 LOG=$LOG \
  python3 mock_runtime.py > /tmp/mock-runtime.out 2>&1 &
MOCK=$!
start_ra() { BIND=127.0.0.1:8790 MCP_INSECURE_LOCAL=1 $BIN >> "$RA_LOG" 2>&1 & RA=$!; sleep 0.5; }
attaches() { grep -c '"ev": "attach", "session": "keep", "status": 101' $LOG 2>/dev/null || echo 0; }
start_ra
r=$($C -X POST 127.0.0.1:8790/attach -d '{"runtime":"ws://127.0.0.1:18090","session":"keep","profile":"owner","ttl_secs":120,"secret":"k1"}')
GID=$(echo "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for i in $(seq 1 20); do [[ $(attaches) -ge 1 ]] && break; sleep 0.3; done
check "grants file written with mode 600" "[[ \$(stat -c %a \"$MCP_GRANTS_FILE\" 2>/dev/null || stat -f %Lp \"$MCP_GRANTS_FILE\") == 600 ]]"
check "grants file holds the grant" "grep -q \"$GID\" \"$MCP_GRANTS_FILE\""
check "secret never appears in GET /attach" "! $C 127.0.0.1:8790/attach | grep -q k1"
before=$(attaches)
kill -9 $RA 2>/dev/null; wait $RA 2>/dev/null
# Rewrite the row as 0.8.x stored a desktop grant (#59): profile desktop, no requested_profile.
python3 - "$MCP_GRANTS_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["grants"]:
    g["profile"] = "desktop"
    g.pop("requested_profile", None)
json.dump(d, open(p, "w"))
PY
start_ra
for i in $(seq 1 30); do [[ $(attaches) -gt $before ]] && break; sleep 0.3; done
check "after kill -9 + restart the node redialled on its own" "[[ \$(attaches) -gt $before ]]"
check "resumed under the same grant id" "$C 127.0.0.1:8790/attach | grep -q \"$GID\""
check "restart logged the resume" "grep -q \"grants: resuming $GID\" $RA_LOG"
g=$($C 127.0.0.1:8790/attach/$GID)
check "a stored desktop grant resumes as observe (#59)" "[[ '$g' == *'\"profile\":\"observe\"'* && '$g' == *'\"requested_profile\":\"desktop\"'* && '$g' == *'\"warning\"'* ]]"
check "the resumed mapping is in the audit file (#59)" "grep '\"source\":\"resume\"' \"$MCP_AUDIT_FILE\" | grep -q \"$GID\""
check "the grants file now says observe + requested desktop" "python3 -c 'import json,sys;g=json.load(open(sys.argv[1]))[\"grants\"][0];sys.exit(0 if (g[\"profile\"],g[\"requested_profile\"])==(\"observe\",\"desktop\") else 1)' \"$MCP_GRANTS_FILE\""
$C -o /dev/null -X DELETE 127.0.0.1:8790/attach/$GID
check "DELETE removes it from the file" "! grep -q \"$GID\" \"$MCP_GRANTS_FILE\""
kill $RA 2>/dev/null; wait $RA 2>/dev/null
start_ra
check "a revoked grant is not resumed" "[[ \$($C 127.0.0.1:8790/attach | python3 -c 'import sys,json;print(len(json.load(sys.stdin)[\"grants\"]))') == 0 ]]"

echo
echo "reverse-attach stderr:"; sed 's/^/  /' $RA_LOG
echo "RESULT: $pass passed, $fail failed"
[[ $fail == 0 ]]
