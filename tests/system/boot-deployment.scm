;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Exercise generated bootloader code on ordinary temporary files. Only the
;; host identity, mount observations and lock location are replaced. This is
;; not a complete guix system command, a FAT filesystem test or a boot test.

(use-modules (gnu bootloader)
             (gnu bootloader grub)
             (guix build utils)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix modules)
             (guix monads)
             (guix scripts system reconfigure)
             (guix store)
             (hello-guix system boot))

(define make-installer (@@ (hello-guix system boot) asahi-boot-installer))
(define directory (mkdtemp "/tmp/hello-guix-deployment-XXXXXX"))
(define target-root (string-append directory "/root"))
(define esp (string-append target-root "/boot/efi"))
(define events (string-append directory "/events"))
(define mode (string-append directory "/mode"))
(define loader-marker (string-append target-root "/boot/grub/loader-marker"))

(define (bundle name bytes)
  ;; boot.bin must be an ordinary file, not a file-union symlink.
  (computed-file name
    #~(begin
        (mkdir #$output)
        (call-with-output-file (string-append #$output "/boot.bin")
          (lambda (port) (display #$bytes port))))))

(define baseline (bundle "boot-baseline-fixture" "known working"))
(define candidate (bundle "boot-candidate-fixture" "candidate"))
(define subsequent (bundle "boot-subsequent-fixture" "subsequent"))
(define empty (bundle "boot-empty-fixture" ""))
(define bootloader-package (plain-file "grub-package-fixture" "fixture"))
(define old-config (plain-file "old-grub-config-fixture" "old configuration"))
(define new-config (plain-file "new-grub-config-fixture" "new configuration"))

(define inherited-installer
  #~(lambda (bootloader target root)
      (let ((contents (lambda (file)
                        (call-with-input-file file
                          (@ (ice-9 textual-ports) get-string-all)))))
        (let ((port (open-file #$events "a")))
          (write (list 'grub bootloader target root
                       (contents #$(string-append esp "/m1n1/boot.bin"))) port)
          (newline port)
          (close-port port))
        (call-with-output-file #$loader-marker
          (lambda (port) (display "new GRUB loader" port)))
        (when (string=? (contents #$mode) "grub-failure")
          (error "injected GRUB installation failure"))
        (when (string=? (contents #$mode) "mount-changed")
          (call-with-output-file #$mode
            (lambda (port) (display "wrong-id" port)))))))

(define baseline-installer (make-installer baseline inherited-installer))
(define candidate-installer (make-installer candidate inherited-installer))
(define subsequent-installer (make-installer subsequent inherited-installer))
(define empty-installer (make-installer empty inherited-installer))

(define configuration
  (bootloader-configuration
   (bootloader
    (bootloader
     (inherit grub-efi-removable-bootloader)
     (package bootloader-package)
     (installer candidate-installer)))
   (targets '("/boot/efi"))))

(define upstream-program
  (install-bootloader-program candidate-installer #f bootloader-package
                              new-config "/boot/grub/grub.cfg"
                              '("/boot/efi") target-root))

(define (fixture-program skipped-installation)
  (with-imported-modules
      (source-module-closure '((hello-guix system boot-files)
                               (guix build utils))
        #:select? (lambda (name)
                    (or (eq? (car name) 'hello-guix)
                        (guix-module-name? name))))
    (program-file "boot-deployment-fixture"
      #~(begin
          (use-modules (hello-guix system boot-files)
                       (guix build utils)
                       (ice-9 textual-ports)
                       (ice-9 match)
                       (srfi srfi-1)
                       (srfi srfi-64))

          (define (put file text)
            (call-with-output-file file (lambda (port) (display text port))))
          (define (contents file) (call-with-input-file file get-string-all))
          (define (record event)
            (let ((port (open-file #$events "a")))
              (write event port) (newline port) (close-port port)))
          (define (observations)
            (call-with-input-file #$events
              (lambda (port)
                (let loop ((result '()))
                  (let ((item (read port)))
                    (if (eof-object? item) (reverse result)
                        (loop (cons item result))))))))
          (define (grub-calls)
            (filter (lambda (event) (eq? 'grub (car event))) (observations)))
          (define (reset-mode value)
            (put #$mode value)
            (put #$events ""))
          (define live #$(string-append esp "/m1n1/boot.bin"))
          (define old #$(string-append esp "/m1n1/boot.bin.old"))
          (define gc-root #$(string-append target-root "/var/guix/gcroots/bootcfg"))
          (define config-file #$(string-append target-root "/boot/grub/grub.cfg"))
          (define module (resolve-module '(hello-guix system boot-files)))
          (define original-lock (module-ref module 'call-with-boot-lock))

          ;; These observations stand in for a booted Asahi host. The real
          ;; path checks, inherited callback, locking and durable writer run.
          (module-set! module 'current-asahi-efi-partuuid
            (lambda ()
              (record '(authority))
              (when (string=? (contents #$mode) "missing-authority")
                (error "injected missing Asahi boot identity"))
              "abc"))
          (module-set! module 'mounted-boot-identity
            (lambda (findmnt path)
              (record (list 'mount path))
              (match (contents #$mode)
                ("wrong-id" (values "def" "vfat"))
                ("wrong-filesystem" (values "abc" "ext4"))
                ("not-mounted" (error "injected missing mount"))
                (_ (values "ABC" "vfat")))))
          (module-set! module 'call-with-boot-lock
            (lambda (file thunk)
              (record (list 'lock file))
              (original-lock #$(string-append directory "/boot.lock") thunk)))

          (mkdir-p #$(string-append esp "/m1n1"))
          (mkdir-p (dirname gc-root))
          (mkdir-p (dirname config-file))
          (put live "known working")
          (put #$loader-marker "old GRUB loader")
          (reset-mode "normal")

          (test-begin "boot-deployment")
          (define runner (test-runner-current))
          (test-equal "image sentinel" 'skipped
            (#$empty-installer #$bootloader-package #f "/missing-root"))
          (test-equal "image sentinel has no host observations or lock" '()
            (observations))
          (test-equal "image sentinel preserves active bytes" "known working" (contents live))

          (test-equal "generated callback deploys its selected bundle" 'installed
            (#$candidate-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "selected candidate bytes" "candidate" (contents live))
          (test-equal "previous bytes retained" "known working" (contents old))
          (test-equal "inherited arguments and ordering"
            (list (list 'grub #$bootloader-package "/boot/efi" #$target-root "known working"))
            (grub-calls))
          (test-equal "host lock path is shared with manual return"
            '(lock "/run/hello-guix-boot.lock") (car (observations)))
          (test-equal "mounted destination checked before and after GRUB"
            (list #$esp #$esp)
            (map cadr (filter (lambda (event) (eq? 'mount (car event)))
                              (observations))))

          (reset-mode "normal")
          (test-equal "live root forwards the target path" 'unchanged
            (#$candidate-installer #$bootloader-package #$esp "/"))
          (test-equal "live-root arguments"
            (list (list 'grub #$bootloader-package #$esp "/" "candidate"))
            (grub-calls))
          (test-equal "unchanged bundle preserves recovery bytes" "known working" (contents old))

          (for-each
           (lambda (failure)
             (reset-mode failure)
             (test-error failure #t
               (#$subsequent-installer #$bootloader-package "/boot/efi" #$target-root))
             (test-equal "prevalidation prevents inherited GRUB" '() (grub-calls))
             (test-equal "prevalidation preserves active bytes" "candidate" (contents live)))
           '("missing-authority" "wrong-id" "wrong-filesystem" "not-mounted"))
          (reset-mode "normal")
          (test-error "empty selected bundle refused before GRUB" #t
            (#$empty-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "empty bundle prevents inherited GRUB" '() (grub-calls))
          (test-error "missing target has no live-target fallback" #t
            (#$candidate-installer #$bootloader-package "/missing" #$target-root))
          (test-equal "missing target prevents inherited GRUB" '() (grub-calls))

          (reset-mode "grub-failure")
          (test-error "inherited GRUB failure propagates" #t
            (#$subsequent-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "GRUB failure preserves active bytes" "candidate" (contents live))
          (test-equal "GRUB failure preserves recovery bytes" "known working" (contents old))
          (reset-mode "mount-changed")
          (test-error "changed mount after GRUB stops publication" #t
            (#$subsequent-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "changed mount preserves active bytes" "candidate" (contents live))

          (reset-mode "normal")
          (let* ((binding (module-variable module 'rename-file))
                 (original (variable-ref binding)))
            (dynamic-wind
              (lambda ()
                (variable-set! binding
                  (lambda (from to)
                    (if (string=? to live) (error "injected publication failure")
                        (original from to)))))
              (lambda ()
                (test-error "writer failure propagates through generated callback" #t
                  (#$subsequent-installer #$bootloader-package "/boot/efi" #$target-root))
                (test-equal "writer failure follows inherited GRUB" 1 (length (grub-calls)))
                (test-equal "writer failure preserves active bytes" "candidate" (contents live))
                (test-equal "writer failure keeps a usable previous copy" "candidate" (contents old)))
              (lambda () (variable-set! binding original))))

          (test-equal "second update" 'installed
            (#$subsequent-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "explicit return uses immutable baseline after repeated updates" 'installed
            (#$baseline-installer #$bootloader-package "/boot/efi" #$target-root))
          (test-equal "original working bytes restored" "known working" (contents live))
          (test-equal "return retains the most recent candidate" "subsequent" (contents old))

          ;; Run Guix's generated deployment program, not a local imitation.
          ;; Its grub.cfg write precedes the installer and survives failure.
          (symlink #$old-config gc-root)
          (symlink #$old-config config-file)
          (reset-mode "grub-failure")
          (test-error "upstream program propagates installer failure" #t
            (primitive-load #$upstream-program))
          (test-equal "upstream failure already changed grub.cfg" "new configuration"
            (contents config-file))
          (test-equal "upstream failure preserves previous GC root" #$old-config (readlink gc-root))
          (test-assert "upstream failure removes temporary GC root"
            (not (file-exists? (string-append gc-root ".new"))))
          (test-equal "upstream failure preserves early boot bundle" "known working" (contents live))
          (reset-mode "normal")
          (primitive-load #$upstream-program)
          (test-equal "upstream success promotes the new GC root" #$new-config (readlink gc-root))
          (test-equal "upstream success deploys selected bundle" "candidate" (contents live))
          (test-equal "inherited installation writes the new GRUB loader"
            "new GRUB loader" (contents #$loader-marker))

          ;; Restore the early bundle explicitly, then select the old menu.
          ;; Neither operation restores GRUB's installed loader files.
          (test-equal "explicit early-bundle return" 'installed
            (install-target-boot #$(file-append baseline "/boot.bin")
                                 "/boot/efi" #$target-root "abc" "unused-findmnt"))
          ;; This is the actual run-installer? #f branch used by native
          ;; generation switching. It is not a full CLI rollback test.
          (reset-mode "normal")
          #$skipped-installation
          (test-equal "native installer opt-out invokes no hardware callback" '() (observations))
          (test-equal "opt-out still selects the requested GRUB configuration"
            "old configuration" (contents config-file))
          (test-equal "opt-out preserves the explicitly restored early bundle"
            "known working" (contents live))
          (test-equal "bundle and menu return leave the newer GRUB loader installed"
            "new GRUB loader" (contents #$loader-marker))
          (test-end "boot-deployment")
          (unless (zero? (test-runner-fail-count runner))
            (error "Boot deployment fixture failed"))
          (display "Generated callback and Guix deployment program verified on temporary files.\n")
          (display "Native CLI rollback, real FAT durability and hardware boot are separate checks.\n")))))

(dynamic-wind
  (const #t)
  (lambda ()
    (with-store store
      (parameterize ((%graft? #f))
        (let* ((skipped
                (run-with-store store
                  (install-bootloader
                   (lambda (exp) (with-monad %store-monad (return exp)))
                   configuration old-config #:target target-root #:run-installer? #f)))
               (drv (run-with-store store (lower-object (fixture-program skipped))))
               (output (derivation->output-path drv)))
          (build-derivations store (list drv))
          (let ((closure (requisites store (list output))))
            (call-with-output-file "boot-deployment-inputs.scm"
              (lambda (port)
                (for-each
                 (lambda (input)
                   (let* ((input-drv (run-with-store store (lower-object input)))
                          (path (derivation->output-path input-drv)))
                     (unless (member path closure)
                       (error "Generated deployment code lost its selected bundle" path))
                     (write path port) (newline port)))
                 (list baseline candidate subsequent empty)))))
          (invoke output)))))
  (lambda () (delete-file-recursively directory)))
