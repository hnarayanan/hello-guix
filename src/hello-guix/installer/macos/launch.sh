#!/bin/bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Run this script from the assembled bundle, not from the source tree.
set -euo pipefail

action=${1:-install}
test "$#" -le 1
case "$action" in check|install) ;; *) echo 'Expected check or install' >&2; exit 1 ;; esac
bundle=$(cd -- "$(dirname -- "$0")" && pwd -P)
test "$(/usr/bin/uname -s)" = Darwin
if test "$(/usr/bin/uname -m)" != arm64; then
    /usr/bin/arch -arm64 /usr/bin/true || {
        echo 'This runtime requires an Apple Silicon Mac.' >&2
        exit 1
    }
    exec /usr/bin/arch -arm64 /bin/bash "$0" "$@"
fi
minimum_macos=$(/usr/bin/plutil -extract minimum_macos raw -o - \
    "$bundle/bundle.json")
macos_version=$(/usr/bin/sw_vers -productVersion)
if ! test "${macos_version%%.*}" -ge "$minimum_macos"; then
    printf 'This installer requires macOS %s or later.\n' "$minimum_macos" >&2
    exit 1
fi

# Start Python with a separate environment. Use the bundle's catalogue,
# Python modules, and libraries, regardless of the caller's settings.
runtime_python() {
    /usr/bin/env -i HOME="$HOME" TERM="${TERM:-xterm-256color}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        DYLD_LIBRARY_PATH="$bundle/runtime/Frameworks/Python.framework/Versions/3.13/lib" \
        DYLD_FRAMEWORK_PATH="$bundle/runtime/Frameworks" \
        SSL_CERT_FILE="$bundle/runtime/Frameworks/Python.framework/Versions/3.13/etc/openssl/cert.pem" \
        "$bundle/runtime/Frameworks/Python.framework/Versions/3.13/bin/python3.13" -E -s -B "$@"
}

runtime_python "$bundle/libexec/bundle.py" --bundle "$bundle"
runtime_python "$bundle/libexec/runtime_check.py" "$bundle"
if test "$action" = check; then
    exit 0
fi

if ! test -t 0 || ! test -t 1; then
    echo "Run the installation from an interactive Terminal window." >&2
    exit 1
fi
test "$(id -u)" != 0 || { echo 'Start this launcher as your macOS user.' >&2; exit 1; }
printf '\n%s\n%s\n%s\n' \
    'Hello Guix opens the Guix installer after reboot, including desktop and service choices.' \
    'Asahi will prepare real disk space and Apple boot authorisation.' \
    'Help and reports: https://github.com/hnarayanan/hello-guix/issues'

# Keep attempt files and logs after the temporary extraction is removed.
runs="$HOME/Library/Application Support/Hello Guix"
logs="$HOME/Library/Logs/Hello Guix"
umask 077
mkdir -p -- "$runs" "$logs"
attempt=$(mktemp -d "$runs/attempt-XXXXXX")
cp -R "$bundle/runtime/." "$attempt/"
cp "$bundle/catalogue/installer_data.json" "$attempt/installer_data.json"
cp "$bundle/bundle.json" "$attempt/bundle.json"
cp -R "$bundle/docs" "$attempt/docs"
log=$(mktemp "$logs/attempt-XXXXXX")
ln -s "$log" "$attempt/installer.log"
printf 'Installer log: %s\nWorking files: %s\n' "$log" "$attempt"
cd -- "$attempt"
# Asahi's install.sh selects the bundled libraries and Apple Silicon mode.
# Set REPO_BASE to use our local catalogue and ZIP file.
exec /usr/bin/sudo /usr/bin/env -i \
    HOME="$HOME" USER="$USER" TERM="${TERM:-xterm-256color}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    REPO_BASE="$bundle/catalogue" \
    DISTRO='Guix System' DISTRO_DOCS="$attempt/docs/installation.md" \
    /bin/sh ./install.sh
