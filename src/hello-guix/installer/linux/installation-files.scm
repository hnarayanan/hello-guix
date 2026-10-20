;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (hello-guix installer linux installation-files)
  #:use-module (hello-guix installer linux target)
  #:use-module (guix build utils)
  #:use-module (guix build syscalls)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:export (call-with-installation-target save-setup-loader
            call-with-preserved-boot-files finish-installation
            prepare-configuration-support))

(define (ordinary-directory path)
  (unless (and (eq? 'directory (stat:type (lstat path)))
               (= (geteuid) (stat:uid (lstat path)))
               (string=? path (canonicalize-path path)))
    (error "Expected an ordinary directory owned by the current user" path)))

(define (ordinary-file path)
  (unless (and (eq? 'regular (stat:type (lstat path)))
               (= (geteuid) (stat:uid (lstat path))))
    (error "Expected an ordinary file owned by the current user" path)))

(define (prepare-configuration-support source channels directory)
  "Copy the helper sources and channels.scm into DIRECTORY beside config.scm.
Copy the contents of store links as editable files. Reject links at the
destination, including on a retry. Copy no other installer state."
  (define (copy-tree input output)
    (if (file-is-directory? input)
        (begin
          (unless (file-exists? output) (mkdir output))
          (ordinary-directory output)
          (chmod output #o755)
          (for-each (lambda (name)
                      (copy-tree (string-append input "/" name)
                                 (string-append output "/" name)))
                    (scandir input (lambda (name) (not (member name '("." "..")))))))
        (begin
          (when (false-if-exception (lstat output)) (ordinary-file output))
          (copy-file input output)
          (chmod output #o644))))
  (ordinary-directory directory)
  (copy-tree source (string-append directory "/hello-guix"))
  (copy-tree channels (string-append directory "/channels.scm")))

(define (copy-wifi-settings source-directory destination)
  ;; Both systems use iwd. Copy only its network profiles, with access
  ;; limited to root. The installed system must obtain its own DNS settings.
  (when (false-if-exception (lstat source-directory))
    (ordinary-directory source-directory)
    (mkdir-p destination)
    (ordinary-directory destination)
    (chmod destination #o700)
    (for-each
     (lambda (name)
       (let ((source (string-append source-directory "/" name))
             (output (string-append destination "/" name)))
         (ordinary-file source)
         (when (false-if-exception (lstat output)) (ordinary-file output))
         (copy-file source output)
         (chmod output #o600)))
     (scandir source-directory
       (lambda (name)
         (any (lambda (suffix) (string-suffix? suffix name))
              '(".psk" ".8021x" ".open")))))))

(define (call-with-installation-target target inspect btrfs thunk)
  "Mount Asahi's empty Linux destination at /mnt for Guix's installer.
This function does not partition or format disks. The setup system stays in RAM."
  (let* ((root "/mnt")
         (esp (string-append root "/boot/efi"))
         (identity (target->sexp target)))
    (define (recheck)
      (unless (equal? identity (target->sexp (inspect)))
        (error "The prepared target changed")))
    (define (entries directory)
      (scandir directory (lambda (name) (not (member name '("." ".."))))))
    (unless (zero? (geteuid))
      (error "Installing the system requires root"))
    (recheck)
    (mkdir-p root)
    (ordinary-directory root)
    (unless (null? (entries root)) (error "The mount directory is not empty" root))
    ;; Prevent Btrfs log replay so this check cannot change the filesystem.
    (mount (target-root target) root "btrfs" MS_RDONLY "subvolid=5,rescue=nologreplay")
    (dynamic-wind
      (const #t)
      (lambda ()
        (let* ((marker (string-append root "/.hello-guix-empty"))
               (record (string-append root "/.hello-guix-installing"))
               (sysfs (string-append "/sys/fs/btrfs/" (target-root-uuid target))))
          (ordinary-file marker)
          (unless (equal? '(hello-guix-empty-root 1) (call-with-input-file marker read))
            (error "Not a Hello Guix empty target"))
          (unless (and (= 1 (length (entries (string-append sysfs "/devices"))))
                       (= 1 (length (entries (string-append sysfs "/devinfo")))))
            (error "Target is not a single-device Btrfs filesystem"))
          (if (false-if-exception (lstat record))
              (begin
                (ordinary-file record)
                (unless (equal? identity (call-with-input-file record read))
                  (error "An earlier installation used different partitions")))
              (unless (equal? '(".hello-guix-empty") (entries root))
                (error "The destination contains unexpected files")))
          (when (false-if-exception (lstat (string-append root "/var/guix/profiles/system")))
            (error "A Guix system already exists here; inspect it before retrying"))))
      (lambda () (umount root)))
    (recheck)
    (mount (target-root target) root "btrfs" 0 "subvolid=5")
    (dynamic-wind
      (const #t)
      (lambda ()
        ;; Asahi has set the partition size. Expand the filesystem to fit.
        ;; Keep command output off the review page. If the command fails,
        ;; invoke/quiet includes its output in the exception.
        (invoke/quiet btrfs "filesystem" "resize" "max" root)
        (call-with-output-file (string-append root "/.hello-guix-installing")
          (lambda (port) (write identity port) (newline port) (fsync port)))
        (mkdir-p esp)
        (ordinary-directory esp)
        (mount (target-efi target) esp "vfat" 0 "iocharset=iso8859-1")
        (dynamic-wind
          (const #t)
          (lambda ()
            (mkdir-p (string-append root "/etc"))
            (ordinary-directory (string-append root "/etc"))
            (copy-wifi-settings "/var/lib/iwd" (string-append root "/var/lib/iwd"))
            (thunk))
          (lambda () (sync) (umount esp))))
      (lambda () (umount root)))))

(define (save-setup-loader esp backup)
  ;; Keep the original loader for recovery. On a retry, the active loader
  ;; might be incomplete, so do not copy it over the backup.
  (let ((source (string-append esp "/EFI/BOOT/BOOTAA64.EFI")))
    (ordinary-file source)
    (mkdir-p (dirname backup))
    (ordinary-directory (dirname backup))
    (if (false-if-exception (lstat backup))
        (ordinary-file backup)
        (let ((temporary (string-append backup ".tmp")))
          (when (false-if-exception (lstat temporary)) (ordinary-file temporary))
          (copy-file source temporary)
          (chmod temporary #o600)
          (call-with-input-file temporary fsync)
          (rename-file temporary backup)
          (sync)))))

(define (call-with-preserved-boot-files esp thunk)
  "Run THUNK. Then check that Asahi's boot files are unchanged, even if THUNK fails.
This function compares checksums but does not restore changed files.
Guix can replace GRUB."
  (let* ((files (map (lambda (name) (string-append esp "/" name))
                     '("m1n1/boot.bin" "ubootefi.var" "vendorfw/firmware.cpio")))
         (hashes (map file-sha256 files)))
    (dynamic-wind
      (const #t)
      thunk
      (lambda ()
        (unless (equal? hashes (map file-sha256 files))
          (error "An Asahi boot file changed during installation; do not reboot"))))))

(define (finish-installation root staging)
  ;; The setup system no longer needs these files. Call this function only
  ;; after installation and boot checks pass, before the completion page.
  (ordinary-directory staging)
  (delete-file-recursively staging)
  (delete-file (string-append root "/.hello-guix-empty"))
  (delete-file (string-append root "/.hello-guix-installing"))
  (sync))
