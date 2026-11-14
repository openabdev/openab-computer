#!/bin/bash
# Print the release version: `let version = "MAJOR.MINOR.PATCH"` in main.swift, the only
# version source. With a tag argument, also require the tag to equal "v<version>" exactly.
# Used by both release jobs and by PR CI, so they apply one rule (#74).
# Usage: release-version.sh [tag]
# RELEASE_VERSION_SOURCE overrides the source file (tests only).
set -euo pipefail

SRC="${RELEASE_VERSION_SOURCE:-$(cd "$(dirname "$0")/.." && pwd)/Sources/oab-computer/main.swift}"
[ -f "$SRC" ] || { echo "release-version: $SRC not found" >&2; exit 66; }
N=$(grep -c '^let version = "[^"]*"$' "$SRC" || true)
[ "$N" = 1 ] || { echo "release-version: expected one 'let version = \"…\"' line in $SRC, found $N" >&2; exit 65; }
V=$(sed -n 's/^let version = "\([^"]*\)"$/\1/p' "$SRC")
printf '%s\n' "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "release-version: '$V' is not MAJOR.MINOR.PATCH" >&2; exit 65; }
if [ $# -gt 0 ] && [ "$1" != "v$V" ]; then
  echo "release-version: tag $1 does not match the binary version source ($V)" >&2; exit 65
fi
printf '%s\n' "$V"
