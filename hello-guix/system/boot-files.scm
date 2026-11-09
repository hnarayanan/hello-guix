;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system boot-files)
  #:use-module ((rnrs io ports) #:select (get-bytevector-n))
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 match)
  #:export (install-boot-bundle check-boot-target
            check-boot-destination install-target-boot
            install-asahi-bootloader install-system-boot))

(define (same-file-contents? left right)
  (and (= (stat:size (stat left)) (stat:size (stat right)))
       (call-with-input-file left
         (lambda (a)
           (call-with-input-file right
             (lambda (b)
               (let loop ()
                 (let ((x (get-bytevector-n a 65536))
                       (y (get-bytevector-n b 65536)))
                   (or (and (eof-object? x) (eof-object? y))
                       (and (equal? x y) (loop)))))))))))

(define (sync-file file)
  (let ((port (open-file file "r")))
    (dynamic-wind (lambda () #t) (lambda () (fsync port))
                  (lambda () (close-port port)))))

(define (durable-copy source destination)
  (let* ((temporary (string-append destination ".XXXXXX"))
         (port (mkstemp! temporary)))
    (close-port port)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (copy-file source temporary)
        (sync-file temporary)
        (rename-file temporary destination)
        (sync-file (dirname destination)))
      (lambda ()
        (when (file-exists? temporary) (delete-file temporary))))))

