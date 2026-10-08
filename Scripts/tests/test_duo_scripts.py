"""Tests for Duo Streaks v2's project checks: check-duo-gating.py, check-required-reason-apis.py,
preflight's section 9 (and the lines of sections 3, 3b and 4 it touched) and release.sh's DUO_V2
switch.

Run from the repository root, with -B so Python leaves no bytecode in the checkout:

    python3 -B -m unittest Scripts/tests/test_duo_scripts.py

Each check is run against small trees built in a temporary folder, a clean one and one with a
deliberate violation per rule, and the gating and required-reason checkers also against this
checkout. Preflight is the real script pointed at a fixture holding only the files section 9
reads, with `xcrun` stubbed so its CloudKit section fails at once instead of going to the
network. The three independent reviews' probes are ported as tables under their own ids
(preflight v01 to v60, release.sh c01 to c23 and d01 to d24), so each finding has a test.

Nothing here archives, exports or uploads. release.sh runs from a temporary copy of the files it
reads, with `xcodebuild`, `codesign` and `xcrun` replaced by stubs first on PATH (they record
their arguments, build fake archives and IPAs from fake apps, and keep a copy of whatever an
upload would have sent), and with the project generation and preflight replaced in the copy.

The fake secrets are put together at run time, so this file never holds the text preflight's
secret rules look for.
"""
import sys

sys.dont_write_bytecode = True  # the modules this loads leave no __pycache__ beside the scripts

import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(REPO, "Scripts")
GATING = os.path.join(SCRIPTS, "check-duo-gating.py")
REASONS = os.path.join(SCRIPTS, "check-required-reason-apis.py")
PREFLIGHT = os.path.join(SCRIPTS, "preflight.sh")
RELEASE = os.path.join(SCRIPTS, "release.sh")
APP_ATTEST = "com.apple.developer.devicecheck.appattest-environment"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def load_gating():
    spec = importlib.util.spec_from_file_location("check_duo_gating", GATING)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write(root, rel, text, mode="w"):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8"})) as handle:
        handle.write(text)
    return path


