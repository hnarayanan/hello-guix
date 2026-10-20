<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Asahi macOS installer

Asahi’s macOS installer already handles resizing, partition creation,
copying system files and device firmware, and the preparation needed for
Apple’s boot authorisation. It reads a catalogue describing the partitions
and files a distribution needs.

Hello Guix uses this machinery to place our temporary Guix installation
system on disk. Our addition supplies two details needed when it starts:

- An initial U-Boot setting points to this installation’s GRUB loader, so
  booting does not depend on scanning for a suitable loader.
- A record identifies the EFI and destination partitions and describes the
  empty target image. Guix uses it to find and check the space prepared in
  macOS before installing the chosen system.

[The patch][patch] calls [our helper][helper] after the system files have
been copied, when the catalogue contains `guix_boot: true`. The helper
writes both details to the new EFI partition. Other catalogue entries
keep the existing behaviour.

Run `make check code` from the project root to prepare the pinned Asahi
source and test this addition. The [development guide][development] covers
preparation and testing. The patch and helper use MIT, matching Asahi’s
installer, so they can be contributed upstream together.

[patch]: patches/0001-initialize-guix-boot-choice.patch
[helper]: overlay/guix_boot.py
[development]: ../../docs/development.md#local-work-on-macos-or-linux
