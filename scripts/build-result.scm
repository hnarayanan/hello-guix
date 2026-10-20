;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Select the checked build result and keep its files protected from deletion.

(use-modules (guix store)
             (ice-9 match))

(match (cdr (command-line))
  ((candidate result)
   (let* ((result (string-append (canonicalize-path (dirname result))
                                "/" (basename result)))
          (previous (false-if-exception (lstat result))))
     (when (and previous (not (eq? 'symlink (stat:type previous))))
       (error "Build result is not a symlink; refusing to replace it" result))
     ;; The candidate's garbage-collection root protects it during this update.
     ;; Create the destination link before the daemon registers it as a root.
     (unless previous (symlink (canonicalize-path candidate) result))
     (catch #t
       (lambda ()
         (with-store store (add-indirect-root store result)))
       (lambda args
         (unless previous (delete-file result))
         (apply throw args)))
     (rename-file candidate result))))
