#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Save the source, then build and check its installation image and catalogue.
set -euo pipefail
# Keep Python's bytecode cache out of the saved source and its checksums.
export PYTHONDONTWRITEBYTECODE=1
dry_run=false
if test "${1:-}" = --dry-run; then dry_run=true; shift; fi
if test "$#" -gt 1; then
    echo 'Usage: build_image.sh [--dry-run] [catalogue-directory]' >&2; exit 1
fi
case "${1:-}" in
    -*) echo 'Unknown image build option.' >&2; exit 1 ;;
esac

python_command=$(command -v "${PYTHON:-python3}")
case "$python_command" in /*) ;; *) python_command="$PWD/$python_command" ;; esac
if ! "$dry_run"; then
    guix_command=$(command -v "${GUIX:-guix}")
    case "$guix_command" in /*) ;; *) guix_command="$PWD/$guix_command" ;; esac
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
build_dir=${BUILD_DIR:-build}
case "$build_dir" in /*) ;; *) build_dir="$PWD/$build_dir" ;; esac
export BUILD_DIR="$build_dir"
catalogue=${1:-$build_dir/catalogue}
case "$catalogue" in /*) ;; *) catalogue="$PWD/$catalogue" ;; esac
source="$build_dir/source-record"

if "$dry_run"; then
    printf 'Source: %s\nChannels: %s\nSaved source: %s\nCatalogue: %s\n' \
        "$PWD" "$PWD/packaging/guix/channels.scm" "$source" "$catalogue"
    printf 'Jobs: %s\nCores: %s\n' "${MAX_JOBS:-Guix default}" "${CORES:-Guix default}"
    if test -e "$source" || test -L "$source"; then
        "$python_command" scripts/build_inputs.py verify --directory "$source"
    fi
    printf '%s\n' '' \
        'The build will save the source, prepare pinned Guix and patched installer modules,' \
        'then build or reuse the image, check it and collect its catalogue.' \
        'Exact dependencies and downloads are determined during the build.' \
        'No files were written and Guix was not invoked.'
    exit 0
fi

mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd -P)
export BUILD_DIR="$build_dir"
source="$build_dir/source-record"
if test "$PWD" != "$source"; then
    "$python_command" scripts/build_inputs.py record --directory "$source"
    # Run the saved build script too, so later edits cannot change this build.
    export GUIX="$guix_command" PYTHON="$python_command"
    exec "$BASH" "$source/scripts/build_image.sh" "$catalogue"
fi

build_options=()
if test -n "${MAX_JOBS:-}"; then build_options+=(--max-jobs="$MAX_JOBS"); fi
if test -n "${CORES:-}"; then build_options+=(--cores="$CORES"); fi

# Select the pinned Guix once for both builds.
profile=$("$guix_command" time-machine --channels=packaging/guix/channels.scm ${build_options[@]+"${build_options[@]}"})
attempt=$(mktemp -d "$build_dir/.build-XXXXXX")
trap 'rm -rf "$attempt"' EXIT
"$profile/bin/guix" build ${build_options[@]+"${build_options[@]}"} --root="$attempt/source" \
    --file=packaging/guix/packages/installer-source.scm
installer_source="$build_dir/installer-source"
"$guix_command" repl scripts/build-result.scm "$attempt/source" "$installer_source"

"$profile/bin/guix" build -L "$installer_source" -L src \
    --system=aarch64-linux ${build_options[@]+"${build_options[@]}"} --root="$attempt/result" \
    --file=packaging/guix/packages/setup-install.scm
"$python_command" scripts/asahi_payload.py check --package "$attempt/result"
"$python_command" scripts/asahi_payload.py stage \
    --package "$attempt/result" --inputs "$source" --output "$catalogue"
"$guix_command" repl scripts/build-result.scm "$attempt/result" "$build_dir/payload"
