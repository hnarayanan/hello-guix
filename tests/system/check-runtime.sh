#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise installed-system support with the selected Guix channel profile.
source "$(dirname "${BASH_SOURCE[0]}")/../support/common.sh"
start_recorded_check runtime-check
(
    mkdir "$records/home"
    runtime_command="$guix_command"
    runtime_path="$PATH"
    daemon=()
    if test -n "${GUIX_DAEMON_SOCKET:-}"; then
        daemon=(GUIX_DAEMON_SOCKET="$GUIX_DAEMON_SOCKET")
    fi
    runtime_guix() {
        env -i HOME="$records/home" PATH="$runtime_path" LC_ALL=C \
            ${daemon[@]+"${daemon[@]}"} "$runtime_command" "$@"
    }

    cd "$records"
    # Ask Guix for its complete profile before following the executable's links.
    # Freeze that profile so a concurrent pull cannot change later commands.
    runtime_guix repl "$source/tests/system/runtime-profile.scm" > profile
    runtime=$(cat profile)
    if ! test -x "$runtime/bin/guix"; then
        printf 'Selected profile has no executable bin/guix: %s\n' "$runtime" >&2
        exit 1
    fi
    runtime_command="$runtime/bin/guix"
    runtime_path="$runtime/bin"
    runtime_guix describe -f channels > channels.scm
    printf '%s\n' "${GUIX_DAEMON_SOCKET:-default local socket}" > daemon
    printf 'Guix profile: %s\n' "$runtime"
    printf 'Building the runtime channel profile with these inputs...\n'
    runtime_guix build ${build_options[@]+"${build_options[@]}"} \
        --root="$records/channel" --file="$source/tests/system/runtime-channel.scm"
    runtime_command="$records/channel/bin/guix"
    runtime_guix repl "$source/tests/system/runtime-profile.scm" > channel-profile
    runtime=$(cat channel-profile)
    if ! test -x "$runtime/bin/guix"; then
        printf 'Built profile has no executable bin/guix: %s\n' "$runtime" >&2
        exit 1
    fi
    runtime_command="$runtime/bin/guix"
    runtime_path="$runtime/bin"
    runtime_guix describe -f channels > channel-channels.scm
    printf 'Checking hardware support through the channel profile...\n'
    runtime_guix repl "$source/tests/system/hardware.scm"
    runtime_guix repl "$source/tests/system/boot.scm"
    runtime_guix repl "$source/tests/system/runtime.scm"
    printf '\nRuntime checks passed with the recorded channel profile.\n'
) 2>&1 | tee "$records/check.log"
