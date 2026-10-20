;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (hello-guix installer linux setup)
             (asahi guix build-system installer)
             (guix channels)
             (guix gexp)
             (guix packages)
             ((guix licenses) #:prefix license:))

;; -L adds source paths, not compiled paths. Load this checked overlay
;; explicitly instead of the channel profile's compiled image builder.
(save-module-excursion
 (lambda ()
   (primitive-load (search-path %load-path "asahi/guix/build-system/installer.scm"))))

(define (input name)
  (primitive-load (string-append (dirname (current-filename)) "/" name)))

(define release-version "0.1")

(define setup-guix (input "setup-tools.scm"))
(define setup-channels (input "../channels.scm"))
(define setup-interface
  ((input "../systems/installer-ui.scm")
   setup-guix (local-file "../channels.scm")))

;; The Asahi Guix channel packages our RAM installation image.
;; Asahi's macOS installer supplies stage-1 m1n1 and extracts the Mac's firmware.
(package
  (name "hello-guix-setup")
  (version release-version)
  (source (setup-system setup-interface setup-guix setup-channels))
  (build-system installer-build-system)
  (arguments
   (list #:image-builder (input "../images/ram-image.scm")
         #:os-name "Guix System"
         #:os-description (string-append "Guix System (Hello Guix " release-version ")")))
  (home-page "https://github.com/hnarayanan/hello-guix")
  (synopsis "Install Guix System in Asahi's prepared space")
  (description "Boot a temporary Guix installation environment in RAM and
ask the standard Guix settings and service questions. Install the chosen
system in the root and EFI partitions prepared by Asahi, preserving the
Mac's early boot components and device firmware.")
  (license license:gpl3+))
