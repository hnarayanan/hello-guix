# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that source preparation preserves local edits and rejects incomplete output."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "asahi_prepare", PROJECT / "scripts/prepare_asahi.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "archive.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            member = tarfile.TarInfo("asahi-installer-test/src/main.py")
            data = b"upstream = True\n"
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        self.pin = {"release": "test", "commit": "test", "url": "unused",
                    "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        (self.root / "packaging/macos").mkdir(parents=True)
        (self.root / "packaging/macos/asahi-installer-source.json").write_text(json.dumps(self.pin))
        self.adaptations = self.root / "patches/asahi-macos-installer"
        self.adaptations.mkdir(parents=True)
        (self.adaptations / "patches").mkdir()
        (self.adaptations / "patches/series").write_text("")
        (self.adaptations / "overlay").mkdir()
        (self.adaptations / "overlay/addition.py").write_text("addition = True\n")
        location = patch.object(prepare, "__file__", str(self.root / "scripts/prepare_asahi.py"))
        location.start()
        self.addCleanup(location.stop)

    def run_prepare(self):
        with contextlib.redirect_stdout(io.StringIO()):
            prepare.prepare(self.archive)

    def test_repeated_preparation_verifies_without_replacing(self):
        self.run_prepare()
        output = self.root / "build/asahi-installer/src/addition.py"
        before = output.stat().st_mtime_ns
        self.run_prepare()
        self.assertEqual(output.stat().st_mtime_ns, before)

    def test_local_edits_are_preserved_and_rejected(self):
        self.run_prepare()
        output = self.root / "build/asahi-installer/src/main.py"
        output.write_text("local edit")
        with self.assertRaisesRegex(ValueError, "Prepared source differs"):
            self.run_prepare()
        self.assertEqual(output.read_text(), "local edit")

    def test_bad_download_does_not_publish_source(self):
        self.archive.write_bytes(b"wrong archive")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.run_prepare()
        self.assertFalse((self.root / "build/asahi-installer").exists())

    def test_bad_patch_does_not_publish_source(self):
        (self.adaptations / "patches/series").write_text("missing.patch\n")
        with self.assertRaises(FileNotFoundError):
            self.run_prepare()
        self.assertFalse((self.root / "build/asahi-installer").exists())

    def test_cached_archive_is_reused_and_checked_in_selected_directory(self):
        destination = self.root / "another build/asahi-installer"
        with contextlib.redirect_stdout(io.StringIO()):
            prepare.prepare(self.archive, destination)
            with patch.object(prepare.urllib.request, "urlopen",
                              side_effect=AssertionError("must reuse the archive")):
                prepare.prepare(None, destination)
                cached, = (destination.parent / "cache").iterdir()
                cached.write_bytes(b"damaged")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    prepare.prepare(None, destination)
        self.assertTrue((destination / "src/main.py").is_file())
        self.assertFalse((self.root / "build").exists())

    def test_temporary_sources_share_cache_and_use_current_adaptations(self):
        cache = self.root / "download cache"
        for attempt in range(2):
            addition = f"addition = {attempt}\n"
            (self.adaptations / "overlay/addition.py").write_text(addition)
            with tempfile.TemporaryDirectory(dir=self.root) as temporary, \
                 contextlib.redirect_stdout(io.StringIO()), \
                 patch.object(prepare.urllib.request, "urlopen",
                              side_effect=AssertionError("must reuse the archive")):
                destination = Path(temporary) / "asahi-installer"
                prepare.prepare(self.archive if attempt == 0 else None,
                                destination, cache)
                self.assertEqual((destination / "src/addition.py").read_text(), addition)
            self.assertFalse(destination.exists())
            cached, = cache.iterdir()
            self.assertEqual(cached.read_bytes(), self.archive.read_bytes())


if __name__ == "__main__":
    unittest.main()
