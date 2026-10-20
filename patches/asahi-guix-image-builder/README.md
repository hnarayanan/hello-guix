<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Asahi Guix image builder

Asahi Guix’s build system takes a Guix system description, builds a disk
image and packages its contents for Asahi’s macOS installer. It also
creates the initial catalogue description. Normally, the described system
occupies the image’s root partition.

Hello Guix needs a temporary system that can run while Guix installs the
system you choose. Our image therefore boots the installer into RAM,
leaving the destination partition available for that new system.

`0001-accept-image-builder.patch` adds an optional `image-builder` argument
so we can supply this layout. Our [setup recipe][setup] passes in the
[RAM image builder][ram-image], and upstream packages the result as usual.
Calls that omit the argument keep the existing behaviour.

[installer-source.scm][source] applies the patch to a verified copy of the
pinned channel’s source. When updating the channel, remove the patch if
upstream provides this extension. Otherwise, check that it still applies
and that the resulting image works. The [development guide][development]
covers building and testing it.

[setup]: ../../packaging/guix/packages/setup-install.scm
[ram-image]: ../../packaging/guix/images/ram-image.scm
[source]: ../../packaging/guix/packages/installer-source.scm
[development]: ../../docs/development.md
