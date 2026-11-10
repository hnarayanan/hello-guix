;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system software)
  #:use-module ((gnu packages gl) #:prefix guix:)
  #:use-module ((gnu packages gnome) #:prefix guix:)
  #:use-module ((gnu packages linux) #:prefix guix:)
  #:use-module ((gnu packages xdisorg) #:prefix guix:)
  #:use-module (gnu system)
  #:use-module (guix packages)
  #:use-module (hello-guix packages upstream)
  #:use-module ((hello-guix packages desktop) #:prefix platform:)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (with-apple-silicon-software))

(define (newer-replacements replacements)
  ;; Once ordinary Guix catches up, its package wins. A later channel update
  ;; must never send a system back to an older Hello Guix software release.
  (filter (match-lambda
            ((original . updated)
             (not (upstream-current? original
                                     (package-version
                                      (effective-package updated))))))
          replacements))

;; These updates retain their runtime interfaces. Check the store-name/output
;; requirements below; audio's changed daemon interfaces belong to its service.
(define %software-replacements
  (newer-replacements `((,guix:mesa . ,platform:mesa)
                        (,guix:libdrm . ,platform:libdrm)
                        (,guix:network-manager . ,platform:network-manager)
                        (,guix:bluez . ,platform:bluez))))

(define %software-transformation (gensym "hello-guix-software"))

(define (check-graft-compatible original updated)
  ;; Guix rewrites store references in place. The hash length and same-named
  ;; output suffixes are fixed, so the package name plus version must fit too.
  ;; This structural check does not establish runtime interface compatibility.
  ;; A chained target can select different packages directly and through an
  ;; indirect graft. Our carried overrides are concrete replacement-free recipes.
  (when (package-replacement updated)
    (error "Cannot graft Apple Silicon software: the replacement itself has a replacement"
           (package-full-name original) (package-full-name updated)
           (package-full-name (package-replacement updated))))
  (let* ((original-name (package-full-name original "-"))
         (updated-name (package-full-name updated "-"))
         (missing (lset-difference string=? (package-outputs original)
                                   (package-outputs updated))))
    (unless (= (string-length original-name) (string-length updated-name))
      (error "Cannot graft Apple Silicon software: package store-name lengths differ"
             original-name (string-length original-name)
             updated-name (string-length updated-name)))
    (unless (null? missing)
      (error "Cannot graft Apple Silicon software: replacement lacks required outputs"
             original-name updated-name missing))))

(define (package-graft-transformation previous replacements)
  (for-each (match-lambda
              ((original . updated)
               (check-graft-compatible original updated)))
            replacements)
  (if (or (null? replacements)
          (eq? replacements
               (procedure-property previous %software-transformation)))
      previous
      (let* ((rewrite
              (package-input-rewriting
               (map (match-lambda
                      ((original . updated)
                       (cons original
                             (package
                               (inherit original)
                               (replacement updated)))))
                    replacements)))
             (transform
              (lambda (object)
                (let ((object (previous object)))
                  (if (package? object) (rewrite object) object)))))
        ;; Retain one transformation when the hardware adapter is applied again.
        ;; Guix itself memoizes package rewriting and file-like lowering.
        (set-procedure-property! transform %software-transformation replacements)
        transform)))

(define (with-apple-silicon-software os)
  "Use the current compatible platform software throughout OS and its services.
Ordinary Guix grafts keep existing builds reusable. Non-package file-like inputs
and any user transformation keep their usual meaning."
  (let* ((previous (operating-system-transformation os))
         (transform (package-graft-transformation previous
                                                  %software-replacements)))
    (if (eq? transform previous) os
        (operating-system
          (inherit os)
          (transformation transform)))))
