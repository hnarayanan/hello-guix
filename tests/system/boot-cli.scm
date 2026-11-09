;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; A real Guix/Shepherd command lifecycle in an unprivileged private container.

(use-modules (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages base)
             (gnu packages guile)
             (gnu system)
             (guix gexp)
             (guix modules)
             (hello-guix system runtime))

(define here (dirname (current-filename)))
(primitive-load (string-append here "/boot-cli-system.scm"))

(define definitions (local-file "boot-cli-system.scm"))
(define hello-modules
  (file-union "hello-guix-runtime-modules"
              `(("hello-guix/system"
                 ,(local-file "../../hello-guix/system" #:recursive? #t)))))
(define guix (running-guix))
(define baseline (make-boot-cli-system "A"))

;; Native reconfiguration lowers its installer after building the system.
;; Generation switching also reconstructs canonical GRUB by name, including
;; its default theme and locales. Retain those inputs here so the outer build
;; preview includes them; --no-substitutes alone does not prevent source builds.
(define canonical-grub
  (lookup-bootloader-by-name 'grub-efi-removable-bootloader))
(define command-inputs
  (file-union "boot-cli-command-inputs"
    `(("grub" ,(bootloader-package canonical-grub))
      ("forward-menu" ,(operating-system-bootcfg baseline))
      ("rollback-menu"
       ,(operating-system-bootcfg
         (operating-system
          (inherit baseline)
          (bootloader (bootloader-configuration (bootloader canonical-grub)))))))))

;; The container shares a running kernel, so give native boot-time-system a
;; command line describing the fixture baseline rather than the host system.
(define kernel-command-line
  (mixed-text-file "boot-cli-cmdline"
    "gnu.system=" baseline " gnu.load=" baseline "/boot\n"))

(define (configuration variant)
  (mixed-text-file (string-append "boot-cli-" variant ".scm")
    "(add-to-load-path \"" hello-modules "\")\n"
    "(primitive-load \"" definitions "\")\n"
    ;; The outer constructor gives native provenance this entry-point file.
    "(operating-system (inherit (make-boot-cli-system \"" variant "\"))\n"
    "  (host-name \"boot-cli-" (string-downcase variant) "\"))\n"))

(define config-a (configuration "A"))
(define config-b (configuration "B"))
(define config-c (configuration "C"))

