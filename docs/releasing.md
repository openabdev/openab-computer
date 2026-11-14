# Releasing oab-computer for macOS

A release is a **universal (arm64 + x86_64), Developer-ID-signed and Apple-notarized** app plus a
signed/notarized installer package. The package is the normal download; the app zip is for advanced
users and inspection.

## Artifacts

A `vMAJOR.MINOR.PATCH` tag publishes a GitHub Release titled `oab-computer VERSION` with:

| Artifact | Use |
|---|---|
| `oab-computer-VERSION-universal.pkg` | Recommended. Double-click; installs/configures the app for the logged-in desktop user |
| `oab-computer-VERSION-universal.app.zip` | Pre-signed app, no package receipt. Contains `Contents/Resources/install-prebuilt.sh` for manual installation |
| `SHA256SUMS` | SHA-256 of both artifacts |

Since 0.12.0 the asset names (`oab-computer-VERSION-*`), the binary, the bundle id and the install
paths all use `oab-computer` (up to 0.11 they were `oab-instance-mcp`).

The installer:

1. verifies bundle id, code signature and team `6LPQNY95AQ` **before** stopping the running service;
2. detects the current Tailscale login and MagicDNS name from structured `tailscale status --json`;
3. installs to `~/.local/oab-computer/oab-computer.app` without re-signing it;
4. creates a bearer token once at `~/.config/oab-computer/token`, mode 600, and preserves it on updates. A 0.11 token at
   `~/.config/oab-instance-mcp/token` is copied (cp, never mv; the old file stays in place) by these rules:
   - macOS: only when this run creates the directory `~/.config/oab-computer`. If that directory already exists nothing is copied,
     and a new token is generated only if the new token file does not exist. `FirstRunSetup.swift` applies the same one-shot rule.
   - Linux: whenever `~/.config/oab-computer/token` is missing; a token is generated only when neither file has one.
   - Either platform: a user who never had an old token gets a new one and must update clients.
5. writes/starts the Aqua-user LaunchAgent `dev.openab.computer`;
6. adds the Playwright upstream when `dev.openab.computer.pw-mcp` is installed; and
7. configures `tailscale serve --https=8444` to loopback port 8795.

A logged-in GUI user and a logged-in Tailscale app are prerequisites. Package scripts run as root,
but immediately enter the console user's GUI bootstrap namespace and drop to that user; no token,
LaunchAgent or config is written to root's home.

## One-time TCC grant

After the first Developer-ID release install, enable **OpenAB Computer** once under System Settings →
Privacy & Security (builds before 0.12.0 used the bundle id `dev.openab.instance-mcp`, so their
entries do not carry over and must be granted again):

- Full Disk Access
- Screen & System Audio Recording
- Accessibility

The first switch from the current Apple Development signature to Developer ID may require that one
re-grant. Every later release carries the same bundle id and Developer ID team, so the grant remains.
Neither the installer nor CI ever ad-hoc re-signs a release app. `install-prebuilt.sh` refuses a wrong
or missing TeamIdentifier before replacing the running app.

## Required GitHub environment and secrets

The workflow uses the `release` environment. Create it with required-reviewer protection if the repo
plan supports that, then add:

| Secret | Value |
|---|---|
| `MACOS_APP_CERT_P12_BASE64` | Base64 of the **Developer ID Application** certificate + private key `.p12` |
| `MACOS_APP_CERT_PASSWORD` | `.p12` export password |
| `MACOS_APP_SIGN_IDENTITY` | Exact common name, e.g. `Developer ID Application: Name (6LPQNY95AQ)` |
| `MACOS_INSTALLER_CERT_P12_BASE64` | Base64 of the **Developer ID Installer** certificate + private key `.p12` |
| `MACOS_INSTALLER_CERT_PASSWORD` | `.p12` export password |
| `MACOS_INSTALLER_SIGN_IDENTITY` | Exact common name, e.g. `Developer ID Installer: Name (6LPQNY95AQ)` |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of an App Store Connect API `.p8` key allowed to notarize |
| `APPLE_NOTARY_KEY_ID` | API key id |
| `APPLE_NOTARY_ISSUER_ID` | API issuer id |

**Use team `6LPQNY95AQ` only.** The machine still contains a deprecated team
`UM92U863A8` Developer ID Application certificate; it must never sign these releases. As of
2026-09-27 there is no Developer ID Application or Installer certificate for `6LPQNY95AQ` on the
build machines and the repository has no Actions secrets, so the first signed tag is intentionally
blocked until those assets are created and installed as secrets.

