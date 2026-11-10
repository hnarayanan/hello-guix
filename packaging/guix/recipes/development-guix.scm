;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Compile an isolated Guix evaluator with the lowering-context correction.

(use-modules (gnu packages base)
             (guix base16)
             (guix channels)
             (guix derivations)
             (guix describe)
             (guix gexp)
             (guix hash)
             (guix monads)
             (guix profiles)
             (guix store)
             (guix utils)
             (srfi srfi-1))

(define base-commit "7c39b1b1a0ad114ab5ceab0c53fb84dd0f990d9f")
(define base-sha256
  "7833221bced75321ee876d02300f6fffb0a67d023364b161c1e3650b23e7faec")

(define recipe (canonicalize-path (current-filename)))
(define patch-file
  (canonicalize-path
   (string-append (dirname recipe)
                  "/../../../patches/gnu-guix-runtime/patches/0001-preserve-lowering-contexts.patch")))
(define patch-sha256
  (bytevector->base16-string (file-hash* patch-file)))
(define source
  (canonicalize-path
   (or (getenv "GUIX_SOURCE")
       (error "Set GUIX_SOURCE to the cached Guix 7c39b1b source directory"))))
(define profile
  (or (current-profile)
      (error "Run this recipe with Guix from an existing channel profile")))
(define entries (manifest-entries (profile-manifest profile)))
(define guix-entry
  (find (lambda (entry) (string=? "guix" (manifest-entry-name entry)))
        entries))

(unless (and guix-entry
             (manifest-entry-channel guix-entry)
             (equal? base-commit
                     (channel-commit (manifest-entry-channel guix-entry))))
  (error "The selected Guix profile must use the patch's upstream revision"
         base-commit))
(unless (any (lambda (entry) (string=? "asahi" (manifest-entry-name entry)))
             entries)
  (error "The selected profile must include the Asahi channel"))
(unless (store-path? source)
  (error "GUIX_SOURCE must name an immutable cached store directory" source))
(unless (string=? base-sha256
                  (bytevector->base16-string
                   (file-hash* source #:recursive? #t #:select? (const #t))))
  (error "Guix source differs from the recorded upstream tree" source))

(define corrected-source
  (computed-file "guix-development-source"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (copy-recursively #$(local-file source #:recursive? #t) #$output
                            #:log (%make-void-port "w"))
          (with-directory-excursion #$output
            (invoke #$(file-append patch "/bin/patch")
                    "--batch" "--fuzz=0" "-p1" "-i"
                    #$(local-file patch-file)))
          ;; Keep the inputs next to this explicitly local source. Its channel
          ;; metadata retains this directory, including these store references.
          (call-with-output-file
              (string-append #$output "/hello-guix-development.scm")
            (lambda (port)
              (write
               '(development-guix
                 (upstream-commit #$base-commit)
                 (upstream-source #$(local-file source #:recursive? #t))
                 (upstream-nar-sha256 #$base-sha256)
                 (patch #$(local-file patch-file))
                 (patch-sha256 #$patch-sha256)
                 (recipe #$(local-file recipe)))
               port)
              (newline port)))))))

;; guix build calls this thunk within its normal store connection, preserving
;; command-line resource limits. The channel compiler reads build-self.scm
;; from a realized source directory, so prepare that input first.
(lambda ()
  (mlet* %store-monad
      ((source-drv (lower-object corrected-source))
       (_ (built-derivations (list source-drv)))
       (instance ->
                 (checkout->channel-instance
                  (derivation->output-path source-drv)))
       (compiled (channel-instances->manifest (list instance))))
    (profile-derivation
     (manifest
      (append (manifest-entries compiled)
              (remove (lambda (entry)
                        (member (manifest-entry-name entry)
                                '("guix" "hello-guix")))
                      entries)))
     #:name "hello-guix-development-profile"
     #:hooks %channel-profile-hooks
     #:format-version 3)))