def run(args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    return result.returncode, ANSI.sub("", result.stdout + result.stderr)


class Tree(unittest.TestCase):
    """A temporary folder per test."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory(prefix="duo-o-")
        self.root = os.path.realpath(self._dir.name)

    def tearDown(self):
        self._dir.cleanup()


# ---------------------------------------------------------------------------------------------
# check-duo-gating.py
# ---------------------------------------------------------------------------------------------

WRAPPED = textwrap.dedent("""\
    // A Duo file.

    #if DUO_V2
    import Foundation

    struct DuoThing {
        let store = DuoStore.shared
    }
    #endif
    """)


class GatingTests(Tree):

    def gate(self):
        return run([sys.executable, GATING, self.root])

    def clean_tree(self):
        write(self.root, "HydroDrop/Duo/DuoThing.swift", WRAPPED)
        write(self.root, "HydroDrop/Duo/KeychainDuoSecretStore.swift", WRAPPED.replace("DuoThing", "KeychainDuoSecretStore"))
        write(self.root, "HydroDrop/Views/DuoPreview.swift", "#if DUO_V2 && DEBUG\nlet duoPreview = DuoStore.preview\n#endif\n")
        write(self.root, "HydroDrop/Shared/DuoCache.swift", "/* header */\n#if DUO_V2\nstruct DuoCache {}\n#endif\n")
        write(self.root, "HydroDropTests/DuoThingTests.swift", WRAPPED)
        write(self.root, "HydroDrop/Router.swift", textwrap.dedent("""\
            import Foundation

            // DuoStore is told about links here, but only with the flag on.
            final class Router {
                #if DUO_V2
                var pendingDuoLink: DuoParsedInvite?
                #endif
                let site = "https://hydrodrop.us/tap" // not a Duo name: DuoStore
                func run() {
                    LegacyDuoCleanup.runOnce()
                    let key = "legacyDuoCleanup.v1.done"
                    #if DEBUG
                    print(key)
                    #endif
                }
            }
            """))

    def test_a_clean_tree_passes(self):
        self.clean_tree()
        code, out = self.gate()
        self.assertEqual(code, 0, out)
        self.assertIn("Duo gating holds: 5 Duo files", out)

    def test_an_unguarded_duo_store_reference_fails_at_its_line(self):
        self.clean_tree()
        write(self.root, "HydroDrop/Views/SettingsView.swift", "import SwiftUI\n\nlet store = DuoStore.shared\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Views/SettingsView.swift:3: `DuoStore` is outside `#if DUO_V2`", out)

    def test_a_hydrocore_duo_type_in_the_widget_or_the_watch_fails(self):
        self.clean_tree()
        write(self.root, "HydroDropWidgets/HydrationWidget.swift", "let ok = DuoStreak.isDayKey(\"2026-10-08\")\n")
        write(self.root, "HydroDrop Watch App/WatchHomeView.swift", "\n\nlet nudge = DuoNudgePreset.cheers\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDropWidgets/HydrationWidget.swift:1: `DuoStreak`", out)
        self.assertIn("HydroDrop Watch App/WatchHomeView.swift:3: `DuoNudgePreset`", out)

    def test_a_duo_property_added_to_a_shared_type_without_its_if_fails(self):
        self.clean_tree()
        write(self.root, "HydroDrop/Notifications/WeeklyRecapNotifier.swift",
              "final class AppRouter {\n    @Published var showingDuoScreen = false\n}\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("WeeklyRecapNotifier.swift:2: `showingDuoScreen`", out)

    def test_a_duo_file_missing_its_if_fails_at_its_first_line_of_code(self):
        self.clean_tree()
        write(self.root, "HydroDrop/Duo/DuoBroken.swift", "// Header.\nimport Foundation\n#if DUO_V2\nstruct DuoBroken {}\n#endif\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Duo/DuoBroken.swift:2: a Duo file must start with `#if DUO_V2`", out)

    def test_every_duo_file_pattern_is_held_to_the_wrapper(self):
        for rel in ("HydroDrop/Views/DuoCard.swift", "HydroDrop/Shared/DuoCache.swift", "HydroDropWidgets/DuoWidget.swift",
                    "HydroDropTests/DuoStoreTests.swift", "HydroDropTests/Support/DuoTestDoubles.swift",
                    "HydroDrop/Duo/SwiftDataDuoLogReader.swift"):
            with self.subTest(rel=rel):
                shutil.rmtree(self.root)
                os.makedirs(os.path.join(self.root, "HydroDrop"))
                write(self.root, rel, "import Foundation\nlet x = 1\n")
                code, out = self.gate()
                self.assertEqual(code, 1, out)
                self.assertIn(f"{rel}:1: a Duo file must start with `#if DUO_V2`", out)

    def test_a_wrapper_that_does_not_need_the_flag_fails(self):
        for condition in ("DEBUG", "DUO_V2 || DEBUG", "!DUO_V2", "canImport(UIKit)"):
            with self.subTest(condition=condition):
                write(self.root, "HydroDrop/Duo/DuoThing.swift", f"#if {condition}\nstruct DuoThing {{}}\n#endif\n")
                code, out = self.gate()
                self.assertEqual(code, 1, out)
                self.assertIn("HydroDrop/Duo/DuoThing.swift:1: a Duo file must start", out)

    def test_a_reference_in_the_else_branch_fails_at_its_line(self):
        self.clean_tree()
        write(self.root, "HydroDrop/Views/RootTabView.swift", textwrap.dedent("""\
            struct RootTabView {
                #if DUO_V2
                let duo = DuoStore.shared
                #else
                let duo = DuoStore.shared
                #endif
            }
            """))
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Views/RootTabView.swift:5: `DuoStore`", out)
        self.assertNotIn("RootTabView.swift:3:", out)

    def test_elseif_and_negated_conditions_are_judged_by_what_they_need(self):
        write(self.root, "HydroDrop/Mixed.swift", textwrap.dedent("""\
            #if !DUO_V2
            let a = 1
            #else
            let b = DuoStore.shared
            #endif
            #if DEBUG
            #if DUO_V2
            let c = DuoStore.shared
            #endif
            #elseif DUO_V2
            let d = DuoStore.shared
            #endif
            #if DUO_V2 || DEBUG
            let e = DuoStore.shared
            #endif
            #if DUO_V2 && os(iOS)
            let f = DuoStore.shared
            #elseif os(iOS)
            let g = DuoStore.shared
            #endif
            """))
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertEqual(sorted(re.findall(r"Mixed\.swift:(\d+):", out), key=int), ["14", "19"])

    def test_the_else_of_a_duo_files_own_wrapper_fails(self):
        write(self.root, "HydroDrop/Duo/DuoThing.swift", "#if DUO_V2\nstruct DuoThing {}\n#else\nlet fallback = 1\n#endif\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Duo/DuoThing.swift:3: an `#else` of the file's `#if DUO_V2`", out)

    def test_code_after_the_wrappers_endif_fails(self):
        write(self.root, "HydroDrop/Duo/DuoThing.swift", "#if DUO_V2\nstruct DuoThing {}\n#endif\n\nlet leaked = 1\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Duo/DuoThing.swift:5: this comes after the `#endif` on line 3", out)

    def test_an_unbalanced_if_fails(self):
        write(self.root, "HydroDrop/Duo/DuoThing.swift", "#if DUO_V2\nstruct DuoThing {}\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Duo/DuoThing.swift:1: this `#if` has no `#endif`", out)

    def test_comments_are_skipped_and_strings_and_interpolations_are_not(self):
        write(self.root, "HydroDrop/Lexer.swift", textwrap.dedent('''\
            /* A block comment naming DuoStore,
               with /* a nested one */ and still DuoStore */
            /// Docs naming DuoStore.
            let url = "https://example.com"; let a = DuoAlpha.x
            let raw = #"a "quoted" // not a comment"#; let b = DuoBravo.x
            let text = """
                /* not a comment */ DuoCharlie
                """
            let said = "\\(DuoDelta.name) and \\("nested \\(DuoEcho.x)")"
            let regex = #/Duo[A-Z]+"//#; let c = DuoFoxtrot.x
            '''))
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        found = re.findall(r"Lexer\.swift:(\d+): `(\w+)`", out)
        self.assertEqual(found, [("4", "DuoAlpha"), ("5", "DuoBravo"), ("7", "DuoCharlie"), ("9", "DuoDelta"),
                                 ("9", "DuoEcho"), ("10", "DuoFoxtrot")])

    def test_an_if_inside_a_comment_or_a_string_is_not_a_directive(self):
        write(self.root, "HydroDrop/Lexer.swift", textwrap.dedent('''\
            /*
            #if DUO_V2
            */
            let a = DuoAlpha.x
            let s = """
            #if DUO_V2
            """
            let b = DuoBravo.x
            '''))
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        self.assertEqual(re.findall(r"Lexer\.swift:(\d+):", out), ["4", "8"])

    def test_duo_api_client_named_outside_its_folder_fails_even_in_a_comment_or_a_wrapped_file(self):
        self.clean_tree()
        write(self.root, "HydroDrop/Duo/DuoComposition.swift", "#if DUO_V2\nlet client = DuoAPIClient()\n#endif\n")
        write(self.root, "HydroDrop/Views/DuoDiagnosticsView.swift", "#if DUO_V2\nlet c: DuoAPIClient? = nil\n#endif\n")
        write(self.root, "HydroDrop/Support/Notes.swift", "// Asks DuoAPIClient for nothing.\nlet x = 1\n")
        write(self.root, "HydroDrop/Info.plist", "<plist><string>DuoAPIClient</string></plist>\n")
        write(self.root, "HydroCore/Sources/HydroCore/DuoWire.swift", "// DuoAPIClient sends these.\n")
        write(self.root, "HydroDropTests/DuoAPIClientTests.swift", "#if DUO_V2\nlet c = DuoAPIClient.self\n#endif\n")
        code, out = self.gate()
        self.assertEqual(code, 1, out)
        found = sorted(re.findall(r"^(.*?):(\d+): names `DuoAPIClient`", out, re.M))
        self.assertEqual(found, [("HydroDrop/Info.plist", "1"), ("HydroDrop/Support/Notes.swift", "1"),
                                 ("HydroDrop/Views/DuoDiagnosticsView.swift", "2")])

    def test_hydrocore_is_not_read(self):
        write(self.root, "HydroDrop/App.swift", "let a = 1\n")
        write(self.root, "HydroCore/Sources/HydroCore/DuoStreak.swift", "public enum DuoStreak {}\n")
        code, out = self.gate()
        self.assertEqual(code, 0, out)

    def test_a_folder_that_is_not_a_checkout_is_refused(self):
        code, out = self.gate()
        self.assertEqual(code, 2, out)

    def test_this_checkout_passes(self):
        code, out = run([sys.executable, GATING, REPO])
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"Duo gating holds: \d+ Duo files")

    def test_every_tracked_swift_file_lexes_back_to_code(self):
        """The comment scanner ends every real file in plain code, with its lines intact."""
        strip = load_gating().strip_comments
        listed = [n for n in subprocess.run(["git", "-C", REPO, "ls-files", "-z", "*.swift"], capture_output=True,
                                            text=True).stdout.split("\0") if n]
        if not listed:  # a copy of the tree that is not a git checkout
            listed = [os.path.relpath(os.path.join(d, f), REPO) for d, _, files in os.walk(REPO)
                      if "/.build" not in d and "/." not in os.path.relpath(d, REPO) for f in files if f.endswith(".swift")]
        self.assertGreater(len(listed), 100)
        for rel in listed:
            with open(os.path.join(REPO, rel), encoding="utf-8") as handle:
                source = handle.read()
            lines, starts = strip(source)
            self.assertEqual(len(lines), source.count("\n") + 1, rel)
            self.assertTrue(starts[-1], f"{rel} does not end in code")


# ---------------------------------------------------------------------------------------------
# check-required-reason-apis.py
# ---------------------------------------------------------------------------------------------

def manifest(categories, collected=0):
    return plistlib.dumps({
        "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [{"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeName"}] * collected,
        "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + c,
                                       "NSPrivacyAccessedAPITypeReasons": reasons} for c, reasons in categories],
    })


BOTH_REASONS = [("UserDefaults", ["CA92.1", "1C8F.1"])]


class RequiredReasonTests(Tree):

    def reasons(self, *flags):
        return run([sys.executable, REASONS, *flags, self.root])

    def test_an_undeclared_file_timestamp_read_fails(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest([("UserDefaults", ["CA92.1"])]), "wb")
        write(self.root, "HydroDrop/Duo/DuoIdentity.swift",
              "let d = UserDefaults.standard\n// creationDate in a comment does not count\nlet c = attrs[.creationDate]\n")
        code, out = self.reasons()
        self.assertEqual(code, 1, out)
        self.assertIn("FileTimestamp: used, NOT DECLARED", out)
        self.assertIn("HydroDrop/Duo/DuoIdentity.swift:3: creationDate", out)
        self.assertNotIn("DuoIdentity.swift:2:", out)
        self.assertIn("UserDefaults: used, declared (CA92.1)", out)

    def test_a_declared_category_passes(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy",
              manifest([("UserDefaults", ["CA92.1"]), ("FileTimestamp", ["C617.1"])]), "wb")
        write(self.root, "HydroDrop/Duo/DuoIdentity.swift", "let c = attrs[.modificationDate]\n")
        code, out = self.reasons()
        self.assertEqual(code, 0, out)
        self.assertIn("FileTimestamp: used, declared (C617.1)", out)

    def test_each_category_is_found_in_the_app_and_hydrocore_but_not_the_tests(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest([]), "wb")
        write(self.root, "HydroDrop/A.swift", "let up = ProcessInfo.processInfo.systemUptime\n")
        write(self.root, "HydroCore/Sources/HydroCore/B.swift", "let free = values.volumeAvailableCapacityForImportantUsage\n")
        write(self.root, "HydroDrop/C.swift", "let modes = UITextInputMode.activeInputModes\n@AppStorage(\"k\") var k = 1\n")
        write(self.root, "HydroDropTests/T.swift", "let s = stat(path, &buffer)\n")
        code, out = self.reasons()
        self.assertEqual(code, 1, out)
        for short in ("SystemBootTime", "DiskSpace", "ActiveKeyboards", "UserDefaults"):
            self.assertIn(f"{short}: used, NOT DECLARED", out)
        self.assertNotIn("FileTimestamp: used", out)

    def test_a_category_declared_with_no_reason_fails(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest([("UserDefaults", [])]), "wb")
        write(self.root, "HydroDrop/A.swift", "let d = UserDefaults.standard\n")
        code, out = self.reasons()
        self.assertEqual(code, 1, out)
        self.assertIn("UserDefaults: declared with no reason", out)

    def test_the_duo_manifest_is_held_to_the_same_rule(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest(BOTH_REASONS + [("FileTimestamp", ["C617.1"])]), "wb")
        write(self.root, "HydroDrop/Duo/PrivacyInfo.xcprivacy", manifest(BOTH_REASONS, collected=6), "wb")
        write(self.root, "HydroDrop/Duo/DuoIdentity.swift", "let c = attrs[.creationDate]\nlet d = UserDefaults.standard\n")
        code, out = self.reasons()
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop/Duo/PrivacyInfo.xcprivacy needs a reason for: FileTimestamp", out)
        self.assertNotIn("HydroDrop/PrivacyInfo.xcprivacy needs a reason", out)

    def test_preflight_mode_fails_a_lost_user_defaults_reason_and_warns_for_the_rest(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest([("UserDefaults", ["CA92.1"])]), "wb")
        write(self.root, "HydroDrop/Duo/PrivacyInfo.xcprivacy", manifest(BOTH_REASONS + [("DiskSpace", [])], 6), "wb")
        write(self.root, "HydroDrop/A.swift", "let made = attrs[.creationDate]\n")
        code, out = self.reasons("--preflight")
        self.assertEqual(code, 0, out)
        lines = out.strip().split("\n")
        self.assertIn("FAIL\tHydroDrop/PrivacyInfo.xcprivacy lacks the UserDefaults reason(s) 1C8F.1", "\n".join(lines))
        self.assertIn("ok\tHydroDrop/Duo/PrivacyInfo.xcprivacy keeps the UserDefaults reasons CA92.1 and 1C8F.1", lines)
        self.assertIn("WARN\tHydroDrop/PrivacyInfo.xcprivacy gives no reason for FileTimestamp", out)
        self.assertIn("WARN\tHydroDrop/Duo/PrivacyInfo.xcprivacy declares DiskSpace with no reason", out)
        self.assertIn("-\tHydroDrop/A.swift:1: creationDate", lines)
        self.assertEqual(sum(1 for l in lines if l.startswith("FAIL")), 1, out)

    def test_an_unreadable_manifest_is_exit_2(self):
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", "not a plist")
        self.assertEqual(self.reasons()[0], 2)
        self.assertEqual(self.reasons("--preflight")[0], 2)
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest(BOTH_REASONS), "wb")
        write(self.root, "HydroDrop/Duo/PrivacyInfo.xcprivacy", "not a plist either")
        self.assertEqual(self.reasons()[0], 2)

    def test_it_leaves_no_bytecode_beside_the_scripts(self):
        scripts = os.path.join(self.root, "copy", "Scripts")
        os.makedirs(scripts)
        for name in ("check-duo-gating.py", "check-required-reason-apis.py"):
            shutil.copy(os.path.join(SCRIPTS, name), scripts)
        write(self.root, "HydroDrop/PrivacyInfo.xcprivacy", manifest(BOTH_REASONS), "wb")
        env = dict(os.environ)
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        code, out = run([sys.executable, os.path.join(scripts, "check-required-reason-apis.py"), self.root], env=env)
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.exists(os.path.join(scripts, "__pycache__")))

    def test_this_checkout_passes_with_only_user_defaults(self):
        code, out = run([sys.executable, REASONS, REPO])
        self.assertEqual(code, 0, out)
        self.assertIn("== HydroDrop/PrivacyInfo.xcprivacy\nUserDefaults: used, declared (CA92.1, 1C8F.1)", out)
        self.assertIn("== HydroDrop/Duo/PrivacyInfo.xcprivacy\nUserDefaults: used, declared (CA92.1, 1C8F.1)", out)
        self.assertNotIn("NOT DECLARED", out)


# ---------------------------------------------------------------------------------------------
# preflight.sh section 9, on a fixture of the files it reads
# ---------------------------------------------------------------------------------------------

SECTION_9_FILES = [
    "project.yml", "Config/Duo.xcconfig", "Config/Duo.Release.xcconfig",
    "HydroDrop/HydroDrop.entitlements", "HydroDrop/HydroDrop.duo.entitlements",
    "HydroDrop/PrivacyInfo.xcprivacy", "HydroDrop/Duo/PrivacyInfo.xcprivacy", "HydroDrop/Info.plist",
    "HydroDrop/Duo/DuoConfig.swift", "docs/.well-known/apple-app-site-association",
    "Scripts/check-duo-gating.py", "Scripts/check-required-reason-apis.py",
]
STRIPE = "sk_" + "live_" + "51HfakeFAKEfake0123456789abcdef"
BEARER = "Bear" + "er " + "eyJhbGciOiJIUzI1NiJ9.fakefakefakefakefake"
PEM = "-----BEGIN " + "RSA PRIVATE KEY-----"
DISCORD = "https://discord.com/api/" + "webhooks/123456789/fakeTOKENfake"
PGP = "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----"
GITHUB = "ghp" + "_" + "fakeGITHUBfake0123456789abcdefghijklmn"
AWS = "AKIA" + "FAKEAWSKEY012345"
CLOUDFLARE = "fakeCLOUDFLAREfake" + "0123456789abcdefghijklmnopq"
SLACK = "https://hooks.slack.com/" + "services/T000/B000/fakeSLACKfake"
SECRET_PARTS = [STRIPE, BEARER, PEM, DISCORD, SLACK, PGP, GITHUB, AWS, CLOUDFLARE, "51HfakeFAKEfake", "eyJhbGciOiJIUzI1NiJ9",
                "fakeTOKENfake", "fakeSLACKfake", "fakeGITHUBfake", "FAKEAWSKEY", "fakeCLOUDFLAREfake"]
PAYWALL = textwrap.dedent('''\
    struct PaywallView {
        static let features: [PlusFeature] = [
            .init(title: "Support indie development", icon: "heart"),
        ]
    }
    ''')
PLAIN = "HydroDrop/HydroDrop.entitlements"
DUO_ENTS = "HydroDrop/HydroDrop.duo.entitlements"
MAN = "HydroDrop/PrivacyInfo.xcprivacy"
DUO_MAN = "HydroDrop/Duo/PrivacyInfo.xcprivacy"
PREFIX = "NSPrivacyCollectedDataType"


class Preflight:
    def __init__(self, code, out):
        self.code, self.out = code, out
        parts = out.split("\nDuo Streaks\n", 1)
        self.body = parts[1].split("─────", 1)[0] if len(parts) == 2 else ""
        lines = self.body.split("\n")
        self.oks = [l.strip()[2:].strip() for l in lines if l.startswith("  ok ")]
        self.fails = [l.strip()[4:].strip() for l in lines if l.startswith("  FAIL ")]
        self.warns = [l.strip()[4:].strip() for l in lines if l.startswith("  WARN ")]
        self.details = [l.strip() for l in lines if l.startswith("          ")]


class Fixture(Tree):
    """A copy of the files preflight's section 9 reads, and an `xcrun` that fails at once."""

    def setUp(self):
        super().setUp()
        for rel in SECTION_9_FILES:
            os.makedirs(os.path.dirname(os.path.join(self.root, rel)), exist_ok=True)
            shutil.copy(os.path.join(REPO, rel), os.path.join(self.root, rel))
        self.bin = tempfile.mkdtemp(prefix="duo-o-bin-")
        write(self.bin, "xcrun", "#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(self.bin, "xcrun"), 0o755)

    def tearDown(self):
        shutil.rmtree(self.bin, ignore_errors=True)
        super().tearDown()

    def preflight(self):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"])
        env.pop("HYDRODROP_SKIP_CLOUDKIT_SCHEMA", None)
        result = Preflight(*run(["/bin/bash", PREFLIGHT, self.root], env=env))
        self.assertTrue(result.body, result.out)
        for secret in SECRET_PARTS:
            self.assertNotIn(secret, result.out, "a secret was printed")
        return result

    def edit_plist(self, rel, change):
        path = os.path.join(self.root, rel)
        with open(path, "rb") as handle:
            value = plistlib.load(handle)
        change(value)
        with open(path, "wb") as handle:
            plistlib.dump(value, handle)

    def replace(self, rel, old, new, count=1):
        path = os.path.join(self.root, rel)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn(old, text, rel)
        write(self.root, rel, text.replace(old, new, count))

    def append(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)

    def restore(self, rel):
        shutil.copy(os.path.join(REPO, rel), os.path.join(self.root, rel))

    def assertFailsWith(self, result, fragment):
        self.assertTrue(any(fragment in f for f in result.fails), f"no FAIL containing {fragment!r} in {result.fails}")


class PreflightTests(Fixture):

    def test_the_copied_files_pass_every_section_9_check(self):
        result = self.preflight()
        self.assertEqual((result.fails, result.warns), ([], []), result.body)
        self.assertEqual(len(result.oks), 33, result.body)
        self.assertEqual(result.code, 1, "sections 1 to 8 fail in a fixture that lacks their files")

    # 9a -------------------------------------------------------------------------------------

    def test_9a_finds_key_files_by_name(self):
        names = ["AuthKey_ABC123.p8", "release.keystore", "upload.jks", "google-services.json", ".env", ".env.production",
                 ".dev.vars", "server.pem", "dist.p12", "dist.pfx", "id_rsa", "id_ed25519"]
        for name in names + ["id_rsa.pub"]:
            write(self.root, f"Keys/{name}", "x")
        write(self.root, "Keys/server.key", PEM + "\nabc\n")
        write(self.root, "Keys/Slides.key", b"PK\x03\x04" + b"\0" * 64 + PEM.encode(), "wb")  # a Keynote document
        write(self.root, "Keys/notes.key", "not a key at all\n")
        result = self.preflight()
        self.assertFailsWith(result, f"{len(names) + 1} key or secret file(s)")
        for name in names + ["server.key"]:
            self.assertIn(f"Keys/{name}  (", result.body)
        for name in ("id_rsa.pub", "Slides.key", "notes.key"):
            self.assertNotIn(f"Keys/{name}  (", result.body)

    def test_9a_finds_secrets_in_sources_and_documents_and_never_prints_them(self):
        write(self.root, "HydroDrop/Duo/Leak.swift", f'// fine\nlet h = "{BEARER}"\n')
        write(self.root, "Config/Leak.xcconfig", f"KEY = {STRIPE}\n")
        write(self.root, "Scripts/leak.sh", f"echo '{PEM}'\n")
        write(self.root, "HydroDrop/Leak.plist", f"<plist><string>{DISCORD}</string></plist>\n")
        write(self.root, "ci/leak.yml", f"\nurl: {SLACK}\n")
        write(self.root, "Scripts/leak.py", f"KEY = '{PEM}'\n")
        write(self.root, "docs/config.json", json.dumps({"k": STRIPE}) + "\n")
        write(self.root, "notes/keys.md", f"key: {STRIPE}\n")
        write(self.root, "notes/key.txt", f"{PEM}\nabc\n")
        write(self.root, "docs/leak.html", f"<p>{BEARER}</p>\n")
        write(self.root, "docs/leak.js", f"const hook = '{DISCORD}';\n")
        write(self.root, "HydroDrop/Resources/en.lproj/Leak.strings", f'\n"k" = "{STRIPE}";\n'.encode("utf-16"), "wb")
        write(self.root, "notes/server-key", f"{PEM}\n")  # no suffix at all: only the PEM rule reads it
        write(self.root, "notes/binary.bin", b"\0\0" + PEM.encode(), "wb")  # binary: not read
        write(self.root, "notes/pgp", PGP + "\n")
        write(self.root, "worker/wrangler.toml", f'[vars]\nGH = "{GITHUB}"\n')
        write(self.root, "worker/aws.json", json.dumps({"id": AWS}) + "\n")
        write(self.root, "worker/cf.toml", f'CLOUDFLARE_API_TOKEN = "{CLOUDFLARE}"\n')
        write(self.root, "notes/no-bom.strings", f'"k" = "{STRIPE}";\n'.encode("utf-16-le"), "wb")
        write(self.root, "Scripts/continued.sh", "curl -H 'Authorization: Bearer \\\n    " + BEARER.split(" ", 1)[1] + "' x\n")
        result = self.preflight()
        for where, rule in (("notes/pgp:1", "a PGP private key"), ("worker/wrangler.toml:2", "a GitHub token"),
                            ("worker/aws.json:1", "an AWS access key id"), ("worker/cf.toml:1", "a Cloudflare API token or key"),
                            ("notes/no-bom.strings:1", "a Stripe live secret key"), ("Scripts/continued.sh:1", "a Bearer token")):
            self.assertIn(f"{where}  ({rule})", result.body)
        self.assertFailsWith(result, "19 line(s) look like a secret")
        for where, rule in (("HydroDrop/Duo/Leak.swift:2", "a Bearer token"), ("Config/Leak.xcconfig:1", "a Stripe live secret key"),
                            ("Scripts/leak.sh:1", "a PEM private key"), ("HydroDrop/Leak.plist:1", "a Discord webhook URL"),
                            ("ci/leak.yml:2", "a Slack webhook URL"), ("Scripts/leak.py:1", "a PEM private key"),
                            ("docs/config.json:1", "a Stripe live secret key"), ("notes/keys.md:1", "a Stripe live secret key"),
                            ("notes/key.txt:1", "a PEM private key"), ("docs/leak.html:1", "a Bearer token"),
                            ("docs/leak.js:1", "a Discord webhook URL"),
                            ("HydroDrop/Resources/en.lproj/Leak.strings:2", "a Stripe live secret key"),
                            ("notes/server-key:1", "a PEM private key")):
            self.assertIn(f"{where}  ({rule})", result.body)
        self.assertNotIn("binary.bin", result.body)

    def test_9a_allows_short_bearer_text_and_the_ad_identifiers(self):
        write(self.root, "HydroDrop/Support/Fine.swift",
              'let a = "Bearer \\(credential.bearer)"\nlet b = "Bearer not-a-real-secret"\nlet task_live = 1\n')
        result = self.preflight()
        self.assertEqual(result.fails, [], result.body)
        self.assertTrue(any(o.startswith("no token, private key or webhook URL") for o in result.oks), result.oks)

    def test_9a_finds_the_server_address_outside_duo_config(self):
        write(self.root, "HydroDrop/Views/Elsewhere.swift", 'let u = URL(string: "https://api.hydrodrop.us/v1")!\n')
        write(self.root, "HydroDropWidgets/W.swift", '\nlet u = "https://api-staging.hydrodrop.us/v1"\n')
        write(self.root, "HydroCore/Sources/HydroCore/C.swift", 'let u = "https://hydrodrop-server.someone.workers.dev"\n')
        write(self.root, "HydroDropTests/T.swift", 'let u = "https://api-staging.hydrodrop.us/v1"\n')  # tests may
        write(self.root, "HydroDrop/Views/Site.swift", 'let u = "https://hydrodrop.us/privacy.html"; let m = "support@hydrodrop.us"\n')
        result = self.preflight()
        self.assertFailsWith(result, "the Duo server's address is written outside HydroDrop/Duo/DuoConfig.swift")
        for where in ("HydroDrop/Views/Elsewhere.swift:1", "HydroDropWidgets/W.swift:2", "HydroCore/Sources/HydroCore/C.swift:1"):
            self.assertIn(where, result.details)
        self.assertNotIn("HydroDropTests/T.swift", result.body)
        self.assertNotIn("Site.swift", result.body)

    def test_9a_reads_what_git_would_commit_in_a_checkout(self):
        if shutil.which("git") is None:
            self.skipTest("no git")
        write(self.root, ".gitignore", "ignored/\n")
        write(self.root, "tracked/AuthKey_TRACKED.p8", "x")
        write(self.root, "untracked/AuthKey_UNTRACKED.p8", "x")
        write(self.root, "ignored/AuthKey_IGNORED.p8", "x")
        subprocess.run(["git", "init", "-q", self.root], check=True)
        subprocess.run(["git", "-C", self.root, "add", "-A", "--", "tracked", ".gitignore"], check=True)
        result = self.preflight()
        self.assertFailsWith(result, "2 key or secret file(s)")
        self.assertIn("tracked/AuthKey_TRACKED.p8", result.body)
        self.assertIn("untracked/AuthKey_UNTRACKED.p8", result.body)
        self.assertNotIn("AuthKey_IGNORED", result.body)

    def test_a_file_name_cannot_add_a_verdict_to_the_relay(self):
        write(self.root, "Keys/evil\nok\tinjected verdict.p8", "x")
        write(self.root, "HydroDrop/Support/odd\nok\tsecond injected.swift", "let made = attrs[.creationDate]\n")
        result = self.preflight()
        self.assertFalse([o for o in result.oks if "injected" in o], result.oks)
        self.assertIn("Keys/evil\\nok\\tinjected verdict.p8  (", result.body)
        self.assertIn("HydroDrop/Support/odd\\nok\\tsecond injected.swift:1: creationDate", result.body)

    def test_a_check_that_crashes_fails_preflight(self):
        write(self.root, "project.yml", b"name: HydroDrop\n\xff\xfe not text\n", "wb")
        result = self.preflight()
        for check in ("9b", "9c", "9d"):
            self.assertFailsWith(result, f"check {check} stopped with an error")
        self.restore("project.yml")
        write(self.root, DUO_MAN, "not a plist")
        self.assertFailsWith(self.preflight(), "check-required-reason-apis.py stopped with an error (exit 2)")

    def test_9a_to_9d_ignore_a_stray_json_module_in_the_checkout(self):
        write(self.root, "json.py", "raise SystemExit('a stray json.py ran')\n")
        write(self.root, "plistlib.py", "raise SystemExit('a stray plistlib.py ran')\n")
        result = self.preflight()
        self.assertEqual(result.fails, [], result.body)
        self.assertNotIn("stray", result.out)

    # 9b -------------------------------------------------------------------------------------

    def test_9b_fails_without_aps_environment(self):
        self.edit_plist(PLAIN, lambda e: e.pop("aps-environment"))
        self.edit_plist(DUO_ENTS, lambda e: e.pop("aps-environment"))
        result = self.preflight()
        self.assertFailsWith(result, "HydroDrop/HydroDrop.entitlements has no aps-environment")
        self.assertFailsWith(result, "HydroDrop/HydroDrop.duo.entitlements has no aps-environment")
        self.assertNotIn("has drifted", result.body)

    def test_9b_fails_when_the_duo_file_drifts_from_the_plain_one(self):
        self.edit_plist(PLAIN, lambda e: e["com.apple.security.application-groups"].append("group.example.other"))
        self.edit_plist(DUO_ENTS, lambda e: e.update({"com.apple.developer.siri": True}))
        result = self.preflight()
        self.assertFailsWith(result, "HydroDrop/HydroDrop.duo.entitlements has drifted from HydroDrop/HydroDrop.entitlements")
        self.assertIn("com.apple.security.application-groups: different values", result.body)
        self.assertIn("com.apple.developer.siri: only in HydroDrop.duo.entitlements", result.body)

    def test_9b_fails_when_only_a_value_drifts(self):
        self.edit_plist(PLAIN, lambda e: e.update({"aps-environment": "production"}))
        result = self.preflight()
        self.assertFailsWith(result, "has drifted")
        self.assertIn("aps-environment: different values", result.body)

    def test_9b_fails_when_a_key_is_missing_from_the_duo_file(self):
        self.edit_plist(DUO_ENTS, lambda e: e.pop("com.apple.developer.weatherkit"))
        result = self.preflight()
        self.assertFailsWith(result, "has drifted")
        self.assertIn("com.apple.developer.weatherkit: only in HydroDrop.entitlements", result.body)

    def test_9b_fails_when_the_plain_file_has_app_attest(self):
        self.edit_plist(PLAIN, lambda e: e.update({APP_ATTEST: "development"}))
        self.assertFailsWith(self.preflight(), "HydroDrop/HydroDrop.entitlements has the App Attest key")

    def test_9b_fails_when_the_duo_file_lacks_app_attest_or_says_production(self):
        for value in (None, "production"):
            with self.subTest(value=value):
                self.restore(DUO_ENTS)
                self.edit_plist(DUO_ENTS, lambda e: e.pop(APP_ATTEST) if value is None else e.update({APP_ATTEST: value}))
                self.assertFailsWith(self.preflight(), f"must set {APP_ATTEST} to development")

    def test_9b_fails_when_the_duo_file_is_missing(self):
        os.remove(os.path.join(self.root, DUO_ENTS))
        self.assertFailsWith(self.preflight(), "HydroDrop/HydroDrop.duo.entitlements not found")

    def test_9b_fails_when_project_yml_signs_with_a_fixed_file_or_sets_the_setting(self):
        for old, new in (('CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"', "CODE_SIGN_ENTITLEMENTS: HydroDrop/HydroDrop.entitlements"),
                         ('CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"', "CODE_SIGN_ENTITLEMENTS: HydroDrop/HydroDrop.duo.entitlements")):
            with self.subTest(new=new):
                self.restore("project.yml")
                self.replace("project.yml", old, new)
                self.assertFailsWith(self.preflight(), 'project.yml must sign the app with "$(DUO_ENTITLEMENTS)"')
        self.restore("project.yml")
        self.replace("project.yml", '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n',
                     '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n        DUO_ENTITLEMENTS: "$(SOMETHING_ELSE)"\n')
        self.assertFailsWith(self.preflight(), "project.yml sets DUO_ENTITLEMENTS itself")

    def test_9b_holds_each_configuration_to_one_plain_default_before_any_include(self):
        line = "DUO_ENTITLEMENTS = HydroDrop/HydroDrop.entitlements"
        cases = [
            ("Config/Duo.xcconfig", lambda: self.replace("Config/Duo.xcconfig", line, "")),
            ("Config/Duo.Release.xcconfig", lambda: self.replace("Config/Duo.Release.xcconfig", line, "")),
            ("Config/Duo.xcconfig", lambda: self.replace("Config/Duo.xcconfig", line, "DUO_ENTITLEMENTS = HydroDrop/HydroDrop.duo.entitlements")),
            ("Config/Duo.Release.xcconfig", lambda: self.replace("Config/Duo.Release.xcconfig", line, line + "\n" + line)),
            ("Config/Duo.Release.xcconfig", lambda: self.append("Config/Duo.Release.xcconfig",
                                                                "DUO_ENTITLEMENTS[sdk=iphoneos*] = HydroDrop/HydroDrop.duo.entitlements\n")),
            ("Config/Duo.Release.xcconfig", lambda: self.replace("Config/Duo.Release.xcconfig", line, "DUO_ENTITLEMENTS = $(PLAIN_ENTITLEMENTS)")),
            ("Config/Duo.xcconfig", lambda: (self.replace("Config/Duo.xcconfig", line + "\n", ""),
                                             self.append("Config/Duo.xcconfig", line + "\n"))),
        ]
        for number, (config, mutate) in enumerate(cases):
            with self.subTest(case=number):
                self.restore("Config/Duo.xcconfig")
                self.restore("Config/Duo.Release.xcconfig")
                mutate()
                self.assertFailsWith(self.preflight(), f"{config} must set DUO_ENTITLEMENTS = HydroDrop/HydroDrop.entitlements")

    def test_9b_lets_the_configurations_set_only_the_two_duo_settings(self):
        for config, line in (("Config/Duo.Release.xcconfig", "CODE_SIGN_ENTITLEMENTS = HydroDrop/HydroDrop.duo.entitlements"),
                             ("Config/Duo.xcconfig", "OTHER_SWIFT_FLAGS = -Onone"),
                             ("Config/Duo.Release.xcconfig", "GENERATE_INFOPLIST_FILE[sdk=iphoneos*] = YES"),
                             ("Config/Duo.xcconfig", "not a setting at all")):
            with self.subTest(line=line):
                self.restore("Config/Duo.xcconfig")
                self.restore("Config/Duo.Release.xcconfig")
                self.append(config, line + "\n")
                result = self.preflight()
                self.assertFailsWith(result, f"{config} sets something besides DUO_V2_CONDITION and DUO_ENTITLEMENTS")
                self.assertTrue(any(d.startswith(config + ":") for d in result.details), result.details)

    def test_9b_holds_every_target_to_its_own_entitlements(self):
        widget = "        CODE_SIGN_ENTITLEMENTS: HydroDropWidgets/HydroDropWidgets.entitlements\n"
        cases = [
            ("widget signs with Duo's", widget, '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n'),
            ("widget signs with none", widget, ""),
            ("Watch app gets a file", "        PRODUCT_BUNDLE_IDENTIFIER: com.jonathonbrown.HydroDrop.watchkitapp\n",
             "        PRODUCT_BUNDLE_IDENTIFIER: com.jonathonbrown.HydroDrop.watchkitapp\n"
             "        CODE_SIGN_ENTITLEMENTS: HydroDrop/HydroDrop.duo.entitlements\n"),
            ("project level", "    CODE_SIGN_STYLE: Automatic\n",
             "    CODE_SIGN_STYLE: Automatic\n    CODE_SIGN_ENTITLEMENTS: HydroDrop/HydroDrop.entitlements\n"),
            ("one SDK", '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n',
             '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n        CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]: "$(DUO_ENTITLEMENTS)"\n'),
        ]
        for name, old, new in cases:
            with self.subTest(name):
                self.restore("project.yml")
                self.replace("project.yml", old, new)
                self.assertFailsWith(self.preflight(), "only the app may sign with $(DUO_ENTITLEMENTS)")

    def test_9b_fails_when_release_reads_a_local_file(self):
        self.append("Config/Duo.Release.xcconfig", '#include? "Duo.local.xcconfig"\n')
        self.assertFailsWith(self.preflight(), "Config/Duo.Release.xcconfig includes another file")

    def test_9b_fails_when_duo_is_turned_on_by_default_or_by_name(self):
        cases = [
            (lambda: self.replace("Config/Duo.Release.xcconfig", "\nDUO_V2_CONDITION =\n", "\nDUO_V2_CONDITION = DUO_V2\n"),
             ["Config/Duo.Release.xcconfig must set DUO_V2_CONDITION to nothing", "DUO_V2 is set by name"]),
            (lambda: self.replace("Config/Duo.xcconfig", "\nDUO_V2_CONDITION =\n", "\nDUO_V2_CONDITION = DUO_V2\n"),
             ["Config/Duo.xcconfig must set DUO_V2_CONDITION to nothing"]),
            (lambda: self.append("Config/Duo.Release.xcconfig", "DUO_V2_CONDITION[sdk=iphoneos*] = DUO_V2\n"),
             ["Config/Duo.Release.xcconfig must set DUO_V2_CONDITION to nothing"]),
            (lambda: self.append("Config/Duo.Release.xcconfig", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) DUO_V2\n"),
             ["DUO_V2 is set by name"]),
            (lambda: self.replace("project.yml", 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) $(DUO_V2_CONDITION)"',
                                  'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DUO_V2"'), ["DUO_V2 is set by name"]),
            (lambda: self.replace("project.yml", '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n',
                                  '        CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"\n        OTHER_SWIFT_FLAGS: "-DDUO_V2"\n'),
             ["DUO_V2 is set by name"]),
        ]
        for number, (mutate, fragments) in enumerate(cases):
            with self.subTest(case=number):
                for rel in ("project.yml", "Config/Duo.xcconfig", "Config/Duo.Release.xcconfig"):
                    self.restore(rel)
                mutate()
                result = self.preflight()
                for fragment in fragments:
                    self.assertFailsWith(result, fragment)

    def test_9b_fails_when_a_configuration_file_is_remapped(self):
        for old, new in (("  Release: Config/Duo.Release.xcconfig", "  Release: Config/Duo.xcconfig"),
                         ("    type: application\n    platform: iOS\n",
                          "    type: application\n    platform: iOS\n    configFiles:\n      Release: Config/Other.xcconfig\n")):
            with self.subTest(new=new):
                self.restore("project.yml")
                self.replace("project.yml", old, new)
                self.assertFailsWith(self.preflight(), "project.yml must map Debug to Config/Duo.xcconfig and Release to")

    def test_9b_fails_when_a_background_mode_or_the_duo_refresh_identifier_goes(self):
        cases = [
            (lambda: self.replace("project.yml", "          - remote-notification\n", ""), "UIBackgroundModes lost remote-notification"),
            (lambda: self.replace("project.yml", "          - fetch\n", ""), "UIBackgroundModes lost fetch"),
            (lambda: self.edit_plist("HydroDrop/Info.plist", lambda i: i["UIBackgroundModes"].remove("fetch")), "UIBackgroundModes lost fetch"),
            (lambda: self.replace("project.yml", '          - "$(PRODUCT_BUNDLE_IDENTIFIER).duo.refresh"\n', ""),
             "BGTaskSchedulerPermittedIdentifiers lost"),
            (lambda: self.edit_plist("HydroDrop/Info.plist", lambda i: i.pop("BGTaskSchedulerPermittedIdentifiers")),
             "BGTaskSchedulerPermittedIdentifiers lost"),
        ]
        for number, (mutate, fragment) in enumerate(cases):
            with self.subTest(case=number):
                self.restore("project.yml")
                self.restore("HydroDrop/Info.plist")
                mutate()
                self.assertFailsWith(self.preflight(), fragment)

    # 9c -------------------------------------------------------------------------------------

    def write_aasa(self, details):
        write(self.root, "docs/.well-known/apple-app-site-association", json.dumps({"applinks": {"details": details}}))

    APP_ID = "YR8YP5788W.com.jonathonbrown.HydroDrop"

    def test_9c_fails_on_an_aasa_that_is_not_json(self):
        write(self.root, "docs/.well-known/apple-app-site-association", "{ not json")
        self.assertFailsWith(self.preflight(), "apple-app-site-association is not JSON")

    def test_9c_fails_when_duo_is_not_claimed_or_is_excluded(self):
        cases = {
            "missing": [{"appIDs": [self.APP_ID], "components": [{"/": "/tap*"}]}],
            "excluded": [{"appIDs": [self.APP_ID], "components": [{"/": "/tap*"}, {"/": "/duo", "exclude": True}]}],
            "excluded first": [{"appIDs": [self.APP_ID], "components": [{"/": "/d*", "exclude": True}, {"/": "/tap*"}, {"/": "/duo"}]}],
            "fragment rule": [{"appIDs": [self.APP_ID], "components": [{"/": "/tap*"}, {"/": "/duo", "#": "nothing"}]}],
            "other app": [{"appIDs": [self.APP_ID], "components": [{"/": "/tap*"}]},
                          {"appIDs": ["YR8YP5788W.com.example.Other"], "components": [{"/": "/duo"}]}],
            "paths NOT": [{"appID": self.APP_ID, "paths": ["NOT /duo", "/tap*", "/duo"]}],
            "named only as excluded": [{"appIDs": [self.APP_ID], "components": [{"/": "/d*"}, {"/": "/tap*"},
                                                                                 {"/": "/duo", "exclude": True}]}],
            "named only with a fragment rule": [{"appIDs": [self.APP_ID], "components": [{"/": "/d*"}, {"/": "/tap*"},
                                                                                          {"/": "/duo", "#": "x"}]}],
        }
        for name, details in cases.items():
            with self.subTest(name):
                self.write_aasa(details)
                result = self.preflight()
                self.assertFailsWith(result, f"does not claim /duo for {self.APP_ID}")
                self.assertTrue(any(o.startswith("the AASA claims /tap*") for o in result.oks), result.oks)

    def test_9c_takes_the_paths_form(self):
        self.write_aasa([{"appID": self.APP_ID, "paths": ["/tap*", "/duo"]}])
        self.assertEqual(self.preflight().fails, [])

    def test_9c_fails_when_the_app_is_not_named(self):
        self.write_aasa([{"appIDs": ["ABCDE12345.com.jonathonbrown.HydroDrop"], "components": [{"/": "/tap*"}, {"/": "/duo"}]}])
        self.assertFailsWith(self.preflight(), f"does not name {self.APP_ID}")

    def test_9c_fails_without_applinks_in_the_entitlements(self):
        for rel in (PLAIN, DUO_ENTS):
            self.edit_plist(rel, lambda e: e.update({"com.apple.developer.associated-domains": ["applinks:example.com"]}))
        result = self.preflight()
        self.assertFailsWith(result, "HydroDrop/HydroDrop.entitlements lacks applinks:hydrodrop.us")
        self.assertFailsWith(result, "HydroDrop/HydroDrop.duo.entitlements lacks applinks:hydrodrop.us")

    # 9d -------------------------------------------------------------------------------------

    def test_9d_fails_when_the_plain_manifest_declares_what_only_duo_collects(self):
        shutil.copy(os.path.join(REPO, DUO_MAN), os.path.join(self.root, MAN))
        self.assertFailsWith(self.preflight(), "HydroDrop/PrivacyInfo.xcprivacy declares collected data")

    def test_9d_fails_on_an_empty_duo_manifest(self):
        self.edit_plist(DUO_MAN, lambda m: m.update({"NSPrivacyCollectedDataTypes": []}))
        self.assertFailsWith(self.preflight(), "HydroDrop/Duo/PrivacyInfo.xcprivacy declares no collected data")

    def test_9d_fails_when_either_manifest_tracks_or_lists_a_tracking_domain(self):
        for rel in (MAN, DUO_MAN):
            with self.subTest(rel=rel):
                self.restore(MAN)
                self.restore(DUO_MAN)
                self.edit_plist(rel, lambda m: m.update({"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": ["api.example.com"]}))
                result = self.preflight()
                self.assertFailsWith(result, f"{rel}: NSPrivacyTracking must be false")
                self.assertFailsWith(result, f"{rel} lists tracking domains")

    def test_9d_fails_on_any_duo_entry_that_is_not_what_compliance_2_2_says(self):
        changes = {
            "a type missing": (lambda types: types.pop(3), "Health: missing"),
            "a type added": (lambda types: types.append(dict(types[0], **{PREFIX: PREFIX + "CrashData"})), "CrashData: not in compliance 2.2"),
            "a type twice": (lambda types: types.append(dict(types[0])), "Name: declared twice"),
            "not linked": (lambda types: types[1].update({PREFIX + "Linked": False}), "UserID: must be linked"),
            "tracking": (lambda types: types[2].update({PREFIX + "Tracking": True}), "DeviceID: must not be tracking"),
            "another purpose": (lambda types: types[4][PREFIX + "Purposes"].append(PREFIX + "PurposeAnalytics"),
                                "OtherUsageData: the purpose must be app functionality alone"),
        }
        for name, (change, line) in changes.items():
            with self.subTest(name):
                self.restore(DUO_MAN)
                self.edit_plist(DUO_MAN, lambda m: change(m["NSPrivacyCollectedDataTypes"]))
                result = self.preflight()
                self.assertFailsWith(result, "does not declare exactly what Duo Streaks collects")
                self.assertTrue(any(d.startswith(line) for d in result.details), result.details)

    def test_9d_fails_when_the_manifests_differ_in_anything_but_what_is_collected(self):
        self.edit_plist(DUO_MAN, lambda m: m["NSPrivacyAccessedAPITypes"].append(
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]}))
        result = self.preflight()
        self.assertFailsWith(result, "the two app manifests must differ only in NSPrivacyCollectedDataTypes")
        self.assertIn("NSPrivacyAccessedAPITypes", result.details)

    def test_9d_fails_when_project_yml_stops_choosing_by_the_condition(self):
        for key, value in (("EXCLUDED_SOURCE_FILE_NAMES", '"*/HydroDrop/Duo/PrivacyInfo.xcprivacy"'),
                           ("DUO_EXCLUDED_MANIFEST_", '"*/HydroDrop/PrivacyInfo.xcprivacy"'),
                           ("DUO_EXCLUDED_MANIFEST_DUO_V2", '"*/HydroDrop/Duo/PrivacyInfo.xcprivacy"'),
                           ("GENERATE_INFOPLIST_FILE", "YES"),
                           ("DUO_INFOPLIST_KEYS_", '"YES"'),
                           ("DUO_INFOPLIST_KEYS_DUO_V2", '"NO"')):
            with self.subTest(key=key):
                self.restore("project.yml")
                path = os.path.join(self.root, "project.yml")
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
                changed, n = re.subn(r"(?m)^(        " + re.escape(key) + r"): .*$", lambda m: f"{m.group(1)}: {value}", text, count=1)
                self.assertEqual(n, 1, key)
                write(self.root, "project.yml", changed)
                result = self.preflight()
                self.assertFailsWith(result, "project.yml no longer picks the manifest, the camera string and Duo's strings")
                self.assertTrue(any(d.startswith(key + " must be") for d in result.details), result.details)

    def test_9d_fails_when_duo_strings_reach_a_build_without_duo(self):
        cases = [
            ('        DUO_EXCLUDED_MANIFEST_: "*/HydroDrop/Duo/PrivacyInfo.xcprivacy Localizable.strings"\n',
             '        DUO_EXCLUDED_MANIFEST_: "*/HydroDrop/Duo/PrivacyInfo.xcprivacy"\n', "DUO_EXCLUDED_MANIFEST_ must be"),
            ('        EXCLUDED_SOURCE_FILE_NAMES: "$(DUO_EXCLUDED_STRINGS_$(DUO_V2_CONDITION))"\n', "",
             "HydroDrop Watch App: EXCLUDED_SOURCE_FILE_NAMES must be"),
            ('        DUO_EXCLUDED_STRINGS_: "Localizable.strings"\n', '        DUO_EXCLUDED_STRINGS_: "Other.strings"\n',
             "HydroDrop Watch App: DUO_EXCLUDED_STRINGS_ must be"),
            ('        DUO_EXCLUDED_STRINGS_: "Localizable.strings"\n',
             '        DUO_EXCLUDED_STRINGS_: "Localizable.strings"\n        DUO_EXCLUDED_STRINGS_DUO_V2: "Localizable.strings"\n',
             "HydroDrop Watch App: DUO_EXCLUDED_STRINGS_DUO_V2 must not be set"),
        ]
        for old, new, line in cases:
            with self.subTest(line=line):
                self.restore("project.yml")
                self.replace("project.yml", old, new)
                result = self.preflight()
                self.assertFailsWith(result, "project.yml no longer picks the manifest, the camera string and Duo's strings")
                self.assertTrue(any(d.startswith(line) for d in result.details), result.details)

    def test_9d_fails_without_the_camera_setting(self):
        path = os.path.join(self.root, "project.yml")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        write(self.root, "project.yml", re.sub(r"(?m)^\s*INFOPLIST_KEY_NSCameraUsageDescription:.*\n", "", text))
        self.assertFailsWith(self.preflight(), "project.yml has no INFOPLIST_KEY_NSCameraUsageDescription")

    def test_9d_fails_when_the_camera_string_is_back_in_info_plist_or_info_properties(self):
        self.edit_plist("HydroDrop/Info.plist", lambda i: i.update({"NSCameraUsageDescription": "camera"}))
        self.assertFailsWith(self.preflight(), "NSCameraUsageDescription is back in HydroDrop/Info.plist")
        self.restore("HydroDrop/Info.plist")
        self.replace("project.yml", "        NSSupportsLiveActivities: true\n",
                     '        NSCameraUsageDescription: "camera"\n        NSSupportsLiveActivities: true\n')
        self.assertFailsWith(self.preflight(), "NSCameraUsageDescription is back in project.yml info.properties")

    def test_9d_fails_a_lost_user_defaults_reason_and_warns_for_an_undeclared_api(self):
        self.edit_plist(MAN, lambda m: m["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"].remove("1C8F.1"))
        self.edit_plist(DUO_MAN, lambda m: m["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"].remove("1C8F.1"))
        write(self.root, "HydroDrop/Support/Age.swift", "let made = attrs[.creationDate]\n")
        result = self.preflight()
        self.assertFailsWith(result, "HydroDrop/PrivacyInfo.xcprivacy lacks the UserDefaults reason(s) 1C8F.1")
        self.assertFailsWith(result, "HydroDrop/Duo/PrivacyInfo.xcprivacy lacks the UserDefaults reason(s) 1C8F.1")
        self.assertTrue(any("gives no reason for FileTimestamp" in w for w in result.warns), result.warns)
        self.assertIn("HydroDrop/Support/Age.swift:1: creationDate", result.details)

    def test_9d_warns_and_does_not_fail_for_an_api_only(self):
        write(self.root, "HydroDrop/Support/Space.swift", "let v = keys.volumeAvailableCapacityForImportantUsageKey\n")
        result = self.preflight()
        self.assertEqual(result.fails, [], result.body)
        self.assertEqual(len(result.warns), 2, result.warns)  # one for each manifest

    def test_9d_fails_when_the_required_reason_script_is_missing(self):
        os.remove(os.path.join(self.root, "Scripts/check-required-reason-apis.py"))
        self.assertFailsWith(self.preflight(), "Scripts/check-required-reason-apis.py not found")

    # 9e, and the lines of sections 3, 3b and 4 this stage touched --------------------------------

    def test_9e_fails_on_a_duo_file_without_its_if(self):
        write(self.root, "HydroDrop/Duo/DuoLeak.swift", "import Foundation\nstruct DuoLeak {}\n")
        result = self.preflight()
        self.assertFailsWith(result, "Duo code that a build without DUO_V2 compiles")
        self.assertIn("HydroDrop/Duo/DuoLeak.swift:1: a Duo file must start with `#if DUO_V2`", result.body)

    def test_9e_fails_when_the_gating_script_is_missing(self):
        os.remove(os.path.join(self.root, "Scripts/check-duo-gating.py"))
        self.assertFailsWith(self.preflight(), "Scripts/check-duo-gating.py not found")

    def test_the_paywall_names_no_duo_streaks_before_they_ship(self):
        write(self.root, "HydroDrop/Views/PaywallView.swift", PAYWALL)
        self.assertIn("ok    no unshipped feature claims on the paywall", self.preflight().out)
        shutil.copy(os.path.join(REPO, "HydroDrop/Views/PaywallView.swift"), os.path.join(self.root, "HydroDrop/Views/PaywallView.swift"))
        self.assertIn("ok    no unshipped feature claims on the paywall", self.preflight().out, "today's paywall")
        for title, claim in (("Duo streak widget", "Duo streak"), ("More duo streaks", "More duo streaks"),
                             ("Duo Streaks with up to five friends", "Duo streak")):
            with self.subTest(title=title):
                write(self.root, "HydroDrop/Views/PaywallView.swift", PAYWALL.replace("Support indie development", title))
                self.assertIn(f"FAIL  paywall advertises '{claim}'", self.preflight().out)

    def test_a_long_paywall_cannot_hide_a_claim(self):
        # printf piped to grep -q under pipefail read a match as none once the text outgrew the
        # pipe: grep stopped at the match and the writer died of SIGPIPE.
        filler = "".join(f'let line{i} = "a paywall line long enough to fill the pipe"\n' for i in range(8000))
        write(self.root, "HydroDrop/Views/PaywallView.swift", PAYWALL.replace("Support indie development", "Duo streak widget") + filler)
        self.assertIn("FAIL  paywall advertises 'Duo streak'", self.preflight().out)

    def test_sections_3b_and_4_name_the_place_never_the_line(self):
        write(self.root, "HydroDrop/Support/Rotate.swift", f'let k = "TODO: rotate {STRIPE}"\n')
        write(self.root, "HydroDrop/Support/Ads2.swift", f'let r = Request(); let k = "{BEARER}"\n')
        write(self.root, "HydroDrop/Support/Ads3.swift", f'func go() {{ MobileAds.shared.start(); let k = "{DISCORD}" }}\n')
        out = self.preflight().out
        self.assertIn("HydroDrop/Support/Rotate.swift:1  (a placeholder string)", out)
        self.assertIn("HydroDrop/Support/Ads2.swift:1  (Request() outside AdManager)", out)
        self.assertIn("HydroDrop/Support/Ads3.swift:1  (MobileAds.shared.start)", out)


