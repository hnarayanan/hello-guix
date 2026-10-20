;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Collect the image's build sources, including sources in G-expressions.
;; Use Guix's derivation graph to include inputs outside package definitions.

(use-modules (guix derivations)
             (guix store)
             ((guix build syscalls) #:select (mkdtemp!))
             ((guix build utils) #:select (delete-file-recursively))
             (ice-9 match)
             (ice-9 popen)
             (ice-9 pretty-print)
             (json)
             (srfi srfi-1))

;; Use a hash table to avoid repeated comparisons between derivations.
;; Keep the input order. Sort archive entries separately.
(define* (unique-by values #:optional (key identity))
  (let ((seen (make-hash-table)))
    (filter (lambda (value)
              (let ((name (key value)))
                (and (not (hash-ref seen name))
                     (begin (hash-set! seen name #t) #t))))
            values)))

(match (cdr (command-line))
  (((and action (or "plan" "archive")) file)
   (let* ((root (read-derivation-from-file file))
          (graph (unique-by
                  (cons root
                        (map derivation-input-derivation
                             (derivation-prerequisites root)))
                  derivation-file-name))
          (fixed (filter fixed-output-derivation? graph)))
     ;; Include the recipes for Guix's precompiled bootstrap tools,
     ;; but omit the binaries from this source archive.
     (define (bootstrap? drv)
       (let ((urls (assoc-ref (derivation-builder-environment-vars drv) "url")))
         (and urls (string-contains urls "/guix/bootstrap/"))))
     (define (outputs derivations)
       (unique-by
        (append-map (lambda (drv)
                      (map (lambda (entry) (derivation-output-path (cdr entry)))
                           (derivation-outputs drv))) derivations)))
     (define sources (outputs (remove bootstrap? fixed)))
     (with-store store
       (define recipes (requisites store (list (derivation-file-name root))))
       (define items (sort (unique-by (append sources recipes)) string<?))
       (case (string->symbol action)
         ((plan)
          (pretty-print `((derivation . ,file)
                          (source-inputs . ,(length sources))
                          (recipes-and-local-inputs . ,(length recipes))
                          (bootstrap-binaries-not-included . ,(sort (outputs (filter bootstrap? fixed)) string<?)))))
         ((archive)
          ;; Prevent garbage collection of inputs while tar reads them.
          ;; Guix authenticates substitutes, or downloads sources and checks their hashes.
          (for-each (lambda (path) (add-temp-root store path)) items)
          (build-derivations store (remove bootstrap? fixed))
          (let ((directory (mkdtemp! "/tmp/hello-guix-sources-XXXXXX")))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let ((manifest (string-append directory "/guix-sources.json")))
                  (call-with-output-file manifest
                    (lambda (port)
                      (scm->json
                       `((format . 1)
                         (derivation . ,(derivation-file-name root))
                         (outputs . ,(list->vector (outputs (list root))))
                         (store_items . ,(list->vector (map basename items))))
                       port)
                      (newline port)))
                  (chmod manifest #o644))
                (let ((tar (open-pipe* OPEN_WRITE "tar" "--create" "--format=posix"
                             "--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime"
                             "--sort=name" "--mode=u+rwX"
                             "--numeric-owner" "--owner=0" "--group=0" "--mtime=@1"
                             "--directory" directory "guix-sources.json"
                             "--directory=/gnu/store" "--verbatim-files-from"
                             "--files-from=-")))
                  (for-each (lambda (path) (display (basename path) tar) (newline tar)) items)
                  (unless (zero? (close-pipe tar)) (error "Source archiving failed"))))
              (lambda () (delete-file-recursively directory)))))))))
  (_ (error "Usage: guix repl scripts/source-archive.scm plan|archive PAYLOAD.drv")))
