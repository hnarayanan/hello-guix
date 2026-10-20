;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Test the installation coordinator and patched Guix final page.
;; Replace file access, installation, and screen output with test functions.
;; This test does not access /mnt.

(use-modules (hello-guix installer linux install)
             (srfi srfi-1)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "installation-order")
(define calls '())
(define failure #f)
(define client? #f)
(define (record name)
  (set! calls (append calls (list name)))
  (when (eq? failure name) (throw 'injected-failure name)))
(define results '((locale . "en_GB.utf8") (user)))
(define replacements
  `(((hello-guix installer linux configuration)
     (target-system-configuration . ,(lambda _ '((operating-system (host-name "test"))))))
    ((hello-guix installer linux installation-files)
     (call-with-installation-target . ,(lambda (target inspect btrfs thunk)
                                        (record 'mount-target)
                                        (dynamic-wind (const #t) thunk
                                                      (lambda () (record 'unmount-target)))))
     (prepare-configuration-support . ,(lambda _ (record 'support)))
     (save-setup-loader . ,(lambda _ (record 'backup)))
     (call-with-preserved-boot-files . ,(lambda (esp thunk)
                                        (record 'protect)
                                        (dynamic-wind (const #t) thunk
                                                      (lambda () (record 'verify)))))
     (finish-installation . ,(lambda _ (record 'cleanup))))
    ((gnu installer parted)
     (mount-user-partitions . ,(lambda _ (record 'mount)))
     (umount-user-partitions . ,(lambda _ (record 'unmount)))
     (start-swapping . ,(const #t))
     (stop-swapping . ,(const #t)))
    ((gnu installer newt final)
     (current-clients . ,(lambda () (if (and client? (memq 'install calls)) '(client) '())))
     (installer-log-line . ,(const #t))
     (configuration->file . ,(lambda _ (record 'write)))
     (run-config-display-page . ,(lambda _
                                  (record 'review)
                                  (when (eq? failure 'cancel)
                                    (abort-to-prompt 'installer-step 'abort))))
     (run-install-shell . ,(lambda _ (record 'install) (not (eq? failure 'install-false))))
     (run-install-failed-page . ,(lambda () (record 'failure) 'failed))
     (message-window . ,(lambda _ (record 'success)))
     (send-to-clients . ,(lambda (message)
                          (unless (equal? message '(installation-complete))
                            (error "Unexpected client message" message))
                          (record 'client-success))))))
(define bindings
  (append-map
   (lambda (group)
     (map (lambda (entry)
            (let ((variable (module-variable (resolve-module (car group)) (car entry))))
              (list variable (variable-ref variable) (cdr entry))))
          (cdr group)))
   replacements))
(define (run)
  (run-prepared-installation results '() 'target (const 'target) "btrfs" "channels" "support"))
(dynamic-wind
  (lambda () (for-each (lambda (entry) (variable-set! (car entry) (caddr entry))) bindings))
  (lambda ()
    (test-equal "production coordinator completes" 'success (run))
    (test-equal "success follows installation, verification, cleanup and unmounts"
      '(mount-target support backup protect mount write review install unmount
        verify cleanup unmount-target success)
      calls)
    (set! client? #t)
    (set! calls '())
    (test-equal "connected clients also complete" 'success (run))
    (test-equal "clients hear success only after the target is released"
      '(unmount-target client-success) (take-right calls 2))
    (set! client? #f)
    (for-each
     (lambda (stage)
       (set! failure stage)
       (set! calls '())
       (test-error (string-append "failure propagates: " (symbol->string stage))
         'injected-failure (run))
       (test-assert (string-append "no success on failure: " (symbol->string stage))
         (not (or (memq 'success calls) (memq 'client-success calls))))
       (when (memq stage '(support backup install verify))
         (test-assert "setup files remain available on an incomplete installation"
           (not (memq 'cleanup calls)))))
     '(support backup install verify cleanup unmount-target))
    (set! failure 'install-false)
    (set! calls '())
    (test-equal "ordinary Guix installation failure keeps its failure flow" 'failed (run))
    (test-assert "failed installation neither cleans up nor reports success"
      (and (memq 'failure calls) (not (memq 'cleanup calls)) (not (memq 'success calls))))
    (set! failure 'cancel)
    (set! calls '())
    (test-equal "review cancellation returns to Guix navigation" 'abort
      (call-with-prompt 'installer-step run (lambda (continuation result) result)))
    (test-assert "cancelled review releases mounts without installing or claiming success"
      (and (memq 'unmount-target calls) (not (memq 'install calls))
           (not (memq 'cleanup calls)) (not (memq 'success calls)))))
  (lambda () (for-each (lambda (entry) (variable-set! (car entry) (cadr entry))) bindings)))
(test-end "installation-order")
(and (zero? (test-runner-fail-count runner))
     (zero? (test-runner-xpass-count runner)))
