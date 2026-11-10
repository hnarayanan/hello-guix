;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system firmware)
  #:use-module (gnu packages compression)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix base32)
  #:use-module ((guix build utils) #:select (find-files))
  #:use-module (guix gexp)
  #:use-module (guix hash)
  #:use-module (guix monads)
  #:use-module (guix modules)
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix store)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:export (apple-firmware
            apple-silicon-firmware
            apple-silicon-initrd
            initrd-with-firmware))

(define-record-type <apple-firmware>
  (%apple-firmware source hash)
  apple-firmware?
  (source apple-firmware-source)
  (hash apple-firmware-hash))

(define (check-firmware-hash source hash directory)
  ;; Match `guix hash -r`, including hidden files and VCS metadata. The
  ;; library's default selector would omit VCS directories.
  (unless (eq? 'directory (stat:type (lstat directory)))
    (error "Apple firmware input is not a directory" directory))
  (let ((found (file-hash* directory #:recursive? #t #:select? (const #t))))
    (unless (bytevector=? (content-hash-value hash) found)
      (let ((path (local-file-absolute-file-name source)))
        (error
         (format #f "Apple firmware hash mismatch~%Directory: ~a~%Declared: ~a~%Found: ~a~%To recompute: guix hash -r '~a'"
                 path
                 (bytevector->nix-base32-string (content-hash-value hash))
                 (bytevector->nix-base32-string found)
                 (string-join (string-split path #\') "'\\''"))))))
  ;; A NAR hashes link text, not external referents. Internal relative aliases
  ;; survive the move into the store; outside targets are not declared inputs.
  (for-each
   (lambda (link)
     (unless (and (not (string-prefix? "/" (readlink link)))
                  (let ((target (canonicalize-path link)))
                    (or (string=? directory target)
                        (string-prefix? (string-append directory "/") target))))
       (error "Apple firmware symlinks must be relative and stay within the declared directory"
              directory link)))
   (find-files directory (lambda (file info) (eq? 'symlink (stat:type info)))
               #:stat lstat)))

(define (checked-apple-firmware source hash)
  ;; Native content-hash checks literal lengths during expansion. Check
  ;; computed hash values too, before touching the directory or the store.
  (unless (and (eq? 'sha256 (content-hash-algorithm hash))
               (bytevector? (content-hash-value hash))
               (= 32 (bytevector-length (content-hash-value hash))))
    (error "Apple firmware requires a 32-byte SHA256 hash" hash))
  (check-firmware-hash source hash (local-file-absolute-file-name source))
  (%apple-firmware source hash))

(define-syntax apple-firmware
  (lambda (s)
    "Name a local firmware directory by its ordinary recursive SHA256 hash.
Resolve a literal relative path beside this declaration, as local-file does."
    (syntax-case s (sha256)
      ((_ directory (sha256 hash))
       (begin
         ;; Guix's decoder accepts unused high bits. A literal should be the
         ;; canonical spelling printed by `guix hash -r`, not a truncated one.
         (syntax-case #'hash (base32)
           ((base32 text)
            (string? (syntax->datum #'text))
            (let* ((text (syntax->datum #'text))
                   (bytes (nix-base32-string->bytevector text)))
              (unless (and (= 32 (bytevector-length bytes))
                           (string=? text (bytevector->nix-base32-string bytes)))
                (syntax-violation 'apple-firmware
                                  "expected a canonical SHA256 base32 hash" s))))
           (_ #t))
         #'(checked-apple-firmware (local-file directory #:recursive? #t)
                                   (content-hash hash sha256)))))))

(define-gexp-compiler (apple-firmware-compiler (firmware <apple-firmware>)
                                             system target)
  ;; Guix may reuse an earlier import of this path. Check the current source
  ;; before lowering, then verify the immutable imported copy to close the
  ;; serialization race. Keep local-file's exact store name and contents.
  (check-firmware-hash (apple-firmware-source firmware)
                       (apple-firmware-hash firmware)
                       (local-file-absolute-file-name (apple-firmware-source firmware)))
  (mlet %store-monad ((file (lower-object (apple-firmware-source firmware)
                                        system #:target target)))
    (check-firmware-hash (apple-firmware-source firmware)
                         (apple-firmware-hash firmware) file)
    (return file)))

(define apple-silicon-firmware
  (mlambda (source)
    "Expose the file-like firmware directory SOURCE in Guix's native layout.
SOURCE contains paths relative to the kernel's firmware search root. Keep
that exact input reachable through lib/firmware; do not extract archives or
inspect the machine evaluating the declaration."
    (when (let unpinned? ((input source))
            (or (local-file? input) (string? input)
                (and (file-append? input)
                     (unpinned? (file-append-base input)))))
      (error "Pin local Apple firmware with (apple-firmware \"hello-guix/firmware\" (sha256 (base32 \"…\")))"))
    (unless (file-like? source)
      (error "Apple Silicon firmware requires a file-like directory" source))
    (computed-file "apple-silicon-firmware"
      #~(begin
          (unless (eq? 'directory (stat:type (stat #$source)))
            (error "Apple Silicon firmware input is not a directory" #$source))
          (mkdir #$output)
          (mkdir (string-append #$output "/lib"))
          (symlink #$source (string-append #$output "/lib/firmware"))))))

(define (initrd-with-firmware initrd firmware)
  "Return INITRD with FIRMWARE available at /lib/firmware before /init runs.
FIRMWARE uses the ordinary Guix firmware package layout. Preserve INITRD's
bytes and runtime references; the kernel unpacks both cpio archives before
starting userspace."
  (define builder
    (with-imported-modules
        (source-module-closure '((gnu build linux-initrd)
                                (guix build utils))
          ;; The archive writer does not use store deduplication, whose
          ;; Guile-Gcrypt extension is absent from the native build Guile.
          #:select? (lambda (module)
                      (and (guix-module-name? module)
                           (not (equal? module '(guix store deduplication))))))
      #~(begin
          (use-modules (gnu build linux-initrd)
                       (guix build utils)
                       (ice-9 ftw))
          (define (copy-firmware source target ancestors)
            ;; Follow aliases, but fail on missing targets, special files or
            ;; directory cycles instead of silently producing a partial tree.
            (let* ((info (stat source))
                   (identity (cons (stat:dev info) (stat:ino info))))
              (case (stat:type info)
                ((directory)
                 (when (member identity ancestors)
                   (error "Firmware directory alias forms a cycle" source))
                 (mkdir target)
                 (for-each
                  (lambda (name)
                    (copy-firmware (string-append source "/" name)
                                   (string-append target "/" name)
                                   (cons identity ancestors)))
                  (scandir source
                           (lambda (name) (not (member name '("." "..")))))))
                ((regular) (copy-file source target))
                (else (error "Firmware input is not a regular file or directory"
                             source)))))
          (mkdir #$output)
          (mkdir-p "contents/lib")
          ;; Materialize the normalization symlink and any firmware aliases.
          ;; Every file is copied independently: the native cpio writer resets
          ;; inode numbers, so preserving separate hardlink groups is unsafe.
          (copy-firmware (string-append #$firmware "/lib/firmware")
                         "contents/lib/firmware" '())
          (with-directory-excursion "contents"
            (unless (write-cpio-archive
                     (string-append #$output "/firmware.cpio.gz") "."
                     #:gzip #+(file-append gzip "/bin/gzip"))
              (error "Could not compress the firmware initrd")))
          (call-with-output-file (string-append #$output "/initrd.img")
            (lambda (port)
              (for-each
               (lambda (file)
                 (call-with-input-file file
                   (lambda (input) (dump-port input port))
                   #:binary #t))
               (list #$initrd (string-append #$output "/firmware.cpio.gz"))))
            #:binary #t)
          (delete-file (string-append #$output "/firmware.cpio.gz"))
          ;; Store reference scanning cannot see references in gzip data.
          ;; Carry Guix's static Guile/runtime references forward without
          ;; retaining a second copy of the base image. For an initrd without
          ;; that metadata, conservatively retain its original store item.
          (call-with-output-file (string-append #$output "/references")
            (lambda (port)
              (let ((references (string-append (dirname #$initrd) "/references")))
                (if (file-exists? references)
                    (call-with-input-file references
                      (lambda (input) (dump-port input port)))
                    (display #$initrd port)))
              ;; Also retain the exact declared source independently of the
              ;; materialized firmware files in the compressed archive.
              (format port "~%~a~%" #$firmware))))))
  (file-append (computed-file "firmware-initrd" builder) "/initrd.img"))

(define apple-silicon-initrd
  (mlambda (firmware)
    "Return the ordinary Guix initrd constructor extended with FIRMWARE."
    (lambda arguments
      (initrd-with-firmware (apply base-initrd arguments) firmware))))
