;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Populate and register the live root with Guix, then compress it for RAM.

(use-modules (gnu packages base)
             (gnu packages compression)
             (gnu packages gnupg)
             (gnu packages guile)
             (guix gexp)
             (guix modules)
             (guix self)
             (ice-9 match))

(lambda (system)
  (define schema (local-file (search-path %load-path "guix/store/schema.sql")))
  (define import-module?
    (match-lambda
      (('guix 'config) #f)
      (('guix 'git) #f)
      (('guix _ ...) #t)
      (('gnu _ ...) #t)
      (_ #f)))
  (computed-file "hello-guix-root.squashfs"
    (with-extensions (list guile-gcrypt guile-sqlite3)
      (with-imported-modules
          `(,@(source-module-closure
                '((gnu build image) (guix store database) (guix build utils))
                #:select? import-module?)
            ((guix config) => ,(make-config.scm)))
        #~(begin
            (use-modules (gnu build image)
                         (guix store database)
                         (guix build utils))
            (setenv "GUIX_LOCPATH" #$(file-append glibc-utf8-locales "/lib/locale"))
            (setlocale LC_ALL "en_US.utf8")
            (sql-schema #$schema)
            (initialize-root-partition "root"
              #:references-graphs '("system")
              #:deduplicate? #f #:system-directory #$system)
            ;; Fixed timestamps make the image independent of build time.
            (invoke #$(file-append squashfs-tools "/bin/mksquashfs")
                    "root" #$output "-all-root" "-noappend" "-comp" "xz"
                    "-processors" (number->string (parallel-job-count))
                    "-mkfs-time" "1" "-all-time" "1"))))
    #:options `(#:references-graphs (("system" ,system)))))
