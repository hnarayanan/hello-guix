;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run outside the checkout with the separate, combined channel profile:
;; guix repl channel-migration.scm FIXTURE NEW-RECORDS-DIRECTORY
;; Only native provenance components are built. System derivations use no
;; grafts for a structural comparison, not an upgrade cost measurement.

(use-modules (gnu services)
             (gnu services base)
             (gnu system)
             (guix build utils)
             (guix channels)
             (guix describe)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix packages)
             (guix profiles)
             (guix store)
             (guix utils)
             (asahi guix services firmware)
             (hello-guix system boot)
             (hello-guix system configuration-retention)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (load-declaration file)
  (save-module-excursion
   (lambda ()
     (set-current-module (make-fresh-user-module))
     (primitive-load file))))

(define (configuration os type)
  (match (filter (lambda (entry) (eq? (service-kind entry) type))
                 (operating-system-user-services os))
    ((entry) (service-value entry))
    (entries (error "Expected exactly one service" type entries))))

(define (channel-revision channel)
  ;; Native provenance's summary omits introductions.  The separate
  ;; channels.scm file below preserves their complete channel declarations.
  (list (channel-name channel) (channel-url channel)
        (channel-branch channel) (channel-commit channel)))

(define (run fixture directory)
  (define profile (current-profile))
  (define original (string-append directory "/original/config.scm"))
  (define added (string-append directory "/added-package/config.scm"))
  (define local-helpers (string-append directory "/local-helpers/config.scm"))
  (define hello-entry
    (find (lambda (entry)
            (let ((channel (manifest-entry-channel entry)))
              (and channel (eq? 'hello-guix (channel-name channel)))))
          (manifest-entries (profile-manifest profile))))
  (unless hello-entry (error "Executing profile has no Hello Guix channel"))
  (mkdir directory)
  (chdir directory)

  ;; Guix's channel output links its source tree and contains compiled modules.
  ;; These checks observe ordinary resolution; they do not modify the loader.
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
                                          "/site-ccache/" relative ".go")))
                (module (resolve-interface
                         `(hello-guix system ,(string->symbol name))))
                (filename (module-filename
                           (resolve-module
                            `(hello-guix system ,(string->symbol name))))))
           (check "Source module resolves through channel output" source
                  (canonicalize-path (search-path %load-path
                                                  (string-append relative ".scm"))))
           (check "Compiled module resolves through channel output" compiled
                  (canonicalize-path (search-path %load-compiled-path
                                                  (string-append relative ".go"))))
           (check "Imported module names the channel source" source
                  (canonicalize-path (search-path %load-path filename)))
           (write (list name source compiled filename) port)
           (newline port)))
       '("audio" "boot-files" "boot" "configuration-retention" "hardware" "runtime"))))

  (mkdir "original")
  (mkdir "added-package")
  (mkdir "local-helpers")
  (copy-file (string-append (dirname fixture) "/channel-local-system.scm") local-helpers)
  (copy-file fixture "local-helpers/system.scm")
  (copy-file (string-append (dirname fixture) "/channel-local-packages.scm")
             "local-helpers/packages.scm")
  (call-with-output-file "DO-NOT-COPY"
    (lambda (port) (display "Private neighbouring file.\n" port)))
  (copy-file fixture original)
  (let* ((text (contents fixture))
         (field "(packages %base-packages)")
         (position (string-contains text field)))
    (unless position (error "Fixture lacks its ordinary packages field"))
    (call-with-output-file added
      (lambda (port)
        (display (substring text 0 position) port)
        (display "(packages (cons (@ (gnu packages base) hello) %base-packages))" port)
        (display (substring text (+ position (string-length field))) port))))

  (let ((base (load-declaration original))
        (changed (load-declaration added))
        (personal (load-declaration local-helpers)))
    (check "One ordinary package was added" "hello"
           (package-name (car (operating-system-packages changed))))
    (check "Existing packages are preserved" (operating-system-packages base)
           (cdr (operating-system-packages changed)))
    (check "Local helper supplies the same ordinary package"
           (operating-system-packages changed) (operating-system-packages personal))
    (check "Firmware service inputs are unchanged"
           (configuration base asahi-firmware-service-type)
           (configuration changed asahi-firmware-service-type))
    (check "Initrd modules are unchanged" (operating-system-initrd-modules base)
           (operating-system-initrd-modules changed))
    (let* ((policy (guix-configuration-channels
                    (configuration base guix-service-type)))
           (hello (find (lambda (channel) (eq? 'hello-guix (channel-name channel)))
                        policy)))
      (check "Future pulls retain Guix and Hello" '(hello-guix guix)
             (map channel-name policy))
      (check "Future channels are unpinned" '(#f #f) (map channel-commit policy))
      (check "No Hello introduction has been invented" #f
             (channel-introduction hello)))

    (with-store store
      (define (lower object)
        (derivation-file-name (run-with-store store (lower-object object))))
      (define (hardware os)
        (check "Boot service follows the system kernel" (operating-system-kernel os)
               (configuration os asahi-boot-service-type))
        `((kernel . ,(lower (operating-system-kernel os)))
          (initrd . ,(lower (operating-system-initrd-file os)))
          (boot . ,(lower (asahi-boot-bundle (operating-system-kernel os))))
          (firmware . ,(map lower (operating-system-firmware os)))))
      (define (derive os file)
        (derivation-file-name
         (run-with-store store
           (operating-system-derivation
            (operating-system-with-provenance os file)))))
      (define* (retain os file #:key local-helpers?)
        (let* ((expected (derive os file))
               ;; Fold Guix's real provenance service into its standard root.
               ;; This builds the three provenance files, not the whole OS.
               (component
                (run-with-store store
                  (service-value
                   (fold-services
                    (append
                     (list (service system-service-type '())
                           (service provenance-service-type file))
                     (if local-helpers?
                         (list (service configuration-source-service-type
                                        (configuration os configuration-source-service-type)))
                         '()))))))
               (output (derivation->output-path component))
               (saved (string-append output "/configuration.scm")))
          (build-derivations store (list component))
          (check "Native provenance preserves the declaration" (contents file)
                 (contents saved))
          (call-with-values (lambda () (system-provenance output))
            (lambda (channels config-file)
              (check "Native provenance records the executing channels"
                     (map channel-revision (current-channels))
                     (map channel-revision channels))
              (check "Native provenance points to the saved declaration"
                     (canonicalize-path saved) (canonicalize-path config-file))))
          (let ((saved-channels
                 (save-module-excursion
                  (lambda ()
                    (set-current-module (make-fresh-user-module))
                    (module-use! (current-module) (resolve-interface '(guix channels)))
                    (primitive-load (string-append output "/channels.scm"))))))
            (check "Saved channels file records the executing channels"
                   (map channel->code (current-channels)) (map channel->code saved-channels)))
          (when local-helpers?
            (let ((retained (string-append output "/configuration-source")))
              (for-each
               (lambda (name)
                 (check "Retained local helpers remain ordinary neighbouring files"
                        'regular (stat:type (lstat (string-append retained "/" name))))
                 (check "Explicit local source is retained byte for byte"
                        (contents (string-append (dirname file) "/" name))
                        (contents (string-append retained "/" name))))
               '("config.scm" "system.scm" "packages.scm"))
              (for-each
               (lambda (name)
                 (check "Unrelated files and channel implementations are not copied"
                        #f (file-exists? (string-append retained "/" name))))
               '("DO-NOT-COPY" "hello-guix" "channels.scm"))))
          (rename-file (dirname file) (string-append (dirname file) "-unavailable"))
          (check "Working declaration is unavailable" #f (file-exists? file))
          ;; The runner replays the saved declaration in a fresh Guix process.
          (call-with-output-file (string-append (basename (dirname file)) ".drv")
            (lambda (port) (display expected port) (newline port)))
          (let ((root (string-append (dirname file) "-provenance")))
            (symlink output root)
            (add-indirect-root store root))
          expected))
      (set-build-options store #:use-substitutes? #f)
      (parameterize ((%graft? #f))
        (let* ((fixed-hardware (hardware base))
               (base-drv (retain base original))
               (added-drv (retain changed added))
               (personal-drv (retain personal local-helpers #:local-helpers? #t)))
          (check "An application change preserves hardware derivations"
                 fixed-hardware (hardware changed))
          (check "Local helper composition preserves hardware derivations"
                 fixed-hardware (hardware personal))
          (check "An application change changes the system derivation" #f
                 (string=? base-drv added-drv))
          (call-with-output-file "derivations.scm"
            (lambda (port)
              (write `((original . ,base-drv) (added-package . ,added-drv)
                       (local-helpers . ,personal-drv)
                       (hardware . ,fixed-hardware)) port)
              (newline port)))))))
  (display "Channel module paths, ordinary packages, native provenance and local sources verified.\n")
  (display "Saved declarations are ready for separate-process replay; authenticated channel replay remains untested.\n"))

(match (cdr (command-line))
  ((fixture directory)
   (unless (string=? (%current-system) "aarch64-linux")
     (error "Channel migration checks require native ARM64 Linux"))
   (run (canonicalize-path fixture)
        (string-append (canonicalize-path (dirname directory)) "/" (basename directory))))
  (_ (error "Usage: channel-migration.scm FIXTURE NEW-RECORDS-DIRECTORY")))
