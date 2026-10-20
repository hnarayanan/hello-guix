#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the candidate from its saved source, even if the working tree changes.
set -euo pipefail
if test "$#" -gt 1; then echo 'Usage: build_candidate.sh [catalogue-directory]' >&2; exit 1; fi
GUIX=$(command -v "${GUIX:-guix}")
PYTHON=$(command -v "${PYTHON:-python3}")
export GUIX PYTHON
case "$GUIX" in /*) ;; *) GUIX="$PWD/$GUIX" ;; esac
case "$PYTHON" in /*) ;; *) PYTHON="$PWD/$PYTHON" ;; esac
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p "${BUILD_DIR:-build}"
export BUILD_DIR=$(cd "${BUILD_DIR:-build}" && pwd -P)
catalogue=${1:-$BUILD_DIR/catalogue}
source="$BUILD_DIR/source-record"
"$PYTHON" scripts/build_inputs.py record --directory "$source"
bash "$source/scripts/build_image.sh"
"$PYTHON" "$source/scripts/asahi_payload.py" stage \
    --package "$BUILD_DIR/payload" --inputs "$source" --output "$catalogue"
