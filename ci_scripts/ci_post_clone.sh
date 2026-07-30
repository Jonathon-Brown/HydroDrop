#!/bin/sh

# Xcode Cloud runs this immediately after cloning, before it resolves dependencies
# or builds.
#
# HydroDrop.xcodeproj is generated from project.yml by XcodeGen and is deliberately
# gitignored, so a fresh clone has no project for Xcode Cloud to open — that is the
# "Project HydroDrop.xcodeproj does not exist at the root of the repository" failure.
# Generating it here puts the project in place before anything needs to read it.
#
# The version is pinned rather than installed from Homebrew: XcodeGen decides how the
# project is laid out, so an unpinned upgrade could quietly change what Xcode Cloud
# archives without a single line of this repository changing.

set -eu

XCODEGEN_VERSION="2.46.0"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
STAGING_DIR="${TMPDIR:-/tmp}/xcodegen-${XCODEGEN_VERSION}"

# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud. Fall back to this script's parent
# so the script also works when run by hand from a checkout.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "Installing XcodeGen ${XCODEGEN_VERSION}..."
mkdir -p "$STAGING_DIR"
curl --fail --silent --show-error --location \
    --output "$STAGING_DIR/xcodegen.zip" "$XCODEGEN_URL"
unzip -q -o "$STAGING_DIR/xcodegen.zip" -d "$STAGING_DIR"

# XcodeGen resolves its bundled setting presets relative to the binary, so it has to
# be run from inside the unpacked layout rather than copied out of it.
XCODEGEN="$STAGING_DIR/xcodegen/bin/xcodegen"
chmod +x "$XCODEGEN"

echo "Generating HydroDrop.xcodeproj from project.yml..."
cd "$REPO_ROOT"
"$XCODEGEN" generate --spec project.yml --project .

# Fail loudly here rather than letting the build fail later with the same opaque
# "does not exist at the root of the repository" message.
if [ ! -d "$REPO_ROOT/HydroDrop.xcodeproj" ]; then
    echo "error: XcodeGen ran but HydroDrop.xcodeproj was not created" >&2
    exit 1
fi

echo "Generated $(ls -d "$REPO_ROOT"/HydroDrop.xcodeproj)"
