;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (guix channels)
             (srfi srfi-1)
             (guix describe)
             (guix derivations)
             (guix packages)
             (guix store)
             (hello-guix system runtime))

(define (channel-codes file)
  (map channel->code
       (sort (primitive-load file)
             (lambda (left right)
               (string<? (symbol->string (channel-name left))
                         (symbol->string (channel-name right)))))))

(unless (equal? (channel-codes (cadr (command-line)))
                (channel-codes (caddr (command-line))))
  (error "Packaged Guix channels differ from the pinned inputs"))
(display "Packaged channel URLs, branches, commits and introductions match.\n")

;; The installed command must keep the whole channel profile.
;; Check that Guix finds its channel records through the package's symbolic link.
(with-store store
  (let* ((drv (package-derivation store (running-guix)))
         (result (derivation->output-path drv)))
    (build-derivations store (list drv))
    (unless (string=? (canonicalize-path result)
                     (canonicalize-path (current-profile)))
      (error "Runtime package did not preserve the executing channel profile"))))
(display "Runtime reuses the executing channel profile.\n")
