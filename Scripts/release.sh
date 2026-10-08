#!/usr/bin/env bash
#
# HydroDrop release helper. Drives the repeatable half of shipping a build and
# stops before App Review submission, which is always done by hand.
#
#   Scripts/release.sh status                      # version, build, archives on disk
#   Scripts/release.sh bump <build> [version]      # pin CURRENT_PROJECT_VERSION (and MARKETING_VERSION)
#   Scripts/release.sh archive                     # regenerate with the tracked package lock, preflight, archive Release for iOS
#   Scripts/release.sh export                      # signed App Store IPA from that archive
#   Scripts/release.sh upload                      # send it to App Store Connect (TestFlight)
#   DUO_V2=1 Scripts/release.sh archive|export|upload   # the same for a build that ships Duo Streaks
#
# DUO_V2=1 is the one switch for a build with Duo Streaks v2 (decision D5). Without it every
# command does what it did before Duo: Duo is compiled out, and the app signs with
# HydroDrop.entitlements and bundles main's privacy manifest and no camera string (D77);
# export and upload check the IPA has nothing of Duo in it. With it, archive passes
# DUO_V2_CONDITION=DUO_V2 and DUO_ENTITLEMENTS=HydroDrop/HydroDrop.duo.entitlements to
# xcodebuild (and stops below version 2.0, which both Duo servers refuse), and export and
# upload check the IPA has Duo, App Attest as production, the Duo manifest and the camera
# string. Give export and upload the same switch as the archive: both judge the IPA by it,
# and a new archive removes the IPA an earlier one left.
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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCHEME="HydroDrop"
PROJECT="HydroDrop.xcodeproj"
BUILD_DIR="build"
DUO_ENTITLEMENTS_FILE="HydroDrop/HydroDrop.duo.entitlements"
APP_ATTEST_KEY="com.apple.developer.devicecheck.appattest-environment"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
err()   { red "error: $*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
die()   { red "error: $*" >&2; exit 1; }

marketing_version() { grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | grep -oE '"[^"]+"' | tr -d '"'; }
build_number()      { grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | grep -oE '"[0-9]+"' | tr -d '"'; }
team_id()           { grep -E 'DEVELOPMENT_TEAM' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/'; }

# The switch's value, checked once before any command runs: only 1 turns Duo on, and anything
# but 1, 0 or nothing stops the script there, so a typo such as DUO_V2=true never quietly
# archives the build without Duo, and never stops it halfway through a check (which used to
# leave an unzipped IPA behind in a temporary folder).
check_switch_value() {
  case "${DUO_V2:-}" in
    1|0|"") return 0 ;;
    *)      die "DUO_V2 is '${DUO_V2}': set it to 1 for a build with Duo Streaks, or leave it unset" ;;
  esac
}

# Whether this run is for a build with Duo Streaks.
duo_switch() { [[ "${DUO_V2:-}" == 1 ]]; }

# The build settings a Duo archive adds to xcodebuild, in DUO_SETTINGS: an array, expanded
# the way preflight expands UNSHIPPED, so an empty one is nothing under `set -u` on macOS's
# bash 3.2 rather than an unbound variable.
duo_settings() {
  DUO_SETTINGS=()
  if duo_switch; then
    DUO_SETTINGS=(DUO_V2_CONDITION=DUO_V2 "DUO_ENTITLEMENTS=$DUO_ENTITLEMENTS_FILE")
  fi
  return 0
}

# App Attest in a signed app, given its entitlements as `plutil -p` prints them. $2 says what a
# build with Duo must carry: `production` for an exported IPA (the source file says development,
# and signing for the App Store rewrites it, the way it rewrites aps-environment), `any` for the
# archive, which is signed for development. A build without Duo must not carry the key at all:
# it would mean Duo's entitlements were signed into a build that does not have Duo, or that an
# archive made with the switch is being exported or uploaded without it. Returns 1 after saying why.
check_app_attest() {
  if duo_switch; then
    if [[ "${2:-production}" == any ]]; then
      grep -qF "\"$APP_ATTEST_KEY\" => " <<< "$1" \
        || { err "the archive lacks $APP_ATTEST_KEY, which a build with Duo needs — archive with DUO_V2=1"; return 1; }
      green "archive signed with App Attest, as DUO_V2=1 asks"
    else
      grep -qF "\"$APP_ATTEST_KEY\" => \"production\"" <<< "$1" \
        || { err "exported IPA lacks $APP_ATTEST_KEY=production, which a build with Duo needs — check the App ID's App Attest capability and its provisioning profile"; return 1; }
      green "IPA signed with App Attest (production), as DUO_V2=1 asks"
    fi
  else
    if grep -qF "\"$APP_ATTEST_KEY\"" <<< "$1"; then
      err "the app has $APP_ATTEST_KEY, but DUO_V2 is unset — an archive made with DUO_V2=1 is exported and uploaded with DUO_V2=1 too"
      return 1
    fi
    green "no App Attest entitlement (DUO_V2 unset)"
  fi
}

