#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Save source for an image build or a recorded test run.

The snapshot contains whole source directories, root files and SHA256SUMS.
Build outputs, caches and Git metadata stay out.
New top-level paths must be classified before making a snapshot.
"""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
SOURCE_FILES = (".gitignore", ".guix-channel", "COPYING", "Makefile", "NOTICE", "README.md")
SOURCE_DIRECTORIES = ("LICENSES", "docs", "hello-guix", "packaging", "patches", "scripts", "tests")
EXCLUDED_ENTRIES = (
    ".git", "build",
    # The checksum inventory and original image source in released source trees.
    "SHA256SUMS", "image-source",
)
CACHE_NAMES = (".DS_Store", "__pycache__")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def valid_source_entry(path, directory):
    """Keep module views as canonical links and other source as ordinary files."""
    name = path.relative_to(directory)
    # An assembly can retain the source of an earlier image beside its own.
    if len(name.parts) > 1 and name.parts[0] in ("image-source", "source-record"):
        return valid_source_entry(path, directory / name.parts[0])
    roots = {
        ("packaging", "guix", "channel"): ("hello-guix/system/", "hello-guix/apple-silicon.scm"),
        ("packaging", "guix", "installer"): ("hello-guix/installer/linux/",),
    }
    allowed = roots.get(name.parts[:3], ())
    relative = Path(*name.parts[3:])
    if path.suffix != ".scm" or not any(
            relative.as_posix().startswith(prefix) if prefix.endswith("/")
            else relative.as_posix() == prefix for prefix in allowed):
        return not path.is_symlink()
    if not path.is_symlink():
        return False
    target = directory / relative
    return (target.is_file() and target.resolve() == directory.resolve() / relative
            and os.readlink(path) == os.path.relpath(target, path.parent))


def file_hashes(directory):
    """Calculate file checksums, allowing the declared source module links."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Expected an ordinary directory: {directory}")
    result = {}
    for path in sorted(directory.rglob("*")):
        if (not valid_source_entry(path, directory)
                or not (path.is_file() or path.is_dir())):
            raise ValueError(f"Unexpected link or special file: {path}")
        if path.is_file():
            result[path.relative_to(directory).as_posix()] = sha256(path)
    return result


def source_files(project, *, outputs=()):
    """Include whole source directories and require every other path to be classified."""
    project = project.resolve()
    for names, kind in ((SOURCE_FILES, Path.is_file), (SOURCE_DIRECTORIES, Path.is_dir)):
        for name in names:
            path = project / name
            if path.is_symlink() or not kind(path):
                raise ValueError(f"Missing or invalid build input: {name}")

    sources = {project / name for name in (*SOURCE_FILES, *SOURCE_DIRECTORIES)}
    excluded = {project / name for name in EXCLUDED_ENTRIES}
    build_dir = project / os.environ.get("BUILD_DIR", "build")
    for path in (*outputs, build_dir):
        path = path.resolve()
        if path.is_relative_to(project):
            if any(path.is_relative_to(source) or source.is_relative_to(path)
                   for source in sources):
                raise ValueError(f"Build output overlaps project source: {path}")
            excluded.add(path)

    files = []

    def collect(path, source=False):
        if path in excluded or path.name in CACHE_NAMES:
            return
        source = source or path in sources
        if not source and not (path.is_dir() and
                               any(output.is_relative_to(path) for output in excluded)):
            raise ValueError(f"Unclassified project path: {path.relative_to(project)}. "
                             "Declare it as source or a build output, or exclude it explicitly.")
        if (not valid_source_entry(path, project)
                or not (path.is_file() or path.is_dir())):
            raise ValueError(f"Unexpected link or special file: {path}")
        if path.is_dir():
            for child in path.iterdir():
                collect(child, source)
        elif source:
            files.append(path.relative_to(project))

    for path in sorted(project.iterdir()):
        collect(path)
    return sorted(files)


def checksum_text(hashes):
    return "".join(f"{digest}  {name}\n" for name, digest in sorted(hashes.items()))


def verify_snapshot(directory, project=PROJECT, *, outputs=()):
    """Require DIRECTORY to match the selected inputs in the current PROJECT."""
    if directory.resolve() != project.resolve():
        outputs = (*outputs, directory)
    expected = {str(name): sha256(project / name)
                for name in source_files(project, outputs=outputs)}
    checksums = checksum_text(expected).encode()
    expected["SHA256SUMS"] = hashlib.sha256(checksums).hexdigest()
    actual = file_hashes(directory)
    changed = sorted(name for name in expected.keys() | actual.keys()
                     if expected.get(name) != actual.get(name))
    if changed:
        raise ValueError("Build inputs changed: " + ", ".join(changed)
                         + ". Keep this source record and choose a new build directory.")
    return actual


def record_snapshot(directory, project=PROJECT, *, outputs=()):
    if directory.exists() or directory.is_symlink():
        return verify_snapshot(directory, project, outputs=outputs)
    files = source_files(project, outputs=(*outputs, directory))
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".inputs-", dir=directory.parent) as temporary:
        snapshot = Path(temporary) / "inputs"
        snapshot.mkdir()
        for name in files:
            target = snapshot / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(project / name, target, follow_symlinks=False)
        (snapshot / "SHA256SUMS").write_text(checksum_text(file_hashes(snapshot)))
        verify_snapshot(snapshot, project, outputs=(*outputs, directory, Path(temporary)))
        snapshot.rename(directory)
    return verify_snapshot(directory, project, outputs=outputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("record", "verify"))
    parser.add_argument("--directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "record":
            record_snapshot(args.directory)
        else:
            verify_snapshot(args.directory)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Build input check failed: {error}\n")
    print(f"Build inputs verified: {args.directory}")


if __name__ == "__main__":
    main()
