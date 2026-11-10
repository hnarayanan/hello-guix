;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (guix gexp))

;; The installed configuration needs these modules and their licenses.
;; Keep the installer code in the temporary setup system.
(file-union "hello-guix-configuration-support"
            `(("modules/hello-guix/system"
               ,(local-file "../../../hello-guix/system" #:recursive? #t))
              ("modules/hello-guix/packages"
               ,(local-file "../../../hello-guix/packages" #:recursive? #t))
              ("modules/hello-guix/apple-silicon.scm"
               ,(local-file "../../../hello-guix/apple-silicon.scm"))
              ("COPYING" ,(local-file "../../../COPYING"))
              ("LICENSES" ,(local-file "../../../LICENSES" #:recursive? #t))))