The tag workflow validates that both identity names are Developer ID identities, verifies the app's
TeamIdentifier is exactly `6LPQNY95AQ`, submits/staples both app and pkg, and runs signature/Gatekeeper
checks before creating the GitHub Release. Signing material lives in an ephemeral keychain and is
deleted in an `always()` cleanup step.

## Cut a release

1. Update `let version = "…"` in `Sources/oab-computer/main.swift` and merge with green CI.
   This is the only version to bump. The Linux binary takes its version from the tag at build
   time (see [Linux version](#linux-version)); do not bump `poc/reverse-attach-linux/Cargo.toml`.
2. Ensure the matching active-team release secrets above exist.
3. Tag the exact main commit and push:

   ```sh
   git tag v0.8.4
   git push origin v0.8.4
   ```

4. The `Release macOS installer` workflow builds/tests, signs, notarizes and publishes the macOS
   artifacts, and (since 0.6.7, named `oab-instance-mcp-VERSION-linux-*` before 0.12.0) `oab-computer-VERSION-linux-{arm64,amd64}.tar.gz` + `.sha256`
   from the same run. All three jobs wait on the `release` environment approval. A manual
   dispatch can retry an existing tag; it is not a way to release an untagged commit, and it
   **must run on the tag ref** — the environment only allows `v*` refs, so a dispatch from
   `main` is rejected before any job starts ("Branch main is not allowed to deploy to release"):

   ```sh
   gh workflow run release.yml --ref v0.12.0 -f tag=v0.12.0
   ```

5. Download both artifacts and verify before installing:

   ```sh
   scripts/verify-release.sh \
     oab-computer-0.12.0-universal.app.zip \
     oab-computer-0.12.0-universal.pkg
   shasum -a 256 -c SHA256SUMS
   ```

6. Install the `.pkg` on a clean/test Mac, verify `sys_info`, and make one reverse-attach call
   before announcing it.

Never move or recreate a tag after an artifact has been published.

**Breaking changes need a migration section in the release notes.** The first release that
contains #59 (two profiles, `observe` and `owner`; `desktop` removed and mapped to `observe`)
must carry the upgrade table and the operator steps from
[`tool-profiles.md` → Upgrading from 0.8.x](tool-profiles.md#upgrading-from-08x-59): what
happens to `desktop` requests, to stored `desktop` grants and to a `switchboard.profile` of
`desktop`, and how to grant `owner` again.

## Linux version

The Linux hands node reports the release version in `sys_info.agent.version` and in MCP
`serverInfo.version` (#74). It is not read from `poc/reverse-attach-linux/Cargo.toml`:

- The release workflow's Linux job checks that the tag equals `let version` in
  `Sources/oab-computer/main.swift`, the same gate as the macOS job, then builds with
  `OAB_RELEASE_VERSION=<tag without v>`, which `option_env!` compiles into the binary.
  Both jobs and PR CI read the version with `scripts/release-version.sh [tag]`, which
  requires one `MAJOR.MINOR.PATCH` line and exact string equality with the tag.
- `smoke.sh` runs with `EXPECT_AGENT_VERSION=<same>` and fails unless both fields report it.
  PR CI does the same with the version read from `main.swift`, then smokes a plain build.
- A build without `OAB_RELEASE_VERSION` (local `cargo build`, `cargo test`) reports
  `<crate version>-dev`, so it can never pass for a release.

## Local/no-secret smoke

CI runs this on every PR:

```sh
swift build
scripts/test-packaging.sh .build/debug/oab-computer
```

It assembles the app, proves unsigned input is rejected by the production installer, exercises the
explicit unsigned test seam in a temporary home, verifies token persistence/LaunchAgent arguments,
builds an unsigned flat pkg, expands it, and checks its payload and postinstall scripts. It never
launches an agent or changes the user's Tailscale serve config.

To build a universal unsigned artifact manually on a Mac:

```sh
swift build -c release --arch arm64 --scratch-path /tmp/imcp-arm64
swift build -c release --arch x86_64 --scratch-path /tmp/imcp-x86_64
lipo -create /tmp/imcp-arm64/release/oab-computer \
             /tmp/imcp-x86_64/release/oab-computer \
             -output /tmp/oab-computer
chmod +x /tmp/oab-computer
scripts/assemble-app.sh /tmp/oab-computer /tmp/oab-computer.app 0.12.0
ALLOW_UNSIGNED=1 scripts/package-pkg.sh /tmp/oab-computer.app /tmp/oab-computer.pkg 0.12.0
```

Unsigned artifacts are testing inputs only; do not install or publish them.
