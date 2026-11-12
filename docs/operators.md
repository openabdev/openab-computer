# Operator notes and gotchas

Moved from the README's Gotchas section. Each item cost a deploy cycle once. Host names are
written as placeholders or as "an M4 Mac mini".

## Gotchas (each one cost a cycle)

- **Keep the `LoopbackHTTPServer` a global.** Declared inside `do {}` it was released at the
  end of the block; the listener stayed bound, accepted connections, and never answered —
  the `[weak self]` handlers were no-ops. `curl` hung to its timeout with no server log line.
- **`codesign` over SSH → `errSecInternalComponent`** for anything in the login keychain, with
  or without `ssh -t`. Sign from a dedicated keychain whose password is on disk
  (`KEYCHAIN` / `KEYCHAIN_PASSWORD_FILE` in `deploy.sh`), passing `--keychain` explicitly.
- **`kiro-cli mcp add --force` truncated `~/.kiro/settings/mcp.json` to 0 bytes** the second
  time it was used in a session. Back the file up before `mcp add`, or edit it by hand.
- **macOS has no `timeout`.** Remote scripts bound steps with `perl -e 'alarm shift; exec @ARGV'`
  and `curl -m`. Write them as bash files: zsh does not word-split `$VAR`, so
  `C="curl -s -m 10"; $C …` is "command not found".
- **`tccutil reset ScreenCapture <bundle-id>` does not make the prompt appear.** After the
  first denial the system records it and further capture attempts fail silently; the grant
  has to be toggled in System Settings on the machine's own display.
- **The setup wizard's Allow button calls the system request, and a recorded denial stays silent.**
  `CGRequestScreenCaptureAccess()` and `AXIsProcessTrustedWithOptions` with the prompt option run only
  when a user clicks Allow in the wizard. After an earlier denial they show no prompt, so the wizard
  re-tests and opens the matching System Settings pane instead. Revocation is checked every 30 seconds
  with preflight calls only (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`), which never prompt
  and never capture.
- **Display sleep = black screenshots.** An M4 Mac mini shipped with `displaysleep 3`; the first
  screenshot after a quiet spell was solid black with a cursor. `pmset -a displaysleep 0`.
- **A stuck `osascript` is usually a consent dialog.** First AppleEvent to an app pops an
  Automation prompt on the Mac; the call blocks until answered. Over SSH the prompt is attributed
  to `sshd-keygen-wrapper` — decline those; only the agent bundle should hold Automation grants.
- **`launchctl bootout` returns before the job is gone**; an immediate `bootstrap` fails and,
  under `set -e`, took the deploy script with it — leaving no agent running. Poll until
  `launchctl print` fails before bootstrapping.
- **Model vision vs capture.** At scale 0.5 a 1080p menu bar is ~12 px tall and the model refuses
  to read it (correctly). Default is now scale 1.0; for text, crop with `region` at `scale: 2`.
- `/tmp` is `/private/tmp` — `exec` reports resolved paths.
- `zsh -f` is deliberate: the user's `.zshenv` sources a RAID-path `.cargo/env` that fails
  under launchd. Callers get a clean shell; set `env` explicitly if they need PATH additions.
- **A LaunchAgent cannot read external volumes without Full Disk Access.** A `cwd` on
  `/Volumes/…` (e.g. a RAID where builds live) does not fail with EPERM — the syscall
  *blocks*, so an un-guarded `exec` would hang to its timeout. Two fixes: `ExecCwd` time-boxes
  a readability probe and returns a clear "grant Full Disk Access to dev.openab.instance-mcp"
  error instead of hanging; and granting FDA to the bundle in System Settings → Privacy &
  Security → Full Disk Access makes the volume readable (verified 2026-09-23: same `ls
  /Volumes/…` went from a 15 s timeout to 39 ms). The grant sticks across re-signing like the
  Screen Recording / Accessibility ones. `exec_start` builds on the RAID work once FDA is granted.
