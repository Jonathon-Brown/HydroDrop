#!/usr/bin/env python3
"""Repair what XcodeGen gets wrong about the StoreKit configuration.

Two separate defects, confirmed by hand in Xcode's own scheme editor rather than by
guessing at path-resolution rules:

1. XcodeGen never gives Products.storekit a `lastKnownFileType` in project.pbxproj —
   it's the only untyped PBXFileReference in the project. Xcode then can't offer it in
   Edit Scheme > Run > Options > StoreKit Configuration at all (the picker shows only
   "None"), regardless of what path the scheme's StoreKitConfigurationFileReference
   points at. This was the actual cause of the paywall's empty-products state, not any
   path arithmetic — the path XcodeGen already emits for the run action
   ("../../HydroDrop/StoreKit/Products.storekit") is exactly what Xcode itself writes
   when you pick the file by hand once it's typed.

2. XcodeGen honors `storeKitConfiguration` for the run action (from project.yml) but
   silently drops it for the test action, so `xcodebuild test` never sees products
   either. Fixed here by copying the run action's own (working) identifier into the
   test action, rather than recomputing a path independently.

Run after every `xcodegen generate`. Idempotent.
"""

import os
import re
import sys

PROJECT = "HydroDrop.xcodeproj"
# Only the iOS scheme runs tests; the watch scheme has a run action only.
TEST_ACTION_SCHEMES = {"HydroDrop.xcscheme"}

REF_RE = re.compile(
    r'<StoreKitConfigurationFileReference\s+identifier\s*=\s*"([^"]*)"\s*>\s*'
    r"</StoreKitConfigurationFileReference>",
    re.S,
)


def reference(indent, path):
    return (
        f'{indent}<StoreKitConfigurationFileReference\n'
        f'{indent}   identifier = "{path}">\n'
        f"{indent}</StoreKitConfigurationFileReference>"
    )


def add_to_test_action(scheme_path):
    """Copy the LaunchAction's own StoreKit identifier into the TestAction."""
    text = open(scheme_path).read()

    launch_match = re.search(r"<LaunchAction\b.*?</LaunchAction>", text, re.S)
    if not launch_match:
        return False
    ref_match = REF_RE.search(launch_match.group(0))
    if not ref_match:
        # LaunchAction has no StoreKit reference either — nothing to mirror.
        return False
    identifier = ref_match.group(1)

    test_match = re.search(r"<TestAction\b.*?</TestAction>", text, re.S)
    if not test_match:
        return False
    if REF_RE.search(test_match.group(0)):
        return False  # already present

    patched_action = test_match.group(0).replace(
        "   </TestAction>",
        reference("      ", identifier) + "\n   </TestAction>",
    )
    text = text[: test_match.start()] + patched_action + text[test_match.end() :]
    open(scheme_path, "w").write(text)
    return True


def patch_file_type(root):
    """Give the .storekit reference a file type.

    XcodeGen does not recognise the .storekit extension and emits the only untyped
    PBXFileReference in the project. Without this, Xcode's StoreKit Configuration
    picker in Edit Scheme has nothing to offer but "None" — see module docstring.
    """
    pbx = os.path.join(root, PROJECT, "project.pbxproj")
    if not os.path.isfile(pbx):
        return False
    text = open(pbx).read()
    pattern = re.compile(
        r"(/\* Products\.storekit \*/ = \{isa = PBXFileReference; )(path = Products\.storekit;)"
    )
    if not pattern.search(text):
        return False
    patched = pattern.sub(r"\1lastKnownFileType = text.json.storekit; \2", text)
    if patched != text:
        open(pbx, "w").write(patched)
        print("typed Products.storekit as text.json.storekit")
        return True
    return False


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")

    scheme_dir = os.path.join(root, PROJECT, "xcshareddata", "xcschemes")
    if not os.path.isdir(scheme_dir):
        sys.exit(f"error: no schemes at {scheme_dir}")

    patch_file_type(root)

    changed = 0
    for name in sorted(os.listdir(scheme_dir)):
        if not name.endswith(".xcscheme") or name not in TEST_ACTION_SCHEMES:
            continue
        path = os.path.join(scheme_dir, name)
        if add_to_test_action(path):
            print(f"added StoreKit configuration to {name}'s test action")
            changed += 1

    # NOTE: we deliberately do not verify these identifiers by resolving them as literal
    # filesystem paths. "../../HydroDrop/StoreKit/Products.storekit" does NOT exist when
    # walked from scheme_dir on disk — and yet it is the exact string both XcodeGen and
    # Xcode's own Edit Scheme UI produce, and it demonstrably works (confirmed against a
    # real product load and sandbox purchase sheet). Xcode is not doing naive relative
    # path resolution here, so a filesystem check would just be a false alarm. The
    # correctness guarantee instead comes from mirroring the run action's own identifier,
    # which is exactly what Xcode itself writes once the file has a lastKnownFileType.
    found = 0
    for name in sorted(os.listdir(scheme_dir)):
        if not name.endswith(".xcscheme"):
            continue
        path = os.path.join(scheme_dir, name)
        idents = re.findall(r'identifier = "([^"]*Products\.storekit)"', open(path).read())
        found += len(idents)
        for ident in idents:
            if os.path.basename(ident) != "Products.storekit":
                sys.exit(f"error: {name} has a malformed StoreKit identifier: {ident}")

    if found == 0:
        sys.exit("error: no StoreKit configuration references found in any scheme")

    print(f"StoreKit scheme references present in {found} action(s) ({changed} file(s) changed)")


if __name__ == "__main__":
    main()
