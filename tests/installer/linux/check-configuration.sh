#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Test Guix's configuration writers, then calculate console and desktop derivations.
source "$(dirname "${BASH_SOURCE[0]}")/../../support/common.sh"
if test -n "${CHECK_CHANNEL_PROFILE:-}"; then
    case "$CHECK_CHANNEL_PROFILE" in
        /*) ;;
        *) echo 'channel_profile must be an absolute profile directory.' >&2; exit 1 ;;
    esac
    if ! test -x "$CHECK_CHANNEL_PROFILE/bin/guix"; then
        printf 'Channel profile has no executable bin/guix: %s\n' "$CHECK_CHANNEL_PROFILE" >&2
        exit 1
    fi
fi
start_check configuration-check
(
configuration_arguments=("$records")
if test -n "${CHECK_CHANNEL_PROFILE:-}"; then
    mkdir "$records/channel-home"
    channel_profile="$CHECK_CHANNEL_PROFILE"
    daemon=()
    if test -n "${GUIX_DAEMON_SOCKET:-}"; then
        daemon=(GUIX_DAEMON_SOCKET="$GUIX_DAEMON_SOCKET")
    fi
    channel_guix() {
        env -i HOME="$records/channel-home" PATH="$channel_profile/bin" LC_ALL=C \
            ${daemon[@]+"${daemon[@]}"} "$channel_profile/bin/guix" "$@"
    }
    # Freeze the complete profile before using it for both writer input and replay.
    channel_guix repl "$source/scripts/system/runtime-profile.scm" > "$records/channel-profile"
    channel_profile=$(cat "$records/channel-profile")
    if ! test -x "$channel_profile/bin/guix"; then
        printf 'Selected profile has no executable bin/guix: %s\n' "$channel_profile" >&2
        exit 1
    fi
    channel_guix describe -f channels > "$records/handoff-channels.scm"
    configuration_arguments+=("$records/handoff-channels.scm")
fi
pinned_guix describe -f channels > "$records/channels.scm"
installer_source
pinned_guix build -L "$records/installer-source" -L packaging/guix/installer -L packaging/guix/channel ${build_options[@]+"${build_options[@]}"} \
    --root="$records/check-program" --file=tests/installer/linux/configuration-check.scm
"$PYTHON" "$test_project/scripts/packaging/source_record.py" verify --directory "$source"

# SRFI-64 saves its test report in the current directory.
(
    cd "$records"
    ./check-program "${configuration_arguments[@]}"
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
if test -n "${CHECK_CHANNEL_PROFILE:-}"; then
    channel_guix repl "$source/tests/installer/linux/channel-handoff.scm" \
        "$records/channel-system.scm" "$records/handoff"
    channel_guix system build --no-grafts --save-provenance --derivation \
        "$records/handoff/provenance/configuration.scm" > "$records/handoff/recovered.drv"
    cmp "$records/handoff/system.drv" "$records/handoff/recovered.drv"
    printf '\nGenerated channel declaration replayed with the recorded profile.\n'
fi
printf '\nConfiguration tests and Guix system derivation passed.\n'
printf 'Example: %s/example-system.scm\n' "$records"
printf 'This example uses fictional users and disks. Do not reconfigure with it.\n'
) 2>&1 | tee "$records/check.log"
