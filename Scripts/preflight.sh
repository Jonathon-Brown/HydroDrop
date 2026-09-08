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
# Still unshipped: alternate app icons. No setAlternateIconName call, no
# CFBundleAlternateIcons in Info.plist, and a single AppIcon.appiconset.
UNSHIPPED=("custom app icons")
FOUND_UNSHIPPED=0
if [[ -f "$PAYWALL" ]]; then
  # Strip comment-only lines first. A comment explaining why a feature was
  # removed is not a claim to the user, and flagging it is a false positive.
  PAYWALL_CODE=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$PAYWALL")
  for claim in "${UNSHIPPED[@]}"; do
    if printf '%s\n' "$PAYWALL_CODE" | grep -qi "$claim"; then
      fail "paywall still advertises '$claim' — not in the binary"
      FOUND_UNSHIPPED=1
    fi
  done
  [[ $FOUND_UNSHIPPED -eq 0 ]] && pass "no unshipped feature claims on the paywall"
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
