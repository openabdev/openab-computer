#!/bin/zsh
# Playwright MCP for oab-instance-mcp step-1 PoC. Loopback only (127.0.0.1:8794); never exposed with tailscale serve (#115).
export PATH=/opt/homebrew/bin:/usr/bin:/bin
BASE="$HOME/.local/oab-instance-mcp"
DNSNAME="${TS_DNSNAME:-$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --self --peers=false --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"
cd "$BASE/pw-mcp"
exec ./node_modules/.bin/playwright-mcp \
  --host 127.0.0.1 --port 8794 \
  --allowed-hosts "$DNSNAME,127.0.0.1,localhost" \
  --user-data-dir "$BASE/pw-profile" \
  --output-dir "$BASE/pw-output" \
  --idle-timeout 1800000 \
  --browser chromium --shared-browser-context --caps vision,pdf
