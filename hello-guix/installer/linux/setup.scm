;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux setup)
  #:use-module (asahi guix systems install)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader m1n1)
  #:use-module (hello-guix installer linux setup-state)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix modules)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (srfi srfi-1)
  #:export (setup-system))

;; Guix includes a separate installer command for use without a local console.
;; Remove that command so all installation paths use our prepared target.
(define setup-services
  (remove (lambda (service)
            (eq? 'installer-program-profile
                 (service-type-name (service-kind service))))
          (operating-system-user-services asahi-installation-os)))

(define* (ram-initrd file-systems #:rest arguments)
  (apply raw-initrd file-systems
         #:volatile-root? #t
         #:pre-mount
         (with-imported-modules
             (source-module-closure '((hello-guix installer linux ram-boot))
               #:select? (lambda (name)
                           (or (guix-module-name? name)
                               (eq? (car name) 'hello-guix))))
           #~(begin
               (use-modules (hello-guix installer linux ram-boot))
               (load-ram-root
                (chosen-efi-device #$(file-append util-linux "/sbin/blkid"))
                #$(file-append util-linux "/sbin/losetup")
                #$(file-append coreutils "/bin/sha256sum"))))
         arguments))

(define (setup-system interface guix channels)
  (operating-system
    (inherit asahi-installation-os)
    (host-name "guix-setup")
    (timezone "Etc/UTC")
    (initrd ram-initrd)
    (initrd-modules
     (append '("loop" "squashfs" "overlay")
             (operating-system-initrd-modules asahi-installation-os)))
    (file-systems
     (cons (file-system
             (device "/dev/loop0") (mount-point "/")
             (type "squashfs") (check? #f))
           %base-file-systems))
    ;; The Asahi Guix channel's image initializer needs m1n1, device trees,
    ;; and U-Boot from this bootloader profile.
    (bootloader
      (bootloader-configuration
        (bootloader m1n1-u-boot-grub-bootloader)
        (targets '("/boot/efi"))))
    (services
      (cons*
       (simple-service 'setup-command profile-service-type
         ;; Guix uses this private helper for its installer command.
         ;; If this binding disappears, evaluation of the build recipe fails.
         (list ((@@ (gnu system install) installer-command-package)
                interface #:executable "guix-system-installer")))
       (simple-service 'setup-origin etc-service-type
         `(("hello-guix/setup"
            ,(plain-file "setup-origin" %installation-marker))))
       (modify-services setup-services
        ;; Guix includes a minimal system for offline installation.
        ;; Its Linux-libre kernel cannot boot this Mac. Remove that system,
        ;; but keep the tools that prepare locales and profiles.
        (gc-root-service-type roots => (remove operating-system? roots))
        (guix-service-type
          config => (guix-configuration
                      (inherit config)
                      (guix guix)
                      (channels channels)))
        (kmscon-service-type
          config => (kmscon-configuration
                      (inherit config)
                      (login-program interface))))))))
