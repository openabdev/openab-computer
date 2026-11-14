# Requirement — browser tools in tiers (Playwright first, Apple Events fallback)

> Implements the decision in [`docs/adr/browser-tiers.md`](../adr/browser-tiers.md) for issue
> [#118](https://github.com/openabdev/openab-computer/issues/118). Linux is covered only by the
> parity statement at the end; its installer is issue
> [#119](https://github.com/openabdev/openab-computer/issues/119).

## Statement

The 32 `browser_*` tools must work on a Mac without a hand-built Node and Chromium setup, and
without a Chrome extension. A `BrowserRouter` serves them from one active backend per
connection:

- **Tier P, Playwright** (preferred): `@playwright/mcp` and a pinned Chromium installed from
  the wizard, run as a child of the app over stdio.
- **Tier A, Apple Events** (fallback, or the choice for the user's real signed-in browser):
  Chrome and Safari driven by Apple Events "execute JavaScript", with the Accessibility tools
  beside it. No download.
- **Tier C, CDP**: reserved in the interface, attended only, not built.

Technology: Swift 5.10, SwiftPM, macOS 14+, AppKit for the wizard, XCTest, JavaScriptCore and
WKWebView in tests. The injected DOM library is plain JavaScript embedded as a Swift string
constant. No new third-party Swift dependency.

## Requirements

### R1. Interface and profiles

- R1.1 One `BrowserBackend` interface (`status()` cheap and never prompting, `tools()`,
  `call()`), with `appleEvents` and `playwright` implementations. `MCPServer` gets an optional
  `browser` router next to `upstreams`. `scoped(to:)` and `mappingTools(_:)` must forward it.
- R1.2 `tools/list` shows exactly the `browser_*` names the active backend can serve now.
  `tools/call` resolves local tools, then generic upstreams, then the router.
- R1.3 Every `browser_*` tool is `owner` only. `observe` sees none and learns nothing: a hidden
  name is the unchanged unknown-tool error.
- R1.4 No new tool names. `BrowserToolCatalog.allNames` lists the 32 real names. The profile
  vector file also holds one synthetic fixture name that checks unknown `browser_*` names stay
  `owner` only. Counts in this document use the 32.
- R1.5 On macOS, a tool a future Playwright adds is filtered out until the catalog, the vector
  file and the tests are updated together. This differs from today's documented owner behaviour,
  where unknown upstream browser tools pass through, and from Linux, which keeps passing
  everything through; R9 and the Linux parity section record the change.
- R1.6 Every result carries `structuredContent.backend`. `sys_info` reports the active backend,
  per-browser state and, for Tier P, whether it is managed or external (no URLs).
- R1.7 `--upstream browser=URL` is handed to the Playwright backend as an external Playwright.
  Any other `--upstream name=URL` is unchanged.

### R2. Router

Preference `auto` (default), `appleEvents` or `playwright`, stored per user. The request header
`OAB-Browser-Backend` (values `auto`, `appleEvents`, `playwright`; anything else is ignored)
overrides it for that connection only and stores nothing.

| Preference | Tier A ready | Tier P ready | Active |
|---|---|---|---|
| auto | any | yes | P, subject to the identity guard |
| auto | yes | no | A, subject to the identity guard |
| auto | no | no | none |
| appleEvents | yes | any | A |
| appleEvents | no | any | none (no silent switch) |
| playwright | any | yes | P |
| playwright | any | no | none |

"Tier A ready" means the target browser's last wizard probe succeeded and no later call
reported setup loss. "Tier P ready" means installed (or external) and an `initialize` health
check within 2 s succeeded in the last 30 s.

- R2.1 **Identity guard.** Under `auto`, within 30 minutes of the last browser call the router
  does not switch to the other backend by itself, in either direction. If the last backend is no
  longer ready, `tools/list` has no `browser_*` names and a call returns a message that says the
  other tier is ready but is not used automatically mid-task, and how to select it. After 30
  minutes without a call, or when a header or menu pin names a backend, the choice is recomputed
  from the table. A finished Playwright install does not move a running Tier A conversation, and
  Tier A setup loss does not move a Playwright one. The clock is injected in tests.
- R2.2 **No fallback to another backend.** A call is never retried on the other tier.
- R2.3 A real tool name the active backend cannot serve returns a normal tool error
  (`isError: true`, not a JSON-RPC error) saying how to install Playwright or select it.
- R2.4 With no ready backend, `tools/list` has no `browser_*` names and a call returns
  "Browser tools are not set up. Open OpenAB Computer, then Browser tools."
- R2.5 Setup-loss errors (Automation denied, the JavaScript switch off, the managed Playwright
  failing for good) mark the backend `needsSetup` or `unavailable`. "Browser not running" fails
  that call only (`Chrome is not running. Open it and retry.`) and does not change selection.
- R2.6 `listChanged` stays `false`; clients re-list.
- R2.7 Tier C is never selected by `auto`.

### R3. Tool-to-tier mapping

Legend: **Full** is the same observable contract as Playwright. **Limited** is served with a
documented difference stated in the tool description. **No** means not listed in Tier A, and a
call gets the "not available with this tier" error.

| Tool | Tier A (Apple Events + AX/OS) | Tier P (Playwright) | Note for Tier A |
|---|---|---|---|
| `browser_navigate` | Full | Full | `set URL`; `http`, `https`, `about:blank` only; waits for `readyState` |
| `browser_navigate_back` | Full | Full | `history.back()` then wait |
| `browser_snapshot` | Limited | Full | own serializer, not Playwright's format |
| `browser_find` | Limited | Full | same traversal as the snapshot |
| `browser_click` | Limited | Full | untrusted `el.click()`; left button, single or double only |
| `browser_type` | Limited | Full | value set plus events; no real keystrokes; `slowly` refused |
| `browser_fill_form` | Full | Full | native setter plus `input` and `change` |
| `browser_press_key` | Limited | Full | OS keystroke to the frontmost browser; brings the browser to the front |
| `browser_hover` | Limited | Full | dispatched mouse events only, no `:hover` CSS |
| `browser_select_option` | Full | Full | sets `value`, dispatches `change` |
| `browser_wait_for` | Full | Full | `time`, `text`, `textGone`; polling, max 30 s per call |
| `browser_tabs` | Limited | Full | list, new, close, select on the target browser |
| `browser_take_screenshot` | No | Full | error points at `screenshot` and the Accessibility tools |
| `browser_console_messages` | No | Full | needs CDP |
| `browser_resize` | Limited | Full | window bounds, not viewport |
| `browser_evaluate` | Limited | Full | isolated world in Chrome, page world in Safari, async by polling |
| `browser_run_code_unsafe` | No | Full | needs a Playwright `page` object |
| `browser_file_upload` | No | Full | needs CDP |
| `browser_drop` | No | Full | needs CDP |
| `browser_pdf_save` | No | Full | needs CDP |
| `browser_network_requests` | No | Full | needs CDP |
| `browser_network_request` | No | Full | needs CDP |
| `browser_handle_dialog` | No | Full | needs CDP; the Tier A timeout error points at `ui_snapshot` and `ui_action` |
| `browser_emulate_media` | No | Full | needs CDP |
| `browser_close` | Full | Full | closes the tab; never quits the user's browser |
| `browser_drag` | No | Full | needs trusted pointer events (see [ADR Q8](../adr/browser-tiers.md#q8-does-tier-a-offer-the-viewport-coordinate-mouse-tools)) |
| `browser_mouse_move_xy` | No | Full | error points at `screenshot` plus `mouse` with screen points |
| `browser_mouse_click_xy` | No | Full | same |
| `browser_mouse_drag_xy` | No | Full | same |
| `browser_mouse_down` | No | Full | same |
| `browser_mouse_up` | No | Full | same |
| `browser_mouse_wheel` | Limited | Full | `window.scrollBy` |

Tier A: 6 Full, 10 Limited, 16 No (32). Tier P: all 32 as the pinned upstream lists them.

Tier A schemas are static. A fixture captured from the pinned `@playwright/mcp` `tools/list`
must contain, for every Tier A tool, a superset of its property names and `required` set, so
callers written for Playwright work unchanged. Unsupported options (for example
`button: "right"`) are refused with a clear error, not ignored.

### R4. Tier A execution

- R4.1 A call validates arguments, resolves the target (browser, window, tab), builds a payload,
  writes it to a 0600 temporary file, and spawns `/usr/bin/osascript` with a static script.
  stdout is read to a hard cap, parsed as an envelope, mapped to a tool result, and the file is
  deleted. The executor sits behind a protocol so a test fake, or an in-process fallback, can
  replace `osascript`.
- R4.2 `osascript` runs through `Process` with an argument array, never a shell, with a minimal
  environment (`HOME`, `TMPDIR`, `LANG`, `PATH=/usr/bin:/bin`) and no inherited secrets. It is
  killed at the deadline.
- R4.3 The AppleScript is a fixed template per browser, compiled in, containing no caller bytes.
  The browser comes from a closed enum of bundle ids. The template refuses to launch a browser
  that is not running. `osascript` receives only two decimal ids, a generated absolute path and a
  decimal timeout, each checked against a strict pattern and never starting with `-`.
- R4.4 Caller data reaches the page only as JSON inside a JavaScript string literal (encoded
  twice; U+2028, U+2029 and `</` escaped). The one exception is the `browser_evaluate` function,
  which is code by design and sits in its own slot; a syntax error in it yields "no envelope".
- R4.5 Temporary files live in `~/Library/Application Support/oab-computer/run/ae/` (mode 0700,
  verified at startup, excluded from backup), created with `O_CREAT | O_EXCL | O_NOFOLLOW`
  mode 0600, removed on success, error, timeout and cancel, and swept at startup when older than
  10 minutes. Payloads are never passed in `argv` and never logged.
- R4.6 The result envelope is a JSON string, `{"ok":true,"v":…,"t":false}` or
  `{"ok":false,"c":"<code>","m":"<short message>"}`.

| Item | Rule |
|---|---|
| JS-side result cap | 200,000 UTF-16 units; truncation is flagged |
| Host-side read cap | 1 MiB of stdout; more kills the child and returns `result exceeded the limit` |
| Snapshot cap | 1,500 nodes, depth 40, name 120 characters, within the result cap |
| Argument caps | function source 128 KiB; other strings 16 KiB; `fields` 200 entries; whole arguments 256 KiB |
| Per-call deadline | default 10 s, hard maximum 30 s; first-consent probe 120 s |
| No envelope in stdout | `script_error` (syntax error, CSP refusal in Safari, or a non-JSON reply) |
| Error text to the caller | at most 2 KiB, built from the envelope or the error class; `osascript` stderr is not passed through or logged |

- R4.7 **Snapshot format.** An outline, one node per line, our own format and not Playwright's.
  Depth-first over the main document, open shadow roots and same-origin iframes. Cross-origin
  iframes and closed shadow roots appear as a placeholder line. Hidden, `aria-hidden`, inert and
  `display:none` elements and `script`, `style`, `noscript` and `template` are skipped. Values
  of password-class inputs (`type=password`, `autocomplete` of `current-password`,
  `new-password`, `one-time-code`, `cc-*`) print as `<hidden>`, and `type=hidden` inputs are
  omitted. A preamble line marks page content as untrusted data.
- R4.8 **Refs** are `e<N>`, the node's ordinal in traversal order. They are not stored in the DOM.
  The host keeps, per tab, the latest snapshot table (role, name fingerprint, tag, depth, text fingerprint,
  plus the document `url` and `timeOrigin`). An action re-walks the document, takes node N and
  compares its fingerprint. A mismatch or a changed `url` or `timeOrigin` returns `stale_ref` and
  does nothing. A new snapshot of a tab makes that tab's older refs stale.
- R4.9 **Constraints and handling.**

| Constraint | Handling |
|---|---|
| Main frame only | Cross-origin iframes are a placeholder; actions inside them are refused with `frame_not_supported` |
| Chrome isolated world, Safari page world | Chrome pages cannot see the library or results. Safari output is treated as page-influenced. `browser_evaluate` documents the difference |
| Untrusted events (`isTrusted` false) | Results carry `structuredContent.untrusted: true`; the error for sites that need a real click says to use `mouse` after `screenshot` |
| `alert`, `confirm`, `prompt`, `beforeunload` block the renderer | The deadline kills the child and returns `blocked_by_dialog` pointing at `ui_snapshot` and `ui_action`. Every payload carries an absolute deadline, and the library returns `expired` instead of acting late |
| Async results are not awaited | `browser_evaluate` and `wait_for` start the work in a job slot in the script world and poll every 150 ms; a lost slot is `async_lost`. Results are never written into the page DOM. If the slot cannot persist (V4), `browser_evaluate` is synchronous only |
| One renderer per tab | At most one in-flight call per tab and two per browser |
| DevTools disabled by policy | Mapped to `blocked_by_policy` |
| Several Chrome profiles | Possibly bound to one profile (V5); noted in the wizard and the manual checklist |

- R4.10 **Targeting.** One target browser, chosen in the wizard (default: the system default
  browser if ready), stored as `browserTools.targetBrowser.v1`. An action with no tab choice
  acts on the front window's active tab. `browser_tabs select` records a current tab that later
  calls use until it disappears, and does not raise the window. Chrome tabs are addressed by
  window id and tab id. Safari has no stable tab id, so tabs are re-validated against URL, title
  and `performance.timeOrigin` before each action; two indistinguishable tabs are a documented
  limit.
- R4.11 **Other behaviour.** `browser_navigate` refuses `javascript:`, `data:`, `file:`,
  `chrome:`, `view-source:` and every non-allowed scheme with `unsupported_scheme`.
  `browser_fill_form` and `browser_type` never echo values. `browser_wait_for` is host-side
  polling, max 30 s. `browser_close` closes the current tab only. `browser_press_key` activates
  the target browser first, and sends nothing if activation fails.
- R4.12 The existing `ui_snapshot` and `ui_action` are unchanged and stay `owner` only. They
  dismiss page dialogs and native choosers, read browser chrome, and back the assisted menu flip.
  Waking Chrome's web accessibility tree is not done here.

### R5. Wizard page "Browser tools"

- R5.1 A new `WizardPage.browser` after `optional` (Full Disk Access) and before `tailnet`:
  `[core, optional, browser]` plus `tailnet` when offered. It is always offered. It holds the
  Playwright install row and one Apple Events row per installed supported browser. The relaunch
  resume key accepts `browser`.
- R5.2 Supported browsers are Google Chrome (`com.google.Chrome`) and Safari
  (`com.apple.Safari`), found by bundle id, so `~/Applications` installs count.
- R5.3 **Per-browser states and the probe.**

| State | Reached when | Row text and button |
|---|---|---|
| `notInstalled` | no application for the bundle id | row hidden |
| `notRunning` | installed, not running | "Open Chrome to continue." **Open Chrome** (launches without taking focus) |
| `needsAutomation` | never probed | "macOS will ask whether OpenAB Computer may control Chrome." **Allow** (runs the probe) |
| `probing` | probe in flight | "Waiting…" with a 120 s timeout and **Cancel** |
| `automationDenied` | probe error -1743 | explains Settings → Privacy & Security → Automation; **Open Settings**, then **Retry** |
| `noWindow` | no window or tab to run in | "Open a Chrome window, then press Retry." |
| `jsDisabled` | error text contains "turned off" (case-insensitive) | Chrome: View → Developer → Allow JavaScript from Apple Events, then Retry, with the verbatim line `Chrome said: Executing JavaScript through AppleScript is turned off.` Safari: Develop → Allow JavaScript from Apple Events (Settings → Advanced if there is no Develop menu). Safari's exact error text is captured by V6 |
| `blockedByDialog` | probe timed out after consent | "A page in Chrome is showing a dialog. Close it, then press Retry." |
| `probeFailed(class)` | any other error | the error class, never page text, and **Retry** |
| `ready` | probe returned `"2"` | "✓ Ready" |

  The Chrome text match is locale fragile (V2). When Automation is allowed, a window exists and
  the error is neither a timeout nor a known TCC code, the state is `jsDisabled (suspected)`,
  shown with the raw error class and the same instructions.
- R5.4 The probe runs the real executor path with the real static template and a trivial payload
  (`String(1+1)`) against the front window's active tab. It reads and changes nothing in the page.
- R5.5 **Probe budget.** A probe runs only on a user click (Allow, Retry, Open Chrome, then once),
  once when the app is re-activated after the user returned from System Settings, and never from
  a timer. At most one probe per browser per 2 s. At launch and in the menu, state comes from the
  last stored result, marked "last checked …". Nothing is probed there, because an undetermined
  Automation state would raise a system prompt with nobody present.
- R5.6 **Footer.** The Playwright row is pre-checked. **Continue** is enabled whenever nothing is in
  flight. A Tier A probe is never required to leave the page. With the box checked and Playwright
  not yet installed, pressing Continue starts the install on the page, with progress and
  **Cancel**, and Continue is disabled until that install ends; when it succeeds the page
  completes and the wizard advances. With the box unchecked, or after an install was skipped
  following a failure, Continue completes the page at once. After a failed install or a probe in any state other than `ready`, `needsAutomation`
  or `notRunning`, the footer adds **Retry** and **Continue without**. **The wizard always
  completes**: offline, a failed download and a refused archive all end in Retry or Continue
  without, with Playwright simply not installed. If neither tier ends up ready, the router lists no
  `browser_*` tools. Unchecking the box with no Apple Events probe is an explicit decline, and
  Continue records the same completion, so declining reaches the tailnet page normally. Closing
  the window is not completion; the page reopens from **Set up browser tools…**. Tailnet exposure
  stays reachable from the Network menu regardless. If no supported browser is installed, only the
  Playwright row shows.
- R5.7 **Assisted flip of Chrome's menu item.** Next to Chrome's `jsDisabled` state, a **Turn it
  on for me** button, available only when Accessibility is granted. It is never automatic. It
  shows an alert naming the exact change, including that this is a Chrome setting for the whole
  profile that lets every app allowed to control Chrome run scripts in every page, including
  signed-in ones, and that removing browser tools from this app does not turn it off. Only on
  **Turn on** does it activate Chrome, press that one menu item through Accessibility, and run the
  probe. If the item is not found (for example a localized menu, V9) it says so and shows the
  manual steps. It never edits Chrome's `Preferences` or any other setting. Consent is per press
  and not stored. Safari's switch is manual only in v1.
- R5.8 **Playwright install row.** A checkbox, pre-checked, with text of this shape, every number
  filled from the embedded manifest and never typed into the copy:

  > **Install Playwright browser (recommended).** Downloads about *N* MB: Node.js, the Playwright
  > MCP server and a separate Chromium, from nodejs.org, registry.npmjs.org and the Chromium host
  > named in the manifest. Installs to `~/Library/Application Support/oab-computer/playwright/`.
  > Each download is checked against values built into this app. It uses its own browser profile,
  > not your Chrome or Safari. Needs an internet connection and about *M* MB of free disk.
  > **Uncheck to skip it;** you can install it later from the menu.

  Consent is the user pressing **Continue** with the box checked. Nothing is downloaded before
  that, and the copy never calls the result safe. When the install finishes, the row shows
  **Open Playwright browser to sign in…**.
- R5.9 **Menu bar.** The browser row reads, for example,
  `Browser tools: Playwright ready · Apple Events (Chrome ready)` or `Playwright not installed`.
  Items: **Set up browser tools…**, **Install Playwright…** (when not installed or failed),
  **Open Playwright browser to sign in…**, **Remove Playwright…**,
  **Prefer: Auto / Apple Events / Playwright**, and the target-browser choice. No URL, tab title
  or page text is ever shown there.
- R5.10 **Persisted values** (`UserDefaults`, prefix `browserTools.`): `backend.v1`,
  `targetBrowser.v1`, `lastProbe.<bundle id>.v1` (state name and time, no text),
  `pageCompleted.v1`, `playwrightOffer.v1` (offered, declined, failed or installed). None is a
  secret, and a probe result is a hint, never proof. Unknown stored values reset to the default
  (`auto`, no target) with one log line naming the key.
- R5.11 Copy strings live in `WizardCopy` and are pinned by tests.

### R6. Entitlements and permissions

- R6.1 `scripts/assemble-app.sh` writes a non-empty `NSAppleEventsUsageDescription` into
  Info.plist: "OpenAB Computer runs scripts in Chrome and Safari when you turn on browser tools,
  so agents you authorise can read and operate web pages."
- R6.2 A new `scripts/oab-computer.entitlements` carries
  `com.apple.security.automation.apple-events`, passed with `--entitlements` by `deploy.sh` and
  the release workflow. It must not change the designated requirement, so existing grants survive.
- R6.3 Automation consent is per (controlling app, target app). Chrome and Safari are separate
  prompts, each answered once in the wizard, and revocation appears as -1743.
- R6.4 Which identity the Automation prompt names for an `osascript` child is unverified (V1).
  If it names something other than OpenAB Computer, the executor switches to an in-process
  executor behind the same protocol, and the wizard and docs change before release. This must be
  checked on a signed `.app`, not a bare `swift build` binary.
- R6.5 Grants are keyed on the signed bundle identity, so there are no ad-hoc releases. The app
  cannot pre-grant Automation and does not try.

### R7. Playwright install, run, update, remove (Tier P)

**Principles.** Nothing is bundled in the app. The app never edits LaunchAgents, `--upstream`
plist arguments, Chrome or Safari settings, or any file it did not create. The PoC under
`~/.local/oab-computer/` is not touched or migrated. If something already answers on
`127.0.0.1:8794`, the app starts no second one and kills nothing, and it does not adopt it
automatically (R7.8).

#### R7.1 What is installed and how it is verified

An embedded manifest (a Swift constant generated at release time, covered by the app signature)
pins, per architecture (`arm64`, `x86_64`, chosen by `sysctl hw.optional.arm64`):

| Artifact | Source | Verification |
|---|---|---|
| Node.js tarball (includes `npm`) | `https://nodejs.org/dist/v<pinned>/node-v<pinned>-darwin-<arch>.tar.gz` | size and SHA-256 from the manifest before extraction. Before the staged Node first runs, `codesign --verify --strict` on `bin/node` and a TeamIdentifier equal to the manifest value (recorded from a verified release, V10) |
| `@playwright/mcp` and its dependencies | `https://registry.npmjs.org/` through the downloaded Node's `npm ci --ignore-scripts --omit=dev --no-audit --no-fund`, using a `package-lock.json` embedded in the manifest | npm checks each package against the lockfile `integrity` (sha512) and fails the install on a mismatch. The lockfile's own SHA-256 is checked before it is written. `--ignore-scripts` blocks install-time code |
| Chromium zip matching the `playwright-core` revision in the lockfile | host and path recorded in the manifest at release time | size and SHA-256 before extraction. `playwright install` is not used; Chromium is passed with `--executable-path` |

A release check, not application code, downloads each artifact, records size and digests, checks
that the Chromium revision equals the one in `playwright-core`'s `browsers.json` for the locked
version, and fails the release on any difference. A maintainer checks the manifest diff like a
lockfile diff.

The downloader enforces HTTPS itself, because Info.plist sets `NSAllowsArbitraryLoads`: only
`https`, only the manifest's host allow-list (`nodejs.org`, `registry.npmjs.org` and the manifest's
Chromium host), redirects re-checked by the same rules, no cookies, no credentials, no certificate
pinning.

`npm ci` makes its own connections, outside the downloader's host allow-list, so the allow-list
does not bound it. The release check therefore also fails the release if any `resolved` URL in the
lockfile is not on `registry.npmjs.org`.

#### R7.2 Install flow

1. **Consent.** The wizard row (R5.8), or from the menu a sheet with the same content: what is
   downloaded with sizes, the install path, host names, "checked against values built into this
   app", total download and disk needed, "needs an internet connection", where to uncheck, and
   that it installs a separate browser with its own profile.
2. **Preflight.** Free disk of at least three times the total download; no other install running
   (an atomic `mkdir` lock tried 50 times at 0.1 s); network reachable, otherwise fail fast.
3. **Staging.** `~/Library/Application Support/oab-computer/playwright/.staging-<UUID>/`, mode
   0700, created fresh and verified by `lstat` to be a directory owned by the user and not a
   symlink. `pkg/` inside it is the only package root npm sees.
4. **Download and verify** each file with progress, size then digest. A mismatch deletes the file
   and aborts the whole install.
5. **Validate, then extract, with the app's own extractor** (`SafeArchiveExtractor`).
   `/usr/bin/tar` and `/usr/bin/unzip` are not used. Stage 1 writes no extracted entries (at most
   a spool bounded by the manifest's total expanded size plus 1 MB). It rejects the whole archive
   for any absolute path, `..` component, empty or NUL-containing name, path through an earlier
   symlink entry, symlink whose target resolves outside the root or is absolute, hardlink,
   device, FIFO or socket, duplicate path with a different type, entry count or size over the
   manifest's, or name over 1024 bytes. Stage 2 creates entries relative to a directory file
   descriptor with `openat`, `mkdirat` and `symlinkat`, `O_NOFOLLOW` and `O_EXCL`, never following
   an existing link. File modes are the archive's `& 0o755`. Any failure deletes staging.
6. **Verify Node's signature, then install packages** with the staged Node, in `<staging>/pkg/`
   as the working directory: `npm ci --ignore-scripts --omit=dev --no-audit --no-fund --userconfig
   <empty file> --globalconfig <empty file> --registry https://registry.npmjs.org/ --cache
   <staging>/npm-cache`, with an allow-list environment (no `npm_config_*`, no `NODE_OPTIONS`, no
   proxy variables). `~/.npmrc` is never read.
7. **Health check.** Start Playwright MCP from staging over stdio, run `initialize` and
   `tools/list`, expect Playwright's server name and the tool names the schema fixture requires,
   then close stdin and wait for exit.
8. **Commit.** Rename staging to `playwright/<manifest version>/` (atomic on one volume) and write
   `playwright/install.json` (mode 0600; manifest version, digests, time) by write then rename.
   The profile and output directories, `playwright/profile/` and `playwright/output/` (0700), are
   shared across versions.
9. **Start** the managed process (R7.4). The sheet shows "Playwright is ready".

Nothing in this flow sets or removes `com.apple.quarantine`. Staging directories left by a crash
or cancel are removed at the next launch, and at once on Cancel.

#### R7.3 Failure paths

Each failure offers **Retry**, and **Skip** or **Continue without** only after the failure.

| Failure | Detection | Message to the user | Log |
|---|---|---|---|
| Offline | `NSURLErrorNotConnectedToInternet`, DNS failure | "No internet connection. Playwright was not installed. Connect and press Retry, or Continue without it and install later from the menu." | event and error code |
| Interrupted or timeout | `NSURLErrorTimedOut`, connection lost | "The download was interrupted." Resumes if resume data exists, else restarts that file | event and code |
| TLS failure or redirect to a non-allowed host | secure-connection error, redirect rule | "A secure connection could not be made." No automatic retry | event and host name |
| Size or digest mismatch | check before extraction | "A download did not match what this app expects. Nothing was installed." Never proceeds | artifact name, "digest mismatch", no digest values |
| Not enough disk | preflight | "Not enough free space: needs X, has Y." | numbers |
| Archive rejected | stage 1 of the extractor | "An archive had unsafe contents. Nothing was installed." | artifact name |
| Node signature check fails | after extract, before first run | "The downloaded Node.js failed its signature check." | event |
| Gatekeeper or launch refusal | health-check exit status or stderr class | "macOS would not run the downloaded browser." Retry, or, only if Google Chrome is installed, **Use my installed Chrome**. The app launches it with its own profile directory. This Chrome is not version-pinned or digest-checked by the app, and the user is told so | event and class |
| Lock held | `mkdir` fails 50 times | "Another install is running." | event |
| Crash after install | supervisor | menu: "Playwright: failed, see log" | event and exit status |

Log lines use the `browser:` prefix and never contain URLs with tokens or response bodies.

#### R7.4 Running it

The managed process is a child of the app, not a LaunchAgent. The app writes no plist. It starts
when a connection's active backend is `playwright` (chosen by `auto` or pinned) and the install is complete. It runs with the staged `node`, the `@playwright/mcp` entry and
`--user-data-dir <profile> --output-dir <output> --idle-timeout 1800000 --browser chromium
--executable-path <our Chromium> --shared-browser-context --caps vision,pdf`. There is **no**
`--port`, `--host` or `--allowed-hosts`: stdio is the default transport when `--port` is absent,
to be confirmed on the pinned version by a live smoke call (V8) and a check that neither Playwright
nor Chromium opens a listening socket (V12).

- stdout is the protocol channel and is never logged.
- The environment is an allow-list (`HOME`, `TMPDIR`, `LANG`, and a `PATH` of the staged `node`
  directory plus `/usr/bin:/bin`).
- **stderr is never persisted.** The app reads it continuously into a 64 KiB in-memory ring buffer
  (newest kept), classifies the exit status and a fixed set of failure signatures (for example
  `singleton lock`, `executable not found`) into app-generated event classes, and logs only those
  classes and numbers. The buffer is never written to disk or returned to a caller. There is no
  `playwright.log`.
- **Supervision.** Restart with backoff of 1 s, 2 s, 4 s up to 30 s. After 5 failures in
  2 minutes the backend is `unavailable` until the user presses Retry. On quit the app terminates
  the process group. The pid is kept in memory only. An orphaned Chromium from a crashed app is
  not killed, because the app cannot prove it is ours; it normally ends by itself when stdin
  closes (V12 confirms). Until then it can hold Chromium's singleton lock on the shared profile,
  and the next managed start reports `profile_locked` ("the browser profile is in use by another
  process; quit that browser and press Retry").

#### R7.5 External Playwright (loopback 8794)

- R7.5.1 The only TCP path. It serves an operator `--upstream browser=URL`, the PoC LaunchAgent
  and the Linux hands node.
- R7.5.2 At startup the router **rejects** any host that is not the literal `127.0.0.1` or `::1`.
  No name resolution is done, so `localhost` and DNS names are refused (exit 64 for flag launches).
- R7.5.3 The browser-path HTTP client follows **no redirects**. Any 3xx is the fixed
  `upstream_redirect` error and no second request is made.
- R7.5.4 Errors are a fixed boundary. Every `UpstreamError`, transport error and JSON-RPC `error`
  maps to a class string (`upstream_http_<status>`, `upstream_redirect`, `upstream_bad_body`,
  `upstream_rpc_error`, `upstream_unreachable`, `upstream_timeout`) with no upstream-supplied
  text. Successful tool results stay passthrough. The generic `--upstream name=URL` path keeps its
  current behaviour.
- R7.5.5 **Listener ownership.** Before use and on every health check, the app finds the pid that
  owns the listening socket (libproc) and compares its uid with the daemon's effective uid. If the
  pid or uid cannot be determined, the external backend is `unavailable` (fail closed). Process
  name and user are shown in the menu and `sys_info` (names only). A same-uid impostor is outside
  this control and is stated as such.
- R7.5.6 The app never calls `tailscale` for 8794 or 8443. A repository test fails if any file
  under `Sources/InstanceMCPCore/Browser/` contains `tailscale`.
- R7.5.7 Loopback is not private: every process of every user can reach it, and Playwright MCP
  0.0.82 has no bearer check in anything this repository configures. The app never presents it as
  private.

#### R7.6 Gatekeeper and quarantine

- The app is not App Sandboxed, is Developer ID signed with hardened runtime and notarized. Hardened
  runtime library validation applies to code loaded into the app's process, not to children.
- The app never strips and never adds `com.apple.quarantine`. If the attribute appears, it is left
  alone. If macOS still refuses to run a file after the digest and signature checks, the install
  stops with the Gatekeeper failure in R7.3.
- Whether our downloader sets the attribute is unverified (V7).
- The Chromium process is a child of the app: it shows in the Dock and has its own window, and it
  does not inherit Screen Recording or Accessibility.

#### R7.7 Update and removal

- **Update.** A new app release embeds a new manifest. The menu and wizard show "Playwright update
  available (x → y)" when `install.json`'s version differs. **Update** runs the install flow into a
  new `playwright/<version>/`, health-checks it, stops the old process, switches `install.json`,
  starts the new one, and keeps the previous directory until the new one has served one
  successful health check. A failed update leaves the old version running. There is no silent
  update. The menu warns when the installed Chromium revision is older than the manifest's by more
  than the manifest's `staleAfterDays`.
- **Removal.** **Remove Playwright…** confirms what is deleted (`playwright/`, including the
  browser profile and its cookies), stops the process, deletes
  `~/Library/Application Support/oab-computer/playwright/`, and clears the stored backend
  preference if it was `playwright`. It touches nothing under `~/.local/oab-computer/`, Chrome or
  Safari, and does not turn off a browser's JavaScript-from-Apple-Events switch (the confirmation
  says so). It is safe to repeat.
- Uninstalling the app does not remove this directory; **Remove Playwright…** is the way.

#### R7.8 Existing listener on 8794

An existing Playwright MCP on 8794 is **external Playwright** only when the operator passed
`--upstream browser=URL`, or the user pressed **Use it** on a prompt that says another program on
this Mac is serving browser tools on port 8794 (process name, user) and that it will receive
everything the agent types or evaluates in the browser. R7.5.5 applies to both. Otherwise it is
ignored; the managed child uses stdio, so a busy 8794 does not affect it.

#### R7.9 Signed-in sites in the Playwright profile

The user signs in once in the Playwright headed window and the persistent profile
(`playwright/profile/`, 0700, shared across versions) keeps the session. There is no cookie import
from Chrome or Safari. Entry points: **Open Playwright browser to sign in…** on the wizard page and
in the menu. It starts the managed child if needed and makes one internal `browser_navigate` to
`about:blank`, which opens the headed Chromium window; the user types the site into its address
bar. That call is not logged with any URL.

Stated limits:

- Some sites block or challenge automated browsers. This is not verified for any site; the wizard
  text says "some sites may refuse an automated browser".
- The profile holds the user's cookies for those sites, protected by the 0700 directory and
  Chromium's own storage, with no further encryption. **Remove Playwright…** deletes it.
- The user should not use the same window while an agent is acting. The managed child owns the
  profile lock, so a second Chromium on the profile fails with `profile_locked`.
- `--idle-timeout` (30 minutes) closes the browser when idle; the session survives in the profile.
- Prompt injection on a signed-in site can act as the user on that site. This is the same residual
  risk as Tier A and is stated in the docs.

### R8. Logging and secret hygiene

- R8.1 The code never logs arguments, results, URLs, titles, page text or `osascript` stderr. The
  existing `tools/call` line logs only the principal and tool name. New `browser:` lines contain
  only an event name, an error class and a number.
- R8.2 The agent log is mode 0644 and this work does not change that, so R8.1 is what protects
  secrets. Opening the log 0600 is a recommended follow-up.
- R8.3 Docs for browser tools say that `browser_fill_form` and `browser_type` values travel in
  call arguments, and that switchboards older than openab-sb 0.2.2 log call arguments, so real
  passwords should not go through an older switchboard.
- R8.4 `osascript` and Playwright children get an allow-list environment.

### R9. Documentation

`docs/tool-profiles.md` and the README browser sections must state that Tier A acts as the user in
their signed-in browser, that Tier P acts as the user on sites signed in to in the Playwright
window, and the Chrome "Allow JavaScript from Apple Events" consequence from the ADR. Wizard
consent text states the same. `docs/tool-profiles.md` and the browser row of
`docs/parity-checklist.md` also record that unknown upstream browser tools are filtered on macOS
(R1.5) while Linux still passes them through.

## Verification checks

None of these is claimed as verified by this document. Each must be settled on a signed build
before the feature it concerns ships.

| Check | Question | If it fails |
|---|---|---|
| V1 | Which identity does the Automation prompt name for an `osascript` child of the signed hardened-runtime app, with and without `NSAppleEventsUsageDescription` and the entitlement? Does a grant survive an update? | Switch to the in-process executor and update copy |
| V2 | Exact Chrome error text and number when the switch is off; is it localized? | Use the fallback classification (R5.3) |
| V3 | Exact AppleScript terms (`tab id … of window id …`), return types, error numbers for no window, `with timeout` behaviour, Safari `do JavaScript … in tab`, and whether stdin can replace the temporary file | Adjust templates and the golden digest |
| V4 | Does Chrome's isolated world keep `globalThis` between two calls? Are Promises awaited? | Synchronous-only `browser_evaluate` and no in-page text polling for `wait_for` |
| V5 | Does Chrome scripting cover only the last-used profile? | Document it and show it in the wizard |
| V6 | Safari's error text when the switch is off, and Develop menu wording in the current Safari | Update copy |
| V7 | Quarantine attribute on our downloads; `spctl` and launch result for Node and Chromium on a clean account, both architectures | The "never strip, never add" rule applies |
| V8 | Capture `tools/list` schemas from the pinned `@playwright/mcp`; does `--executable-path` work with our Chromium? Which `--allowed-hosts` value works with the external adapter? | Create the fixture and adjust flags |
| V8b | (external) Does a cross-origin `fetch` or form POST from an `https://` page, with MCP headers and `Host: 127.0.0.1`, get refused by Playwright MCP 0.0.82 on 8794? Does Chrome's Private Network Access block it? | State the exposure in the external-use consent copy; managed path unaffected |
| V9 | Can the Chrome menu item be found and its state read through Accessibility, localized and not? | Hide the button and show manual steps only |
| V10 | The Node release's signing TeamIdentifier, recorded from a verified download | The manifest carries it |
| V11 | (external) Can libproc report the owning pid and uid of a loopback listener for same-user and other-user processes without elevated rights? | The external path fails closed for both the flag and the consent prompt; managed stdio is unaffected |
| V12 | **Release blocker.** With the pinned `@playwright/mcp` started with no `--port`, do the process and its Chromium children hold no TCP or UDP listener (`lsof -nP -i` per pid, on the build host)? Does it exit on stdin EOF? Repeat the listener check with the "Use my installed Chrome" launch (`--executable-path` at Google Chrome, app profile directory): no debugging port, and the tool list and health check still succeed. Is stdio the default, with `browser_run_code_unsafe` present? | A listener blocks release until removed (pipe-based debugging) or authenticated. No EOF exit means the app relies on killing the process group on quit and on restart |
| V13 | (external) Does the browser-path session refuse 301, 302, 307 and 308 from a loopback server, with a second listener proving no request arrives? | Unit-tested with a local test server, so a failure is a build failure |
| V14 | Does an internal `browser_navigate` to `about:blank` open a headed Chromium window on the persistent profile with an address bar, and does a sign-in survive stopping and restarting the managed process and relaunching the app? Which sites refuse the automated browser is recorded per site | Add a URL field to the sign-in entry point; document the sites that refuse |

Remaining assumptions: `@playwright/mcp` 0.0.82 stays the pinned version until V8 chooses a newer
one, and the manifest, not this document, names the final versions. AppleScript terms and every
message marked "to be captured" are placeholders until V2, V3 and V6. The 30-minute identity-guard
window is a design value.

## Files to change and add

**Add** under `Sources/InstanceMCPCore/Browser/`: `BrowserBackend.swift`, `BrowserRouter.swift`,
`BrowserToolCatalog.swift`, `AppleEventsBackend.swift`, `AppleEventExecutor.swift` (protocol and
`OsascriptExecutor`), `AEPayload.swift`, `AEScriptLibrary.swift`, `AERefTable.swift`,
`AEToolSchemas.swift`, `BrowserSetupModel.swift`, `PlaywrightBackend.swift`,
`PlaywrightInstaller.swift`, `PlaywrightManifest.swift`, `ManagedProcess.swift`,
`StdioMCPClient.swift`, `PortOwnerProbe.swift` (external path only), `SafeArchiveExtractor.swift`.
Also `Sources/oab-computer/BrowserPageView.swift`, `scripts/oab-computer.entitlements` and
`conformance/browser_tool_schemas.json`. Resources are Swift constants, not SwiftPM resource
bundles, because `assemble-app.sh` copies only the binary and `install-prebuilt.sh`.

**Change:** `MCPServer.swift`, `MCPHTTPEndpoint.swift` (forward the header), `ToolProfile.swift`
(forward `browser` in `scoped(to:)` and `mappingTools(_:)`), `main.swift` (build the router, route
`--upstream browser=`, loopback check), `SetupWizardModel.swift`,
`PermissionSetupWindowController.swift`, `StatusItemController.swift`, `MenuModel.swift`,
`SysInfoTool.swift` (backend and state, no URLs), `scripts/assemble-app.sh`, `scripts/deploy.sh`,
`.github/workflows/release.yml` (entitlements), `scripts/test-packaging.sh`,
`scripts/test-pw-mcp-check.sh` (scan `Browser/`), `docs/tool-profiles.md`, the README browser
sections and `docs/parity-checklist.md`.

**Not changed:** the agent log mode, `poc/pw-mcp/*`, the `install-prebuilt.sh` upstream detection,
and Linux code.

## Test plan

Build and test run on the Mac build host and in CI on `macos-15`; a developer laptop is not
required. No automated test calls `osascript` against a browser, runs `tailscale`, or changes a real
setting. Live consent dialogs cannot be automated.

### Unit tests (`swift test`, no GUI) — runnable on the build host

1. Payload encoder hostile corpus through JavaScriptCore (quotes, backslashes, newlines, NUL,
   U+2028 and U+2029, `*/`, backticks, `${…}`, a `</script>` fragment): the decoded value is
   byte-identical and nothing outside the literal changes. The static AppleScript golden digest.
   Argument pattern checks.
2. Temporary file: mode 0600, directory 0700, `O_EXCL`, deletion on every path, startup sweep.
3. Envelope parser and error classification with a fake executor: -1743, -1712, -1728, 9001,
   "turned off", no envelope, oversized.
4. Router matrix (R2): the Playwright-first rows, the header override (and that it stores
   nothing), the 30-minute identity guard in both directions with an injected clock, no fallback
   when a named backend is not ready, `observe` seeing nothing, the unsupported-tool message,
   `scoped` and `mappingTools` forwarding.
5. Tool matrix: each of the 32 names appears exactly once per tier (the synthetic fixture name is
   absent from both); unknown upstream tools are filtered; Tier A counts 6, 10 and 16; the schema
   fixture check; `vectorNames(prefix: "browser_")` equals the 32 plus the synthetic name; no
   `browser_*` name is allowed by `observe`.
6. Ref table: stale after a new snapshot, fingerprint mismatch, changed `timeOrigin`.
7. Wizard model: page order, footer actions, "Retry and Continue without only after a failure",
   resume page `browser`, state mapping from error classes, pinned copy strings. The Playwright
   box is pre-checked; Continue is enabled with the box unchecked; an offline preflight failure
   ends in Retry or Continue without and the page completes; declining reaches the tailnet page;
   copy carries the manifest sizes and host names and never the word "safe".
8. Installer with an injected downloader and file system: digest mismatch aborts and cleans,
   HTTPS-only and the redirect rule, offline mapping, disk check, atomic commit, the `npm` argument
   vector (empty `--userconfig` and `--globalconfig`, `--registry`, `--cache` in staging,
   allow-list environment, working directory `<staging>/pkg/`), update keeps the old version on
   failure, removal and idempotence, the lock.
9. `SafeArchiveExtractor` with generated tar and zip archives: absolute path, `../`, entry through
   an earlier symlink, escaping symlink, hardlink, device node, setuid mode, duplicate path,
   oversize. Each asserts stage 1 rejects it, a sentinel file outside staging is unchanged, and no
   file was created in staging. A benign archive with relative internal symlinks (the Node
   `bin/npm` shape) extracts with the right modes.
10. Listener ownership (external): with an injected probe, owner uid equal to ours is accepted;
    unknown owner and other uid fail closed; no call is sent to an unowned listener.
11. Managed stdio client with a stub child: newline-delimited JSON-RPC over pipes, partial lines, a
    child exit mid-call (clear error, supervision restarts), stderr never mixed into the protocol
    stream.
12. Process launch: the managed argument vector contains no `--port`, `--host` or
    `--allowed-hosts`; the environment is the allow-list; `npm ci` runs in `<staging>/pkg/` and a
    sentinel `node_modules` in the app's working directory is untouched; no Playwright log file is
    created under `~/Library/Logs/oab-computer/` or Application Support.
13. Loopback rule for `--upstream browser=`, and a repository scan that no `tailscale` string
    appears under `Browser/`.
14. External adapter redirect boundary (V13): a local server answers 301, 302, 307 and 308 pointing
    at a second listener; that listener receives no connection, the caller gets
    `upstream_redirect`, and the POST body is never re-sent.
15. Error boundary: a fake upstream returns a non-2xx body, a JSON-RPC `error` with a message and
    a malformed body, each carrying a canary secret; the caller error and every log line contain
    only the fixed class strings. A stub managed child writes canary URLs and tokens to stderr and
    exits; no file under the log or Application Support directories contains the canary, and the
    ring buffer is unreachable from any tool result.
16. Secret hygiene: canary secrets sent through every Tier A tool and the fake Playwright adapter
    are absent from captured log lines, stderr, errors, the run directory and echoed fields.
17. `BrowserProfileTests` updated to go through the router.
18. `scripts/test-packaging.sh`: the assembled Info.plist has a non-empty
    `NSAppleEventsUsageDescription`, and signed builds show the entitlement.

### GUI-session tests — skipped without a window server

The injected library inside `WKWebView`: roles, names, password masking, hidden-element skipping,
open shadow DOM, same-origin iframe, caps and truncation, ref re-walk. On the build host run them
under `launchctl asuser`. WKWebView is the Safari engine in the page world, so it also approximates
Safari. Chrome's isolated-world differences are covered only by the manual list.

### Manual checklist — a person at the console of a Mac with Chrome and Safari

Record each result next to the matching V check.

- M1 The Automation prompt for Chrome shows the usage text and names the expected app.
- M2 The same for Safari.
- M3 Deny, then Retry shows the denied text; allow in Settings, then Retry shows ready.
- M4 Chrome's switch off: capture the exact error. Switch on: ready.
- M5 Safari without a Develop menu: the instructions match the current Safari.
- M6 Multiple windows, tabs and Chrome profiles: `browser_tabs` list, select, close.
- M7 Async `browser_evaluate` and `wait_for` across two calls (V4).
- M8 An `alert()` page: timeout error, dialog dismissed through `ui_snapshot` and `ui_action`, and
  the queued action does not fire after dismissal.
- M9 A strict-CSP page in Safari: the `browser_evaluate` error is clear.
- M10 A large real page: snapshot truncation and timing.
- M11 The assisted menu flip with consent, in English and one non-English Chrome.
- M12 Revoke Automation while running: the next call returns the denied message, then there are no
  `browser_*` tools (or the "not used automatically" message), and `auto` does not switch to the
  other tier within 30 minutes. An explicit header or menu pin, or 30 idle minutes, is required
  before Tier P serves the conversation.
- M13 Playwright install on a clean account: the default pre-checked path, the unchecked path, and
  offline with the box checked. Also normal, offline, interrupted and tampered-manifest (debug
  build) cases; quarantine and `spctl` results; the "Use my installed Chrome" fallback (no
  listener, tool list, health check, Chrome version noted); headed launch; update; removal; and
  leftover staging after a kill.
- M14 After a reboot the managed process starts, and port 8794 is either free or an external
  listener is detected.
- M15 After the whole session, no file remains under
  `~/Library/Application Support/oab-computer/run/ae/` and no secret appears in
  `~/Library/Logs/oab-computer/`.
- M16 Sign-in: open the Playwright window from the wizard and from the menu, sign in to one site,
  stop and restart the managed process, relaunch the app, and confirm the session persists. Record
  which sites refuse the automated browser (V14).
- M17 Router: with Playwright and Apple Events both ready, an agent with no header gets Playwright;
  a second connection with `OAB-Browser-Backend: appleEvents` gets the real browser; stopping
  Playwright mid-task does not switch an `auto` connection within 30 minutes.

## Linux parity

Linux has no Apple Events, no Accessibility tools (`ui_snapshot` and `ui_action` are deferred, see
[#102](https://github.com/openabdev/openab-computer/issues/102)) and no wizard. The Linux hands
node keeps exactly today's browser path: Playwright MCP on `127.0.0.1:8794` through
`MCP_UPSTREAM`, installed by `scripts/install-linux.sh`, with the same 32 names and the same
`owner` and `observe` rule. This work changes no Rust code and no vector in
`conformance/profile_vectors.json`, so the Rust `profile_conformance` test is unaffected.

Gaps that remain and are not claimed as closed: the verified on-demand download is macOS only, and
the Linux installer still uses the Node on `PATH` and either the distribution's Chromium or
Playwright's own Chromium download, without a pinned manifest; the filtering of unknown upstream
browser tools (R1.5) is macOS only; and the loopback check for the browser upstream is added to the Swift
daemon only. The Linux installer is out of scope here and is tracked in
[#119](https://github.com/openabdev/openab-computer/issues/119), to be designed later. The
`docs/parity-checklist.md` entry is updated to say so.

## Out of scope

A Chrome extension. Building Tier C (CDP). Brave, Edge, Arc and other Chromium browsers. Per-site
allow or deny lists. Waking Chrome's web accessibility tree for `ui_snapshot`. Changing
`ui_snapshot` limits. `observe`-profile browser tools. Bundling Node or Chromium. Migrating or
removing the PoC `poc/pw-mcp` scripts. Linux-side changes, including the Linux installer. Cookie
import into the Playwright profile. Any new tool name. Authentication on the external 8794
listener. Adopting an external Playwright without consent. Telemetry.
