#!/bin/sh
# Regenerate HydroDrop.xcodeproj from project.yml.
#
# Use this rather than calling `xcodegen generate` directly: a bare XcodeGen run
# leaves the schemes pointing at a StoreKit configuration file that does not exist,
# which makes the paywall come up empty with no error. See
# Scripts/patch_scheme_storekit.py for the details.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [ -x "$REPO_ROOT/.tools/xcodegen/bin/xcodegen" ]; then
    XCODEGEN="$REPO_ROOT/.tools/xcodegen/bin/xcodegen"
elif command -v xcodegen > /dev/null 2>&1; then
    XCODEGEN="$(command -v xcodegen)"
else
    echo "error: xcodegen not found (expected .tools/xcodegen/bin/xcodegen or on PATH)" >&2
    exit 1
fi

"$XCODEGEN" generate --spec project.yml
python3 "$REPO_ROOT/Scripts/patch_scheme_storekit.py" "$REPO_ROOT"
