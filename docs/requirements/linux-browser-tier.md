# Requirements: Linux managed Playwright tier

> **Status:** accepted design, not implemented as of v0.12.0. Today's Linux behavior is in
> [`docs/linux-setup.md`](../linux-setup.md).

- **Issues:** [#119](https://github.com/openabdev/openab-computer/issues/119), [#118](https://github.com/openabdev/openab-computer/issues/118)
- **ADR:** [`docs/adr/linux-browser-tier.md`](../adr/linux-browser-tier.md) (decisions D1 to D17 are cited below)
- **macOS counterparts:** [`docs/adr/browser-tiers.md`](../adr/browser-tiers.md), [`browser-tiers.md`](browser-tiers.md)

## 1. Requirements

### R1. Managed child

- R1.1 `@playwright/mcp` runs as a stdio child of the daemon. No TCP, UDP or Unix listener exists
  in the managed tree. Port 8794 is not used by the managed path.
- R1.2 The child is started only under a kernel-enforced whole-tree stop mechanism that succeeded in a
  self-test on the host (D4). Otherwise the backend is `unavailable: containment_unverified` and no
  child is started.
- R1.3 After the daemon stops by any route, including `kill -9` and an out-of-memory kill, no
  managed `node`, Chromium or helper process survives.
- R1.4 The stdio client bounds a line at 8 MiB, keeps stdout and stderr apart, bounds stderr, and
  sends `ping` and `notifications/cancelled` on timeout. No secret appears in any log or error.
- R1.5 Restart happens on the next call only, with backoff of 1, 2, 4 up to 30 seconds. After five
  failures in two minutes the backend is `unavailable` until `browser status --retry` or the next
  daemon start. `sandbox_unavailable` and a `profile_locked` with a live holder are setup problems
  and are not retried.
- R1.6 `OAB_BROWSER=off` starts no managed child.

### R2. Downloads and pins

- R2.1 One `pins.json`, schema 2, keyed by `darwin-arm64`, `darwin-x64`, `linux-x64` and
  `linux-arm64`, shared by Swift and Rust, with `conformance/pins_vectors.json` satisfied by both (D1).
- R2.2 Chromium comes from Chrome for Testing wherever it hosts the pinned version, else from the
  pinned Playwright CDN build. The release fails if a platform has neither (D2).
- R2.3 Every download is checked for size and SHA-256 against the manifest embedded in the release
  binary. The binary never fetches pins. The consent text states the download sizes taken from the
  manifest, and never uses the word "safe".
- R2.4 Archives are extracted in two stages by repository code (ADR security notes). A rejected
  archive creates nothing in staging.
- R2.5 `browser install --from-dir <dir>` installs from hand-copied archives and npm tarballs,
  checked against the same digests, with `npm ci --offline`, contacting neither the download hosts
  nor the registry (D17).
- R2.6 The stripped release binary stays under 6 MiB on each architecture (D3).

### R3. Install, update, remove

- R3.1 Install writes to a staging directory, runs a headless health check on a throwaway profile,
  then commits by rename. A failed dependency preflight deletes staging on exit.
- R3.2 Update is prompted, never silent. It installs the new version beside the old one and keeps
  the old one if the health check fails. The previous version is cleaned up later through
  `pending-cleanup.json`.
- R3.3 Remove deletes only what carries the installer's markers and prints "left in place" for
  everything else. It never touches the legacy paths listed in the ADR.
- R3.4 Install, update and remove serialize on `.install.lock`, which is never unlinked.
- R3.5 `browser preflight` lists every missing shared library in one run, with distro package
  hints, and never installs packages. It also reports libc, the glibc floor, the user-namespace
  state, disk needed and free, and seat presence. musl is refused with a clear message (D16).
- R3.6 Without root the installer does everything under the user's home. Root actions are printed
  with the exact command and the reason, and run only with `--apply-system-changes` (D7).

### R4. Router

- R4.1 Managed wins whenever it is installed. External needs `MCP_BROWSER_BACKEND=external`. A stale
  `MCP_UPSTREAM` is ignored with one `browser: external_upstream_ignored` log line and a `sys_info`
  field (D5).
- R4.2 `MCP_BROWSER_BACKEND=external` without an `MCP_UPSTREAM browser=` line is
  `unavailable: external_not_configured`. It does not fall back to managed.
- R4.3 External mode requires a literal loopback host, refuses redirects, returns fixed error
  classes, and checks the listener's owner uid on every connection used, failing closed.
- R4.4 The managed backend lists exactly the 32 catalog names. The external path forwards every
  upstream tool (D15). `observe` sees no `browser_*` tool and `owner` sees all of them.
- R4.5 No call is retried on another backend.

### R5. Seats and sign-in

- R5.1 The browser runs headed when a seat socket exists, else headless. `pw-config.json` records
  the mode, and the daemon rewrites it before every start.
- R5.2 `browser signin` opens a headed window for a one-time sign-in. On a headless seat the user
  drives it through `screenshot`, `mouse` and `key`, or through the documented `wayvnc` recipe (D8).
- R5.3 Chromium always runs with `--password-store=basic`, written by the launch-vector function
  and covered by tests. The docs call it obfuscation, not strong encryption (D11).
- R5.4 A migrated host starts with a fresh profile. The old profile is untouched and listed by
  `browser status` as holding cookies (D9).
- R5.5 Docs state that some sites block automated browsers. They make no claim about any site.

### R6. Units and hosts

- R6.1 `oab-computer.service` keeps `KillMode=process` and loses its `MCP_UPSTREAM` line. The
  installer writes no browser unit. The runtime browser unit is transient and writes nothing to disk.
- R6.2 The browser unit uses the properties listed in the ADR. `RestrictNamespaces`,
  `MemoryDenyWriteExecute`, `SystemCallFilter` and `PrivateDevices` are never set.
- R6.3 An upgrade never touches an existing old browser unit. If one is enabled or active, the
  installer prints a warning with the exact `systemctl --user disable --now <unit>` command. A plain
  stop is not enough, because those units restart at login or boot.
- R6.4 `browser status` reports `legacy_units`, `legacy` paths with sizes, `listeners`,
  `containment`, `external_configured` (yes or no, no URL), and the manifest and install ids. It
  contains no URL, token or page data, and `--json` emits only fixed fields.

### R7. Release

- R7.1 The tarball names stay. The binary embeds the pins. `pw-mcp.sh` ships one more minor release
  marked deprecated, then is removed (D14).
- R7.2 The release job re-downloads every platform artifact, compares size and SHA-256, checks the
  Node digest against Node's published list, checks the Chromium revision, recomputes `minGlibc`
  and the needed libraries, and fails on any difference or missing platform.
- R7.3 Linux tarballs carry build-provenance attestations. The docs give an optional verification
  command and state that it does not make the download safe (D12).
- R7.4 Support follows D16. The docs list which rows are automated and which are a manual run per
  release.

## 2. Cutover runbook

This runbook applies to hosts that run the old external Playwright unit. It is a procedure for a
person, not a PR. Hosts fall into two classes:

- **Class N (new-style unit).** One host runs the browser unit written by the current installer, with
  the `MCP_UPSTREAM` line inside the daemon unit, and data under `~/.local/oab-computer`.
- **Class O (old-style unit).** Three hosts run an older browser unit, with the `MCP_UPSTREAM` line
  in a drop-in under the daemon unit's `.d/` directory, and data under
  `~/.local/oab-instance-mcp/pw-mcp`.

Facts such as which unit is enabled, which profile is in use and how large the old directories are
are collected in step 0, not assumed.

### 2.1 Preconditions

A release containing the managed tier is installed and verified on a throwaway account, covering
manual checks M1 to M4 in the test plan. Class N is cut over first (D13). The class O hosts follow
together after one week of normal use on the class N host with no browser incident.

### 2.2 Steps, per host

0. **Inventory, read-only.** Record the output of `systemctl --user list-units 'oab-*'`, the
   contents of the units and drop-ins, `ss -ltn` for port 8794, the Chromium path in use, `ls -la`
   and `du -sh` of the legacy directories, the glibc version, the architecture,
   `/proc/sys/kernel/apparmor_restrict_unprivileged_userns`, free disk, and whether a seat socket
   exists. Save it to a dated file outside the repository.
1. **Back up by copying, never moving.** Copy the daemon unit, the browser unit, the drop-in,
   `pw-config.json` and the daemon binary (as `oab-computer.prev`) into
   `${XDG_DATA_HOME:-$HOME/.local/share}/oab-computer/backup-<date>/`. That directory is a sibling
   of `playwright/`, never inside it, so the installer never mistakes it for its own data. Do not
   copy the profile (D9).
2. **Install the new binary beside the old one.** Use `install -m 755` to a temporary name and rename
   it into place after step 4 succeeds. The old daemon keeps running on the old binary until step 5.
3. **Preflight.** Run `oab-computer browser preflight`. Resolve what it lists. Install packages, and
   on hosts with the AppArmor restriction load the new path-scoped profile (root, by a person).
4. **Side-by-side install.** Run `oab-computer browser install`. The old unit keeps serving port 8794
   throughout. The health check is headless on a throwaway profile, so it does not conflict with the
   seat or the old profile. Do not continue unless the health check succeeds.
5. **Cutover, in one short window.**
   1. Stop and disable the old browser unit with `systemctl --user disable --now <old unit>`. A plain
      stop would bring the unauthenticated listener back at the next login or boot.
   2. Remove the `MCP_UPSTREAM` line (class N) or the drop-in file (class O). Edit after the backup
      of step 1, and do not delete anything else.
   3. Run `systemctl --user daemon-reload`, then restart `oab-computer.service` on the new binary.
   4. Run `oab-computer browser signin` if a login is needed.
6. **Verify.**
   - The daemon health endpoint answers.
   - The authenticated tool list shows 32 `browser_*` names, and a `browser_navigate` to
     `about:blank` works.
   - `ss -ltnup` shows no listener on 8794 and none owned by the managed tree. `browser status`
     agrees.
   - `sys_info` reports `backend: managed`, the containment mode and the display mode.
   - End the user manager session and log in again, or reboot. Then `systemctl --user is-enabled
     <old unit>` reports `disabled` and `ss -ltn` shows no 8794 listener.

   If any check fails, the host is not cut over. Use the rollback below.
7. **Kill test, once per class.** Run `kill -9` on the daemon. Within the check's time bound, confirm
   that no `node` or Chromium process from the install directory remains and that the restarted
   daemon serves a call.
8. **Soak.** Leave the old unit disabled but not deleted, and the legacy directories in place, for
   one week of normal use with no browser incident.

Differences for class N: the unit to disable is the one the installer wrote, the `MCP_UPSTREAM` line
sits inside the daemon unit (edited, with the backup), and its profile and output directories are
under `~/.local/oab-computer`. Differences for class O: the thing to remove is the drop-in, the old
unit has its own name, and the legacy tree may hold a `node_modules`, a profile with cookies and an
output directory.

### 2.3 Removing leftovers after the soak

The installer never deletes these. A person does, from the list that `browser status` prints with
sizes. Each command is documented in `docs/linux-setup.md` and marked if it needs root.

1. Disable and delete the old unit files, delete the drop-in, run `daemon-reload`.
2. Delete the legacy directories. The old profile holds cookies, so check it first.
3. Delete the old AppArmor profile (root) and the stale `pw-config.json`.

### 2.4 Rollback

At any point before the old units are deleted:

1. Stop the transient browser unit if present, then stop `oab-computer.service`.
2. Optionally run `oab-computer browser remove` to free disk. It does not restore anything by
   itself.
3. Restore the backed-up daemon unit and drop-in, put `oab-computer.prev` back as the binary, and
   run `daemon-reload`.
4. Enable and start the old browser unit with `systemctl --user enable --now`, then start
   `oab-computer.service`.
5. Verify as in step 6, expecting the old behaviour: a listener on 8794 and `backend: external`.

If the new binary stays but the managed tier misbehaves, set `OAB_BROWSER=off` in a drop-in and
restart. On a host that has not reached step 5, that alone is enough. On a host where step 5 already
ran, it is not a return to the external path. External mode needs the `MCP_UPSTREAM=browser=...`
line (removed in step 5) and the old unit (stopped in step 5). Restore both from the backup, add
`MCP_BROWSER_BACKEND=external` as the explicit trust act, start the old unit, and restart the
daemon.

## 3. Test plan

### 3.1 Automated: unit tests (`cargo test --release`, no network, no root, no systemd)

1. **Manifest.** Decode and validate the embedded pins and the shared `pins_vectors.json`. Check the
   embedded `package.json` and lockfile digests, platform selection for all four ids, that consent
   numbers equal manifest numbers, and that the consent text never contains "safe".
2. **Downloader**, against a fake download server on `127.0.0.1:0` in a test thread. Cases: ok,
   size mismatch, digest mismatch, redirect to an allowed host, a disallowed host and `http`,
   truncated body, slow body, and an over-cap `Content-Length`. Loopback `http` is allowed only
   through a test-only constructor. No production flag exists.
3. **Extractor**, with archives built in the test: absolute path, `../`, entry through an earlier
   symlink, escaping symlink, hardlink, device node, setuid mode, duplicate path, oversize, name over
   1024 bytes, NUL name, and a benign Node-shaped tree with internal relative symlinks. Each
   rejection asserts a sentinel file outside staging is unchanged and nothing was created in staging.
4. **State and ownership.** Markers, a foreign or unreadable `install.json`, a symlinked root or data
   directory, staging without a marker, `remove` idempotence, the "left in place" report, lock
   contention, atomic commit, update keeping the old version on a failed health check, and a failed
   dependency preflight deleting staging.
5. **Preflight.** An ELF reader over small generated ELF files (needed list and `GLIBC_` needs), a
   fake `ldconfig -p`, a fake `/etc/os-release`, glibc and musl detection, and the disk calculation.
   All missing sonames appear in one run.
6. **Stdio client**, with a stub child: partial lines, a line over 8 MiB, child exit mid call,
   `ping`, cancellation on timeout, and stdout and stderr never mixed.
7. **Containment**, with a stub that daemonizes a grandchild (`setsid`, new group):
   - Graceful stop kills the grandchild.
   - A helper playing the daemon is killed with `SIGKILL`; the node stub dies through
     `PR_SET_PDEATHSIG`, and a second supervisor's startup sweep kills the detached grandchild whose
     executable is under the fake version directory while a look-alike outside it survives.
   - The thread-versus-process `PR_SET_PDEATHSIG` rule has its own test.
   - CLI children (sign-in and health check, with a detached grandchild) are stopped with `SIGHUP`,
     `SIGTERM` and `SIGKILL`. After the first two nothing survives. After `SIGKILL` the next start's
     sweep removes the survivor, while a live sign-in protected by its run record and a look-alike
     outside the root are left alone.
   - With a test double whose self-test fails, the backend is `unavailable: containment_unverified`
     and nothing is spawned. With one that succeeds, the child starts.
   - The sweep takes `.sweep.lock` without blocking and is skipped, not blocked, while another sweep
     holds it.
8. **Environment in unit mode.** The unit vector begins with `/usr/bin/env -i`, contains no `-E` or
   `--setenv`, and lists exactly the allow-list.
9. **Launch vector.** The rendered arguments and `pw-config.json`, headed and headless, contain
   `--password-store=basic` and never `--no-sandbox`, `--port` or `--host`. A config edited to drop
   the flag is rewritten before the start. The generated docs text contains "obfuscation" and "not
   strong encryption".
10. **Secrets and logs.** Canary strings in tool arguments, stub stderr, stub stdout and `install.json`
    inputs are absent from captured daemon stderr, the data directory and every returned error.
11. **No listener.** With a stub standing in for Playwright, the self-check reports none. A stub that
    binds a TCP, a UDP and a Unix listener makes the check report each.
12. **Router.** Managed beats a stale `MCP_UPSTREAM` unless `MCP_BROWSER_BACKEND=external`. External
    requires a literal loopback host, including `http://[::1]:<port>/mcp`. A 301, 302, 307 or 308 is
    refused and a second listener sees no connection. Errors use fixed classes with a canary in the
    upstream body. A different owner uid and an unreadable table fail closed (the table reader takes
    an injected file). `observe` sees none and `owner` sees all 32.
13. **Offline install.** `browser install --from-dir` against a fake download server and a fake
    registry listener, each of which must see zero connections.
14. **Remove and concurrency.** `remove` with a live run record, remove versus install on the lock
    (never a different inode, and the file still exists afterwards), and the cross-mode profile lock.
15. **Support rules.** `--use-system-chromium` is rejected without a recorded refusal and accepted
    with one. A failed libc check does not count as a refusal.
16. **Existing suites** stay green: `profile_conformance`, `http_conformance`, `wire_conformance`.

### 3.2 Automated: script and pins tests

- `scripts/test-install-linux.sh` is extended, with a fake `HOME` and stubbed `systemctl`, `sudo`,
  `apt-get` and `oab-computer browser`: expected unit text with no browser unit and no
  `MCP_UPSTREAM`; the consent prompt text equals the stub's `plan` output; `--browser none`; the
  non-interactive default (D6); no `sudo` call of any kind without `--apply-system-changes`, and the
  printed commands match what the flag would run (D7); no `8794` in any written file; and an upgrade
  on a host with an enabled old unit prints the warning and leaves the unit unchanged.
- `scripts/test-pw-mcp-check.sh` scans that nothing under `poc/reverse-attach-linux/` and
  `scripts/install-linux.sh` starts Playwright with a port.
- `scripts/test-playwright-pins.py` gains Linux cases: platform keys, `minGlibc` extraction from a
  generated ELF, a missing platform, and a lockfile with an `os`-conditional optional dependency.
- `scripts/check-no-private-identifiers.sh` runs on both documents and on every file this work adds.

### 3.3 Automated: CI jobs

- The offline pins job is unchanged and covers schema 2.
- A **release-time Linux smoke**, as a matrix over Ubuntu 22.04 and 24.04 on amd64 and arm64, and a
  Debian 12 container job that covers install, preflight and the health check up to the containment
  check. Each smoke does a real `browser install` into a temporary `HOME`, a real health check, the
  listener self-check on the live tree, a `kill -9` of the harness and a survivor check.
  - The smoke relaxes the unprivileged-user-namespace restriction on the ephemeral runner only, and
    records that in the log. This is not advice for hosts, where the path-scoped profile is preferred.
  - The job provides the user manager the smoke needs (linger, `user@<uid>.service`, an
    `XDG_RUNTIME_DIR`) and checks `systemctl --user is-system-running` before it starts. If the
    runner cannot provide one, the smoke fails and the release is blocked.
  - It runs on `workflow_dispatch` and as a release requirement, not per PR, because it downloads
    hundreds of MB. It is the Linux form of the macOS no-listener check and blocks a release.
- An optional per-PR systemd job on a runner with a user manager covers transient-unit mode. The
  release smoke does not depend on it.
- A CI check records binary size and `cargo tree` and fails above 6 MiB per architecture.

### 3.4 Manual checklist on real nodes

A person records each result against its check.

| ID | Check |
| --- | --- |
| M1 | amd64 desktop host with a seat: install, consent text, sign-in, restart, session persists. |
| M2 | arm64 desktop host with a seat: the same, plus memory in use (informs `MemoryMax`). |
| M3 | Headless-seat host with the AppArmor restriction: preflight lists the profile, the health check fails without it and succeeds with it, and sign-in works through `screenshot`, `mouse` and `key`. |
| M4 | Each architecture, per release: a full install and run on a Debian 12 host and on Raspberry Pi OS hardware, and the glibc floor against the oldest supported OS. |
| M5 | Transient-unit mode: `kill -9` the daemon, restart it, `systemctl stop`, and reboot. Run `browser signin` over SSH, drop the SSH client, then `kill -9` the CLI, and confirm no survivor after the next child start. Start the daemon by hand outside the unit, `kill -9` it, and confirm unit mode was refused (`daemon_not_unit_main`), no second daemon was pulled in and no browser process exists. |
| M6 | `browser update` with a deliberately broken pin (debug build) keeps the old version. |
| M7 | `browser remove` with an unrelated directory inside the data root: it stays and is reported. |
| M8 | Cutover rehearsal on a spare account for each host class, then rollback. |
| M9 | No listener: `ss -ltnup` and `ss -lxp` during a browser call. |
| M10 | The hosts' real network: the downloads work through each host's actual egress. |

### 3.5 Facts to verify before release

These are expected, not yet measured. A failed check has the stated consequence.

| ID | Question | If it fails |
| --- | --- | --- |
| V1 | Does the generator find a pinned-version Chromium source for each platform? | Pin the Playwright CDN build for that platform. The release is blocked until each platform has a source. |
| V2 | With the pinned `@playwright/mcp` and no `--port`, does the whole tree hold no TCP, UDP or Unix listener, on both architectures? | Release blocker. |
| V3 | Does node exit on stdin EOF, does Chromium exit when node dies, and how long after daemon `SIGKILL`? | Informational. The stop guarantee does not depend on it. |
| V4 | Do `systemd-run --user --pipe`, `BindsTo` on a transient unit and `NoNewPrivileges` work with the AppArmor user-namespace profile, and does `BindsTo` fire when the daemon unit auto-restarts? | If `BindsTo` does not fire, the self-test fails and the tier is unavailable until another mechanism verifies. `NoNewPrivileges` is dropped where it conflicts. |
| V5 | Is the measured `minGlibc` below the oldest supported OS? | Narrow the supported matrix. |
| V6 | Does headed Wayland-native Chromium open on the headless seat and on the other compositor, and does a sign-in survive a restart? | Add `DISPLAY` handling or a URL field to the sign-in flow. |
| V7 | Do cookies stay readable across headed and headless starts with `--password-store=basic`? | Release blocker for the sign-in flow. |
| V8 | Does the pinned Chromium read the managed policy directory, or must a launch flag block the camera and microphone prompt? | Replace the policy file with the flag. |
| V9 | Does the ELF preflight list the same missing libraries as the loader on both architectures? | Rely on the health check classification. |
| V10 | Does the pinned `playwright-core` carry its native-dependency table? | Maintain the hint table in the repository. |
| V11 | Does `ProtectHome=read-only` apply in a user manager on each host class? | Drop the namespace tier on that host and say so in `status`. |
| V12 | Does `/proc/net/tcp` expose the owner uid of another user's listener without elevated rights, with and without `hidepid`? | Fail closed with `listener_owner_unknown`. |
| V13 | Are the `wayvnc` option names in the recipe valid in the release the docs name, and does it refuse a client without credentials? | Fix the recipe, or withdraw it and keep only the existing-tools path. |

## 4. PR split

Size: S under 300 changed lines, M 300 to 1000, L 1000 to 2500, with generated and test code counted
separately where noted. These are estimates.

| PR | Contents | Depends on | Size |
| --- | --- | --- | --- |
| **L0 Shared pins** | Schema 2 with platform keys. Generator and verify extended to Linux artifacts, `minGlibc`, `needed` and package hints. Swift platform id and validation. Id formula. `conformance/pins_vectors.json`. Swift and Python tests. Regenerated Swift constant. No Rust. | D1, D2 | M, plus a large generated JSON |
| **L1a Download and extract** | `manifest.rs`, `download.rs`, `extract.rs`, dependency additions, fake server and hostile-archive tests, the 6 MiB size check. | L0, D3 | L |
| **L1b State and install** | `state.rs`, `install.rs`, `preflight.rs`, ownership markers, lock, update, remove, and the `plan`, `preflight`, `install` (with `--from-dir`), `update`, `remove` and `status` subcommands. | L1a, D16, D17 | L |
| **L2 Managed child and router** | `child.rs`, `stdio_client.rs`, `backend.rs`, the signal handler, process-tree layers, the transient service with `env -i`, run records, the containment self-test and availability check, the CLI-child supervisor, `OAB_BROWSER=off`, the `Upstream` refactor, the external-listener checks, `sys_info` fields and router precedence. | L1b, D4, D5, D15 | L |
| **L3 Installer and docs** | `install-linux.sh` prompts and flags, no browser unit and no `MCP_UPSTREAM`, `test-install-linux.sh`, the generated docs table, `linux-setup.md`, the support declaration, `--apply-system-changes` including the printed linger and `tailscale serve` commands, launch-vector tests, README, parity checklist, and `browser signin`. | L2, D6, D7, D8, D11, D16 | M |
| **L4 Hardening** | Hardening tiers and probes, `status` reporting, the containment self-test fixture and cleanup, and the optional systemd CI job. | L2 | M |
| **L5 Release and cutover** | The release smoke matrix and Debian 12 container job, the per-release manual record, pins verification for all platforms, build-provenance attestation and its documented command, `pw-mcp.sh` marked deprecated, the legacy listing in `status`, and the cutover and rollback document. | L3, L4, D10, D12, D14 | S to M |
| **L6 PID-namespace mechanism** | The PID-namespace supervisor and its self-test for hosts without a user manager. It does not block L5. Until it lands, those hosts have no managed tier. | L2, L4 | M |
| **Cutover** | Section 2, by a person. | L5, D9, D10, D13 | n/a |

L0 can land with no Linux code and is the only PR that touches shipped macOS code. L1a and L1b can be
reviewed by someone who reads only the Rust, L2 by someone who knows the daemon, and L3 and L4 by the
installer owner.
