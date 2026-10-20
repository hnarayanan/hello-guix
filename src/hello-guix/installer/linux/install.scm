;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux install)
  #:use-module (hello-guix installer linux configuration)
  #:use-module (hello-guix installer linux installation-files)
  #:use-module (gnu installer steps)
  #:use-module (gnu installer newt final)
  #:export (run-prepared-installation))

(define (run-prepared-installation results steps target inspect btrfs channels support)
  "Use Guix's review, account setup, installation, and completion pages.
Report success only after the checks, cleanup, and both unmount operations succeed.
INSPECT checks TARGET again. BTRFS is the path to the btrfs command.
CHANNELS is the path to channels.scm. SUPPORT is the directory with the
configuration modules and licenses."
  (unless (string=? (%installer-target-dir) "/mnt")
    (error "Expected the standard Guix installation target"))
  (let* ((configuration (target-system-configuration steps results target))
         (result
          (call-with-installation-target target inspect btrfs
            (lambda ()
              (let* ((root (%installer-target-dir))
                     (esp (string-append root "/boot/efi"))
                     (staging (string-append esp "/hello-guix")))
                (prepare-configuration-support support channels (string-append root "/etc"))
                (save-setup-loader esp (string-append staging "/setup-bootaa64.efi"))
                (let ((result
                       (call-with-preserved-boot-files esp
                         (lambda ()
                           ;; Show Guix's completion page after our checks and cleanup.
                           (run-final-page (acons 'partition '() results) steps #f
                             #:configuration configuration
                             #:on-success (const 'installed))))))
                  (when (eq? result 'installed)
                    (finish-installation root staging))
                  result))))))
    (if (eq? result 'installed)
        (run-install-success-page
         #:message "Installation is complete. Press Reboot to start your Guix system.")
        result)))
