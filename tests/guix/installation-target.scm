;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Test installation target preparation on a disk attached only to a VM.

(use-modules (gnu packages base)
             (gnu packages disk)
             (gnu packages linux)
             (gnu packages commencement)
             (gnu packages gnupg)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages virtualization)
             (gnu system linux-initrd)
             (guix gexp)
             (guix modules))

(define modules
  ((@@ (gnu system linux-initrd) flat-linux-module-directory)
   linux-libre '("virtio_pci" "virtio_blk" "btrfs" "vfat" "nls_cp437" "nls_iso8859-1")))

(define interrupt-uuid
  (with-imported-modules (source-module-closure '((guix build utils)))
    (computed-file "interrupt-uuid.so"
      #~(begin
          (use-modules (guix build utils))
          (setenv "PATH" #$(file-append gcc-toolchain "/bin"))
          (setenv "LIBRARY_PATH" #$(file-append gcc-toolchain "/lib"))
          (invoke #$(file-append gcc-toolchain "/bin/gcc") "-shared" "-fPIC" "-O2"
                  "-I" #$(file-append gcc-toolchain "/include")
                  #$(local-file "interrupt-uuid.c") "-o" #$output)))))

(define guest
  (with-extensions (list guile-gcrypt guile-json-3)
     (with-imported-modules
         (source-module-closure
          '((hello-guix installer linux installation-files) (hello-guix system boot-files))
          #:select? (lambda (name) (or (guix-module-name? name)
                                      (eq? (car name) 'hello-guix))))
       (program-file "installation-target-guest"
         #~(begin
              (setenv "BOOT_FILES_TEST" #$(local-file "../boot.scm"))
              (primitive-load #$(local-file "installation-target-guest.scm")))
         #:guile guile-3.0-latest))))

(define initrd
  (expression->initrd
     (with-imported-modules
         (source-module-closure '((gnu build linux-boot) (gnu build linux-modules)))
       #~(begin
           (use-modules (gnu build linux-boot)
                        (gnu build linux-modules)
                        (guix build syscalls))
           (mount-essential-file-systems)
           (load-linux-modules-from-directory
            '("virtio_pci" "virtio_blk" "btrfs" "vfat" "nls_cp437" "nls_iso8859-1") #$modules)
           (setenv "PARTED" #$(file-append parted "/sbin/parted"))
           (setenv "MKFS_BTRFS" #$(file-append btrfs-progs "/bin/mkfs.btrfs"))
           (setenv "MKFS_FAT" #$(file-append dosfstools "/sbin/mkfs.fat"))
           (setenv "BTRFS" #$(file-append btrfs-progs "/bin/btrfs"))
           (setenv "BTRFSTUNE" #$(file-append btrfs-progs "/bin/btrfstune"))
           (setenv "INTERRUPT_UUID" #$interrupt-uuid)
           (setenv "LSBLK" #$(file-append util-linux+udev "/bin/lsblk"))
           (setenv "FINDMNT" #$(file-append util-linux "/bin/findmnt"))
           ;; The initrd's static Guile loads Linux modules. The full Guile
           ;; interpreter runs target preparation with the guile-gcrypt extension.
           (execl #$guest #$guest)))))

(file-union "installation-target-check"
 `(("kernel" ,(file-append linux-libre "/Image")) ("initrd" ,initrd)
   ("qemu" ,(file-append qemu-minimal "/bin/qemu-system-aarch64"))
   ("timeout" ,(file-append coreutils "/bin/timeout"))))
