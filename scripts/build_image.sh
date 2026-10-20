#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and check an image before selecting it as the current result.
set -euo pipefail
case "${1:-}" in
    '') plan=() ;;
    --dry-run) plan=(--dry-run) ;;
    *) echo 'Usage: build_image.sh [--dry-run]' >&2; exit 1 ;;
esac
if test "$#" -gt 1; then echo 'Use at most one option.' >&2; exit 1; fi

guix_command=$(command -v "${GUIX:-guix}")
case "$guix_command" in /*) ;; *) guix_command="$PWD/$guix_command" ;; esac
python_command=$(command -v "${PYTHON:-python3}")
case "$python_command" in /*) ;; *) python_command="$PWD/$python_command" ;; esac
cd "$(dirname "${BASH_SOURCE[0]}")/.."
build_dir=${BUILD_DIR:-build}
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd -P)
build_options=()
if test -n "${MAX_JOBS:-}"; then build_options+=(--max-jobs="$MAX_JOBS"); fi
if test -n "${CORES:-}"; then build_options+=(--cores="$CORES"); fi

# Select the pinned Guix once for both builds.
profile=$("$guix_command" time-machine --channels=packaging/guix/channels.scm ${build_options[@]+"${build_options[@]}"})
attempt=$(mktemp -d "$build_dir/.build-XXXXXX")
trap 'rm -rf "$attempt"' EXIT
"$profile/bin/guix" build ${build_options[@]+"${build_options[@]}"} --root="$attempt/source" \
    --file=packaging/guix/packages/installer-source.scm
"$guix_command" repl scripts/build-result.scm "$attempt/source" "$build_dir/installer-source"

if test "${#plan[@]}" -eq 0; then plan=(--root="$attempt/result"); fi
"$profile/bin/guix" build -L "$build_dir/installer-source" -L src \
    --system=aarch64-linux ${build_options[@]+"${build_options[@]}"} "${plan[@]}" \
    --file=packaging/guix/packages/setup-install.scm
if test "${1:-}" != --dry-run; then
    "$python_command" scripts/asahi_payload.py check --package "$attempt/result"
    "$guix_command" repl scripts/build-result.scm "$attempt/result" "$build_dir/payload"
fi
