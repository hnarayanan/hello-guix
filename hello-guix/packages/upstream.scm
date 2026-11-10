;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix packages upstream)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (effective-package upstream-current?))

(define (effective-package package)
  "Return Guix's direct build selection: PACKAGE or its immediate replacement.
This follows package->bag, not a recursive interpretation of replacement chains."
  (or (package-replacement package) package))

(define (upstream-current? package version)
  "Whether Guix directly builds PACKAGE at VERSION or a newer release."
  (version>=? (package-version (effective-package package)) version))
