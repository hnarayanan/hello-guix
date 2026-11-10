;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix apple-silicon)
  #:use-module (hello-guix system hardware)
  #:use-module (hello-guix system firmware)
  #:re-export (on-apple-silicon apple-firmware))
