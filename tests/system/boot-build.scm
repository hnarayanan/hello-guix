;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Build tiny bundles, with an optional already realised bundle as a byte oracle.

(use-modules (gnu packages base)
             (gnu packages bash)
             (gnu packages compression)
             (guix build utils)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix modules)
             (guix monads)
             (guix store)
             (hello-guix system boot)
             (ice-9 match)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define make-bundle (@@ (hello-guix system boot) make-asahi-boot-bundle))
(define arguments (cdr (command-line)))
(unless (= 3 (length arguments))
  (error "Expected reference bundle (or empty), jobs and cores" arguments))
(define reference (car arguments))

(define fixtures
  (computed-file "asahi-boot-build-fixtures"
    (with-imported-modules (source-module-closure '((guix build utils)))
      #~(begin
          (use-modules (guix build utils) (rnrs io ports))
          (define (put name bytes)
            (let ((file (string-append #$output name)))
              (mkdir-p (dirname file))
              (call-with-output-file file
                (lambda (port) (put-bytevector port bytes)) #:binary #t)))
          (mkdir-p (string-append #$output "/empty-kernel/lib/dtbs/apple"))
          ;; Create in a different order from the required lexical ordering.
          (put "/kernel/lib/dtbs/apple/z.dtb" #vu8(3 130))
          (put "/kernel/lib/dtbs/apple/nested/b.dtb" #vu8(2 129))
          (put "/kernel/lib/dtbs/apple/a.dtb" #vu8(1 128))
          (put "/kernel/lib/dtbs/apple/ignored.txt" #vu8(99))
          (put "/m1n1/libexec/m1n1.bin" #vu8(0 255 77 49))
          (put "/u-boot/libexec/u-boot-nodtb.bin" #vu8(66 79 79 84 0 255))))))
(define kernel (file-append fixtures "/kernel"))
(define m1n1 (file-append fixtures "/m1n1"))
(define u-boot (file-append fixtures "/u-boot"))
(define bundle (make-bundle kernel m1n1 u-boot))

;; The old Asahi builder writes m1n1, sorted DTBs, then `gzip -c U-BOOT`.
;; Keep that original shell operation as an independent byte-format oracle.
(define expected
  (computed-file "asahi-boot-build-expected"
    (with-imported-modules (source-module-closure '((guix build utils)))
      #~(begin
          (use-modules (guix build utils))
          (setenv "PATH" (string-append #$coreutils "/bin:" #$gzip "/bin"))
          (invoke #$(file-append bash-minimal "/bin/sh") "-c"
                  (string-append
                   "cat " #$(file-append m1n1 "/libexec/m1n1.bin") " "
                   #$(file-append kernel "/lib/dtbs/apple/a.dtb") " "
                   #$(file-append kernel "/lib/dtbs/apple/nested/b.dtb") " "
                   #$(file-append kernel "/lib/dtbs/apple/z.dtb") " > " #$output
                   " && gzip -c " #$(file-append u-boot "/libexec/u-boot-nodtb.bin")
                   " >> " #$output))))))

(define (contents file)
  (call-with-input-file file get-bytevector-all #:binary #t))

(test-begin "boot-build")
(define runner (test-runner-current))
(with-store store
  (apply set-build-options store
         (append (if (string-null? (cadr arguments)) '()
                     (list #:max-build-jobs (string->number (cadr arguments))))
                 (if (string-null? (caddr arguments)) '()
                     (list #:build-cores (string->number (caddr arguments))))))
  (parameterize ((%graft? #f))
    (define (lower object)
      (run-with-store store (lower-object object)))
    (define (build object)
      (let ((drv (lower object)))
        (build-derivations store (list drv))
        (derivation->output-path drv)))
    (let* ((drv (lower bundle))
           (actual (build bundle))
           (old-format (build expected))
           (boot-file (string-append actual "/boot.bin")))
      (test-equal "direct binary copying preserves the upstream format"
        (contents old-format) (contents boot-file))
      (test-equal "binary m1n1 and all Apple DTBs in lexical order"
        #vu8(0 255 77 49 1 128 2 129 3 130)
        (call-with-input-file boot-file
          (lambda (port) (get-bytevector-n port 10)) #:binary #t))
      (test-assert "construction has no GRUB or image-library inputs"
        (every (lambda (input)
                 (let ((path (derivation-input-path input)))
                   (not (any (lambda (name) (string-contains path name))
                             '("-grub-efi-" "-guile-sqlite3-" "-guile-gcrypt-")))))
               (derivation-inputs drv)))
      (test-assert "missing U-Boot rejects the build"
        (catch #t
          (lambda ()
            (build (make-bundle kernel m1n1 (file-append fixtures "/missing-u-boot")))
            #f)
          (lambda _ #t)))
      (test-assert "a kernel without Apple device trees rejects the build"
        (catch #t
          (lambda ()
            (build (make-bundle (file-append fixtures "/empty-kernel") m1n1 u-boot))
            #f)
          (lambda _ #t)))
      (test-equal "the valid immutable bundle survives a failed build"
        (contents old-format) (contents boot-file)))
    (unless (string-null? reference)
      (let* ((reference (canonicalize-path reference))
             (paths (map (lambda (name)
                           (canonicalize-path (string-append reference "/" name)))
                         '("kernel" "m1n1" "u-boot"))))
        (unless (and (valid-path? store reference)
                     (every (lambda (path) (valid-path? store path)) paths))
          (error "Reference and its inputs must already exist in the Guix store" reference))
        ;; symlink-to constructs only three tiny aliases. Their store references
        ;; retain these existing inputs; no kernel/source tree is copied or built.
        (let* ((actual (build (apply make-bundle (map symlink-to paths))))
               (original (string-append reference "/boot.bin"))
               (rebuilt (string-append actual "/boot.bin"))
               (closure (requisites store (list actual))))
          (test-assert "reference inputs are retained without rebuilding them"
            (every (lambda (path) (member path closure)) paths))
          (test-assert "cached reference bundle is byte-identical"
            (equal? (contents original) (contents rebuilt)))
          (call-with-output-file "boot-build-reference.scm"
            (lambda (port)
              (write `((reference ,reference) (inputs ,paths)
                       (rebuilt ,actual) (bytes ,(stat:size (stat original)))) port)
              (newline port)))
          (format #t "Compared cached boot bundle: ~a (~a bytes)~%"
                  reference (stat:size (stat original))))))))
(test-end "boot-build")
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
