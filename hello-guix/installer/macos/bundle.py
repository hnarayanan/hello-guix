#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the macOS bundle before the installer starts."""

import argparse
import hashlib
import json
from pathlib import Path
import stat


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(directory):
    """Record file checksums, executable bits, and framework links."""
    require(directory.is_dir() and not directory.is_symlink(),
            f"Expected an ordinary directory: {directory}")
    root = directory.resolve()
    result = {}
    for path in sorted(directory.rglob("*")):
        name = path.relative_to(directory).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = path.readlink()
            require(not target.is_absolute() and path.resolve().is_relative_to(root),
                    f"Link leaves the bundle: {name}")
            result[name] = {"link": str(target)}
        elif stat.S_ISREG(mode):
            result[name] = {"sha256": sha256(path), "executable": mode & 0o111}
        else:
            require(stat.S_ISDIR(mode), f"Special file in bundle: {name}")
    return result


def check_bundle(bundle):
    report = json.loads((bundle / "bundle.json").read_text())
    require(report.get("format") == 1 and report.get("kind") == "installation",
            "Unrecognized bundle format")
    require(report["kind"] == report["payload"]["kind"], "Bundle and payload kinds differ")
    actual = inventory(bundle)
    del actual["bundle.json"]
    expected = report["files"]
    changed = sorted(name for name in actual.keys() | expected.keys()
                     if actual.get(name) != expected.get(name))
    require(not changed, "Bundle files changed: " + ", ".join(changed))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = check_bundle(args.bundle)
        print(f"Bundle verified: {args.bundle}")
        print(f"Payload SHA-256: {report['payload']['sha256']}")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Bundle check failed: {error}\n")


if __name__ == "__main__":
    main()
