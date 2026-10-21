#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Pass only a newly created disk-image file to QEMU, never a host device.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
case "${1:-}" in
    installation-target)
        size=20G; seconds=600; marker=HELLO-GUIX-TARGET
        arguments='console=ttyAMA0 panic=1 hello-guix-test=installation-target' ;;
    installation) ;;
    *) echo 'Usage: check-vm.sh installation-target|installation' >&2; exit 1 ;;
esac
fixture=$1
start_check "$fixture"
(
if test "$fixture" = installation; then
    installer_source
    pinned_guix build -L "$records/installer-source" -L src ${build_options[@]+"${build_options[@]}"} \
        --root="$records/fixture" --file=tests/guix/installation-vm.scm
    "$records/fixture/python" tests/run-installation-vm.py "$records/fixture" \
        --qemu "$records/fixture/qemu" --fdtput "$records/fixture/fdtput" \
        --firmware "$records/fixture/firmware" --output="$records" \
        ${VM_MEMORY:+--memory "$VM_MEMORY"}
    exit
fi
pinned_guix build -L src ${build_options[@]+"${build_options[@]}"} \
    --root="$records/tools" --file="tests/guix/$fixture.scm"
truncate -s "$size" "$records/disk.img"
# The guest needs no terminal input, which can suspend QEMU under timeout.
"$records/tools/timeout" "$seconds" "$records/tools/qemu" \
    -machine virt -cpu max -accel tcg -m 3072 -smp 2 -nographic -no-reboot \
    -kernel "$records/tools/kernel" -initrd "$records/tools/initrd" \
    -append "$arguments" \
    -drive "if=none,id=test,format=raw,file=$records/disk.img" \
    -device virtio-blk-pci,drive=test -nic none \
    < /dev/null > "$records/console.log" 2>&1
grep -F "$marker-PASS" "$records/console.log"
! grep -F "$marker-FAIL" "$records/console.log"
) 2>&1 | tee "$records/check.log"
