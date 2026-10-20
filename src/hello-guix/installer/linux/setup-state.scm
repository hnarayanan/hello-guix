;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux setup-state)
  #:use-module (ice-9 textual-ports)
  #:export (%installation-marker
            check-installation-origin
            validate-setup-origin))

;; Only the RAM installer has this marker in its system generation's etc directory.
(define %installation-marker "hello-guix-ram-installer\n")

(define (validate-setup-origin booted current marker)
  "Check that the RAM installer is both the booted and current system generation.
The caller must also check the destination before it writes installation files."
  (unless (and (string? booted) (string-prefix? "/gnu/store/" booted)
               (string-suffix? "-system" booted)
               (equal? booted current)
               (equal? marker %installation-marker))
    (error "This program requires its booted setup image"))
  booted)

(define (check-installation-origin)
  (let* ((booted (canonicalize-path "/run/booted-system"))
         (current (canonicalize-path "/run/current-system"))
         (marker (call-with-input-file
                     (string-append booted "/etc/hello-guix/setup")
                   get-string-all)))
    (validate-setup-origin booted current marker)))
