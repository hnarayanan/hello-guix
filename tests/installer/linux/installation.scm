;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Test the installation coordinator and patched Guix final page.
;; Replace file access, installation, and screen output with test functions.
;; This test does not access /mnt.

(use-modules (hello-guix installer linux install)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "installation-order")
(define calls '())
(define failure #f)
(define client? #f)
(define writer-channels #f)
(define writer-firmware #f)
(define writer-firmware-sha256 #f)
(define hashed-firmware #f)
(define firmware-arguments #f)
(define (record name)
  (set! calls (append calls (list name)))
  (when (eq? failure name) (throw 'injected-failure name)))
(define results '((locale . "en_GB.utf8") (user)))
(define replacements
  `(((hello-guix installer linux configuration)
     (target-system-configuration
      . ,(lambda* (steps results target #:key channels firmware firmware-sha256)
           (set! writer-channels channels)
           (set! writer-firmware firmware)
           (set! writer-firmware-sha256 firmware-sha256)
           (when channels (record 'configuration))
           (when (eq? failure 'configuration) (throw 'injected-failure 'configuration))
           '((operating-system (host-name "test"))))))
    ((hello-guix installer linux firmware)
     (prepare-installation-firmware . ,(lambda arguments
                                        (set! firmware-arguments arguments)
                                        (record 'prepare-firmware))))
    ((guix hash)
     (file-hash* . ,(lambda* (directory #:key recursive? select?)
                     (set! hashed-firmware directory)
                     (unless (and recursive? (select? "firmware/.hello-guix-origin.scm" #f)
                                  (select? "firmware/.git/config" #f))
                       (error "Firmware hashing must cover the complete recursive directory"))
                     (record 'hash-firmware)
                     (make-bytevector 32 0))))
    ((gnu installer utils)
     (installer-log-port . ,current-error-port))
    ((hello-guix installer linux installation-files)
     (call-with-installation-target . ,(lambda (target inspect btrfs thunk)
                                        (record 'mount-target)
                                        (dynamic-wind (const #t) thunk
                                                      (lambda () (record 'unmount-target)))))
     (prepare-configuration-support . ,(lambda _ (record 'support)))
     (save-setup-loader . ,(lambda _ (record 'backup)))
     (call-with-preserved-firmware . ,(lambda (esp thunk)
                                        (record 'protect)
                                        (dynamic-wind (const #t) thunk
                                                      (lambda () (record 'verify)))))
     (check-installed-boot . ,(lambda _ (record 'verify-bundle)))
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
(define* (run #:key channels)
  (run-prepared-installation results '() 'target (const 'target) "btrfs" "channels" "support"
                            #:channels channels))
(dynamic-wind
  (lambda () (for-each (lambda (entry) (variable-set! (car entry) (caddr entry))) bindings))
  (lambda ()
    (test-equal "production coordinator completes" 'success (run))
    (test-equal "success follows installation, verification, cleanup and unmounts"
      '(mount-target support backup protect mount write review install unmount
        verify verify-bundle cleanup unmount-target success)
      calls)
    (test-equal "legacy coordinator leaves channel mode disabled" #f writer-channels)
    (test-equal "legacy declaration has no explicit firmware input" #f writer-firmware)
    (test-equal "legacy installation does not prepare firmware" #f firmware-arguments)
    (test-equal "legacy declaration does not acquire a firmware hash" #f writer-firmware-sha256)
    (test-equal "legacy installation does not hash a firmware directory" #f hashed-firmware)
    (set! calls '())
    (run #:channels '(selected-evaluator-records))
    (test-equal "coordinator passes explicit evaluator records to the writer"
      '(selected-evaluator-records) writer-channels)
    (test-equal "coordinator supplies the relative declared firmware path"
      "hello-guix/firmware" writer-firmware)
    (test-equal "firmware comes from this mounted target's explicit archive"
      '("/mnt/boot/efi/vendorfw/firmware.cpio" "/mnt/etc/hello-guix/firmware")
      firmware-arguments)
    (test-equal "the hash covers the final directory beside the declaration"
      "/mnt/etc/hello-guix/firmware" hashed-firmware)
    (test-equal "the writer receives the ordinary Guix base32 hash"
      (make-string 52 #\0) writer-firmware-sha256)
    (test-equal "publication and hashing precede configuration generation and review"
      '(mount-target backup protect prepare-firmware hash-firmware configuration
        mount write review install unmount verify verify-bundle cleanup unmount-target success)
      calls)
    (set! failure 'prepare-firmware)
    (set! calls '())
    (test-error "firmware preparation failure prevents configuration evaluation"
      'injected-failure (run #:channels '(selected-evaluator-records)))
    (test-equal "firmware failure checks the original archive and releases the target"
      '(mount-target backup protect prepare-firmware verify unmount-target) calls)
    (set! failure 'hash-firmware)
    (set! calls '())
    (test-error "hash failure prevents configuration generation and review"
      'injected-failure (run #:channels '(selected-evaluator-records)))
    (test-equal "hash failure checks the original archive and releases the target"
      '(mount-target backup protect prepare-firmware hash-firmware verify unmount-target) calls)
    (set! failure 'configuration)
    (set! calls '())
    (test-error "channel configuration failure releases the prepared target"
      'injected-failure (run #:channels '(selected-evaluator-records)))
    (test-equal "channel configuration failure preserves firmware and releases the target"
      '(mount-target backup protect prepare-firmware hash-firmware configuration
        verify unmount-target) calls)
    (set! calls '())
    (test-error "invalid configuration fails before mounting" 'injected-failure (run))
    (test-equal "failed configuration has not touched the target" '() calls)
    (set! failure #f)
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
       (when (memq stage '(support backup install verify verify-bundle))
         (test-assert "setup files remain available on an incomplete installation"
           (not (memq 'cleanup calls)))))
     '(support backup install verify verify-bundle cleanup unmount-target))
    (set! failure 'install-false)
    (set! calls '())
    (test-equal "ordinary Guix installation failure keeps its failure flow" 'failed (run))
    (test-assert "failed installation neither cleans up nor reports success"
      (and (memq 'failure calls) (not (memq 'verify-bundle calls))
           (not (memq 'cleanup calls)) (not (memq 'success calls))))
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
