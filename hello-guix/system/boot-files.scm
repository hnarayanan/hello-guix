;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system boot-files)
  #:use-module ((rnrs io ports) #:select (get-bytevector-n))
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 match)
  #:export (install-boot-bundle check-boot-target install-system-boot))

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

(define (install-boot-bundle source directory)
  "Replace DIRECTORY/boot.bin with SOURCE. Keep the previous bytes in boot.bin.old.
If the bytes match, leave both files unchanged. DIRECTORY must contain a
boot bundle. The caller must check the partition identity."
  (let ((target (string-append directory "/boot.bin"))
        (old (string-append directory "/boot.bin.old"))
        (next (string-append directory "/boot.bin.new")))
    (for-each
     (lambda (file)
       (unless (and (eq? 'regular (stat:type (lstat file)))
                    (> (stat:size (stat file)) 0))
         (error "Expected a nonempty regular boot bundle" file)))
     (list source target))
    (if (same-file-contents? source target)
        'unchanged
        (begin
          ;; Copy SOURCE first. During recovery, it can be boot.bin.old.
          (durable-copy source next)
          (durable-copy target old)
          (rename-file next target)
          (sync-file directory)
          'installed))))

(define (check-boot-target chosen mounted filesystem)
  "Require the mounted FAT partition to be the one chosen by m1n1."
  (unless (and (not (string-null? chosen))
               (string-ci=? chosen mounted) (string=? filesystem "vfat"))
    (error "The mounted EFI partition does not match this boot" chosen mounted filesystem)))

(define (install-system-boot system findmnt)
  "Install SYSTEM's retained bundle on the currently booted Mac's EFI partition."
  (unless (zero? (geteuid)) (error "Installing a boot bundle requires root"))
  (unless (file-exists? "/proc/device-tree/chosen/asahi,efi-system-partition")
    (error "Boot-bundle installation requires a system started through Asahi"))
  (let* ((system (canonicalize-path system))
         (bundle (string-append system "/asahi-boot"))
         (chosen (string-trim-right
                  (call-with-input-file
                      "/proc/device-tree/chosen/asahi,efi-system-partition" get-string-all)
                  #\nul)))
    (unless (file-exists? bundle)
      (error "This generation has no retained Asahi boot bundle; use its separately saved boot files" system))
    (unless (and (string-prefix? "/gnu/store/" system)
                 (string=? (canonicalize-path (string-append system "/kernel/Image"))
                           (canonicalize-path (string-append bundle "/kernel/Image"))))
      (error "The retained bundle does not match the selected system's kernel" system))
    ;; Allow only one update or restore operation at a time. Keep the lock
    ;; file in place so all callers lock the same inode.
    (call-with-output-file "/run/hello-guix-boot.lock"
      (lambda (lock)
        (flock lock LOCK_EX)
        (let* ((port (open-pipe* OPEN_READ findmnt "--noheadings" "--raw"
                                 "--output" "PARTUUID,FSTYPE" "--mountpoint" "/boot/efi"))
               (fields (string-tokenize (get-string-all port)))
               (status (close-pipe port)))
          (unless (zero? status) (error "/boot/efi is not a mounted filesystem"))
          (match fields
            ((uuid filesystem) (check-boot-target chosen uuid filesystem))
            (_ (error "Unexpected EFI mount description" fields))))
        (let ((result (install-boot-bundle (string-append bundle "/boot.bin")
                                          "/boot/efi/m1n1")))
          (format #t "Boot bundle ~a for ~a.~%" result system)
          (when (eq? result 'installed)
            (format #t "Previous bundle: /boot/efi/m1n1/boot.bin.old~%")))))))
