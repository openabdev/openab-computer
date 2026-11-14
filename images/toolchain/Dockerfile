# oab-toolchain — the sandbox image for the sandbox adapter (docs/adr/sandbox-adapter.md)
#
# Contains the fat toolchain that stays OUT of agent images: python, node,
# git, gh. Sandboxes are created from this image by the OrbStack adapter
# (Phase 1) via:
#
#   docker run -d --network oab-sandbox --cpus <n> --memory <m> \
#     --pids-limit <p> --security-opt no-new-privileges \
#     oab-toolchain sleep infinity
#
# Build (multi-arch; arm64 first-class — Mac mini / Pi, amd64 for Intel nodes):
#
#   docker buildx build --platform linux/arm64,linux/amd64 -t oab-toolchain images/toolchain
#
# Conventions the adapters depend on (see ADR "Sandbox constraints" and
# the OrbStack adapter mapping):
# - /var/log/oab-jobs/    exec_start output files (<job_id>.out / .err)
# - /workspace            default cwd for sandbox_exec
# - non-root user `sandbox` (uid 1000); no sudo, no setuid helpers
# - NO credentials baked in: tokens are injected per-session via
#   sandbox_exec env (see ADR "Sandbox constraints" and "Auth changes")
#
# Trust anchors (audit before trusting a rebuild):
# - Base image pinned by multi-arch manifest-list digest (covers arm64+amd64).
#   Bump: `docker buildx imagetools inspect debian:bookworm-slim` and update
#   the digest below after the smoke test passes.
# - NodeSource apt key: https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
#   (key ID 2F59B5F99B1BE0B4). Verify:
#   gpg --show-keys --with-fingerprint /etc/apt/keyrings/nodesource.gpg
# - GitHub CLI apt key: https://cli.github.com/packages/githubcli-archive-keyring.gpg
#   Current fingerprint is published in the official install docs
#   (https://github.com/cli/cli/blob/trunk/docs/install_linux.md — the key
#   was rotated in 2026, so verify against docs, not cached values):
#   gpg --show-keys --with-fingerprint /etc/apt/keyrings/githubcli-archive-keyring.gpg

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

LABEL org.opencontainers.image.source="https://github.com/openabdev/openab-computer" \
      org.opencontainers.image.title="oab-toolchain" \
      org.opencontainers.image.description="Sandbox toolchain image for the sandbox adapter (docs/adr/sandbox-adapter.md)" \
      org.opencontainers.image.base.name="docker.io/library/debian:bookworm-slim"

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=1

# Base toolchain: python, node (NodeSource, keyring-verified apt source —
# no pipe-to-bash), git, gh, and the small utilities coding agents
# habitually need. One layer, cleaned.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
         | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
         > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        nodejs \
        gh \
        python3 python3-pip python3-venv \
        git \
        jq ripgrep unzip zip less procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root sandbox user; job-output dir owned by it (adapter contract path).
RUN useradd -m -u 1000 -s /bin/bash sandbox \
    && mkdir -p /var/log/oab-jobs /workspace \
    && chown sandbox:sandbox /var/log/oab-jobs /workspace

USER sandbox
WORKDIR /workspace

# The adapter starts sandboxes with an explicit `sleep infinity`; CMD is a
# fallback for manual `docker run`.
CMD ["sleep", "infinity"]
