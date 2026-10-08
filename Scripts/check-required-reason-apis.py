#!/usr/bin/env python3
"""Compares the required-reason APIs the app's code uses with what its privacy manifests declare.

Apple asks every app that calls one of its "required reason" APIs to say why, by category, in
`PrivacyInfo.xcprivacy` (`NSPrivacyAccessedAPITypes`), and App Store Connect refuses an upload
whose binary uses one the manifest does not name. HydroDrop's manifest names only UserDefaults
(CA92.1 and 1C8F.1). Duo Streaks v2 brings Keychain items, files kept out of backups and
timers, and compliance §2.2 says a file-timestamp reason is needed only if `DuoIdentity` reads a
file's dates (it keeps its install day as text instead). This script greps for the symbols of
each category and reports what the code uses against what the manifest declares:

  - File timestamp: creationDate, modificationDate, fileModificationDate, fileCreationDate,
    contentModificationDate (and its resource key), stat(, fstat(, fstatat(, lstat(,
    getattrlist and its variants, and the Foundation names NSFileModificationDate,
    NSFileCreationDate, NSURLContentModificationDateKey and NSURLCreationDateKey;
  - System boot time: systemUptime, mach_absolute_time;
  - Disk space: volumeAvailableCapacity (and its keys), volumeTotalCapacity, systemFreeSize,
    systemSize, statfs(, statvfs(, fstatfs(, fstatvfs(, and getattrlist and its variants,
    which Apple lists under both, and NSFileSystemFreeSize, NSFileSystemSize and the
    NSURLVolume capacity keys;
  - Active keyboard: activeInputModes;
  - User defaults: UserDefaults, NSUserDefaults and @AppStorage, which is UserDefaults.

The app has two manifests (decision D77): `HydroDrop/PrivacyInfo.xcprivacy`, which a build
without Duo bundles, and `HydroDrop/Duo/PrivacyInfo.xcprivacy`, which a build with DUO_V2
bundles instead. Either can ship, so every category the code uses has to be declared in both.

It reads the Swift the app target compiles (HydroDrop/, and HydroCore/Sources/, which is linked
into the app), with comments skipped, not the tests and not the widget or the Watch app, which
have manifests of their own. A symbol can be named without the API being called (a property of
your own called `creationDate`), and an API can be reached without its name (a dependency,
Objective-C), so a "used" line is a place to look, not a verdict. Preflight's section 9d runs it
with `--preflight`: there a lost UserDefaults reason fails, since the app's own defaults and the
App Group are read on every launch and App Store Connect refuses an upload without them, and
anything else it finds warns.

Usage:
    Scripts/check-required-reason-apis.py [--preflight] [REPO]

Exit status 0 when every category the code uses is declared in every manifest, 1 when one is
not, 2 when a manifest cannot be read. With --preflight it prints one verdict a line (ok, FAIL,
WARN, or - for a detail, a tab before the text) and exits 0 unless a manifest cannot be read.
"""
import importlib.util
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ["HydroDrop", "HydroCore/Sources"]
MANIFEST = "HydroDrop/PrivacyInfo.xcprivacy"
DUO_MANIFEST = "HydroDrop/Duo/PrivacyInfo.xcprivacy"
USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
USER_DEFAULTS_REASONS = ["CA92.1", "1C8F.1"]

_GETATTRLIST = r"(?:f)?getattrlist(?:bulk|at)?\b"
CATEGORIES = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        r"\bcreationDate", r"\bmodificationDate", r"\bfileModificationDate", r"\bfileCreationDate",
        r"\bcontentModificationDate", r"\bstat\(", r"\bfstat\(", r"\bfstatat\(", r"\blstat\(",
        r"\b" + _GETATTRLIST, r"\bNSFile(?:Modification|Creation)Date\b", r"\bNSURL(?:ContentModification|Creation)DateKey\b",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": [r"\bsystemUptime\b", r"\bmach_absolute_time\b"],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
        r"\bvolumeAvailableCapacity", r"\bvolumeTotalCapacity", r"\bsystemFreeSize\b", r"\bsystemSize\b",
        r"\bstatfs\(", r"\bstatvfs\(", r"\bfstatfs\(", r"\bfstatvfs\(", r"\b" + _GETATTRLIST,
        r"\bNSFileSystem(?:Free)?Size\b", r"\bNSURLVolume(?:Available|Total)Capacity",
    ],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": [r"\bactiveInputModes\b"],
    "NSPrivacyAccessedAPICategoryUserDefaults": [r"\bUserDefaults\b", r"\bNSUserDefaults\b", r"@AppStorage\b"],
}


