#!/usr/bin/env bash
#
# HydroDrop release helper. Drives the repeatable half of shipping a build and
# stops before App Review submission, which is always done by hand.
#
#   Scripts/release.sh status                      # version, build, archives on disk
#   Scripts/release.sh bump <build> [version]      # pin CURRENT_PROJECT_VERSION (and MARKETING_VERSION)
#   Scripts/release.sh archive                     # preflight, regenerate, archive Release for iOS
#   Scripts/release.sh export                      # signed App Store IPA from that archive
#   Scripts/release.sh upload                      # send it to App Store Connect (TestFlight)
#
# Upload uses the App Store Connect API key when ASC_API_KEY_ID and
# ASC_API_ISSUER_ID are set (the .p8 must be in ~/.appstoreconnect/private_keys),
# and otherwise the Apple ID signed in to Xcode, which is how 1.0.1 build 17 went up.
#
# Version rules App Store Connect enforces, learned the hard way:
#   - build numbers only go up, across every version
#   - once a version is approved its train is closed; the next upload needs a
#     higher MARKETING_VERSION, not just a higher build

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

SCHEME="HydroDrop"
PROJECT="HydroDrop.xcodeproj"
BUILD_DIR="build"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
die()   { red "error: $*" >&2; exit 1; }

marketing_version() { grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | grep -oE '"[^"]+"' | tr -d '"'; }
build_number()      { grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | grep -oE '"[0-9]+"' | tr -d '"'; }
team_id()           { grep -E 'DEVELOPMENT_TEAM' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/'; }

archive_path() { echo "$BUILD_DIR/HydroDrop-$(marketing_version)-$(build_number).xcarchive"; }
export_dir()   { echo "$BUILD_DIR/export-$(marketing_version)-$(build_number)"; }

# Everything this script produces lives under build/, which is gitignored.
clear_dir() { [[ -e "$1" ]] && rm -r -- "$1"; return 0; }

write_options() {
  # $1 = path, $2 = destination (export|upload)
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$2</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$(team_id)</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}

cmd_status() {
  echo "version $(marketing_version) build $(build_number)  team $(team_id)"
  echo "branch  $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)$(git status --porcelain | grep -q . && echo '  (uncommitted changes)')"
  echo "archives:"
  ls -d "$BUILD_DIR"/HydroDrop-*.xcarchive 2>/dev/null | sed 's/^/  /' || echo "  none"
  for k in HYDRODROP_TEAM_ID ASC_API_KEY_ID ASC_API_ISSUER_ID; do
    printf '  %-18s %s\n' "$k" "$([ -n "${!k:-}" ] && echo set || echo unset)"
  done
}

cmd_bump() {
  local build="${1:-}" version="${2:-}"
  [[ "$build" =~ ^[0-9]+$ ]] || die "usage: release.sh bump <build-number> [marketing-version]"
  local current; current="$(build_number)"
  (( build > current )) || die "build $build is not higher than the current $current — build numbers only go up"
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"$build\"/" project.yml
  if [[ -n "$version" ]]; then
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "marketing version '$version' should look like 1.0.1"
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$version\"/" project.yml
  fi
  green "project.yml now $(marketing_version) ($(build_number))"
  git --no-pager diff --stat -- project.yml
  echo "Commit this before archiving so the build is reproducible."
}

cmd_archive() {
  echo "== preflight =="
  bash Scripts/preflight.sh || die "preflight failed — fix the failures above, do not archive over them"
  echo "== regenerate project =="
  sh Scripts/generate.sh
  local archive; archive="$(archive_path)"
  clear_dir "$archive"
  echo "== archive $(marketing_version) ($(build_number)) =="
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates archive -quiet
  # A "Generic Xcode Archive" has no ApplicationProperties and cannot be uploaded.
  # It means SKIP_INSTALL / INSTALL_PATH are wrong on a target; fix project.yml.
  plutil -extract ApplicationProperties xml1 -o /dev/null "$archive/Info.plist" \
    || die "archive has no ApplicationProperties (Generic Xcode Archive) — check SKIP_INSTALL/INSTALL_PATH in project.yml"
  [[ -d "$archive/Products/Applications/HydroDrop.app/Watch/HydroDrop Watch App.app" ]] \
    || die "Watch app missing from the archive"
  local v b
  v=$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$archive/Info.plist")
  b=$(plutil -extract ApplicationProperties.CFBundleVersion raw "$archive/Info.plist")
  green "archived $v ($b) with Watch app at $archive"
}

cmd_export() {
  local archive; archive="$(archive_path)"
  [[ -d "$archive" ]] || die "no archive at $archive — run 'release.sh archive' first"
  local out; out="$(export_dir)"
  clear_dir "$out"; mkdir -p "$BUILD_DIR"
  write_options "$BUILD_DIR/ExportOptions-export.plist" export
  echo "== export =="
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions-export.plist" \
    -exportPath "$out" -allowProvisioningUpdates -quiet
  [[ -f "$out/HydroDrop.ipa" ]] || die "export produced no IPA"
  # CloudKit sync is driven by silent pushes; without this entitlement builds 15
  # and 16 only synced on launch. Automatic signing should rewrite it to production.
  local ents; ents=$(mktemp -d)
  unzip -oq "$out/HydroDrop.ipa" -d "$ents"
  local ok=0
  if codesign -d --entitlements :- "$ents/Payload/HydroDrop.app" 2>/dev/null | plutil -p - | grep -q '"aps-environment" => "production"'; then
    ok=1
  fi
  clear_dir "$ents"
  [[ $ok -eq 1 ]] || die "exported IPA lacks aps-environment=production — check HydroDrop.entitlements"
  green "IPA signed with aps-environment=production"
  green "exported $out/HydroDrop.ipa"
}

cmd_upload() {
  local archive; archive="$(archive_path)"
  [[ -d "$archive" ]] || die "no archive at $archive — run 'release.sh archive' first"
  echo "== upload $(marketing_version) ($(build_number)) =="
  local log; log=$(mktemp)
  if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    local ipa; ipa="$(export_dir)/HydroDrop.ipa"
    [[ -f "$ipa" ]] || cmd_export
    echo "using App Store Connect API key $ASC_API_KEY_ID"
    xcrun altool --upload-app -f "$ipa" -t ios \
      --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID" 2>&1 | tee "$log" || true
  else
    echo "ASC_API_KEY_ID / ASC_API_ISSUER_ID unset — uploading with the Apple ID signed in to Xcode"
    write_options "$BUILD_DIR/ExportOptions-upload.plist" upload
    xcodebuild -exportArchive -archivePath "$archive" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions-upload.plist" \
      -exportPath "$BUILD_DIR/upload-$(marketing_version)-$(build_number)" \
      -allowProvisioningUpdates 2>&1 | grep -iE "upload|error|ITMS|fail|Exported" | tee "$log" || true
  fi
  local outcome=fail
  if grep -qiE "train version .* is closed|higher version than that of the previously approved" "$log"; then
    outcome=closed
  elif grep -qiE "Upload succeeded|No errors uploading" "$log"; then
    outcome=ok
  fi
  clear_dir "$log"
  case $outcome in
    closed) die "App Store Connect has already approved $(marketing_version). Bump MARKETING_VERSION (release.sh bump <build> <version>), commit, archive, upload again." ;;
    ok)     green "uploaded $(marketing_version) ($(build_number)) — processing on App Store Connect; verify on TestFlight, do NOT submit for review from here" ;;
    *)      die "upload did not report success — read the output above" ;;
  esac
}

case "${1:-}" in
  status)  cmd_status ;;
  bump)    shift; cmd_bump "$@" ;;
  archive) cmd_archive ;;
  export)  cmd_export ;;
  upload)  cmd_upload ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
