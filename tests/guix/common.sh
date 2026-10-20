#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Run tests as an ordinary user, from a saved copy of the source.
set -euo pipefail

build_options=()
if test -n "${MAX_JOBS:-}"; then build_options+=(--max-jobs="$MAX_JOBS"); fi
if test -n "${CORES:-}"; then build_options+=(--cores="$CORES"); fi

test_project=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

start_check() {
    if test "$(uname -s)" != Linux || test "$(id -u)" = 0; then
        echo 'Run this check on Guix as an ordinary user, without sudo.' >&2
        exit 1
    fi
    guix_command=${GUIX:-$(command -v guix)}
    guix_command=$(command -v "$guix_command")
    # Resolve relative GUIX paths before the directory changes.
    case "$guix_command" in /*) ;; *) guix_command="$PWD/$guix_command" ;; esac
    PYTHON=$(command -v "${PYTHON:-python3}")
    case "$PYTHON" in /*) ;; *) PYTHON="$PWD/$PYTHON" ;; esac
    export PYTHON
    umask 077
    build_dir=${BUILD_DIR:-$test_project/build}
    mkdir -p "$build_dir"
    build_dir=$(cd "$build_dir" && pwd -P)
    records=$(mktemp -d "$build_dir/$1-XXXXXX")
    source="$records/source"
    trap finish_check EXIT
    "${PYTHON:-python3}" "$test_project/scripts/build_inputs.py" record --directory "$source"
    cd "$source"
    printf 'Records: %s\n' "$records"
    # Authenticate channels once. Use the resulting profile for all test commands.
    pinned_profile=$("$guix_command" time-machine \
        --channels="$source/packaging/guix/channels.scm" ${build_options[@]+"${build_options[@]}"})
}

finish_check() {
    local status=${1:-$?}
    if ! "${PYTHON:-python3}" "$test_project/scripts/build_inputs.py" verify --directory "$source"; then
        if test "$status" = 0; then status=1; fi
    fi
    printf '\nRecords: %s\n' "$records"
    exit "$status"
}

pinned_guix() {
    "$pinned_profile/bin/guix" "$@"
}

installer_source() {
    pinned_guix build ${build_options[@]+"${build_options[@]}"} --root="$records/installer-source" \
        --file=packaging/guix/packages/installer-source.scm
}

build_runtime() {
    pinned_guix build ${build_options[@]+"${build_options[@]}"} --root="$records/runtime" \
        --file=packaging/guix/packages/setup-tools.scm
    runtime=$(readlink -e "$records/runtime")
    mkdir "$records/home"
}

# Each invocation has no personal profile, Scheme paths or channel cache.
clean_guix() {
    env -i HOME="$records/home" PATH="$runtime/bin" LC_ALL=C \
        "$runtime/bin/guix" "$@"
}
