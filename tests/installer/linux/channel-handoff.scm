;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Evaluate a real writer output with its authenticated channel profile.
;; guix repl channel-handoff.scm GENERATED-CONFIG NEW-RECORDS-DIRECTORY
;; The caller authenticates the profile first. This checks the declaration
;; handoff; it builds only evaluator/provenance components, not the system.

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
             (srfi srfi-1))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (channel-codes-by-name channels)
  ;; Describe output and profile manifests can enumerate the same channels in
  ;; different orders. The future policy names the same distinct inputs.
  (map channel->code
       (sort channels
             (lambda (left right)
               (string<? (symbol->string (channel-name left))
                         (symbol->string (channel-name right)))))))

(define (load-declaration file)
  (save-module-excursion
   (lambda ()
     (set-current-module (make-fresh-user-module))
     (module-use! (current-module) (resolve-interface '(guix channels)))
     (primitive-load file))))

(define (run fixture directory)
  (define profile (current-profile))
  (define selected (current-channels))
  (define hello-entry
    (and profile
         (find (lambda (entry)
                 (let ((channel (manifest-entry-channel entry)))
                   (and channel (eq? 'hello-guix (channel-name channel)))))
               (manifest-entries (profile-manifest profile)))))
  (unless (and hello-entry (every channel-introduction selected))
    (error "Expected a selected channel profile with Hello and trust introductions"))
  (mkdir directory)
  (chdir directory)
  (mkdir "working")
  (copy-file fixture "working/config.scm")
  (let* ((file (string-append directory "/working/config.scm"))
         (os (load-declaration file))
         (daemon
          (match (filter (lambda (entry) (eq? guix-service-type (service-kind entry)))
                         (operating-system-user-services os))
            ((entry) (service-value entry))
            (_ (error "Expected one Guix service")))))
    ;; Nothing beside this copied entry point can rescue the imports.
    (check "Future defaults preserve evaluated channels except selection commits"
           (channel-codes-by-name
            (map (lambda (input) (channel (inherit input) (commit #f))) selected))
           (channel-codes-by-name (guix-configuration-channels daemon)))
    (call-with-output-file "module-origins.scm"
      (lambda (port)
        (for-each
         (lambda (name)
           (let* ((relative (string-append "hello-guix/system/" name))
                  (output (manifest-entry-item hello-entry))
                  (source (canonicalize-path
                           (string-append output "/share/guile/site/"
                                          (effective-version) "/" relative ".scm")))
                  (compiled (canonicalize-path
                             (string-append output "/lib/guile/" (effective-version)
                                            "/site-ccache/" relative ".go"))))
             (check "Hello source resolves through the channel" source
                    (canonicalize-path (search-path %load-path
                                                    (string-append relative ".scm"))))
             (check "Hello bytecode resolves through the channel" compiled
                    (canonicalize-path (search-path %load-compiled-path
                                                    (string-append relative ".go"))))
             (write (list name source compiled) port)
             (newline port)))
         '("audio" "boot-files" "boot" "hardware" "runtime"))))
    (with-store store
      (set-build-options store #:use-substitutes? #f)
      (parameterize ((%graft? #f))
        (let* ((system (run-with-store store
                         (operating-system-derivation
                          (operating-system-with-provenance os file))))
               (evaluator (run-with-store store
                            (lower-object (guix-configuration-guix daemon))))
               (provenance
                (run-with-store store
                  (service-value
                   (fold-services
                    (list (service system-service-type '())
                          (service provenance-service-type file))))))
               (output (derivation->output-path provenance)))
          (build-derivations store (list evaluator provenance))
          (check "Installed Guix retains the complete evaluating profile"
                 (canonicalize-path profile)
                 (canonicalize-path (derivation->output-path evaluator)))
          (check "Native provenance retains the generated declaration"
                 (contents file) (contents (string-append output "/configuration.scm")))
          (check "Native provenance retains exact selected channels and trust"
                 (map channel->code selected)
                 (map channel->code
                      (load-declaration (string-append output "/channels.scm"))))
          (call-with-output-file "system.drv"
            (lambda (port) (display (derivation-file-name system) port) (newline port)))
          (symlink output "provenance")
          (add-indirect-root store (string-append directory "/provenance"))
          (rename-file "working" "working-unavailable")
          (check "Working entry point is unavailable" #f (file-exists? file))))))
  (display "Generated declaration, channel imports, evaluator and native provenance verified.\n")
  (display "Replay provenance/configuration.scm in a fresh process and compare system.drv.\n"))

(match (cdr (command-line))
  ((fixture directory)
   (run (canonicalize-path fixture)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))))
  (_ (error "Usage: channel-handoff.scm GENERATED-CONFIG NEW-RECORDS-DIRECTORY")))
