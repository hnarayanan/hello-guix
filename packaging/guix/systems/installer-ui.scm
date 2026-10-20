;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu installer)
             (gnu packages bash)
             (gnu packages gnupg)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages linux)
             (guix gexp)
             (guix modules)
             (ice-9 match))

;; -L adds source paths, not compiled paths. Load this overlay explicitly
;; instead of the channel profile's already compiled installer module.
(save-module-excursion
 (lambda () (primitive-load (search-path %load-path "gnu/installer.scm"))))

(define (project-module? name)
  (match name (('hello-guix 'installer 'linux _ ...) #t) (_ #f)))

(define configuration-support
  (primitive-load (string-append (dirname (current-filename))
                                 "/../packages/configuration-support.scm")))

(lambda (runtime channels)
  (define questions
    (installer-program
     #:dry-run? #f
     #:guix-for-installer runtime
     #:steps
     (with-imported-modules
         ;; This procedure runs in a separate process. Include its imports
         ;; even if the launcher has already imported the same modules.
         (source-module-closure '((hello-guix installer linux install)
                                  (hello-guix installer linux configuration)
                                  (hello-guix installer linux setup-state)
                                  (hello-guix installer linux target))
                                #:select? project-module?)
       #~(lambda (current-installer)
           (use-modules (hello-guix installer linux install)
                        (hello-guix installer linux configuration)
                        (hello-guix installer linux setup-state)
                        (hello-guix installer linux target))
           (define* (observe #:key (unique-root? #t))
             (check-installation-origin)
             (inspect-target
              #:unique-root? unique-root?
              #:lsblk #$(file-append util-linux+udev "/bin/lsblk")
              #:findmnt #$(file-append util-linux "/bin/findmnt")))
           (define (inspect)
             (call-with-values
                 observe
               (lambda (target evidence) target)))
           (define target
             (delay
               (prepare-target observe #$(file-append btrfs-progs "/bin/btrfs")
                               #$(file-append btrfs-progs "/bin/btrfstune"))))
           (prepared-system-steps
            (#$(installer-steps #:dry-run? #f) current-installer)
            (lambda (results steps)
              (run-prepared-installation results steps (force target) inspect
                #$(file-append btrfs-progs "/bin/btrfs") #$channels #$configuration-support))
            ;; Guix builds the step list before it starts its error handler.
            ;; Prepare the target during the welcome step so Guix can handle errors.
            #:prepare (lambda () (force target)))))))

  (with-extensions (list runtime guile-gcrypt guile-json-3)
    (with-imported-modules
        (source-module-closure '((hello-guix installer linux setup-state))
                               #:select? project-module?)
      (program-file "guix-system-installer"
        #~(begin
            (use-modules (hello-guix installer linux setup-state)
                         (guix build utils)
                         (guix build syscalls))
            (check-installation-origin)
            (let ((lock
                   (catch 'flock-error
                     (lambda () (lock-file "/run/hello-guix-install.lock" #:wait? #f))
                     (lambda _
                       (display "The installer is already running on another console. Return to it to continue.\n"
                                (current-error-port))
                       (exit 1)))))
              (dynamic-wind
                (const #t)
                (lambda ()
                  (catch #t
                    (lambda ()
                      (invoke #$questions))
                    (lambda (key . arguments)
                      (display "Setup stopped: " (current-error-port))
                      (print-exception (current-error-port) #f key arguments))))
                (lambda () (unlock-file lock))))
            ;; Guix's completion page requests a reboot. If the user cancels
            ;; installation or an error occurs, open a maintenance shell.
            (execl #$(file-append bash "/bin/bash") "bash" "--login"))
        #:guile guile-3.0-latest))))
