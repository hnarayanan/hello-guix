;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Full Guix command dispatch in a disposable container with its own Shepherd.
;; Kernel/GRUB/mount observations are fixtures; system activation is real.

(use-modules (guix build utils)
             (ice-9 textual-ports)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 regex)
             (srfi srfi-1))

(unless (and (equal? "1" (getenv "BOOT_CLI_ISOLATED"))
             (getenv "BOOT_CLI_HOST_PIDNS")
             (not (equal? (getenv "BOOT_CLI_HOST_PIDNS")
                          (readlink "/proc/self/ns/pid")))
             (zero? (getuid)))
  (error "Run this fixture only through make check code only=runtime-system"))

(define (required name)
  (or (getenv name) (error "Missing fixture input" name)))
(define guix (required "BOOT_CLI_GUIX"))
(define config-a (required "BOOT_CLI_A"))
(define config-b (required "BOOT_CLI_B"))
(define config-c (required "BOOT_CLI_C"))
(define return-command (required "BOOT_CLI_RETURN"))
(define baseline (required "BOOT_CLI_BASELINE"))
(define expected-b (required "BOOT_CLI_EXPECTED_B"))
(define expected-c (required "BOOT_CLI_EXPECTED_C"))
(define live "/boot/efi/m1n1/boot.bin")
(define bootcfg "/boot/grub/grub.cfg")
(define calls "/var/log/boot-cli-installer.log")
(define profile "/var/guix/profiles/system")
(define records "/records")
(define sequence 0)
(define assertions 0)

(define (contents file) (call-with-input-file file get-string-all))
(define (optional-contents file)
  (and (file-exists? file) (contents file)))
