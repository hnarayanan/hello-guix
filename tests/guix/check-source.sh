#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# Build fictional configurations and recover them using only their saved source.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
plan_only=false
desktop=false
for option in "$@"; do
    case "$option" in
        --dry-run) plan_only=true ;;
        --desktop) desktop=true ;;
        *) echo 'Usage: check-source.sh [--desktop] [--dry-run]' >&2; exit 1 ;;
    esac
done
start_check source-check
(
build_runtime
clean_guix describe -f channels > "$records/channels.scm"
clean_guix repl tests/runtime.scm packaging/guix/channels.scm "$records/channels.scm"

variants=(console)
grafts=(--no-grafts)
if "$desktop"; then
    variants+=(gnome)
    grafts=() # Complete desktop builds retain normal grafts.
fi
for variant in "${variants[@]}"; do
    directory="$records/$variant"
    bundle="$directory/original"
    mkdir -p "$bundle/hello-guix/modules/hello-guix/system"
    cp "$source/packaging/guix/channels.scm" "$bundle/channels.scm"
    cp "$source/COPYING" "$bundle/hello-guix/COPYING"
    cp -R "$source/LICENSES" "$bundle/hello-guix/LICENSES"
    cp "$source/src/hello-guix/system/"*.scm "$bundle/hello-guix/modules/hello-guix/system/"
    case "$variant" in
        console) services='(cons (service network-manager-service-type) %base-services)' ;;
        gnome) services='(cons (service gnome-desktop-service-type) %desktop-services)' ;;
    esac
    printf '(use-modules (gnu) (gnu services desktop) (gnu services networking))\n(define test-services %s)\n' \
        "$services" > "$bundle/config.scm"
    cat "$source/tests/source-system.scm" >> "$bundle/config.scm"
    printf 'private neighbouring file\n' > "$bundle/DO-NOT-COPY"
    cd "$directory" # Do not let the checkout rescue imports.
    clean_guix system build ${grafts[@]+"${grafts[@]}"} --save-provenance --derivation \
        "$bundle/config.scm" > original.drv
    mv "$bundle" relocated
    bundle="$directory/relocated"
    clean_guix system build ${grafts[@]+"${grafts[@]}"} --save-provenance --derivation \
        "$bundle/config.scm" > relocated.drv
    cmp original.drv relocated.drv

    cp -R "$bundle" incomplete
    rm incomplete/hello-guix/modules/hello-guix/system/hardware.scm
    if clean_guix system build --no-grafts --derivation incomplete/config.scm > missing-helper.log 2>&1; then
        echo 'An incomplete bundle unexpectedly evaluated.' >&2
        exit 1
    fi
    grep -Fq 'no code for module (hello-guix system hardware)' missing-helper.log
    if "$plan_only"; then
        clean_guix build --dry-run "$(cat relocated.drv)"
        continue
    fi

    clean_guix build ${build_options[@]+"${build_options[@]}"} --root="$directory/system" "$(cat relocated.drv)"
    saved="$directory/system/configuration-source"
    clean_guix gc --references "$(readlink -e system)" > references.txt
    grep -Fxq "$(readlink -e "$saved")" references.txt
    test ! -e "$saved/DO-NOT-COPY"
    rm "$bundle/DO-NOT-COPY"
    diff -r "$bundle" "$saved"
    clean_guix repl "$source/tests/runtime.scm" "$saved/channels.scm" system/channels.scm

    cp -R -L "$saved" recovered
    chmod -R u+w recovered
    printf '\n;; Later working-copy edit.\n' >> "$bundle/config.scm"
    mv "$bundle" working-copy-unavailable
    clean_guix system build ${grafts[@]+"${grafts[@]}"} --save-provenance --derivation \
        recovered/config.scm > recovered.drv
    cmp original.drv recovered.drv
    diff -r recovered "$saved"
    clean_guix system build ${grafts[@]+"${grafts[@]}"} --save-provenance --derivation \
        working-copy-unavailable/config.scm > edited.drv
    if cmp -s original.drv edited.drv; then
        echo 'A source edit did not change the system derivation.' >&2
        exit 1
    fi
    clean_guix gc --requisites "$(readlink -e system)" > closure.txt
    grep -E -- '-home$' closure.txt > audio-home.txt
    test "$(wc -l < audio-home.txt)" -eq 1
    printf '\n%s: source relocation, isolation and generation recovery passed.\n' "$variant"
done

if "$desktop" && ! "$plan_only"; then
    for component in kernel initrd; do
        test "$(readlink -e "$records/console/system/$component")" = \
             "$(readlink -e "$records/gnome/system/$component")"
    done
    cmp "$records/console/audio-home.txt" "$records/gnome/audio-home.txt"
    profile="$records/gnome/system/profile"
    for app in gnome-shell orca rygel; do test -x "$profile/bin/$app"; done
    test -s "$profile/share/wayland-sessions/gnome.desktop"
    test -s "$profile/share/glib-2.0/schemas/gschemas.compiled"
    test -s "$profile/share/glib-2.0/schemas/org.gnome.system.locale.gschema.xml"
    echo 'Complete GNOME and shared kernel, initrd and audio Home checked.'
fi
if "$plan_only"; then echo 'Build plan only; full build and recovery remain.'; fi
echo 'No system was activated. All configurations have fictional disks.'
) 2>&1 | tee "$records/check.log"
