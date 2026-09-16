#!/usr/bin/env bash
# Syntax-check the packaged tracker and run its Node contract tests.
#
#   scripts/check-tracker.sh
#
# These assets are plain files under Sources/*/Resources, so this runs without
# building anything Swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TRACKER="Sources/CopilotProjectsCore/Resources/tracker"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to check the tracker" >&2
  exit 1
fi
NODE_VERSION="$(node -p 'process.versions.node')"
IFS=. read -r NODE_MAJOR NODE_MINOR _ <<<"$NODE_VERSION"
if (( NODE_MAJOR < 22 || (NODE_MAJOR == 22 && NODE_MINOR < 15) )); then
  echo "error: Node 22.15+ is required for the JavaScript test hooks (found $NODE_VERSION)" >&2
  exit 1
fi

echo "==> node --check on packaged assets"
node --check "$TRACKER/extension.mjs"

echo "==> node --test JSTests"
node --test "JSTests/**/*.test.mjs"