(define guest
  (with-imported-modules (source-module-closure '((guix build utils)))
    (program-file "boot-cli-guest"
      #~(begin (primitive-load #$(local-file "boot-cli-guest.scm")))
      #:guile guile-3.0-latest)))

(define run
  (with-imported-modules
      (source-module-closure '((gnu build linux-container)
                               (gnu system file-systems)
                               (guix build utils)
                               (guix build syscalls)))
    (program-file "boot-cli-run"
      #~(begin
          (use-modules (gnu build linux-container)
                       (gnu system file-systems)
                       (guix build utils)
                       (guix build syscalls)
                       (ice-9 match)
                       (ice-9 textual-ports)
                       (srfi srfi-1))
          (define records
            (match (cdr (command-line))
              ((directory) (canonicalize-path directory))
              (_ (error "Usage: boot-cli-run ABSOLUTE-RECORD-DIRECTORY"))))
          (define raw-socket (or (getenv "GUIX_DAEMON_SOCKET")
                                 "/var/guix/daemon-socket/socket"))
          (define socket
            (if (string-prefix? "unix://" raw-socket)
                (substring raw-socket 7) raw-socket))
          (unless (and (string-prefix? "/" socket)
                       (eq? 'socket (stat:type (stat socket))))
            (error "This fixture requires a local Unix Guix daemon socket" raw-socket))
          (define host-namespaces
            (map (lambda (name)
                   (cons name (readlink (string-append "/proc/self/ns/" name))))
                 '("mnt" "pid" "user" "uts" "net")))
          (define (binding source destination writable?)
            (file-system
             (device source) (mount-point destination) (type "none")
             (flags (if writable? '(bind-mount) '(bind-mount read-only)))
             (check? #f)))
          (define mounts
            (list (binding "/gnu/store" "/gnu/store" #f)
                  (binding #$kernel-command-line "/proc/cmdline" #f)
                  (binding (dirname socket) "/host-daemon" #f)
                  (binding records "/records" #t)))
          (define status
            (call-with-container mounts
              (lambda ()
                (for-each
                 (lambda (entry)
                   (when (string=? (cdr entry)
                                  (readlink (string-append "/proc/self/ns/" (car entry))))
                     (error "Namespace isolation failed" (car entry))))
                 host-namespaces)
                (setenv "BOOT_CLI_ISOLATED" "1")
                (setenv "BOOT_CLI_HOST_PIDNS" (assoc-ref host-namespaces "pid"))
                (setenv "GUIX_DAEMON_SOCKET"
                        (string-append "/host-daemon/" (basename socket)))
                (setenv "HOME" "/root")
                (setenv "TMPDIR" "/tmp")
                (setenv "LC_ALL" "C")
                (setenv "PATH" #$(file-append guix "/bin"))
                (unsetenv "GUIX_NEW_SYSTEM")
                (setenv "BOOT_CLI_GUIX" #$(file-append guix "/bin/guix"))
                (setenv "BOOT_CLI_A" #$config-a)
                (setenv "BOOT_CLI_B" #$config-b)
                (setenv "BOOT_CLI_C" #$config-c)
                (setenv "BOOT_CLI_BASELINE" #$baseline)
                (setenv "BOOT_CLI_RETURN" #$boot-cli-return)
                (setenv "BOOT_CLI_EXPECTED_A" #$(file-append (boot-cli-bundle "A") "/boot.bin"))
                (setenv "BOOT_CLI_EXPECTED_B" #$(file-append (boot-cli-bundle "B") "/boot.bin"))
                (setenv "BOOT_CLI_EXPECTED_C" #$(file-append (boot-cli-bundle "C") "/boot.bin"))
                (setenv "BOOT_CLI_ESPDIR" "/boot/efi")
                (for-each mkdir-p '("/run" "/etc" "/bin" "/root" "/home" "/tmp"
                                    "/var/log" "/var/lib/boot-cli" "/var/guix/profiles"
                                    "/var/guix/gcroots" "/boot/grub" "/boot/efi/m1n1"))
                (symlink #$baseline "/var/guix/profiles/system-1-link")
                (symlink "system-1-link" "/var/guix/profiles/system")
                (call-with-output-file "/boot/efi/m1n1/boot.bin"
                  (lambda (port) (display "accepted-A" port)))
                (call-with-output-file "/boot/grub/grub.cfg"
                  (lambda (port) (format port "# Initial fixture menu: ~a~%" #$baseline)))
                ;; The scenario runs beside genuine Shepherd PID1. It waits for
                ;; Shepherd's socket, then runs separate native CLI processes.
                (safe-clone SIGCHLD
                  (lambda ()
                    (let wait ((left 120))
                      (unless (and (file-exists? "/var/run/shepherd/socket")
                                   (file-exists? "/run/booted-system")
                                   (string=? (gethostname) "boot-cli-a"))
                        (when (zero? left) (error "Baseline Shepherd did not become ready"))
                        (sleep 1) (wait (1- left))))
                    (let ((result (system* #$guest)))
                      (call-with-output-file "/records/guest.exit"
                        (lambda (port) (display (or (status:exit-val result) 1) port)))
                      (force-output)
                      (kill 1 SIGTERM)))
                  (lambda (pid)
                    ;; Only bootstrap activation needs this input. The
                    ;; separately forked scenario exercises the native CLI
                    ;; with an ordinary, clean environment.
                    (setenv "GUIX_NEW_SYSTEM" #$baseline)
                    (primitive-load #$(file-append baseline "/boot")))))
              #:host-uids 1
              #:writable-root? #t
              ;; Upstream system containers use this for Guix issue4788.
              #:lock-mounts? #f
              #:process-spawned-hook
              (lambda (pid)
                ;; Fixture cancellation must also stop a Shepherd that has
                ;; changed session. Killing namespace PID1 removes every
                ;; process in that namespace, including descendants.
                (for-each
                 (lambda (signal)
                   (sigaction signal
                     (lambda (_) (false-if-exception (kill pid SIGKILL)))))
                 (list SIGINT SIGTERM))
                (call-with-output-file (string-append records "/container.pid")
                  (lambda (port) (display pid port))))))
          (define exit-file (string-append records "/guest.exit"))
          (unless (file-exists? exit-file)
            (error "Container ended before the command checks completed" status))
          (exit (call-with-input-file exit-file read))))))

(file-union "boot-cli-check"
 `(("run" ,run)
   ("command-inputs" ,command-inputs)
   ("bootstrap-system" ,baseline)
   ("A.scm" ,config-a) ("B.scm" ,config-b) ("C.scm" ,config-c)
   ("guix" ,(file-append guix "/bin/guix"))
   ("timeout" ,(file-append coreutils "/bin/timeout"))))
