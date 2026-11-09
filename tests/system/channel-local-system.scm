;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Fictional personal declaration. Keep its two local helpers explicitly;
;; channel implementations and native channel provenance are separate inputs.

(use-modules (gnu services)
             (gnu system)
             (guix gexp)
             (hello-guix system configuration-retention))

(define directory (dirname (current-filename)))
(define base (primitive-load (string-append directory "/system.scm")))

(operating-system
 (inherit base)
 (packages (append (primitive-load (string-append directory "/packages.scm"))
                   (operating-system-packages base)))
 (services
  (cons (service configuration-source-service-type
                 ;; This dedicated directory contains only personal sources.
                 ;; Keep ordinary files together: Guix canonicalizes the entry
                 ;; point before loading it, so individual file-union links
                 ;; would lose the neighbouring helpers.
                 (local-file directory "personal-configuration" #:recursive? #t))
        (operating-system-user-services base))))
