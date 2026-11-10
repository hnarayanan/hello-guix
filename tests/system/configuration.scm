;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Check a reviewed declaration with its selected complete channel profile.
;; guix repl configuration.scm CONFIG NEW-RECORDS JOBS CORES

(use-modules (gnu services)
             (gnu services base)
             (gnu system)
             (guix build utils)
             (guix channels)
             (guix describe)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix profiles)
             (guix store)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (load-declaration file)
  (save-module-excursion
   (lambda ()
     (set-current-module (make-fresh-user-module))
     (module-use! (current-module) (resolve-interface '(guix channels)))
     (primitive-load file))))

(define (run configuration directory jobs cores)
  (define profile (current-profile))
  (define selected (current-channels))
  (define hello-entry
    (and profile
         (find (lambda (entry)
                 (let ((channel (manifest-entry-channel entry)))
                   (and channel (eq? 'hello-guix (channel-name channel)))))
               (manifest-entries (profile-manifest profile)))))
  (unless hello-entry
    (error "Select a complete channel profile containing Hello Guix"))
  (mkdir directory)
  (chdir directory)
  (mkdir-p "working/hello-guix")
  (copy-file configuration "working/config.scm")
  (unless (copy-recursively
           (string-append (dirname configuration) "/hello-guix/firmware")
           "working/hello-guix/firmware" #:log #f)
    (error "Could not copy the declaration's prepared firmware"))
  (let* ((file (string-append directory "/working/config.scm"))
         (os (load-declaration file))
         (firmware
          (match (filter (lambda (input)
                           (and (computed-file? input)
                                (string=? "apple-silicon-firmware"
                                          (computed-file-name input))))
                         (operating-system-firmware os))
            ((input) input)
            (_ (error "Expected exactly one explicit Apple Silicon firmware input"))))
         (daemon
          (match (filter (lambda (entry) (eq? guix-service-type (service-kind entry)))
                         (operating-system-user-services os))
            ((entry) (service-value entry))
            (_ (error "Expected one Guix service")))))
    ;; Followed defaults belong to the reviewed declaration. The evaluator's
    ;; exact channels are retained separately in native provenance.
    (call-with-output-file "future-channels.scm"
      (lambda (port)
        (write `(list ,@(map channel->code (guix-configuration-channels daemon))) port)
        (newline port)))
    (call-with-output-file "module-origins.scm"
      (lambda (port)
        (for-each
         (lambda (relative)
           (let* ((output (manifest-entry-item hello-entry))
                  (source (canonicalize-path
                           (string-append output "/share/guile/site/"
                                          (effective-version) "/" relative ".scm")))
                  (compiled (canonicalize-path
                             (string-append output "/lib/guile/" (effective-version)
                                            "/site-ccache/" relative ".go"))))
             (check "Hello source resolves through the selected channel" source
                    (canonicalize-path (search-path %load-path
                                                    (string-append relative ".scm"))))
             (check "Hello bytecode resolves through the selected channel" compiled
                    (canonicalize-path (search-path %load-compiled-path
                                                    (string-append relative ".go"))))
             (write (list relative source compiled) port)
             (newline port)))
         '("hello-guix/apple-silicon" "hello-guix/system/audio"
           "hello-guix/system/boot-files" "hello-guix/system/boot"
           "hello-guix/system/firmware" "hello-guix/system/hardware"
           "hello-guix/system/runtime"))))
    (with-store store
      (define (retain name output)
        (symlink output name)
        (add-indirect-root store (string-append directory "/" name)))
      (apply set-build-options store
             (append (list #:use-substitutes? #f)
                     (if (string-null? jobs) '()
                         (list #:max-build-jobs (string->number jobs)))
                     (if (string-null? cores) '()
                         (list #:build-cores (string->number cores)))))
      (retain "profile" (canonicalize-path profile))
      ;; This compares structure and replay. Native system build commands use
      ;; normal grafts when separately previewing or building the candidate.
      (parameterize ((%graft? #f))
        (let* ((system (run-with-store store
                         (operating-system-derivation
                          (operating-system-with-provenance os file))))
               (evaluator (run-with-store store
                            (lower-object (guix-configuration-guix daemon))))
               (normalized (run-with-store store (lower-object firmware)))
               (declared (run-with-store store
                           (lower-object
                            (local-file
                             (string-append directory "/working/hello-guix/firmware")
                             #:recursive? #t))))
               (provenance
                (run-with-store store
                  (service-value
                   (fold-services
                    (list (service system-service-type '())
                          (service provenance-service-type file))))))
               (saved (derivation->output-path provenance)))
          (check "System retains its explicit firmware dependency" #t
                 (and (member (derivation-file-name normalized)
                              (requisites store (list (derivation-file-name system)))) #t))
          (check "System retains its selected evaluator dependency" #t
                 (and (member (derivation-file-name evaluator)
                              (requisites store (list (derivation-file-name system)))) #t))
          ;; These small wrappers retain already supplied inputs. The complete
          ;; system derivation is deliberately not among the build targets.
          (build-derivations store (list evaluator normalized provenance))
          (check "Installed Guix retains the complete evaluating profile"
                 (canonicalize-path profile)
                 (canonicalize-path (derivation->output-path evaluator)))
          (check "Native provenance retains the reviewed declaration"
                 (contents file) (contents (string-append saved "/configuration.scm")))
          (check "Native provenance retains exact selected channels and trust"
                 (map channel->code selected)
                 (map channel->code
                      (load-declaration (string-append saved "/channels.scm"))))
          (call-with-output-file "system.drv"
            (lambda (port) (display (derivation-file-name system) port) (newline port)))
          (retain "derivation" (derivation-file-name system))
          (retain "provenance" saved)
          (let* ((normalized-output (derivation->output-path normalized))
                 (retained (canonicalize-path
                            (string-append normalized-output "/lib/firmware"))))
            (check "Firmware uses the declaration's explicit relative directory" declared retained)
            (check "Firmware closure retains its exact declared input" #t
                   (and (member retained (requisites store (list normalized-output))) #t))
            (retain "normalized-firmware" normalized-output)
            (mkdir-p "recovery/hello-guix")
            (copy-file (string-append saved "/configuration.scm") "recovery/config.scm")
            (unless (copy-recursively retained "recovery/hello-guix/firmware" #:log #f)
              (error "Could not restore the retained firmware for replay")))
          (rename-file "working" "working-unavailable")
          (check "Working declaration is unavailable" #f (file-exists? file))
          (check "Working firmware is unavailable" #f
                 (file-exists? (string-append directory "/working/hello-guix/firmware")))))))
  (display "Reviewed declaration, explicit firmware, evaluator and native provenance verified.\n"))

(match (cdr (command-line))
  ((configuration directory jobs cores)
   (run (canonicalize-path configuration)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))
        jobs cores))
  (_ (error "Usage: configuration.scm CONFIG NEW-RECORDS JOBS CORES")))
