# ADR: Browser tools in tiers — Playwright first, Apple Events as the fallback

- **Status:** Accepted
- **Issue:** [#118](https://github.com/openabdev/openab-computer/issues/118)
- **Requirement:** [`docs/requirements/browser-tiers.md`](../requirements/browser-tiers.md) (tool-to-tier table, wizard states, install flows, test plan)
- **Related:** [`reverse-attach.md`](reverse-attach.md) (profiles and the shell-equivalence of `owner`), [`docs/tool-profiles.md`](../tool-profiles.md), [#119](https://github.com/openabdev/openab-computer/issues/119) (Linux installer, design later)

## Context

OpenAB Computer exposes 32 `browser_*` tools. Today they exist only as a relay to an
externally started Playwright MCP (`--upstream browser=http://127.0.0.1:8794/mcp`). Making that
work means installing Node, `@playwright/mcp` and a Chromium by hand, which is a large
overhead for a normal Mac user. Issue #118 asked for a cheaper path.

Constraints that shaped the answer:

1. **No Chrome extension.** An extension needs a store listing or developer-mode install, and
   it is a second trust root in the user's browser. It is out of the design.
2. **Playwright is the full-fidelity backend** but costs a few hundred MB and a network
   download. That cost must be offered, not forced, and the setup must still finish offline.
3. **Chrome and Safari already accept Apple Events** "execute JavaScript" once the user allows
   it, with no download. This drives the user's *real*, signed-in browser, which is a larger
   privilege than a separate profile.
4. **A Playwright listener is not private.** Any process of any user on the Mac can reach a
   loopback port, and Playwright MCP 0.0.82 has no bearer check in anything this repository
   configures. The same server serves `browser_run_code_unsafe` (arbitrary Node code).
5. `owner` is already shell-equivalent (see [`reverse-attach.md`](reverse-attach.md), decision
   4), and `observe` sees no `browser_*` tool. That rule does not change.

## Decision

`browser_*` tools get one internal interface, `BrowserBackend`, and a `BrowserRouter` that
selects **one active backend per connection**. No new tool names are added: every name is one
of the existing 32, so profile fixtures and the Linux conformance tests stay valid.

1. **Tier P, Playwright, is preferred** whenever it is ready. `@playwright/mcp` and a pinned
   Chromium are installed from the setup wizard; nothing is bundled in the app.
2. **Tier A, Apple Events plus Accessibility, is the fallback** and the choice when a task needs
   the user's real logged-in browser. Chrome and Safari only. It needs no download; all human
   consent (the browser's "Allow JavaScript from Apple Events" switch and the macOS Automation
   prompt) is collected once in the wizard, then calls are unattended.
3. **Tier C, Chrome remote debugging (CDP), is attended only.** The interface reserves a slot,
   but it is not built, never chosen automatically, and never started unattended.
4. **The wizard's Playwright install step is pre-checked with an opt-out.** A normal install
   therefore downloads a few hundred MB and needs network. The wizard still completes offline
   or on any failure, with Playwright not installed and a retry from the menu.
5. **Managed Playwright runs over stdio as a child of the app.** It is designed to open no listening socket, which is a release blocker
   checked by V12 in the requirements.
   Port 8794 stays loopback-only and is used only by an external Playwright (operator
   `--upstream browser=`, the PoC, the Linux hands node).
6. **The download pins live in a manifest embedded in the signed app.** The app never fetches
   pins; new pins ship only with a new app release.
7. **The app never adds or strips `com.apple.quarantine`.** It verifies digests and Node's
   signature and stops with a clear error if macOS refuses to run a file.
8. **Sites are signed in once, in the Playwright headed window.** The persistent profile keeps
   the session. There is no cookie import from Chrome or Safari. Some sites
   block automated browsers, so a sign-in there may fail or be challenged.

### Router behaviour

The preference is `auto` (default), `appleEvents` or `playwright`, stored per user and
overridable per connection with the `OAB-Browser-Backend` request header. Under `auto`,
Playwright is chosen when ready, else Apple Events.

- **No silent fallback to a named backend.** If the header or menu pin names a backend that is
  not ready, `tools/list` shows no `browser_*` names and a call returns a setup message naming
  that backend.
- **Identity guard.** Tier A and Tier P are different identities (the real signed-in sessions
  versus the Playwright profile). Under `auto`, the router remembers the backend and time of
  the last browser call, and within 30 minutes it does not switch to the other backend by
  itself, in either direction. If the last backend is no longer ready, the caller gets a
  message saying the other tier is ready but is not used automatically mid-task. After 30
  minutes without a browser call, or when a header or menu pin names a backend, the choice is
  recomputed. The window is a design value and can change without changing any interface.
- **No retry on the other backend.** A call is never repeated on a different tier, because that
  would move the caller between the real browser and the Playwright profile.
- Every browser result carries `structuredContent.backend`.

### Decided questions

The following thirteen questions were put to the owner. Each entry gives the chosen option, the
reason, and the options not taken.

#### Q1. Which tier serves a call when both are ready?

**Chosen: Playwright first.** Apple Events is the fallback and the choice for the user's real
signed-in browser, reached with the `OAB-Browser-Backend: appleEvents` header or the menu pin,
with the 30-minute identity guard above.

Rationale: Tier A acts in the user's real sessions (banking, mail, admin consoles). Tier P uses
a separate profile that holds only what the user signed in to. Defaulting to the smaller
identity is the safer default, and the real browser is an explicit choice.

Rejected:

- *One active backend, `auto` prefers Apple Events.* Defaults to the larger privilege.
- *Per-tool composite* (each tool from A when A supports it, else from P). Moves one
  conversation between two identities tool by tool.

#### Q2. May the wizard turn on Chrome's "Allow JavaScript from Apple Events" through Accessibility?

**Chosen: offer it with explicit per-press consent.** A **Turn it on for me** button next to the
manual steps. An alert names the exact change, it is never automatic, consent is never stored,
and the manual steps remain the fallback if the menu item is not found.

Rationale: it is a security setting in the user's browser, so it needs a deliberate human act.
The app already holds Accessibility, and a button reduces the chance of a mistake in a
localized menu.

Rejected:

- *Manual steps only in v1.* Safe, but pushes a fiddly step onto every user before the assisted
  flip is known to fail.
- *Never.* The app would not press another app's security-setting menu item at all.

#### Q3. Which Chromium does the Playwright install use?

**Chosen: the pinned Playwright Chromium**, downloaded, digest-pinned and separate from the
user's Chrome. If macOS refuses to run it, the user's installed Chrome is offered as a fallback
only when present (Q5). That fallback is not version-pinned or digest-checked.

Rationale: the engine matches the pinned `playwright-core` revision and its version is ours to
pin, so tool behaviour is reproducible.

Rejected:

- *Use the user's installed Google Chrome only.* Smaller, but needs Chrome and its version is
  not pinned by us.
- *Let the user choose in the install sheet.* Builds and tests both paths for little gain.

#### Q4. What is the trust root for the download pins?

**Chosen: a manifest embedded in the signed app.** The npm lockfile and digests are generated
by a release check and checked by a maintainer like a lockfile diff. The app signature covers
them. New pins ship only with a new app release.

Rationale: no key custody, no fetch at install time, and the pins are as trustworthy as the app.

Rejected:

- *A manifest fetched at install time and verified with a detached signature from a
  project-held key.* Allows pin updates without a release, but adds key custody and a fetch.
- *Upstream's own tooling* (`npm install`, `playwright install`, trusting the registry and CDN
  as they are). No pins of our own, so no integrity check before extraction.

#### Q5. What happens if downloads carry `com.apple.quarantine`, or Gatekeeper refuses them?

**Chosen: never strip and never add the attribute.** Verify digests (and Node's signature). If
macOS refuses to run a file, stop with a clear error, and offer the user's installed Chrome if
present (not version-pinned or digest-checked).

Rationale: stripping quarantine to make unsigned binaries run overrides a macOS protection on
the strength of our own check. Adding it deliberately would only make the unnotarized Chromium
unusable.

Rejected:

- *Strip quarantine after our own digest check.* Defeats Gatekeeper for pinned but unsigned
  binaries.
- *Add quarantine to everything we download.* Relies on Gatekeeper's assessment, which blocks
  an unnotarized Chromium.

#### Q6. Which browsers does Tier A support in v1?

**Chosen: Chrome and Safari only.**

Rationale: Brave and other Chromium browsers share Chrome's scripting design, but the setting
name, menu text and bundle ids were not verified.

Rejected:

- *Chrome, Safari, plus Brave and Edge* after each is verified like Chrome. Deferred, not
  refused.
- *Any Chromium-family browser that answers the same script,* detected at runtime. Best effort
  on a security-sensitive path.

#### Q7. How is the managed Playwright kept away from other local users, processes and web pages?

**Chosen: stdio, no listener.** Managed Playwright runs as a child of the app over its stdin and
stdout. Port 8794 stays loopback-only for the external path only. Release is blocked if the
listener check (V12) finds any listener on the pinned version.

Rationale: a listener on 8794 is reachable by every process of every user on the Mac. With no
bearer check and `browser_run_code_unsafe` served, another local user could bypass the
authenticated `:8795` facade and run Node code as the OpenAB Computer user. Web pages may also
reach it (`--allowed-hosts` stops DNS rebinding only). Shipping that as the managed default
would be an unauthenticated code-execution path, so the design departs from the literal
"8794" wording for the managed case only.

Rejected:

- *An HTTP listener behind an authenticating proxy in the app, Playwright on a random private
  loopback port.* The private port is still a listener another process can call directly.
  TCP loopback alone cannot prevent that, so it is weaker than stdio.
- *Keep Playwright on `127.0.0.1:8794` and document the residual risk.* Must not ship as the
  default while any other local user can reach `browser_run_code_unsafe`. Acceptable only with
  explicit sign-off for single-user Macs.

#### Q8. Does Tier A offer the viewport-coordinate mouse tools?

**Chosen: no.** `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`,
`browser_mouse_down` and `browser_mouse_up` are not listed in Tier A. The error points at
`screenshot` plus `mouse`. `browser_drag` is folded into this decision.

Rationale: mapping viewport coordinates to screen points depends on toolbar height, side
panels, zoom and display scale. The existing `mouse` tool already works in screen points.

Rejected:

- *Offer them with a JavaScript-derived mapping and an accuracy caveat.*
- *Offer them but require screen-point coordinates from the caller.* Changes their meaning
  versus Playwright.

#### Q9. Does Tier A need a per-site restriction in v1?

**Chosen: none in v1.** The wizard consent text and `docs/tool-profiles.md` state the exposure.

Rationale: `owner` is already shell-equivalent, and a site list adds policy and UI before there
is usage evidence. The exposure is stated plainly instead.

Rejected:

- *A user-editable deny list, empty by default,* checked on `navigate`, new tab and before every
  action.
- *An allow list only,* so Tier A refuses every site until the user adds it.

#### Q10. Which browser and tab does a Tier A call act on by default?

**Chosen: one target browser chosen in the wizard,** defaulting to the system default browser if
it is ready, acting on the front window's active tab or the tab chosen by `browser_tabs select`.

Rationale: acting on the wrong browser or tab means acting in the wrong session. A single
target makes the identity predictable.

Rejected:

- *Whichever supported browser is frontmost at call time.* The target can change under the
  caller.
- *Require an explicit tab handle on every call.* Safest, but breaks Playwright-shaped callers.

#### Q11. How is a stale Playwright install handled?

**Chosen: prompt on update, never silent.** An app release that carries new pins shows "update
available" in the menu and wizard. The update runs side by side with a health check and keeps
the old version on failure. The menu warns when the installed Chromium is older than the
manifest allows.

Rationale: a pinned Chromium stops receiving fixes while it drives arbitrary sites with a
persistent profile, so staleness must be visible. A silent update could replace a working
install with a broken one.

Rejected:

- *Update automatically at launch* when the manifest is newer.
- *Manual only:* remove and reinstall, no prompts.

#### Q12. May the app use a Playwright MCP it did not start (an existing listener on 8794)?

**Chosen: only with explicit trust.** An external listener is used only when the operator passed
`--upstream browser=URL`, or the user pressed **Use it** on a prompt naming the process and
user, and only while the listener owner's uid equals the daemon's uid. It fails closed if the
owner cannot be determined. Managed stdio mode has no listener to adopt.

Rationale: any local process can bind 8794 first, copy Playwright's `initialize` answer, then
receive `browser_fill_form` values and `browser_evaluate` source while forging results.
Self-identification over the protocol proves nothing. The PoC LaunchAgent and the Linux hands
node legitimately use an externally started Playwright on that port, so the path stays.

Rejected:

- *Never adopt an external listener in the app-managed path* (only the operator flag reaches
  one).
- *Adopt automatically* if it answers `initialize` as Playwright MCP.

#### Q13. Does Tier A offer `browser_take_screenshot`?

**Chosen: no.** The error points at `screenshot` and the Accessibility tools. Tier P serves it.

Rationale: a window capture through the OS includes whatever overlaps the window and needs
Screen Recording. The existing `screenshot` tool already captures the screen.

Rejected:

- *An OS window capture of the target browser's front window,* with Screen Recording required
  and overlap documented.
- *A DOM-derived rendering* (for example an SVG `foreignObject` snapshot). Not pixel-accurate,
  and it fails on cross-origin images and many pages.

## Security and threat model summary

Assets: the user's signed-in sessions and cookies, page content, values typed through
`browser_fill_form` and `browser_type`, the bearer token, and secrets in the page.

| Threat | Control |
|---|---|
| A token-holding `owner` caller reads secrets from the page | Accepted by design: `owner` is shell-equivalent. Consent text and docs say so. `observe` has no browser tools. Per-site limits are not in v1 (Q9). |
| Secrets in logs | The code never logs arguments, results, URLs, titles, page text, or `osascript` stderr. New `browser:` log lines carry only an event name, an error class and a number. The agent log is world-readable (mode 0644), so the rule is enforced by a test that sends canary secrets through every tool. |
| Secrets echoed back or left on disk | Snapshots mask password-class values and omit hidden inputs. `browser_fill_form` and `browser_type` replies never contain values. Apple Events payload files are mode 0600, created exclusively in a 0700 directory, removed on every path, and never passed in `argv`. |
| Script injection into AppleScript or JavaScript | One static AppleScript template per browser, strict argument patterns, an argument array with no shell, and caller data embedded only as JSON inside a string literal. A hostile-corpus test covers the encoding. |
| A hostile page attacks the injected library | Chrome runs it in an isolated world. Safari runs in the page world, so Safari output is treated as page-influenced. Snapshots mark page content as untrusted data. |
| Prompt injection leading the agent to abuse a real session | Not preventable here. Mitigated by `owner` only, the untrusted-data marker, and the dedicated-computer advice in `docs/tool-profiles.md`. Stated as a residual risk. |
| A stale queued action after a blocking dialog | Every payload carries an absolute deadline; the library refuses to act after it. |
| `javascript:`, `data:`, `file:` navigation | Only `http`, `https` and `about:blank` are accepted in Tier A. |
| A local process or web page reaching Playwright | Managed: stdio, nothing to reach, release blocked on any listener (V12). External: loopback is reachable by every local process, so it is used only on an explicit flag or consent and the app does not call it private. For an external 8794, whether Playwright refuses a cross-origin request and whether Chrome's Private Network Access blocks it is not verified (V8b). |
| Impersonating the external upstream | Never trusted by self-identification. Used only after explicit trust and while the listener owner's uid equals ours (Q12). A same-uid impostor is outside this control, because same-uid code can already act as the user. |
| An upstream error or redirect that leaks data or moves a request | The external adapter follows no redirects and returns fixed error classes with no upstream text. Managed stderr is kept only in a bounded in-memory buffer, never persisted or returned. |
| A pre-checked download most users accept unread | The text names sources, size and verification and never calls the result safe. Every artifact is checked against the embedded manifest before use. Unchecking is always available, and **Continue without** appears after a failure. |
| Archive extraction escaping the staging directory | The app validates the whole archive before writing anything, then extracts relative to a directory descriptor without following links. |
| Secrets in the Playwright profile | The profile is a 0700 directory under the user's account, never copied or logged, excluded from backup, and deleted by **Remove Playwright…**. There is no encryption beyond Chromium's own. |
| Environment leakage into children | `osascript` and Playwright get an allow-list environment; the bearer token and cloud or `GH_*` style variables are not passed. |

Residual trust in the download, stated plainly: this is integrity against a pinned manifest,
not proof of safety. The manifest is as trustworthy as the maintainers' release step (first
fetch is trust-on-first-use). `npm ci --ignore-scripts` stops install scripts, but the packages
still run as the user when Playwright MCP starts. Node and Chromium are third-party builds, and
a pinned Chromium goes stale (Q11). `browser_run_code_unsafe` is arbitrary Node code in that
process, and it is `owner` only like `exec`.

For Chrome, "Allow JavaScript from Apple Events" is a per-profile switch. Once it is on, every
app already allowed to control Chrome gains script access to all signed-in pages, and removing
browser tools from this app does not turn it off. The wizard says so; `docs/tool-profiles.md` is to be updated to say so (see the requirements, R9).

## Consequences

**Gained**

- A working browser path without a Node and Chromium install, via Tier A on Chrome or Safari.
- The full 32-tool surface through Tier P, installed with one pre-checked step.
- No listening socket for managed Playwright (release blocked unless V12 confirms it), so no unauthenticated local code-execution path.
- Download integrity checked against values in the signed app, before extraction.
- Existing profile fixtures, `observe` hiding and Linux conformance tests stay valid.

**Paid**

- Two backends, a router, a wizard page, a downloader, a safe archive extractor and a stdio MCP
  client are new code.
- Tier A is a larger privilege than the old text promised: it acts in the user's real
  signed-in browser. `docs/tool-profiles.md`, the README and the wizard copy must say so.
- Tier A is limited: 6 tools match Playwright's contract, 10 are served with documented
  differences, and 16 are not served (see the requirement document). Its clicks and typing are
  untrusted events, and it works on the main frame only.
- The pre-checked install means most users download a few hundred MB and trust the pinned
  manifest. A pinned Chromium needs update prompts.
- Some behaviour is unverified until a check on a signed build: which identity the Automation
  prompt names, the exact consent and error texts of Chrome and Safari, whether Chrome's
  isolated world keeps globals between calls, and the quarantine behaviour of our downloader.
  The requirement document lists these as checks V1 to V14.
- `--upstream browser=URL` no longer produces a generic upstream. It is handed to the Playwright
  backend as an external Playwright and must be a literal loopback address. This is a
  deliberate break.

## Non-goals

- A Chrome extension.
- Building Tier C (CDP).
- Brave, Edge, Arc and other Chromium browsers (Q6).
- Per-site allow or deny lists (Q9).
- Cookie import from Chrome or Safari into the Playwright profile.
- Authentication on the external 8794 listener.
- Adopting an external Playwright without consent (Q12).
- Bundling Node or Chromium in the app.
- `observe`-profile browser tools, and any new tool name.
- The Linux installer, tracked in [#119](https://github.com/openabdev/openab-computer/issues/119)
  and designed later. The Linux hands node keeps today's browser path.
