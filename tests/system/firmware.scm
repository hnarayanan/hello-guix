;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Build only synthetic firmware and native provenance, then prepare replay.
;; guix repl firmware.scm FIXTURE NEW-RECORDS JOBS CORES

(use-modules (gnu packages base)
             (gnu packages compression)
             (gnu services)
             (gnu services base)
             (gnu system)
             (guix build utils)
             (guix channels)
             (guix describe)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix modules)
             (guix packages)
             (guix store)
             (hello-guix apple-silicon)
             (hello-guix system boot)
             (hello-guix system configuration-retention)
             (hello-guix system firmware)
             (ice-9 match)
             (ice-9 textual-ports)
             (ice-9 popen)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-bytevector-all #:binary #t))

(define* (load-declaration file #:optional (bindings '()))
  (save-module-excursion
   (lambda ()
     (set-current-module (make-fresh-user-module))
     (module-use! (current-module) (resolve-interface '(guix channels)))
     (let ((result (primitive-load file)))
       (if (null? bindings) result
           (cons result (map (lambda (name) (module-ref (current-module) name))
                             bindings)))))))

(define (directory-hash directory)
  ;; Compare against the actual user command, not a second copy of its helper.
  (let* ((port (open-pipe* OPEN_READ (string-append (current-profile) "/bin/guix")
                         "hash" "-r" directory))
         (result (string-trim-right (get-string-all port))))
    (check "The selected Guix hashes the fixture successfully" 0 (close-pipe port))
    (check "Guix prints a recursive SHA-256 in base32" 52 (string-length result))
    result))

(define (write-declaration fixture target hash)
  (copy-file fixture target)
  (substitute* target (("@FIRMWARE_SHA256@") hash)))

(define (write-bytes file bytes)
  (call-with-output-file file
    (lambda (port) (put-bytevector port bytes)) #:binary #t))

(define (refusal-message thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda (key . arguments)
      (call-with-output-string
        (lambda (port) (print-exception port #f key arguments))))))

(define (expect-invalid-input message thunk)
  (let ((diagnostic (refusal-message thunk)))
    (unless (and (string? diagnostic)
                 (not (string-contains diagnostic "Apple firmware hash mismatch")))
      (error message "diagnostic" diagnostic))))

(define (expect-refusal message thunk . fragments)
  (let ((diagnostic (refusal-message thunk)))
    (unless (and (string? diagnostic)
                 (every (lambda (fragment) (string-contains diagnostic fragment))
                        fragments))
      (error message "diagnostic" diagnostic "required" fragments))))

(define (unhashed-firmware source)
  ;; Freeze the former wrapper to test derivation identity across this change.
  ;; Production deliberately provides no way to bypass the declared hash.
  (computed-file "apple-silicon-firmware"
    #~(begin
        (unless (eq? 'directory (stat:type (stat #$source)))
          (error "Apple Silicon firmware input is not a directory" #$source))
        (mkdir #$output)
        (mkdir (string-append #$output "/lib"))
        (symlink #$source (string-append #$output "/lib/firmware")))))

(define (firmware os)
  ;; The free AVD firmware is an independent ordinary package. Isolate the
  ;; explicit Apple input whose byte retention and early loading we test here.
  (match (filter (lambda (input)
                   (and (computed-file? input)
                        (string=? "apple-silicon-firmware"
                                  (computed-file-name input))))
                 (operating-system-firmware os))
    ((input) input)
    (other (error "Expected exactly one explicit Apple Silicon firmware input" other))))

(define (synthetic-initrd)
  ;; A real native archive with a reference outside its compressed contents.
  ;; This isolates archive construction from kernel and static Guile builds.
  (file-append
   (computed-file "firmware-test-initrd"
     (with-imported-modules
         (source-module-closure '((gnu build linux-initrd) (guix build utils))
           #:select? (lambda (module)
                       (and (guix-module-name? module)
                            (not (equal? module '(guix store deduplication))))))
       #~(begin
           (use-modules (gnu build linux-initrd) (guix build utils))
           (mkdir #$output)
           (mkdir "contents")
           (call-with-output-file "contents/init"
             (lambda (port) (display "Synthetic base initrd.\n" port)))
           (call-with-output-file (string-append #$output "/references")
             (lambda (port)
               (display #$(plain-file "initrd-runtime-reference" "Retain me.\n") port)
               (newline port)))
           (with-directory-excursion "contents"
             (unless (write-cpio-archive
                      (string-append #$output "/initrd.cpio.gz") "."
                      #:gzip #+(file-append gzip "/bin/gzip"))
               (error "Could not build the synthetic initrd"))))))
   "/initrd.cpio.gz"))

(define (slice bytes start end)
  (let ((result (make-bytevector (- end start))))
    (bytevector-copy! bytes start result 0 (- end start))
    result))

(define (cpio-entries file gzip)
  ;; Read both complete newc archives independently of the archive writer.
  ;; Ordinary cpio extraction stops at the first TRAILER!!! member.
  (let* ((port (open-pipe* OPEN_READ gzip "-dc" file))
         (bytes (get-bytevector-all port)))
    (define (align offset) (* 4 (quotient (+ offset 3) 4)))
    (define (field start) (string->number (utf8->string (slice bytes start (+ start 8))) 16))
    (check "All gzip members decompress successfully" 0 (close-pipe port))
    (let loop ((offset 0) (entries '()))
      (cond
       ((= offset (bytevector-length bytes)) (reverse entries))
       ((zero? (bytevector-u8-ref bytes offset)) (loop (+ offset 1) entries))
       (else
        (check "Initrd members use the kernel's newc format" "070701"
               (utf8->string (slice bytes offset (+ offset 6))))
        (let* ((size (field (+ offset 54)))
               (name-size (field (+ offset 94)))
               (name (utf8->string (slice bytes (+ offset 110)
                                         (+ offset 109 name-size))))
               (data (align (+ offset 110 name-size)))
               (next (align (+ data size))))
          (loop next (cons (cons name (slice bytes data (+ data size))) entries))))))))

(define (run fixture directory jobs cores)
  (define original (string-append directory "/working/config.scm"))
  (define changed (string-append directory "/changed/config.scm"))
  (define original-bytes #vu8(0 1 2 255))
  (define changed-bytes #vu8(0 1 3 255))
  (mkdir directory)
  (chdir directory)
  (for-each
   (lambda (name bytes)
     (let ((input (string-append name "/hello-guix/firmware")))
       (mkdir-p (string-append input "/brcm"))
       (write-bytes (string-append input "/brcm/fixture.bin") bytes)
       (symlink "fixture.bin" (string-append input "/brcm/alias.bin"))
       (call-with-output-file (string-append input "/manifest.txt")
         (lambda (port) (display "Synthetic test input; no Apple firmware.\n" port)))
       (call-with-output-file (string-append input "/.hello-guix-origin.scm")
         (lambda (port) (display "((fixture . original))\n" port)))
       ;; Guix's command hashes VCS files too; the library default excludes them.
       (mkdir (string-append input "/.git"))
       (call-with-output-file (string-append input "/.git/fixture")
         (lambda (port) (display "Synthetic VCS entry.\n" port)))
       (write-declaration fixture (string-append name "/config.scm")
                          (directory-hash input))))
   '("working" "changed") (list original-bytes changed-bytes))
  (call-with-output-file "working/channels.scm"
    (lambda (port)
      (write `(list ,@(map channel->code (current-channels))) port)
      (newline port)))
  (mkdir-p "working/hello-guix/modules/firmware")
  (for-each
   (lambda (file)
     (call-with-output-file file
       (lambda (port) (display ";; Synthetic support source.\n" port))))
   '("working/hello-guix/modules/fixture.scm"
     "working/hello-guix/modules/firmware/keep.scm"))
  (let* ((loaded (load-declaration original '(firmware-input my-system)))
         (base (car loaded))
         (pinned-input (cadr loaded))
         (ordinary (caddr loaded))
         (input-directory (string-append directory "/working/hello-guix/firmware"))
         (declared-hash (directory-hash input-directory))
         (raw-input (local-file input-directory #:recursive? #t))
         (legacy ((@@ (hello-guix system hardware) adapt-system)
                  ordinary (unhashed-firmware raw-input) #f #f))
         (repeated (on-apple-silicon base #:firmware pinned-input #:audio? #f))
         (other (load-declaration changed))
         (package-edit
          (operating-system (inherit base)
            (packages (cons hello (operating-system-packages base)))))
         (hostname-edit (operating-system (inherit base) (host-name "renamed-fixture"))))
    ;; All these failures happen during declaration evaluation, before a store
    ;; connection or any build. The declaration lives under working/, not cwd.
    (define (reject-change message change restore)
      (dynamic-wind
        change
        (lambda ()
          (let ((found (directory-hash input-directory)))
            (check "A changed fixture has a different native hash" #f
                   (string=? declared-hash found))
            (expect-refusal message (lambda () (load-declaration original))
                            declared-hash found input-directory "guix hash -r")))
        restore))
    (let ((file (string-append input-directory "/brcm/fixture.bin")))
      (reject-change "A changed firmware byte is refused before building"
                     (lambda () (write-bytes file changed-bytes))
                     (lambda () (write-bytes file original-bytes))))
    (let ((file (string-append input-directory "/added.bin")))
      (reject-change "An added file is refused before building"
                     (lambda () (write-bytes file changed-bytes))
                     (lambda () (delete-file file))))
    (let* ((file (string-append input-directory "/manifest.txt"))
           (bytes (contents file)))
      (reject-change "A removed file is refused before building"
                     (lambda () (delete-file file))
                     (lambda () (write-bytes file bytes))))
    (for-each
     (lambda (name)
       (let* ((file (string-append input-directory "/" name))
              (bytes (contents file)))
         (reject-change (string-append "Changed hidden content is refused: " name)
                        (lambda () (write-bytes file changed-bytes))
                        (lambda () (write-bytes file bytes)))))
     '(".hello-guix-origin.scm" ".git/fixture"))
    (for-each
     (lambda (hash)
       (write-declaration fixture "working/malformed.scm" hash)
       (expect-invalid-input "A malformed literal hash is refused during evaluation"
                       (lambda () (load-declaration "working/malformed.scm")))
       (delete-file "working/malformed.scm"))
     (list "not-a-sha256" (make-string 53 #\0) (make-string 52 #\e)
           ;; Change unused high bits without changing the decoded SHA256.
           (string-append (if (char=? #\0 (string-ref declared-hash 0)) "2" "3")
                          (substring declared-hash 1))))
    (expect-invalid-input "A malformed dynamic hash is refused during evaluation"
                    (lambda ()
                      (apple-firmware input-directory (sha256 (make-bytevector 31 0)))))
    (for-each
     (lambda (input)
       (expect-refusal "A bare local directory requests a declared hash"
                       (lambda () (on-apple-silicon ordinary #:firmware input #:audio? #f))
                       "apple-firmware" "sha256" "base32"))
     (list raw-input input-directory
           (file-append raw-input "")
           (file-append (file-append raw-input "/brcm") "")))
    (let ((alias (string-append input-directory "/brcm/unsafe-alias.bin")))
      (write-bytes "working/outside.bin" original-bytes)
      (for-each
       (lambda (target)
         (dynamic-wind
           (lambda () (symlink target alias))
           (lambda ()
             (write-declaration fixture "working/unsafe-alias.scm"
                                (directory-hash input-directory))
             (expect-invalid-input "A matching hash cannot pin an unsafe firmware alias"
                                   (lambda () (load-declaration
                                               (string-append directory
                                                              "/working/unsafe-alias.scm")))))
           (lambda () (delete-file alias))))
       (list "../../../outside.bin" "missing.bin"
             (string-append input-directory "/brcm/fixture.bin")))
      (delete-file "working/outside.bin")
      (delete-file "working/unsafe-alias.scm"))
    (check "Restoring the fixture restores the exact native hash"
           declared-hash (directory-hash input-directory))
    (with-store store
      (apply set-build-options store
             (append (list #:use-substitutes? #f)
                     (if (string-null? jobs) '()
                         (list #:max-build-jobs (string->number jobs)))
                     (if (string-null? cores) '()
                         (list #:build-cores (string->number cores)))))
      (parameterize ((%graft? #f))
        (define (lower object)
          (run-with-store store (lower-object object)))
        (define (derive os)
          (run-with-store store (operating-system-derivation os)))
        (define (hardware os)
          (map (lambda (object) (derivation-file-name (lower object)))
               (list (operating-system-kernel os)
                     (asahi-boot-bundle (operating-system-kernel os)))))
        (define (retain root output)
          (symlink output root)
          (add-indirect-root store (string-append directory "/" root)))
        (let* ((raw-store-path (lower raw-input))
               (pinned-store-path (lower pinned-input))
               (base-initrd-file (synthetic-initrd))
               (base-initrd (lower base-initrd-file))
               (combined (lower (initrd-with-firmware base-initrd-file (firmware base))))
               (changed-combined (lower (initrd-with-firmware base-initrd-file (firmware other))))
               (normalized (lower (firmware base)))
               (legacy-normalized (lower (unhashed-firmware raw-input)))
               (changed-normalized (lower (firmware other)))
               (base-system (derive base))
               (legacy-system (derive legacy))
               (repeated-system (derive repeated))
               (fixed-hardware (hardware base))
               (system (derive (operating-system-with-provenance base original)))
               (provenance
                (run-with-store store
                  (service-value
                   (fold-services
                    (list (service system-service-type '())
                          (service provenance-service-type original))))))
               (normalized-output (derivation->output-path normalized))
               (changed-output (derivation->output-path changed-normalized))
               (saved (derivation->output-path provenance))
               (support (lower (configuration-source original)))
               (support-output (derivation->output-path support)))
          (check "Pinning preserves the former local-file store path"
                 raw-store-path pinned-store-path)
          (check "Pinning preserves the former firmware derivation"
                 (derivation-file-name legacy-normalized)
                 (derivation-file-name normalized))
          (check "Pinning preserves the former complete system derivation"
                 (derivation-file-name legacy-system)
                 (derivation-file-name base-system))
          (check "Repeated pinned adaptation preserves the system derivation"
                 (derivation-file-name base-system)
                 (derivation-file-name repeated-system))
          (let* ((cached (cadr (load-declaration original '(firmware-input))))
                 (file (string-append input-directory "/brcm/fixture.bin")))
            (dynamic-wind
              (lambda () (write-bytes file changed-bytes))
              (lambda ()
                (expect-refusal "Lowering rechecks bytes changed after construction"
                                (lambda () (lower cached))
                                declared-hash (directory-hash input-directory)
                                input-directory "guix hash -r"))
              (lambda () (write-bytes file original-bytes))))
          (for-each
           (lambda (edited)
             (check "Personal edits preserve kernel and boot inputs"
                    fixed-hardware (hardware edited))
             (check "Personal edits preserve the initrd derivation"
                    (derivation-file-name (lower (operating-system-initrd-file base)))
                    (derivation-file-name (lower (operating-system-initrd-file edited))))
             (check "Personal edits preserve the firmware derivation"
                    (derivation-file-name normalized)
                    (derivation-file-name (lower (firmware edited))))
             (check "Personal edits change the system derivation" #f
                    (string=? (derivation-file-name base-system)
                              (derivation-file-name (derive edited)))))
           (list package-edit hostname-edit))
          (check "Firmware changes preserve kernel and boot inputs"
                 fixed-hardware (hardware other))
          (check "Changed bytes change the initrd derivation" #f
                 (string=?
                  (derivation-file-name (lower (operating-system-initrd-file base)))
                  (derivation-file-name (lower (operating-system-initrd-file other)))))
          (check "Changed bytes change the archive derivation" #f
                 (string=? (derivation-file-name combined)
                           (derivation-file-name changed-combined)))
          (check "Changed bytes change the firmware derivation" #f
                 (string=? (derivation-file-name normalized)
                           (derivation-file-name changed-normalized)))
          (check "Changed bytes change the system derivation" #f
                 (string=? (derivation-file-name base-system)
                           (derivation-file-name (derive other))))
          ;; This visits declared references; it does not build the system.
          (check "The system derivation retains the firmware dependency" #t
                 (and (member (derivation-file-name normalized)
                              (requisites store (list (derivation-file-name system)))) #t))
          (build-derivations store
                             (list normalized changed-normalized provenance support
                                   combined changed-combined))
          (let* ((combined-output (derivation->output-path combined))
                 (base-output (derivation->output-path base-initrd))
                 (gzip-command (string-append (derivation->output-path (lower gzip)) "/bin/gzip"))
                 (archive (string-append combined-output "/initrd.img"))
                 (entries (cpio-entries archive gzip-command))
                 (changed-entries
                  (cpio-entries (string-append (derivation->output-path changed-combined)
                                              "/initrd.img") gzip-command))
                 (base-bytes (contents (string-append base-output "/initrd.cpio.gz"))))
            (retain "initrd" combined-output)
            (retain "changed-initrd" (derivation->output-path changed-combined))
            (check "The ordinary initrd remains byte-for-byte intact" base-bytes
                   (slice (contents archive) 0 (bytevector-length base-bytes)))
            (check "The original init program occurs once" 1
                   (count (lambda (entry) (string=? (car entry) "./init")) entries))
            (check "Both archive trailers survive" 2
                   (count (lambda (entry) (string=? (car entry) "TRAILER!!!")) entries))
            (check "Firmware is present before init at the kernel search path"
                   original-bytes (assoc-ref entries "./lib/firmware/brcm/fixture.bin"))
            (check "Firmware aliases are materialized for early boot"
                   original-bytes (assoc-ref entries "./lib/firmware/brcm/alias.bin"))
            (check "Changed firmware reaches the archive"
                   changed-bytes (assoc-ref changed-entries "./lib/firmware/brcm/fixture.bin"))
            (check "The archive retains the exact normalized input" #t
                   (and (member normalized-output (requisites store (list combined-output))) #t))
            (check "The archive retains the ordinary initrd runtime reference" #t
                   (and (member (string-trim-right
                                 (call-with-input-file (string-append base-output "/references")
                                   get-string-all))
                                (requisites store (list combined-output))) #t)))
          (for-each
           (lambda (invalid)
             (let ((drv (lower (initrd-with-firmware
                                base-initrd-file (apple-silicon-firmware invalid)))))
               (check "Invalid firmware cannot produce a partial early archive" #t
                      (catch #t
                        (lambda () (build-derivations store (list drv)) #f)
                        (lambda arguments #t)))))
           (list (plain-file "not-a-firmware-directory" "invalid\n")
                 (computed-file "broken-firmware-alias"
                   #~(begin (mkdir #$output)
                            (symlink "missing" (string-append #$output "/alias"))))
                 (computed-file "cyclic-firmware-alias"
                   #~(begin (mkdir #$output)
                            (symlink "." (string-append #$output "/cycle"))))))
          (retain "normalized" normalized-output)
          (retain "changed-normalized" changed-output)
          (retain "provenance" saved)
          (retain "source-support" support-output)
          (for-each
           (lambda (name)
             (check "Source recovery retains configuration and ordinary support"
                    (contents (string-append "working/" name))
                    (contents (string-append support-output "/" name))))
           '("config.scm" "channels.scm" "hello-guix/modules/fixture.scm"
             "hello-guix/modules/firmware/keep.scm"))
          (check "Source recovery excludes only the declared firmware subtree" #f
                 (file-exists? (string-append support-output "/hello-guix/firmware")))
          (let* ((retained (canonicalize-path (string-append normalized-output "/lib/firmware")))
                 (input (lower (local-file (string-append directory "/working/hello-guix/firmware")
                                          #:recursive? #t))))
            (check "Normalized output uses the exact declared directory" input retained)
            (check "The normalized closure retains the input" #t
                   (and (member input (requisites store (list normalized-output))) #t))
            (check "Original firmware bytes are unchanged" original-bytes
                   (contents (string-append retained "/brcm/fixture.bin")))
            (check "Changed firmware bytes are distinct" changed-bytes
                   (contents (string-append changed-output "/lib/firmware/brcm/fixture.bin")))
            (check "The input manifest is retained"
                   (contents "working/hello-guix/firmware/manifest.txt")
                   (contents (string-append retained "/manifest.txt")))
            (check "Native provenance preserves the declaration"
                   (contents original) (contents (string-append saved "/configuration.scm")))
            (check "Native provenance preserves exact channels"
                   (map channel->code (current-channels))
                   (map channel->code (load-declaration (string-append saved "/channels.scm"))))
            ;; Restore ordinary files at the declaration's original relative path.
            ;; Native provenance alone does not carry neighbouring firmware data.
            (mkdir-p "recovery/hello-guix")
            (copy-file (string-append saved "/configuration.scm") "recovery/config.scm")
            (check "Recovered declaration is an ordinary file" 'regular
                   (stat:type (lstat "recovery/config.scm")))
            (copy-recursively retained "recovery/hello-guix/firmware" #:log #f)
            (rename-file "working" "working-unavailable")
            (rename-file "changed" "changed-unavailable")
            (check "Original declaration is unavailable" #f (file-exists? original))
            (check "Original input is unavailable" #f
                   (file-exists? (string-append directory "/working/hello-guix/firmware")))
            (call-with-output-file "expected.drv"
              (lambda (port) (display (derivation-file-name system) port) (newline port)))
            (call-with-output-file "inputs.scm"
              (lambda (port)
                (write `((firmware-sha256 . ,declared-hash)
                         (unpinned-input . ,raw-store-path)
                         (pinned-input . ,pinned-store-path)
                         (unpinned-firmware . ,(derivation-file-name legacy-normalized))
                         (pinned-firmware . ,(derivation-file-name normalized))
                         (unpinned-system . ,(derivation-file-name legacy-system))
                         (pinned-system . ,(derivation-file-name base-system))
                         (repeated-system . ,(derivation-file-name repeated-system))
                         (retained-input . ,retained) (normalized . ,normalized-output)
                         (changed-normalized . ,changed-output)
                         (hardware . ,fixed-hardware)) port)
                (newline port))))))))
  (display "Native firmware hashes, early refusal, unchanged derivations and archives verified.\n")
  (display "Recovery declaration and relative firmware input are ready for fresh-process replay.\n"))

(match (cdr (command-line))
  ((fixture directory jobs cores)
   (run (canonicalize-path fixture)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        jobs cores))
  (_ (error "Usage: firmware.scm FIXTURE NEW-RECORDS JOBS CORES")))
