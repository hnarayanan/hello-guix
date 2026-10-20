# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later

import gzip
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class RetainedBootBundleTests(unittest.TestCase):
    def test_components_and_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            parts = {"m1n1/libexec/m1n1.bin": b"m1n1",
                     "kernel/lib/dtbs/apple/a.dtb": b"\xd0\x0d\xfe\xedA",
                     "kernel/lib/dtbs/apple/b.dtb": b"\xd0\x0d\xfe\xedB",
                     "u-boot/libexec/u-boot-nodtb.bin": b"u-boot"}
            for name, data in parts.items():
                file = bundle / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(data)
            m1n1, a, b, uboot = parts.values()
            compressed = gzip.compress(uboot)
            cases = [("valid", m1n1 + a + b + compressed, True),
                     ("missing tree", m1n1 + a + compressed, False),
                     ("reordered trees", m1n1 + b + a + compressed, False),
                     ("truncated U-Boot", m1n1 + a + b + compressed[:-5], False),
                     ("wrong U-Boot", m1n1 + a + b + gzip.compress(b"other"), False)]
            for name, content, valid in cases:
                with self.subTest(name=name):
                    (bundle / "boot.bin").write_bytes(content)
                    result = subprocess.run(["bash", str(PROJECT / "tests/boot-bundle.sh"),
                                             str(bundle)], capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)


if __name__ == "__main__":
    unittest.main()
