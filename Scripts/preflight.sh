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
# The paywall must not promise any of these yet. "More duo streaks" is for a feature
# taken out of the app in 1.8 and coming back as Duo Streaks v2, so it stays here until
# the release that ships it. "Duo streak widget" used to sit beside it and was taken off
# because the duo widget is free (decision D18): it is not a HydroDrop+ feature waiting
# to ship but one that never is, so it is never a paywall claim. "Duo streak" stands in
# its place, matched in any case like every line here, so no other wording of Duo
# ("Duo Streaks with up to five friends") reaches the paywall before Duo ships either,
# which the one exact phrase above would let through. P7, which ships Duo, decides what
# the paywall may say about it and revisits both lines. Workout-aware
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
  "Duo streak"
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
    # A here-string, not printf piped to grep: under pipefail, grep stopping at its first match
    # can kill the writer with SIGPIPE, and the claim would then be read as absent.
    if grep -qi "$claim" <<< "$PAYWALL_CODE"; then
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
  printf '%s\n' "$BARE_REQUESTS" | cut -d: -f1,2 | sed 's/^/          /; s/$/  (Request() outside AdManager)/'
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
  printf '%s\n' "$SDK_STARTS" | grep . | cut -d: -f1,2 | sed 's/^/          /; s/$/  (MobileAds.shared.start)/'
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
  # The place and the rule only, never the line: a TODO beside a pasted key would print it.
  printf '%s\n' "$PLACEHOLDERS" | cut -d: -f1,2 | sed 's/^/          /; s/$/  (a placeholder string)/'
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
# 9. Duo Streaks
#
# Duo Streaks v2 is the first feature that talks to a server of HydroDrop's own, so the
# tree now holds an address that must live in one place, a second entitlements file that
# adds App Attest, invite links the website has to claim, and a privacy manifest that
# declares what the server keeps. These are checks 1 to 4 of recon 06 §5 (plan P2 items 8
# and 10). Its checks 5 to 8 (the website's claims, ATS, the iCloud Duo's leftovers and
# the reviewer aids) land with P7.
#
# The plist and JSON checks run in Python (python3 ships with Xcode's command-line tools)
# and print one verdict a line, a tab between the verdict (ok, FAIL, WARN, or - for a
# detail) and its text, which duo_relay hands to pass, fail and warn. A finding about a
# secret names the file, the line and the rule, never the text, so this log is never
# where a key leaks.
# ---------------------------------------------------------------------------
echo "Duo Streaks"

duo_relay() {
  local verdict message
  while IFS=$'\t' read -r verdict message; do
    case "$verdict" in
      ok)   pass "$message" ;;
      FAIL) fail "$message" ;;
      WARN) warn "$message" ;;
      -)    echo "          $message" ;;
      "")   ;;
      *)    echo "          $verdict${message:+ $message}" ;;
    esac
  done
}

IFS= read -r -d '' DUO_CHECKS <<'PY' || true
import fnmatch, json, os, plistlib, re, subprocess, sys

check, repo, team = sys.argv[1], sys.argv[2], sys.argv[3]
os.chdir(repo)

def one_line(text):
    """The text with its backslashes, tabs and line breaks written out, so a file name that holds
    them can neither break the relay's lines nor add a verdict of its own."""
    return str(text).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

def say(verdict, text):
    print(f"{verdict}\t{one_line(text)}")

def detail(text):
    print(f"-\t{one_line(text)}")

PLAIN = "HydroDrop/HydroDrop.entitlements"
DUO = "HydroDrop/HydroDrop.duo.entitlements"
APP_ATTEST = "com.apple.developer.devicecheck.appattest-environment"
DOMAINS = "com.apple.developer.associated-domains"

def load_plist(path):
    """The plist, or None after saying why it could not be read."""
    try:
        with open(path, "rb") as handle:
            value = plistlib.load(handle)
    except FileNotFoundError:
        say("FAIL", f"{path} not found")
        return None
    except Exception:
        say("FAIL", f"{path} is not a property list that can be read")
        return None
    if not isinstance(value, dict):
        say("FAIL", f"{path} is not a dictionary")
        return None
    return value

def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None

def without_comments(project):
    """project.yml with its comments blanked: what it says, not what it explains."""
    return "\n".join(re.sub(r"(^|\s)#.*$", "", line) for line in project.split("\n"))

def target_block(project, name):
    """The lines of one target in project.yml, from its name under `targets:` to the next."""
    block, in_targets, inside = [], False, False
    for line in without_comments(project).split("\n"):
        if re.match(r"^\S", line):
            in_targets, inside = line.startswith("targets:"), False
            continue
        if in_targets and re.match(r"^  \S", line):
            inside = re.match(r"^  " + re.escape(name) + r":\s*$", line) is not None
            continue
        if inside:
            block.append(line)
    return block

