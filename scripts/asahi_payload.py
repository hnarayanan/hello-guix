#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the Asahi installation image built by Guix. Prepare a local OS catalogue.

Staging writes a new catalogue through a temporary directory beside it.
This program does not extract archives, run the installer, mount filesystems,
or open devices.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import sys
import tempfile
import uuid
import zipfile

from build_inputs import (PROJECT, checksum_text, file_hashes, sha256,
                          verify_snapshot)

# %asahi-installer-os-path in the pinned (asahi guix search-paths) module.
PACKAGE_DIRECTORY = Path("share/asahi-installer/os")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def relative_path(value):
    require(isinstance(value, str) and bool(value), "Missing archive path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and all(p not in (".", "..") for p in path.parts)
            and str(path) == value.rstrip("/")
            and not any(c in value for c in "\\:\0")
            and all(ord(c) >= 32 for c in value), f"Unsafe archive path: {value!r}")
    require(all(not part.endswith((".", " ")) for part in path.parts),
            f"Ambiguous FAT path: {value!r}")
    return path


def byte_size(value):
    require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*B", value),
            f"Expected an exact positive byte size, got {value!r}")
    return int(value[:-1])


def read_prefix(archive, name, size):
    with archive.open(name) as stream:
        return stream.read(size)


def check_efi(archive, name):
    header = read_prefix(archive, name, 4096)
    require(header[:2] == b"MZ" and len(header) >= 64, "EFI loader has no DOS header")
    offset = struct.unpack_from("<I", header, 60)[0]
    require(offset + 94 <= len(header) and header[offset:offset + 4] == b"PE\0\0",
            "EFI loader has no readable PE header")
    require(struct.unpack_from("<H", header, offset + 4)[0] == 0xAA64,
            "EFI loader is not ARM64")
    require(struct.unpack_from("<H", header, offset + 24)[0] == 0x20B,
            "EFI loader is not PE32+")
    require(struct.unpack_from("<H", header, offset + 92)[0] == 10,
            "EFI loader is not an EFI application")


def check_root(archive, name):
    size = archive.getinfo(name).file_size
    require(size % 4096 == 0, "Root image size is not a multiple of 4 KiB")
    header = read_prefix(archive, name, 65536 + 4096)[65536:]
    require(len(header) == 4096 and header[64:72] == b"_BHRfS_M",
            "Root image has no Btrfs superblock")
    require(struct.unpack_from("<Q", header, 48)[0] == 65536,
            "Unexpected Btrfs superblock location")
    filesystem_size = struct.unpack_from("<Q", header, 112)[0]
    require(0 < filesystem_size <= size and filesystem_size % 4096 == 0,
            "Btrfs filesystem extends beyond the raw image or has an invalid size")
    require(struct.unpack_from("<Q", header, 136)[0] == 1,
            "Root image must contain a single-device filesystem")
    require(struct.unpack_from("<I", header, 144)[0] == 4096,
            "Root image must use 4 KiB Btrfs sectors")
    identity = uuid.UUID(bytes=header[32:48])
    require(identity.int != 0, "Root filesystem UUID is empty")
    return str(identity), filesystem_size


def check_payload(package_directory):
    directory = package_directory / PACKAGE_DIRECTORY
    metadata_files = sorted(directory.glob("*.json"))
    require(len(metadata_files) == 1,
            f"Expected one OS description in {directory}; found {len(metadata_files)}")
    return check_os(metadata_files[0], directory)


