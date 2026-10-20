;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (guix gexp))

;; The installed configuration needs these modules and their licenses.
;; Keep the installer code in the temporary setup system.
(file-union "hello-guix-configuration-support"
            `(("modules/hello-guix/system"
               ,(local-file "../../../src/hello-guix/system" #:recursive? #t))
              ("COPYING" ,(local-file "../../../COPYING"))
              ("LICENSES" ,(local-file "../../../LICENSES" #:recursive? #t))))
