#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Download the selected Asahi installer source. Apply the patches in series order."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


def tree_contents(directory):
    """Record file checksums, executable bits, and link targets. Ignore Python caches."""
    result = {}
    for path in sorted(directory.rglob("*")):
        name = path.relative_to(directory)
        if "__pycache__" in name.parts:
            continue
        if path.is_symlink():
            result[str(name)] = ("link", str(path.readlink()))
        elif path.is_file():
            result[str(name)] = ("file", path.stat().st_mode & 0o111,
                                 hashlib.sha256(path.read_bytes()).hexdigest())
        elif not path.is_dir():
            raise ValueError(f"Unexpected source entry: {path}")
    return result


def unpack_source(archive, destination, pin):
    """Verify and unpack the exact source archive into a fresh directory."""
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != pin["sha256"]:
        raise ValueError("Source archive checksum mismatch")
    source_name = f"asahi-installer-{pin['commit']}"
    with tarfile.open(archive, "r:gz") as source_archive:
        for member in source_archive.getmembers():
            if member.name.split("/", 1)[0] != source_name:
                raise ValueError(f"Unexpected archive path: {member.name}")
        source_archive.extractall(destination, filter="data")
    return destination / source_name


def apply_adaptations(source, project):
    """Apply the patch series and additional files to an unmodified source tree."""
    directory = project / "patches/asahi-macos-installer"
    patches = []
    for line in (directory / "patches/series").read_text().splitlines():
        name = line.strip()
        if not name or name.startswith("#"):
            continue
        if Path(name).name != name or not name.endswith(".patch"):
            raise ValueError(f"Invalid patch filename: {name}")
        patch = directory / "patches" / name
        if not patch.is_file():
            raise FileNotFoundError(patch)
        patches.append(patch)

    for patch in patches:
        print(f"Applying {patch.name}", flush=True)
        subprocess.run(
            ["patch", "-p1", "-F", "0", "--batch", "--forward", "-i", str(patch.resolve())],
            cwd=source, check=True,
        )
    for addition in sorted((directory / "overlay").glob("*.py")):
        target = source / "src" / addition.name
        if target.exists() or target.is_symlink():
            raise FileExistsError(f"Overlay would replace an upstream file: {target}")
        shutil.copyfile(addition, target)
    return len(patches)


def prepare(local_archive, directory=None):
    project = Path(__file__).resolve().parents[1]
    destination = directory or project / "build/asahi-installer"
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise FileExistsError(f"Expected an ordinary source directory: {destination}")

    pin = json.loads((project / "packaging/macos/asahi-installer-source.json").read_text())
    destination.parent.mkdir(parents=True, exist_ok=True)
    cached = destination.parent / "cache" / f"asahi-{pin['sha256']}.tar.gz"
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=destination.parent) as temporary:
        temporary = Path(temporary)
        archive = temporary / "source.tar.gz"
        if local_archive or cached.exists():
            content = (local_archive or cached).read_bytes()
        else:
            print(f"Downloading {pin['url']}", flush=True)
            request = urllib.request.Request(pin["url"], headers={"User-Agent": "hello-guix"})
            with urllib.request.urlopen(request, timeout=60) as response:
                content = response.read()

        digest = hashlib.sha256(content).hexdigest()
        if digest != pin["sha256"]:
            raise ValueError(f"Archive checksum mismatch: expected {pin['sha256']}, got {digest}")
        archive.write_bytes(content)
        if not cached.exists():
            cached.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, cached)
        print(f"Verified {pin['release']} ({pin['commit']})", flush=True)

        source = unpack_source(archive, temporary / "unpacked", pin)
        patch_count = apply_adaptations(source, project)

        # If the tree exists, compare it with the expected source.
        # Stop if local edits would change the release.
        if destination.exists():
            expected, actual = tree_contents(source), tree_contents(destination)
            changed = sorted(name for name in expected.keys() | actual.keys()
                             if expected.get(name) != actual.get(name))
            if changed:
                raise ValueError("Prepared source differs: " + ", ".join(changed)
                                 + f". Preserve your edits and move {destination} aside before retrying.")
        else:
            source.rename(destination)

    print(f"Prepared source verified: {destination} ({patch_count} patches)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="use a local archive, with the same checksum check")
    parser.add_argument("--directory", type=Path, help="prepared source directory")
    arguments = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error("Python 3.12 or later is required")
    try:
        prepare(arguments.archive, arguments.directory)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Source preparation failed: {error}\n")


if __name__ == "__main__":
    main()
