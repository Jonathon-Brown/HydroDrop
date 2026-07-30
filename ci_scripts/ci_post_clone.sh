#!/bin/sh

# Xcode Cloud runs this immediately after cloning, before it resolves dependencies
# or builds.
#
# HydroDrop.xcodeproj is generated from project.yml by XcodeGen and is deliberately
# gitignored, so a fresh clone has no project for Xcode Cloud to open — that is the
# "Project HydroDrop.xcodeproj does not exist at the root of the repository" failure.
# Generating it here puts the project in place before anything needs to read it.

set -eu

XCODEGEN_VERSION="2.46.0"

# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud. Fall back to this script's parent
# so the script also works when run by hand from a checkout.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

# Homebrew is preinstalled on Xcode Cloud runners but is not always on PATH for a
# non-login shell.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

XCODEGEN=""

# Homebrew first. Downloading the release archive straight from GitHub is the more
# precise option — it pins the version — but Xcode Cloud could not complete a TLS
# handshake with GitHub's asset CDN and curl aborted with exit 35, failing the build.
# Homebrew's CDN is reachable from that environment, and `brew install` is Apple's
# own documented example for a post-clone script.
if command -v brew > /dev/null 2>&1; then
    echo "Installing XcodeGen via Homebrew..."
    if brew install xcodegen; then
        XCODEGEN="$(command -v xcodegen || true)"
    else
        echo "warning: brew install xcodegen failed, trying a direct download" >&2
    fi
else
    echo "warning: Homebrew not found, trying a direct download" >&2
fi

# Kept as a fallback for a runner without Homebrew. This is the path that hit the TLS
# failure, so it is a second chance rather than something to rely on.
if [ -z "$XCODEGEN" ]; then
    STAGING_DIR="${TMPDIR:-/tmp}/xcodegen-${XCODEGEN_VERSION}"
    URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    echo "Downloading XcodeGen ${XCODEGEN_VERSION}..."
    mkdir -p "$STAGING_DIR"
    if curl --fail --silent --show-error --location --retry 3 \
        --output "$STAGING_DIR/xcodegen.zip" "$URL"; then
        unzip -q -o "$STAGING_DIR/xcodegen.zip" -d "$STAGING_DIR"
        # XcodeGen resolves its bundled setting presets relative to the binary, so it
        # has to run from inside the unpacked layout rather than be copied out of it.
        XCODEGEN="$STAGING_DIR/xcodegen/bin/xcodegen"
        chmod +x "$XCODEGEN"
    fi
fi

if [ -z "$XCODEGEN" ] || [ ! -x "$XCODEGEN" ]; then
    echo "error: could not obtain XcodeGen; HydroDrop.xcodeproj cannot be generated" >&2
    exit 1
fi

echo "Using $("$XCODEGEN" --version)"
echo "Generating HydroDrop.xcodeproj from project.yml..."
cd "$REPO_ROOT"
"$XCODEGEN" generate --spec project.yml --project .

# Fail loudly here rather than letting the build fail later with the same opaque
# "does not exist at the root of the repository" message.
if [ ! -d "$REPO_ROOT/HydroDrop.xcodeproj" ]; then
    echo "error: XcodeGen ran but HydroDrop.xcodeproj was not created" >&2
    exit 1
fi

echo "Generated $REPO_ROOT/HydroDrop.xcodeproj"
