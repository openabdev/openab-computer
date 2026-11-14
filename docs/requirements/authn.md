# Design — bearer-token authn as defence-in-depth for the MCP endpoint

**Renamed** from `oab-instance-mcp` to `oab-computer` in 0.12.0 (the product name is OpenAB Computer). This is a dated record: paths, unit, label and artifact names below are the 0.8–0.11 names (`oab-instance-mcp`, `dev.openab.instance-mcp`, `oab-pw-mcp.service`).

> Recorded 2026-09-23. Implements the "two callers, two trust levels, one daemon"
> constraint from [`connect-closed-loop.md`](connect-closed-loop.md), first slice: add a
> shared bearer token so a leaked tailnet credential alone cannot reach the agent.

## Problem

`oab-instance-mcp` runs on macmini bound to loopback; `tailscale serve --https=8444` terminates
TLS and injects `Tailscale-User-Login`, and `AuthPolicy` checks it against
`--allow-login <owner-login>`. Today that is the *only* control (no `--token` in the
deployed LaunchAgent). OpenAB Connect's `MacAgentClient` connects straight to
`https://macmini.<tailnet>.ts.net:8444/mcp` and sends **no** `Authorization` header — its own
comment states "nothing here is a secret — auth is the caller's Tailscale identity".

### Threat: a leaked tailnet credential is sufficient

`Tailscale-User-Login` reflects the **login identity of the connecting node**, authenticated by the
Tailscale control plane and un-spoofable by the HTTP client (`tailscale serve` overwrites any
client-supplied header — verified). But that identity is only as strong as tailnet
enrolment:

- An **ephemeral auth key** (`tskey-auth-…`) that leaks lets anyone `tailscale up --authkey`
  a node into the tailnet.
- If that key is **user-owned** (issued under the owner's login), the enrolled node presents
  `Tailscale-User-Login: <owner-login>`, passes `--allow-login`, and reaches the full
  `exec` shell. (A **tagged** key — `tag:…` — has no user login and would be denied, but we
  cannot assume every enrolment path is tagged.)

So the entire trust of the MCP endpoint currently rests on "the tailnet key never leaks and
node identity is always what we expect". That is a single point of failure for a full shell.

## Decision

Add a **shared bearer token** as a second, independent factor, `AND`-combined with the
existing Tailscale login check. `AuthPolicy.decide` already implements AND semantics (both a
configured token and a configured login must pass); we simply start configuring both.

- Normal operation: request must (a) arrive with an allow-listed `Tailscale-User-Login`
  **and** (b) carry `Authorization: Bearer <token>`.
- Leaked tailnet key: the attacker's node may pass (a) but not (b) → `401`.
- Leaked token but no tailnet access: cannot even reach `:8444` (not on the tailnet) → also safe.

Two doors, failure-independent. The token is our own secret (rotatable at will, per-caller,
attributable in logs), unlike a tailnet key whose revocation needs the admin console.

### Non-goals for this slice

- **Per-caller capability sets** (Connect's screen-attach must not grant `exec`) — required by
  `connect-closed-loop.md` but deferred until the screen-attach endpoint exists (phase 2b/3).
  This slice ships a *single* shared token; the structure is noted below so the next slice is
  additive, not a rewrite.
- **mTLS / short-lived certs** — heavier than warranted for a single-operator mesh.
- **SSH-tunnel-based auth** — rejected: the sandbox agent's connectivity model is tsnet on the
  tailnet (per `connect-closed-loop.md`), not SSH, and giving a sandbox an SSH key to macmini
  would grant *more* than the MCP endpoint, not less.

## Token lifecycle

**Generation & storage (agent side, macmini).** `deploy.sh` generates a random token on first
deploy if one does not already exist, stores it at `~/.config/oab-instance-mcp/token` (mode 600),
and passes `--token-file` to the LaunchAgent (alongside the existing `--allow-login`). Re-deploys
reuse the existing file so the token is stable across upgrades (like the TCC grants). Rotation =
delete the file and re-deploy, then update clients.

```
token=$(openssl rand -hex 32)          # 256-bit
umask 077; printf '%s' "$token" > ~/.config/oab-instance-mcp/token
# LaunchAgent args: … --allow-login <email> --token-file ~/.config/oab-instance-mcp/token
```

**Distribution.** The menu bar gains a "Copy Token" action (and shows a masked form) so a human
at the Mac can copy the token and paste it into Connect. The token is never logged or shown in
full in `agent.log`.

**Storage (client side, Connect).** `ScreenProfile` is persisted in `UserDefaults`, which is
**not** an appropriate place for a secret. The token is therefore stored in the **login
Keychain**, keyed by the profile name, and only a boolean "has token" travels in the Codable
profile. `MacAgentClient` sets `Authorization: Bearer <token>` when a token exists for the
profile.

## Changes

### oab-instance-mcp

- `scripts/deploy.sh`: generate/reuse `~/.config/oab-instance-mcp/token`, add `--token-file`.
- `StatusItemController`: read the token file; add a masked display line + "Copy Token" action.
- `AuthPolicy`: no code change (AND semantics already present); covered by existing tests.
- `README.md`: document that the deployed agent now requires a bearer token.

### OpenAB Connect (client side)

- `ScreenProfile`: add non-persisted `token` + a Keychain helper (`ScreenTokenStore`) keyed by
  profile name; `ScreenStore.save/remove` write/delete the Keychain item.
- `SidebarScreens.presentScreenSheet`: add a "Token" field (optional; blank = no token, for
  `--insecure-local` loopback use).
- `MacAgentClient.post`: send `Authorization: Bearer <token>` when present; extend the 401
  message to mention a missing/incorrect token as a cause.

## Verification

- Unit: `AuthPolicy` AND semantics already tested (token required even for an allow-listed
  login; wrong token denied).
- Live on macmini: with the agent deployed with `--token-file`,
  - a request with correct login header but **no** `Authorization` → `401`;
  - the same request **with** `Authorization: Bearer <token>` → `200`;
  - Connect can watch the screen only after its profile's token is set.

## Matching rules (as implemented)

Pinned by `conformance/auth_vectors.json`; both backends pass it (Refs #79).

- The login compare is case-insensitive: the allowlist and the `Tailscale-User-Login` header are
  both lowercased (`AuthPolicy.swift:18-20,46`; `auth.rs:33,52,104`). The allowed principal is
  the lowercased login.
- The `Bearer` scheme is case-insensitive. The token after the scheme and its space is compared byte for byte, in
  constant time, so a case change is a bad token.
- The HTTP parser strips whitespace around every header value before the policy runs (RFC 9110
  §5.5; `HTTP.swift`, `http.rs`), so a trailing space on the wire is accepted. `decide()` itself
  does not trim: a value that still carries a trailing space, or an extra space after `Bearer`,
  is a bad token. The vectors are `decide()`-level, so their header strings are post-parse values.
- Deny reasons are logged, never sent: the caller gets `401` and nothing that says why. The
  reason strings are listed in `docs/parity-checklist.md` §4.
