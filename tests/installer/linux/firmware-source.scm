;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Build synthetic Asahi archive inputs; no devices or installed paths are used.
;; guix repl firmware-source.scm NEW-RECORDS [JOBS CORES [ARCHIVE]]

(use-modules (hello-guix installer linux firmware)
             (gnu build linux-initrd)
             (guix base16)
             (guix build utils)
             ((guix cpio) #:prefix cpio:)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix store)
             (gcrypt hash)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define (put file text)
  (mkdir-p (dirname file))
  (call-with-output-file file (lambda (port) (display text port))))
(define (contents file)
  (call-with-input-file file get-string-all))
(define (digest file)
  (bytevector->base16-string (file-sha256 file)))

(define (run directory jobs cores requested-archive)
  (define real-input
    (and requested-archive (not (string-null? requested-archive))
         (canonicalize-path requested-archive)))
  (define runner (test-runner-simple))

  ;; Use Guix's writer, including a header override for Asahi's data-first
  ;; hard-link representation. There is no fixture binary archive parser.
  (define (fixture name variant)
    (let* ((root (string-append directory "/" name))
           (archive (string-append directory "/" name ".cpio")))
      (mkdir root)
      (with-directory-excursion root
        (put "vendorfw/brcm/first.bin"
             (if (eq? variant 'changed-archive) "synthetic firmware C\n"
                 "synthetic firmware A\n"))
        (put "vendorfw/apple/second.bin" "synthetic firmware B\n")
        (define first-hash (digest "vendorfw/brcm/first.bin"))
        (define second-hash (digest "vendorfw/apple/second.bin"))
        (put "vendorfw/.vendorfw.manifest"
             (string-append
              "FILE brcm/first.bin SHA256 " first-hash "\n"
              "FILE apple/second.bin SHA256 " second-hash "\n"
              (if (eq? variant 'hardlinks)
                  "LINK brcm/linked.bin brcm/first.bin\nLINK apple/linked.bin apple/second.bin\n"
                  "")))
        (case variant
          ((hardlinks)
           (put "vendorfw/brcm/linked.bin" "")
           (put "vendorfw/apple/linked.bin" ""))
          ((missing-data) (put "vendorfw/brcm/first.bin" ""))
          ((missing-file) (delete-file "vendorfw/brcm/first.bin"))
          ((missing-manifest) (delete-file "vendorfw/.vendorfw.manifest"))
          ((extra-file) (put "vendorfw/unrecorded.bin" "unexpected\n"))
          ((receipt-collision)
           (put "vendorfw/.hello-guix-origin.scm" "archive supplied receipt\n")
           (put "vendorfw/.vendorfw.manifest"
                (string-append (contents "vendorfw/.vendorfw.manifest")
                               "FILE .hello-guix-origin.scm SHA256 "
                               (digest "vendorfw/.hello-guix-origin.scm") "\n")))
          ((symlink)
           (delete-file "vendorfw/brcm/first.bin")
           (symlink "../apple/second.bin" "vendorfw/brcm/first.bin"))
          ((unexpected-path) (put "outside.bin" "unexpected\n"))
          ((traversal)
           (put "../escape.bin" "outside source tree\n"))
          ((absolute)
           (put "absolute.bin" "outside archive namespace\n")))
        (define files
          (append
           (list "vendorfw" "vendorfw/apple" "vendorfw/brcm")
           (filter file-exists?
                   '("vendorfw/brcm/first.bin" "vendorfw/apple/second.bin"
                     "vendorfw/brcm/linked.bin" "vendorfw/apple/linked.bin"
                     "vendorfw/.vendorfw.manifest" "vendorfw/unrecorded.bin"
                     "vendorfw/.hello-guix-origin.scm"
                     "outside.bin"))
           (case variant
             ((traversal) '("vendorfw/../../escape.bin"))
             ((absolute) (list (string-append root "/absolute.bin")))
             (else '()))))
        ;; For traversal, the deliberately unsafe name resolves to this file.
        (when (eq? variant 'traversal)
          (put "../escape.bin" "outside source tree\n"))
        (define (header file)
          (if (and (eq? variant 'hardlinks)
                   (member file '("vendorfw/brcm/first.bin" "vendorfw/brcm/linked.bin"
                                  "vendorfw/apple/second.bin" "vendorfw/apple/linked.bin")))
              (cpio:make-cpio-header
               #:inode (if (string-prefix? "vendorfw/brcm/" file) 41 42)
               #:mode #o100644 #:nlink 2 #:size (stat:size (stat file))
               #:name-size (string-length file))
              (cpio:file->cpio-header file)))
        (call-with-output-file archive
          (lambda (port)
            (cpio:write-cpio-archive files port #:file->header header))
          #:binary #t))
      archive))

  (mkdir directory)
  (chdir directory)
  (test-runner-current runner)
  (test-begin "firmware-source")
  (test-error "preparation requires a file-like archive" #t
    (prepared-apple-silicon-firmware "firmware.cpio"))
  (test-assert "construction does not inspect a missing input"
    (file-like? (prepared-apple-silicon-firmware
                 (local-file (string-append directory "/not-present.cpio")))))


  (with-store store
    (apply set-build-options store
           (append (list #:use-substitutes? #f)
                   (if (string-null? jobs) '()
                       (list #:max-build-jobs (string->number jobs)))
                   (if (string-null? cores) '()
                       (list #:build-cores (string->number cores)))))
    (parameterize ((%graft? #f))
      (define (realize archive)
        (let* ((prepared (prepared-apple-silicon-firmware (local-file archive)))
               (result (computed-file "firmware-source-result"
                         #~(symlink #$prepared #$output)))
               (drv (run-with-store store (lower-object result))))
          (build-derivations store (list drv))
          (canonicalize-path (derivation->output-path drv))))
      (for-each
       (lambda (variant)
         (let* ((archive (fixture (symbol->string variant) variant))
                (before (digest archive))
                (firmware (realize archive))
                (origin (call-with-input-file
                            (string-append (dirname firmware) "/origin.scm") read)))
           (test-equal "first firmware bytes survive preparation"
             "synthetic firmware A\n" (contents (string-append firmware "/brcm/first.bin")))
           (test-equal "second firmware bytes survive preparation"
             "synthetic firmware B\n" (contents (string-append firmware "/apple/second.bin")))
           (test-equal "the upstream manifest is retained exactly"
             (contents (string-append directory "/" (symbol->string variant)
                                      "/vendorfw/.vendorfw.manifest"))
             (contents (string-append firmware "/.vendorfw.manifest")))
           (test-assert "new provenance is outside the firmware search root"
             (not (file-exists? (string-append firmware "/origin.scm"))))
           (test-equal "preparation leaves the source archive unchanged" before (digest archive))
           (match origin
             (('apple-silicon-firmware-source ('version 1)
                ('archive retained) ('sha256 hash))
              (test-equal "origin records the exact source checksum" before hash)
              (test-equal "origin retains the exact source bytes" before (digest retained)))
             (_ (test-assert "origin has the documented format" #f)))
           (when (eq? variant 'hardlinks)
             (for-each
              (lambda (pair)
                (let ((original (string-append firmware "/" (car pair)))
                      (linked (string-append firmware "/" (cdr pair))))
                  (test-equal "Asahi data-first hard links retain their bytes"
                    (contents original) (contents linked))))
              '(("brcm/first.bin" . "brcm/linked.bin")
                ("apple/second.bin" . "apple/linked.bin"))))))
       '(standard hardlinks))
      (for-each
       (lambda (variant)
         (let* ((archive (fixture (symbol->string variant) variant))
                (before (digest archive)))
           (test-error (string-append "reject " (symbol->string variant)) #t
             (realize archive))
           (test-equal "failed preparation leaves its source unchanged" before (digest archive))))
       '(missing-data missing-file missing-manifest extra-file symlink
                      unexpected-path traversal absolute))
      (let ((archive (string-append directory "/truncated.cpio")))
        (put archive "070701")
        (test-error "reject a truncated archive" #t (realize archive)))
      (let* ((archive (string-append directory "/hardlinks.cpio"))
             (etc (string-append directory "/handoff-etc"))
             (parent (string-append etc "/hello-guix"))
             (destination (string-append parent "/firmware"))
             (receipt (string-append destination "/.hello-guix-origin.scm")))
        (mkdir etc)
        (test-equal "production handoff creates the firmware directory"
          destination (prepare-installation-firmware archive destination))
        (test-equal "handoff creates only the missing immediate parent"
          '("hello-guix") (scandir etc (lambda (name) (not (member name '("." ".."))))))
        (for-each
         (lambda (pair)
           (test-equal "handoff materializes each firmware path"
             (cdr pair) (contents (string-append destination "/" (car pair)))))
         '(("brcm/first.bin" . "synthetic firmware A\n")
           ("brcm/linked.bin" . "synthetic firmware A\n")
           ("apple/second.bin" . "synthetic firmware B\n")
           ("apple/linked.bin" . "synthetic firmware B\n")))
        (test-equal "handoff preserves the upstream manifest"
          (contents (string-append directory "/hardlinks/vendorfw/.vendorfw.manifest"))
          (contents (string-append destination "/.vendorfw.manifest")))
        (test-equal "receipt contains only stable archive provenance"
          `(hello-guix-firmware-origin
            (version 1) (provider asahi-installer)
            (archive "vendorfw/firmware.cpio") (sha256 ,(digest archive)))
          (call-with-input-file receipt read))
        (let ((inode (stat:ino (stat destination)))
              (receipt-text (contents receipt)))
          (test-equal "an exact handoff retry succeeds"
            destination (prepare-installation-firmware archive destination))
          (test-equal "an exact retry reuses the existing directory"
            inode (stat:ino (stat destination)))
          (test-equal "an exact retry preserves its receipt"
            receipt-text (contents receipt))
          (put (string-append destination "/brcm/first.bin") "changed by user\n")
          (test-error "handoff refuses changed existing firmware" #t
            (prepare-installation-firmware archive destination))
          (test-equal "failed retry does not overwrite changed firmware"
            "changed by user\n" (contents (string-append destination "/brcm/first.bin")))
          (put (string-append destination "/brcm/first.bin") "synthetic firmware A\n")
          (put receipt "changed receipt\n")
          (test-error "handoff refuses a changed existing receipt" #t
            (prepare-installation-firmware archive destination))
          (test-equal "failed retry does not replace the existing receipt"
            "changed receipt\n" (contents receipt))
          (put receipt receipt-text)
          (let ((different (fixture "different-archive" 'changed-archive)))
            (test-error "handoff refuses a different valid archive" #t
              (prepare-installation-firmware different destination))
            (test-equal "different input leaves the existing receipt unchanged"
              receipt-text (contents receipt)))
          (let ((collision (fixture "receipt-collision" 'receipt-collision)))
            (test-error "archive cannot supply the reserved handoff receipt" #t
              (prepare-installation-firmware collision destination))
            (test-equal "receipt collision leaves existing firmware unchanged"
              "synthetic firmware A\n" (contents (string-append destination "/brcm/first.bin"))))
          (test-error "invalid source cannot replace existing firmware" #t
            (prepare-installation-firmware
             (string-append directory "/missing-data.cpio") destination))
          (test-equal "source failure preserves the existing receipt"
            receipt-text (contents receipt)))
        (let ((alias (string-append etc "/alias")))
          (symlink destination alias)
          (test-error "handoff rejects a destination symlink" #t
            (prepare-installation-firmware archive alias))
          (test-equal "rejected destination symlink is unchanged" destination (readlink alias)))
        (let ((alias (string-append etc "/linked-parent")))
          (symlink parent alias)
          (test-error "handoff rejects a destination parent symlink" #t
            (prepare-installation-firmware archive (string-append alias "/firmware"))))
        (let ((alias (string-append destination "/extra-link")))
          (link (string-append destination "/brcm/first.bin") alias)
          (test-error "handoff rejects hard links in the editable destination" #t
            (prepare-installation-firmware archive destination))
          (test-equal "failed handoff leaves the existing hard link alone" 2
            (stat:nlink (stat alias)))
          (delete-file alias))
        (let ((special (string-append destination "/unexpected-fifo")))
          (mknod special 'fifo #o600 0)
          (test-error "handoff rejects special files in the destination" #t
            (prepare-installation-firmware archive destination))
          (test-equal "failed handoff leaves the existing special file alone" 'fifo
            (stat:type (lstat special)))
          (delete-file special))
        (test-equal "handoff failures clean only their new staging directories"
          '("firmware")
          (scandir parent (lambda (name) (not (member name '("." "..")))))))
      ;; Optional read-only acceptance of the caller's explicit installation
      ;; archive. Realize only its normalized input; never activate a system.
      (when real-input
        (let* ((before (digest real-input))
               (firmware (realize real-input))
               (origin-file (string-append (dirname firmware) "/origin.scm"))
               (origin (call-with-input-file origin-file read)))
          (test-equal "real preparation leaves the explicit archive unchanged"
            before (digest real-input))
          (match origin
            (('apple-silicon-firmware-source ('version 1)
               ('archive retained) ('sha256 hash))
             (test-equal "real origin records the explicit archive checksum" before hash)
             (test-equal "real origin retains the explicit archive bytes" before (digest retained)))
            (_ (test-assert "real origin has the documented format" #f)))
          (let ((destination (string-append directory "/real-handoff/firmware")))
            (test-equal "real source passes the production handoff in fixture storage"
              destination (prepare-installation-firmware real-input destination))
            (test-equal "real handoff preserves the upstream manifest"
              (contents (string-append firmware "/.vendorfw.manifest"))
              (contents (string-append destination "/.vendorfw.manifest"))))
          (symlink firmware "real-firmware")
          (add-indirect-root store (string-append directory "/real-firmware"))
          (call-with-output-file "real-firmware.scm"
            (lambda (port)
              (write `(firmware-source-verification
                       (archive ,real-input)
                       (sha256 ,before)
                       (firmware ,firmware)
                       (origin ,origin)) port)
              (newline port)))))))
  (test-end "firmware-source")
  (exit (zero? (test-runner-fail-count runner))))

(match (command-line)
  ((_ directory)
   (run (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        "" "" #f))
  ((_ directory jobs cores)
   (run (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        jobs cores #f))
  ((_ directory jobs cores archive)
   (run (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        jobs cores archive))
  (_ (error "Usage: firmware-source.scm NEW-RECORDS [JOBS CORES [ARCHIVE]]")))