def target_setting(project, target, key):
    for line in target_block(project, target):
        match = re.match(r"^\s+" + re.escape(key) + r":\s*(.*?)\s*$", line)
        if match:
            return match.group(1).strip('"')
    return None

def app_setting(project, key):
    return target_setting(project, "HydroDrop", key)

def tree_files():
    """What git would commit: tracked files and untracked ones it does not ignore. Outside a
    git checkout, every file on disk but build output."""
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True, text=True).stdout.strip()
        if os.path.realpath(top) != os.path.realpath("."):
            raise ValueError("a folder inside another checkout")
        out = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                             capture_output=True, check=True).stdout
        names = [n for n in out.decode("utf-8", "surrogateescape").split("\0") if n]
    except (OSError, ValueError, subprocess.CalledProcessError):
        names = []
        for directory, subdirs, files in os.walk("."):
            subdirs[:] = [d for d in subdirs if d not in (".git", "build", "DerivedData", ".build", ".tools")
                          and not d.endswith(".xcodeproj")]
            names += [os.path.relpath(os.path.join(directory, f), ".") for f in files]
    return sorted(n for n in names if os.path.isfile(n))

def lines_of(path):
    """A text file's lines; a strings file saved as UTF-16 is read as text, anything else with a
    NUL byte in its first 8 KB as binary (no lines)."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return []
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", "replace").split("\n")
    head = data[:8192]
    if b"\0" in head:
        # UTF-16 with no byte-order mark: ASCII text leaves every other byte zero.
        even, odd = head[0::2], head[1::2]
        if odd and odd.count(0) > 0.9 * len(odd) and even.count(0) < 0.1 * len(even):
            return data.decode("utf-16-le", "replace").split("\n")
        if even and even.count(0) > 0.9 * len(even) and odd.count(0) < 0.1 * len(odd):
            return data.decode("utf-16-be", "replace").split("\n")
        return []
    return data.decode("utf-8", "replace").split("\n")

def logical_lines(lines):
    """(number, text) for each line, a line that ends with a backslash joined to the next, as a
    shell reads it, so a token split across a continued line is still whole."""
    number, joined, start = 0, None, 0
    for number, line in enumerate(lines, start=1):
        text = line.rstrip("\r")
        if joined is None:
            joined, start = "", number
        if text.endswith("\\"):
            joined += text[:-1]
            continue
        yield start, joined + (text.lstrip() if joined else text)
        joined = None
    if joined:
        yield start, joined

def key_text(path):
    """Whether a .key file is a text key with a PEM header, not a Keynote document (a zip)."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(65536)
    except OSError:
        return False
    return not head.startswith(b"PK\x03\x04") and b"\0" not in head and b"-----BEGIN" in head

def yaml_list(block, key):
    """The items of a YAML list under `key` in a target's lines, quotes taken off."""
    items, indent = None, None
    for line in block:
        match = re.match(r"^(\s*)" + re.escape(key) + r":\s*$", line)
        if match and items is None:
            items, indent = [], len(match.group(1))
            continue
        if items is not None:
            if not line.strip():
                continue
            item = re.match(r"^(\s*)-\s*(.*?)\s*$", line)
            if item and len(item.group(1)) >= indent:
                items.append(item.group(2).strip('"\''))
                continue
            if len(line) - len(line.lstrip()) <= indent:
                break
    return items or []

# 9a -------------------------------------------------------------------------------------------
SECRET_FILES = [
    ("a private key (.p8), as Apple's APNs, DeviceCheck and App Store Connect keys are", lambda n: n.endswith(".p8")),
    ("an App Store Connect API key (AuthKey_*)", lambda n: n.startswith("authkey_")),
    ("a Firebase configuration (google-services.json)", lambda n: n == "google-services.json"),
    ("an Android signing keystore", lambda n: n.endswith((".jks", ".keystore"))),
    ("an environment file (.env)", lambda n: n == ".env" or n.startswith(".env.")),
    ("a Wrangler secrets file (.dev.vars)", lambda n: n == ".dev.vars" or n.startswith(".dev.vars.")),
    ("a PEM file", lambda n: n.endswith(".pem")),
    ("a certificate with its private key (.p12, .pfx)", lambda n: n.endswith((".p12", ".pfx"))),
    ("a private key file (.key)", lambda n: n.endswith(".key")),
    ("an SSH private key (id_rsa and the like)",
     lambda n: n.startswith(("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")) and not n.endswith(".pub")),
]
# A .key name is a key only when it holds one: a Keynote document is a .key file too.
NAME_NEEDS_CONTENT = {"a private key file (.key)": key_text}
# The sources and the documents a key could be pasted into, the website under docs/ among them
# (it is public the moment it is pushed).
SOURCE_SUFFIXES = (".swift", ".plist", ".entitlements", ".xcprivacy", ".yml", ".yaml", ".sh", ".py", ".xcconfig",
                   ".json", ".js", ".html", ".md", ".txt", ".strings", ".toml")
