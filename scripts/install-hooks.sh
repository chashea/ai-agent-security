#!/usr/bin/env bash
# Point git at .githooks/ so contributors pick up pre-commit checks.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
echo "git core.hooksPath -> .githooks"
echo "pre-commit installed. Bypass per-commit with: git commit --no-verify"
