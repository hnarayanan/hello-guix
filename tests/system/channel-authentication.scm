;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Native authentication and exact-revision replay of a local test channel.
;; Called by check-channel-authentication.sh with an upstream-only profile.

(use-modules (guix channels)
             (guix describe)
             (guix derivations)
             (guix diagnostics)
             (guix gexp)
             (guix git-authenticate)
             (guix monads)
             (guix openpgp)
             (guix profiles)
             (guix store)
             (guix utils)
             (git oid)
             (ice-9 match)
             (ice-9 pretty-print)
             (srfi srfi-1)
             (srfi srfi-34))

(define profile (current-profile))
(unless profile (error "Select an existing Guix and Asahi channel profile"))
(define entries (manifest-entries (profile-manifest profile)))
(define original-channels (profile-channels profile))

;; Native authentication can trust commits from current-channels by name.
;; Start with upstream inputs, so no existing Hello entry can bypass this test.
(when (any (lambda (channel) (eq? 'hello-guix (channel-name channel)))
           original-channels)
  (error "Authentication fixture requires a profile without Hello Guix" profile))

(define (channel-output name)
  (let ((entry (find (lambda (entry)
                       (let ((channel (manifest-entry-channel entry)))
                         (and channel (eq? name (channel-name channel)))))
                     entries)))
    (unless entry (error "Selected profile lacks required channel" name))
    (symlink-to (manifest-entry-item entry))))

(define (save file value)
  (call-with-output-file file (lambda (port) (pretty-print value port))))

(define (save-channels file channels)
  (save file `(list ,@(map channel->code channels))))

(define (check message expected actual)
  (unless (equal? expected actual)
    (error message "expected" expected "actual" actual)))

(define (fetch store channel)
  ;; This is the same fetch/authentication entry used by guix pull. Fetch only
  ;; Hello here: its declared upstream inputs are the already selected profile.
  ;; We do not claim to test a fresh time-machine bootstrap of all channels.
  ((@@ (guix channels) latest-channel-instance) store channel #:authenticate? #t))

(define (reject store channel mode expected introduction directory)
  (define caught
    (guard (condition
            ((and (equal? mode "reject-unsigned")
                  (unsigned-commit-error? condition))
             (check "Rejected wrong unsigned commit" expected
                    (oid->string (git-authentication-error-commit condition)))
             'unsigned-commit)
            ((and (equal? mode "reject-unauthorized")
                  (unauthorized-commit-error? condition))
             (check "Rejected wrong unauthorized commit" expected
                    (oid->string (git-authentication-error-commit condition)))
             'unauthorized-commit)
            ((and (equal? mode "reject-introduction")
                  (formatted-message? condition)
                  (equal? (formatted-message-string condition)
                          "initial commit ~a is signed by '~a' instead of '~a'\n"))
             (check "Rejected wrong introduction" introduction
                    (car (formatted-message-arguments condition)))
             (check "Rejected wrong introduction signer"
                    (openpgp-format-fingerprint
                     (channel-introduction-first-commit-signer
                      (channel-introduction channel)))
                    (list-ref (formatted-message-arguments condition) 2))
             (save (string-append directory "/diagnostic.scm")
                   (cons (formatted-message-string condition)
                         (formatted-message-arguments condition)))
             'wrong-introduction-signer))
      (fetch store channel)
      (error "Invalid channel was accepted" mode expected)))
  (save (string-append directory "/rejected.scm") caught)
  (format #t "Rejected ~a through native Guix authentication.~%" caught))

(define (build-profile store instance directory)
  (define requirements (channel-instance-dependencies instance))
  (check "Fixture must retain the real Asahi dependency" '(asahi)
         (map channel-name requirements))
  (define drv
    (run-with-store store
      (mlet %store-monad
          ((compiled ((@@ (guix channels) build-channel-instance)
                      instance (%current-system) (channel-output 'guix)
                      (map (lambda (dependency)
                             (channel-output (channel-name dependency)))
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
         #:name "hello-guix-authenticated-profile"
         #:hooks %channel-profile-hooks
         #:format-version 3
         #:system (%current-system)))))
  (call-with-output-file (string-append directory "/profile.drv")
    (lambda (port) (display (derivation-file-name drv) port) (newline port)))
  (build-derivations store (list drv))
  (let* ((output (derivation->output-path drv))
         (root (string-append directory "/profile"))
         (resolved (profile-channels output))
         (hello (find (lambda (channel) (eq? 'hello-guix (channel-name channel)))
                      resolved)))
    (unless hello (error "Built profile lost its Hello Guix provenance"))
    (check "Profile recorded the wrong commit" (channel-instance-commit instance)
           (channel-commit hello))
    (check "Profile recorded the wrong introduction"
           (channel->code
            (channel (inherit (channel-instance-channel instance))
                     (commit (channel-instance-commit instance))))
           (channel->code hello))
    (check "Upstream channel inputs changed"
           (map channel->code original-channels)
           (map channel->code
                (remove (lambda (channel) (eq? 'hello-guix (channel-name channel)))
                        resolved)))
    (symlink output root)
    (add-indirect-root store root)
    (save-channels (string-append directory "/channels.scm") resolved)
    (save (string-append directory "/instance.scm") (channel-instance->sexp instance))
    (format #t "Authenticated ~a; channel profile: ~a~%"
            (channel-instance-commit instance) output)))

(define (run mode repository introduction signer revision expected directory jobs cores)
  (define selected
    (if (equal? mode "replay")
        (let* ((recorded (primitive-load revision))
               (hello (find (lambda (channel) (eq? 'hello-guix (channel-name channel)))
                            recorded)))
          (unless hello (error "Recorded channels lack Hello Guix" revision))
          (check "Replay changed the upstream inputs"
                 (map channel->code original-channels)
                 (map channel->code
                      (remove (lambda (channel) (eq? 'hello-guix (channel-name channel)))
                              recorded)))
          (check "Replay changed the repository" repository (channel-url hello))
          hello)
        (channel
          (name 'hello-guix)
          (url repository)
          (branch "main")
          (commit (and (not (equal? revision "main")) revision))
          (introduction
           (make-channel-introduction introduction (openpgp-fingerprint signer))))))
  (with-store store
    (apply set-build-options store
           (append (if (string-null? jobs) '()
                       (list #:max-build-jobs (string->number jobs)))
                   (if (string-null? cores) '()
                       (list #:build-cores (string->number cores)))))
    (if (string-prefix? "reject-" mode)
        (reject store selected mode expected introduction directory)
        (let ((instance (fetch store selected)))
          (check "Fetched the wrong revision" expected (channel-instance-commit instance))
          (build-profile store instance directory)))))

(match (cdr (command-line))
  (("inputs" directory)
   (channel-output 'guix)
   (channel-output 'asahi)
   (save-channels (string-append directory "/upstream-channels.scm") original-channels)
   (format #t "Authentication fixture evaluator: ~a~%" profile))
  (((and mode (or "build" "replay" "reject-unsigned" "reject-unauthorized"
                  "reject-introduction"))
    repository introduction signer revision expected directory jobs cores)
   (run mode repository introduction signer revision expected directory jobs cores))
  (_ (error "Usage: channel-authentication.scm inputs DIRECTORY; or MODE REPOSITORY INTRO SIGNER REVISION EXPECTED DIRECTORY JOBS CORES")))
