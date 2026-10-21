#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check Asahi's imports and local package reader without installation."""

import contextlib
from ctypes import create_string_buffer
import io
import json
import os
from pathlib import Path
import ssl
import sys


def forbid_side_effects(event, arguments):
    if event.startswith(("subprocess.", "socket.")) or event in (
            "os.system", "os.posix_spawn", "os.exec", "os.fork",
            "os.remove", "os.rename", "os.mkdir", "os.rmdir", "os.chmod"):
        raise RuntimeError(f"Side effect forbidden in runtime check: {event}")
    if event == "open":
        flags = arguments[2]
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            raise RuntimeError("File writes are forbidden in runtime check")


def main():
    bundle = Path(sys.argv[1]).resolve()
    runtime = bundle / "runtime"
    os.chdir(runtime)
    os.environ["REPO_BASE"] = str(bundle / "catalogue")
    sys.path.insert(0, str(runtime))
    sys.dont_write_bytecode = True
    sys.addaudithook(forbid_side_effects)

    import main as asahi
    import osinstall
    import m1n1
    from util import lzfse, COMPRESSION_LZFSE
    # Exercise the native calls Asahi uses to compress files during installation.
    plain = b"Hello, Guix.\n" * 1024
    compressed = create_string_buffer(len(plain) + 1024)
    scratch = create_string_buffer(lzfse.compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))
    size = lzfse.compression_encode_buffer(compressed, len(compressed), plain,
                                         len(plain), scratch, COMPRESSION_LZFSE)
    restored = create_string_buffer(len(plain))
    decoded = lzfse.compression_decode_buffer(restored, len(restored), compressed,
                                            size, None, COMPRESSION_LZFSE)
    if not size or decoded != len(plain) or restored.raw != plain:
        raise ValueError("Native LZFSE compression check failed")
    # Check the package reader from the selected Asahi release.
    # Do not call InstallerMain.main(), partition_disk(), install(), or
    # constructors that inspect the system.
    data = json.loads((bundle / "catalogue/installer_data.json").read_text())
    entry, = data["os_list"]
    if entry.get("guix_boot") is not True:
        raise ValueError("Guix boot adaptation is not selected")
    consumer = osinstall.OSInstaller(None, data, entry)
    with contextlib.redirect_stdout(io.StringIO()):
        consumer.load_package()
    try:
        if consumer.ucache is not None:
            raise ValueError("Local package unexpectedly uses the network")
        consumer.pkg.getinfo("esp/EFI/BOOT/BOOTAA64.EFI")
        consumer.pkg.getinfo("esp/m1n1/boot.bin")
    finally:
        consumer.pkg.fp.close()
        consumer.pkg.close()
    certificates = ssl.create_default_context().get_ca_certs()
    if not certificates:
        raise ValueError("Bundled certificate store is empty")
    print(json.dumps({
        "python": sys.version.split()[0],
        "openssl": ssl.OPENSSL_VERSION,
        "certificates": len(certificates),
        "asahi_module": str(Path(asahi.__file__).relative_to(bundle)),
        "stage_1": m1n1.get_version(str(runtime / "boot/m1n1.bin")),
        "os": entry["name"],
        "package_reader": "local ZIP opened successfully",
        "compression": "LZFSE round trip passed",
        "installer_started": False,
    }, indent=2))
    print("Bundled runtime verified")


if __name__ == "__main__":
    main()
