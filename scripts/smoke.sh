#!/bin/bash
# Loopback smoke test for oab-computer. Every step is time-bounded; the server it
# starts is killed on exit. Usage: scripts/smoke.sh [path-to-binary] [port]
set -u
B="${1:-.build/release/oab-computer}"
PORT="${2:-8797}"
URL="http://127.0.0.1:$PORT/mcp"
LOG="$(mktemp)"

# macOS has no coreutils `timeout`; bound with perl alarm.
t() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
post() { # post <json> [extra curl args...]
  local body="$1"; shift
  curl -s -m 10 -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" -d "$body"
}
field() { python3 -c 'import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

pkill -f "oab-computer --port $PORT" 2>/dev/null || true

echo "--- no auth flags (expect refusal, exit 64) ---"
t 5 "$B" --port "$PORT"; echo "exit=$?"

echo "--- start --insecure-local on $PORT ---"
"$B" --port "$PORT" --insecure-local >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; echo "--- server log ---"; cat "$LOG"; rm -f "$LOG"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.3; done

echo "--- initialize ---"
HDR="$(mktemp)"
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' -D "$HDR" | head -c 300; echo
SID=$(grep -i '^mcp-session-id:' "$HDR" | awk '{print $2}' | tr -d '\r'); rm -f "$HDR"
echo "sid=$SID"
S=(-H "Mcp-Session-Id: $SID")

echo "--- tools/list ---"
post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "${S[@]}" | grep -oE '"name":"[a-z_]+"' | tr '\n' ' '; echo

echo "--- sys_info ---"
post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sys_info","arguments":{}}}' "${S[@]}" | field 'r["result"]["content"][0]["text"]'

echo "--- exec ---"
post '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"exec","arguments":{"command":"uname -m; id -un"}}}' "${S[@]}" | field 'r["result"]["content"][0]["text"]'

echo "--- exec timeout (expect timed_out=true within ~2s) ---"
post '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"exec","arguments":{"command":"sleep 30","timeout_secs":1}}}' "${S[@]}" | field 'r["result"]["structuredContent"]["timed_out"]'

echo "--- screenshot ---"
post '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}' "${S[@]}" \
  | field '[(c["type"], c.get("mimeType"), len(c.get("data","")), c.get("text","")[:120]) for c in r["result"]["content"]]'

echo "--- via-tailscale headers w/o login (expect 401) ---"
post '{"jsonrpc":"2.0","id":7,"method":"ping"}' -H 'X-Forwarded-For: 100.1.1.1' -o /dev/null -w '%{http_code}\n'

echo "--- unknown session (expect 404) ---"
post '{"jsonrpc":"2.0","id":8,"method":"ping"}' -H 'Mcp-Session-Id: nope' -o /dev/null -w '%{http_code}\n'
