<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Making the system your own

The installer leaves your configuration at `/etc/config.scm`. Open it and
you’ll find familiar things: your machine’s name, user accounts, desktop
environment and services. You can change these through Guix’s usual
configuration system.

We’ll begin with one small change, then look at the parts Hello Guix adds
for Apple hardware. We’ll also walk through updating the system and
returning to a saved generation. The Guix manual’s
[Using the Configuration System][using-configuration] is the place to
explore further. Here, we’ll focus on preserving the Mac’s hardware support
as you make the system your own.

## A first change

To try a small change, open `/etc/config.scm` in a text editor with
administrator privileges. Find the existing `host-name` field and change
its value, perhaps to:

```scheme
(host-name "orchard")
```

Leave the rest of the file unchanged. Save it, then run:

```sh
sudo guix system reconfigure /etc/config.scm
```

After the command finishes successfully, check the name:

```sh
hostname
```

If you chose `orchard`, it should print:

```text
orchard
```

`guix system reconfigure` builds and applies the system your configuration
describes. You use it after changing packages or services too. The manual’s
[System Configuration][system-configuration] section covers those choices in
detail.

<a id="system-generation"></a>

Each successful reconfiguration also records a new
[*system generation*][using-configuration]. Keeping earlier generations
lets you return to them.

## What Hello Guix adds

### Hardware support

As you make the system your own, you may replace GNOME, add services or
choose a console system. The Mac’s hardware support needs to remain part
of that description. We keep it there by wrapping the configuration in
`with-asahi-hardware`:

```scheme
(with-asahi-hardware
  (operating-system
    ;; Your accounts, locale, packages, services, bootloader and filesystems.
    ...))
```

This abbreviated example shows the shape of the declaration. The function
comes from `(hello-guix system hardware)`. It adds the Asahi kernel,
firmware services, graphics modules and audio integration to your choices.
The result is another `operating-system` value, which Guix builds in the
usual way.

This lets you keep describing the system in ordinary Guix terms. A browser
uses the usual audio interface, with Asahi’s services providing the support
for the Mac’s speakers.

For Wi-Fi, you can choose NetworkManager or ConnMan. `with-asahi-hardware`
configures it to use iwd. The function makes these hardware-specific
choices part of your system description.

Custom kernels or hardware services may need further integration and
testing before Hello Guix can support them.

### Audio and Guix Home

Some services run for the whole computer, while others run under your
account. Sound needs both. System services handle the hardware and protect
the Mac’s speakers from overheating. Software running under your account
mixes and routes sound from applications.

Guix lets you describe an account’s software and settings through
[Guix Home][guix-home]. Like your system configuration, a Home configuration
is written in Scheme. Guix can [include it in the system
declaration][home-in-system], so `guix system reconfigure` manages both.

The [Asahi Guix Channel][asahi-channel] supplies audio services for both
the system and Guix Home, with the settings Apple hardware needs.

Hello Guix’s `with-asahi-hardware` applies these services to your
configuration. It sets up system audio and adds Home audio for the ordinary
accounts in your system declaration. For each account without a Home
configuration declared there, it creates a small one for audio. If one is
already declared, it adapts the audio services while retaining your other
choices.

With either arrangement, `guix system reconfigure` manages both your system
and Home. If you later choose to manage Home separately with
`guix home reconfigure`, carry over the audio setup in two steps. The
examples below abbreviate your existing declarations with `...`.

1. Tell `with-asahi-hardware` to leave your account’s Home configuration to
   you. Set `#:home-users` to a list of the other ordinary account names
   that should keep the automatic audio setup, each listed once. Use `'()`
   if there are none:

   ```scheme
   (with-asahi-hardware
     (operating-system
       ...)
     #:home-users '())
   ```

   If you have also declared your account’s Home configuration within the
   system configuration, remove that declaration.

2. Wrap your separate Home declaration in Hello Guix’s
   `with-asahi-home-audio` function. Import it from
   `(hello-guix system audio)`:

   ```scheme
   (use-modules (gnu home) (hello-guix system audio))

   (with-asahi-home-audio
     (home-environment
       ...))
   ```

   This keeps the Asahi audio settings in your session while you configure
   the rest through Guix Home.

After making these changes, reconfigure the system. Then apply your
separate Home configuration, using `-L` on the command line to tell Guix
where to find the Hello Guix modules:

```sh
guix home -L /etc/hello-guix/modules reconfigure home.scm
```

Replace `home.scm` with your Home configuration file. If you keep the
modules elsewhere, use that directory’s path after `-L`. Log out and back
in to check sound. The Guix Home manual covers the rest of that workflow.

## How updates work

So far, we’ve changed the configuration while keeping its software
versions. Updating the software also means keeping the Mac’s boot files
compatible with it. We’ll look at both parts before making any changes.

### Locking channel versions

Guix is a rolling release distribution. Its [channels][channels] normally
follow Git branches, so `guix pull` fetches newer versions of Guix and its
package definitions. `guix system reconfigure` then builds your system
using those definitions.

