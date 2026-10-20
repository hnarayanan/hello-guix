<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Restoring boot files

To get back to macOS, shut down the Mac, then hold the power button until
Startup Options appears. Choose Macintosh HD, or your usual macOS startup
volume.

The repair depends on where startup stopped:

- If an interrupted installation leaves you at a GRUB error or a
  `grub rescue>` prompt, you may be able to
  [restore the installer’s boot loader](#restore-the-installers-boot-loader)
  and return to setup.
- If an update to an installed system prevents it from reaching GRUB,
  [restore the early boot bundle](#restore-the-early-boot-bundle) saved
  before that update.

These are different boot files. Follow the procedure for your situation
on the affected Mac.

## Restore the installer’s boot loader

Hello Guix saves a copy before Guix replaces the installer’s boot loader.
It is kept at `hello-guix/setup-bootaa64.efi` on the EFI partition, which
holds boot files.

If you can still open Guix’s installer, follow the
[retry instructions](installation.md#retry-the-installation) instead.
Restoring the loader gives you access to setup; it does not undo what has
already been installed.

The saved loader and temporary setup files are removed after a successful
installation.

### Identify the installation

In the preparation log, find the **EFI PARTUUID** printed by Asahi. Use
`diskutil list` and `diskutil info` to find the EFI partition with the same
**Disk / Partition UUID**. Use this UUID to identify it; names and partition
numbers can change. If you cannot find a unique match, ask for help and
include the preparation log.

### Restore the saved loader

Fill in the two values below. The commands check the partition identity,
confirm that the required files are present and verify the setup image’s
checksum. They save the current loader if present, restore the saved setup
loader, and unmount EFI. Partitions, firmware, m1n1 and Apple boot policy
remain unchanged.

```sh
(
set -eu
efi_device='diskXsY'             # The identifier found with diskutil.
expected_efi='PASTE-EFI-PARTUUID' # From this installation's preparation log.
actual=$(/usr/sbin/diskutil info -plist "$efi_device" |
  /usr/bin/plutil -extract DiskUUID raw -o - -)
test "$(printf %s "$actual" | tr '[:upper:]' '[:lower:]')" = \
     "$(printf %s "$expected_efi" | tr '[:upper:]' '[:lower:]')"
sudo /usr/sbin/diskutil mount "$efi_device"
esp=$(/usr/sbin/diskutil info -plist "$efi_device" |
  /usr/bin/plutil -extract MountPoint raw -o - -)
test -s "$esp/hello-guix/setup-bootaa64.efi"
test -s "$esp/hello-guix/linux"
test -s "$esp/hello-guix/initrd"
(cd "$esp/hello-guix"; shasum -a 256 -c SHA256SUMS)
recovery=$(mktemp -d "$HOME/hello-guix-recovery.XXXXXX")
cp "$esp/asahi/guix-boot.json" "$recovery/"
if test -f "$esp/EFI/BOOT/BOOTAA64.EFI"; then
  cp "$esp/EFI/BOOT/BOOTAA64.EFI" "$recovery/BOOTAA64.EFI.before"
fi
sudo cp "$esp/hello-guix/setup-bootaa64.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
cmp "$esp/hello-guix/setup-bootaa64.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
sync
sudo /usr/sbin/diskutil unmount "$efi_device"
printf 'Setup loader restored. Records: %s\n' "$recovery"
)
```

If a check fails, keep its output for a problem report. If EFI is still
mounted, run `sudo diskutil unmount diskXsY`, replacing `diskXsY` with the
same disk identifier you used above.

### Start setup again

After the commands succeed, restart and select the same Guix installation
in Startup Options. If setup opens, follow the
[retry instructions](installation.md#retry-the-installation).

If setup still cannot start, or refuses to resume,
[report the problem](https://github.com/hnarayanan/hello-guix/issues).
Include the new error, the original installation error and the command
output above.

## Restore the early boot bundle

Use these steps from macOS if an update stops the Mac from showing the
GRUB boot menu. Restoring the saved `m1n1/boot.bin` lets the Mac load GRUB
with the boot components that worked before the update. You then choose
the matching Guix generation in that menu.

Use the recovery folder you saved [before the update][before-update]. It
contains `boot.bin`, the working boot bundle, and `efi.txt`, which identifies
the EFI partition. The saved system path and generation list tell you which
Guix generation belongs with that bundle.

Work through these steps in one Terminal window on the affected Mac.
Wait for each command to succeed before continuing. If one fails, keep
its output and stop. If you have mounted EFI, use the unmount command in
the last step before leaving.

1. **Find the right partition.** Set `recovery` to your saved folder,
   then display its partition record and the Mac’s disks:

   ```sh
   recovery="/path/to/your/guix-recovery-folder"
   cat "$recovery/efi.txt"
   diskutil list
   ```

   Choose an EFI partition to inspect. Replace `diskXsY` with its macOS
   identifier, not the Linux device name in `efi.txt`:

   ```sh
   efi_device='diskXsY'
   diskutil info "$efi_device"
   ```

   Its **Disk / Partition UUID** must match the PARTUUID in `efi.txt`,
   ignoring letter case. If you cannot find a unique match, ask for help
   before continuing.

2. **Check and mount it.** Compare the selected partition’s UUID with
   the saved record. Only continue when you see **EFI partition matches
   the saved record**:

   ```sh
   expected_efi=$(awk '{print $2}' "$recovery/efi.txt") &&
     test -n "$expected_efi" &&
     actual=$(diskutil info -plist "$efi_device" |
       plutil -extract DiskUUID raw -o - -) &&
     test "$(printf %s "$actual" | tr '[:upper:]' '[:lower:]')" = \
          "$(printf %s "$expected_efi" | tr '[:upper:]' '[:lower:]')" &&
     printf 'EFI partition matches the saved record.\n'
   ```

   Mount the partition. The variable `esp` records where macOS mounted it,
   so the following commands can find its boot files:

   ```sh
   sudo diskutil mount "$efi_device" &&
     esp=$(diskutil info -plist "$efi_device" |
       plutil -extract MountPoint raw -o - -)
   ```

3. **Save the current bundle, then restore the working one.** Keep the
   failed bundle in a new folder, separate from your saved recovery files:

   ```sh
   before=$(mktemp -d "$HOME/hello-guix-boot-repair.XXXXXX") &&
     cp "$esp/m1n1/boot.bin" "$before/boot.bin" &&
     printf 'Current boot bundle saved in %s\n' "$before"
   ```

   Now copy the working bundle back to EFI. These commands check that the
   saved file is not empty and that the restored copy is identical. Only
   continue when you see **Saved boot bundle restored**:

   ```sh
   test -s "$recovery/boot.bin" &&
     sudo cp "$recovery/boot.bin" "$esp/m1n1/boot.bin" &&
     cmp "$recovery/boot.bin" "$esp/m1n1/boot.bin" &&
     printf 'Saved boot bundle restored.\n'
   ```

4. **Finish and restart.** Flush the writes and unmount the partition:

   ```sh
   sync && sudo diskutil unmount "$efi_device"
   ```

   Restart into the same Guix installation and select the saved generation
   in GRUB. Restoring the boot bundle does not select that generation for
   you.

Once Guix starts, continue with
[Return to an earlier generation][return-to-generation] in the configuration
guide. Those steps make the saved generation the default for future boots
and recover its editable configuration.

This follows Asahi’s [recovery procedure][asahi-recovery]. It restores the
early boot bundle; damage to GRUB or a filesystem needs a different repair.
The FAT filesystem used on EFI cannot guarantee that all writes complete if
power is lost during replacement.

[before-update]: configuration.md#save-the-working-system
[return-to-generation]: configuration.md#return-to-an-earlier-generation
[asahi-recovery]:
  https://asahilinux.org/docs/sw/u-boot/#important-note-for-package-maintainers
