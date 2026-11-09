# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check module views and their preservation in portable source records."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/packaging"))
from source_record import PROJECT, file_hashes, record_snapshot, source_files, verify_snapshot
from macos_bundle import verify_checksums, write_archive


CHANNEL = Path("packaging/guix/channel")
INSTALLER = Path("packaging/guix/installer")
HARDWARE = Path("hello-guix/system/hardware.scm")


class SourceLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        for name in source_files(PROJECT):
            target = self.project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target, follow_symlinks=False)
        self.snapshot = self.root / "snapshot"

    def test_views_match_real_modules_and_namespaces(self):
        runtime = set((self.project / "hello-guix/system").rglob("*.scm"))
        runtime.update((self.project / "hello-guix").glob("*.scm"))
        installer = set((self.project / "hello-guix/installer/linux").rglob("*.scm"))
        self.assertTrue(runtime)
        self.assertTrue(installer)
        self.assertRegex((self.project / ".guix-channel").read_text(),
                         r'\(directory\s+"packaging/guix/channel"\)')
        for view, originals in ((CHANNEL, runtime), (INSTALLER, installer)):
            with self.subTest(view=view):
                directory = self.project / view
                expected = {path.relative_to(self.project) for path in originals}
                entries = list(directory.rglob("*"))
                self.assertTrue(entries)
                # Directory links would conceal additional modules from this census.
                for entry in entries:
                    if entry.is_dir():
                        self.assertFalse(entry.is_symlink(), entry)
                files = {path.relative_to(directory): path for path in entries
                         if not path.is_dir()}
                self.assertEqual(set(files), expected)
                for name, alias in files.items():
                    self.assertTrue(alias.is_symlink(), alias)
                    original = self.project / name
                    self.assertEqual(os.readlink(alias),
                                     os.path.relpath(original, alias.parent))
                    self.assertEqual(alias.resolve(strict=True), original.resolve(strict=True))
                    text = "\n".join(line for line in alias.read_text().splitlines()
                                     if not line.lstrip().startswith(";"))
                    declaration = re.match(r"\s*\(define-module\s+\(([^()]*)\)", text)
                    self.assertIsNotNone(declaration, name)
                    self.assertEqual(tuple(declaration.group(1).split()),
                                     name.with_suffix("").parts)

    def test_views_exclude_standalone_build_and_test_programs(self):
        poisons = ("packaging/guix/not-a-module.scm", "scripts/not-a-module.scm",
                   "tests/not-a-module.scm", "hello-guix/installer/macos/not-a-module.scm")
        for name in poisons:
            (self.project / name).write_text('(error "Do not load this standalone program")\n')
        record_snapshot(self.snapshot, self.project)
        # These files remain in the real source snapshot. The module views,
        # rather than a stripped test checkout, keep them out of module discovery.
        for name in poisons:
            self.assertEqual((self.snapshot / name).read_bytes(),
                             (self.project / name).read_bytes())
        for view in (CHANNEL, INSTALLER):
            self.assertFalse(any(path.name == "not-a-module.scm"
                                 for path in (self.snapshot / view).rglob("*.scm")))
        self.assertFalse((self.snapshot / CHANNEL / "hello-guix/installer").exists())
        self.assertFalse((self.snapshot / INSTALLER / "hello-guix/system").exists())

    def test_source_edits_reach_views_and_invalidate_saved_record(self):
        record_snapshot(self.snapshot, self.project)
        alias_name = CHANNEL / HARDWARE
        before = (self.project / HARDWARE).read_bytes()
        changed = before + b"\n;; A change to the single authoritative module.\n"
        (self.project / HARDWARE).write_bytes(changed)
        self.assertEqual((self.project / alias_name).read_bytes(), changed)
        self.assertEqual((self.snapshot / alias_name).read_bytes(), before)
        digest = hashlib.sha256(changed).hexdigest()
        hashes = file_hashes(self.project)
        self.assertEqual(hashes[HARDWARE.as_posix()], digest)
        self.assertEqual(hashes[alias_name.as_posix()], digest)
        saved_digest = hashlib.sha256(before).hexdigest()
        checksums = (self.snapshot / "SHA256SUMS").read_text().splitlines()
        self.assertIn(f"{saved_digest}  {HARDWARE.as_posix()}", checksums)
        self.assertIn(f"{saved_digest}  {alias_name.as_posix()}", checksums)
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.snapshot, self.project)

    def test_snapshot_and_release_archive_keep_relocatable_views(self):
        record_snapshot(self.snapshot, self.project)
        expected = file_hashes(self.snapshot)
        links = {path.relative_to(self.snapshot): os.readlink(path)
                 for path in self.snapshot.rglob("*") if path.is_symlink()}
        self.assertTrue(links)
        # Neither the relocated snapshot nor the archive may depend on the checkout.
        shutil.rmtree(self.project)
        moved = self.root / "another place/source"
        moved.parent.mkdir()
        self.snapshot.rename(moved)
        verify_snapshot(moved, moved)
        self.assertEqual(file_hashes(moved), expected)
        archive = self.root / "source.tar.gz"
        write_archive(moved, archive, "hello-guix-source")
        shutil.rmtree(moved)
        extracted = self.root / "unpacked"
        extracted.mkdir()
        with tarfile.open(archive, "r:gz") as stream:
            for name, target in links.items():
                member = stream.getmember("hello-guix-source/" + name.as_posix())
                self.assertTrue(member.issym(), name)
                self.assertEqual(member.linkname, target)
            stream.extractall(extracted, filter="data")
        restored = extracted / "hello-guix-source"
        verify_checksums(restored)
        verify_snapshot(restored, restored)
        self.assertEqual(file_hashes(restored), expected)
        for name, target in links.items():
            self.assertTrue((restored / name).is_symlink(), name)
            self.assertEqual(os.readlink(restored / name), target)
            self.assertTrue((restored / name).resolve(strict=True).is_relative_to(restored.resolve()))

    def test_equal_content_cannot_disguise_retargeted_views(self):
        record_snapshot(self.snapshot, self.project)
        outside = self.root / "same-bytes.scm"
        outside.write_bytes((self.project / HARDWARE).read_bytes())
        for directory in (self.project, self.snapshot):
            alias = directory / CHANNEL / HARDWARE
            original = directory / HARDWARE
            canonical = os.readlink(alias)
            duplicate = original.with_name("same-bytes.scm")
            duplicate.write_bytes(original.read_bytes())
            targets = {
                "outside": os.path.relpath(outside, alias.parent),
                "absolute": str(original),
                "noncanonical": "./" + canonical,
                "different module": os.path.relpath(duplicate, alias.parent),
            }
            for kind, target in targets.items():
                with self.subTest(directory=directory.name, kind=kind):
                    alias.unlink()
                    alias.symlink_to(target)
                    self.assertEqual(alias.read_bytes(), original.read_bytes())
                    with self.assertRaises(ValueError):
                        file_hashes(directory)
                    with self.assertRaises(ValueError):
                        source_files(directory)
            alias.unlink()
            alias.symlink_to(canonical)
            duplicate.unlink()

    def test_saved_module_views_cannot_be_flattened(self):
        record_snapshot(self.snapshot, self.project)
        alias = self.snapshot / CHANNEL / HARDWARE
        contents = alias.read_bytes()
        alias.unlink()
        alias.write_bytes(contents)
        with self.assertRaises(ValueError):
            verify_snapshot(self.snapshot, self.project)
        with self.assertRaises(ValueError):
            file_hashes(self.snapshot)

    def test_views_reject_missing_and_directory_targets(self):
        record_snapshot(self.snapshot, self.project)
        for directory in (self.project, self.snapshot):
            original = directory / HARDWARE
            alias = directory / CHANNEL / HARDWARE
            contents = original.read_bytes()
            for kind in ("missing", "directory"):
                with self.subTest(directory=directory.name, kind=kind):
                    original.unlink()
                    if kind == "directory":
                        original.mkdir()
                    self.assertTrue(alias.is_symlink())
                    with self.assertRaises(ValueError):
                        file_hashes(directory)
                    with self.assertRaises(ValueError):
                        source_files(directory)
                    if kind == "directory":
                        original.rmdir()
                    original.write_bytes(contents)


if __name__ == "__main__":
    unittest.main()
