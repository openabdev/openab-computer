# Linux release record, VERSION

Copy this file to `docs/release-records/linux-VERSION.md` (VERSION without the leading `v`), fill it
in against the release candidate, and commit it to `main` **before** the tag. The `record` job of
`.github/workflows/linux-release-smoke.yml` runs `scripts/check-release-record.sh VERSION` and
fails a release when the file is missing, when any table row still holds the placeholder
`PENDING`, when the `V2` or `D7` row is missing or says `open, owner decision pending`, or when a
blocking gate row is not `pass` (or `n/a` with a reason).

Rules for the person filling it in:

- Replace every `PENDING` with a result. Write `n/a` and the reason when a row does not apply; never
  delete a row.
  A gate row whose Blocking cell says `yes` (V1, V2, V7) must read `pass`, or `n/a, reason`; `fail` or
  anything else fails the record check.
- Record what you ran and saw. No host names, tailnet names, addresses, logins or tokens: name a host
  by class ("amd64 desktop", "arm64 desktop", "headless-seat host").
- The `V2` and `D7` rows record decisions the owner made ([the ADR](../adr/linux-browser-tier.md)).
  Never remove those rows, and never change them to say the decision is open again without the owner.
  The `V2` result still needs the measurement: quote the `GATE V2 pass` line of each architecture.
- This record is the manual half of "Tested" (ADR D16, requirement R7.4). The automated half is the
  smoke run linked below.

## Release

| Field | Value |
| --- | --- |
| Version | PENDING |
| Commit | PENDING |
| Date | PENDING |
| Person | PENDING |
| Smoke run URL (`linux-release-smoke.yml`, dispatched on the release candidate) | PENDING |

## Automated smoke cells (section 3.3, from the smoke run above)

| Cell | Result | Notes |
| --- | --- | --- |
| Ubuntu 22.04 amd64 | PENDING | PENDING |
| Ubuntu 22.04 arm64 | PENDING | PENDING |
| Ubuntu 24.04 amd64 | PENDING | PENDING |
| Ubuntu 24.04 arm64 | PENDING | PENDING |
| Debian 12 container amd64 | PENDING | PENDING |
| Debian 12 container arm64 | PENDING | PENDING |

## Manual checks (section 3.4, M1 to M10)

| Check | Result | Date | Host class | Notes |
| --- | --- | --- | --- | --- |
| M1 amd64 desktop host with a seat: install, consent text, sign-in, restart, session persists | PENDING | PENDING | PENDING | PENDING |
| M2 arm64 desktop host with a seat: the same, plus memory in use | PENDING | PENDING | PENDING | PENDING |
| M3 Headless-seat host with the AppArmor restriction: profile listed, health check fails without it and succeeds with it, sign-in through `screenshot`, `mouse` and `key` | PENDING | PENDING | PENDING | PENDING |
| M4 Each architecture: full install and run on a Debian 12 host and on Raspberry Pi OS hardware, glibc floor against the oldest supported OS | PENDING | PENDING | PENDING | PENDING |
| M5 Transient-unit mode: `kill -9` the daemon, restart, `systemctl stop`, reboot; `browser signin` over SSH and `kill -9` the CLI; a hand-started daemon is refused (`daemon_not_unit_main`) | PENDING | PENDING | PENDING | PENDING |
| M6 `browser update` with a deliberately broken pin (debug build) keeps the old version | PENDING | PENDING | PENDING | PENDING |
| M7 `browser remove` with an unrelated directory inside the data root: it stays and is reported | PENDING | PENDING | PENDING | PENDING |
| M8 Cutover rehearsal on a spare account for each host class, then rollback | PENDING | PENDING | PENDING | PENDING |
| M9 No TCP or UDP listener, and any Unix listener inside the private per-run `TMPDIR` (V2): `ss -ltnup` and `ss -lxp` during a browser call | PENDING | PENDING | PENDING | PENDING |
| M10 The hosts' real network: the downloads work through each host's actual egress | PENDING | PENDING | PENDING | PENDING |

The wording of each check is in section 3.4 of
[the requirements](../requirements/linux-browser-tier.md); that text wins over the short names here.

## Release gates (section 3.5, V1 to V13)

"Blocking" is what section 3.5 says, not a choice made here. V2 and D7 are the two owner decisions, both decided.

| Gate | Result | Evidence | Blocking |
| --- | --- | --- | --- |
| V1 each platform has a pinned-version Chromium source | PENDING | PENDING | yes |
| V2 no TCP or UDP listener, Unix listeners only inside the private `TMPDIR`, on both architectures | PENDING | the smoke's `GATE V2 pass` line for amd64 and for arm64 | yes |
| V3 stdin EOF and Chromium exit timing after daemon `SIGKILL` | PENDING | the smoke's `GATE V3` line | no (informational) |
| V4 `systemd-run --user --pipe`, `BindsTo`, `NoNewPrivileges` with AppArmor | PENDING | the smoke's `GATE V4` line | no (the tier is unavailable if `BindsTo` does not fire; the smoke cell still fails) |
| V5 `minGlibc` below the oldest supported OS | PENDING | PENDING | no (narrow the matrix) |
| V6 headed Wayland Chromium, sign-in survives a restart | PENDING | PENDING | no (doc fix) |
| V7 cookies readable headed and headless with `--password-store=basic` | PENDING | PENDING | yes (for sign-in) |
| V8 policy directory against a launch flag | PENDING | PENDING | no |
| V9 ELF preflight against the loader | PENDING | the smoke's `GATE V9` line | no |
| V10 `playwright-core` native dependency table | PENDING | PENDING | no |
| V11 `ProtectHome=read-only` in a user manager | PENDING | the smoke's `GATE V11` line | no (drop the namespace tier) |
| V12 `/proc/net/tcp` owner uid | PENDING | PENDING | no (fail closed) |
| V13 `wayvnc` options | PENDING | PENDING | no |
| D7 AppArmor profile: the single path-scoped glob profile is kept (decided; residual risk in the ADR) | decided, glob kept | M3 above is the evidence | no |

## Support table rows to update (ADR D16)

| Row of the supported-systems table in `docs/linux-setup.md` | Automated check | Manual run |
| --- | --- | --- |
| Debian 12 | PENDING | PENDING |
| Raspberry Pi OS | PENDING | PENDING |
| Ubuntu 22.04 | PENDING | PENDING |
| Ubuntu 24.04 | PENDING | PENDING |
