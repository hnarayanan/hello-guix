;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Locate the complete channel profile, not just its underlying Guix package.

(use-modules (guix describe))

(let ((profile (current-profile)))
  (unless profile
    (error "Select a Guix command from an existing pull or time-machine profile"))
  (display (canonicalize-path profile))
  (newline))