def load_strip_comments():
    sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
    spec = importlib.util.spec_from_file_location("check_duo_gating", os.path.join(HERE, "check-duo-gating.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.strip_comments


def manifests(repo):
    """The app's manifests that exist: main's always, the Duo one where the branch has it."""
    return [m for m in (MANIFEST, DUO_MANIFEST) if m == MANIFEST or os.path.exists(os.path.join(repo, m))]


def declared_categories(repo, path=MANIFEST):
    with open(os.path.join(repo, path), "rb") as handle:
        manifest = plistlib.load(handle)
    if not isinstance(manifest, dict):
        raise ValueError("not a dictionary")
    declared = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []) or []:
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str):
            reasons = entry.get("NSPrivacyAccessedAPITypeReasons") or []
            declared[entry["NSPrivacyAccessedAPIType"]] = [r for r in reasons if isinstance(r, str)]
    return declared


def uses(repo, strip_comments):
    patterns = {category: re.compile("|".join(symbols)) for category, symbols in CATEGORIES.items()}
    found = {category: [] for category in CATEGORIES}
    for root in SOURCES:
        top = os.path.join(repo, root)
        for directory, subdirs, files in os.walk(top):
            subdirs[:] = sorted(d for d in subdirs if not d.startswith(".") and d != "build")
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                rel = os.path.relpath(path, repo).replace(os.sep, "/")
                with open(path, encoding="utf-8", errors="replace") as handle:
                    lines, _ = strip_comments(handle.read())
                for number, line in enumerate(lines, start=1):
                    for category, pattern in patterns.items():
                        match = pattern.search(line)
                        if match:
                            found[category].append((rel, number, match.group(0)))
    return found


def one_line(text):
    """Backslashes, tabs and line breaks written out, so a file name cannot add a verdict line."""
    return str(text).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def short(category):
    return category.replace("NSPrivacyAccessedAPICategory", "")


def report(path, declared, found):
    """The plain report for one manifest; returns the categories it lacks."""
    print(f"== {path}")
    undeclared = []
    for category in CATEGORIES:
        places = found[category]
        if category in declared and not declared[category]:
            print(f"{short(category)}: declared with no reason, which App Store Connect refuses")
            undeclared.append(category)
        if places:
            state = "declared (" + ", ".join(declared[category]) + ")" if category in declared else "NOT DECLARED"
            print(f"{short(category)}: used, {state}")
            for rel, number, symbol in places[:20]:
                print(f"    {rel}:{number}: {symbol}")
            if len(places) > 20:
                print(f"    ... and {len(places) - 20} more")
            if category not in declared:
                undeclared.append(category)
        elif category in declared:
            print(f"{short(category)}: declared, and no use found in the app's own code (a dependency may still need it)")
    for category in sorted(set(declared) - set(CATEGORIES)):
        print(f"{short(category)}: declared; this script has no symbols for it")
    if undeclared:
        print(f"{path} needs a reason for: " + ", ".join(sorted({short(c) for c in undeclared})))
    return undeclared


def verdicts(path, declared, found):
    """The same for preflight, as verdict lines; a lost UserDefaults reason is the one failure."""
    lost = [r for r in USER_DEFAULTS_REASONS if r not in declared.get(USER_DEFAULTS, [])]
    if lost:
        print(f"FAIL\t{path} lacks the UserDefaults reason(s) {', '.join(lost)}: the app's own defaults and the "
              "App Group are read on every launch, and App Store Connect refuses an upload without them")
    else:
        print(f"ok\t{path} keeps the UserDefaults reasons CA92.1 and 1C8F.1")
    for category in CATEGORIES:
        if category == USER_DEFAULTS:
            continue
        if category in declared and not declared[category]:
            print(f"WARN\t{path} declares {short(category)} with no reason, which App Store Connect refuses")
        places = found[category]
        if places and category not in declared:
            print(f"WARN\t{path} gives no reason for {short(category)}, which the code may use "
                  "(a symbol to look at, from check-required-reason-apis.py):")
            for rel, number, symbol in places[:5]:
                print(f"-\t{one_line(rel)}:{number}: {symbol}")
            if len(places) > 5:
                print(f"-\t... and {len(places) - 5} more")


def main(argv):
    args = argv[1:]
    preflight = "--preflight" in args
    args = [a for a in args if a != "--preflight"]
    repo = os.path.abspath(args[0] if args else os.path.join(HERE, ".."))
    declared = {}
    for path in manifests(repo):
        try:
            declared[path] = declared_categories(repo, path)
        except (OSError, plistlib.InvalidFileException, ValueError) as error:
            print(f"cannot read {path}: {error}", file=sys.stderr)
            return 2
    found = uses(repo, load_strip_comments())
    if preflight:
        for path in declared:
            verdicts(path, declared[path], found)
        return 0
    lacking = []
    for path in declared:
        lacking += report(path, declared[path], found)
    if lacking:
        return 1
    print("every required-reason category the app's code uses is declared in " + " and ".join(declared))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
