;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu bootloader)
             (gnu image)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages bootloaders)
             (gnu packages compression)
             (gnu system)
             (gnu system image)
             (gnu system uuid)
             (guix gexp)
             (guix modules)
             (asahi guix build modules))

(define compressed-root
  (primitive-load (string-append (dirname (current-filename)) "/ram-root.scm")))

(lambda (name setup)
  (define os (operating-system-with-provenance setup))
  (define root-image (compressed-root os))
  (define boot-config
    (computed-file "ram-grub.cfg"
      #~(call-with-output-file #$output
          (lambda (port)
            ;; cmdpath identifies the EFI partition that loaded GRUB.
            ;; A filesystem label can match more than one installation.
            (format port "insmod regexp~%regexp --set=1:root '^\\(([^)]+)\\)' \"$cmdpath\"~%")
            ;; Match the interface naming policy in the generated system.
            (format port "linux /hello-guix/linux root=/dev/loop0 rootfstype=squashfs gnu.system=~a gnu.load=~a/boot net.ifnames=0~%" #$os #$os)
            (display "initrd /hello-guix/initrd\nboot\n" port)))))
  (define esp
    (partition
     (size (* 3 (expt 2 30)))
     (offset root-offset)
     (label "EFI") (file-system "fat32")
     (file-system-options '("-S" "4096")) (flags '(esp))
     (initializer
      (with-imported-modules
          (source-module-closure '((asahi guix build bootloader m1n1))
                                 #:select? import-asahi-module?)
        #~(lambda* (directory #:key bootloader-package #:allow-other-keys)
            (use-modules (asahi guix build bootloader m1n1)
                         (guix build utils))
            (setenv "PATH" (string-join
                            (list (string-append #$bash-minimal "/bin")
                                  (string-append #$coreutils "/bin")
                                  (string-append #$gzip "/bin")
                                  (getenv "PATH")) ":"))
            (unless (< (stat:size (stat #$root-image)) (* 2600 (expt 2 20)))
              (error "RAM image exceeds the EFI staging budget"))
            (m1n1-initialize-efi-partition directory
              #:bootloader-package bootloader-package #:grub-efi #$grub-efi)
            ;; Load part_gpt before GRUB calculates cmdpath. Otherwise,
            ;; cmdpath identifies the whole disk instead of the partition.
            (setenv "TMPDIR" directory)
            (invoke #$(file-append grub-efi "/bin/grub-mkstandalone")
                    "-O" "arm64-efi" "--modules=part_gpt fat"
                    "-o" (string-append directory "/EFI/BOOT/BOOTAA64.EFI")
                    (string-append "boot/grub/grub.cfg=" #$boot-config))
            (let ((staging (string-append directory "/hello-guix")))
              (mkdir-p staging)
              (copy-file #$root-image (string-append staging "/root.squashfs"))
              (copy-file (string-append #$os "/kernel/Image") (string-append staging "/linux"))
              (copy-file (string-append #$os "/initrd") (string-append staging "/initrd"))
              (with-directory-excursion staging
                (with-output-to-file "SHA256SUMS"
                  (lambda () (invoke #$(file-append coreutils "/bin/sha256sum") "root.squashfs"))))))))))
  (define destination
    (partition
     (size (* 512 (expt 2 20))) (label "Guix_target")
     ;; Guix's image builder identifies the root by this flag.
     (flags '(boot))
     (file-system "btrfs") (file-system-options '("-s" "4096"))
     ;; A fixed UUID makes the template reproducible. Before setup mounts it,
     ;; setup checks its bytes and replaces this UUID with the new GPT partition UUID.
     (uuid (uuid "4bd928ab-b956-48a8-910b-bb98ba7f2044"))
     (initializer
      #~(lambda* (directory #:key #:allow-other-keys)
          (mkdir-p directory)
          (call-with-output-file (string-append directory "/.hello-guix-empty")
            (lambda (port) (display "(hello-guix-empty-root 1)\n" port)))))))
  ;; system-image normally rewrites the OS root to its disk partition.
  ;; Use its existing partition builder directly so setup keeps /dev/loop0.
  ((@@ (gnu system image) system-disk-image)
   (image (name name) (format 'disk-image) (operating-system os)
          (partition-table-type 'gpt) (partitions (list esp destination)))
   #:bootloader (bootloader-configuration-bootloader (operating-system-bootloader os))
   #:bootcfg boot-config #:register-closures? #f))
