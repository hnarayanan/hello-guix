;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system firmware)
  #:use-module (guix gexp)
  #:use-module (guix memoization)
  #:export (apple-silicon-firmware))

(define apple-silicon-firmware
  (mlambda (source)
    "Expose the file-like firmware directory SOURCE in Guix's native layout.
SOURCE contains paths relative to the kernel's firmware search root. Keep
that exact input reachable through lib/firmware; do not extract archives or
inspect the machine evaluating the declaration."
    (unless (file-like? source)
      (error "Apple Silicon firmware requires a file-like directory" source))
    (computed-file "apple-silicon-firmware"
      #~(begin
          (unless (eq? 'directory (stat:type (stat #$source)))
            (error "Apple Silicon firmware input is not a directory" #$source))
          (mkdir #$output)
          (mkdir (string-append #$output "/lib"))
          (symlink #$source (string-append #$output "/lib/firmware"))))))
