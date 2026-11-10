;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Build a channel profile from recorded source and the selected profile's inputs.

(use-modules (guix channels)
             (guix describe)
             (guix gexp)
             (guix monads)
             (guix profiles)
             (guix store)
             (guix utils)
             (srfi srfi-1))

(define source
  (canonicalize-path (string-append (dirname (current-filename)) "/../..")))
;; Direct preflights must not import a checkout's caches or build outputs.
(define inputs
  (map (lambda (name) (string-append source "/" name))
       '(".gitignore" ".guix-authorizations" ".guix-channel"
         "COPYING" "Makefile" "NOTICE" "README.md"
         "LICENSES" "docs" "hello-guix" "packaging" "patches" "scripts" "tests")))
(define (channel-file? file stat)
  (and (not (member (basename file) '(".DS_Store" "__pycache__")))
       (or (string=? file source)
           (any (lambda (input)
                  (or (string=? file input)
                      (string-prefix? (string-append input "/") file)))
                inputs))))

(define profile (current-profile))
(unless profile
  (error "Select Guix from an existing channel profile"))
;; Keep every selected dependency; replace only our own development entry.
(define entries
  (remove (lambda (entry)
            (string=? "hello-guix" (manifest-entry-name entry)))
          (manifest-entries (profile-manifest profile))))

(define (channel-output name)
  (let ((entry (find (lambda (entry)
                       (let ((channel (manifest-entry-channel entry)))
                         (and channel (eq? name (channel-name channel)))))
                     entries)))
    (unless entry
      (error "Selected profile lacks required channel" name profile))
    ;; The channel compiler requires derivations for its extensions. Guix's
    ;; symlink constructor supplies one while reusing the existing output.
    (symlink-to (manifest-entry-item entry))))

;; No Git commit is invented for the saved working tree. Guix marks this
;; local instance with its default zero revision.
(define instance (checkout->channel-instance source #:name 'hello-guix))
(define metadata ((@@ (guix channels) channel-instance-metadata) instance))
(define requirements (channel-instance-dependencies instance))

(unless (equal? "/packaging/guix/channel"
                ((@@ (guix channels) channel-metadata-directory) metadata))
  (error "Hello Guix channel must select the packaged system modules"))
(unless (and (= 1 (length requirements))
             (eq? 'asahi (channel-name (car requirements)))
             (equal? "main" (channel-branch (car requirements)))
             (not (channel-commit (car requirements)))
             (channel-introduction (car requirements)))
  (error "Expected an authenticated, unpinned Asahi main dependency"))

;; Use Guix's actual channel compiler. Its private single-channel entry point
;; lets this test reuse built dependencies instead of rebuilding Guix itself.
;; Asahi currently declares no further channel dependencies.
(with-store store
  (let ((saved (add-to-store store "hello-guix-channel-source" #t "sha256" source
                             #:select? channel-file?)))
    (let ((instance (checkout->channel-instance saved #:name 'hello-guix)))
      (run-with-store store
        (mlet* %store-monad
            ((compiled ((@@ (guix channels) build-channel-instance)
                        instance (%current-system) (channel-output 'guix)
                        (map (lambda (channel)
                               (channel-output (channel-name channel)))
                             requirements))))
          (profile-derivation
           (manifest
            (append entries
                    (list (manifest-entry
                            (name "hello-guix")
                            (version (substring (channel-instance-commit instance) 0 7))
                            (item compiled)
                            (properties
                             `((source ,(channel-instance->sexp instance))))))))
           #:name "hello-guix-runtime-profile"
           ;; Match a normal pulled channel profile, including its package cache.
           #:hooks %channel-profile-hooks
           #:format-version 3
           #:system (%current-system)))))))
