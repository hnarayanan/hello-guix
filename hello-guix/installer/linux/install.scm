;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux install)
  #:use-module (hello-guix installer linux configuration)
  #:use-module (hello-guix installer linux installation-files)
  #:use-module (hello-guix installer linux firmware)
  #:use-module (guix base32)
  #:use-module (guix hash)
  #:use-module (gnu installer steps)
  #:use-module (gnu installer newt final)
  #:use-module ((gnu installer utils) #:select (installer-log-port))
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:export (read-installer-channels run-prepared-installation))

(define (read-installer-channels guix)
  "Read channel records from the explicit setup GUIX executable.
The generated installer is not itself a Guix profile. Ask its selected
bin/guix, which already has authenticated channel records, before preparing
the target. Return #f for the legacy profile without Hello Guix."
  (unless (and (string? guix) (string-prefix? "/" guix))
    (error "Expected an absolute setup Guix executable" guix))
  (let* ((port (open-pipe* OPEN_READ guix "describe" "-f" "channels"))
         (status #f)
         (text (dynamic-wind
                 (const #t)
                 (lambda () (get-string-all port))
                 (lambda () (set! status (close-pipe port))))))
    (unless (zero? status)
      (error "Could not read the setup Guix channel records" guix status))
    (call-with-input-string text
      (lambda (input)
        (let ((form (read input)))
          (unless (and (not (eof-object? form)) (eof-object? (read input)))
            (error "Expected one setup Guix channel declaration"))
          ;; This is the selected executable's own describe output, not a
          ;; user channel override or a declaration from an arbitrary file.
          (let ((module (make-fresh-user-module)))
            (module-use! module (resolve-interface '(guix channels)))
            (configuration-channels (eval form module))))))))

(define* (run-prepared-installation results steps target inspect btrfs channel-file support
                                    #:key channels)
  "Use Guix's review, account setup, installation, and completion pages.
Report success only after the checks, cleanup, and both unmount operations succeed.
INSPECT checks TARGET again. BTRFS is the path to the btrfs command.
CHANNEL-FILE is the legacy channels.scm path. SUPPORT is the directory with
configuration modules and licenses. CHANNELS contains explicit setup evaluator
records from read-installer-channels, or #f to retain the legacy declaration."
  (unless (string=? (%installer-target-dir) "/mnt")
    (error "Expected the standard Guix installation target"))
  (let* ((firmware (and channels "hello-guix/firmware"))
         (configuration (and (not channels)
                             (target-system-configuration steps results target)))
         (result
          (call-with-installation-target target inspect btrfs
            (lambda ()
              (let* ((root (%installer-target-dir))
                     (esp (string-append root "/boot/efi"))
                     (staging (string-append esp "/hello-guix")))
                ;; Channel imports and native provenance replace copied legacy support.
                (unless channels
                  (prepare-configuration-support support channel-file
                                                 (string-append root "/etc")))
                (save-setup-loader esp (string-append staging "/setup-bootaa64.efi"))
                (let ((result
                       (call-with-preserved-firmware esp
                         (lambda ()
                           (when firmware
                             (let ((log (installer-log-port)))
                               (with-output-to-port log
                                 (lambda ()
                                   (with-error-to-port log
                                     (lambda ()
                                       (prepare-installation-firmware
                                        (string-append esp "/vendorfw/firmware.cpio")
                                        (string-append root "/etc/" firmware))))))
                               (force-output log)))
                           ;; Hash the published directory, including its receipt,
                           ;; before writing the declaration Guix will evaluate.
                           (let ((configuration
                                  (if firmware
                                      (target-system-configuration
                                       steps results target
                                       #:channels channels #:firmware firmware
                                       #:firmware-sha256
                                       (bytevector->nix-base32-string
                                        (file-hash* (string-append root "/etc/" firmware)
                                                    #:recursive? #t
                                                    #:select? (const #t))))
                                      configuration)))
                             ;; Show completion after our checks and cleanup.
                             (run-final-page (acons 'partition '() results) steps #f
                               #:configuration configuration
                               #:on-success (const 'installed)))))))
                  (when (eq? result 'installed)
                    (check-installed-boot root)
                    (finish-installation root staging))
                  result))))))
    (if (eq? result 'installed)
        (run-install-success-page
         #:message "Installation is complete. Press Reboot to start your Guix system.")
        result)))