def check_os(metadata_file, directory):
    """Check one OS description and its ZIP file."""
    metadata = json.loads(metadata_file.read_text())
    require(isinstance(metadata, dict) and isinstance(metadata.get("os_list"), list)
            and len(metadata["os_list"]) == 1, "Expected exactly one OS entry")
    entry = metadata["os_list"][0]
    require(isinstance(entry, dict), "OS entry must be an object")
    require(entry.get("boot_object") == "m1n1.bin"
            and entry.get("next_object") == "m1n1/boot.bin", "Unexpected Asahi boot chain")
    require(entry.get("extras") in ([], {}), "Unexpected extra downloads")
    require(isinstance(entry.get("supported_fw"), list)
            and "13.5" in entry["supported_fw"], "The M1 firmware baseline is missing")
    archive_name = entry.get("package")
    require(relative_path(archive_name).name == archive_name and archive_name.endswith(".zip"),
            "Package must name a local ZIP file")
    archive_path = directory / archive_name
    require(archive_path.is_file(), f"Missing archive: {archive_path}")
    parts = entry.get("partitions")
    require(isinstance(parts, list) and len(parts) == 2
            and all(isinstance(p, dict) for p in parts), "Expected EFI and root partitions")
    require(all(isinstance(p.get("name"), str) and p["name"]
                and all(ord(c) >= 32 for c in p["name"]) for p in parts),
            "Each partition must have a printable name")
    efi, root = parts
    require(efi.get("type") == "EFI" and efi.get("format") == "fat"
            and efi.get("source") == "esp" and not efi.get("image")
            and not efi.get("expand"), "Invalid EFI partition description")
    require(efi.get("copy_firmware") is True and efi.get("copy_installer_data") is True,
            "EFI partition must receive firmware and installer records")
    require("volume_id" not in efi or (isinstance(efi["volume_id"], str)
            and re.fullmatch(r"0x[0-9a-fA-F]{1,8}", efi["volume_id"])),
            "Invalid EFI FAT volume ID")
    require(not entry.get("guix_boot") or "volume_id" not in efi,
            "A published catalogue must let Asahi create a fresh EFI identity")
    require(root.get("type") == "Linux" and root.get("expand") is True
            and not root.get("format") and not root.get("source"),
            "Root must be an expandable raw Linux image")
    root_name = root.get("image")
    require(relative_path(root_name).name == root_name, "Root image must be at archive root")
    icon_name = entry.get("icon")
    require(relative_path(icon_name).name == icon_name, "Icon must be at archive root")
    efi_size, root_size = byte_size(efi["size"]), byte_size(root["size"])
    require(efi_size % 4096 == root_size % 4096 == 0, "Partition sizes must align to 4 KiB")

    with zipfile.ZipFile(archive_path) as archive:
        names = set()
        folded_names = set()
        file_names = set()
        efi_bytes = 0
        for member in archive.infolist():
            path = relative_path(member.filename)
            require(member.filename not in names and str(path).casefold() not in folded_names,
                    f"Duplicate or case-ambiguous archive path: {member.filename}")
            names.add(member.filename)
            folded_names.add(str(path).casefold())
            mode = member.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR),
                    f"Archive contains a special file: {member.filename}")
            require(not member.flag_bits & 1, "Encrypted archives are unsupported")
            if member.is_dir():
                require(path.parts[0] == "esp", "Unexpected archive directory")
            else:
                file_names.add(str(path).casefold())
                require(member.filename in (root_name, icon_name) or path.parts[0] == "esp",
                        f"Unexpected payload file: {member.filename}")
                if path.parts[0] == "esp":
                    efi_bytes += member.file_size

        for name in folded_names:
            require(not any(str(parent) in file_names for parent in PurePosixPath(name).parents),
                    f"Archive file is also a parent directory: {name}")

        for name in (root_name, icon_name, "esp/m1n1/boot.bin", "esp/EFI/BOOT/BOOTAA64.EFI",
                     "esp/hello-guix/root.squashfs", "esp/hello-guix/SHA256SUMS",
                     "esp/hello-guix/linux", "esp/hello-guix/initrd"):
            require(name in names and archive.getinfo(name).file_size > 0,
                    f"Missing or empty payload file: {name}")
        require(not any(name in ("esp/vendorfw", "esp/asahi")
                        or name.startswith(("esp/vendorfw/", "esp/asahi/"))
                        for name in folded_names),
                "Per-machine firmware and installer records must not be distributed")
        require("esp/ubootefi.var" not in folded_names,
                "Initial EFI variables must be made for the new partition, not shipped in the image")
        require(archive.getinfo(root_name).file_size == root_size
                or (entry.get("guix_boot") is True and root_size == 8 * 1024**3
                    and archive.getinfo(root_name).file_size < root_size),
                "Root partition metadata does not match the image size")
        require(efi_bytes + 128 * 1024 * 1024 < efi_size,
                "EFI partition needs room for firmware, records and FAT overhead")
        ram_root = "esp/hello-guix/root.squashfs"
        require(96 <= archive.getinfo(ram_root).file_size < 2600 * 1024**2,
                "RAM filesystem exceeds the supported size")
        require(read_prefix(archive, ram_root, 4) == b"hsqs",
                "RAM root is not a SquashFS image")
        with archive.open(ram_root) as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        require(archive.read("esp/hello-guix/SHA256SUMS") ==
                f"{digest}  root.squashfs\n".encode(), "RAM filesystem checksum differs")
        check_efi(archive, "esp/EFI/BOOT/BOOTAA64.EFI")
        root_uuid, filesystem_size = check_root(archive, root_name)
        with archive.open(root_name) as stream:
            root_digest = hashlib.file_digest(stream, "sha256").hexdigest()
        root_image = {"bytes": archive.getinfo(root_name).file_size,
                      "sha256": root_digest}
        require(not entry.get("guix_boot") or entry.get("guix_root_image") == root_image,
                "Root image preparation record differs from the archive")
        require(read_prefix(archive, icon_name, 4) == b"icns", "Invalid icon header")
        require(archive.testzip() is None, "Archive CRC check failed")

    report = {
        "kind": "installation",
        "archive": archive_name,
        "sha256": sha256(archive_path),
        "archive_bytes": archive_path.stat().st_size,
        "efi_bytes": efi_size,
        "root_bytes": root_size,
        "root_uuid": root_uuid,
        "root_filesystem_bytes": filesystem_size,
        "root_image": root_image,
        "checks": ["archive paths", "archive CRCs", "partition sizes", "ARM64 EFI header",
                   "Btrfs superblock", "firmware handover flags"],
        "limitations": ["No boot or complete-filesystem check has been performed.",
                        "Setup provisions accounts and the next boot; this check does not verify hardware installation."],
    }
    return entry, archive_path, report


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def stage(package_directory, output, inputs, project=PROJECT):
    input_hashes = verify_snapshot(inputs, project)
    entry, archive_path, report = check_payload(package_directory)
    # Enable our Asahi extension, which sets the initial U-Boot boot order.
    entry["guix_boot"] = True
    # Without volume_id, Asahi generates a new FAT filesystem UUID.
    entry["partitions"][0].pop("volume_id", None)
    entry["guix_root_image"] = report["root_image"]
    # Asahi can make the partition larger than the image.
    # Set a minimum capacity without adding empty blocks to the download.
    entry["partitions"][1]["size"] = f"{8 * 1024**3}B"
    report["root_bytes"] = 8 * 1024**3
    report["package_output"] = str(package_directory.resolve())
    report["source_checksums_sha256"] = sha256(inputs / "SHA256SUMS")
    documents = {
        "installer_data.json": json_bytes({"os_list": [entry]}),
        "payload-report.json": json_bytes(report),
    }
    expected = {name: hashlib.sha256(content).hexdigest()
                for name, content in documents.items()}
    expected.update({f"source-record/{name}": digest for name, digest in input_hashes.items()})
    expected[f"os/{archive_path.name}"] = report["sha256"]
    documents["SHA256SUMS"] = checksum_text(expected).encode()
    expected["SHA256SUMS"] = hashlib.sha256(documents["SHA256SUMS"]).hexdigest()

    if output.exists() or output.is_symlink():
        require(file_hashes(output) == expected,
                f"Existing catalogue differs: {output}. Preserve it and choose a new BUILD_DIR.")
        return report

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".payload-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        publication = temporary / "catalogue"
        (publication / "os").mkdir(parents=True)
        copied = publication / "os" / archive_path.name
        shutil.copyfile(archive_path, copied)
        shutil.copytree(inputs, publication / "source-record")
        for name, content in documents.items():
            (publication / name).write_bytes(content)
        require(file_hashes(publication) == expected, "Files changed while staging")
        verify_snapshot(inputs, project)
        require(not output.exists() and not output.is_symlink(), f"Output already exists: {output}")
        publication.rename(output)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "stage"))
    parser.add_argument("--package", required=True, type=Path, help="Guix package output directory")
    parser.add_argument("--output", type=Path, help="new local catalogue directory (stage only)")
    parser.add_argument("--inputs", type=Path, help="saved build inputs (stage only)")
    args = parser.parse_args()
    if args.command == "stage" and (args.output is None or args.inputs is None):
        parser.error("stage requires --output and --inputs")
    if args.command == "check" and (args.output is not None or args.inputs is not None):
        parser.error("check does not use --output or --inputs")
    try:
        if args.command == "stage":
            report = stage(args.package, args.output, args.inputs)
        else:
            _, _, report = check_payload(args.package)
        print(json.dumps(report, indent=2, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, RuntimeError) as error:
        parser.exit(1, f"Payload check failed: {error}\n")


if __name__ == "__main__":
    main()
