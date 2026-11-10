#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise installed-system support with the selected Guix channel profile.
source "$(dirname "${BASH_SOURCE[0]}")/../support/common.sh"
case "${1:-}" in
    "") check_name=runtime-check ;;
    --channel) check_name=runtime-channel ;;
    --system) check_name=runtime-system ;;
    --firmware) check_name=runtime-firmware ;;
    *) echo 'Usage: check-runtime.sh [--channel|--system|--firmware]' >&2; exit 1 ;;
esac
if test "$#" -gt 1; then echo 'Usage: check-runtime.sh [--channel|--system|--firmware]' >&2; exit 1; fi
if test -n "${CHECK_CONFIGURATION:-}"; then
    if test "$check_name" != runtime-check; then
        echo 'configuration= is for make check code only=runtime.' >&2; exit 1
    fi
    case "$CHECK_CONFIGURATION" in
        /*) ;;
        *) echo 'configuration= requires an absolute path.' >&2; exit 1 ;;
    esac
    if ! test -f "$CHECK_CONFIGURATION" || ! test -r "$CHECK_CONFIGURATION"; then
        printf 'Configuration is not a readable file: %s\n' "$CHECK_CONFIGURATION" >&2
        exit 1
    fi
    if test -n "${BOOT_REFERENCE:-}"; then
        echo 'Choose configuration= or boot_reference= for the runtime check.' >&2; exit 1
    fi
fi
start_recorded_check "$check_name"
(
    mkdir "$records/home"
    runtime_command="$guix_command"
    runtime_path="$PATH"
    # The system fixture shares only this build socket with its host. It cannot
    # use a remote daemon, whose store would not be available to the container.
    if test "$check_name" = runtime-system; then
        daemon_socket=${GUIX_DAEMON_SOCKET:-/var/guix/daemon-socket/socket}
        case "$daemon_socket" in
            /*) ;;
            unix:///*) daemon_socket=${daemon_socket#unix://} ;;
            *) echo 'Runtime-system requires a local Unix Guix daemon socket.' >&2; exit 1 ;;
        esac
        if ! test -S "$daemon_socket"; then
            printf 'Guix daemon socket is not a local Unix socket: %s\n' "$daemon_socket" >&2
            exit 1
        fi
        export GUIX_DAEMON_SOCKET="$daemon_socket"
    fi
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
    runtime_guix repl "$source/scripts/system/runtime-profile.scm" > profile
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
    if test -n "${CHECK_CONFIGURATION:-}"; then
        runtime_guix repl "$source/tests/system/configuration.scm" \
            "$CHECK_CONFIGURATION" "$records/configuration" "${MAX_JOBS:-}" "${CORES:-}"
        runtime_guix system build --no-grafts --save-provenance --derivation \
            "$records/configuration/recovery/config.scm" > "$records/configuration/recovered.drv"
        cmp "$records/configuration/system.drv" "$records/configuration/recovered.drv"
        printf '\nReviewed configuration replayed with the selected channel profile.\n'
        exit
    fi
    if test "$check_name" = runtime-channel; then
        printf 'Building the disposable channel authentication tools...\n'
        runtime_guix build ${build_options[@]+"${build_options[@]}"} \
            --root="$records/tools" --file="$source/tests/system/channel-tools.scm"
        env -i HOME="$records/home" PATH="$runtime_path" LC_ALL=C \
            ${daemon[@]+"${daemon[@]}"} "$records/tools/timeout" \
            --signal=TERM --kill-after=20 600 "$records/tools/bash" \
            "$source/tests/system/check-channel-authentication.sh" \
            "$source" "$records/authentication" "$records/tools" \
            "$runtime/bin/guix" "${MAX_JOBS:-}" "${CORES:-}"
        printf '\nAuthenticated local channel checks passed with the recorded inputs.\n'
        exit
    fi
    printf 'Building the runtime channel profile with these inputs...\n'
    runtime_guix build ${build_options[@]+"${build_options[@]}"} \
        --root="$records/channel" --file="$source/tests/system/runtime-channel.scm"
    runtime_command="$records/channel/bin/guix"
    runtime_guix repl "$source/scripts/system/runtime-profile.scm" > channel-profile
    runtime=$(cat channel-profile)
    if ! test -x "$runtime/bin/guix"; then
        printf 'Built profile has no executable bin/guix: %s\n' "$runtime" >&2
        exit 1
    fi
    runtime_command="$runtime/bin/guix"
    runtime_path="$runtime/bin"
    runtime_guix describe -f channels > channel-channels.scm
    if test "$check_name" = runtime-system; then
        printf 'Building the disposable command-path fixture...\n'
        runtime_guix build --no-grafts ${build_options[@]+"${build_options[@]}"} \
            --root="$records/fixture" --file="$source/tests/system/boot-cli.scm"
        env -i HOME="$records/home" PATH="$runtime_path" LC_ALL=C \
            ${daemon[@]+"${daemon[@]}"} "$records/fixture/timeout" \
            --signal=TERM --kill-after=20 1200 "$records/fixture/run" "$records"
        printf '\nNative system command checks passed with the recorded channel profile.\n'
        exit
    fi
    if test "$check_name" = runtime-firmware; then
        printf 'Building the disposable early-firmware fixture...\n'
        runtime_guix build --no-grafts ${build_options[@]+"${build_options[@]}"} \
            --root="$records/fixture" --file="$source/tests/system/firmware-initrd.scm"
        "$records/fixture/timeout" --signal=TERM --kill-after=20 300 \
            "$records/fixture/qemu" -machine virt -cpu max -accel tcg \
            -m 512 -smp 1 -nographic -no-reboot -nic none \
            -kernel "$records/fixture/kernel" -initrd "$records/fixture/initrd" \
            -append 'console=ttyAMA0 panic=1' \
            < /dev/null > "$records/console.log" 2>&1
        grep -F 'HELLO-GUIX-FIRMWARE-PASS' "$records/console.log"
        if grep -F 'HELLO-GUIX-FIRMWARE-FAIL' "$records/console.log"; then exit 1; fi
        printf '\nFirmware is available before initrd setup in the disposable VM.\n'
        exit
    fi
    printf 'Checking hardware support through the channel profile...\n'
    runtime_guix repl "$source/tests/system/hardware.scm"
    runtime_guix repl "$source/tests/system/boot.scm"
    runtime_guix repl "$source/tests/system/boot-deployment.scm"
    runtime_guix repl "$source/tests/system/boot-build.scm" \
        "${BOOT_REFERENCE:-}" "${MAX_JOBS:-}" "${CORES:-}"
    runtime_guix repl "$source/tests/system/runtime.scm"
    runtime_guix repl "$source/tests/system/firmware.scm" \
        "$source/tests/system/firmware-system.scm" "$records/firmware" "${MAX_JOBS:-}" "${CORES:-}"
    runtime_guix system build --no-grafts --save-provenance --derivation \
        "$records/firmware/recovery/config.scm" > "$records/firmware/recovered.drv"
    cmp "$records/firmware/expected.drv" "$records/firmware/recovered.drv"
    runtime_guix repl "$source/tests/system/channel-migration.scm" \
        "$source/tests/system/channel-system.scm" "$records/migration"
    for variant in original added-package; do
        runtime_guix system build --no-grafts --save-provenance --derivation \
            "$records/migration/$variant-provenance/configuration.scm" \
            > "$records/migration/$variant-recovered.drv"
        cmp "$records/migration/$variant.drv" "$records/migration/$variant-recovered.drv"
    done
    runtime_guix system build --no-grafts --save-provenance --derivation \
        "$records/migration/local-helpers-provenance/configuration-source/config.scm" \
        > "$records/migration/local-helpers-recovered.drv"
    cmp "$records/migration/local-helpers.drv" "$records/migration/local-helpers-recovered.drv"
    printf 'Saved declarations replayed in fresh Guix processes.\n'
    printf '\nRuntime checks passed with the recorded channel profile.\n'
) 2>&1 | tee "$records/check.log"