# Every search of a value below reads it from a here-string, never from printf piped to grep -q:
# under pipefail, grep stops at its first match, the writer then dies of SIGPIPE, and the pipeline
# reports a failure, so a match was read as none, now and then (always, for a long value).
# A signed bundle's entitlements as `plutil -p` prints them, or a failure when codesign or plutil
# cannot read them, so an unreadable signature is never taken for one without App Attest.
# (`--entitlements :-` is the form codesign says will stop working.)
entitlements_of() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null
}

# The widget and the Watch app never carry App Attest, whatever the switch: Duo's entitlements
# are the app's alone, and a project-level setting could sign every target with them. $1 = the
# .app. Returns 1 after saying why.
check_extensions_signing() {
  local app=$1 part ents
  for part in "PlugIns/HydroDropWidgets.appex" "Watch/HydroDrop Watch App.app"; do
    ents=$(entitlements_of "$app/$part") || { err "cannot read the entitlements of $part"; return 1; }
    if grep -qF "\"$APP_ATTEST_KEY\"" <<< "$ents"; then
      err "$part is signed with $APP_ATTEST_KEY, which only the app may carry"
      return 1
    fi
  done
  green "the widget and the Watch app carry no App Attest entitlement"
}

# What a built app holds, whichever way it was signed, against the switch: Duo's code
# (DuoAPIClient, the one class that talks to the server, is in the binary only when Duo is
# compiled in), the three privacy manifests (app, widget, Watch app; recon 06 §5 check 4 and
# compliance §2.2), tracking off in each, the app's collected data types (none without Duo, the
# six of compliance §2.2 with it, decision D77), the camera's purpose string only with Duo, and
# Duo's push words (Localizable.strings) in the app and the Watch app only with Duo, since main's
# bundles have no strings file at all.
# $1 = the .app. Returns 1 after saying why.
check_app_contents() {
  local app=$1 manifest count camera=no part strings
  local with=without want_types=0 want_camera=no
  if duo_switch; then with=with; want_types=6; want_camera=yes; fi
  [[ -f "$app/HydroDrop" ]] || { err "${app##*/} has no HydroDrop binary"; return 1; }
  if grep -qa DuoAPIClient "$app/HydroDrop"; then
    [[ $with == with ]] || { err "the app has Duo Streaks compiled in (DuoAPIClient), but DUO_V2 is unset"; return 1; }
  else
    [[ $with == without ]] || { err "the app has no Duo Streaks (no DuoAPIClient), though DUO_V2=1 asks for it"; return 1; }
  fi
  for manifest in "PrivacyInfo.xcprivacy" "PlugIns/HydroDropWidgets.appex/PrivacyInfo.xcprivacy" \
                  "Watch/HydroDrop Watch App.app/PrivacyInfo.xcprivacy"; do
    [[ -f "$app/$manifest" ]] || { err "the app has no privacy manifest at $manifest"; return 1; }
    [[ "$(plutil -extract NSPrivacyTracking raw -o - "$app/$manifest" 2>/dev/null)" == false ]] \
      || { err "$manifest does not say NSPrivacyTracking false"; return 1; }
  done
  count=$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$app/PrivacyInfo.xcprivacy" 2>/dev/null) || count=0
  [[ "$count" == "$want_types" ]] \
    || { err "the app's privacy manifest declares ${count:-0} collected data type(s); a build $with Duo declares $want_types"; return 1; }
  plutil -extract NSCameraUsageDescription raw -o - "$app/Info.plist" >/dev/null 2>&1 && camera=yes
  [[ $camera == "$want_camera" ]] \
    || { err "the app's Info.plist $([[ $camera == yes ]] && echo has || echo lacks) NSCameraUsageDescription; a build $with Duo $([[ $want_camera == yes ]] && echo has it || echo has none)"; return 1; }
  for part in "" "Watch/HydroDrop Watch App.app/"; do
    strings=no
    { compgen -G "$app/$part*.lproj/Localizable.strings" >/dev/null || [[ -f "$app/${part}Localizable.strings" ]]; } && strings=yes
    [[ $strings == "$want_camera" ]] \
      || { err "${part:-the app/}Localizable.strings is $([[ $strings == yes ]] && echo there || echo missing); a build $with Duo $([[ $want_camera == yes ]] && echo has one || echo has none)"; return 1; }
  done
  green "the app has Duo Streaks $([[ $with == with ]] && echo compiled in || echo compiled out), three privacy manifests that do not track, $count collected type(s), $([[ $camera == yes ]] && echo the || echo no) camera string and $([[ $want_camera == yes ]] && echo Duo\'s || echo no) strings files"
}

