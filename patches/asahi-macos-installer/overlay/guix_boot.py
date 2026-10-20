# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: MIT
"""Set the initial boot choice for a new Guix EFI partition.

Asahi's OSInstaller calls this module after it copies the installation files.
This module does not create partitions or change existing U-Boot variables.
For the U-Boot version-1 file format, see tools/efivar.py and
lib/efi_loader/efi_var_file.c in AsahiLinux/u-boot, asahi-v2025.10-2.
"""

import hashlib
import json
import logging
import os
from pathlib import Path
import re
import struct
import subprocess
import uuid
import zlib


EFI_GLOBAL = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c")
LOADER = r"\EFI\BOOT\BOOTAA64.EFI"
STORE_MAGIC = 0x0161566966456255
EFI_PARTITION_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"


def partition_number(table, start, size):
    """Find the GPT entry by its start sector and size in macOS 'gpt -r show' output.

    A new BSD disk identifier can have a temporary suffix that differs from
    its GPT index. Do not use that suffix as the partition number in a boot path.
    """
    matches = []
    for line in table.splitlines():
        columns = line.split(None, 3)
        if len(columns) != 4 or not all(c.isdecimal() for c in columns[:3]):
            continue
        begin, length, index = map(int, columns[:3])
        if (begin, length) == (start, size):
            if columns[3].upper() != f"GPT PART - {EFI_PARTITION_TYPE}":
                raise ValueError("Matching GPT entry is not an EFI system partition")
            matches.append(index)
    if len(matches) != 1:
        raise ValueError("Cannot identify one EFI partition in the GPT")
    return matches[0]


def variable(name, data):
    # Attribute value 7 enables nonvolatile storage, boot-service access,
    # and runtime access. Set the authentication timestamp to zero.
    record = struct.pack("<IIQ16s", len(data), 7, 0, EFI_GLOBAL.bytes_le)
    record += name.encode("utf-16-le") + b"\0\0" + data
    return record + bytes(-len(record) % 8)


def boot_store(partition_number, start, size, partuuid):
    """Encode one persistent boot choice. START and SIZE are logical sectors."""
    if not (0 < partition_number < 2**32 and 0 < start < 2**64
            and 0 < size < 2**64 and start + size < 2**64):
        raise ValueError("Invalid EFI partition geometry")
    identity = uuid.UUID(partuuid)
    if identity.int == 0:
        raise ValueError("EFI partition UUID is empty")
    # The UEFI hard-drive path contains the GPT partition number, sector range, and GUID.
    drive = struct.pack("<BBHIQQ16sBB", 4, 1, 42, partition_number, start, size,
                        identity.bytes_le, 2, 2)
    filename = LOADER.encode("utf-16-le") + b"\0\0"
    path = drive + struct.pack("<BBH", 4, 4, 4 + len(filename)) + filename + b"\x7f\xff\x04\x00"
    option = struct.pack("<IH", 1, len(path)) + "Guix System\0".encode("utf-16-le") + path
    body = variable("Boot0000", option) + variable("BootOrder", struct.pack("<H", 0))
    return struct.pack("<QQII", 0, STORE_MAGIC, 24 + len(body), zlib.crc32(body)) + body


def initialize_boot(esp, partition, root_partition, root_image):
    """Write U-Boot variables on ESP only if it has boot files and no existing variable store."""
    esp = Path(esp)
    if (not isinstance(root_image, dict) or set(root_image) != {"bytes", "sha256"}
            or type(root_image["bytes"]) is not int
            or not 0 < root_image["bytes"] <= root_partition.size
            or root_image["bytes"] % 4096
            or not isinstance(root_image["sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", root_image["sha256"])):
        raise ValueError("Invalid empty root image record")
    match = re.fullmatch(r"(disk[0-9]+)s[1-9][0-9]*", partition.name)
    if not match or partition.type != "EFI":
        raise ValueError("Expected a macOS EFI partition identifier")
    root_match = re.fullmatch(r"(disk[0-9]+)s[1-9][0-9]*", root_partition.name)
    if (not root_match or root_match[1] != match[1]
            or root_partition.type != "Linux Filesystem"
            or root_partition.offset < partition.offset + partition.size
            or root_partition.size < 8 * 1024**3
            or uuid.UUID(root_partition.uuid).int == 0):
        raise ValueError("Expected an unused Linux target of at least 8 GiB after this EFI")
    block_size = partition.info.get("DeviceBlockSize")
    if block_size not in (512, 4096):
        raise ValueError("Unknown device logical block size; cannot form a UEFI device path")
    if partition.offset % block_size or partition.size % block_size:
        raise ValueError("EFI partition is not aligned to its logical block size")
    for name in ("m1n1/boot.bin", "EFI/BOOT/BOOTAA64.EFI"):
        path = esp / name
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing boot file: {name}")
    target = esp / "ubootefi.var"
    temporary = esp / "ubootefi.var.guix-new"
    if target.exists() or target.is_symlink() or temporary.exists() or temporary.is_symlink():
        raise FileExistsError("EFI variables already exist; refusing to replace them")
    start, size = partition.offset // block_size, partition.size // block_size
    table = subprocess.check_output(["gpt", "-r", "show", f"/dev/{match[1]}"], text=True)
    number = partition_number(table, start, size)
    content = boot_store(number, start, size, partition.uuid)
    records = esp / "asahi/guix-boot.json"
    if records.exists() or records.is_symlink():
        raise FileExistsError("Guix boot record already exists")
    record = {
        "layout": "hello-guix-ram-v1",
        "root_partition_uuid": str(uuid.UUID(root_partition.uuid)),
        "root_start_bytes": root_partition.offset,
        "root_size_bytes": root_partition.size,
        "root_image": root_image,
        "partition_uuid": str(uuid.UUID(partition.uuid)),
        "partition_number": number,
        "logical_sector_bytes": block_size,
        "start_sector": start,
        "sector_count": size,
        "loader": LOADER,
        "boot_order": ["0000"],
        "variable_store_sha256": hashlib.sha256(content).hexdigest(),
    }
    records.parent.mkdir(parents=True, exist_ok=True)
    # Save the partition record before the boot choice.
    # If a write fails, keep the record and stop. Do not overwrite it on a retry.
    with records.open("x") as stream:
        json.dump(record, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    with temporary.open("xb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    if temporary.read_bytes() != content:
        raise OSError("EFI variable file verification failed")
    if target.exists() or target.is_symlink():
        raise FileExistsError("EFI variable store appeared during installation")
    temporary.rename(target)
    logging.info("Guix initial boot entry: %s", record)
