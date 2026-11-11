# UI tools: `ui_snapshot` and `ui_action`

Full detail for the two accessibility-tree tools. The [README tools table](../README.md#tools)
has the summary. Both tools are macOS only; the Linux AT-SPI port is deferred
([#102](https://github.com/openabdev/openab-computer/issues/102)).

## `ui_snapshot`

Accessibility tree of a native app's window (AXUIElement), read-only. `owner` only.

- **Target.** Default: the frontmost app's focused window. `app` (bundle id or name) or `pid`
  selects an app; `window` (title or index) or `all_windows` selects windows.
  `include_menu_bar` also walks the app's menu bar, so menu items get refs.
- **Per node.** Role, subrole, title, value (secure fields always masked), state, frame in
  display points (the `screenshot`/`mouse` space, with display index), and a `ref` valid within
  the `snapshot_id`.
- **Bounds.** `max_depth` 20 (≤50), `max_nodes` 300 (≤2000), `timeout_ms` 3000 (≤10000) bound the
  whole call, every AX call included. Partial results are flagged `truncated` / `timed_out`, and
  elements that do not answer within 0.5 s are flagged `unresponsive`.
- **Values.** Long text values are read as a 200-character prefix.
- **TCC.** Needs Accessibility.

## `ui_action`

Acts on a `ui_snapshot` node by ref through the Accessibility API, without moving the pointer.
`owner` only (`shell`-class, like `mouse` and `key`).

- **Arguments.** `snapshot_id` + `ref` + `action`.
- **Actions.**
  - `press` (AXPress).
  - `set_value` (AXValue, with `value`: string, number or bool; replaces the whole value).
  - `focus` (sets AXFocused; never raises a window; refused where AXFocused is not settable).
  - `show_menu`, `confirm`, `cancel`, `increment`, `decrement`.
- **Unsupported actions.** An action the element does not support is refused before anything is
  done, and the error lists the actions it does support.
- **`activate`.** Does **not** activate the app or raise a window unless `activate: true`. With
  it, the tool sets AXFrontmost on the app, falls back to activating it, then raises the ref's
  window. If the app does not come to the front, the call fails and does nothing.
  `show_menu`, menu-bar items of a background app and `focus` before `key` typing commonly need it.
- **Secure fields.** `set_value` can set a secure field over `/mcp` and a reverse attach. This
  daemon never logs or returns their value, and never logs `value` for any target. Through
  `--switchboard`, `set_value` on a secure field is **refused by default**, and nothing is typed
  into the app. See [Serving a switchboard](../README.md#serving-a-switchboard---switchboard)
  for the opt-in.
- **Audit exposure.** Through a switchboard older than openab-sb 0.2.2, `ui_action` arguments,
  including `set_value` values, are written to the switchboard's audit log. 0.2.2
  ([openabdev/openab-sb#16](https://github.com/openabdev/openab-sb/pull/16)) records `value` and
  `key` `text` only as a redacted length. Do not send secrets through `set_value` over an older
  switchboard (`key` typing has the same exposure).
- **Timeout.** `timeout_ms` 2000 (≤10000) bounds the whole call: checks get at most 0.5 s each,
  and the action gets the rest. An action the app does not confirm in time is reported as
  *unconfirmed*. It may have happened, so re-snapshot and do not repeat it blindly.
- **`structuredContent`.** The target, `activated`, and, budget permitting, `post_state`
  (focused, and value for non-secure fields).
- **TCC.** Needs Accessibility.

## Refs and stale refs

- The last 4 snapshots are kept for 5 minutes.
- A ref from a snapshot that is gone is refused as `stale ref`. So is a ref whose element
  vanished, changed role or subrole, moved to another process, or left its window.
- The tool never guesses a replacement. Take a new `ui_snapshot` and use the new ref.

## Containers

A ref under a window is accepted only while the element is still in a window it was walked
under: its `AXWindow`, or, for controls that report none (a save or confirm sheet's buttons), its
`AXTopLevelUIElement` or the nearest window, sheet, drawer or popover up its `AXParent` chain,
must be one recorded on the ref's path. An element whose nearest container was never walked is
refused as `stale ref … has left its window`.
