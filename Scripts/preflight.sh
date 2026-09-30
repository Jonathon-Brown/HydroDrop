#!/usr/bin/env bash
#
# HydroDrop preflight — checks the specific things that caused rejections
# on builds up to 14. Exits non-zero if anything would likely bounce again.
#
# Usage: ./preflight.sh [/path/to/HydroDrop]

set -uo pipefail

REPO="${1:-${HYDRODROP_REPO:-$HOME/Developer/HydroDrop}}"
EXPECTED_TEAM="${HYDRODROP_TEAM_ID:-}"

FAILURES=0
WARNINGS=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
amber() { printf '\033[33m%s\033[0m\n' "$1"; }

fail() { red   "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
warn() { amber "  WARN  $1"; WARNINGS=$((WARNINGS + 1)); }
pass() { green "  ok    $1"; }

if [[ ! -d "$REPO" ]]; then
  red "Repo not found: $REPO"
  echo "Set HYDRODROP_REPO or pass the path as an argument."
  exit 2
fi

cd "$REPO" || exit 2
echo "Preflight for $REPO"
echo

# ---------------------------------------------------------------------------
# 1. Guideline 3.1.2(c) — paywall must show Terms of Use and Privacy Policy
# ---------------------------------------------------------------------------
echo "Paywall legal links (3.1.2(c))"
PAYWALL="HydroDrop/Views/PaywallView.swift"

if [[ ! -f "$PAYWALL" ]]; then
  fail "$PAYWALL not found"
else
  grep -q "Terms of Use" "$PAYWALL" \
    && pass "Terms of Use link present" \
    || fail "no 'Terms of Use' link in PaywallView"

  grep -q "Privacy Policy" "$PAYWALL" \
    && pass "Privacy Policy link present" \
    || fail "no 'Privacy Policy' link in PaywallView"

  # The links must not be nested inside a products-loaded branch — that was
  # the original bug. Crude but effective: legalFooter should be referenced
  # from the main VStack, not from inside a switch case.
  if grep -q "legalFooter" "$PAYWALL"; then
    pass "legalFooter is a separate view (rendered unconditionally)"
  else
    warn "could not find legalFooter — verify links render when products fail to load"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 2. Guideline 2.1(b) — no infinite spinner when products come back empty
# ---------------------------------------------------------------------------
echo "Product load failure handling (2.1(b))"
STORE="HydroDrop/StoreKit/StoreManager.swift"

if [[ ! -f "$STORE" ]]; then
  fail "$STORE not found"
else
  grep -q "ProductLoadState" "$STORE" \
    && pass "ProductLoadState present" \
    || fail "StoreManager has no ProductLoadState — spinner can hang forever"

  grep -q "isEmpty" "$STORE" \
    && pass "empty product array is handled explicitly" \
    || fail "StoreManager does not check for an empty product array"
fi

if [[ -f "$PAYWALL" ]]; then
  grep -q "Try Again" "$PAYWALL" \
    && pass "retry affordance present on failure state" \
    || warn "no 'Try Again' button found on the paywall failure state"
fi
echo

# ---------------------------------------------------------------------------
# 3. Guideline 2.3.1 — paywall must not advertise unshipped features
# ---------------------------------------------------------------------------
echo "Paywall honesty (2.3.1)"
# Features that do NOT ship. Keep this list current — every entry here is a
# claim the paywall must not make.
#
# Confirmed shipping and so removed from this list. All of it ships in build
# 15 — the binary behind the live 1.0 on the App Store:
#   iCloud sync (cloudKitDatabase: .automatic + CloudKit entitlement), streak
#     freeze (StreakFreeze.swift, applied in HomeView, surfaced in
#     SettingsView), 30-day history, streak tracking.
#   mascot skins (MascotSkin.swift: 5 authored skins, charms rendered in
#     MascotView.charmBackdrop/charmFill/charmForeground, gated via
#     AppSettings.activeMascotSkin, picker in SettingsView); pace-aware
#     reminders (ReminderManager slot suppression on expectedFraction, fed
#     live intake from HomeView, gated via AppSettings.smartRemindersActive).
#     Both "pace-aware" and "Smart, pace" dropped — same shipping feature.
#
# These last two were previously filed here under "build 16". That was wrong:
# build 16 changes only CURRENT_PROJECT_VERSION and adds this script, so its
# HydroDrop/ tree is identical to build 15's and it ships nothing new.
#
# Alternate app icons shipped in 1.1: one AppIcon-<Skin>.appiconset per paid
# skin, registered via ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES and switched
# by AppIconManager.
#
# The paywall must not promise any of these yet. The two duo lines are for a
# feature taken out of the app in 1.8, so they must never be claimed. Workout-aware
# suggestions haven't been seen working on hardware. The rest are in the app
# (bottle tags and caffeine since 1.7, World decorations and Health insights since
# 1.8) but aren't on the paywall's list. The weekly recap, hot-day suggestions and
# the Live Activity used to sit here too, until each was seen working on a device.
# Remove a line here in the same change that adds it to PaywallView.PlusFeature.all,
# and not before.
UNSHIPPED=(
  "Unlimited bottle tags"
  "Caffeine"
  "More duo streaks"
  "Duo streak widget"
  "World decorations"
  "Health insights"
  "Workout-aware"
)
FOUND_UNSHIPPED=0
if [[ -f "$PAYWALL" ]]; then
  # Strip comment-only lines first. A comment explaining why a feature was
  # removed is not a claim to the user, and flagging it is a false positive.
  PAYWALL_CODE=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$PAYWALL")
  for claim in ${UNSHIPPED[@]+"${UNSHIPPED[@]}"}; do
    if printf '%s\n' "$PAYWALL_CODE" | grep -qi "$claim"; then
      fail "paywall advertises '$claim', which isn't cleared for the paywall yet (see UNSHIPPED)"
      FOUND_UNSHIPPED=1
    fi
  done
  [[ $FOUND_UNSHIPPED -eq 0 ]] && pass "no unshipped feature claims on the paywall"
fi
echo

# ---------------------------------------------------------------------------
# 3b. Ads are non-personalized and the app never asks to track
#
# The privacy manifest says NSPrivacyTracking is false and the privacy page says
# ads are non-personalized. Both stop being true the moment a request is made
# without npa=1, or App Tracking Transparency comes back.
# ---------------------------------------------------------------------------
echo "Ads and tracking"
BARE_REQUESTS=$(grep -rnE '(^|[^A-Za-z.])Request\(\)' HydroDrop --include='*.swift' 2>/dev/null \
  | grep -v 'HydroDrop/Ads/AdManager.swift')
if [[ -n "$BARE_REQUESTS" ]]; then
  fail "an ad request is made outside AdManager.makeRequest(), so it may be personalized:"
  echo "$BARE_REQUESTS" | sed 's/^/          /'
else
  pass "every ad request goes through AdManager.makeRequest()"
fi
if grep -q '"npa": "1"' HydroDrop/Ads/AdManager.swift 2>/dev/null; then
  pass "ad requests ask for non-personalized ads (npa=1)"
else
  fail "AdManager no longer sets npa=1"
fi
if grep -rqE 'AppTrackingTransparency|ATTrackingManager|NSUserTrackingUsageDescription' \
  HydroDrop project.yml --include='*.swift' --include='*.yml' --include='*.plist' 2>/dev/null; then
  fail "App Tracking Transparency is back; the manifest and privacy page say the app never asks to track"
else
  pass "no App Tracking Transparency prompt or usage string"
fi
# The privacy page also says there are no ads, and Google's ad software never starts, in
# the EEA, the UK and Switzerland. That holds only while the SDK starts in exactly one
# place, after AdRegion has said yes, the banner waits for the same answer, and the
# Info.plist keeps the SDK from setting itself up at launch on its own.
SDK_STARTS=$(grep -rn 'MobileAds.shared.start' HydroDrop --include='*.swift' 2>/dev/null)
if [[ $(printf '%s\n' "$SDK_STARTS" | grep -c .) -ne 1 || "$SDK_STARTS" != HydroDrop/Ads/AdManager.swift:* ]] \
  || grep -rqE 'AdManager\.start\(' HydroDrop --include='*.swift' 2>/dev/null; then
  fail "Google's ad SDK must start exactly once, in AdAvailability.decide(), after the region check:"
  echo "$SDK_STARTS" | sed 's/^/          /'
else
  pass "Google's ad SDK starts only in AdAvailability, after the region check"
fi
if grep -qE '^[[:space:]]*GADDelayInitialization:[[:space:]]*true' project.yml 2>/dev/null; then
  pass "the ad SDK doesn't set itself up at launch (GADDelayInitialization)"
else
  fail "project.yml lost GADDelayInitialization, so Google's ad SDK sets itself up at every launch, in the EEA, UK and Switzerland too"
fi
MISSING_REGION=""
for code in GB GBR CH CHE NO NOR IS ISL LI LIE DE DEU FR FRA IE IRL; do
  grep -q "\"$code\"" HydroDrop/Ads/AdRegion.swift 2>/dev/null || MISSING_REGION="$MISSING_REGION $code"
done
if [[ -n "$MISSING_REGION" ]]; then
  fail "AdRegion no longer lists:$MISSING_REGION (the privacy page says there are no ads there)"
else
  pass "AdRegion still covers the EEA, the UK and Switzerland"
fi
if grep -q 'ads.servesAds' HydroDrop/Ads/BannerAdView.swift 2>/dev/null; then
  pass "the banner waits for the region check"
else
  fail "BannerAdView no longer checks AdAvailability.servesAds"
fi
echo

# ---------------------------------------------------------------------------
# 4. Placeholder / prototype strings anywhere in the app
# ---------------------------------------------------------------------------
echo "Placeholder strings"
PLACEHOLDERS=$(grep -rniE '"[^"]*(prototype|coming soon|lorem ipsum|TODO:|placeholder)[^"]*"' \
  HydroDrop --include='*.swift' 2>/dev/null)

if [[ -n "$PLACEHOLDERS" ]]; then
  fail "placeholder text found in user-facing strings:"
  echo "$PLACEHOLDERS" | sed 's/^/          /'
else
  pass "no placeholder strings in Swift sources"
fi
echo

# ---------------------------------------------------------------------------
# 5. App icon must have no alpha channel
# ---------------------------------------------------------------------------
echo "App icon"
ICON="HydroDrop/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

if [[ ! -f "$ICON" ]]; then
  fail "icon-1024.png not found at $ICON"
elif ! command -v sips >/dev/null 2>&1; then
  warn "sips unavailable (not macOS?) — skipping alpha check"
else
  HAS_ALPHA=$(sips -g hasAlpha "$ICON" 2>/dev/null | awk '/hasAlpha/ {print $2}')
  if [[ "$HAS_ALPHA" == "yes" ]]; then
    fail "icon has an alpha channel — App Store will reject it"
    echo "          fix: magick '$ICON' -alpha remove -alpha off '$ICON'"
  else
    pass "icon has no alpha channel"
  fi

  DIMS=$(sips -g pixelWidth -g pixelHeight "$ICON" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd'x' -)
  [[ "$DIMS" == "1024x1024" ]] \
    && pass "icon is 1024x1024" \
    || fail "icon is $DIMS, expected 1024x1024"
fi
echo

# ---------------------------------------------------------------------------
# 6. Signing and versioning
# ---------------------------------------------------------------------------
echo "Project config"
TEAM=$(grep -E 'DEVELOPMENT_TEAM' project.yml 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [[ -z "$TEAM" ]]; then
  fail "DEVELOPMENT_TEAM not set in project.yml"
elif [[ -n "$EXPECTED_TEAM" && "$TEAM" != "$EXPECTED_TEAM" ]]; then
  fail "DEVELOPMENT_TEAM is $TEAM, expected $EXPECTED_TEAM"
else
  pass "DEVELOPMENT_TEAM = $TEAM"
  [[ -z "$EXPECTED_TEAM" ]] && warn "set HYDRODROP_TEAM_ID to have this verified"
fi

# project.yml sets CFBundleVersion to $(CURRENT_PROJECT_VERSION); the pinned number
# lives on the CURRENT_PROJECT_VERSION line itself.
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml 2>/dev/null | grep -oE '"[0-9]+"' | tr -d '"' | head -1)
if [[ -z "$BUILD" ]]; then
  warn "CFBundleVersion is not pinned in project.yml — XcodeGen may reset it"
  PLIST_BUILD=$(plutil -extract CFBundleVersion raw HydroDrop/Info.plist 2>/dev/null)
  [[ -n "$PLIST_BUILD" ]] && echo "          Info.plist currently says: $PLIST_BUILD"
else
  pass "CFBundleVersion pinned at $BUILD"
fi
echo

# ---------------------------------------------------------------------------
# 7. The Swift package lock CI depends on
#
# Xcode Cloud resolves packages with automatic resolution disabled, so it needs a
# Package.resolved from the repository. Xcode only ever writes one inside the generated,
# gitignored HydroDrop.xcodeproj, so the tracked copy in Dependencies/ is what CI gets,
# placed by ci_scripts/ci_post_clone.sh. If a package is bumped locally and that copy is
# not refreshed, CI silently builds the old versions, or stops outright. Catch it here.
# ---------------------------------------------------------------------------
echo "Swift package lock"
TRACKED_LOCK="Dependencies/Package.resolved"
PROJECT_LOCK="HydroDrop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if ! grep -qE '^packages:' project.yml 2>/dev/null; then
  pass "no Swift packages declared, so no lock is needed"
elif [[ ! -f "$TRACKED_LOCK" ]]; then
  fail "$TRACKED_LOCK is missing — Xcode Cloud cannot resolve packages without it"
  echo "          copy $PROJECT_LOCK there and commit it"
elif [[ ! -f "$PROJECT_LOCK" ]]; then
  # A fresh clone that has not been opened in Xcode yet. Nothing to compare against,
  # and the tracked copy is present, which is what CI actually reads.
  pass "tracked lock present (no generated copy to compare against yet)"
elif ! cmp -s "$TRACKED_LOCK" "$PROJECT_LOCK"; then
  fail "$TRACKED_LOCK is stale — Xcode has resolved different package versions"
  echo "          cp \"$PROJECT_LOCK\" \"$TRACKED_LOCK\" && git add $TRACKED_LOCK"
  diff <(grep -E '"(identity|version)"' "$TRACKED_LOCK") \
       <(grep -E '"(identity|version)"' "$PROJECT_LOCK") | sed 's/^/          /' || true
else
  PINS=$(grep -c '"identity"' "$TRACKED_LOCK" 2>/dev/null || echo 0)
  pass "tracked lock matches the resolved project ($PINS package(s))"
fi
echo

# ---------------------------------------------------------------------------
# 8. The CloudKit Production schema
#
# TestFlight and App Store builds sync with CloudKit's Production environment, whose schema
# changes only when the Development schema is deployed to it by hand in CloudKit Console. A
# build whose SwiftData models have a field Production lacks can't export any record that
# sets it, and since 1.9 gives every new drink a healthSyncID, iCloud sync of every new
# drink would stall. So every stored property of every @Model has to be in Production
# before a build is uploaded.
#
# Needs a CloudKit management token in the login keychain, saved once with:
#   xcrun cktool save-token --type management
# HYDRODROP_SKIP_CLOUDKIT_SCHEMA=1 turns a failure to reach CloudKit into a warning, for a
# run with no network or no token. A field that is missing is always a failure.
# ---------------------------------------------------------------------------
echo "CloudKit Production schema"
CK_CONTAINER=$(grep -oE 'iCloud\.[A-Za-z0-9.-]+' HydroDrop/HydroDrop.entitlements 2>/dev/null | head -1)
CK_SCHEMA_ERR=$(mktemp -t hydrodrop-ckschema)
if [[ -z "$TEAM" || -z "$CK_CONTAINER" ]]; then
  fail "could not find the team ID or the iCloud container to check"
elif ! CK_SCHEMA=$(xcrun cktool export-schema --team-id "$TEAM" --container-id "$CK_CONTAINER" --environment production 2>"$CK_SCHEMA_ERR"); then
  CK_REASON=$(head -3 "$CK_SCHEMA_ERR")
  if [[ "${HYDRODROP_SKIP_CLOUDKIT_SCHEMA:-}" == "1" ]]; then
    warn "could not read the Production schema of $CK_CONTAINER (skipped by HYDRODROP_SKIP_CLOUDKIT_SCHEMA)"
  else
    fail "could not read the Production schema of $CK_CONTAINER"
  fi
  [[ -n "$CK_REASON" ]] && echo "$CK_REASON" | sed 's/^/          /'
  echo "          a CloudKit management token is needed once: xcrun cktool save-token --type management"
else
  CK_MISSING=""
  for MODEL_FILE in $(grep -rlE '^@Model' HydroDrop --include='*.swift' 2>/dev/null); do
    MODEL=$(grep -A1 -E '^@Model' "$MODEL_FILE" | grep -oE 'class [A-Za-z0-9_]+' | head -1 | awk '{print $2}')
    [[ -z "$MODEL" ]] && continue
    # The record type's block, from its RECORD TYPE line to the line that closes it.
    CK_BLOCK=$(printf '%s\n' "$CK_SCHEMA" | awk -v type="CD_$MODEL" '
      !inside && $0 ~ ("RECORD TYPE \"?" type "\"?[ (]") { inside = 1 }
      inside { print }
      inside && /\);?[[:space:]]*$/ && $0 !~ /RECORD TYPE/ { inside = 0 }')
    if [[ -z "$CK_BLOCK" ]]; then
      CK_MISSING="$CK_MISSING CD_$MODEL"
      continue
    fi
    # Stored properties only: a `var name: Type` at the class's own indent, with no body.
    # A computed property opens a brace on the same line.
    for FIELD in $(grep -E '^    var [A-Za-z0-9_]+: [^{]+$' "$MODEL_FILE" | sed -E 's/^    var ([A-Za-z0-9_]+):.*/\1/'); do
      printf '%s\n' "$CK_BLOCK" | grep -qE "(^|[^A-Za-z0-9_])\"?CD_${FIELD}\"?[[:space:]]" \
        || CK_MISSING="$CK_MISSING CD_$MODEL.CD_$FIELD"
    done
  done
  if [[ -n "$CK_MISSING" ]]; then
    fail "the Production schema of $CK_CONTAINER is missing:$CK_MISSING"
    echo "          deploy the Development schema to Production in CloudKit Console before uploading"
  else
    pass "every stored property of every @Model is in the Production schema of $CK_CONTAINER"
  fi
fi
rm -f "$CK_SCHEMA_ERR"
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "─────────────────────────────────────────"
if [[ $FAILURES -gt 0 ]]; then
  red "$FAILURES failure(s), $WARNINGS warning(s) — do not archive yet"
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  amber "0 failures, $WARNINGS warning(s) — review before archiving"
  exit 0
else
  green "All checks passed"
  exit 0
fi
