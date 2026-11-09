;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The test runner adds a console or GNOME test-services list before this source.
;; This configuration uses fictional disks. Build it, but do not activate it.

(add-to-load-path (string-append (dirname (current-filename)) "/hello-guix/modules"))

(use-modules (gnu)
             (gnu bootloader grub)
             (gnu services networking)
             (gnu services base)
             (guix gexp)
             (hello-guix system configuration-retention)
             (hello-guix system hardware)
             (hello-guix system runtime))

(with-asahi-hardware
 (operating-system
  (host-name "source-replay")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")
  (bootloader
   (bootloader-configuration
    (bootloader grub-efi-removable-bootloader)
    (targets '("/boot/efi"))))
  (file-systems
   (cons* (file-system
           (device (uuid "11111111-2222-4333-8444-555555555555" 'btrfs))
           (mount-point "/")
           (type "btrfs"))
          (file-system
           (device (uuid "1234-ABCD" 'fat32))
           (mount-point "/boot/efi")
           (type "vfat"))
          %base-file-systems))
  (users
   (cons (user-account
          (name "alex")
          (group "users")
          (supplementary-groups '("wheel" "netdev" "audio" "video")))
         %base-user-accounts))
  (services
   (cons* (service configuration-source-service-type
                   (configuration-source (current-filename)))
          (modify-services test-services
            (guix-service-type config =>
              (guix-configuration (inherit config) (guix (running-guix)))))))))
