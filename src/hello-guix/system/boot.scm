;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system boot)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages bootloaders)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (asahi guix packages bootloader)
  #:use-module (asahi guix build modules)
  #:export (asahi-boot-bundle asahi-boot-service-type))

(define (asahi-boot-bundle kernel)
  "Build the stage-two boot bundle for KERNEL without writes to an EFI partition.
Keep its inputs so the system generation records its boot code."
  (define inputs
    (file-union "asahi-boot-inputs"
                `(("lib/dtbs" ,(file-append kernel "/lib/dtbs/apple"))
                  ("libexec/m1n1.bin" ,(file-append asahi-m1n1 "/libexec/m1n1.bin"))
                  ("libexec/u-boot-nodtb.bin"
                   ,(file-append asahi-u-boot "/libexec/u-boot-nodtb.bin")))))
  (computed-file "asahi-boot"
    (with-extensions (list guile-sqlite3 guile-gcrypt)
      (with-imported-modules
          (source-module-closure '((asahi guix build bootloader m1n1))
            #:select? (lambda (name)
                        (or (import-asahi-module? name)
                            (equal? name '(guix config))
                            (equal? name '(guix store deduplication)))))
        #~(begin
            (use-modules (asahi guix build bootloader m1n1)
                         (guix build utils))
            (setenv "PATH" (string-join
                            (list (string-append #$bash-minimal "/bin")
                                  (string-append #$coreutils "/bin")
                                  (string-append #$gzip "/bin")) ":"))
            ;; Use the channel's public image initializer in a build directory.
            ;; Its temporary GRUB loader is not part of the resulting bundle.
            (mkdir "efi")
            (m1n1-initialize-efi-partition "efi"
              #:bootloader-package #$inputs #:grub-efi #$grub-efi)
            (mkdir #$output)
            (copy-file "efi/m1n1/boot.bin" (string-append #$output "/boot.bin"))
            (symlink #$kernel (string-append #$output "/kernel"))
            (symlink #$asahi-m1n1 (string-append #$output "/m1n1"))
            (symlink #$asahi-u-boot (string-append #$output "/u-boot"))
            (symlink #$(boot-command) (string-append #$output "/install")))))))

(define (boot-bundle-entry kernel)
  (with-monad %store-monad
    (return `(("asahi-boot" ,(asahi-boot-bundle kernel))))))

(define (boot-command)
  (with-imported-modules
      (source-module-closure '((hello-guix system boot-files))
        #:select? (lambda (name) (eq? (car name) 'hello-guix)))
    (program-file "hello-guix-boot"
      #~(begin
          (use-modules (hello-guix system boot-files)
                       (ice-9 match))
          (match (cdr (command-line))
            ((system)
             (catch #t
               (lambda ()
                 (install-system-boot system #$(file-append util-linux "/bin/findmnt")))
               (lambda (key . arguments)
                 (display "Boot bundle was not installed: " (current-error-port))
                 (print-exception (current-error-port) #f key arguments)
                 (exit 1))))
            (_ (display "Usage: hello-guix-boot SYSTEM-DIRECTORY\n"
                        (current-error-port))
               (exit 2)))))))

(define asahi-boot-service-type
  (service-type
   (name 'asahi-boot)
   (extensions (list (service-extension system-service-type boot-bundle-entry)))
   (description
    "Retain the matching m1n1, Apple device trees and U-Boot bundle with this
system generation. Building or activating the system does not install it.")))
