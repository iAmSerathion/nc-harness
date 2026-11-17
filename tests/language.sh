#!/usr/bin/env bash
# Language guard: no German in any file of the repo (tests/language.ts). Runs on Linux and macOS (bash 3.2).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
export PATH="$BUN_DIR:$PATH"
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0   # no Bun cache anywhere
command -v bun > /dev/null || { echo "FAIL: bun not on the test PATH" >&2; exit 1; }

cd "$REPO"
exec bun --no-env-file "$REPO/tests/language.ts"
