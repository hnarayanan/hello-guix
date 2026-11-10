;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux firmware)
  #:use-module (gnu packages cpio)
  #:use-module (gnu packages gnupg)
  #:use-module (guix base16)
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module (guix build utils)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix store)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:export (prepared-apple-silicon-firmware prepare-installation-firmware))

(define (prepared-apple-silicon-firmware archive)
  "Return the firmware directory prepared from the file-like Asahi ARCHIVE.
Extract with GNU cpio in a Guix build, validate the upstream manifest, and
materialize independent files. The returned directory contains Linux firmware
paths and the conventional .vendorfw.manifest. Its backing store item retains
origin.scm beside that directory, including the exact archive reference and
SHA-256. This constructor neither probes an ESP nor writes a configuration."
  (unless (file-like? archive)
    (error "Firmware preparation requires a file-like archive" archive))
  (file-append
   (computed-file "apple-silicon-firmware-source"
     (with-extensions (list guile-gcrypt)
       (with-imported-modules
           (source-module-closure '((guix build utils) (guix base16)))
         #~(begin
             (use-modules (guix build utils)
                          (guix base16)
                          (gcrypt hash)
                          (ice-9 ftw)
                          (ice-9 match)
                          (ice-9 popen)
                          (ice-9 rdelim)
                          (srfi srfi-1))
             (define cpio #+(file-append cpio "/bin/cpio"))
             (define (digest path)
               (bytevector->base16-string (file-sha256 path)))
             (define (entries directory)
               (scandir directory
                        (lambda (name) (not (member name '("." ".."))))))
             (define (safe-name? name)
               (and (not (string-null? name))
                    (every (lambda (part)
                             (and (not (member part '("" "." "..")))
                                  (string-every
                                   (lambda (char)
                                     (or (char<=? #\a char #\z)
                                         (char<=? #\A char #\Z)
                                         (char<=? #\0 char #\9)
                                         (memv char '(#\. #\_ #\- #\+ #\, #\@))))
                                   part)))
                           (string-split name #\/))))
             (define (firmware-name? name)
               (and (safe-name? name)
                    (not (string=? name ".vendorfw.manifest"))))
             ;; Let cpio parse the archive. Limit its namespace before extraction;
             ;; check actual names/types afterwards, including embedded newlines.
             (let ((pipe (open-pipe* OPEN_READ cpio "--list" "--quiet"
                                     "--file" #$archive)))
               (let loop ((seen '()))
                 (let ((name (read-line pipe)))
                   (if (eof-object? name)
                       (unless (and (zero? (close-pipe pipe)) (pair? seen))
                         (error "Cannot list the firmware archive"))
                       (begin
                         (unless (and (safe-name? name)
                                      (or (string=? name "vendorfw")
                                          (string-prefix? "vendorfw/" name))
                                      (not (member name seen)))
                           (error "Unexpected firmware archive path" name))
                         (loop (cons name seen)))))))
             (mkdir "unpacked")
             (invoke cpio "--extract" "--make-directories"
                     "--no-absolute-filenames" "--no-preserve-owner" "--quiet"
                     "--directory" "unpacked" "--file" #$archive)
             (unless (equal? (entries "unpacked") '("vendorfw"))
               (error "Expected only vendorfw in the firmware archive"))
             (define (regular-files directory)
               (append-map
                (lambda (name)
                  (let ((path (string-append directory "/" name)))
                    (unless (safe-name? name)
                      (error "Unexpected extracted firmware name" path))
                    (case (stat:type (lstat path))
                      ((directory) (regular-files path))
                      ((regular) (list path))
                      (else (error "Unexpected extracted firmware type" path)))))
                (entries directory)))
             (unless (eq? 'directory (stat:type (lstat "unpacked/vendorfw")))
               (error "Expected a firmware directory"))
             (define files (regular-files "unpacked/vendorfw"))
             (define manifest "unpacked/vendorfw/.vendorfw.manifest")
             (unless (member manifest files)
               (error "The firmware archive has no upstream manifest"))
             (define (firmware-path name)
               (unless (firmware-name? name)
                 (error "Unexpected firmware manifest path" name))
               (let ((path (string-append "unpacked/vendorfw/" name)))
                 (unless (member path files)
                   (error "Missing firmware manifest file" name))
                 path))
             (define described
               (call-with-input-file manifest
                 (lambda (port)
                   (let loop ((names '()))
                     (let ((line (read-line port)))
                       (if (eof-object? line) names
                           (let ((name
                                  (match (string-tokenize line)
                                    (("FILE" name "SHA256" expected)
                                     (unless (string=? expected
                                                       (digest (firmware-path name)))
                                       (error "Firmware checksum does not match" name))
                                     name)
                                    (("LINK" name target)
                                     (unless (member target names)
                                       (error "Firmware link has no preceding source" name))
                                     (unless (string=? (digest (firmware-path name))
                                                       (digest (firmware-path target)))
                                       (error "Firmware link contents do not match" name))
                                     name)
                                    (_ (error "Unexpected firmware manifest entry" line)))))
                             (when (member name names)
                               (error "Duplicate firmware manifest entry" name))
                             (loop (cons name names)))))))))
             (unless (and (pair? described)
                          (lset= string=?
                                 (map firmware-path described)
                                 (delete manifest files)))
               (error "Firmware files and manifest do not agree"))
             (mkdir #$output)
             ;; copy-file deliberately materializes hard-linked archive entries.
             ;; Native deterministic CPIO headers reset inode numbers, so keeping
             ;; their original link counts would conflate distinct link groups.
             (unless (copy-recursively "unpacked/vendorfw"
                                       (string-append #$output "/firmware")
                                       #:copy-file copy-file #:log #f)
               (error "Could not materialize the complete firmware directory"))
             (call-with-output-file (string-append #$output "/origin.scm")
               (lambda (port)
                 (write `(apple-silicon-firmware-source
                          (version 1)
                          (archive ,#$archive)
                          (sha256 ,(digest #$archive))) port)
                 (newline port)))))))
   "/firmware"))

(define (prepare-installation-firmware archive destination)
  "Prepare explicit ARCHIVE as the editable firmware directory DESTINATION.
Keep the normalized store output rooted until a complete ordinary directory
and deterministic origin receipt have been copied. Publish a new directory
by rename; reuse an existing directory only when every path and byte agrees.
Never merge, follow destination links, or alter an existing different tree."
  (define receipt-name ".hello-guix-origin.scm")
  (define (entries path)
    (scandir path (lambda (name) (not (member name '("." ".."))))))
  (define (exists? path) (false-if-exception (lstat path)))
  (define (ordinary-directory path)
    (unless (and (eq? 'directory (stat:type (lstat path)))
                 (string=? path (canonicalize-path path)))
      (error "Expected an ordinary firmware destination parent" path)))
  (define (tree path)
    (let ((info (lstat path)))
      (case (stat:type info)
        ((directory)
         `(directory ,@(map (lambda (name)
                              (cons name (tree (string-append path "/" name))))
                            (entries path))))
        ((regular)
         (unless (= 1 (stat:nlink info))
           (error "Firmware destination contains a hard link" path))
         `(regular ,(file-sha256 path)))
        (else (error "Firmware destination contains a link or special file" path)))))
  (define (copy-entry source target)
    (case (stat:type (lstat source))
      ((directory)
       (mkdir target #o755)
       (for-each (lambda (name)
                   (copy-entry (string-append source "/" name)
                               (string-append target "/" name)))
                 (entries source)))
      ((regular) (copy-file source target) (chmod target #o644))
      (else (error "Normalized firmware contains a link or special file" source))))
  (unless (and (string? archive) (string-prefix? "/" archive)
               (eq? 'regular (stat:type (lstat archive))))
    (error "Expected an absolute ordinary firmware archive" archive))
  (let ((parent (dirname destination)))
    (unless (and (string-prefix? "/" destination)
                 (not (member (basename destination) '("" "." ".."))))
      (error "Expected an absolute firmware destination" destination))
    (ordinary-directory (if (exists? parent) parent (dirname parent)))
    ;; Guix keeps temporary roots for this connection's lifetime. Register
    ;; the output explicitly, including a cached output, and keep the same
    ;; connection open through validation, copy and publication.
    (parameterize ((current-build-output-port (current-error-port)))
      (with-store store
        (set-build-options store)
        (let* ((prepared (prepared-apple-silicon-firmware (local-file archive)))
               (drv (run-with-store store (lower-object prepared)))
               (normalized-output (derivation->output-path drv))
               (firmware (string-append normalized-output "/firmware")))
          (add-temp-root store normalized-output)
          (build-derivations store (list drv))
          (when (exists? (string-append firmware "/" receipt-name))
            (error "Firmware archive collides with the installation receipt" receipt-name))
          (let* ((sha256
                  (call-with-input-file (string-append normalized-output "/origin.scm")
                    (lambda (port)
                      (let ((origin (read port)))
                        (unless (eof-object? (read port))
                          (error "Unexpected trailing firmware origin data"))
                        (match origin
                          (('apple-silicon-firmware-source ('version 1)
                             ('archive (? string? retained)) ('sha256 (? string? hash)))
                           (unless (string=? hash
                                             (bytevector->base16-string
                                              (file-sha256 archive)))
                             (error "The source firmware archive changed during preparation"))
                           hash)
                          (_ (error "Unexpected normalized firmware origin" origin)))))))
                 (staging
                  (begin
                    ;; The modern handoff needs no copied legacy helpers.
                    ;; Create only its immediate parent, under the already
                    ;; checked configuration directory, after validation.
                    (unless (exists? parent) (mkdir parent #o755))
                    (ordinary-directory parent)
                    (mkdtemp! (string-append parent "/.firmware-XXXXXX")))))
            (dynamic-wind
              (const #t)
              (lambda ()
                (for-each (lambda (name)
                            (copy-entry (string-append firmware "/" name)
                                        (string-append staging "/" name)))
                          (entries firmware))
                (call-with-output-file (string-append staging "/" receipt-name)
                  (lambda (port)
                    (write `(hello-guix-firmware-origin
                             (version 1)
                             (provider asahi-installer)
                             (archive "vendorfw/firmware.cpio")
                             (sha256 ,sha256)) port)
                    (newline port)))
                (chmod (string-append staging "/" receipt-name) #o644)
                (chmod staging #o755)
                (unless (string=? sha256 (bytevector->base16-string
                                          (file-sha256 archive)))
                  (error "The source firmware archive changed during handoff"))
                (if (exists? destination)
                    (unless (equal? (tree staging) (tree destination))
                      (error "Existing firmware differs from the prepared input" destination))
                    (begin
                      (rename-file staging destination)
                      (set! staging #f)))
                destination)
              (lambda ()
                (when staging (delete-file-recursively staging))))))))))
