#!/usr/bin/env bash
# Run before publishing docs/. Findings are redacted; this never deploys anything.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$REPO_DIR/Scripts/check_website.py"
python3 -B "$REPO_DIR/Scripts/test_website_checks.py"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "Install Gitleaks first (brew install gitleaks). Secret scan is required." >&2
  exit 1
fi
gitleaks dir "$REPO_DIR/docs" --redact=100 --no-banner
gitleaks git "$REPO_DIR" --log-opts='--all -- docs' --redact=100 --no-banner
