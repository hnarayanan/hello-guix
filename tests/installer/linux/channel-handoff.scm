;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Evaluate a real writer output with its authenticated channel profile.
;; guix repl channel-handoff.scm GENERATED-CONFIG NEW-RECORDS-DIRECTORY
;; The caller authenticates the profile first. This checks the declaration
;; handoff; it builds only evaluator, firmware and provenance components.

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
             (ice-9 popen)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (declared-firmware-hash file)
  (call-with-input-file file
    (lambda (port)
      (let loop ()
        (match (read port)
          (('on-apple-silicon 'my-system #:firmware
            ('apple-firmware "hello-guix/firmware" ('sha256 ('base32 hash))))
           hash)
          ((? eof-object?) (error "Generated declaration has no firmware content hash"))
          (_ (loop)))))))

(define (directory-hash guix directory)
  ;; Independently check the generated pin with the documented user command.
  (let* ((port (open-pipe* OPEN_READ guix "hash" "-r" directory))
         (hash (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? status)
      (error "Could not compute the generated declaration's firmware hash" status))
    (string-trim-right hash)))

(define (channel-codes-by-name channels)
  ;; Describe output and profile manifests can enumerate the same channels in
  ;; different orders. The future policy names the same distinct inputs.
  (map channel->code
       (sort channels
             (lambda (left right)
               (string<? (symbol->string (channel-name left))
                         (symbol->string (channel-name right)))))))

(define* (load-declaration file #:optional (module (make-fresh-user-module)))
  (save-module-excursion
   (lambda ()
     (set-current-module module)
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
  (mkdir "working/hello-guix")
  (unless (copy-recursively
           (string-append (dirname fixture) "/hello-guix/firmware")
           "working/hello-guix/firmware" #:log #f)
    (error "Could not copy the prepared firmware into the isolated declaration"))
  (let ((firmware-directory (string-append directory "/working/hello-guix/firmware")))
    (check "The prepared firmware receipt exists before declaration evaluation" #t
           (file-exists? (string-append firmware-directory "/.hello-guix-origin.scm")))
    (check "The generated declaration records ordinary guix hash -r output"
           (directory-hash (string-append profile "/bin/guix") firmware-directory)
           (declared-firmware-hash "working/config.scm")))
  (let* ((file (string-append directory "/working/config.scm"))
         (declaration-module (make-fresh-user-module))
         (os (load-declaration file declaration-module))
         (personal (module-ref declaration-module 'my-system))
         (ordinary-firmware (operating-system-firmware personal))
         (inputs (operating-system-firmware os))
         (firmware
          (begin
            (check "The generated system preserves its ordinary firmware inputs"
                   ordinary-firmware (take inputs (length ordinary-firmware)))
            ;; The free AVD firmware is an independent platform input.
            ;; Find the explicit Apple input whose bytes this check retains.
            (match (filter (lambda (input)
                             (and (computed-file? input)
                                  (string=? "apple-silicon-firmware"
                                            (computed-file-name input))))
                           inputs)
              ((input) input)
              (other (error "Expected exactly one explicit Apple firmware input" other)))))
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
         (lambda (relative)
           (let* ((output (manifest-entry-item hello-entry))
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
             (write (list relative source compiled) port)
             (newline port)))
         '("hello-guix/apple-silicon" "hello-guix/system/audio"
           "hello-guix/system/boot-files" "hello-guix/system/boot"
           "hello-guix/system/firmware" "hello-guix/system/hardware"
           "hello-guix/system/runtime"))))
    (with-store store
      (set-build-options store #:use-substitutes? #f)
      (parameterize ((%graft? #f))
        (let* ((system (run-with-store store
                         (operating-system-derivation
                          (operating-system-with-provenance os file))))
               (evaluator (run-with-store store
                            (lower-object (guix-configuration-guix daemon))))
               (normalized (run-with-store store (lower-object firmware)))
               (provenance
                (run-with-store store
                  (service-value
                   (fold-services
                    (list (service system-service-type '())
                          (service provenance-service-type file))))))
               (output (derivation->output-path provenance)))
          (check "The generated system retains its explicit firmware dependency" #t
                 (and (member (derivation-file-name normalized)
                              (requisites store (list (derivation-file-name system)))) #t))
          (build-derivations store (list evaluator normalized provenance))
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
          (let* ((normalized-output (derivation->output-path normalized))
                 (retained (canonicalize-path
                            (string-append normalized-output "/lib/firmware")))
                 (declared (run-with-store store
                             (lower-object
                              (local-file
                               (string-append directory "/working/hello-guix/firmware")
                               #:recursive? #t)))))
            (check "Normalized firmware retains the exact prepared directory" declared retained)
            (check "Firmware closure retains its declared source" #t
                   (and (member retained (requisites store (list normalized-output))) #t))
            (for-each
             (lambda (name)
               (check "Prepared bytes, upstream manifest and installation receipt are retained"
                      (contents (string-append "working/hello-guix/firmware/" name))
                      (contents (string-append retained "/" name))))
             '("brcm/first.bin" "brcm/linked.bin" "apple/second.bin" "apple/linked.bin"
               ".vendorfw.manifest" ".hello-guix-origin.scm"))
            (symlink normalized-output "normalized-firmware")
            (add-indirect-root store (string-append directory "/normalized-firmware"))
            ;; Native provenance keeps the declaration; restore its explicit
            ;; relative input from the generation's retained firmware directory.
            (mkdir-p "recovery/hello-guix")
            (copy-file (string-append output "/configuration.scm") "recovery/config.scm")
            (unless (copy-recursively retained "recovery/hello-guix/firmware" #:log #f)
              (error "Could not restore the retained firmware for replay")))
          (rename-file "working" "working-unavailable")
          (check "Working entry point is unavailable" #f (file-exists? file))
          (check "Working firmware directory is unavailable" #f
                 (file-exists? (string-append directory "/working/hello-guix/firmware")))))))
  (display "Generated declaration, prepared firmware, channel imports and native provenance verified.\n")
  (display "Replay recovery/config.scm in a fresh process and compare system.drv.\n"))

(match (cdr (command-line))
  ((fixture directory)
   (run (canonicalize-path fixture)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))))
  (_ (error "Usage: channel-handoff.scm GENERATED-CONFIG NEW-RECORDS-DIRECTORY")))
