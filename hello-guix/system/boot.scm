;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system boot)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix memoization)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (asahi guix packages bootloader)
  #:export (asahi-boot-bundle asahi-boot-service-type with-asahi-bootloader))

(define (make-asahi-boot-bundle kernel m1n1 u-boot)
  ;; The format follows write-m1n1/install-bootloader-to-esp in Asahi Guix's
  ;; (asahi guix build bootloader m1n1), unchanged between ee2e7465 and
  ;; b9132769. Select regular Apple DTBs and copy bytes without a shell;
  ;; retain gzip -c's filename and timestamp header exactly.
  ;; https://codeberg.org/asahi-guix/channel/src/commit/b9132769b361431e999f7d166d715ef4c6e101d2/modules/asahi/guix/build/bootloader/m1n1.scm
  (computed-file "asahi-boot"
    (with-imported-modules (source-module-closure '((guix build utils)))
      #~(begin
          (use-modules (guix build utils)
                       (ice-9 popen)
                       (rnrs io ports))
          (define (copy-bytes input output)
            (let loop ((bytes (get-bytevector-n input 65536)))
              (unless (eof-object? bytes)
                (put-bytevector output bytes)
                (loop (get-bytevector-n input 65536)))))
          (define dtbs
            (find-files #$(file-append kernel "/lib/dtbs/apple")
                        (lambda (file info)
                          (and (eq? 'regular (stat:type info))
                               (string-suffix? ".dtb" file)))
                        #:stat stat))
          (unless (pair? dtbs)
            (error "No Apple device trees in the selected kernel" #$kernel))
          (mkdir #$output)
          (call-with-output-file (string-append #$output "/boot.bin")
            (lambda (output)
              (for-each
               (lambda (file)
                 (call-with-input-file file
                   (lambda (input) (copy-bytes input output)) #:binary #t))
               (cons #$(file-append m1n1 "/libexec/m1n1.bin") dtbs))
              (let ((pipe (open-pipe* OPEN_READ #$(file-append gzip "/bin/gzip")
                                      "-c" #$(file-append u-boot "/libexec/u-boot-nodtb.bin"))))
                (copy-bytes pipe output)
                (unless (zero? (close-pipe pipe))
                  (error "Could not compress the selected U-Boot" #$u-boot))))
            #:binary #t)
          (symlink #$kernel (string-append #$output "/kernel"))
          (symlink #$m1n1 (string-append #$output "/m1n1"))
          (symlink #$u-boot (string-append #$output "/u-boot"))
          (symlink #$(boot-command) (string-append #$output "/install"))))))

(define asahi-boot-bundle
  (mlambdaq (kernel)
    "Build the stage-two boot bundle for KERNEL without writes to an EFI partition.
Keep its inputs so the system generation records its boot code."
    (make-asahi-boot-bundle kernel asahi-m1n1 asahi-u-boot)))

(define (asahi-boot-installer bundle installer)
  (with-imported-modules
      (source-module-closure '((hello-guix system boot-files))
        #:select? (lambda (name) (eq? (car name) 'hello-guix)))
    #~(lambda (bootloader target root)
        (use-modules (hello-guix system boot-files))
        (install-asahi-bootloader
         #$installer bootloader #$(file-append bundle "/boot.bin") target root
         #+(file-append util-linux "/bin/findmnt")))))

;; Memoization keeps reapplication recognisable without accepting arbitrary
;; bootloaders that happen to use GRUB's name. The bundle is shared with the
;; retained generation entry and does not depend on the complete system.
(define asahi-bootloader
  (mlambdaq (kernel)
    (bootloader
     (inherit grub-efi-removable-bootloader)
     (installer
      (asahi-boot-installer
       (asahi-boot-bundle kernel)
       (bootloader-installer grub-efi-removable-bootloader))))))

(define (with-asahi-bootloader configuration kernel)
  "Keep CONFIGURATION's GRUB settings and deploy KERNEL's matching Asahi bundle.
Support the ordinary removable EFI loader and a single target. Constructing
this configuration neither discovers a machine nor installs boot files."
  (let ((loader (bootloader-configuration-bootloader configuration))
        (targets (bootloader-configuration-targets configuration))
        (adapted (asahi-bootloader kernel)))
    (unless (and (list? targets) (= 1 (length targets))
                 (or (not (car targets))
                     (and (string? (car targets))
                          (string-prefix? "/" (car targets)))))
      (error "Asahi boot deployment requires one absolute EFI target" targets))
    (cond
     ((eq? loader adapted) configuration)
     ((eq? loader grub-efi-removable-bootloader)
      (bootloader-configuration (inherit configuration) (bootloader adapted)))
     (else
      (error "Asahi boot deployment requires the standard removable EFI GRUB loader"
             (bootloader-name loader))))))

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
          (define* (install system #:key boot-file (target "/boot/efi"))
            (catch #t
              (lambda ()
                (install-system-boot system #$(file-append util-linux "/bin/findmnt")
                                     #:boot-file boot-file #:target target))
              (lambda (key . arguments)
                (display "Boot-bundle operation failed: " (current-error-port))
                (print-exception (current-error-port) #f key arguments)
                (exit 1))))
          (match (cdr (command-line))
            ((system) (install system))
            (("--restore" boot-file system) (install system #:boot-file boot-file))
            (("--target" target system) (install system #:target target))
            (("--target" target "--restore" boot-file system)
             (install system #:boot-file boot-file #:target target))
            (_ (display "Usage: hello-guix-boot [--target EFI-MOUNTPOINT] [--restore BOOT-FILE] SYSTEM-DIRECTORY\n"
                        (current-error-port))
               (exit 2)))))))

(define asahi-boot-service-type
  (service-type
   (name 'asahi-boot)
   (extensions (list (service-extension system-service-type boot-bundle-entry)))
   (description
    "Retain the matching m1n1, Apple device trees and U-Boot bundle with this
system generation. Building or activating the system does not install it.")))
