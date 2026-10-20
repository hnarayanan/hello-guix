;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Use guix time-machine with packaging/guix/channels.scm so the tools and
;; installation image use the same package definitions.
(specifications->manifest
 '("bash" "coreutils" "diffutils" "findutils" "grep" "sed" "gawk"
   "make" "python" "patch" "tar" "gzip"
   "nss-certs" "glibc-locales"))
