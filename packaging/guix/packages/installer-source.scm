;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Patch copies of installer modules. Leave the installed channel modules unchanged.

(use-modules (gnu packages base)
             (guix gexp))

(define installer-file
  (or (search-path %load-path "gnu/installer.scm")
      (error "Cannot find the pinned Guix installer source")))

(define asahi-builder
  (or (search-path %load-path "asahi/guix/build-system/installer.scm")
      (error "Cannot find the pinned Asahi Guix image builder")))

(define source-checksums
  '(("asahi/guix/build-system/installer.scm"
     . "111478e2be132b85283db7f02e8f4aa1238ae6576fc8c70b1dd4ad3879ce85e2")
    ("gnu/installer.scm"
     . "3a5a89c614566b825ddd605b3e0d16ded0c1624653e7238ce2324bdd8a14b062")
    ("gnu/installer/newt/user.scm"
     . "b00b6886f671f7744b8e77f0153633910ad84c2ce846ae6b9c9c0e24ed14e64d")
    ("gnu/installer/newt/final.scm"
     . "8219956364ba11544e120fdce02dd3ae120e95e0efcd94bf419ff03cbedd0b6e")
    ("gnu/installer/final.scm"
     . "1284f6f6ae49b00c9cf11847b3d7bec19fb57c69e466da4224cf25c96fab0ca9")
    ("gnu/installer/utils.scm"
     . "60846e84b80bfa0aa33aa59342d1d7712ff7e3bbedbbf7a3b5e9ed3d1e623a1c")
    ("gnu/installer/hardware.scm"
     . "31f5ae4942ff653d15577beaf994a9102a9611b601818a64d7e51733ba6351a0")
    ("gnu/installer/services.scm"
     . "da2bcc701decff7790c3615da9f6a365d31eb8a2e2813b8f74acc6b474659382")))

(computed-file "guix-installer-source"
  (with-imported-modules '((guix build utils))
    #~(begin
        (use-modules (guix build utils)
                     (ice-9 rdelim)
                     (srfi srfi-13))
        (define (apply-series directory)
          (call-with-input-file (string-append directory "/series")
            (lambda (port)
              (let loop ((line (read-line port)))
                (unless (eof-object? line)
                  (let ((name (string-trim-both line)))
                    (unless (or (string-null? name) (string-prefix? "#" name))
                      (unless (and (string=? name (basename name))
                                   (string-suffix? ".patch" name))
                        (error "Invalid patch filename" name))
                      (invoke #$(file-append patch "/bin/patch")
                              "--batch" "--fuzz=0" "-p1" "-i"
                              (string-append directory "/" name))))
                  (loop (read-line port)))))))
        (mkdir-p (string-append #$output "/gnu"))
        (with-directory-excursion #$output
          (mkdir-p "asahi/guix/build-system")
          (copy-file #$(local-file asahi-builder) "asahi/guix/build-system/installer.scm")
          (copy-file #$(local-file installer-file) "gnu/installer.scm")
          (copy-recursively
           #$(local-file (string-append (dirname installer-file) "/installer")
                         "installer" #:recursive? #t)
           "gnu/installer")
          (for-each (lambda (file) (chmod file #o644))
                    '#$(map car source-checksums))
          (invoke #$(file-append coreutils "/bin/sha256sum") "--check"
                  #$(plain-file "installer-source.sha256"
                     (apply string-append
                       (map (lambda (file)
                              (string-append (cdr file) "  " (car file) "\n"))
                            source-checksums))))
          (for-each apply-series
            (list
             #$(local-file "../../../patches/asahi-guix-image-builder/patches"
                           "asahi-guix-patches" #:recursive? #t)
             #$(local-file "../../../patches/gnu-guix-installer/patches"
                           "guix-installer-patches" #:recursive? #t)))))))
