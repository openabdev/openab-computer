#!/bin/bash
# Read-only check, sourced by install.sh and by scripts/test-pw-mcp-check.sh (#115).
# Older installs ran `tailscale serve --https=8443` to 127.0.0.1:8794, which hands the
# unauthenticated Playwright MCP to the whole tailnet. This function only reads
# `tailscale serve status`. It never creates, changes or removes a mapping, and it never
# fails the caller. It prints no login, tailnet name or token.
# Expects $TS (the Tailscale.app binary); falls back to `tailscale` on PATH.
warn_legacy_8443_mapping() {
  local cli="" out
  if [ -n "${TS:-}" ] && [ -x "$TS" ]; then cli=$TS; else cli=$(command -v tailscale 2>/dev/null || true); fi
  if [ -z "$cli" ]; then
    echo "Tailscale :8443 check: could not check (Tailscale CLI not found)"; return 0
  fi
  # TERM_PROGRAM makes the Tailscale.app binary act as a CLI.
  if ! out=$(TERM_PROGRAM=oab-computer-pw-mcp-installer "$cli" serve status 2>/dev/null) || [ -z "$out" ]; then
    echo "Tailscale :8443 check: could not check (serve status unreadable)"; return 0
  fi
  # A mapping is a non-indented "https://...:8443" header followed by a handler line to 8794.
  if printf '%s\n' "$out" | awk '
      /^[^ |]/ { cur = ($0 ~ /:8443([ \t]|$)/) }
      cur && /(127\.0\.0\.1|localhost):8794/ { found = 1 }
      END { exit !found }'; then
    cat <<'MSG'
WARNING: this Mac still maps tailnet port :8443 to 127.0.0.1:8794 (Playwright MCP).
  Playwright MCP has no authentication, so any device on your tailnet can drive the browser,
  including browser_run_code_unsafe. Browser tools do not need it: oab-computer reaches
  Playwright over loopback. This installer does not remove it. To remove it, run:
    tailscale serve --https=8443 off
MSG
  else
    echo "Tailscale :8443 check: no mapping to 127.0.0.1:8794 found"
  fi
  return 0
}
