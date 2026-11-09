;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu packages gnupg)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages tls)
             (hello-guix system runtime)
             (guix gexp)
             (guix modules)
             ((guix self) #:select (make-config.scm))
             (ice-9 match))

;; Import installer modules separately from the runtime's package and system
;; definitions, as the installer program does.
(define (import-module? name)
  (match name
    (('guix 'config) #f)
    (('hello-guix 'installer 'linux _ ...) #t)
    (('gnu 'installer _ ...) #t)
    (('gnu 'build _ ...) #t)
    (('guix 'build _ ...) #t)
    (('guix 'read-print) #t)
    (_ #f)))

;; The formatters need Newt and JSON modules even without screen output.
;; Supply the same Guile extensions as Guix's installer program.
(define runtime (running-guix))

(lambda (name body)
  (with-extensions (list runtime guile-gcrypt guile-newt
                       guile-parted guile-bytestructures guile-json-3
                       guile-git guile-webutils guile-gnutls
                       guile-zlib guile-zstd)
    (with-imported-modules
        `(,@(source-module-closure
             '((hello-guix installer linux install)
               (hello-guix installer linux configuration)
               (hello-guix installer linux setup-state)
               (gnu installer newt final)
               (gnu installer hardware)
               (gnu installer hostname)
               (gnu installer locale)
               (gnu installer newt keymap)
               (gnu installer services)
               (gnu installer timezone)
               (gnu installer user))
             #:select? import-module?)
          ((guix config) => ,(make-config.scm)))
      (program-file name
        #~(begin
            ;; Search the imported modules before the runtime's standard installer modules.
            (eval-when (expand load eval)
              (let ((source (string-append #$runtime "/share/guile/site/"
                                           (effective-version)))
                    (compiled (string-append #$runtime "/lib/guile/"
                                             (effective-version) "/site-ccache")))
                (set! %load-path (append (delete source %load-path) (list source)))
                (set! %load-compiled-path
                  (append (delete compiled %load-compiled-path) (list compiled)))))
            #$body)
        #:guile guile-3.0-latest))))
