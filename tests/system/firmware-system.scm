;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Fictional storage and synthetic firmware. Never activate this declaration.

(use-modules (gnu)
             (gnu bootloader grub)
             (gnu services base)
             (guix gexp)
             (hello-guix apple-silicon)
             (hello-guix system runtime))

(define my-system
  (operating-system
   (host-name "firmware-fixture")
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
   ;; Isolate the supplied input; ordinary firmware composition has unit checks.
   (firmware '())
   (packages %base-packages)
   (services
    (modify-services %base-services
      (guix-service-type config =>
        (guix-configuration
         (inherit config)
         (guix (running-guix))))))))

(on-apple-silicon
 my-system
 #:firmware (local-file "hello-guix/firmware" #:recursive? #t)
 #:audio? #f)
