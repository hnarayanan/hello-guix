;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Exercise the standard lowering hook with tiny libraries and a real graft.

(use-modules (gnu)
             (gnu bootloader grub)
             (gnu home)
             (gnu system)
             (guix build-system trivial)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             ((guix licenses) #:prefix license:)
             (guix monads)
             (guix packages)
             (guix profiles)
             (guix store)
             (hello-guix system software)
             (hello-guix packages upstream)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define arguments (cdr (command-line)))
(unless (= 2 (length arguments))
  (error "Expected jobs and cores" arguments))
(define graft-transformation
  (@@ (hello-guix system software) package-graft-transformation))
(define newer-replacements
  (@@ (hello-guix system software) newer-replacements))

(define (library version)
  (package
    (name "hello-guix-software-fixture-library")
    (version version)
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           #~(begin
               (mkdir #$output)
               (call-with-output-file (string-append #$output "/version")
                 (lambda (port) (display #$version port))))))
    (synopsis "Graphics integration fixture")
    (description "A tiny library for checking system-wide package grafts.")
    (home-page "https://github.com/hello-guix/hello-guix")
    (license license:gpl3+)))
(define old (library "1.0"))
(define new (library "1.1"))
(define consumer
  (package
    (inherit old)
    (name "hello-guix-software-fixture-consumer")
    (inputs `(("library" ,old)))
    (arguments
     (list #:builder
           #~(begin
               (mkdir #$output)
               (call-with-output-file (string-append #$output "/library")
                 (lambda (port)
                   (display (assoc-ref %build-inputs "library") port))))))))
;; Like a service's program or configuration: the package is inside another
;; file-like object, not a member of operating-system-packages.
(define service-file
  (computed-file "hello-guix-software-fixture-service"
    #~(symlink #$consumer #$output)))
(define original-file (plain-file "software-original" "original"))
(define personal-file (plain-file "software-personal" "personal"))
(define (personal-transform object)
  (if (eq? object original-file) personal-file object))
(define replacements (list (cons old new)))
(define transform (graft-transformation personal-transform replacements))
(define system-profile
  (profile
    ;; Two services may contribute the same ordinary package, as GNOME and
    ;; NetworkManager do. Both must see one selected runtime implementation.
    (content (packages->manifest (list old old consumer)))
    (hooks '())
    (locales? #f)))

(test-begin "software")
(define runner (test-runner-current))
(test-eq "the user's file-like transformation remains active"
  personal-file (transform original-file))
(test-eq "unrelated file-like objects retain their identity"
  service-file (transform service-file))
(test-eq "reapplying the adaptation retains one transformation"
  transform (graft-transformation transform replacements))
(test-eq "an empty software update preserves the user transformation"
  personal-transform (graft-transformation personal-transform '()))
(test-equal "only a newer maintained version overrides ordinary Guix"
  replacements
  (newer-replacements
   (list (cons old new) (cons new old) (cons new (library "1.1")))))
(test-equal "a newer existing Guix replacement is never downgraded"
  '()
  (newer-replacements
   (list (cons (package (inherit old) (replacement (library "1.2"))) new))))
(define latest (library "1.2"))
;; Replacement fields are thunked. Bind B once so the identity assertion tests
;; policy selection rather than constructing another equivalent B on each read.
(define intermediate (package (inherit new) (replacement latest)))
(define replacement-chain
  (package (inherit old) (replacement intermediate)))
(test-eq "upstream policy selects the immediate replacement"
  intermediate (effective-package replacement-chain))
(test-assert "equal directly selected upstream versions take precedence"
  (upstream-current? replacement-chain "1.1"))
(test-assert "a later replacement is not the direct package selection"
  (not (upstream-current? replacement-chain "1.2")))
(define intermediate-update (library "1.1.1"))
(test-equal "an update is compared with Guix's direct package selection"
  (list (cons replacement-chain intermediate-update))
  (newer-replacements (list (cons replacement-chain intermediate-update))))
(test-error "an active maintained graft replacement must be concrete" #t
  (graft-transformation identity (list (cons old replacement-chain))))
(test-error "a longer replacement version is rejected before lowering" #t
  (graft-transformation identity (list (cons old (library "1.10")))))
(test-error "equal version lengths cannot conceal a renamed package" #t
  (graft-transformation identity
    (list (cons old (package (inherit new) (name "renamed-library"))))))
(define split-library
  (package (inherit old) (outputs '("out" "lib"))))
(test-error "a replacement must retain the original outputs" #t
  (graft-transformation identity (list (cons split-library new))))
(test-assert "additional replacement outputs remain valid"
  (procedure?
   (graft-transformation identity
     (list (cons old (package (inherit new) (outputs '("out" "lib"))))))))
(test-eq "an irrelevant incompatible downgrade is filtered before validation"
  identity
  (graft-transformation identity
    (newer-replacements (list (cons (library "10.0") new)))))

(define personal-library
  (package (inherit old) (name "personal-library")))
(test-equal "an explicitly customized package is not replaced by the default"
  (package-full-name personal-library)
  (package-full-name (transform personal-library)))
(test-assert "an explicitly customized package has no default replacement"
  (not (package-replacement (transform personal-library))))

(define os
  (operating-system
    (host-name "software-fixture")
    (timezone "Europe/London")
    (locale "en_GB.utf8")
    (bootloader (bootloader-configuration (bootloader grub-efi-bootloader)))
    (file-systems (cons (file-system (device "/dev/fixture")
                                     (mount-point "/") (type "ext4"))
                        %base-file-systems))
    (transformation personal-transform)))
(define adapted (with-apple-silicon-software os))
(test-eq "repeated system adaptation returns the same system"
  adapted (with-apple-silicon-software adapted))
(test-eq "the declared packages retain their ordinary representation"
  (operating-system-packages os) (operating-system-packages adapted))
(test-eq "filesystems retain their identity"
  (operating-system-file-systems os) (operating-system-file-systems adapted))
(test-eq "the composed operating-system transformation preserves user choices"
  personal-file ((operating-system-transformation adapted) original-file))

(with-store store
  (define (build object transformation graft?)
    (let ((drv (parameterize ((%graft? graft?))
                 (run-with-store store
                   (with-transformation transformation (lower-object object))))))
      (build-derivations store (list drv))
      (derivation->output-path drv)))
  (define (contents file)
    (call-with-input-file file get-string-all))
  (apply set-build-options store
         (append (if (string-null? (car arguments)) '()
                     (list #:max-build-jobs (string->number (car arguments))))
                 (if (string-null? (cadr arguments)) '()
                     (list #:build-cores (string->number (cadr arguments))))))
  ;; Guix selects A's immediate replacement B for a direct build of A, even
  ;; when B itself names C. Compare actual outputs, not just our helper's shape.
  (let ((actual (build replacement-chain identity #t))
        (selected (effective-package replacement-chain)))
    (test-equal "package policy agrees with the version Guix actually builds"
      (package-version selected) (contents (string-append actual "/version")))
    (test-equal "package policy selects the same realised store output as Guix"
      (build selected identity #f) actual))

  (let* ((original (build old identity #f))
         (replacement (build new identity #f))
         (ungrafted (build service-file transform #f))
         (grafted (build service-file transform #t))
         (profile (build system-profile transform #t))
         (closure (requisites store (list grafted))))
    (test-equal "without grafts the original build input is retained"
      original (contents (string-append ungrafted "/library")))
    (test-equal "normal lowering updates an indirect service dependency"
      replacement (contents (string-append grafted "/library")))
    (test-assert "the final runtime closure contains the new library"
      (member replacement closure))
    (test-assert "the final runtime closure excludes the old library"
      (not (member original closure)))
    (test-equal "service and desktop profile contributions agree after lowering"
      "1.1" (contents (string-append profile "/version")))
    (test-equal "a profile client uses the same selected implementation"
      replacement (contents (string-append profile "/library"))))

  ;; Home lowers inside its own transformation scope (identity by default).
  ;; A graft can suspend that lowering while a sibling system union is lowered.
  ;; Cached graft inputs avoid that suspension and can hide the bug. Make runs
  ;; here in its unique runtime-check directory; retain that recorded identifier
  ;; in the tiny package names so both orderings start cold on every check.
  (for-each
   (lambda (home-first?)
     (let* ((order (if home-first? "home-first" "union-first"))
            (name (string-append "hello-guix-software-nested-"
                                 (basename (getcwd)) "-" order))
            (old (package (inherit (library "3.0")) (name name)))
            (new (package (inherit (library "3.1")) (name name)))
            (patched (package (inherit old) (replacement new)))
            (home-consumer
             (package
               (inherit consumer)
               (name (string-append name "-consumer"))
               (inputs `(("library" ,patched)))))
            (home (home-environment
                    (packages (list home-consumer))
                    (services '())))
            (union-name (string-append name "-union"))
            (union
             (with-imported-modules '((guix build union))
               (computed-file union-name
                 #~(begin
                     (use-modules (guix build union))
                     (union-build #$output (list #$old))))))
            (inputs (if home-first? (list home union) (list union home)))
            (object
             (computed-file (string-append name "-composition")
               #~(begin
                   (mkdir #$output)
                   (for-each
                    (lambda (input name)
                      (symlink input (string-append #$output "/" name)))
                    (list #$@inputs)
                    '#$(if home-first? '("home" "union") '("union" "home"))))))
            (transform (graft-transformation identity (list (cons old new))))
            (drv (parameterize ((%graft? #t))
                   (run-with-store store
                     (with-transformation transform (lower-object object)))))
            (union-drv
             (derivation-input-derivation
              (find (lambda (input)
                      (string-suffix? (string-append "-" union-name ".drv")
                                      (derivation-input-path input)))
                    (derivation-inputs drv))))
            (replacement
             (derivation->output-path
              (run-with-store store
                (with-transformation identity (lower-object new)))))
            (declared (append-map derivation-input-output-paths
                                  (derivation-inputs union-drv)))
            (builder (contents (last (derivation-builder-arguments union-drv)))))
       ;; Inspect the actual union already lowered in the composition. Lowering
       ;; it again in isolation would discard the context that exposed the bug.
       (test-assert (string-append order ": union declares its replacement")
         (member replacement declared))
       (test-assert (string-append order ": union expands its replacement")
         (string-contains builder replacement))
       (test-assert (string-append order ": composition expands its declared union")
         (string-contains
          (contents (last (derivation-builder-arguments drv)))
          (derivation->output-path union-drv)))
       (let ((built?
              (catch #t
                (lambda ()
                  (build-derivations store (list drv))
                  #t)
                (lambda args
                  (format (current-error-port) "Nested lowering failed: ~s~%" args)
                  #f))))
         (test-assert (string-append order ": composed Home and union build") built?)
         (when built?
           (test-equal (string-append order ": union selects the new library")
             "3.1"
             (contents (string-append (derivation->output-path drv)
                                      "/union/version")))))))
   '(#t #f)))
(test-end "software")
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
