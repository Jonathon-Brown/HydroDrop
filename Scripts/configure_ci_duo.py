#!/usr/bin/env python3
"""Select Duo explicitly in Xcode Cloud's disposable checkout, before XcodeGen."""

import os
from pathlib import Path
import re
import sys
import tempfile


def configure(root, environ):
    switch = environ.get("DUO_V2", "")
    if switch not in ("", "0", "1"):
        raise ValueError("DUO_V2 must be 1 to include Duo, or 0/unset to leave it out")
    # The normal Run button keeps its local override. Only Cloud's numbered runner
    # checkout is rewritten; invoking this helper locally must not enable an archive.
    if not environ.get("CI_BUILD_NUMBER"):
        if switch == "1":
            raise ValueError("CI_BUILD_NUMBER is missing; use DUO_V2=1 Scripts/release.sh locally")
        return "Outside Xcode Cloud; leaving the tracked Duo configuration unchanged."
    if not re.fullmatch(r"[1-9][0-9]*", environ["CI_BUILD_NUMBER"]):
        raise ValueError("CI_BUILD_NUMBER must be a positive integer")

    enabled = switch == "1"
    if enabled:
        project = (root / "project.yml").read_text()
        versions = re.findall(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', project, re.MULTILINE)
        declarations = re.findall(r"^\s*MARKETING_VERSION:", project, re.MULTILINE)
        if (not versions or len(versions) != len(declarations) or len(set(versions)) != 1
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", versions[0])
                or int(versions[0].split(".")[0]) < 2):
            raise ValueError("Duo needs one consistent MARKETING_VERSION of 2.0 or higher on every target")

    entitlements = "HydroDrop/HydroDrop.duo.entitlements" if enabled else "HydroDrop/HydroDrop.entitlements"
    if not (root / entitlements).is_file():
        raise ValueError("The selected entitlements file is missing: " + entitlements)
    changes = []
    for relative in ("Config/Duo.xcconfig", "Config/Duo.Release.xcconfig"):
        path = root / relative
        source = path.read_text()
        # Release has never imported a local file. Keep that guarantee even if the
        # configuration changes later, and omit Debug's optional override on the
        # runner so it cannot contradict the workflow's explicit selection.
        includes = re.findall(r'^\s*#include[^\n]*$', source, re.MULTILINE)
        allowed = '#include? "Duo.local.xcconfig"'
        if any(line.strip() != allowed or relative.endswith("Release.xcconfig") for line in includes):
            raise ValueError("Unexpected configuration include in " + relative)
        source = re.sub(r'^\s*#include\? "Duo\.local\.xcconfig"\s*$', "", source, flags=re.MULTILINE)
        for key, value in (("DUO_V2_CONDITION", "DUO_V2" if enabled else ""),
                           ("DUO_ENTITLEMENTS", entitlements)):
            pattern = r"^" + key + r"\s*=.*$"
            if len(re.findall(pattern, source, re.MULTILINE)) != 1:
                raise ValueError("Expected exactly one " + key + " assignment in " + relative)
            source = re.sub(pattern, key + " = " + value, source, flags=re.MULTILINE)
        changes.append((path, source))

    # Validate the complete selection before changing either file. Atomic replacement
    # leaves no half-written xcconfig if a runner is interrupted; a failed write stops
    # the post-clone hook before it can generate or build a project.
    for path, source in changes:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            try:
                handle.write(source)
                handle.flush()
                os.fsync(handle.fileno())
                temporary.chmod(path.stat().st_mode & 0o777)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
    return "Xcode Cloud Duo " + ("enabled" if enabled else "disabled") + "; selected " + entitlements


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: configure_ci_duo.py <repository-root>")
    try:
        print(configure(Path(sys.argv[1]).resolve(), os.environ))
    except (OSError, ValueError) as error:
        sys.exit("error: " + str(error))
