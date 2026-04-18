#!/usr/bin/env bash
# Point git at .githooks/ so contributors pick up pre-commit + pre-push checks.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
echo "git core.hooksPath -> .githooks"
echo "pre-commit installed. Bypass per-commit with: git commit --no-verify"
echo "pre-push installed (full CI mirror). Bypass with: git push --no-verify"
echo "Skip individual pre-push jobs via env: SKIP_PYTEST=1, SKIP_PESTER=1,"
echo "  SKIP_BICEP=1, SKIP_PSSA=1, SKIP_SMOKE=1"
echo "Opt-in adversarial smoke (requires live AI Gateway + az login):"
echo "  RUN_ADVERSARIAL_SMOKE=1 git push  # asserts 100% jailbreak coverage"
