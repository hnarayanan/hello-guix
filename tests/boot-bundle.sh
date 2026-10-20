#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Check saved components without boot code execution or writes to EFI.
set -euo pipefail
export LC_ALL=C
bundle=${1:?Usage: bash tests/boot-bundle.sh ASAHI-BOOT-DIRECTORY}
work=$(mktemp -d "${TMPDIR:-/tmp}/hello-guix-boot-check.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The bundle contains m1n1, the kernel's Apple device trees in filename order,
# and compressed U-Boot, in that sequence. Compare all bytes in each component.
dtbs=("$bundle/kernel/lib/dtbs/apple/"*.dtb)
for file in "$bundle/m1n1/libexec/m1n1.bin" "${dtbs[@]}"; do
    test -s "$file"
done
cat "$bundle/m1n1/libexec/m1n1.bin" "${dtbs[@]}" > "$work/prefix"
bytes=$(wc -c < "$work/prefix")
head -c "$bytes" "$bundle/boot.bin" | cmp "$work/prefix" -
tail -c "+$((bytes + 1))" "$bundle/boot.bin" | gzip -dc > "$work/u-boot"
cmp "$bundle/u-boot/libexec/u-boot-nodtb.bin" "$work/u-boot"
printf 'Boot bundle contains the retained m1n1, Apple device trees and U-Boot.\n'
