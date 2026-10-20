# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Test archive validation and Asahi's package reader.

The test images contain headers, not bootable filesystems.
No test runs diskutil, mkfs, mount, or the Asahi installer.
"""

import contextlib
import copy
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts"))
from asahi_payload import check_os, check_payload, sha256, stage
from build_inputs import record_snapshot


from payload_fixtures import ENTRY, PACKAGE_DIRECTORY, efi_image, ram_files, root_image


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.package = self.directory / "package"
        self.input = self.package / PACKAGE_DIRECTORY
        self.input.mkdir(parents=True)
        self.inputs = self.directory / "inputs"
        record_snapshot(self.inputs)
        self.entry = copy.deepcopy(ENTRY)
        self.files = {
            **ram_files(),
            "guix.icns": b"icns" + bytes(12),
            "Guix_image.img": root_image(),
            "esp/m1n1/boot.bin": b"m1n1 fixture",
            "esp/EFI/BOOT/BOOTAA64.EFI": efi_image(),
        }

    def write_payload(self, extra=None):
        (self.input / "guix-setup.json").write_text(json.dumps({"os_list": [self.entry]}))
        with zipfile.ZipFile(self.input / "guix-setup.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in self.files.items():
                archive.writestr(name, content)
            if extra:
                archive.writestr(*extra)

    def test_display_names_do_not_identify_the_payload(self):
        self.entry.update(name="A new description", default_os_name="My Guix")
        self.write_payload()
        self.assertEqual(check_payload(self.package)[0], self.entry)

    def test_valid_archive_report(self):
        self.write_payload()
        entry, archive, report = check_payload(self.package)
        self.assertEqual(entry, self.entry)
        self.assertEqual(report["kind"], "installation")
        self.assertEqual(report["sha256"], sha256(archive))
        self.assertEqual(report["root_uuid"], "00112233-4455-6677-8899-aabbccddeeff")
        self.assertEqual(report["root_image"], {"bytes": len(root_image()),
            "sha256": hashlib.sha256(root_image()).hexdigest()})

    def test_fat_volume_id_without_leading_zeroes(self):
        # Asahi Guix reads the ID from file(1), which omits leading zeroes.
        for volume_id in ("0x286b938", "0x1", "0x00000001"):
            with self.subTest(volume_id=volume_id):
                self.entry["partitions"][0]["volume_id"] = volume_id
                self.write_payload()
                check_payload(self.package)

    def test_invalid_fat_volume_id(self):
        for volume_id in (None, 1, "0x", "0x100000000", "0x12xyz", "1234abcd"):
            with self.subTest(volume_id=volume_id):
                self.entry["partitions"][0]["volume_id"] = volume_id
                self.write_payload()
                with self.assertRaisesRegex(ValueError, "EFI FAT volume ID"):
                    check_payload(self.package)

    def test_missing_boot_files(self):
        for name in ("esp/m1n1/boot.bin", "esp/EFI/BOOT/BOOTAA64.EFI"):
            with self.subTest(name=name):
                content = self.files.pop(name)
                self.write_payload()
                with self.assertRaisesRegex(ValueError, "Missing or empty"):
                    check_payload(self.package)
                self.files[name] = content

    def test_wrong_cpu_architecture(self):
        efi = bytearray(efi_image())
        struct.pack_into("<H", efi, 132, 0x8664)
        self.files["esp/EFI/BOOT/BOOTAA64.EFI"] = bytes(efi)
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "not ARM64"):
            check_payload(self.package)

    def test_truncated_root_even_with_matching_metadata(self):
        self.files["Guix_image.img"] = root_image()[:-4096]
        self.entry["partitions"][1]["size"] = "126976B"
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "filesystem extends beyond"):
            check_payload(self.package)

    def test_partition_padding_is_allowed(self):
        self.files["Guix_image.img"] = root_image() + bytes(4096)
        self.entry["partitions"][1]["size"] = "135168B"
        self.write_payload()
        _, _, report = check_payload(self.package)
        self.assertEqual(report["root_filesystem_bytes"], 131072)
        self.assertEqual(report["root_bytes"], 135168)

    def test_shipped_boot_variables_rejected(self):
        self.write_payload(extra=("esp/ubootefi.var", b"foreign boot choices"))
        with self.assertRaisesRegex(ValueError, "Initial EFI variables"):
            check_payload(self.package)

    def test_case_variant_boot_variables_rejected(self):
        self.write_payload(extra=("esp/UBOOTEFI.VAR", b"foreign boot choices"))
        with self.assertRaisesRegex(ValueError, "Initial EFI variables"):
            check_payload(self.package)

    def test_file_cannot_also_be_directory(self):
        self.write_payload(extra=("esp/EFI", b"not a directory"))
        with self.assertRaisesRegex(ValueError, "also a parent directory"):
            check_payload(self.package)

    def test_changed_inputs_are_not_published(self):
        self.write_payload()
        (self.inputs / "packaging/guix/packages/setup-install.scm").write_text("changed")
        output = self.directory / "catalogue"
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            stage(self.package, output, self.inputs)
        self.assertFalse(output.exists())

    def test_incompatible_sector_size(self):
        image = bytearray(root_image())
        struct.pack_into("<I", image, 65536 + 144, 16384)
        self.files["Guix_image.img"] = bytes(image)
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "4 KiB Btrfs"):
            check_payload(self.package)

    def test_unaligned_image(self):
        self.files["Guix_image.img"] = root_image() + b"x"
        self.entry["partitions"][1]["size"] = "131073B"
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "align to 4 KiB"):
            check_payload(self.package)

    def test_missing_handover_flags(self):
        for flag in ("copy_firmware", "copy_installer_data"):
            with self.subTest(flag=flag):
                self.entry = copy.deepcopy(ENTRY)
                self.entry["partitions"][0][flag] = False
                self.write_payload()
                with self.assertRaisesRegex(ValueError, "firmware and installer records"):
                    check_payload(self.package)

    def test_missing_partition_name_is_rejected_before_asahi(self):
        del self.entry["partitions"][0]["name"]
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "printable name"):
            check_payload(self.package)

    def test_archive_path_attacks(self):
        for name in ("../escape", "/absolute", "esp/../escape", "esp//ambiguous",
                     "esp/./ambiguous", "esp\\escape", "esp/EFI/BOOT/bootaa64.efi",
                     "esp/trailing./file", "esp/trailing /file"):
            with self.subTest(name=name):
                self.write_payload(extra=(name, b"bad"))
                with self.assertRaises(ValueError):
                    check_payload(self.package)

    def test_symlinks_rejected(self):
        member = zipfile.ZipInfo("esp/link")
        member.create_system = 3
        member.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_payload(extra=(member, "../../outside"))
        with self.assertRaisesRegex(ValueError, "special file"):
            check_payload(self.package)

    def test_machine_specific_data_rejected(self):
        for name in ("esp/vendorfw/firmware.cpio", "esp/asahi/installer.log",
                     "esp/VENDORFW/firmware.cpio", "esp/Asahi/installer.log"):
            with self.subTest(name=name):
                self.write_payload(extra=(name, b"machine data"))
                with self.assertRaisesRegex(ValueError, "Per-machine"):
                    check_payload(self.package)

    def test_staging_is_repeatable_and_preserves_existing_output(self):
        self.write_payload()
        one, two = self.directory / "one", self.directory / "two"
        stage(self.package, one, self.inputs)
        stage(self.package, two, self.inputs)
        entry, _, _ = check_os(one / "installer_data.json", one / "os")
        self.assertNotIn("volume_id", entry["partitions"][0])
        self.assertEqual(entry["guix_root_image"]["sha256"],
                         hashlib.sha256(root_image()).hexdigest())
        self.assertEqual((one / "SHA256SUMS").read_bytes(), (two / "SHA256SUMS").read_bytes())
        before = (one / "SHA256SUMS").stat().st_mtime_ns
        stage(self.package, one, self.inputs)
        self.assertEqual((one / "SHA256SUMS").stat().st_mtime_ns, before)
        self.assertEqual((one / "source-record/packaging/guix/channels.scm").read_bytes(),
                         (PROJECT / "packaging/guix/channels.scm").read_bytes())
        (one / "installer_data.json").write_text("edited")
        with self.assertRaisesRegex(ValueError, "Existing catalogue differs"):
            stage(self.package, one, self.inputs)
        self.assertEqual((one / "installer_data.json").read_text(), "edited")

    def test_published_root_record_must_match_image(self):
        self.entry["guix_boot"] = True
        del self.entry["partitions"][0]["volume_id"]
        self.entry["guix_root_image"] = {"bytes": len(root_image()), "sha256": "0" * 64}
        self.write_payload()
        with self.assertRaisesRegex(ValueError, "Root image preparation record"):
            check_payload(self.package)

    def test_failed_check_does_not_publish_catalogue(self):
        self.files.pop("esp/m1n1/boot.bin")
        self.write_payload()
        output = self.directory / "catalogue"
        with self.assertRaises(ValueError):
            stage(self.package, output, self.inputs)
        self.assertFalse(output.exists())

    def test_actual_asahi_consumer(self):
        """Test Asahi's package reader and partition size calculations without a disk."""
        source = Path(os.environ.get("ASAHI_SOURCE", PROJECT / "build/asahi-installer"))
        self.assertTrue((source / "src/osinstall.py").is_file(), "Run make check code to prepare Asahi source")
        sys.path.insert(0, str(source / "src"))
        self.addCleanup(sys.path.pop, 0)
        upstream = importlib.import_module("osinstall")
        self.write_payload()
        output = self.directory / "catalogue"
        stage(self.package, output, self.inputs)
        catalogue = json.loads((output / "installer_data.json").read_text())
        self.assertEqual(catalogue["os_list"][0]["guix_root_image"],
                         {"bytes": len(root_image()),
                          "sha256": hashlib.sha256(root_image()).hexdigest()})

        partitions = []

        class DiskModel:
            def addPartition(self, previous, kind, name, size):
                partitions.append((previous, kind, name, size))
                return SimpleNamespace(name=f"test{len(partitions)}")

        commands = []
        with patch.dict(os.environ, {"REPO_BASE": str(output)}), \
             patch.object(upstream.subprocess, "run", side_effect=lambda cmd, **kw: commands.append(cmd)), \
             contextlib.redirect_stdout(io.StringIO()):
            installer = upstream.OSInstaller(DiskModel(), catalogue, catalogue["os_list"][0])
            installer.load_package()
            self.addCleanup(installer.pkg.fp.close)
            self.addCleanup(installer.pkg.close)
            self.assertTrue(installer.needs_firmware)
            self.assertTrue(installer.expandable)
            self.assertEqual(installer.min_size, 500 * 1024**2 + 8 * 1024**3)
            installer.name = "My Guix"
            installer.partition_disk("stub", installer.min_size + 20 * 1024**3)
            self.assertEqual(partitions[0][1:], ("%EFI%", "%noformat%", 500 * 1024**2))
            self.assertEqual(partitions[1][1:], ("%Linux%", "%noformat%", 28 * 1024**3))
            self.assertEqual(commands, [["newfs_msdos", "-F", "32", "-v", "EFI - My Gu",
                                         "/dev/rtest1"]])
            self.assertEqual(installer.pkg.read("esp/m1n1/boot.bin"), b"m1n1 fixture")


if __name__ == "__main__":
    unittest.main()
