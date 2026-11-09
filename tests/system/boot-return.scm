;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Tiny store generations and the production deployment entry points for the VM.

(use-modules (gnu packages base)
             (hello-guix system boot)
             (guix gexp)
             (guix modules))

(let ()
  (define kernel
    (file-union "boot-return-kernel"
      `(("Image" ,(plain-file "Image" "fixture kernel; not executable")))))

  (define (bundle name)
    (computed-file (string-append "boot-return-" name)
      #~(begin
          (mkdir #$output)
          (call-with-output-file (string-append #$output "/boot.bin")
            (lambda (port) (display #$name port)))
          (symlink #$kernel (string-append #$output "/kernel")))))

  (define bundle-a (bundle "retained-A"))
  (define bundle-b (bundle "B"))
  (define bundle-c (bundle "C"))
  (define system-a
    (file-union "boot-return-system-A"
      `(("kernel" ,kernel) ("asahi-boot" ,bundle-a))))

  (define without-bundle
    (file-union "boot-return-no-bundle" `(("kernel" ,kernel))))
  (define no-kernel (file-union "boot-return-no-kernel" '()))
  (define empty-kernel
    (file-union "boot-return-empty-kernel"
      `(("kernel/Image" ,(plain-file "empty-Image" "")))))

  (define modules
    (source-module-closure '((hello-guix system boot-files))
      #:select? (lambda (name) (eq? (car name) 'hello-guix))))

  ;; The VM has no Apple device tree. Only that authority observation is replaced;
  ;; the CLI, privilege check, store/kernel validation, lock and mount probe run.
  (define restore
    (with-imported-modules modules
      (program-file "boot-return-cli"
        #~(begin
            (use-modules (hello-guix system boot-files))
            (module-set! (resolve-module '(hello-guix system boot-files))
                         'current-asahi-efi-partuuid
                         (lambda () (or (getenv "BOOT_TEST_PARTUUID")
                                        (error "Missing fixture identity"))))
            (primitive-load #$((@@ (hello-guix system boot) boot-command)))))))

  (define grub
    #~(lambda (package target root)
        (call-with-output-file (string-append root target "/grub-fixture")
          (lambda (port) (display package port)))))

  (with-imported-modules modules
    (program-file "boot-return-check"
      #~(begin
          (use-modules (hello-guix system boot-files)
                       (ice-9 textual-ports))
          (module-set! (resolve-module '(hello-guix system boot-files))
                       'current-asahi-efi-partuuid
                       (lambda () (or (getenv "BOOT_TEST_PARTUUID")
                                      (error "Missing fixture identity"))))
          (define system-a #$system-a)
          (define restore #$restore)
          (define without-bundle #$without-bundle)
          (define no-kernel #$no-kernel)
          (define empty-kernel #$empty-kernel)
          (define checksum #$(file-append coreutils "/bin/sha256sum"))
          (define install-b #$((@@ (hello-guix system boot) asahi-boot-installer)
                               bundle-b grub))
          (define install-c #$((@@ (hello-guix system boot) asahi-boot-installer)
                               bundle-c grub))
          (primitive-load #$(local-file "boot-return-guest.scm")))))
)
