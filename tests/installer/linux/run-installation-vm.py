#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install and boot a console system in a fresh copy of the Guix VM fixture.

QEMU receives two ordinary image files, outbound user-mode networking, and no
host shares or device passthrough. Keep the console logs on success or failure.
"""

import argparse
from pathlib import Path
import os
import platform
import selectors
import shutil
import subprocess
import tempfile
import time


class Console:
    def __init__(self, command, log, timeout):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.log = log.open("wb")
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.deadline = time.monotonic() + timeout

    def expect(self, text=None):
        needle = text.encode() if text is not None else None
        while needle is None or needle not in self.buffer:
            if time.monotonic() >= self.deadline:
                raise TimeoutError(f"VM did not reach {text!r}; see its console log")
            if self.selector.select(1):
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    if needle is None and self.process.wait(timeout=10) == 0:
                        return
                    raise RuntimeError(f"VM exited before {text!r}; see its console log")
                self.log.write(data)
                self.log.flush()
                self.buffer += data
                if b"HELLO-GUIX-CHECK-FAIL" in self.buffer:
                    raise RuntimeError("Guest check failed; see its console log")
        self.buffer = self.buffer.split(needle, 1)[1]

    def send(self, command):
        self.process.stdin.write((command + "\n").encode())
        self.process.stdin.flush()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--qemu", default="qemu-system-aarch64")
    parser.add_argument("--fdtput", default="fdtput")
    parser.add_argument("--firmware", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("build"))
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--memory", type=int, default=6144,
                        help="guest RAM in MiB (default: 6144)")
    args = parser.parse_args()
    if args.memory <= 0:
        parser.error("Guest memory must be a positive number of MiB")
    if os.getuid() == 0:
        parser.error("Run as an ordinary user, without sudo")
    fixture = args.fixture.resolve()
    for name in ("disk.qcow2", "checks.img", "linux", "initrd", "system", "efi-id"):
        if not (fixture / name).is_file():
            parser.error(f"Missing regular fixture file: {name}")
    if not args.firmware.is_file():
        parser.error("Expected an AArch64 UEFI firmware file")
    args.output.mkdir(parents=True, exist_ok=True)
    records = Path(tempfile.mkdtemp(prefix="installation-vm-", dir=args.output)).resolve()
    print(f"Records: {records}", flush=True)
    disk = records / "disk.qcow2"
    mac = platform.system() == "Darwin"
    shutil.copyfile(fixture / "disk.qcow2", disk)
    disk.chmod(0o600)
    accel = "hvf" if mac else ("kvm" if os.access("/dev/kvm", os.W_OK) else "tcg")
    print(f"Virtual machine: {accel}, {args.memory} MiB RAM. "
          "Logs stay in the records directory.", flush=True)
    base = [args.qemu, "-machine", "virt,acpi=off", "-accel", accel,
            "-cpu", "max" if accel == "tcg" else "host", "-m", str(args.memory), "-smp", "2"]
    dtb = records / "virt.dtb"
    subprocess.run([*base, "-machine", f"dumpdtb={dtb}", "-display", "none", "-nic", "none"], check=True)
    subprocess.run([args.fdtput, "-t", "s", str(dtb), "/chosen", "asahi,efi-system-partition",
                    (fixture / "efi-id").read_text().strip()], check=True)
    common = [*base, "-dtb", str(dtb), "-display", "none", "-serial", "stdio",
              "-monitor", "none", "-no-reboot",
              "-drive", f"file={disk},format=qcow2,if=virtio",
              "-drive", f"file={fixture}/checks.img,format=raw,if=virtio,readonly=on",
              "-nic", "user,model=virtio-net-pci"]
    system = (fixture / "system").read_text().strip()
    setup = ["-kernel", str(fixture / "linux"), "-initrd", str(fixture / "initrd"),
             "-append", f"root=/dev/loop0 rootfstype=squashfs gnu.system={system} "
                        f"gnu.load={system}/boot console=ttyAMA0 net.ifnames=0"]
    mount_checks = "mkdir -p /run/vm-check; mount -o ro /dev/vdb /run/vm-check"
    vm = Console([*common, *setup], records / "install.log", 600)
    try:
        vm.expect("[press ENTER to login]")
        vm.send("")
        vm.expect("~#")
        vm.send("(" + mount_checks + " && guix repl /run/vm-check/install.scm) || "
                "printf 'HELLO-GUIX-%s\\n' CHECK-FAIL")
        vm.expect("HELLO-GUIX-REVIEW-CANCEL-PASS")
        print("Packaged questions and review cancellation passed. Installing…", flush=True)
        vm.deadline = time.monotonic() + args.timeout
        vm.expect("HELLO-GUIX-INSTALL-PASS")
        vm.deadline = time.monotonic() + 120
        vm.expect()
    finally:
        vm.close()
    print("Installation passed. Booting the installed system…", flush=True)
    vm = Console([*common, "-bios", str(args.firmware.resolve())], records / "boot.log", 300)
    try:
        vm.expect("login:")
        vm.send("root")
        vm.expect("Password:")
        vm.send("vm-password")
        vm.expect("~#")
        vm.send("(" + mount_checks + " && sh /run/vm-check/boot.sh) || "
                "printf 'HELLO-GUIX-%s\\n' CHECK-FAIL")
        vm.expect("HELLO-GUIX-BOOT-PASS")
        vm.expect("~#")
        vm.send("exit")
        vm.expect("login:")
        vm.send("alex")
        vm.expect("Password:")
        vm.send("vm-password")
        vm.expect("~$")
        vm.send('sudo -k sh -c \'test "$(id -u)" = 0 && printf "HELLO-GUIX-%s\\n" SUDO-PASS\'')
        vm.expect("Password:")
        vm.send("vm-password")
        vm.expect("HELLO-GUIX-SUDO-PASS")
        vm.expect("~$")
        vm.send("sudo -k /run/current-system/profile/sbin/halt")
        vm.expect("Password:")
        vm.send("vm-password")
        vm.deadline = time.monotonic() + 120
        vm.expect()
    finally:
        vm.close()
    print(f"Installed boot, source, DNS, ordinary login and sudo passed. Records: {records}")


if __name__ == "__main__":
    main()
