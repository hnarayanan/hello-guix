#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a reviewed system with its selected channel profile and retain the result.
set -euo pipefail

plan=false
if test "${1:-}" = --plan; then plan=true; shift; fi
if test "$#" != 1; then
    echo 'Usage: build.sh [--plan] /absolute/config.scm' >&2; exit 1
fi
configuration=$1
case "$configuration" in
    /*) ;;
    *) echo 'configuration= requires an absolute path.' >&2; exit 1 ;;
esac
if ! test -f "$configuration" || ! test -r "$configuration"; then
    printf 'Configuration is not a readable file: %s\n' "$configuration" >&2; exit 1
fi
build_dir=${BUILD_DIR:-build}
guix_command=${GUIX:-guix}
build_options=()
if test -n "${MAX_JOBS:-}"; then build_options+=(--max-jobs="$MAX_JOBS"); fi
if test -n "${CORES:-}"; then build_options+=(--cores="$CORES"); fi

if "$plan"; then
    printf 'Configuration: %s\nGuix: %s\nRecords: %s/system-build-*\n' \
        "$configuration" "$guix_command" "$build_dir"
    printf 'Jobs: %s\nCores: %s\n\n' "${MAX_JOBS:-Guix default}" "${CORES:-Guix default}"
    printf '%s\n' \
        'The build selects this complete channel profile, records its channels, then runs' \
        'guix system build with normal grafts and saved provenance. Its result is retained' \
        'as a garbage-collection root. Dependencies and downloads are resolved during build.'
    exit 0
fi

if test "$(uname -s)" != Linux || test "$(id -u)" = 0; then
    echo 'Build the system on Linux as an ordinary user, without sudo.' >&2; exit 1
fi
guix_command=$(command -v "$guix_command")
case "$guix_command" in /*) ;; *) guix_command="$PWD/$guix_command" ;; esac
umask 077
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd -P)
records=$(mktemp -d "$build_dir/system-build-XXXXXX")
trap 'status=$?; printf "%s\n" "$status" > "$records/status"; exit "$status"' EXIT
printf 'Records: %s\n' "$records"
(
    mkdir "$records/home"
    daemon=()
    if test -n "${GUIX_DAEMON_SOCKET:-}"; then
        daemon=(GUIX_DAEMON_SOCKET="$GUIX_DAEMON_SOCKET")
    fi
    run_guix() {
        env -i HOME="$records/home" PATH="$runtime_path" LC_ALL=C \
            ${daemon[@]+"${daemon[@]}"} "$guix_command" "$@"
    }
    runtime_path=$PATH
    # Resolve the complete profile before following the executable's links.
    # Later commands use its immutable store path, even if a user pulls meanwhile.
    run_guix repl "$(dirname "${BASH_SOURCE[0]}")/runtime-profile.scm" > "$records/profile"
    profile=$(cat "$records/profile")
    guix_command="$profile/bin/guix"
    runtime_path="$profile/bin"
    if ! test -x "$guix_command"; then
        printf 'Selected profile has no executable bin/guix: %s\n' "$profile" >&2; exit 1
    fi
    run_guix describe -f channels > "$records/channels.scm"
    printf '%s\n' "$configuration" > "$records/configuration"
    printf '%s\n' "${GUIX_DAEMON_SOCKET:-default local socket}" > "$records/daemon"
    arguments=(system build --save-provenance --root="$records/system"
               ${build_options[@]+"${build_options[@]}"} "$configuration")
    printf '%q ' "$guix_command" "${arguments[@]}" > "$records/command"
    printf '\n' >> "$records/command"
    run_guix "${arguments[@]}"
    test -d "$records/system"
    printf '\nSystem built and retained: %s/system\n' "$records"
) 2>&1 | tee "$records/build.log"
