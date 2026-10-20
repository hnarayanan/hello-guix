;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Check the Guix final-page extension without screen output or installation.

(use-modules (gnu installer newt final)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "prepared-final-page")
(define module (resolve-module '(gnu installer newt final)))
(define calls '())
(define install-ok? #t)
(define prepared '((operating-system (host-name "prepared"))))
(define formatted '((operating-system (host-name "upstream"))))
(define results '((partition) (locale . "en_GB.utf8") (user . (example-user))))
(define (record name . arguments)
  (set! calls (append calls (list (cons name arguments)))))

;; Replace external operations with test functions. Use the patched final page.
;; Restore the original functions, even if an error occurs.
(define replacements
  `((current-clients . ,(const '()))
    (installer-log-line . ,(lambda _ #t))
    (format-configuration . ,(lambda (steps results) (record 'format) formatted))
    (configuration->file . ,(lambda (config) (record 'write config)))
    (mount-user-partitions . ,(lambda (partitions) (record 'mount partitions)))
    (start-swapping . ,(lambda _ #t))
    (umount-user-partitions . ,(lambda (partitions) (record 'unmount partitions)))
    (stop-swapping . ,(lambda _ #t))
    (run-config-display-page . ,(lambda* (#:key locale) (record 'review locale)))
    (run-install-shell . ,(lambda* (locale #:key users)
                           (record 'install locale users) install-ok?))
    (run-install-success-page . ,(lambda () (record 'success) 'success))
    (run-install-failed-page . ,(lambda () (record 'failure) 'failure))))
(define (binding name)
  (module-variable
   (if (memq name '(mount-user-partitions umount-user-partitions
                    start-swapping stop-swapping))
       (resolve-module '(gnu installer parted))
       module)
   name))
(define originals
  (map (lambda (entry)
         (cons (binding (car entry))
               (variable-ref (binding (car entry)))))
       replacements))
(dynamic-wind
  (lambda ()
    (for-each (lambda (entry)
                (variable-set! (binding (car entry)) (cdr entry)))
              replacements))
  (lambda ()
    (test-equal "prepared configuration uses upstream install/completion"
      'success (run-final-page results '() #f #:configuration prepared))
    (test-equal "review precedes real installation; mounts are released"
      `((mount ()) (write ,prepared) (review "en_GB.utf8")
        (install "en_GB.utf8" (example-user)) (unmount ()) (success)) calls)
    (set! calls '())
    (test-equal "default upstream call still succeeds"
      'success (run-final-page results '() #f))
    (test-equal "default configuration still comes from upstream formatting"
      `(format) (car calls))
    (test-assert "default writer receives upstream configuration"
      (member `(write ,formatted) calls))
    (set! calls '())
    (test-equal "dry run accepts a prepared configuration"
      'success (run-final-page results '() #t #:configuration prepared))
    (test-equal "dry run reviews without mounting or installing"
      `((write ,prepared) (review "en_GB.utf8") (success)) calls)
    (set! calls '())
    (test-equal "caller can defer the success page" 'installed
      (run-final-page results '() #f #:configuration prepared
                      #:on-success (lambda () (record 'ready) 'installed)))
    (test-assert "deferred completion does not report success"
      (and (member '(ready) calls) (not (member '(success) calls))))
    (set! calls '())
    (test-error "completion errors propagate" 'completion-error
      (run-final-page results '() #f #:configuration prepared
                      #:on-success (lambda () (throw 'completion-error))))
    (test-assert "completion error never displays success" (not (member '(success) calls)))
    (set! calls '())
    (set! install-ok? #f)
    (test-equal "installation failure retains upstream failure flow"
      'failure (run-final-page results '() #f #:configuration prepared))
    (test-assert "failure unmounts and never reports success"
      (and (member '(unmount ()) calls) (not (member '(success) calls)))))
  (lambda ()
    (for-each (lambda (entry) (variable-set! (car entry) (cdr entry))) originals)))
(test-end "prepared-final-page")
(and (zero? (test-runner-fail-count runner))
     (zero? (test-runner-xpass-count runner)))
