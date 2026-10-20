;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run on ordinary temporary files, or on the target VM's mounted FAT filesystem.

(use-modules (hello-guix system boot-files)
             (guix build utils)
             (srfi srfi-64))

(define (run-tests directory)
  (test-begin "boot-files")
  (define runner (test-runner-current))
  (define (path name) (string-append directory "/" name))
  (define (write-file name text)
    (call-with-output-file (path name) (lambda (port) (display text port))))
  (define (contents name)
    (call-with-input-file (path name) (@ (ice-9 textual-ports) get-string-all)))
  (write-file "boot.bin" "working")
  (write-file "candidate" "candidate")
  (test-equal "install" 'installed (install-boot-bundle (path "candidate") directory))
  (test-equal "candidate selected" "candidate" (contents "boot.bin"))
  (test-equal "previous bundle retained" "working" (contents "boot.bin.old"))
  (test-equal "repeat" 'unchanged (install-boot-bundle (path "candidate") directory))
  (test-equal "repeat retains backup" "working" (contents "boot.bin.old"))
  (test-equal "restore backup in place" 'installed
    (install-boot-bundle (path "boot.bin.old") directory))
  (test-equal "old bytes restored" "working" (contents "boot.bin"))
  (test-equal "candidate available for return" "candidate" (contents "boot.bin.old"))
  (write-file "empty" "")
  (test-error "empty input refused" #t (install-boot-bundle (path "empty") directory))
  (test-error "missing input refused" #t (install-boot-bundle (path "missing") directory))
  (test-equal "failed input preserves working file" "working" (contents "boot.bin"))
  ;; Make the final rename fail. Copy and fsync operations still run.
  ;; Both the active bundle and its backup must remain usable.
  (define module (resolve-module '(hello-guix system boot-files)))
  (define original-rename rename-file)
  (define rename-binding (module-variable module 'rename-file))
  (variable-set! rename-binding
    (lambda (from to)
      (if (string=? to (path "boot.bin")) (error "injected publication failure")
          (original-rename from to))))
  (test-error "failed publication" #t (install-boot-bundle (path "candidate") directory))
  (test-equal "live bundle intact" "working" (contents "boot.bin"))
  (test-equal "recovery copy intact" "working" (contents "boot.bin.old"))
  (variable-set! rename-binding original-rename)
  (test-equal "retry after failure" 'installed (install-boot-bundle (path "candidate") directory))
  (test-equal "retry backup" "working" (contents "boot.bin.old"))
  (check-boot-target "abc" "ABC" "vfat")
  (test-error "wrong EFI identity refused" #t (check-boot-target "abc" "def" "vfat"))
  (test-error "missing chosen identity refused" #t (check-boot-target "" "" "vfat"))
  (test-error "non-FAT mount refused" #t (check-boot-target "abc" "abc" "ext4"))
  (test-end "boot-files")
  (unless (= 0 (test-runner-fail-count runner)) (error "Boot-file tests failed")))

(let* ((external (getenv "BOOT_TEST_DIRECTORY"))
       (directory (or external (mkdtemp "/tmp/hello-guix-boot-XXXXXX"))))
  (dynamic-wind
    (const #t)
    (lambda () (run-tests directory))
    (lambda () (unless external (delete-file-recursively directory)))))
