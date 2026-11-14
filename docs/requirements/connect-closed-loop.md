# Requirement — OpenAB Connect closed loop: agent operates the Mac mini, human observes

**Renamed** from `oab-instance-mcp` to `oab-computer` in 0.12.0 (the product name is OpenAB Computer). This is a dated record: paths, unit, label and artifact names below are the 0.8–0.11 names (`oab-instance-mcp`, `dev.openab.instance-mcp`, `oab-pw-mcp.service`).

> Recorded 2026-09-22 (mid-Step-1 PoC). Not scheduled; captured so Step 2/3 design
> choices do not foreclose it. Parent design: openabdev/openab#1544.

## Statement

Using OpenAB Connect (the native macOS/iOS client for `openab-pty`, separate repo):

1. **Observe** — Connect can *attach the Mac agent's screen session* the same way it attaches
   a PTY session today: pick the Mac mini in the session list and see its live desktop
   inside Connect (and later OpenAB Remote on iPhone).
2. **Operate** — the agent running in Connect's PTY session (the coding CLI inside the
   `openab-pty` sandbox) can *drive that same Mac mini over the tailnet*: run commands,
   control the browser, click/type, using the MCP endpoints `oab-instance-mcp` exposes.

Together: **the agent controls the Mac, I watch it happen, from one app**. That is the closed
loop — Connect is where the human both talks to the agent and sees the consequences.

## Why this changes the Step-2 design (constraints to honour now)

- **Screen must be streamable, not just snapshot-able.** `screenshot` as an MCP image
  content block serves the agent's eyes. Connect needs a *continuous* feed: `SCStream` →
  VideoToolbox H.264/HEVC → WebSocket, decoded in Connect with `AVSampleBufferDisplayLayer`.
  Design the Swift daemon with the capture pipeline as a shared component from day one, with
  two sinks (one-shot JPEG for MCP, encoded stream for Connect) — not a screenshot function
  that later grows a stream bolted on.
- **The daemon is a session provider to Connect.** Connect's mental model is "sessions you
  attach to" (openab-pty `CLIENT-CONTRACT.md`: bearer token, WSS attach, keepalive ~50 ms,
  401 ambiguity handling). The Mac agent should present a screen session using the *same
  contract shape* (auth via `Authorization: Bearer`, attach over WSS, admin API to list /
  renew) so Connect gains a new session *kind* rather than a second client stack. Protocol
  models should live in a Swift package shared by the daemon and Connect (the issue's
  "shared Codable protocol models" point).
- **Two callers, two trust levels, one daemon.** The agent in the sandbox calls MCP tools
  (exec / mouse / key / browser); Connect calls the screen-attach endpoint and, later,
  human input passthrough. These must be separately authorisable — the sandbox agent must
  never get the human's attach credential, and Connect's attach token must not grant `exec`.
  Bind auth to *who* (Tailscale identity via `tailscale serve` headers, or per-caller tokens),
  not to the port.
- **Human input passthrough is in scope eventually.** Watching implies wanting to intervene
  (click a captcha, type a password). The same CGEvent injector the agent uses is what
  Connect's mouse/keyboard forwarding will use; keep it a single component.

## Reachability

- Connect (human's Mac / iPhone) → Mac mini screen session: direct over the tailnet,
  `wss://macmini.<tailnet>.ts.net:<port>/…`. Video stream must not transit the sandbox.
- Agent (inside the `openab-pty` sandbox, k8s/ECS) → Mac mini: needs the sandbox on the
  tailnet — `tsnet` embedded in the pod, Tailscale k8s operator, or `tailscaled` sidecar
  (issue §1). Locally today the "sandbox" is just kiro-cli on the laptop, which already
  works (Step 1).
- The Mac mini itself never initiates to either side; it is a passive tailnet service
  guarded by ACLs. Fits the issue's "hands & feet on an isolated VLAN" posture.

## Phasing proposal

| Phase | Deliverable | Depends on |
|---|---|---|
| 2 (planned) | Swift daemon: `exec`, `screenshot`, `sys_info` over MCP | — |
| 2b | Capture pipeline split into shared component; H.264 stream endpoint over WSS with a `ffplay`/`mpv` smoke test | 2 |
| 3 | Connect: new session kind "Mac screen", attach + render via `AVSampleBufferDisplayLayer`; read-only | 2b + openab-pty contract review |
| 3b | Connect: mouse/keyboard passthrough (human intervention) | 3 |
| 4 | Connect's agent (in sandbox) reaches macmini MCP over tailnet — `tsnet` or sidecar in the `openab-pty` image | openab-pty change |

## Open questions

- ~~Register with `openab-pty` runtime vs. direct?~~ **Decided 2026-09-22 (owner: "your
  call"): direct.** Connect keeps a "Mac agents" list alongside runtimes and attaches to the
  daemon over the tailnet; the runtime never sees video. Revisit only if the two-list UX
  proves confusing.
- Codec choice for iPhone over cellular (HEVC + adaptive bitrate) vs LAN-only H.264 first.
- Can Playwright MCP's headed Chromium and the agent's CGEvent input coexist without the
  human's cursor fighting the agent's? Probably needs an "agent has the wheel" indicator in
  Connect and input arbitration in the daemon.
- OpenAB Remote (iPhone) is a stated target in #1544; is it in this requirement's first cut,
  or Mac-only first?