(define (assert description value)
  (set! assertions (1+ assertions))
  (format #t "~a: ~a~%" (if value "PASS" "FAIL") description)
  (force-output)
  (unless value (error description)))
(define (check description expected actual)
  (unless (equal? expected actual)
    (format #t "Expected: ~s~%Observed: ~s~%" expected actual))
  (assert description (equal? expected actual)))
(define (generation)
  (match (string-split (basename (readlink profile)) #\-)
    (("system" number "link") number)
    (_ (error "Unexpected system generation link" (readlink profile)))))
(define (default-menu-system)
  ;; Merely finding an old system anywhere would also match a history entry.
  (let* ((text (contents bootcfg))
         (entry (string-match "gnu[.]system=([^[:space:]\"]+)" text)))
    (unless (and entry (string-match "set default=\"?0\"?" text))
      (error "Expected a default first system entry" text))
    (canonicalize-path (match:substring entry 1))))
(define (snapshot)
  (list (canonicalize-path profile)
        (canonicalize-path "/run/current-system")
        (canonicalize-path "/run/booted-system")
        (gethostname)
        (optional-contents "/etc/hostname")
        (contents live)
        (optional-contents (string-append live ".old"))
        (optional-contents bootcfg)
        (optional-contents "/boot/efi/grub-fixture")
        (optional-contents calls)
        (scandir "/var/guix/profiles")))

(define* (run name arguments #:key (success? #t))
  (set! sequence (1+ sequence))
  (let* ((file (format #f "~a/~2,'0d-~a.log" records sequence name))
         (args (append '("system" "--no-grafts" "--no-substitutes"
                         "--max-jobs=1" "--cores=2") arguments))
         (status
          (begin
            (format #t "Command ~a: ~s~%" name (cons guix args))
            (force-output)
            (let ((port (open-file (string-append records "/commands.scm") "a")))
              (write (cons guix args) port) (newline port) (close-port port))
            (with-output-to-file file
              (lambda ()
                (with-error-to-port (current-output-port)
                  (lambda () (apply system* guix args))))))))
    (unless (eq? success? (zero? status))
      (display (contents file))
      (error "Unexpected command result" name status))
    (format #t "Command ~a exited ~a; log ~a~%" name (status:exit-val status) file)
    (force-output)
    (contents file)))

(define (built-system output)
  (match (filter (lambda (line) (and (string-prefix? "/gnu/store/" line)
                                    (string-suffix? "-system" line)))
                 (string-split output #\newline))
    ((system) system)
    (paths (error "Expected one built system" paths))))

(catch #t
  (lambda ()
    (check "baseline profile" baseline (canonicalize-path profile))
    (check "baseline activation" "boot-cli-a" (gethostname))
    (check "accepted baseline differs deliberately from retained bytes" "accepted-A" (contents live))
    (assert "bootstrap environment does not leak into commands"
            (not (getenv "GUIX_NEW_SYSTEM")))
    (define baseline-generation (generation))
    (define initial (snapshot))
    (copy-file live "/records/accepted-boot.bin")
    (call-with-output-file "/records/accepted-system"
      (lambda (port) (display baseline port) (newline port)))
    (run "list-generations" '("list-generations"))
    (define system-b
      (built-system (run "build-b" (list "build" "--save-provenance" config-b))))
    (check "building a system has no deployment or activation effects" initial (snapshot))
    (run "dry-run-c" (list "reconfigure" "--dry-run" "--no-kexec" "--skip-checks" config-c))
    (check "dry-run has no deployment or activation effects" initial (snapshot))

    (run "reconfigure-b" (list "reconfigure" "--no-kexec" "--skip-checks" config-b))
    (check "normal reconfiguration selects the previously built system" system-b
           (canonicalize-path profile))
    (check "normal reconfiguration activates its system" system-b
           (canonicalize-path "/run/current-system"))
    (check "normal reconfiguration changes the live hostname" "boot-cli-b" (gethostname))
    (check "normal reconfiguration deploys its bundle" (contents expected-b) (contents live))
    (check "first deployment preserves the accepted baseline" "accepted-A"
           (contents (string-append live ".old")))
    (check "normal reconfiguration called the matching inherited GRUB installer"
           "B\n" (contents calls))
    (check "normal reconfiguration installed the matching GRUB fixture"
           "B" (contents "/boot/efi/grub-fixture"))
    (check "normal reconfiguration selects the new default menu entry"
           system-b (default-menu-system))
    (define b-generation (generation))
    (define b-menu (contents bootcfg))
    (define b-calls (contents calls))
    (define b-loader (contents "/boot/efi/grub-fixture"))

    (run "without-bootloader-c"
         (list "reconfigure" "--no-bootloader" "--no-kexec" "--skip-checks" config-c))
    (define system-c (canonicalize-path profile))
    (assert "opt-out still selects a new system" (not (equal? system-b system-c)))
    (check "opt-out still activates its system" system-c
           (canonicalize-path "/run/current-system"))
    (check "opt-out changes the live hostname" "boot-cli-c" (gethostname))
    (check "opt-out leaves the earlier boot bundle" (contents expected-b) (contents live))
    (check "opt-out leaves the GRUB menu" b-menu (contents bootcfg))
    (check "opt-out leaves the GRUB binary" b-loader (contents "/boot/efi/grub-fixture"))
    (check "opt-out does not call the inherited installer" b-calls (contents calls))
    (check "opt-out retains its matching bundle without deploying it"
           (contents expected-c) (contents (string-append system-c "/asahi-boot/boot.bin")))

    (run "roll-back" '("roll-back"))
    (check "native rollback selects B" system-b (canonicalize-path profile))
    (check "native rollback current-system follows the boot-time system" baseline
           (canonicalize-path "/run/current-system"))
    (check "native rollback updates the configured hostname" "boot-cli-b"
           (string-trim-both (contents "/etc/hostname")))
    (check "native rollback does not restart the live hostname service" "boot-cli-c" (gethostname))
    (check "native rollback selects B generation" b-generation (generation))
    (check "native rollback does not call the bundle/GRUB installer" b-calls (contents calls))

    (run "switch-to-a" (list "switch-generation" baseline-generation))
    (check "native generation selection returns to A" baseline (canonicalize-path profile))
    (check "native generation selection selects A as current system" baseline
           (canonicalize-path "/run/current-system"))
    (check "native generation selection updates configured hostname" "boot-cli-a"
           (string-trim-both (contents "/etc/hostname")))
    (check "native generation selection leaves B early bundle" (contents expected-b) (contents live))
    (check "native generation selection leaves later GRUB binary" b-loader
           (contents "/boot/efi/grub-fixture"))
    (check "native generation selection skips inherited installer" b-calls (contents calls))
    (check "native generation selection restores A as the default menu entry"
           baseline (default-menu-system))

    ;; The recovery command is retained independently of whichever generation
    ;; is selected. Check exact bytes saved while the baseline was working.
    (check "saved baseline survived all changes" "accepted-A"
           (contents "/records/accepted-boot.bin"))
    (invoke return-command "--restore" "/records/accepted-boot.bin" baseline)
    (check "explicit return restores exact accepted bytes" "accepted-A" (contents live))
    (check "explicit return preserves later GRUB" b-loader (contents "/boot/efi/grub-fixture"))
    ;; A deployment refusal is not an atomic rollback of upstream activation.
    (call-with-output-file "/var/lib/boot-cli/wrong-target" (const #t))
    (define refused
      (run "wrong-target-c"
           (list "reconfigure" "--no-kexec" "--skip-checks" config-c) #:success? #f))
    (assert "deployment fails for the intended partition mismatch"
            (string-contains refused
              "The mounted EFI partition does not match the intended target"))
    (check "failed deployment has already selected C" system-c (canonicalize-path profile))
    (check "failed deployment has already activated C" system-c
           (canonicalize-path "/run/current-system"))
    (check "failed deployment has already selected C's boot menu"
           system-c (default-menu-system))
    (check "destination refusal preserves accepted boot bytes" "accepted-A" (contents live))
    (check "destination refusal prevents inherited GRUB" b-calls (contents calls))
    (delete-file "/var/lib/boot-cli/wrong-target")
    (run "return-after-failure" (list "switch-generation" baseline-generation))
    (invoke return-command "--restore" "/records/accepted-boot.bin" baseline)
    (check "checked return after failure selects A" baseline (canonicalize-path profile))
    (check "checked return after failure preserves accepted bytes" "accepted-A" (contents live))
    (check "build and reconfiguration never change the booted system" baseline
           (canonicalize-path "/run/booted-system"))
    (format #t "HELLO-GUIX-CLI-PASS (~a assertions)~%" assertions))
  (lambda (key . arguments)
    (print-exception (current-error-port) #f key arguments)
    (display "HELLO-GUIX-CLI-FAIL\n")
    (force-output)
    (exit 1)))
