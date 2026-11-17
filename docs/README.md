# Documentation index

Start with the [project README](../README.md): what OpenAB Computer is, quick start, tools, auth, ports
and the install and upgrade sections. This page lists every document under `docs/` with one line each
and its status. Status is as of v0.12.0, except the Linux browser tier rows, which are as of `main` after it.

## Guides

| Document | What it covers | Status |
|---|---|---|
| [Upgrading from 0.11 or earlier](upgrade-0.12.md) | Step-by-step move from `oab-instance-mcp` to `oab-computer` on macOS and Linux, with backup and rollback | Current |
| [Browser tools](browser-tools.md) | The 32 `browser_*` tools: managed and external Playwright on macOS and Linux | Current |
| [Linux hands node setup](linux-setup.md) | Install and operate a Linux node with `install-linux.sh` | Current |
| [Tool profiles](tool-profiles.md) | Which tools `owner` and `observe` see, per platform | Current |
| [UI tools](ui-tools.md) | `ui_snapshot` and `ui_action` (macOS only) | Current |
| [Operator notes and gotchas](operators.md) | Lessons from deploys and operation | Current |
| [Releasing](releasing.md) | Artifacts, signing, notarization, Playwright pins, cutting a release | Current (maintainers) |

## Design records

ADRs record a decision and its status. Requirements documents hold the detailed design behind them.
Several carry the pre-0.12 names (`oab-instance-mcp`) because they are dated records.

| Document | What it covers | Status |
|---|---|---|
| [ADR: Reverse attach](adr/reverse-attach.md) | The Mac dials the sandbox | Accepted, shipped in every release (0.6.0 and later) |
| [Requirement: Reverse attach](requirements/reverse-attach.md) | Full design, threat model, phasing | Dated record, implemented |
| [ADR: Linux-first Rust port](adr/linux-rust-port.md) | One core, per-OS backends | Accepted, Linux tarballs shipped since 0.6.5 |
| [Parity checklist](parity-checklist.md) | What the conformance suite does not cover yet, for the Swift retirement gate | Tracking |
| [ADR: Browser tools in tiers](adr/browser-tiers.md) | Playwright first, Apple Events as fallback | Accepted, partly built (Playwright tier only) |
| [Requirement: Browser tiers](requirements/browser-tiers.md) | Tool-to-tier table, wizard states, install flows, tests | Accepted, partly built |
| [ADR: Linux managed Playwright tier](adr/linux-browser-tier.md) | Managed browser on Linux | Accepted; L0 to L3 implemented (L4 hardening, L5 release and L6 supervisor pending) |
| [Requirement: Linux browser tier](requirements/linux-browser-tier.md) | Requirements, cutover runbook, PR split | Accepted; L0 to L3 implemented |
| [ADR: Sandbox adapter](adr/sandbox-adapter.md) | Disposable sandboxes for an agent's toolchain, so a bot does not hold raw host access | Proposed |
| [Requirement: Bearer-token authn](requirements/authn.md) | Shared bearer token as defence in depth | Dated record (2026-09-23) |
| [Requirement: OpenAB Connect closed loop](requirements/connect-closed-loop.md) | An agent operates the Mac while a human watches | Dated record, not scheduled |

## Archived

| Document | What it covers | Status |
|---|---|---|
| [Oracle Cloud reference architecture](oracle-cloud-refarch.md) | Hand-installed 0.8.0 node on an Oracle Cloud VM | Archived: commands and asset names no longer work for 0.12.0 |

## Elsewhere in the repository

- [`poc/pw-mcp/README.md`](../poc/pw-mcp/README.md): the optional external Playwright agent for macOS.
- [`poc/reverse-attach-linux/README.md`](../poc/reverse-attach-linux/README.md): the Linux node source
  and its history.
- [`conformance/README.md`](../conformance/README.md): shared test vectors both implementations pass.
- `docs/images/`: the overview diagram used by the README.