(define (check-boot-file file)
  (unless (and (eq? 'regular (stat:type (lstat file)))
               (> (stat:size (stat file)) 0))
    (error "Expected a nonempty regular boot bundle" file)))

(define (check-boot-inputs source directory)
  (unless (eq? 'directory (stat:type (lstat directory)))
    (error "Expected an existing ordinary m1n1 directory" directory))
  (for-each check-boot-file (list source (string-append directory "/boot.bin"))))

(define (install-boot-bundle source directory)
  "Replace DIRECTORY/boot.bin with SOURCE. Keep the previous bytes in boot.bin.old.
If the bytes match, leave both files unchanged. DIRECTORY must contain a
boot bundle. The caller must check the partition identity."
  (let ((target (string-append directory "/boot.bin"))
        (old (string-append directory "/boot.bin.old"))
        (next (string-append directory "/boot.bin.new")))
    (for-each check-boot-file (list source target))
    (if (same-file-contents? source target)
        'unchanged
        (begin
          ;; Copy SOURCE first. During recovery, it can be boot.bin.old.
          (durable-copy source next)
          (durable-copy target old)
          (rename-file next target)
          (sync-file directory)
          'installed))))

(define (check-boot-target expected mounted filesystem)
  "Require a mounted FAT partition with the EXPECTED partition UUID."
  (unless (and (not (string-null? expected))
               (string-ci=? expected mounted) (string=? filesystem "vfat"))
    (error "The mounted EFI partition does not match the intended target"
           expected mounted filesystem)))

(define (mounted-boot-identity findmnt mount-point)
  (let* ((port (open-pipe* OPEN_READ findmnt "--noheadings" "--raw"
                           "--output" "PARTUUID,FSTYPE" "--mountpoint" mount-point))
         (fields (string-tokenize (get-string-all port)))
         (status (close-pipe port)))
    (unless (zero? status) (error "EFI target is not a mounted filesystem" mount-point))
    (match fields
      ((uuid filesystem) (values uuid filesystem))
      (_ (error "Unexpected EFI mount description" mount-point fields)))))

(define (check-boot-destination target root expected findmnt)
  "Return TARGET's mounted EFI directory beneath ROOT after checking EXPECTED.
TARGET is an absolute path in the installed system. Never fall back to the
running system's TARGET when the destination beneath ROOT is missing."
  (unless (and (string-prefix? "/" root)
               (string-prefix? "/" target)
               (not (string=? target "/"))
               (not (member ".." (string-split target #\/)))
               (not (member "." (string-split target #\/))))
    (error "Expected an absolute target path beneath an absolute root" target root))
  (let* ((root (canonicalize-path root))
         (prefix (if (string=? root "/") "/" (string-append root "/")))
         (esp (canonicalize-path (string-append
                                  (if (string=? root "/") "" root) target))))
    (unless (and (file-is-directory? root)
                 (not (string=? root esp))
                 (string-prefix? prefix esp)
                 (file-is-directory? esp))
      (error "EFI target must be beneath the destination root" target root))
    (call-with-values
        (lambda () (mounted-boot-identity findmnt esp))
      (lambda (uuid filesystem) (check-boot-target expected uuid filesystem)))
    esp))

(define (install-target-boot source target root expected findmnt)
  "Install SOURCE on the checked EFI TARGET beneath ROOT.
SOURCE is the selected boot.bin file. The caller supplies the intended partition
UUID and serializes deployment; this procedure does not discover a live system."
  (let* ((esp (check-boot-destination target root expected findmnt))
         (directory (string-append esp "/m1n1")))
    (check-boot-inputs source directory)
    (install-boot-bundle source directory)))

(define (current-asahi-efi-partuuid)
  (let ((file "/proc/device-tree/chosen/asahi,efi-system-partition"))
    (unless (file-exists? file)
      (error "Boot-bundle installation requires a system started through Asahi"))
    (string-trim-right (call-with-input-file file get-string-all) #\nul)))

(define (call-with-boot-lock file thunk)
  ;; Keep this host-side lock in place. All updates and returns must lock
  ;; the same inode, including installation beneath an alternate root.
  (let ((lock (open-file file "w")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (flock lock LOCK_EX)
        (thunk))
      ;; Closing the descriptor releases flock even when THUNK throws.
      (lambda () (close-port lock)))))

(define* (install-asahi-bootloader installer bootloader source target root findmnt
                                 #:key expected
                                 (lock-file "/run/hello-guix-boot.lock"))
  "Install BOOTLOADER with INSTALLER and deploy the selected boot bundle SOURCE.
A false TARGET is Guix's image-generation sentinel and causes no effects.
Otherwise check the independently EXPECTED partition UUID, or the live Asahi
identity when omitted. Serialize with manual returns using the host LOCK-FILE."
  (if (not target)
      'skipped
      (call-with-boot-lock lock-file
        (lambda ()
          (let* ((expected (or expected (current-asahi-efi-partuuid)))
                 (esp (check-boot-destination target root expected findmnt)))
            ;; Check both bundles before GRUB can change anything on the ESP.
            (check-boot-inputs source (string-append esp "/m1n1"))
            (installer bootloader target root)
            ;; The inherited installer may have taken time. Recheck the exact
            ;; mounted target before replacing its early boot bundle.
            (install-target-boot source target root expected findmnt))))))

(define* (install-system-boot system findmnt #:key boot-file)
  "Install SYSTEM's retained bundle on the currently booted Mac's EFI partition.
When BOOT-FILE is supplied, restore those explicit saved bytes instead. The
caller must verify their checksum and association with SYSTEM; this procedure
cannot establish that an external bundle matches the selected kernel."
  (unless (zero? (geteuid)) (error "Installing a boot bundle requires root"))
  (let* ((system (canonicalize-path system))
         (bundle (string-append system "/asahi-boot"))
         (kernel (string-append system "/kernel/Image"))
         (chosen (current-asahi-efi-partuuid)))
    (unless (or boot-file (file-exists? bundle))
      (error "This generation has no retained Asahi boot bundle; use its separately saved boot files" system))
    (unless (and (string-prefix? "/gnu/store/" system)
                 (eq? 'regular (stat:type (stat kernel)))
                 (> (stat:size (stat kernel)) 0))
      (error "Expected a stored system with a nonempty kernel" system))
    (unless boot-file
      (unless (string=? (canonicalize-path kernel)
                        (canonicalize-path (string-append bundle "/kernel/Image")))
        (error "The retained bundle does not match the selected system's kernel" system)))
    (call-with-boot-lock "/run/hello-guix-boot.lock"
      (lambda ()
        (let ((result (install-target-boot (or boot-file (string-append bundle "/boot.bin"))
                                          "/boot/efi" "/" chosen findmnt)))
          (format #t "Boot bundle ~a for ~a.~%" result system)
          (when (eq? result 'installed)
            (format #t "Previous bundle: /boot/efi/m1n1/boot.bin.old~%")))))))