# Written so that none of them matches its own text, since this file is read too.
SECRET_TEXT = [
    ("a Bearer token", re.compile(r"Bearer [A-Za-z0-9._~+/=-]{20,}")),
    ("a Stripe live secret key", re.compile(r"(?<![A-Za-z0-9_])sk_l[i]ve_")),
    ("a PEM private key", re.compile(r"-----BEGIN[ A-Z0-9]*PRIVATE KEY-----")),
    ("a PGP private key", re.compile(r"-----BEGIN PGP PRIVATE KEY BL[O]CK-----")),
    ("a Discord webhook URL", re.compile(r"discord(?:app)?\.com/api/webhooks/", re.I)),
    ("a Slack webhook URL", re.compile(r"hooks\.slack\.com/(?:services|workflows|triggers)/", re.I)),
    ("a GitHub token", re.compile(r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})")),
    ("an AWS access key id", re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])")),
    ("a Cloudflare API token or key", re.compile(r"(?:cloudflare|cf)_?api_?(?:token|key)[\"']?\s*[:=]\s*[\"']?[A-Za-z0-9_-]{37,}", re.I)),
]
# Looked for in every text file, whatever it is called.
ANY_FILE_RULES = ("a PEM private key", "a PGP private key")
SERVER_HOME = "HydroDrop/Duo/DuoConfig.swift"
SERVER_HOST = re.compile(r"(?<![A-Za-z0-9.-])api(?:-[A-Za-z0-9]+)*\.hydrodrop\.us\b|\b[A-Za-z0-9-]+\.workers\.dev\b", re.I)
SERVER_SCOPE = ("HydroDrop/", "HydroDropWidgets/", "HydroDrop Watch App/", "HydroCore/Sources/", "Config/")

def check_9a():
    files = tree_files()
    named = [(rel, [rule for rule, test in SECRET_FILES if test(os.path.basename(rel).lower())
                    and NAME_NEEDS_CONTENT.get(rule, lambda path: True)(rel)]) for rel in files]
    named = [(rel, rules) for rel, rules in named if rules]
    if named:
        say("FAIL", f"{len(named)} key or secret file(s) that git would commit:")
        for rel, rules in named:
            detail(f"{rel}  ({'; '.join(rules)})")
    else:
        say("ok", "no key, keystore, certificate, .env, .dev.vars, .key or SSH key file that git would commit")
    hits, read = [], 0
    for rel in files:
        # A PEM or PGP private key is looked for in every text file, whatever it is called; the
        # other rules in the source and document types above.
        rules = SECRET_TEXT if rel.endswith(SOURCE_SUFFIXES) else [r for r in SECRET_TEXT if r[0] in ANY_FILE_RULES]
        lines = lines_of(rel)
        read += 1 if lines and rel.endswith(SOURCE_SUFFIXES) else 0
        for number, line in logical_lines(lines):
            hits += [(rel, number, rule) for rule, pattern in rules if pattern.search(line)]
    if hits:
        say("FAIL", f"{len(hits)} line(s) look like a secret (the text is not printed):")
        for rel, number, rule in hits:
            detail(f"{rel}:{number}  ({rule})")
    else:
        say("ok", f"no token, private key or webhook URL in {read} source and document files, and no PEM private "
                  "key in any text file (the AdMob and SKAdNetwork identifiers are public and match none of the rules)")
    stray = []
    for rel in files:
        if rel == SERVER_HOME or not (rel.startswith(SERVER_SCOPE) or rel == "project.yml"):
            continue
        stray += [(rel, number) for number, line in enumerate(lines_of(rel), start=1) if SERVER_HOST.search(line)]
    if stray:
        say("FAIL", f"the Duo server's address is written outside {SERVER_HOME}, the one place a release changes it:")
        for rel, number in stray:
            detail(f"{rel}:{number}")
    else:
        say("ok", f"the Duo server's address is written only in {SERVER_HOME}")