# Every check of an exported IPA, in one place: export runs it on the IPA it just made and
# upload on one it finds, so neither sends an IPA these checks refused or one an earlier archive
# left behind. $1 = the IPA. Returns 1 after saying why.
verify_ipa() {
  local ipa=$1 tmp signed rc=0
  [[ -f "$ipa" ]] || { err "no IPA at $ipa"; return 1; }
  tmp=$(mktemp -d)
  if ! unzip -oq "$ipa" -d "$tmp" 2>/dev/null; then
    clear_dir "$tmp"; err "$ipa cannot be unzipped"; return 1
  fi
  # CloudKit sync is driven by silent pushes; without this entitlement builds 15
  # and 16 only synced on launch. Automatic signing should rewrite it to production.
  signed=$(entitlements_of "$tmp/Payload/HydroDrop.app") || signed=""
  if ! grep -q '"aps-environment" => "production"' <<< "$signed"; then
    err "exported IPA lacks aps-environment=production (or its entitlements cannot be read) — check HydroDrop.entitlements"; rc=1
  else
    green "IPA signed with aps-environment=production"
    { check_app_attest "$signed" production && check_extensions_signing "$tmp/Payload/HydroDrop.app" \
        && check_app_contents "$tmp/Payload/HydroDrop.app"; } || rc=1
  fi
  clear_dir "$tmp"
  return $rc
}

# The same for the archive, which the Xcode-account upload exports and sends in one step with
# no IPA left to look at first. $1 = the archive. Returns 1 after saying why.
verify_archive() {
  local app="$1/Products/Applications/HydroDrop.app" signed
  # aps-environment in any form proves the entitlements were read: an unreadable signature used
  # to pass as one without App Attest.
  signed=$(entitlements_of "$app") || signed=""
  grep -qF '"aps-environment" => ' <<< "$signed" \
    || { err "the archive's app lacks aps-environment, or its entitlements cannot be read"; return 1; }
  check_app_attest "$signed" any && check_extensions_signing "$app" && check_app_contents "$app"
}

# A build with Duo links to the Duo Streaks rules and to the privacy page's Duo section, and its
# review notes cite both, so its archive waits for the website: docs/terms.html, a section with
# id="duo" in docs/privacy.html, and nothing there that still says HydroDrop runs no servers
# (stage I review 2). Returns 1 after saying what is missing.
duo_docs_ready() {
  local ready=0
  [[ -f docs/terms.html ]] || { err "docs/terms.html (the Duo Streaks rules) is missing"; ready=1; }
  if [[ ! -f docs/privacy.html ]]; then
    err "docs/privacy.html is missing"; ready=1
  else
    grep -qE "id=[\"']duo[\"']" docs/privacy.html || { err "docs/privacy.html has no Duo Streaks section (id=\"duo\")"; ready=1; }
    if grep -qiE "runs no servers?|no servers? of its own" docs/privacy.html; then
      err "docs/privacy.html still says HydroDrop runs no servers"; ready=1
    fi
  fi
  return $ready
}

# Both Duo servers answer 426 upgrade_required to a write from a client older than 2.0
# (MIN_CLIENT_IOS), so a Duo archive below 2.0 would ship a Duo that can never write.
duo_version_ok() {
  local version major
  version=$(marketing_version); major=${version%%.*}
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 2 ))
}

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
  echo "branch  $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)$([[ -n "$(git status --porcelain)" ]] && echo '  (uncommitted changes)')"
  echo "archives:"
  ls -d "$BUILD_DIR"/HydroDrop-*.xcarchive 2>/dev/null | sed 's/^/  /' || echo "  none"
  for k in HYDRODROP_TEAM_ID ASC_API_KEY_ID ASC_API_ISSUER_ID; do
    printf '  %-18s %s\n' "$k" "$([ -n "${!k:-}" ] && echo set || echo unset)"
  done
  if duo_switch; then
    printf '  %-18s %s\n' DUO_V2 "set: Duo Streaks compiled in, App Attest, the Duo privacy manifest and the camera string (needs version 2.0 or higher)"
  else
    printf '  %-18s %s\n' DUO_V2 "unset: no Duo Streaks, plain entitlements, main's privacy manifest, no camera string"
  fi
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

# The tracked lock is what a commit pins, and what Xcode Cloud builds with (see
# ci_scripts/ci_post_clone.sh). The generated project's own copy is local state: a
# fresh checkout or worktree resolves packages on its own and can pick newer versions,
# which is how an archive of 1.8 (31) first came out with a new major version of
# Google's consent SDK that build 30 never had. So a release always builds with the
# tracked copy, and says so when the project had resolved something else.
use_tracked_lock() {
  local tracked="Dependencies/Package.resolved"
  local in_project="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  [[ -f "$tracked" ]] || die "$tracked is missing — commit the package lock before releasing"
  if [[ -f "$in_project" ]] && ! cmp -s "$tracked" "$in_project"; then
    red "the generated project had resolved different package versions; building with the tracked lock instead:"
    diff <(grep -E '"(identity|version)"' "$in_project") <(grep -E '"(identity|version)"' "$tracked") | sed 's/^/  /' || true
  fi
  mkdir -p "$(dirname "$in_project")"
  cp "$tracked" "$in_project"
}

