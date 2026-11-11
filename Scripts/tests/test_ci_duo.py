"""Runner selection tests use disposable fixtures; no CI job, signing or upload runs."""

import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("configure_ci_duo", ROOT / "Scripts/configure_ci_duo.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CloudDuoSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hydrodrop-ci-duo-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Config").mkdir()
        (self.root / "HydroDrop").mkdir()
        for relative in ("Config/Duo.xcconfig", "Config/Duo.Release.xcconfig",
                         "HydroDrop/HydroDrop.entitlements", "HydroDrop/HydroDrop.duo.entitlements"):
            shutil.copy2(ROOT / relative, self.root / relative)
        (self.root / "project.yml").write_text('  MARKETING_VERSION: "2.0"\n  MARKETING_VERSION: "2.0"\n')
        self.env = {"CI_BUILD_NUMBER": "35"}

    def configs(self):
        return [(self.root / "Config" / name).read_text() for name in ("Duo.xcconfig", "Duo.Release.xcconfig")]

    def assert_selection(self, enabled):
        for text in self.configs():
            condition = "DUO_V2" if enabled else ""
            entitlement = "HydroDrop.duo.entitlements" if enabled else "HydroDrop.entitlements"
            self.assertRegex(text, r"(?m)^DUO_V2_CONDITION = " + condition + r"$")
            self.assertIn("DUO_ENTITLEMENTS = HydroDrop/" + entitlement, text)
            self.assertNotRegex(text, r"(?m)^\s*#include")

    def rejected_unchanged(self, env=None):
        before = self.configs()
        with self.assertRaises(ValueError):
            module.configure(self.root, env or self.env)
        self.assertEqual(before, self.configs())

    def test_default_off_and_explicit_zero(self):
        for switch in (None, "0"):
            if switch is not None:
                self.env["DUO_V2"] = switch
            module.configure(self.root, self.env)
            self.assert_selection(False)

    def test_enable_sets_compilation_and_signing_in_both_configurations(self):
        module.configure(self.root, dict(self.env, DUO_V2="1"))
        self.assert_selection(True)

    def test_off_resets_previous_runner_selection(self):
        module.configure(self.root, dict(self.env, DUO_V2="1"))
        module.configure(self.root, self.env)
        self.assert_selection(False)

    def test_local_override_is_never_imported_by_runner(self):
        local = self.root / "Config/Duo.local.xcconfig"
        local.write_text("DUO_V2_CONDITION = WRONG\nDUO_ENTITLEMENTS = private.entitlements\n")
        module.configure(self.root, dict(self.env, DUO_V2="1"))
        self.assert_selection(True)
        self.assertIn("WRONG", local.read_text())

    def test_invalid_switch_stops_before_any_write(self):
        for switch in ("true", "yes", "2", " 1", "1\n"):
            with self.subTest(switch=switch):
                self.rejected_unchanged(dict(self.env, DUO_V2=switch))

    def test_low_malformed_or_mixed_versions_stop_before_any_write(self):
        self.env["DUO_V2"] = "1"
        for versions in (['1.8.1'], ['2'], ['2.0-beta'], ['2.0', '1.8.1'], ['2.0', '2.1'], []):
            with self.subTest(versions=versions):
                (self.root / "project.yml").write_text("".join('  MARKETING_VERSION: "' + v + '"\n' for v in versions))
                self.rejected_unchanged()

    def test_non_duo_legacy_version_remains_supported(self):
        (self.root / "project.yml").write_text('  MARKETING_VERSION: "1.8.1"\n')
        module.configure(self.root, self.env)
        self.assert_selection(False)

    def test_local_invocation_does_not_edit_configuration(self):
        before = self.configs()
        module.configure(self.root, {})
        self.assertEqual(before, self.configs())
        self.rejected_unchanged({"DUO_V2": "1"})

    def test_invalid_runner_counter_stops_before_any_write(self):
        for counter in ("0", "-1", "35x", "35\n"):
            self.rejected_unchanged({"CI_BUILD_NUMBER": counter})

    def test_missing_selected_entitlements_stops_before_any_write(self):
        (self.root / "HydroDrop/HydroDrop.duo.entitlements").unlink()
        self.rejected_unchanged(dict(self.env, DUO_V2="1"))

    def test_missing_or_duplicate_assignment_stops_before_either_write(self):
        release = self.root / "Config/Duo.Release.xcconfig"
        original = release.read_text()
        for value in (original.replace("DUO_V2_CONDITION =", "REMOVED ="), original + "\nDUO_ENTITLEMENTS = wrong\n"):
            release.write_text(value)
            self.rejected_unchanged(dict(self.env, DUO_V2="1"))

    def test_release_rejects_local_or_other_include(self):
        release = self.root / "Config/Duo.Release.xcconfig"
        release.write_text(release.read_text() + '\n#include? "Duo.local.xcconfig"\n')
        self.rejected_unchanged(dict(self.env, DUO_V2="1"))

    def test_hook_selects_before_build_stamp_and_generation(self):
        hook = (ROOT / "ci_scripts/ci_post_clone.sh").read_text()
        self.assertLess(hook.index('python3 "$REPO_ROOT/Scripts/configure_ci_duo.py"'), hook.index('echo "Stamping build number'))
        self.assertLess(hook.index('python3 "$REPO_ROOT/Scripts/configure_ci_duo.py"'), hook.index('"$XCODEGEN" generate'))


if __name__ == "__main__":
    unittest.main()
