;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (guix channels)
             (gnu packages package-management))

(guix-for-channels
 (primitive-load
  (string-append (dirname (current-filename)) "/../channels.scm")))