cmd_archive() {
  duo_settings
  if duo_switch; then
    [[ -f "$DUO_ENTITLEMENTS_FILE" ]] || die "$DUO_ENTITLEMENTS_FILE is missing, and a build with Duo signs with it"
    duo_version_ok || die "a build with Duo Streaks needs MARKETING_VERSION 2.0 or higher, and this is $(marketing_version): both Duo servers answer 426 to an older client, so its Duo could never write"
    duo_docs_ready || die "a build with Duo Streaks needs the website's Duo pages first (see above)"
  fi
  echo "== regenerate project =="
  sh Scripts/generate.sh
  use_tracked_lock
  # Given this checkout's path: on its own, preflight checks ~/Developer/HydroDrop,
  # which from a worktree is some other branch entirely.
  echo "== preflight =="
  bash Scripts/preflight.sh "$REPO" || die "preflight failed — fix the failures above, do not archive over them"
  local archive; archive="$(archive_path)"
  clear_dir "$archive"
  # The IPA an earlier archive of this version and build exported belongs to that archive, which
  # may have been made the other way round, so a new archive removes it and upload exports afresh.
  clear_dir "$(export_dir)"
  echo "== archive $(marketing_version) ($(build_number))$(duo_switch && echo ' with Duo Streaks (DUO_V2=1)') =="
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -onlyUsePackageVersionsFromResolvedFile \
    -allowProvisioningUpdates ${DUO_SETTINGS[@]+"${DUO_SETTINGS[@]}"} archive -quiet
  # A "Generic Xcode Archive" has no ApplicationProperties and cannot be uploaded.
  # It means SKIP_INSTALL / INSTALL_PATH are wrong on a target; fix project.yml.
  plutil -extract ApplicationProperties xml1 -o /dev/null "$archive/Info.plist" \
    || die "archive has no ApplicationProperties (Generic Xcode Archive) — check SKIP_INSTALL/INSTALL_PATH in project.yml"
  [[ -d "$archive/Products/Applications/HydroDrop.app/Watch/HydroDrop Watch App.app" ]] \
    || die "Watch app missing from the archive"
  local v b
  v=$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$archive/Info.plist")
  b=$(plutil -extract ApplicationProperties.CFBundleVersion raw "$archive/Info.plist")
  verify_archive "$archive" || die "the archive at $archive is not what DUO_V2 asks for (see above)"
  green "archived $v ($b) with Watch app at $archive"
  if duo_switch; then
    yellow "by hand before this build goes out: compliance 1.8 keeps TM1 and the 24-hour lines off docs/terms.html until the admin Worker is live; confirm the admin Worker is deployed for the API this build talks to (api.hydrodrop.us for a Release build)"
  fi
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
  if ! verify_ipa "$out/HydroDrop.ipa"; then
    clear_dir "$out"
    die "export refused the IPA and removed $out, so upload cannot send it"
  fi
  green "exported $out/HydroDrop.ipa"
}

cmd_upload() {
  local archive; archive="$(archive_path)"
  [[ -d "$archive" ]] || die "no archive at $archive — run 'release.sh archive' first"
  echo "== upload $(marketing_version) ($(build_number)) =="
  local log; log=$(mktemp)
  if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    local ipa; ipa="$(export_dir)/HydroDrop.ipa"
    if [[ -f "$ipa" ]]; then
      echo "== checking the IPA already exported =="
      verify_ipa "$ipa" || { clear_dir "$(export_dir)"; die "the IPA at $ipa fails the export checks, so it was removed and nothing was sent"; }
    else
      cmd_export
    fi
    echo "using App Store Connect API key $ASC_API_KEY_ID"
    xcrun altool --upload-app -f "$ipa" -t ios \
      --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID" 2>&1 | tee "$log" || true
  else
    echo "ASC_API_KEY_ID / ASC_API_ISSUER_ID unset — uploading with the Apple ID signed in to Xcode"
    verify_archive "$archive" || die "the archive at $archive is not what DUO_V2 asks for (see above), so nothing was sent"
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

# Run as a command; a test sources this file for its functions and runs none of them.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  check_switch_value
  case "${1:-}" in
    status)  cmd_status ;;
    bump)    shift; cmd_bump "$@" ;;
    archive) cmd_archive ;;
    export)  cmd_export ;;
    upload)  cmd_upload ;;
    *) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
fi
