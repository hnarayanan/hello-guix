;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Native Guix command fixtures. These systems are only for an isolated container.

(use-modules (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages base)
             (gnu packages bash)
             (gnu services)
             (gnu services base)
             (gnu system)
             (gnu system accounts)
             (gnu system file-systems)
             (gnu system linux-container)
             (guix build-system trivial)
             (guix gexp)
             (guix modules)
             (guix monads)
             (guix packages)
             (guix store)
             (hello-guix system boot)
             (hello-guix system runtime)
             (srfi srfi-1))

(define boot-cli-kernel
  (package
    (name "boot-cli-kernel")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           #~(begin
               (mkdir #$output)
               (call-with-output-file (string-append #$output "/Image")
                 (lambda (port) (display "fixture kernel; not executable" port))))))
    (synopsis "Kernel-shaped input for an isolated command test")
    (description "This is a small non-bootable input for lifecycle tests.")
    (home-page "https://github.com/hnarayanan/hello-guix")
    (license #f)))

(define boot-cli-initrd (plain-file "boot-cli-initrd" "fixture initrd; not executable"))

(define (boot-cli-bundle variant)
  (computed-file (string-append "boot-cli-bundle-" variant)
    #~(begin
        (mkdir #$output)
        (call-with-output-file (string-append #$output "/boot.bin")
          (lambda (port) (display #$(string-append "retained-" variant) port)))
        (symlink #$boot-cli-kernel (string-append #$output "/kernel")))))

;; The container has no FAT mount or Apple device tree. Supply only those
;; observations; the production CLI, destination checks, lock and writer run.
;; The preceding installation-target VM test covers actual FAT publication.
(define boot-cli-observations
  #~(begin
      (use-modules (hello-guix system boot-files))
      (let ((module (resolve-module '(hello-guix system boot-files))))
        (module-set! module 'current-asahi-efi-partuuid
          (lambda () "11111111-2222-4333-8444-555555555555"))
        (module-set! module 'mounted-boot-identity
          (lambda (findmnt path)
            (unless (and (string=? path "/boot/efi") (file-exists? path))
              (error "Unexpected fixture EFI destination" path))
            (values
             (if (file-exists? "/var/lib/boot-cli/wrong-target")
                 "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
                 "11111111-2222-4333-8444-555555555555")
             "vfat"))))))

(define boot-cli-modules
  (source-module-closure '((hello-guix system boot-files))
    #:select? (lambda (name) (eq? (car name) 'hello-guix))))

(define boot-cli-return
  (with-imported-modules boot-cli-modules
    (program-file "boot-cli-return"
      #~(begin
          #$boot-cli-observations
          (primitive-load #$((@@ (hello-guix system boot) boot-command)))))))

(define (boot-cli-loader variant)
  (define inherited
    #~(lambda (package target root)
        (call-with-output-file (string-append root target "/grub-fixture")
          (lambda (port) (display #$variant port)))
        (let ((port (open-file "/var/log/boot-cli-installer.log" "a")))
          (display #$variant port) (newline port) (close-port port))))
  (define installer
    ((@@ (hello-guix system boot) asahi-boot-installer)
     (boot-cli-bundle variant) inherited))
  (bootloader
   (inherit grub-efi-removable-bootloader)
   (installer
    (with-imported-modules boot-cli-modules
      #~(begin #$boot-cli-observations #$installer)))))

(define (make-boot-cli-system variant)
  (unless (member variant '("A" "B" "C")) (error "Unknown fixture variant" variant))
  (let* ((base
          (operating-system
           (host-name (string-append "boot-cli-" (string-downcase variant)))
           (label (string-append "Hello Guix command fixture " variant))
           (kernel boot-cli-kernel)
           (kernel-arguments '())
           (initrd (lambda* (file-systems #:rest options) boot-cli-initrd))
           (initrd-modules '())
           (firmware '())
           (timezone "Etc/UTC")
           (locale "en_US.utf8")
           ;; Guix adds this one locale; omit its larger default locale set.
           (locale-definitions '())
           (bootloader (bootloader-configuration
                        (bootloader (boot-cli-loader variant))
                        (targets '("/boot/efi"))
                        (theme (grub-theme (image #f)))))
           (file-systems (list (file-system
                               (device "nothing") (mount-point "/") (type "dummy"))))
           ;; A single mapped uid/gid is enough. No host accounts are shared.
           (users (list (user-account
                         (name "root") (uid 0) (group "root")
                         (password "") (home-directory "/root"))))
           (groups (list (user-group (name "root") (id 0))))
           (skeletons '())
           (pam-services '())
           (privileged-programs '())
           (setuid-programs '())
           (packages (list bash coreutils (running-guix)))
           ;; Builds use the explicitly exposed host daemon socket. There is
           ;; no daemon service here that could replace or manage that socket.
           (services '())))
         (contained (containerized-operating-system base '())))
    (operating-system
     (inherit contained)
     (kernel boot-cli-kernel)
     (initrd (lambda* (file-systems #:rest options) boot-cli-initrd))
     (initrd-modules '())
     ;; Container conversion removes native boot parameters and substitutes a
     ;; kernel. Keep its real account/activation/Shepherd services, but retain
     ;; explicit test boot entries for the native generation commands.
     (essential-services
      (remove (lambda (service)
                (eq? (service-kind service)
                     (@@ (gnu system) linux-builder-service-type)))
              (operating-system-essential-services contained)))
     (services
      (cons
       (simple-service 'boot-cli-system-entries system-service-type
        (with-monad %store-monad
          (return
           `(("kernel" ,boot-cli-kernel)
             ("initrd" ,boot-cli-initrd)
             ("parameters" ,((@@ (gnu system) operating-system-boot-parameters-file) base))
             ("asahi-boot" ,(boot-cli-bundle variant))))))
       (operating-system-user-services contained))))))
