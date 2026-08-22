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
cd "$REPO_ROOT"

# CURRENT_PROJECT_VERSION is committed as a fixed value, and the project is regenerated
# from project.yml on every CI run — so every Xcode Cloud build uploaded the same build
# number, and App Store Connect rejects a duplicate during processing. The build goes
# green here and then never appears in TestFlight. Xcode Cloud's own monotonic counter
# is in CI_BUILD_NUMBER; stamp it in before generating. This edits the runner's checkout
# only, and is a no-op outside Xcode Cloud.
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    echo "Stamping build number ${CI_BUILD_NUMBER} into project.yml..."
    /usr/bin/sed -i '' -E \
        "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"${CI_BUILD_NUMBER}\"/" \
        project.yml
    grep -n "CURRENT_PROJECT_VERSION" project.yml
else
    echo "CI_BUILD_NUMBER not set; leaving the committed build number alone."
fi

echo "Generating HydroDrop.xcodeproj from project.yml..."
"$XCODEGEN" generate --spec project.yml --project .

# Fail loudly here rather than letting the build fail later with the same opaque
# "does not exist at the root of the repository" message.
if [ ! -d "$REPO_ROOT/HydroDrop.xcodeproj" ]; then
    echo "error: XcodeGen ran but HydroDrop.xcodeproj was not created" >&2
    exit 1
fi

# XcodeGen emits StoreKit configuration paths the schemes cannot resolve, and omits
# them from the test action entirely. Repair both before anything opens the project.
python3 "$REPO_ROOT/Scripts/patch_scheme_storekit.py" "$REPO_ROOT"

echo "Generated $REPO_ROOT/HydroDrop.xcodeproj"