# 9b -------------------------------------------------------------------------------------------
def check_9b():
    plain, duo = load_plist(PLAIN), load_plist(DUO)
    for path, ents in ((PLAIN, plain), (DUO, duo)):
        if ents is None:
            continue
        if "aps-environment" in ents:
            say("ok", f"{os.path.basename(path)} has aps-environment")
        else:
            say("FAIL", f"{path} has no aps-environment: iCloud sync's pushes and Duo's notifications both need it")
    if plain is not None:
        if APP_ATTEST in plain:
            say("FAIL", f"{PLAIN} has the App Attest key, so a release without Duo cannot sign until the App ID has the capability")
        else:
            say("ok", f"{os.path.basename(PLAIN)} has no App Attest key, so a release without Duo signs as before")
    if duo is not None:
        if duo.get(APP_ATTEST) == "development":
            say("ok", f"{os.path.basename(DUO)} adds App Attest (development, which export makes production)")
        else:
            say("FAIL", f"{DUO} must set {APP_ATTEST} to development")
    if plain is not None and duo is not None:
        rest = {k: v for k, v in duo.items() if k != APP_ATTEST}
        if rest == plain:
            say("ok", f"{os.path.basename(DUO)} is {os.path.basename(PLAIN)} plus App Attest and nothing else")
        else:
            say("FAIL", f"{DUO} has drifted from {PLAIN}; it must be a copy plus App Attest, so mirror the change:")
            for key in sorted(set(plain) | set(rest)):
                if key not in rest:
                    detail(f"{key}: only in {os.path.basename(PLAIN)}")
                elif key not in plain:
                    detail(f"{key}: only in {os.path.basename(DUO)}")
                elif plain[key] != rest[key]:
                    detail(f"{key}: different values")
    # Which file a build signs with: the plain one unless a Duo build says otherwise.
    project = read_text("project.yml") or ""
    signs_with = app_setting(project, "CODE_SIGN_ENTITLEMENTS")
    if signs_with == "$(DUO_ENTITLEMENTS)" and "HydroDrop.duo.entitlements" not in without_comments(project):
        say("ok", "the app target signs with $(DUO_ENTITLEMENTS), and project.yml never names the Duo file itself")
    else:
        say("FAIL", "project.yml must sign the app with \"$(DUO_ENTITLEMENTS)\" and never name HydroDrop.duo.entitlements, "
                    "so App Attest comes only from a Duo build")
    if re.search(r"(?m)^[ \t]+DUO_ENTITLEMENTS\s*:", without_comments(project)):
        say("FAIL", "project.yml sets DUO_ENTITLEMENTS itself, which overrides the configurations' plain default")
    for config in ("Config/Duo.xcconfig", "Config/Duo.Release.xcconfig"):
        code = [re.sub(r"//.*$", "", line) for line in (read_text(config) or "").split("\n")]
        assigned = [(n, m.group(1), m.group(2).strip()) for n, line in enumerate(code)
                    for m in [re.match(r"^\s*DUO_ENTITLEMENTS(\[[^\]]*\])?\s*=(.*)$", line)] if m]
        includes = [n for n, line in enumerate(code) if re.match(r"^\s*#include", line)]
        if (len(assigned) == 1 and assigned[0][1] is None and assigned[0][2] == PLAIN
                and all(assigned[0][0] < n for n in includes)):
            say("ok", f"{config} signs with {os.path.basename(PLAIN)} by default")
        else:
            say("FAIL", f"{config} must set DUO_ENTITLEMENTS = {PLAIN} exactly once, for every SDK, before any "
                        "#include; without it that configuration signs with no entitlements at all, and with "
                        "another value or a later line it signs with something else")
        # Duo is off unless a build says otherwise: the condition's default is empty.
        conditions = [(m.group(1), m.group(2).strip()) for line in code
                      for m in [re.match(r"^\s*DUO_V2_CONDITION(\[[^\]]*\])?\s*=(.*)$", line)] if m]
        if conditions == [(None, "")]:
            say("ok", f"{config} leaves DUO_V2_CONDITION empty, so Duo is compiled out by default")
        else:
            say("FAIL", f"{config} must set DUO_V2_CONDITION to nothing, once and for every SDK: Duo is off unless "
                        "a build turns it on on purpose")
    if re.search(r"^\s*#include", read_text("Config/Duo.Release.xcconfig") or "", re.M):
        say("FAIL", "Config/Duo.Release.xcconfig includes another file, so a local override could reach an archive")
    # The two configurations are project-level, so whatever else they set reaches every target,
    # the widget and the Watch app included: a CODE_SIGN_ENTITLEMENTS there would sign the Watch
    # app with Duo's entitlements in every release. They hold the two Duo settings and nothing else.
    for config in ("Config/Duo.xcconfig", "Config/Duo.Release.xcconfig"):
        stray = []
        for number, line in enumerate((read_text(config) or "").split("\n"), start=1):
            code = re.sub(r"//.*$", "", line).strip()
            if not code or code.startswith("#include"):
                continue
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\s*=", code)
            if not match or match.group(1) not in ("DUO_V2_CONDITION", "DUO_ENTITLEMENTS"):
                stray.append(f"{config}:{number}  ({match.group(1) if match else 'not a setting'})")
        if stray:
            say("FAIL", f"{config} sets something besides DUO_V2_CONDITION and DUO_ENTITLEMENTS, which reaches every target:")
            for where in stray:
                detail(where)
        else:
            say("ok", f"{config} sets only DUO_V2_CONDITION and DUO_ENTITLEMENTS")
    # Only the app signs with $(DUO_ENTITLEMENTS), the widget with its own file, and no other target
    # (the Watch app, the tests) and no project-level setting names an entitlements file at all.
    signing, target, in_targets = [], None, False
    for number, line in enumerate(without_comments(project).split("\n"), start=1):
        if re.match(r"^\S", line):
            in_targets, target = line.startswith("targets:"), None
        elif in_targets and re.match(r"^  \S", line):
            target = line.strip().rstrip(":")
        match = re.match(r"^\s+CODE_SIGN_ENTITLEMENTS(\[[^\]]*\])?\s*:\s*(.*?)\s*$", line)
        if match:
            signing.append((target if in_targets else None, match.group(1), match.group(2).strip('"'), number))
    wanted = {"HydroDrop": "$(DUO_ENTITLEMENTS)", "HydroDropWidgets": "HydroDropWidgets/HydroDropWidgets.entitlements"}
    wrong = [f"project.yml:{n}  ({t or 'project level'}{c or ''}: {v})" for t, c, v, n in signing
             if c is not None or wanted.get(t) != v]
    missing = [t for t in wanted if not any(st == t and sc is None for st, sc, _, _ in signing)]
    if wrong or missing:
        say("FAIL", "only the app may sign with $(DUO_ENTITLEMENTS) and the widget with its own file; nothing else "
                    "may set CODE_SIGN_ENTITLEMENTS:")
        for where in wrong + [f"{t} sets none" for t in missing]:
            detail(where)
    else:
        say("ok", "the app signs with $(DUO_ENTITLEMENTS), the widget with its own file, and no other target sets one")
    # The condition only ever arrives through $(DUO_V2_CONDITION): a literal DUO_V2 (or -DDUO_V2)
    # in project.yml or a configuration would compile Duo into every build, a release included.
    literal = re.compile(r"(?<![A-Za-z0-9_])(?:-D\s*)?DUO_V2(?![A-Za-z0-9_])")
    named = []
    for path, comment in (("project.yml", "#"), ("Config/Duo.xcconfig", "//"), ("Config/Duo.Release.xcconfig", "//")):
        text = without_comments(read_text(path) or "") if comment == "#" else "\n".join(
            re.sub(r"//.*$", "", line) for line in (read_text(path) or "").split("\n"))
        for number, line in enumerate(text.split("\n"), start=1):
            if literal.search(line.replace("$(DUO_V2_CONDITION)", "")):
                named.append(f"{path}:{number}")
    if named:
        say("FAIL", "DUO_V2 is set by name, so Duo is compiled into builds that did not ask for it:")
        for where in named:
            detail(where)
    else:
        say("ok", "DUO_V2 reaches the compiler only through $(DUO_V2_CONDITION)")
    top = [line for line in without_comments(project).split("\n")]
    mapping, inside = {}, False
    for line in top:
        if re.match(r"^configFiles:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line):
            inside = False
        if inside:
            match = re.match(r"^\s+(\w+):\s*(\S+)\s*$", line)
            if match:
                mapping[match.group(1)] = match.group(2).strip('"\'')
    others = [n for n, line in enumerate(top, start=1) if re.match(r"^\s+configFiles:", line)]
    if mapping == {"Debug": "Config/Duo.xcconfig", "Release": "Config/Duo.Release.xcconfig"} and not others:
        say("ok", "project.yml builds Debug from Config/Duo.xcconfig and Release from Config/Duo.Release.xcconfig")
    else:
        say("FAIL", "project.yml must map Debug to Config/Duo.xcconfig and Release to Config/Duo.Release.xcconfig, "
                    "with no target of its own configFiles, or a release reads another file")
    # The background modes and the BGTask identifier stay: CloudKit's sync needs the silent
    # push, iOS can still launch a tester's app for the retired Duo's refresh, and Duo v2 takes
    # that identifier over (memory: keep-background-modes).
    block = target_block(project, "HydroDrop")
    info = load_plist("HydroDrop/Info.plist") or {}
    for key, wanted in (("UIBackgroundModes", ["remote-notification", "fetch"]),
                        ("BGTaskSchedulerPermittedIdentifiers", ["$(PRODUCT_BUNDLE_IDENTIFIER).duo.refresh"])):
        declared, plisted = yaml_list(block, key), info.get(key) if isinstance(info.get(key), list) else []
        lost = [w for w in wanted if w not in declared or w not in plisted]
        if lost:
            say("FAIL", f"{key} lost {', '.join(lost)} in project.yml or HydroDrop/Info.plist; it must stay")
        else:
            say("ok", f"{key} keeps {', '.join(wanted)}")

# 9c -------------------------------------------------------------------------------------------
AASA = "docs/.well-known/apple-app-site-association"
LINK_PATHS = [("/tap*", "/tap", "bottle tags"), ("/duo", "/duo", "Duo invites")]

def claims(entry, pattern, sample):
    """Whether an applinks entry names `pattern` in a rule that is not an exclusion and puts no
    condition on the fragment (a Duo invite's code is the fragment), and whether the first
    rule that matches `sample` lets it through: iOS stops at the first match, so an exclusion
    above the claim wins. Components are read when there are any, as iOS 13 and later do;
    the older `paths` list otherwise, where `NOT ` marks an exclusion."""
    rules = []  # (pattern, excluded, conditions on the fragment)
    if isinstance(entry.get("components"), list):
        for component in entry["components"]:
            if isinstance(component, dict) and isinstance(component.get("/", "*"), str):
                rules.append((component.get("/", "*"), component.get("exclude") is True, component.get("#", "*") != "*"))
    elif isinstance(entry.get("paths"), list):
        for path in entry["paths"]:
            if isinstance(path, str):
                rules.append((path[4:], True, False) if path.startswith("NOT ") else (path, False, False))
    named = any(path == pattern and not excluded and not fragment for path, excluded, fragment in rules)
    first = next(((excluded, fragment) for path, excluded, fragment in rules if fnmatch.fnmatchcase(sample, path)), None)
    return named and first == (False, False)

def check_9c():
    bundle = app_setting(read_text("project.yml") or "", "PRODUCT_BUNDLE_IDENTIFIER")
    if not team or not bundle:
        say("FAIL", "could not read the team and the app's bundle identifier from project.yml")
        return
    app_id = f"{team}.{bundle}"
    try:
        with open(AASA, encoding="utf-8") as handle:
            aasa = json.load(handle)
    except FileNotFoundError:
        say("FAIL", f"{AASA} not found")
        return
    except ValueError:
        say("FAIL", f"{AASA} is not JSON, so iOS opens no link in the app")
        return
    details = aasa.get("applinks", {}).get("details", []) if isinstance(aasa, dict) and isinstance(aasa.get("applinks"), dict) else []
    entries = [d for d in details if isinstance(d, dict)
               and (app_id in (d.get("appIDs") if isinstance(d.get("appIDs"), list) else []) or d.get("appID") == app_id)]
    if not entries:
        say("FAIL", f"{AASA} does not name {app_id}, so iOS opens no link in the app")
    else:
        for pattern, sample, what in LINK_PATHS:
            if any(claims(entry, pattern, sample) for entry in entries):
                say("ok", f"the AASA claims {pattern} for {app_id} ({what})")
            else:
                say("FAIL", f"the AASA does not claim {pattern} for {app_id}, so {what} open the website instead of the app")
    for path in (PLAIN, DUO):
        ents = load_plist(path)
        if ents is None:
            continue
        domains = ents.get(DOMAINS)
        if isinstance(domains, list) and "applinks:hydrodrop.us" in domains:
            say("ok", f"{os.path.basename(path)} has applinks:hydrodrop.us")
        else:
            say("FAIL", f"{path} lacks applinks:hydrodrop.us, so no link opens the app")

# 9d -------------------------------------------------------------------------------------------
# Two manifests (decision D77): main's, which a build without Duo bundles, and the Duo one, which
# a build with DUO_V2 bundles instead. project.yml leaves one of them out by the condition. At P7,
# when Duo is on by default, the plain one and the selection settings go.
MANIFEST = "HydroDrop/PrivacyInfo.xcprivacy"
DUO_MANIFEST = "HydroDrop/Duo/PrivacyInfo.xcprivacy"
PREFIX = "NSPrivacyCollectedDataType"
# Compliance §2.2 and decision 3's recommended defaults: what the Duo server keeps, linked to the
# member, never tracking, for the app's functionality only.
DECLARED = ["Name", "UserID", "DeviceID", "Health", "OtherUsageData", "OtherUserContent"]
PURPOSES = ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
CAMERA = "NSCameraUsageDescription"
# The settings that pick a manifest and merge the camera string, as project.yml must have them.
SELECTION = {
    "EXCLUDED_SOURCE_FILE_NAMES": "$(DUO_EXCLUDED_MANIFEST_$(DUO_V2_CONDITION))",
    "DUO_EXCLUDED_MANIFEST_": "*/HydroDrop/Duo/PrivacyInfo.xcprivacy Localizable.strings",
    "DUO_EXCLUDED_MANIFEST_DUO_V2": "*/HydroDrop/PrivacyInfo.xcprivacy",
    "GENERATE_INFOPLIST_FILE": "$(DUO_INFOPLIST_KEYS_$(DUO_V2_CONDITION))",
    "DUO_INFOPLIST_KEYS_": "NO",
    "DUO_INFOPLIST_KEYS_DUO_V2": "YES",
}
# And Duo's push words, which the Watch app takes from HydroDrop/Resources: none without Duo.
WATCH = "HydroDrop Watch App"
WATCH_SELECTION = {
    "EXCLUDED_SOURCE_FILE_NAMES": "$(DUO_EXCLUDED_STRINGS_$(DUO_V2_CONDITION))",
    "DUO_EXCLUDED_STRINGS_": "Localizable.strings",
}

def tracking_checks(path, manifest):
    if manifest.get("NSPrivacyTracking") is not False:
        say("FAIL", f"{path}: NSPrivacyTracking must be false; the app never tracks and its label says so")
    if manifest.get("NSPrivacyTrackingDomains", []) not in ([], None):
        say("FAIL", f"{path} lists tracking domains; the Duo server is first-party functionality, not tracking")

def check_9d():
    plain, duo = load_plist(MANIFEST), load_plist(DUO_MANIFEST)
    if plain is not None:
        tracking_checks(MANIFEST, plain)
        if plain.get("NSPrivacyCollectedDataTypes") in ([], None):
            say("ok", f"{MANIFEST} is main's: no tracking, no collected data, for a build without Duo")
        else:
            say("FAIL", f"{MANIFEST} declares collected data, but it is the manifest of a build without Duo, which "
                        f"collects none; Duo's declarations belong in {DUO_MANIFEST}")
    if duo is not None:
        tracking_checks(DUO_MANIFEST, duo)
        entries = duo.get("NSPrivacyCollectedDataTypes") or []
        if not isinstance(entries, list) or not entries:
            say("FAIL", f"{DUO_MANIFEST} declares no collected data, but Duo Streaks sends a name, ids, each day's "
                        "progress and nudges to HydroDrop's server (compliance 2.2)")
        else:
            problems, seen = [], []
            for entry in entries:
                kind = entry.get(PREFIX) if isinstance(entry, dict) else None
                short = kind[len(PREFIX):] if isinstance(kind, str) and kind.startswith(PREFIX) else str(kind)
                seen.append(short)
                if not isinstance(entry, dict):
                    problems.append(f"{short}: not a dictionary")
                    continue
                if entry.get(PREFIX + "Linked") is not True:
                    problems.append(f"{short}: must be linked (it is kept under the member's id)")
                if entry.get(PREFIX + "Tracking") is not False:
                    problems.append(f"{short}: must not be tracking")
                if entry.get(PREFIX + "Purposes") != PURPOSES:
                    problems.append(f"{short}: the purpose must be app functionality alone")
            missing = [t for t in DECLARED if t not in seen]
            extra = sorted(set(t for t in seen if t not in DECLARED))
            twice = sorted(set(t for t in seen if seen.count(t) > 1))
            problems += [f"{t}: missing" for t in missing] + [f"{t}: not in compliance 2.2" for t in extra]
            problems += [f"{t}: declared twice" for t in twice]
            if problems:
                say("FAIL", f"{DUO_MANIFEST} does not declare exactly what Duo Streaks collects (compliance 2.2):")
                for problem in problems:
                    detail(problem)
            else:
                say("ok", f"{DUO_MANIFEST} declares the six types of compliance 2.2, linked, not tracking, "
                          "for app functionality")
    if plain is not None and duo is not None:
        differ = sorted(k for k in set(plain) | set(duo) if k != "NSPrivacyCollectedDataTypes" and plain.get(k) != duo.get(k))
        if differ:
            say("FAIL", "the two app manifests must differ only in NSPrivacyCollectedDataTypes; they also differ in:")
            for key in differ:
                detail(key)
        else:
            say("ok", "the two app manifests differ only in what is collected (the same required-reason APIs)")
    # Which one a build bundles, and the camera string, which only a Duo build merges in.
    project = read_text("project.yml") or ""
    wrong = [f"{k} must be {v}" for k, v in SELECTION.items() if app_setting(project, k) != v]
    wrong += [f"{WATCH}: {k} must be {v}" for k, v in WATCH_SELECTION.items() if target_setting(project, WATCH, k) != v]
    wrong += [f"{WATCH}: DUO_EXCLUDED_STRINGS_DUO_V2 must not be set"] if target_setting(project, WATCH, "DUO_EXCLUDED_STRINGS_DUO_V2") else []
    if wrong:
        say("FAIL", "project.yml no longer picks the manifest, the camera string and Duo's strings by DUO_V2_CONDITION:")
        for line in wrong:
            detail(line)
    else:
        say("ok", "the app and the Watch app bundle the Duo manifest, the camera string and Duo's strings only when "
                  "DUO_V2_CONDITION says so")
    camera = app_setting(project, "INFOPLIST_KEY_" + CAMERA)
    if camera:
        say("ok", "the camera's purpose string is a build setting a Duo build merges in")
    else:
        say("FAIL", f"project.yml has no INFOPLIST_KEY_{CAMERA}, so a Duo build's QR scanner would end the app")
    info = load_plist("HydroDrop/Info.plist")
    in_plist = info is not None and CAMERA in info
    in_properties = any(re.match(r"^\s+" + CAMERA + r"\s*:", line) for line in target_block(project, "HydroDrop"))
    if in_plist or in_properties:
        say("FAIL", f"{CAMERA} is back in {'HydroDrop/Info.plist' if in_plist else 'project.yml info.properties'}, "
                    "so a build without Duo would carry the camera string")
    elif info is not None:
        say("ok", f"HydroDrop/Info.plist has no {CAMERA}, as main's has none")

{"9a": check_9a, "9b": check_9b, "9c": check_9c, "9d": check_9d}[check]()
PY

DUO_PY=0
if command -v python3 >/dev/null 2>&1; then
  DUO_PY=1
else
  fail "python3 not found: the Duo Streaks checks need it (it ships with Xcode's command-line tools)"
fi

duo_check() {
  # $1 = the check's id. A check that stops with an error fails, whatever it printed first.
  local out rc
  # -I: neither the environment nor a stray json.py in the current folder can change what runs.
  out=$(python3 -I -B -c "$DUO_CHECKS" "$1" "$REPO" "$TEAM" 2>&1)
  rc=$?
  duo_relay <<< "$out"
  [[ $rc -eq 0 ]] || fail "check $1 stopped with an error (exit $rc)"
}

# 9a. No secrets in the tree. A key or a token in a commit is public the moment the
# repository is, and stays in its history after the file goes. Files git would commit
# (tracked, or untracked and not ignored) are checked by name; Swift, plist, YAML,
# xcconfig and script sources by content. And the Duo server's address is written in
# DuoConfig.swift alone, so staging and production are switched in one place.
[[ $DUO_PY -eq 1 ]] && duo_check 9a

# 9b. Push, and App Attest only for Duo. aps-environment was silently dropped once
# (2edecdc), which left iCloud syncing only at launch, and Duo's notifications need it too.
# App Attest needs the capability on the App ID and in the provisioning profile, so it
# lives in HydroDrop.duo.entitlements, which only a Duo build signs with. That file is a
# copy of HydroDrop.entitlements plus the one key, so any change to the plain file has to
# be mirrored there, and this fails on any drift.
[[ $DUO_PY -eq 1 ]] && duo_check 9b

# 9c. Universal links. The website's apple-app-site-association has to claim every path
# the app opens (bottle tags at /tap, Duo invites at /duo) for this app's ID, and the
# entitlements have to name the domain, or a tapped link opens a web page instead.
[[ $DUO_PY -eq 1 ]] && duo_check 9c

# 9d. The privacy manifests and the camera's purpose string. Xcode builds the privacy report
# from the manifest, and the App Store label must agree, so each build has to bundle exactly
# what it collects: a build without Duo main's manifest and no camera string, a build with Duo
# the six types of compliance §2.2 (linked, never tracking) and the QR scanner's string. And
# both manifests keep the reasons for every required-reason API the code calls: App Store
# Connect refuses an upload without the UserDefaults ones, so their loss fails; anything else
# check-required-reason-apis.py finds is a symbol to look at, so it warns.
[[ $DUO_PY -eq 1 ]] && duo_check 9d
REASONS="$REPO/Scripts/check-required-reason-apis.py"
if [[ $DUO_PY -ne 1 ]]; then
  :
elif [[ ! -f "$REASONS" ]]; then
  fail "Scripts/check-required-reason-apis.py not found"
else
  REASONS_OUT=$(python3 -I -B "$REASONS" --preflight "$REPO" 2>&1)
  REASONS_RC=$?
  duo_relay <<< "$REASONS_OUT"
  [[ $REASONS_RC -le 1 ]] || fail "check-required-reason-apis.py stopped with an error (exit $REASONS_RC)"
fi

# 9e. With DUO_V2 off, nothing of Duo can be reached: every Duo file is wholly inside
# `#if DUO_V2`, no Duo name sits outside one, and nothing outside HydroDrop/Duo/ names
# DuoAPIClient (Scripts/check-duo-gating.py says how).
GATING="$REPO/Scripts/check-duo-gating.py"
if [[ $DUO_PY -ne 1 ]]; then
  :
elif [[ ! -f "$GATING" ]]; then
  fail "Scripts/check-duo-gating.py not found"
elif GATING_OUT=$(python3 -I -B "$GATING" "$REPO" 2>&1); then
  pass "a build without DUO_V2 has no Duo code it can reach (check-duo-gating.py)"
else
  fail "Duo code that a build without DUO_V2 compiles (Scripts/check-duo-gating.py):"
  printf '%s\n' "$GATING_OUT" | sed 's/^/          /'
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
