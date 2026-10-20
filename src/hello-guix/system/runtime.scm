;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system runtime)
  #:use-module (gnu packages package-management)
  #:use-module (guix build-system trivial)
  #:use-module (guix config)
  #:use-module (guix describe)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (running-guix))

(define (running-guix)
  "Package the Guix profile that evaluates this configuration, including its channels.
Guix pull or time-machine has already downloaded and authenticated those channels.
Reuse that profile for builds on the same architecture. Use Guix's standard
channel build for cross builds or if Guix runs outside a channel profile."
  (let ((profile (current-profile))
        (base (guix-for-channels (current-channels))))
    (if (and profile (string=? (%current-system) %system)
             (not (%current-target-system)))
        (package
          (inherit base)
          (source #f)
          (build-system trivial-build-system)
          (arguments
           (list #:builder
                 #~(symlink #$(canonicalize-path profile) #$output))))
        base)))
