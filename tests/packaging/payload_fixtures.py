# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Supply package data for the image, build, and bundle tests.

The byte arrays contain only the headers that these checks need.
They are not bootable images. These fixtures do not access disk devices.
"""

import hashlib
from pathlib import Path
import struct


# Match the upstream install-package layout independently of the checker.
# Source: (asahi guix search-paths), revision ee2e7465c0137224bcc0ad3b3d0d02109cb3a6c7.
PACKAGE_DIRECTORY = Path("share/asahi-installer/os")


def root_image():
    image = bytearray(128 * 1024)
    base = 65536
    image[base + 32:base + 48] = bytes.fromhex("00112233445566778899aabbccddeeff")
    struct.pack_into("<Q", image, base + 48, base)
    image[base + 64:base + 72] = b"_BHRfS_M"
    struct.pack_into("<Q", image, base + 112, len(image))
    struct.pack_into("<Q", image, base + 136, 1)
    struct.pack_into("<I", image, base + 144, 4096)
    return bytes(image)


def efi_image():
    image = bytearray(512)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 60, 128)
    image[128:132] = b"PE\0\0"
    struct.pack_into("<H", image, 132, 0xAA64)
    struct.pack_into("<H", image, 152, 0x20B)
    struct.pack_into("<H", image, 220, 10)
    return bytes(image)


def ram_files():
    root = b"hsqs" + bytes(92)
    return {
        "esp/hello-guix/root.squashfs": root,
        "esp/hello-guix/linux": b"kernel fixture",
        "esp/hello-guix/initrd": b"initrd fixture",
        "esp/hello-guix/SHA256SUMS":
            f"{hashlib.sha256(root).hexdigest()}  root.squashfs\n".encode(),
    }


ENTRY = {
    "name": "Guix System (Hello Guix 0.1)",
    "default_os_name": "Guix System",
    "boot_object": "m1n1.bin",
    "next_object": "m1n1/boot.bin",
    "package": "guix-setup.zip",
    "icon": "guix.icns",
    "supported_fw": ["12.3", "12.3.1", "13.5"],
    "extras": [],
    "partitions": [
        {"name": "EFI", "type": "EFI", "size": "524288000B", "format": "fat",
         "volume_id": "0x1234abcd", "copy_firmware": True, "copy_installer_data": True,
         "source": "esp"},
        {"name": "Guix_image", "type": "Linux", "size": "131072B",
         "image": "Guix_image.img", "expand": True},
    ],
}
