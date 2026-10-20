;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (guix gexp))

(define installer-test
  (primitive-load (string-append (dirname (current-filename)) "/installer-runtime.scm")))
(define configuration-support
  (primitive-load (string-append (dirname (current-filename))
                                 "/../../packaging/guix/packages/configuration-support.scm")))

(installer-test "check-mac-configuration"
  #~(begin
      (use-modules (hello-guix installer linux configuration))
      (for-each
       (lambda (file) (unless (primitive-load file) (exit #f)))
       (list #$(local-file "../target.scm")
             #$(local-file "../installer-final.scm")
             #$(local-file "../installation-files.scm")
             #$(local-file "../installation.scm")))
      ((@ (hello-guix installer linux installation-files) prepare-configuration-support)
       #$configuration-support #$(local-file "../../packaging/guix/channels.scm")
       (cadr (command-line)))
      (primitive-load #$(local-file "../configuration.scm"))))
