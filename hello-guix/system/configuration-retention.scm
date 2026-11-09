;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system configuration-retention)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:export (configuration-source configuration-source-service-type))

(define (configuration-source file)
  "Keep FILE and its support files in a portable directory.
Include only configuration sources, not the other files in /etc. Firmware
under hello-guix/firmware belongs to the system's firmware inputs instead."
  (let* ((directory (dirname file))
         (support (string-append directory "/hello-guix"))
         (firmware (delay (string-append (canonicalize-path support) "/firmware"))))
    (file-union "configuration-source"
                `(("config.scm" ,(local-file file "config.scm"))
                  ("channels.scm" ,(local-file (string-append directory "/channels.scm")))
                  ("hello-guix" ,(local-file support #:recursive? #t
                                  #:select? (lambda (file properties)
                                              (not (string=? file (force firmware))))))))))

(define (configuration-source-entry source)
  ;; This reference prevents garbage collection of the source while the
  ;; system generation exists. The service has no activation action.
  (with-monad %store-monad
    (return `(("configuration-source" ,source)))))

(define configuration-source-service-type
  (service-type
   (name 'configuration-source)
   (extensions
    (list (service-extension system-service-type configuration-source-entry)))
   (description
    "Retain a complete, readable configuration directory in this system
generation.  Supply a file-like directory containing the configuration,
its local helper modules and channel pins.  Its contents become public in
the Guix store; keep secrets and machine firmware outside this directory.")))