# ---------------------------------------------------------------------------------------------
# The release-safety review's preflight probes, by their ids
# ---------------------------------------------------------------------------------------------

def strip_duo_path(value):
    for detail in value["applinks"]["details"]:
        if "components" in detail:
            detail["components"] = [c for c in detail["components"] if c.get("/") != "/duo"]
        if "paths" in detail:
            detail["paths"] = [p for p in detail["paths"] if p != "/duo"]


class ReviewerViolationTests(Fixture):
    """Each probe of the review, on a fresh fixture: the FAIL (or WARN) it must raise, or PASS.
    "3:" and "4:" look at the whole output, for the paywall section and the placeholder one."""

    def settings(self, text):
        rel = "HydroDrop/Views/SettingsView.swift"
        if not os.path.exists(os.path.join(self.root, rel)):
            write(self.root, rel, "struct SettingsView {}\n")
        self.append(rel, text)

    def paywall(self, title):
        write(self.root, "HydroDrop/Views/PaywallView.swift", PAYWALL.replace("Support indie development", title))

    def aasa(self, change):
        rel = "docs/.well-known/apple-app-site-association"
        with open(os.path.join(self.root, rel), encoding="utf-8") as handle:
            value = json.load(handle)
        change(value)
        write(self.root, rel, json.dumps(value))

    def cases(self):
        w, p, s, a = (lambda *x: write(self.root, *x)), self.edit_plist, self.replace, self.append
        return [
            ("v01", lambda: w("HydroDrop/Support/Payments.swift", f'let key = "{STRIPE}"\n'), r"HydroDrop/Support/Payments\.swift:1  \(a Stripe live secret key\)"),
            ("v02", lambda: w("docs/config.json", json.dumps({"k": STRIPE}) + "\n"), r"docs/config\.json:1  \(a Stripe live secret key\)"),
            ("v03", lambda: w("notes/keys.md", f"key: {STRIPE}\n"), r"notes/keys\.md:1  \(a Stripe live secret key\)"),
            ("v04", lambda: w(".env.production", "X=1\n"), r"\.env\.production  \(an environment file"),
            ("v05", lambda: w("Certificates/dist.p12", "x"), r"Certificates/dist\.p12  \(a certificate"),
            ("v06", lambda: w("AuthKey_FAKE123.p8", "x"), r"AuthKey_FAKE123\.p8  \(a private key"),
            ("v07", lambda: w("HydroDrop/Views/Elsewhere.swift", 'import Foundation\n\nlet u = URL(string: "https://api-staging.hydrodrop.us/v1")!\n'),
             r"^HydroDrop/Views/Elsewhere\.swift:3$"),
            ("v08", lambda: w("HydroDropWidgets/Probe.swift", 'let u = "https://hydrodrop-api.someone.workers.dev"\n'), r"^HydroDropWidgets/Probe\.swift:1$"),
            ("v10", lambda: w("Scripts/smoke.sh", f"curl -H 'Authorization: {BEARER}' x\n"), r"Scripts/smoke\.sh:1  \(a Bearer token\)"),
            ("v11", lambda: w("notes/key.txt", PEM + "\nabc\n"), r"notes/key\.txt:1  \(a PEM private key\)"),
            ("v12", lambda: w("server.key", PEM + "\nabc\n"), r"server\.key  \(a private key file"),
            ("v13", lambda: w("HydroDrop/Support/Hook.swift", f'let hook = "{DISCORD}"\n'), r"HydroDrop/Support/Hook\.swift:1  \(a Discord webhook URL\)"),
            ("v14", lambda: w("build/leak.swift", f'let k = "{STRIPE}"\n'), "PASS"),
            ("v16", lambda: p("HydroDrop/Info.plist", lambda i: i.update({"DuoServer": "https://api.hydrodrop.us"})), r"^HydroDrop/Info\.plist:\d+$"),
            ("v17", lambda: a("project.yml", f"# {STRIPE}\n"), r"project\.yml:\d+  \(a Stripe live secret key\)"),
            ("v20", lambda: p(PLAIN, lambda e: e.update({"com.apple.developer.siri": True})), r"com\.apple\.developer\.siri: only in HydroDrop\.entitlements"),
            ("v21", lambda: p(PLAIN, lambda e: e.update({APP_ATTEST: "development"})), r"has the App Attest key"),
            ("v22", lambda: p(DUO_ENTS, lambda e: e.update({APP_ATTEST: "production"})), r"must set .* to development"),
            ("v23", lambda: s("Config/Duo.Release.xcconfig", "DUO_ENTITLEMENTS = HydroDrop/HydroDrop.entitlements", ""),
             r"Config/Duo\.Release\.xcconfig must set DUO_ENTITLEMENTS"),
            ("v24", lambda: s("project.yml", 'CODE_SIGN_ENTITLEMENTS: "$(DUO_ENTITLEMENTS)"', "CODE_SIGN_ENTITLEMENTS: HydroDrop/HydroDrop.duo.entitlements"),
             r"project\.yml must sign the app with"),
            ("v25", lambda: s("Config/Duo.Release.xcconfig", "\nDUO_V2_CONDITION =\n", "\nDUO_V2_CONDITION = DUO_V2\n"),
             r"Config/Duo\.Release\.xcconfig must set DUO_V2_CONDITION to nothing"),
            ("v25b", lambda: s("project.yml", '"$(inherited) $(DUO_V2_CONDITION)"', '"$(inherited) DUO_V2"'), r"DUO_V2 is set by name"),
            ("v26", lambda: a("Config/Duo.Release.xcconfig", "DUO_ENTITLEMENTS[sdk=iphoneos*] = HydroDrop/HydroDrop.duo.entitlements\n"),
             r"Config/Duo\.Release\.xcconfig must set DUO_ENTITLEMENTS"),
            ("v27", lambda: (p(PLAIN, lambda e: e.pop("aps-environment")), p(DUO_ENTS, lambda e: e.pop("aps-environment"))), r"has no aps-environment"),
            ("v28", lambda: a("Config/Duo.Release.xcconfig", '#include? "Duo.local.xcconfig"\n'), r"includes another file"),
            ("v29", lambda: s("project.yml", "          - remote-notification\n", ""), r"UIBackgroundModes lost remote-notification"),
            ("v30", lambda: s("project.yml", '          - "$(PRODUCT_BUNDLE_IDENTIFIER).duo.refresh"\n', ""), r"BGTaskSchedulerPermittedIdentifiers lost"),
            ("v31", lambda: self.aasa(strip_duo_path), r"does not claim /duo"),
            ("v32", lambda: w("docs/.well-known/apple-app-site-association", "{ nope"), r"is not JSON"),
            ("v33", lambda: p(PLAIN, lambda e: e.update({"com.apple.developer.associated-domains": []})), r"HydroDrop/HydroDrop\.entitlements lacks applinks"),
            ("v34", lambda: p(DUO_MAN, lambda m: m["NSPrivacyCollectedDataTypes"].append(dict(m["NSPrivacyCollectedDataTypes"][0], **{PREFIX: PREFIX + "CrashData"}))),
             r"CrashData: not in compliance 2\.2"),
            ("v34p", lambda: p(MAN, lambda m: m.update({"NSPrivacyCollectedDataTypes": [{PREFIX: PREFIX + "Name"}]})),
             r"HydroDrop/PrivacyInfo\.xcprivacy declares collected data"),
            ("v35", lambda: p(DUO_MAN, lambda m: m.update({"NSPrivacyTracking": True})), r"Duo/PrivacyInfo\.xcprivacy: NSPrivacyTracking must be false"),
            ("v36", lambda: p(MAN, lambda m: m.update({"NSPrivacyTrackingDomains": ["ads.example.com"]})), r"HydroDrop/PrivacyInfo\.xcprivacy lists tracking domains"),
            ("v37", lambda: p(MAN, lambda m: m.update({"NSPrivacyAccessedAPITypes": []})), r"HydroDrop/PrivacyInfo\.xcprivacy lacks the UserDefaults reason"),
            ("v38", lambda: p("HydroDrop/Info.plist", lambda i: i.update({"NSCameraUsageDescription": "HydroDrop uses the camera."})),
             r"NSCameraUsageDescription is back in HydroDrop/Info\.plist"),
            ("v39", lambda: s("project.yml", "        INFOPLIST_KEY_NSCameraUsageDescription:", "        # INFOPLIST_KEY_NSCameraUsageDescription:"),
             r"has no INFOPLIST_KEY_NSCameraUsageDescription"),
            ("v40", lambda: p(DUO_MAN, lambda m: m.update({"NSPrivacyCollectedDataTypes": []})), r"Duo/PrivacyInfo\.xcprivacy declares no collected data"),
            ("v41", lambda: w(MAN, "garbage"), r"HydroDrop/PrivacyInfo\.xcprivacy is not a property list"),
            ("v42", lambda: self.settings("\nlet probeStore = DuoStore.shared\n"), r"SettingsView\.swift:\d+: `DuoStore` is outside"),
            ("v43", lambda: self.settings("\n#if DUO_V2\nlet probeA = 1\n#else\nlet probeB = DuoStore.shared\n#endif\n"), r"SettingsView\.swift:\d+: `DuoStore`"),
            ("v44", lambda: self.settings('\nlet probeS = "\\(DuoStore.shared)"\n'), r"SettingsView\.swift:\d+: `DuoStore`"),
            ("v45", lambda: self.settings("\n/* harmless */ let probeC = DuoStore.shared\n"), r"SettingsView\.swift:\d+: `DuoStore`"),
            ("v47", lambda: s("HydroDrop/Duo/DuoConfig.swift", "\n#endif", "\n"),
             r"DuoConfig\.swift:\d+: this `#if` has no `#endif`"),
            ("v48", lambda: w("HydroDropWidgets/Note.swift", "// DuoAPIClient\n"), r"names `DuoAPIClient`"),
            ("v49", lambda: w("HydroDrop/Duo/DuoProbe.swift", "#if DUO_V2 || DEBUG\nstruct DuoProbe {}\n#endif\n"), r"DuoProbe\.swift:1: a Duo file must start"),
            ("v50", lambda: w("HydroDrop/Support/Age.swift", 'import Foundation\nlet made = try? FileManager.default.attributesOfItem(atPath: "/")[.creationDate]\n'),
             "WARN:gives no reason for FileTimestamp"),
            ("v51", lambda: w("HydroDrop/Support/Space.swift", 'import Foundation\nlet v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])\n'),
             "WARN:gives no reason for DiskSpace"),
            ("v52", lambda: self.paywall("Duo streak widget"), "3:paywall advertises 'Duo streak'"),
            ("v53", lambda: self.paywall("More duo streaks"), "3:paywall advertises 'More duo streaks'"),
            ("v54", lambda: self.paywall("Duo Streaks with up to five friends"), "3:paywall advertises 'Duo streak'"),
            ("v60", lambda: w("HydroDrop/Support/Rotate.swift", f'let k = "TODO: rotate {STRIPE}"\n'),
             "4:HydroDrop/Support/Rotate.swift:1  (a placeholder string)"),
            ("v61", lambda: w("json.py", "raise SystemExit('a stray json.py ran')\n"), "PASS"),
        ]

    def test_every_probe(self):
        pristine = self.root + "-pristine"
        shutil.copytree(self.root, pristine)
        try:
            for probe, mutate, expect in self.cases():
                with self.subTest(probe=probe):
                    shutil.rmtree(self.root)
                    shutil.copytree(pristine, self.root)
                    mutate()
                    result = self.preflight()
                    if expect == "PASS":
                        self.assertEqual(result.fails, [], result.body)
                    elif expect.startswith("WARN:"):
                        self.assertTrue(any(expect[5:] in w for w in result.warns), result.warns)
                        self.assertEqual(result.fails, [], result.body)
                    elif expect[:2] in ("3:", "4:"):
                        self.assertIn(expect[2:], result.out)
                        self.assertEqual(result.code, 1)
                    else:
                        lines = result.fails + result.details
                        self.assertTrue(any(re.search(expect, line) for line in lines), f"{expect!r} not in {lines}")
                        self.assertEqual(result.code, 1)
        finally:
            shutil.rmtree(pristine, ignore_errors=True)


