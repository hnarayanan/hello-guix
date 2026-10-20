<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# GNU Guix installer

Guix’s installer normally handles partitioning. Asahi has already assigned
the disk space before Guix starts, so we need a way to reuse the installer
with that choice made. These patches let us select its existing steps and
supply a configuration with the Mac’s storage and hardware settings. Guix
still handles the questions, account setup and installation. We also defer
its success page until our boot-file checks and unmounting are complete.

Each patch explains its reason, and [`series`](patches/series) sets their
order. [`installer-source.scm`](../../packaging/guix/packages/installer-source.scm)
checks the original source hashes, then applies the patches to a copy of
the Guix source selected in [`channels.scm`](../../packaging/guix/channels.scm).
This makes an upstream source change require deliberate review. When
updating Guix, check which patches it has made unnecessary and remove them.
The [development guide](../../docs/development.md) covers building and testing.
