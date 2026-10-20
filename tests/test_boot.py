# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: MIT

import contextlib
import hashlib
import importlib
import os
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid
import zlib


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "patches/asahi-macos-installer/overlay"))
from guix_boot import boot_store, initialize_boot, partition_number


def decode_variables(content):
    """Read the U-Boot file format without using the code under test."""
    reserved, magic, length, crc = struct.unpack_from("<QQII", content)
    assert reserved == 0 and magic == 0x0161566966456255
    assert length == len(content) and crc == zlib.crc32(content[24:])
    result = {}
    position = 24
    while position < length:
        size, attrs, timestamp, guid = struct.unpack_from("<IIQ16s", content, position)
        assert attrs == 7 and timestamp == 0
        assert uuid.UUID(bytes_le=guid) == uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c")
        position += 32
        end = position
        while content[end:end + 2] != b"\0\0":
            end += 2
            assert end < length
        name = content[position:end].decode("utf-16-le")
        position = end + 2
        assert name not in result
        result[name] = content[position:position + size]
        position = (position + size + 7) & ~7
    assert position == length
    return result


class BootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.esp = Path(self.temporary.name)
        for name in ("m1n1/boot.bin", "EFI/BOOT/BOOTAA64.EFI"):
            path = self.esp / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
        self.partition = SimpleNamespace(
            name="disk9s12", type="EFI", offset=64 * 1024**2, size=500 * 1024**2,
            uuid="00112233-4455-6677-8899-aabbccddeeff", info={"DeviceBlockSize": 4096})

        self.root_image = {"bytes": 128 * 1024, "sha256": "a" * 64}
        self.root_partition = SimpleNamespace(
            name="disk9s13", type="Linux Filesystem", offset=564 * 1024**2,
            size=16 * 1024**3, uuid="11112233-4455-6677-8899-aabbccddeeff")

        def table_output(command, *, text):
            self.assertEqual(command, ["gpt", "-r", "show", "/dev/disk9"])
            self.assertTrue(text)
            block_size = self.partition.info["DeviceBlockSize"]
            # Use a GPT index that differs from the temporary BSD suffix s12.
            return (f"{self.partition.offset // block_size} {self.partition.size // block_size} "
                    "7 GPT part - C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n")

        lookup = patch("guix_boot.subprocess.check_output", side_effect=table_output)
        lookup.start()
        self.addCleanup(lookup.stop)

    def test_persistent_order_and_full_device_path(self):
        initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        content = (self.esp / "ubootefi.var").read_bytes()
        variables = decode_variables(content)
        self.assertEqual(set(variables), {"Boot0000", "BootOrder"})
        self.assertEqual(variables["BootOrder"], b"\0\0")
        option = variables["Boot0000"]
        attributes, path_size = struct.unpack_from("<IH", option)
        self.assertEqual(attributes, 1)
        label = "Guix System\0".encode("utf-16-le")
        self.assertEqual(option[6:6 + len(label)], label)
        device_path = option[6 + len(label):]
        self.assertEqual(len(device_path), path_size)
        drive = struct.unpack_from("<BBHIQQ16sBB", device_path)
        self.assertEqual(drive[:6], (4, 1, 42, 7, 16384, 128000))
        self.assertEqual(uuid.UUID(bytes_le=drive[6]), uuid.UUID(self.partition.uuid))
        self.assertEqual(drive[7:], (2, 2))
        self.assertEqual(device_path[42:44], b"\x04\x04")
        self.assertEqual(device_path[46:-4].decode("utf-16-le"), "\\EFI\\BOOT\\BOOTAA64.EFI\0")
        self.assertEqual(device_path[-4:], b"\x7f\xff\x04\x00")
        record = json.loads((self.esp / "asahi/guix-boot.json").read_text())
        self.assertEqual(record["variable_store_sha256"], hashlib.sha256(content).hexdigest())
        self.assertEqual(record["partition_number"], 7)
        self.assertEqual(record["layout"], "hello-guix-ram-v1")
        self.assertEqual(record["root_partition_uuid"], self.root_partition.uuid)
        self.assertEqual(record["root_start_bytes"], self.root_partition.offset)
        self.assertEqual(record["root_size_bytes"], self.root_partition.size)
        self.assertEqual(record["root_image"], self.root_image)

    def test_gpt_metadata_and_free_space_are_not_partitions(self):
        table = """      start       size  index  contents
                  0          1         PMBR
                  1          1         Pri GPT header
                  2         32         Pri GPT table
                 34       2014
               2048      32768      5  GPT part - C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        """
        self.assertEqual(partition_number(table, 2048, 32768), 5)
        with self.assertRaises(ValueError):
            partition_number(table, 34, 2014)

    def test_gpt_wrong_type_or_ambiguous_geometry_stops(self):
        with self.assertRaises(ValueError):
            partition_number("2048 32768 5 GPT part - OTHER", 2048, 32768)
        line = "2048 32768 5 GPT part - C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n"
        with self.assertRaises(ValueError):
            partition_number(line + line, 2048, 32768)

    def test_512_byte_sectors_are_not_confused_with_bytes(self):
        self.partition.info["DeviceBlockSize"] = 512
        initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        record = json.loads((self.esp / "asahi/guix-boot.json").read_text())
        self.assertEqual((record["start_sector"], record["sector_count"]), (131072, 1024000))

    def test_existing_variables_are_never_replaced(self):
        target = self.esp / "ubootefi.var"
        target.write_bytes(b"existing boot choices")
        with self.assertRaises(FileExistsError):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertEqual(target.read_bytes(), b"existing boot choices")
        self.assertFalse((self.esp / "asahi/guix-boot.json").exists())

    def test_interrupted_write_never_publishes_boot_choice(self):
        # The first fsync saves the record. The second saves the new variable file.
        with patch("guix_boot.os.fsync", side_effect=[None, OSError("write failed")]):
            with self.assertRaisesRegex(OSError, "write failed"):
                initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertFalse((self.esp / "ubootefi.var").exists())
        partial = self.esp / "ubootefi.var.guix-new"
        before = partial.read_bytes()
        with self.assertRaises(FileExistsError):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertEqual(partial.read_bytes(), before)

    def test_existing_record_requires_inspection(self):
        record = self.esp / "asahi/guix-boot.json"
        record.parent.mkdir()
        record.write_text("interrupted attempt")
        with self.assertRaisesRegex(FileExistsError, "record already exists"):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertFalse((self.esp / "ubootefi.var").exists())
        self.assertEqual(record.read_text(), "interrupted attempt")

    def test_unknown_sector_size_stops_before_writing(self):
        self.partition.info = {}
        with self.assertRaisesRegex(ValueError, "logical block size"):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertFalse((self.esp / "ubootefi.var").exists())

    def test_invalid_root_image_record_stops_before_writing(self):
        for image in ({}, {"bytes": -1, "sha256": "a" * 64},
                      {"bytes": self.root_partition.size + 4096, "sha256": "a" * 64},
                      {"bytes": 4096, "sha256": "not a checksum"}):
            with self.subTest(image=image), self.assertRaisesRegex(ValueError, "root image"):
                initialize_boot(self.esp, self.partition, self.root_partition, image)
            self.assertFalse((self.esp / "ubootefi.var").exists())

    def test_misaligned_partition_stops_before_writing(self):
        self.partition.offset += 1
        self.root_partition.offset += 1
        with self.assertRaisesRegex(ValueError, "aligned"):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)

    def test_missing_loader_stops_before_writing(self):
        (self.esp / "EFI/BOOT/BOOTAA64.EFI").unlink()
        with self.assertRaisesRegex(ValueError, "Missing boot file"):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)

    def test_root_on_another_disk_is_rejected_before_any_write(self):
        self.root_partition.name = "disk8s13"
        with self.assertRaises(ValueError):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)
        self.assertFalse((self.esp / "ubootefi.var").exists())
        self.assertFalse((self.esp / "asahi/guix-boot.json").exists())

    def test_root_overlapping_efi_is_rejected(self):
        self.root_partition.offset = self.partition.offset
        with self.assertRaises(ValueError):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)

    def test_undersized_root_is_rejected(self):
        self.root_partition.size = 1024**3
        with self.assertRaises(ValueError):
            initialize_boot(self.esp, self.partition, self.root_partition, self.root_image)

    def test_invalid_identity(self):
        with self.assertRaises(ValueError):
            boot_store(12, 1, 1, "not a UUID")
        with self.assertRaises(ValueError):
            boot_store(0, 1, 1, self.partition.uuid)
        with self.assertRaises(ValueError):
            boot_store(12, 1, 1, "00000000-0000-0000-0000-000000000000")

    def test_upstream_hook_is_opt_in_and_uses_created_efi(self):
        source = Path(os.environ.get("ASAHI_SOURCE", PROJECT / "build/asahi-installer")) / "src"
        self.assertTrue((source / "osinstall.py").is_file(), "Run make check code to prepare Asahi source")
        sys.path.insert(0, str(source))
        self.addCleanup(sys.path.pop, 0)
        upstream = importlib.import_module("osinstall")
        template = {"default_os_name": "Guix System", "partitions": [],
                    "boot_object": "m1n1.bin", "next_object": "m1n1/boot.bin",
                    "guix_root_image": self.root_image}
        disk = SimpleNamespace(mount=lambda name: str(self.esp))
        for enabled in (False, True):
            with self.subTest(enabled=enabled), \
                 patch.object(upstream, "initialize_boot") as initialize, \
                 patch.object(upstream.m1n1, "build"), \
                 contextlib.redirect_stdout(io.StringIO()):
                template["guix_boot"] = enabled
                installer = upstream.OSInstaller(disk, {}, template)
                installer.part_info = [self.partition, self.root_partition]
                installer.efi_part = self.partition
                installer.install(SimpleNamespace(boot_obj_path="unused"))
                if enabled:
                    initialize.assert_called_once_with(str(self.esp), self.partition, self.root_partition, self.root_image)
                else:
                    initialize.assert_not_called()


if __name__ == "__main__":
    unittest.main()