# ---------------------------------------------------------------------------------------------
# release.sh, run from a copy with xcodebuild, codesign and xcrun stubbed
# ---------------------------------------------------------------------------------------------

XCODEBUILD_STUB = r'''#!/bin/bash
{ echo "== xcodebuild"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
archive=""; exportPath=""; options=""; mode=""; prev=""
for a in "$@"; do
  case "$prev" in -archivePath) archive="$a";; -exportPath) exportPath="$a";; -exportOptionsPlist) options="$a";; esac
  [ "$a" = archive ] && mode=archive
  [ "$a" = -exportArchive ] && mode=export
  prev="$a"
done
here=$PWD
if [ "$mode" = archive ]; then
  mkdir -p "$archive/Products/Applications"
  cp -R "$APPS/${FAKE_APP:-plain}/HydroDrop.app" "$archive/Products/Applications/"
  mkdir -p "$archive/Products/Applications/HydroDrop.app/Watch/HydroDrop Watch App.app"
  cat > "$archive/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>ApplicationProperties</key><dict><key>CFBundleShortVersionString</key><string>v</string><key>CFBundleVersion</key><string>b</string></dict></dict></plist>
P
elif [ "$mode" = export ]; then
  app="$archive/Products/Applications/HydroDrop.app"
  [ -n "${FAKE_IPA_APP:-}" ] && app="$APPS/$FAKE_IPA_APP/HydroDrop.app"
  t=$(mktemp -d); mkdir -p "$t/Payload"; cp -R "$app" "$t/Payload/"
  case "$options" in
    *upload*)
      n=$(ls "$SENT" | wc -l | tr -d ' ')
      (cd "$t" && /usr/bin/zip -qry "$SENT/sent-$n-xcode.ipa" Payload)
      [ -n "${XCB_STDOUT:-}" ] && printf '%s\n' "$XCB_STDOUT" ;;
    *)
      mkdir -p "$exportPath"
      case "$exportPath" in /*) dest="$exportPath";; *) dest="$here/$exportPath";; esac
      if [ -n "${FAKE_IPA_CORRUPT:-}" ]; then echo "not a zip" > "$dest/HydroDrop.ipa"
      else (cd "$t" && /usr/bin/zip -qry "$dest/HydroDrop.ipa" Payload); fi ;;
  esac
  rm -rf "$t"
fi
exit 0
'''
CODESIGN_STUB = r'''#!/bin/bash
{ echo "== codesign"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
for target; do :; done
case "$target" in
  *HydroDropWidgets.appex) kind="${WIDGET_ENTS:-extension}" ;;
  *"HydroDrop Watch App.app") kind="${WATCH_ENTS:-extension}" ;;
  *.xcarchive/*) kind="${ARCHIVE_ENTS:-plaindev}" ;;
  *) kind="${FAKE_ENTS:-plain}" ;;
esac
[ "$kind" = fail ] && exit 1
cat "$ENTS/$kind.plist"
'''
XCRUN_STUB = r'''#!/bin/bash
{ echo "== xcrun"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
if [ "$1" = altool ]; then
  prev=""; f=""
  for a in "$@"; do [ "$prev" = -f ] && f="$a"; prev="$a"; done
  n=$(ls "$SENT" | wc -l | tr -d ' ')
  cp "$f" "$SENT/sent-$n-altool.ipa"
  printf '%s\n' "${ALTOOL_OUT:-No errors uploading 'HydroDrop.ipa'}"
  exit 0
fi
exit 1
'''
ENTITLEMENT_KINDS = {
    "plain": {"aps-environment": "production"},
    "plaindev": {"aps-environment": "development"},
    "noaps": {},
    "duoprod": {"aps-environment": "production", APP_ATTEST: "production"},
    "duodev": {"aps-environment": "production", APP_ATTEST: "development"},
    "duoarchive": {"aps-environment": "development", APP_ATTEST: "development"},
    "duonoaps": {APP_ATTEST: "production"},
    "extension": {"com.apple.security.application-groups": ["group.com.jonathonbrown.HydroDrop"]},
    # Larger than a pipe holds, which is what made printf piped to grep -q fail under pipefail.
    "huge": dict({"aps-environment": "production"}, **{f"com.example.filler-{i:05d}": "x" * 40 for i in range(4000)}),
}
SIX = ["Name", "UserID", "DeviceID", "Health", "OtherUsageData", "OtherUserContent"]
WIDGET_MANIFEST = "PlugIns/HydroDropWidgets.appex/PrivacyInfo.xcprivacy"
WATCH_MANIFEST = "Watch/HydroDrop Watch App.app/PrivacyInfo.xcprivacy"
# Every step of a Duo build with the switch: the archive's app and signing, and the IPA's.
DUO = {"DUO_V2": "1", "FAKE_APP": "duo", "ARCHIVE_ENTS": "duoarchive", "FAKE_ENTS": "duoprod"}
ASC = {"ASC_API_KEY_ID": "KEYID", "ASC_API_ISSUER_ID": "ISSUER"}


