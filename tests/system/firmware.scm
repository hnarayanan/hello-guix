;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Build only synthetic firmware and native provenance, then prepare replay.
;; guix repl firmware.scm FIXTURE NEW-RECORDS JOBS CORES

(use-modules (gnu packages base)
             (gnu services)
             (gnu services base)
             (gnu system)
             (guix build utils)
             (guix channels)
             (guix describe)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix store)
             (hello-guix system boot)
             (hello-guix system configuration-retention)
             (ice-9 match)
             (ice-9 textual-ports)
             (rnrs io ports)
             (srfi srfi-1))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-bytevector-all #:binary #t))

(define (load-declaration file)
  (save-module-excursion
   (lambda ()
     (set-current-module (make-fresh-user-module))
     (module-use! (current-module) (resolve-interface '(guix channels)))
     (primitive-load file))))

(define (firmware os)
  (match (operating-system-firmware os)
    ((input) input)
    (other (error "Expected only the explicitly supplied firmware" other))))

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
       (copy-file fixture (string-append name "/config.scm"))
       (call-with-output-file (string-append input "/brcm/fixture.bin")
         (lambda (port) (put-bytevector port bytes)) #:binary #t)
       (call-with-output-file (string-append input "/manifest.txt")
         (lambda (port) (display "Synthetic test input; no Apple firmware.\n" port)))))
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
  (let* ((base (load-declaration original))
         (other (load-declaration changed))
         (package-edit
          (operating-system (inherit base)
            (packages (cons hello (operating-system-packages base)))))
         (hostname-edit (operating-system (inherit base) (host-name "renamed-fixture"))))
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
        (let* ((normalized (lower (firmware base)))
               (changed-normalized (lower (firmware other)))
               (base-system (derive base))
               (fixed-hardware (hardware base))
               (system (derive (operating-system-with-provenance base original)))
               (provenance
                (run-with-store store
                  (service-value
                   (fold-services
                    (list (service system-service-type '())
                          (service provenance-service-type original))))))
               (output (derivation->output-path normalized))
               (changed-output (derivation->output-path changed-normalized))
               (saved (derivation->output-path provenance))
               (support (lower (configuration-source original)))
               (support-output (derivation->output-path support)))
          (for-each
           (lambda (edited)
             (check "Personal edits preserve kernel and boot inputs"
                    fixed-hardware (hardware edited))
             (check "Personal edits preserve the firmware derivation"
                    (derivation-file-name normalized)
                    (derivation-file-name (lower (firmware edited))))
             (check "Personal edits change the system derivation" #f
                    (string=? (derivation-file-name base-system)
                              (derivation-file-name (derive edited)))))
           (list package-edit hostname-edit))
          (check "Firmware changes preserve kernel and boot inputs"
                 fixed-hardware (hardware other))
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
          (build-derivations store (list normalized changed-normalized provenance support))
          (retain "normalized" output)
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
          (let* ((retained (canonicalize-path (string-append output "/lib/firmware")))
                 (input (lower (local-file (string-append directory "/working/hello-guix/firmware")
                                          #:recursive? #t))))
            (check "Normalized output uses the exact declared directory" input retained)
            (check "The normalized closure retains the input" #t
                   (and (member input (requisites store (list output))) #t))
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
                (write `((retained-input . ,retained) (normalized . ,output)
                         (changed-normalized . ,changed-output)
                         (hardware . ,fixed-hardware)) port)
                (newline port))))))))
  (display "Declared firmware bytes, references and configuration changes verified.\n")
  (display "Recovery declaration and relative firmware input are ready for fresh-process replay.\n"))

(match (cdr (command-line))
  ((fixture directory jobs cores)
   (run (canonicalize-path fixture)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        jobs cores))
  (_ (error "Usage: firmware.scm FIXTURE NEW-RECORDS JOBS CORES")))
