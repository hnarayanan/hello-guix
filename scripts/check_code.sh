#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Run local checks by default, or a selected Guix check on Linux.
set -euo pipefail
case "${1:-python}" in
    python|hardware|source|desktop|configuration|installation-target|installation) ;;
    *) echo "Unknown code check: $1. Run make help." >&2; exit 1 ;;
esac
if test "$#" -gt 2; then echo 'Usage: check_code.sh [check] [source-archive]' >&2; exit 1; fi
PYTHON=$(command -v "${PYTHON:-python3}")
case "$PYTHON" in /*) ;; *) PYTHON="$PWD/$PYTHON" ;; esac
export PYTHON
if test "${1:-python}" != python; then
    GUIX=$(command -v "${GUIX:-guix}")
    case "$GUIX" in /*) ;; *) GUIX="$PWD/$GUIX" ;; esac
    export GUIX
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
case "${1:-python}" in
    python)
        build_dir=${BUILD_DIR:-build}
        "$PYTHON" scripts/prepare_asahi.py --directory "$build_dir/asahi-installer" \
            ${2:+--archive "$2"}
        export ASAHI_SOURCE=$(cd "$build_dir/asahi-installer" && pwd -P)
        "$PYTHON" -m unittest discover -s tests -v ;;
    hardware|source|configuration)
        bash "tests/guix/check-$1.sh" ;;
    desktop) bash tests/guix/check-source.sh --desktop ;;
    installation-target|installation) bash tests/guix/check-vm.sh "$1" ;;
esac
