;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (guix channels)
             (ice-9 match)
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

;; Installer checks also require exact agreement with their release inputs.
;; Runtime checks use the selected profile directly and have no pin comparison.
(match (cdr (command-line))
  (() #t)
  ((expected actual)
   (unless (equal? (channel-codes expected) (channel-codes actual))
     (error "Packaged Guix channels differ from the pinned inputs"))
   (display "Packaged channel URLs, branches, commits and introductions match.\n"))
  (_ (error "Usage: runtime.scm [expected-channels actual-channels]")))

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
