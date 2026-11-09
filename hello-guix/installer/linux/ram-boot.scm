;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux ram-boot)
  #:use-module (guix build utils)
  #:use-module (guix build syscalls)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (load-ram-root chosen-efi-device))

(define* (chosen-efi-device blkid #:optional
                           (chosen-file "/proc/device-tree/chosen/asahi,efi-system-partition"))
  ;; The udev service has not started. Use the partition UUID from m1n1.
  ;; Wait for Linux to detect the NVMe device after the initrd loads its modules.
  ;; Use lowercase for blkid's case-sensitive PARTUUID selector.
  (let ((id (string-downcase
             (string-trim-right (call-with-input-file chosen-file get-string-all) #\nul))))
    (let wait ((left 20))
      (let* ((port (open-pipe* OPEN_READ blkid "-t" (string-append "PARTUUID=" id)
                              "-o" "device"))
             (names (string-tokenize (get-string-all port)))
             (status (close-pipe port)))
        (cond
         ((and (zero? status) (= 1 (length names))) (car names))
         ((and (null? names) (> left 0)) (sleep 1) (wait (1- left)))
         (else (error "Cannot identify Asahi's EFI partition" id names)))))))

(define (available-memory)
  (call-with-input-file "/proc/meminfo"
    (lambda (port)
      (let* ((line (find (lambda (line) (string-prefix? "MemAvailable:" line))
                         (string-split (get-string-all port) #\newline)))
             (kib (and line (string->number (cadr (string-tokenize line))))))
        (unless kib (error "Cannot measure available memory"))
        (* 1024 kib)))))

(define (load-ram-root device losetup sha256sum)
  "Copy the compressed setup system into RAM, then unmount DEVICE.
Guix's boot-system mounts /dev/loop0 with a temporary, writable root overlay.
The switch-root operation preserves /dev and the tmpfs mounted below it."
  (let ((esp "/hello-guix-efi") (ram "/dev/hello-guix"))
    (mkdir-p esp)
    (mount device esp "vfat" MS_RDONLY "iocharset=iso8859-1")
    (dynamic-wind
      (const #t)
      (lambda ()
        (unless (file-exists? (string-append esp "/asahi/guix-boot.json"))
          (error "Missing Hello Guix boot record. Return to macOS and use the Hello Guix installer to prepare this installation."))
        (let* ((source (string-append esp "/hello-guix/root.squashfs"))
               (bytes (stat:size (stat source))))
          ;; Keep at least 2 GiB of RAM for Guile and system services.
          ;; During installation, Guix stores new downloads on the target disk.
          (unless (and (> bytes 0) (< bytes (expt 2 32))
                       (> (available-memory) (+ bytes (* 2 (expt 2 30)))))
            (error "Insufficient RAM for this installation image" bytes))
          (mkdir-p ram)
          (mount "tmpfs" ram "tmpfs" 0
                 (format #f "size=~a,mode=0700" (+ bytes (* 8 (expt 2 20)))))
          (display "Loading the Guix installation system into RAM...\n")
          (copy-file source (string-append ram "/root.squashfs"))
          (copy-file (string-append esp "/hello-guix/SHA256SUMS")
                     (string-append ram "/SHA256SUMS"))
          (with-directory-excursion ram
            (invoke sha256sum "--check" "SHA256SUMS"))
          (copy-file (string-append esp "/asahi/guix-boot.json")
                     (string-append ram "/target.json"))))
      (lambda () (umount esp)))
    (invoke losetup "--read-only" "/dev/loop0"
            (string-append ram "/root.squashfs"))
    (display "Live system is in RAM; installation partitions are released.\n")))