class ReleaseHarness(Tree):

    def setUp(self):
        super().setUp()
        self.rel = os.path.join(self.root, "rel")
        for rel in ("Scripts/release.sh", "project.yml", "HydroDrop/HydroDrop.duo.entitlements", "Dependencies/Package.resolved"):
            os.makedirs(os.path.dirname(os.path.join(self.rel, rel)), exist_ok=True)
            shutil.copy(os.path.join(REPO, rel), os.path.join(self.rel, rel))
        write(self.rel, "docs/terms.html", "<h1>Duo Streaks rules</h1>\n")
        write(self.rel, "docs/privacy.html", '<section id="duo"><h2>Duo Streaks</h2></section>\n')
        write(self.rel, "Scripts/generate.sh", '#!/bin/sh\necho "== generate.sh" >> "$STUB_LOG"\n')
        write(self.rel, "Scripts/preflight.sh",
              "#!/bin/bash\n{ echo \"== preflight.sh\"; printf '[%s]\\n' \"$@\"; } >> \"$STUB_LOG\"\nexit ${PREFLIGHT_RC:-0}\n")
        git = ["git", "-C", self.rel, "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run(["git", "init", "-q", self.rel], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-qm", "copy"], check=True)
        self.bin = os.path.join(self.root, "bin")
        for name, text in (("xcodebuild", XCODEBUILD_STUB), ("codesign", CODESIGN_STUB), ("xcrun", XCRUN_STUB)):
            os.chmod(write(self.bin, name, text), 0o755)
        self.ents = os.path.join(self.root, "ents")
        for kind, value in ENTITLEMENT_KINDS.items():
            write(self.ents, f"{kind}.plist", plistlib.dumps(value), "wb")
        self.apps = os.path.join(self.root, "apps")
        self.app("plain", duo=False)
        self.app("duo", duo=True)
        self.sent = os.path.join(self.root, "sent")
        os.makedirs(self.sent)
        self.log = os.path.join(self.root, "stub.log")
        for folder in ("home", "tmp"):
            os.makedirs(os.path.join(self.root, folder))

    def app(self, name, duo, camera=None, types=None, tracking_in=None, drop=None, binary=True, strings=None):
        """A fake HydroDrop.app: its binary names DuoAPIClient only with Duo, and it carries the
        three manifests, the app's collected types and the camera string the switch implies,
        unless an argument changes one of them."""
        app = os.path.join(self.apps, name, "HydroDrop.app")
        os.makedirs(app)
        if binary:
            write(app, "HydroDrop", "\0binary " + name + (" DuoAPIClient" if duo else "") + "\n")
        info = {"CFBundleIdentifier": "com.jonathonbrown.HydroDrop"}
        if (duo if camera is None else camera):
            info["NSCameraUsageDescription"] = "camera"
        write(app, "Info.plist", plistlib.dumps(info), "wb")
        for where in ((["app", "watch"] if duo else []) if strings is None else strings):
            folder = "" if where == "app" else "Watch/HydroDrop Watch App.app/"
            write(app, folder + "en.lproj/Localizable.strings", '"duo.nudge.title" = "%@ nudged you";\n')
        count = (6 if duo else 0) if types is None else types
        for rel in ("PrivacyInfo.xcprivacy", WIDGET_MANIFEST, WATCH_MANIFEST):
            if rel == drop:
                continue
            value = {"NSPrivacyTracking": rel == (tracking_in or ""), "NSPrivacyTrackingDomains": [],
                     "NSPrivacyCollectedDataTypes": [{PREFIX: PREFIX + SIX[i % 6]} for i in range(count)] if rel == "PrivacyInfo.xcprivacy" else []}
            write(app, rel, plistlib.dumps(value), "wb")
        return name

    def version(self, value):
        path = os.path.join(self.rel, "project.yml")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        write(self.rel, "project.yml", re.sub(r'(?m)^(\s*MARKETING_VERSION:).*$', rf'\1 "{value}"', text))

    def release(self, *args, **env):
        environment = {"PATH": self.bin + ":" + SYSTEM_PATH, "HOME": os.path.join(self.root, "home"),
                       "TMPDIR": os.path.join(self.root, "tmp"), "TERM": "dumb", "STUB_LOG": self.log,
                       "ENTS": self.ents, "APPS": self.apps, "SENT": self.sent}
        environment.update(env)
        return run(["/bin/bash", "Scripts/release.sh", *args], cwd=self.rel, env=environment)

    def steps(self, *runs):
        """Runs each (args, env) in turn and returns the exit codes and the outputs."""
        results = [self.release(*args, **env) for args, env in runs]
        return [code for code, _ in results], "\n".join(out for _, out in results)

    def sent_kinds(self):
        kinds = []
        for name in sorted(os.listdir(self.sent), key=lambda n: int(n.split("-")[1])):
            with zipfile.ZipFile(os.path.join(self.sent, name)) as archive:
                binary = archive.read("Payload/HydroDrop.app/HydroDrop").decode("utf-8", "replace")
            kinds.append(binary.split("binary ", 1)[1].split()[0])
        return kinds

    def calls(self, tool):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            blocks = handle.read().split("== ")[1:]
        return [re.findall(r"^\[(.*)\]$", block, re.M) for block in blocks if block.startswith(tool + "\n")]

    def export_dir(self):
        path = os.path.join(self.rel, "build")
        return [d for d in os.listdir(path) if d.startswith("export-")] if os.path.isdir(path) else []

    def ipa_exists(self):
        return any(os.path.exists(os.path.join(self.rel, "build", d, "HydroDrop.ipa")) for d in self.export_dir())


