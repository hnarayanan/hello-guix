<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Installing Guix on your Mac

[Hello Guix](https://harishnarayanan.org/projects/hello-guix) installs
[GNU Guix](https://guix.gnu.org/) alongside
[macOS](https://www.apple.com/macos/). You choose how much space to give it,
and macOS remains available as a separate startup choice.

You’ll begin in macOS to prepare that space and allow the Mac to boot the
new system. Then Guix’s installer will ask you questions about things like
your Wi-Fi connection, user accounts and choice of desktop environment,
and use your answers to complete the installation.

## Before starting

Back up your data before starting: installation changes your Mac’s storage
and boot setup. Use a macOS administrator account, and make sure you have
internet access for both preparation and the Guix installation.

The installer requires **macOS 26 or later on Apple Silicon** because its
bundled libffi library is built for that version. The
[build guide](development.md#assemble-on-macos) explains this choice.
Hardware testing has used one **MacBook Air (M1, 2020)**. Other models
remain untested. Read [what has been tested](#what-has-been-tested) for the
scope and known limitations.

Allow roughly **3 GB of free space in macOS** for preparation, in addition
to the space you intend to give Guix. This holds both the 1 GB download and
its 1.1 GB of extracted contents at the same time, with room for the
installer’s working files and filesystem overhead. The launcher checks that
there is enough space before it downloads or extracts anything.

Guix’s own space needs depend on what you install. Leave room for your
desktop environment and personal files, as well as the older system
versions Guix keeps so you can return to them. The installer accepts a
minimum of 8 GiB for the main Guix partition, but
[GNOME](https://www.gnome.org/) and future configurations can need
substantially more.

## The installation flow

### 1. Make room for Guix

On the Mac where you want to install Guix, choose how you’d like to begin.
You can save the
[installer script](https://harishnarayanan.org/projects/hello-guix/install.sh)
as `install.sh` in your Downloads folder, read it in your text editor, then
open Terminal and run:

```sh
sh "$HOME/Downloads/install.sh"
```

Or download and run it directly from Terminal:

```sh
curl -fsSL --proto '=https' \
  https://harishnarayanan.org/projects/hello-guix/install.sh | sh
```

Both routes download the same installer and check its SHA-256 checksum and
contents. Hello Guix uses
[Asahi’s installer](https://github.com/AsahiLinux/asahi-installer) for this
first stage: it prepares the storage and boot files, and collects the
firmware your Mac needs. Enter your macOS administrator password when asked.

For example, suppose macOS occupies all the available space on your drive.
The following excerpts show the main decisions, using the sizes from our
256 GB test MacBook Air. The installer calculates the limits for your Mac.

First, choose `r` to make room:

```text
Choose what to do:
  r: Resize an existing partition to make space for a new OS
  q: Quit without doing anything
» Action (r): r
```

If there is more than one partition it can resize, the installer asks you
to choose one. Select your main macOS partition. At **New size**, you are
choosing how much space **macOS keeps**. You can enter a size such as
`100GB`, a percentage such as `50%` of that partition’s current size, or
`min` for the smallest size the installer allows.

In our test, `min` left about 94 GB for macOS and freed about 151 GB. Your
minimum depends on what is already on your Mac; you can choose a larger
size to leave more room for future macOS use. Review the amounts before
entering `y` to start the resize:

```text
Minimum new size: 94.06 GB (38.38%)
» New size (50%): min
Resizing will free up 151.05 GB of space.
» Continue? (y/N): y
```

Wait for **Resize complete**, then press Enter to return to the menu.
Choose `f` to install into the space you have just freed. If your drive
already has enough unallocated space, you can begin here: this means space
outside any partition, rather than unused space within macOS.

```text
Choose what to do:
  f: Install an OS into free space
  q: Quit without doing anything
» Action (f): f

Choose an OS to install:
  1: Guix System (Hello Guix 0.1)
» OS: 1
```

If several free areas are large enough, the installer asks which to use.
It then asks how much of that area to give the new installation. This time,
the size describes **what Guix receives**. Enter a size or percentage to
leave some space unallocated, or `max` to use the whole area. Finally,
choose the name you will see in Apple’s Startup Options:

```text
» New OS size (max): max
» OS name (Guix System): Hello Guix
```

This allocation includes an Apple bootstrap volume of about 2.5 GB and a
**3 GiB EFI partition** (about 3.2 GB) for boot files. The rest becomes the
main Guix partition. Both boot areas remain part of the installation after
setup finishes.

Here is how the space was divided in our example. Sizes are rounded;
Apple’s existing boot and recovery partitions remain in place.

```text
256 GB test drive: about 251 GB reported
├──   6 GB: existing Apple boot and recovery partitions
└── 245 GB: macOS partition before resizing
    ├──  94 GB: remains with macOS
    └── 151 GB: new Guix installation
        ├──   6 GB: boot files
        └── 145 GB: Guix, applications and personal files
```

We installed GNOME, Bluetooth, OpenSSH and CUPS within that Guix allocation.
The 145 GB is the space available to the system, not the amount consumed by
the installation. The 3 GB needed for preparation comes from the macOS
allocation.

### 2. Allow the Mac to boot it

When preparation finishes, follow the installer’s shutdown and power-button
instructions to enter Apple’s Startup Options. Select the new installation,
using the name you chose earlier.

> **Placeholder: Apple’s Startup Options.** Show macOS and the new Guix
> installation, with the Guix entry selected. Caption: “Select the name you
> gave your new installation.”

The Mac now enters Apple Recovery to authorise the new system. If it asks
you to **Select a volume to recover**, choose your usual macOS volume and
sign in when prompted.

A Terminal window then opens to complete preparation. It asks twice for
your macOS administrator account and password, and explains the changes
to boot security. These apply only to the new installation. Your existing
macOS installation keeps its own security settings.

> **Placeholder: boot authorisation.** Show the Terminal window explaining
> the security changes, with personal details removed. Caption: “Authorise
> the new Guix installation using your macOS administrator account.”

When the Terminal window reports **Installation complete**, press Enter
to reboot into Guix’s installer.

### 3. Choose what to install

Guix asks for your language, keyboard layout, timezone and accounts, then
offers desktop environments and services. Bluetooth is an optional service
in the networking choices.

> **Placeholder: Guix’s desktop environment choices.** Show the selection
> screen with GNOME selected and the other choices visible. Caption:
> “Choose the desktop environment you would like to use.”

Together, your answers describe your new system. Guix will install it in
the space you set aside earlier in macOS.

Review the generated configuration before proceeding. Guix then downloads
or builds the software for your chosen system. A desktop environment such
as GNOME needs many packages, so this step can take a while. The time
depends on your choices, connection speed and whether packages need to be
built locally; watch the download and build messages for progress.

The completion page appears after installation and cleanup have finished.
Press **Reboot** to start your new system. The temporary setup image is
removed, while the boot partitions remain in use.

## Your first login

Log in with the account you created. Check that you can reach a website,
and, if you chose a desktop environment, try its sound, brightness and
network controls. The [known limitations](#what-has-been-tested) below may
help if something behaves unexpectedly.

Your choices are saved in `/etc/config.scm`. The installer also saves
`/etc/channels.scm`, which records the versions of Guix and its additional
package definitions used for the build. When you’re ready to change
something, continue with [making the system your own](configuration.md).
Read [how updates work](configuration.md#how-updates-work) before changing
those versions.

## What has been tested

On a MacBook Air (M1, 2020), Hello Guix installs alongside macOS and boots
into GNOME on Wayland. Installation works with existing free space or by
shrinking macOS, either to a chosen size or to the minimum the installer
offers. Other Mac models remain untested.

Wi-Fi and internet access, built-in speakers, Bluetooth pairing and audio
playback, keyboard backlight, screen brightness and volume controls work.
OpenSSH works after reboot. Rebuilding the saved configuration produces
the same installed system, and removing and restoring a desktop
environment has been verified.

The documented
[update and rollback procedure](configuration.md#update-your-system)
has also been checked on this Mac. These findings apply to the software
versions tested; other channel combinations remain unverified.

There are a few limitations to be aware of:

- **Printing remains unverified.** The print service starts, but adding a
  printer through GNOME failed in our checks.
- **GNOME’s Secure Shell panel does not reflect the working SSH service.**
  If you selected OpenSSH during installation, you can still connect over
  SSH even if the panel shows it as off.
- **Wi-Fi scanning may need a second attempt.** This happened once across
  at least a dozen installation runs. If the first scan returns no networks,
  try **Scan** again.
- **A Broadcom roaming message can appear across a text login prompt.**
  Login and internet access still worked when it appeared. Wi-Fi roaming
  remains unverified.
- **Suspend and network reliability need more testing.** Short suspend and
  resume checks pass, with sound and networking working after wake. An
  unexplained failure to wake required a full power-off, and brief Wi-Fi
  disconnects during normal use have recovered automatically. Overnight
  battery behaviour remains unverified.

## If something stops

### Return to macOS

You can return to macOS if the installation stops. Shut the Mac down fully,
then press and hold the power button until Startup Options appears. Select
**Macintosh HD**, or the name of your usual macOS startup disk, to return to
your desktop. This leaves the Guix partitions in place; it simply starts
macOS. If you want to keep logs from Guix’s installer, follow the
[steps below](#find-and-save-the-logs) before rebooting.

### Retry the installation

If Apple’s authorisation step did not finish, follow the instructions shown
by Asahi’s installer. If asked to resume, run the same installer command
from macOS and continue with the existing installation rather than creating
another one.

The launcher keeps its download in `~/Library/Caches/Hello Guix/` on macOS
and checks it before reusing it. You can remove this cache once installation
is complete.

If Guix reports a download or build failure, note the error before choosing
**Resume**. Guix’s installer allows a retry only before it has created a
system generation (a saved system build). Some packages may need downloading
again after a failed attempt; the packages shipped in the installer remain
reusable.

If Guix refuses to resume, keep its message and the original error for a
problem report. The partial installation needs inspection before another
attempt.

If installation stopped before completion and the next boot stops at a GRUB
error instead of reaching setup or Guix, see [restoring the installer’s boot
loader](recovery.md#restore-the-installers-boot-loader).

### Find and save the logs

On macOS, each attempt saves a log in `~/Library/Logs/Hello Guix/attempt-*`.
Its working files are in
`~/Library/Application Support/Hello Guix/attempt-*/`. That folder includes
a link to the log named `installer.log` and a copy of this guide. Once
installation is complete and you no longer need these records, you may
delete that attempt’s folder and log.

Guix’s installer runs in memory, so its logs are lost on reboot. To save
them, open a maintenance shell with Ctrl+Alt+F3 (Fn+Control+Option+F3 on the
Mac’s keyboard) and press Enter at the login prompt. This is the setup
environment’s root shell.

Copy `/tmp/installer.*.log` and any `installer-backtrace` dump to a mounted
USB stick, then unmount the stick before rebooting. If you cannot save the
files, take a photo of the error. When ready to leave the shell, run `sync`,
then `reboot` or `halt`.

When [reporting a problem](https://github.com/hnarayanan/hello-guix/issues),
include the release version, Mac model, stage and exact error. Review logs
before sharing them, as they can contain personal information.