As a new project, we want to give you a dependable starting point. Hello
Guix 0.1 therefore uses a tested snapshot of Guix and Asahi Guix. The
installer records their exact revisions in the `(commit "…")` fields of
`channels.scm`. Your system’s Guix service makes these the defaults for
`guix pull`, unless you supply your own channel file. With these defaults,
`guix pull` keeps the pinned revisions. It does not advance them or rewrite
the file.

This gives rolling Guix something of the predictability of a fixed release.
You decide when to move beyond the snapshot. Keeping it also means waiting
for newer software and fixes until you update the pins.

### The files that boot Guix

A [system generation](#system-generation) records the software Guix will
run. That system relies on lower-level boot components to start. Some of
that state lives outside the generation, so switching generations alone
cannot restore the whole boot environment.

Hello Guix builds each generation’s *boot bundle* with the
[Asahi Guix Channel’s][asahi-channel] builders. [m1n1][m1n1] and
[U-Boot][u-boot] prepare the Mac to start Guix, using *device trees* that
describe its hardware. These come from the generation’s kernel so the
startup files match the system being booted.

The generation saves this bundle in `asahi-boot/`, beside its `kernel/`
directory. The selected generation’s bundle is therefore available at
`/var/guix/profiles/system/asahi-boot/`. To start, the Mac reads a separate
copy at `/boot/efi/m1n1/boot.bin`. In 0.1, reconfiguration does not update that
copy. The steps below install it explicitly, so the Mac uses the bundle
for the generation you select, including on rollback. I plan to automate
this step.

One thing to keep in mind is that Apple’s firmware and boot policy sit
outside Guix’s control. Boot policy sets the rules for allowing a system
to start. A macOS update can change this state, and a Guix rollback cannot
undo it. For future versions of Hello Guix, I need to think carefully about
how to detect these changes and respond to them gracefully. For now, the
[boot-chain diagram](architecture.md#from-apples-boot-environment-to-linux)
shows how these parts fit together.

## Update your system

Hello Guix uses the versions of Guix and Asahi Guix pinned in
`channels.scm`. To update, first save your working system, then prepare a
separate configuration with newer pins. Build it, boot into it and check
that it works on your Mac. Once you are satisfied, use that tested
configuration and its pins as your new starting point. The steps below
walk through this process.

For each procedure below, keep its commands in the same terminal and wait
for each command to finish successfully before continuing.

### Save the working system

Start from a working system you have rebooted into. Save its Guix
generation and active boot bundle before updating, so you can return to
them if needed.

First, create a folder for the recovery files and display its path.
The variable `recovery` holds that path for the commands below:

```sh
recovery=$(mktemp -d "$HOME/guix-recovery-XXXXXX")
printf 'Recovery files: %s\n' "$recovery"
```

Record the system you booted into and the list of available generations:

```sh
readlink -f /run/booted-system > "$recovery/system.txt"
guix system list-generations > "$recovery/generations.txt"
```

Record the EFI partition’s identity. This lets you find the same partition
from macOS if you need to restore the boot bundle:

```sh
findmnt -n -o SOURCE,PARTUUID /boot/efi > "$recovery/efi.txt"
```

Finally, copy the active boot bundle into the recovery folder. The read
needs root access, but your shell handles `>`, so the copy belongs to you:

```sh
sudo cat /boot/efi/m1n1/boot.bin > "$recovery/boot.bin"
```

Copy the recovery folder to a USB stick readable from both Guix and macOS,
or another place you can access from macOS.

In `generations.txt`, find the entry whose “canonical file name” matches
the path in `system.txt`. Keep that generation until you have tested the
update. The bundle installer also keeps `boot.bin.old`, but that holds only
the previous bundle and will change with later updates.

Keep your usual backups too. System generations do not back up your
personal files.

### Prepare the new configuration

Your configuration consists of three items, initially saved under `/etc`:

- `config.scm` describes your choices.
- `channels.scm` records the Guix and Asahi Guix versions used to build them.
- `hello-guix/` contains the hardware adapter and its licences.

Choose a name for your new working folder. This example uses
`~/guix-system`. If it already exists, choose another name:

```sh
configuration="$HOME/guix-system"
mkdir "$configuration"
```

For your first update, copy the three items from `/etc` and enter the new
folder. For later updates, copy them from your current configuration folder
instead:

```sh
cp -R /etc/config.scm /etc/channels.scm /etc/hello-guix "$configuration/"
cd "$configuration"
```

The originals stay under `/etc`. The generated `config.scm` finds the other
two beside itself, so keep that arrangement. Keep private files out of
`hello-guix/`, since Guix saves its contents in the store, where other users
can read them.

Make another copy of the channel file to follow newer revisions:

```sh
cp channels.scm channels-unpinned.scm
```

Open `channels-unpinned.scm` in your editor and remove each channel’s
`(commit "…")` field. Keep its branch and introduction, including the
commit inside `make-channel-introduction`, which establishes trust.

Use that file to prepare a newer Guix and
[record its exact channel revisions][replicating-guix] in `channels.scm`.
This can take a while: Guix fetches the channels and builds a Guix from
them. The command preserves the introductions without changing your usual
Guix profile. It writes to a new file first, so a failed fetch leaves your
recorded pins unchanged:

```sh
guix time-machine -C channels-unpinned.scm -- describe -f channels \
  > channels-new.scm &&
  mv channels-new.scm channels.scm
```

Build and test these Guix and Asahi Guix versions together, because the
Asahi channel depends on Guix’s packages and build tools.

The revisions tested for 0.1 are in
[`packaging/guix/channels.scm`](../packaging/guix/channels.scm). Other
combinations need their own testing.

### Build, apply and check

Stay in your working folder and use the revisions now recorded in
`channels.scm`. The variable `profile` holds the location of that Guix, so
the build and reconfiguration use the same version without fetching the
channels again under `sudo`:

```sh
profile=$(guix time-machine -C channels.scm)
```

Build the system without applying it. The `--save-provenance` flag records
its configuration and channel revisions, as `reconfigure` does by default.
This makes both commands build the same system, so reconfiguration can
reuse it. The build can use the Asahi Guix Channel’s
[pre-built packages][substitutes], which your configuration already trusts:

```sh
"$profile/bin/guix" system build --save-provenance config.scm
```

When the build succeeds, apply the configuration using that same Guix:

```sh
sudo "$profile/bin/guix" system reconfigure config.scm
```

Next, install the matching boot bundle. The path after `install` selects
the generation whose bundle to use. Here, `/var/guix/profiles/system` points
to the generation you just applied.

This command checks the EFI partition’s identity, saves the previous
bundle as `m1n1/boot.bin.old`, and replaces `m1n1/boot.bin`. If the bundle is
already installed, both files stay unchanged:

```sh
sudo /var/guix/profiles/system/asahi-boot/install /var/guix/profiles/system
```

The first replacement can change the file even with the same kernel,
because the installation bundle contains additional device trees.

After the commands succeed, reboot and check sound, networking, Bluetooth
and suspend before deleting an older generation you may still need.

Once you are satisfied, use this folder’s `config.scm` and `channels.scm`
for future changes. Reconfiguration does not replace the editable files
you copied from `/etc`, so those still contain your earlier settings and
pins.

If Guix starts and you want to return to your saved system, follow the
next section. If startup fails before the GRUB boot menu appears, first
follow the
[boot repair steps in macOS](recovery.md#restore-the-early-boot-bundle).

## Return to an earlier generation

These steps run inside Guix. They select your saved system generation for
future boots and install its matching boot bundle.

First, set `recovery` to the folder you saved before the update. Replace
the example path with its actual location:

```sh
recovery="/path/to/your/guix-recovery-folder"
```

In that folder’s `generations.txt`, find the entry whose “canonical file
name” matches the path in `system.txt`. Check that its generation number is
still in the list of available generations:

```sh
guix system list-generations
```

Select that generation for future boots, replacing `GENERATION` with its
number. `command -v` selects the Guix in your shell, which may differ from
the one `sudo` would find:

```sh
sudo "$(command -v guix)" system switch-generation GENERATION
```

Check that the selected system matches the one you saved. Continue only
if this prints “Saved system selected.”:

```sh
test "$(readlink -f /var/guix/profiles/system)" = \
  "$(cat "$recovery/system.txt")" &&
  printf 'Saved system selected.\n'
```

Install the selected generation’s matching boot bundle, so the Mac uses
both together on its next start:

```sh
sudo /var/guix/profiles/system/asahi-boot/install /var/guix/profiles/system
```

Once the bundle installation succeeds, reboot.

The saved generation also keeps its configuration files. After reboot,
find them at `/run/current-system/configuration-source`. Copy the whole
directory to a new working folder before making further changes. This
brings your editable configuration back to the same version as the system.
Guix’s manual describes the other [system generation
commands][system-commands].

[using-configuration]:
  https://guix.gnu.org/manual/en/html_node/Using-the-Configuration-System.html
[system-configuration]:
  https://guix.gnu.org/manual/en/html_node/System-Configuration.html
[asahi-channel]: https://codeberg.org/asahi-guix/channel
[m1n1]: https://asahilinux.org/docs/sw/m1n1-user-guide/
[u-boot]: https://docs.u-boot.org/en/latest/board/apple/m1.html
[guix-home]:
  https://guix.gnu.org/manual/en/html_node/Home-Configuration.html
[home-in-system]:
  https://guix.gnu.org/manual/en/html_node/Guix-Services.html#guix_002dhome_002dservice_002dtype
[channels]: https://guix.gnu.org/manual/en/html_node/Channels.html
[replicating-guix]:
  https://guix.gnu.org/manual/en/html_node/Replicating-Guix.html
[substitutes]: https://guix.gnu.org/manual/en/html_node/Substitutes.html
[system-commands]:
  https://guix.gnu.org/manual/en/html_node/Invoking-guix-system.html