ARCHIVE = (("archive",), {})
EXPORT = (("export",), {})


class ReleaseTests(ReleaseHarness):

    # status, usage and bump (c01 to c09, d01 to d09) --------------------------------------

    def test_c01_c02_d01_to_d03_status_says_what_the_switch_does(self):
        for env, line in (({}, "DUO_V2             unset: no Duo Streaks, plain entitlements, main's privacy manifest, no camera string"),
                          (dict(ASC, HYDRODROP_TEAM_ID="T"), "ASC_API_KEY_ID     set"),
                          ({"DUO_V2": "1"}, "DUO_V2             set: Duo Streaks compiled in, App Attest, the Duo privacy manifest"),
                          ({"DUO_V2": "0"}, "DUO_V2             unset"), ({"DUO_V2": ""}, "DUO_V2             unset")):
            with self.subTest(env=env):
                code, out = self.release("status", **env)
                self.assertEqual(code, 0, out)
                self.assertIn(line, out)

    def test_c03_c04_print_the_usage(self):
        for args in ((), ("frobnicate",)):
            code, out = self.release(*args)
            self.assertEqual(code, 2, out)
            self.assertIn("DUO_V2=1 Scripts/release.sh archive|export|upload", out)
            self.assertIn("a new archive removes the IPA an earlier one left", out)

    def test_d04_to_d08_a_switch_that_is_not_1_stops_the_script(self):
        for value in ("true", " 1", "01", "1 ", "yes", "1\n"):
            with self.subTest(value=value):
                code, out = self.release("status", DUO_V2=value)
                self.assertEqual(code, 1, out)
                self.assertIn(f"DUO_V2 is '{value}'", out)

    def test_c05_to_c09_d09_bump(self):
        for args, env, code_wanted, fragment in ((("bump", "35"), {}, 0, 'CURRENT_PROJECT_VERSION: "35"'),
                                                 (("bump", "35", "1.9"), {}, 0, 'MARKETING_VERSION: "1.9"'),
                                                 (("bump", "34"), {}, 1, None), (("bump", "abc"), {}, 1, None),
                                                 (("bump", "35", "1.9.x"), {}, 1, None),
                                                 (("bump", "35"), {"DUO_V2": "yes"}, 1, None)):
            with self.subTest(args=args, env=env):
                subprocess.run(["git", "-C", self.rel, "checkout", "-q", "--", "project.yml"], check=True)
                code, out = self.release(*args, **env)
                self.assertEqual(code, code_wanted, out)
                if fragment:
                    with open(os.path.join(self.rel, "project.yml"), encoding="utf-8") as handle:
                        self.assertIn(fragment, handle.read())

    # archive (c10, c11, d10, d15, d17) ----------------------------------------------------

    def test_c10_a_plain_archive_passes_no_duo_setting(self):
        code, out = self.release("archive")
        self.assertEqual(code, 0, out)
        args = self.calls("xcodebuild")[0]
        self.assertEqual(args[-2:], ["archive", "-quiet"])
        self.assertFalse([a for a in args if a.startswith("DUO_")], args)
        self.assertEqual(self.calls("preflight.sh"), [[self.rel]])
        self.assertTrue(self.calls("generate.sh"))

    def test_c11_a_failed_preflight_stops_the_archive(self):
        code, out = self.release("archive", PREFLIGHT_RC="1")
        self.assertEqual(code, 1, out)
        self.assertIn("preflight failed", out)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_d10_a_duo_archive_needs_version_2(self):
        for version, wanted in (("1.8.1", 1), ("1.9.9", 1), ("2.0", 0), ("10.0", 0)):
            with self.subTest(version=version):
                os.remove(self.log) if os.path.exists(self.log) else None
                self.version(version)
                code, out = self.release("archive", **DUO)
                self.assertEqual(code, wanted, out)
                if wanted:
                    self.assertIn("needs MARKETING_VERSION 2.0 or higher", out)
                    self.assertEqual(self.calls("xcodebuild"), [])

    def test_d10_a_duo_archive_adds_exactly_the_two_settings(self):
        self.version("2.0")
        self.release("archive")
        plain = self.calls("xcodebuild")[0]
        os.remove(self.log)
        code, out = self.release("archive", **DUO)
        self.assertEqual(code, 0, out)
        duo = self.calls("xcodebuild")[0]
        self.assertEqual(duo[-4:], ["DUO_V2_CONDITION=DUO_V2", "DUO_ENTITLEMENTS=HydroDrop/HydroDrop.duo.entitlements", "archive", "-quiet"])
        self.assertEqual(duo[:-4], plain[:-2])

    def test_d15_d17_a_bad_switch_or_a_missing_duo_file_builds_nothing(self):
        code, out = self.release("archive", DUO_V2="true")
        self.assertEqual(code, 1, out)
        self.version("2.0")
        os.remove(os.path.join(self.rel, "HydroDrop/HydroDrop.duo.entitlements"))
        code, out = self.release("archive", **DUO)
        self.assertEqual(code, 1, out)
        self.assertIn("HydroDrop.duo.entitlements is missing", out)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_the_archive_is_checked_against_the_switch(self):
        self.version("2.0")
        for env, fragment in ((dict(DUO, FAKE_APP="plain"), "no Duo Streaks (no DuoAPIClient)"),
                              ({"FAKE_APP": "duo"}, "compiled in (DuoAPIClient), but DUO_V2 is unset"),
                              (dict(DUO, ARCHIVE_ENTS="plaindev"), "the archive lacks")):
            with self.subTest(env=env):
                code, out = self.release("archive", **env)
                self.assertEqual(code, 1, out)
                self.assertIn(fragment, out)
                self.assertIn("is not what DUO_V2 asks for", out)

    def test_a_new_archive_removes_the_ipa_an_earlier_one_left(self):
        codes, out = self.steps(ARCHIVE, EXPORT)
        self.assertEqual(codes, [0, 0], out)
        self.assertTrue(self.ipa_exists())
        code, out = self.release("archive")
        self.assertEqual(code, 0, out)
        self.assertFalse(self.ipa_exists())

    # export (c12 to c16, d11 to d14, d18, d19, d22) -------------------------------------

    def test_c12_export_needs_an_archive(self):
        code, out = self.release("export")
        self.assertEqual(code, 1, out)
        self.assertIn("no archive", out)

    def test_c13_d11_good_ipas_are_exported(self):
        codes, out = self.steps(ARCHIVE, EXPORT)
        self.assertEqual(codes, [0, 0], out)
        self.assertTrue(self.ipa_exists())
        self.version("2.0")
        codes, out = self.steps((("archive",), DUO), (("export",), DUO))
        self.assertEqual(codes, [0, 0], out)
        self.assertTrue(self.ipa_exists())

    def refused(self, archive_env, export_env, fragment):
        codes, out = self.steps((("archive",), archive_env), (("export",), export_env))
        self.assertEqual(codes, [0, 1], out)
        self.assertIn(fragment, out)
        self.assertIn("export refused the IPA and removed", out)
        self.assertFalse(self.ipa_exists(), "a refused IPA was left for upload")

    def test_c14_c15_c16_plain_exports_that_are_refused(self):
        for env, fragment in (({"FAKE_ENTS": "noaps"}, "lacks aps-environment=production"),
                              ({"FAKE_ENTS": "fail"}, "lacks aps-environment=production"),
                              ({"FAKE_ENTS": "duoprod"}, "but DUO_V2 is unset")):
            with self.subTest(env=env):
                self.refused({}, env, fragment)

    def test_d12_d13_d14_d18_d19_d22_duo_exports_that_are_refused(self):
        self.version("2.0")
        for env, fragment in ((dict(DUO, FAKE_ENTS="duodev"), f"lacks {APP_ATTEST}=production"),
                              (dict(DUO, FAKE_ENTS="plain"), f"lacks {APP_ATTEST}=production"),
                              (dict(DUO, FAKE_ENTS="duonoaps"), "lacks aps-environment=production"),
                              ({"FAKE_ENTS": "duoprod"}, "but DUO_V2 is unset"),
                              (dict(DUO, FAKE_ENTS="fail"), "lacks aps-environment=production"),
                              ({"DUO_V2": "0", "FAKE_ENTS": "duoprod"}, "but DUO_V2 is unset")):
            with self.subTest(env=env):
                self.refused(DUO, env, fragment)

    def test_export_checks_the_code_the_manifests_and_the_camera_string(self):
        self.app("plain-with-duo", duo=True)
        self.app("duo-without", duo=False, camera=True, types=6)
        self.app("plain-six", duo=False, types=6)
        self.app("duo-none", duo=True, types=0)
        self.app("plain-camera", duo=False, camera=True)
        self.app("duo-no-camera", duo=True, camera=False)
        self.app("no-widget", duo=False, drop=WIDGET_MANIFEST)
        self.app("no-watch", duo=False, drop=WATCH_MANIFEST)
        self.app("no-app-manifest", duo=False, drop="PrivacyInfo.xcprivacy")
        self.app("widget-tracks", duo=False, tracking_in=WIDGET_MANIFEST)
        self.app("app-tracks", duo=False, tracking_in="PrivacyInfo.xcprivacy")
        self.app("no-binary", duo=False, binary=False)
        self.app("plain-app-strings", duo=False, strings=["app"])
        self.app("plain-watch-strings", duo=False, strings=["watch"])
        self.app("duo-no-app-strings", duo=True, strings=["watch"])
        self.app("duo-no-watch-strings", duo=True, strings=["app"])
        self.version("2.0")
        cases = [
            ({}, {"FAKE_IPA_APP": "plain-with-duo"}, "compiled in (DuoAPIClient), but DUO_V2 is unset"),
            (DUO, dict(DUO, FAKE_IPA_APP="duo-without"), "no Duo Streaks (no DuoAPIClient)"),
            ({}, {"FAKE_IPA_APP": "plain-six"}, "declares 6 collected data type(s); a build without Duo declares 0"),
            (DUO, dict(DUO, FAKE_IPA_APP="duo-none"), "declares 0 collected data type(s); a build with Duo declares 6"),
            ({}, {"FAKE_IPA_APP": "plain-camera"}, "Info.plist has NSCameraUsageDescription; a build without Duo has none"),
            (DUO, dict(DUO, FAKE_IPA_APP="duo-no-camera"), "Info.plist lacks NSCameraUsageDescription; a build with Duo has it"),
            ({}, {"FAKE_IPA_APP": "plain-app-strings"}, "the app/Localizable.strings is there; a build without Duo has none"),
            ({}, {"FAKE_IPA_APP": "plain-watch-strings"}, "Watch/HydroDrop Watch App.app/Localizable.strings is there; a build without Duo has none"),
            (DUO, dict(DUO, FAKE_IPA_APP="duo-no-app-strings"), "the app/Localizable.strings is missing; a build with Duo has one"),
            (DUO, dict(DUO, FAKE_IPA_APP="duo-no-watch-strings"), "Watch/HydroDrop Watch App.app/Localizable.strings is missing; a build with Duo has one"),
            ({}, {"FAKE_ENTS": "plaindev"}, "lacks aps-environment=production"),
            ({}, {"FAKE_IPA_CORRUPT": "1"}, "cannot be unzipped"),
            ({}, {"WIDGET_ENTS": "duoprod"}, f"PlugIns/HydroDropWidgets.appex is signed with {APP_ATTEST}"),
            ({}, {"WATCH_ENTS": "duoprod"}, f"Watch/HydroDrop Watch App.app is signed with {APP_ATTEST}"),
            (DUO, dict(DUO, WIDGET_ENTS="duoprod"), f"PlugIns/HydroDropWidgets.appex is signed with {APP_ATTEST}"),
            ({}, {"WIDGET_ENTS": "fail"}, "cannot read the entitlements of PlugIns/HydroDropWidgets.appex"),
            ({}, {"FAKE_IPA_APP": "no-widget"}, f"no privacy manifest at {WIDGET_MANIFEST}"),
            ({}, {"FAKE_IPA_APP": "no-watch"}, f"no privacy manifest at {WATCH_MANIFEST}"),
            ({}, {"FAKE_IPA_APP": "no-app-manifest"}, "no privacy manifest at PrivacyInfo.xcprivacy"),
            ({}, {"FAKE_IPA_APP": "widget-tracks"}, f"{WIDGET_MANIFEST} does not say NSPrivacyTracking false"),
            ({}, {"FAKE_IPA_APP": "app-tracks"}, "PrivacyInfo.xcprivacy does not say NSPrivacyTracking false"),
            ({}, {"FAKE_IPA_APP": "no-binary"}, "has no HydroDrop binary"),
        ]
        for archive_env, export_env, fragment in cases:
            with self.subTest(app=export_env.get("FAKE_IPA_APP"), env=export_env):
                self.refused(archive_env, export_env, fragment)

    # upload (c17 to c23, d16, d20, d21, d23, d24) -------------------------------------------

    def test_c17_c18_d16_d20_good_uploads_send_what_was_built(self):
        codes, out = self.steps(ARCHIVE, (("upload",), ASC))
        self.assertEqual(codes, [0, 0], out)
        codes, out = self.steps(ARCHIVE, (("upload",), {"XCB_STDOUT": "Upload succeeded"}))
        self.assertEqual(codes, [0, 0], out)
        self.version("2.0")
        codes, out = self.steps((("archive",), DUO), (("upload",), dict(DUO, **ASC)))
        self.assertEqual(codes, [0, 0], out)
        codes, out = self.steps((("archive",), DUO), (("upload",), dict(DUO, XCB_STDOUT="Upload succeeded")))
        self.assertEqual(codes, [0, 0], out)
        self.assertEqual(self.sent_kinds(), ["plain", "plain", "duo", "duo"])

    def test_c19_c20_c21_failed_uploads(self):
        closed = "ERROR ITMS-90062: The train version 1.8.1 is closed for new build submissions"
        codes, out = self.steps(ARCHIVE, (("upload",), dict(ASC, ALTOOL_OUT=closed)))
        self.assertEqual(codes, [0, 1], out)
        self.assertIn("has already approved", out)
        codes, out = self.steps((("upload",), dict(ASC, ALTOOL_OUT="*** Error: something")),)
        self.assertEqual(codes, [1], out)
        self.assertIn("did not report success", out)
        shutil.rmtree(os.path.join(self.rel, "build"))
        code, out = self.release("upload")
        self.assertEqual(code, 1, out)
        self.assertIn("no archive", out)

    def test_c22_upload_checks_and_sends_the_ipa_already_exported(self):
        codes, out = self.steps(ARCHIVE, EXPORT, (("upload",), ASC))
        self.assertEqual(codes, [0, 0, 0], out)
        self.assertIn("checking the IPA already exported", out)
        self.assertEqual(self.sent_kinds(), ["plain"])
        self.assertEqual(len([c for c in self.calls("xcodebuild") if "-exportArchive" in c]), 1)

    def test_c23_d23_d24_upload_never_sends_an_ipa_export_refused(self):
        codes, out = self.steps(ARCHIVE, (("export",), {"FAKE_ENTS": "noaps"}), (("upload",), dict(ASC, FAKE_ENTS="noaps")))
        self.assertEqual(codes, [0, 1, 1], out)
        self.version("2.0")
        codes, out = self.steps((("archive",), DUO), (("export",), {"FAKE_ENTS": "duoprod"}),
                                (("upload",), dict(ASC, FAKE_ENTS="duoprod")))
        self.assertEqual(codes, [0, 1, 1], out)
        codes, out = self.steps((("archive",), DUO), (("upload",), dict(DUO, FAKE_ENTS="duodev", **ASC)),
                                (("upload",), dict(DUO, FAKE_ENTS="duodev", **ASC)))
        self.assertEqual(codes, [0, 1, 1], out)
        self.assertEqual(self.sent_kinds(), [])

    def test_d21_a_plain_upload_after_a_duo_export_sends_the_plain_build(self):
        self.version("2.0")
        codes, out = self.steps((("archive",), DUO), (("export",), DUO), ARCHIVE, (("upload",), ASC))
        self.assertEqual(codes, [0, 0, 0, 0], out)
        self.assertEqual(self.sent_kinds(), ["plain"])

    def test_upload_refuses_a_stale_ipa_it_finds(self):
        self.version("2.0")
        codes, out = self.steps((("archive",), DUO), (("export",), DUO))
        self.assertEqual(codes, [0, 0], out)
        # A Duo IPA from an earlier run, uploaded without the switch: checked, refused, removed.
        code, out = self.release("upload", FAKE_ENTS="duoprod", **ASC)
        self.assertEqual(code, 1, out)
        self.assertIn("fails the export checks, so it was removed and nothing was sent", out)
        self.assertFalse(self.ipa_exists())
        self.assertEqual(self.sent_kinds(), [])

    def test_d20_the_xcode_account_upload_checks_the_archive_first(self):
        self.version("2.0")
        for archive_env, upload_env, fragment in ((DUO, {"XCB_STDOUT": "Upload succeeded"}, "but DUO_V2 is unset"),
                                                  ({}, {"DUO_V2": "1", "XCB_STDOUT": "Upload succeeded"}, "the archive lacks"),
                                                  (DUO, dict(DUO, ARCHIVE_ENTS="plaindev", XCB_STDOUT="Upload succeeded"), "the archive lacks")):
            with self.subTest(archive=archive_env, upload=upload_env):
                codes, out = self.steps((("archive",), archive_env), (("upload",), upload_env))
                self.assertEqual(codes, [0, 1], out)
                self.assertIn(fragment, out)
                self.assertIn("so nothing was sent", out)
        self.assertEqual(self.sent_kinds(), [])

    # the second round: the website's Duo pages, signatures, the switch's value ------------

    def test_o16_a_duo_archive_needs_the_websites_duo_pages(self):
        self.version("2.0")
        privacy = os.path.join(self.rel, "docs/privacy.html")
        for change, fragment in ((lambda: os.remove(os.path.join(self.rel, "docs/terms.html")), "docs/terms.html (the Duo Streaks rules) is missing"),
                                 (lambda: write(self.rel, "docs/privacy.html", "<h2>Privacy</h2>\n"), "has no Duo Streaks section"),
                                 (lambda: write(self.rel, "docs/privacy.html", '<section id="duo"></section><p>HydroDrop runs no servers.</p>\n'),
                                  "still says HydroDrop runs no servers"),
                                 (lambda: os.remove(privacy), "docs/privacy.html is missing")):
            with self.subTest(fragment=fragment):
                write(self.rel, "docs/terms.html", "<h1>Duo Streaks rules</h1>\n")
                write(self.rel, "docs/privacy.html", '<section id="duo"><h2>Duo Streaks</h2></section>\n')
                if os.path.exists(self.log):
                    os.remove(self.log)
                change()
                code, out = self.release("archive", **DUO)
                self.assertEqual(code, 1, out)
                self.assertIn(fragment, out)
                self.assertIn("needs the website's Duo pages first", out)
                self.assertEqual(self.calls("xcodebuild"), [])
        write(self.rel, "docs/terms.html", "<h1>Duo Streaks rules</h1>\n")
        write(self.rel, "docs/privacy.html", "<section id='duo'></section>\n")
        code, out = self.release("archive", **DUO)
        self.assertEqual(code, 0, out)
        self.assertIn("by hand before this build goes out: compliance 1.8 keeps TM1", out)
        os.remove(os.path.join(self.rel, "docs/terms.html"))
        code, out = self.release("archive")
        self.assertEqual(code, 0, "a build without Duo does not need the Duo pages")
        self.assertNotIn("by hand before this build goes out", out)

    def test_o19_an_unreadable_or_incomplete_archive_signature_is_refused(self):
        for env in ({"ARCHIVE_ENTS": "fail"}, {"ARCHIVE_ENTS": "noaps"}):
            with self.subTest(env=env):
                codes, out = self.steps(ARCHIVE, (("upload",), dict(env, XCB_STDOUT="Upload succeeded")))
                self.assertEqual(codes, [0, 1], out)
                self.assertIn("lacks aps-environment, or its entitlements cannot be read", out)
        self.assertEqual(self.sent_kinds(), [])
        calls = self.calls("codesign")
        self.assertTrue(calls and all("--xml" in c and ":-" not in c for c in calls), calls)

    def test_o20_the_archive_check_covers_the_widget_and_the_watch_app(self):
        for env, fragment in (({"WIDGET_ENTS": "duoarchive"}, "PlugIns/HydroDropWidgets.appex is signed with"),
                              ({"WATCH_ENTS": "duoarchive"}, "Watch/HydroDrop Watch App.app is signed with"),
                              ({"WATCH_ENTS": "fail"}, "cannot read the entitlements of Watch/HydroDrop Watch App.app")):
            with self.subTest(env=env):
                code, out = self.release("archive", **env)
                self.assertEqual(code, 1, out)
                self.assertIn(fragment, out)

    def test_o21_a_bad_switch_stops_every_command_before_it_starts(self):
        code, out = self.release("archive")
        self.assertEqual(code, 0, out)
        os.remove(self.log)
        for args in (("export",), ("upload",), ("bump", "35"), ()):
            with self.subTest(args=args):
                code, out = self.release(*args, DUO_V2="yes", **ASC)
                self.assertEqual(code, 1, out)
                self.assertIn("DUO_V2 is 'yes'", out)
        self.assertEqual(self.calls("xcodebuild"), [])
        self.assertEqual(os.listdir(os.path.join(self.root, "tmp")), [])
        self.assertEqual(self.sent_kinds(), [])

    # the functions on their own, sourced ---------------------------------------------------

    def sourced(self, script, duo):
        env = {"PATH": SYSTEM_PATH, "HOME": os.path.join(self.root, "home"), "TERM": "dumb"}
        if duo is not None:
            env["DUO_V2"] = duo
        return run(["/bin/bash", "-c", f'source "{RELEASE}"\n{script}'], env=env)

    def test_sourcing_runs_no_command(self):
        code, out = self.sourced("echo sourced", None)
        self.assertEqual((code, out.strip()), (0, "sourced"))

    def test_the_duo_settings_are_added_only_with_the_switch(self):
        script = 'duo_settings; for a in ${DUO_SETTINGS[@]+"${DUO_SETTINGS[@]}"}; do echo "<$a>"; done; echo end'
        self.assertEqual(self.sourced(script, None), (0, "end\n"))
        code, out = self.sourced(script, "1")
        self.assertEqual(out.split(), ["<DUO_V2_CONDITION=DUO_V2>", "<DUO_ENTITLEMENTS=HydroDrop/HydroDrop.duo.entitlements>", "end"])

    def test_a_long_signature_is_read_whole(self):
        codes, out = self.steps(ARCHIVE, (("export",), {"FAKE_ENTS": "huge"}))
        self.assertEqual(codes, [0, 0], out)
        big = f'"{APP_ATTEST}" => "production"\n' + "".join(f'"filler{i}" => "{"x" * 40}"\n' for i in range(4000))
        code, out = self.sourced(f"check_app_attest '{big}' production", "1")
        self.assertEqual(code, 0, out[:300])
        code, out = self.sourced(f"check_app_attest '{big}' production", None)
        self.assertEqual(code, 1, out[:300])

    def test_check_app_attest_by_the_switch(self):
        production = f'"aps-environment" => "production"\n"{APP_ATTEST}" => "production"'
        development = f'"aps-environment" => "production"\n"{APP_ATTEST}" => "development"'
        none = '"aps-environment" => "production"'
        for duo, signed, mode, expected in (("1", production, "production", 0), ("1", development, "production", 1),
                                            ("1", development, "any", 0), ("1", none, "production", 1), ("1", none, "any", 1),
                                            (None, none, "production", 0), (None, production, "production", 1),
                                            (None, development, "any", 1)):
            with self.subTest(duo=duo, signed=signed, mode=mode):
                code, out = self.sourced(f"check_app_attest '{signed}' {mode}", duo)
                self.assertEqual(code, expected, out)


if __name__ == "__main__":
    unittest.main()
