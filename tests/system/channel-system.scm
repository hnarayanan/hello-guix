;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Proposed migration fixture. These disks are fictional; never activate it.
;; Evaluate with the separate Guix + Asahi + Hello Guix test profile.

(use-modules (gnu)
             (gnu bootloader grub)
             (gnu services networking)
             (gnu services base)
             (guix channels)
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
  (packages %base-packages)
  (services
   (modify-services
       (cons (service network-manager-service-type) %base-services)
     (guix-service-type config =>
       (guix-configuration
        (inherit config)
        (guix (running-guix))
        ;; The intended future pull policy, not a working published channel:
        ;; Hello's channel metadata and introduction have not been released.
        ;; This fixture evaluates the declaration; it must not run guix pull.
        (channels
         (cons (channel
                (name 'hello-guix)
                (url "https://github.com/hello-guix/hello-guix")
                (branch "main"))
               %default-channels))))))))
