#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Check the reusable adapter without the installer overlay or a system build.
source "$(dirname "${BASH_SOURCE[0]}")/../support/common.sh"
start_check hardware-check
(
    pinned_guix describe -f channels > "$records/channels.scm"
    cd "$records"
    pinned_guix repl -L "$source/packaging/guix/channel" "$source/tests/system/hardware.scm"
    pinned_guix repl -L "$source/packaging/guix/channel" "$source/tests/system/boot.scm"
    printf '\nHardware adapter checks passed. No system was activated.\n'
) 2>&1 | tee "$records/check.log"
