#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Test Guix's configuration writers, then calculate console and desktop derivations.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
start_check configuration-check
(
pinned_guix describe -f channels > "$records/channels.scm"
installer_source
pinned_guix build -L "$records/installer-source" -L src ${build_options[@]+"${build_options[@]}"} \
    --root="$records/check-program" --file=tests/guix/configuration-check.scm
"$PYTHON" "$test_project/scripts/build_inputs.py" verify --directory "$source"

# SRFI-64 saves its test report in the current directory.
(
    cd "$records"
    ./check-program "$records"
)

# Guix checks the imports, services, bootloader, and filesystems.
# Disable graft computation, which can download packages even with --derivation.
# Release builds use grafts. This test checks only the configuration.
for example in example gnome connman dhcp sway; do
    printf '\nDeriving %s configuration...\n' "$example"
    pinned_guix system build --system=aarch64-linux --no-grafts --derivation \
        "$records/$example-system.scm" > "$records/$example-system.drv"
    test -s "$records/$example-system.drv"
done
printf '\nConfiguration tests and Guix system derivation passed.\n'
printf 'Example: %s/example-system.scm\n' "$records"
printf 'This example uses fictional users and disks. Do not reconfigure with it.\n'
) 2>&1 | tee "$records/check.log"
