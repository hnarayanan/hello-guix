;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux configuration)
  #:use-module (gnu installer steps)
  #:use-module (gnu installer services)
  #:use-module ((gnu installer utils) #:select (installer-log-port))
  #:use-module (ice-9 match)
  #:use-module ((gnu installer user) #:select (user-name))
  #:use-module (gnu system uuid)
  #:use-module ((guix read-print) #:select (comment vertical-space))
  #:use-module (hello-guix installer linux target)
  #:use-module (srfi srfi-1)
  #:export (prepared-system-steps system-configuration target-system-configuration))

(define* (prepared-system-steps steps finish #:key prepare)
  "Use Guix's settings and navigation with a prepared target.
Replace the final step with FINISH. If supplied, run PREPARE before the
welcome page, inside Guix's error handler. Keep the other steps unchanged."
  (map
   (lambda (id)
     (let ((matching (filter (lambda (step) (eq? id (installer-step-id step))) steps)))
       (unless (= 1 (length matching)) (error "Expected one upstream step" id))
       (let ((step (car matching)))
         (cond
          ((eq? id 'final)
           (installer-step (inherit step) (compute finish)))
          ((and prepare (eq? id 'welcome))
           (installer-step
            (inherit step)
            (compute (lambda arguments
                       ;; Newt uses the terminal during preparation.
                       ;; Send command output to Guix's log to keep the screen clear.
                       (let ((log (installer-log-port)))
                         (with-output-to-port log
                           (lambda () (with-error-to-port log prepare)))
                         (force-output log))
                       (apply (installer-step-compute step) arguments)))))
          (else step)))))
   '(locale welcome timezone keymap hostname network substitutes user services final)))

(define %settings '(locale timezone keymap hostname user services))

(define (checked-uuid value type)
  (unless (and (string? value) (string->uuid value type))
    (error "Expected a filesystem UUID" type))
  (uuid->string (string->uuid value type) type))

(define (setting-step steps results id)
  ;; Reject missing answers instead of installing defaults the user did not select.
  (let ((matching (filter (lambda (step)
                            (eq? id (installer-step-id step)))
                          steps))
        (answers (filter (lambda (answer) (eq? id (car answer))) results)))
    (unless (and (= 1 (length matching))
                 (= 1 (length answers))
                 (result-step results id)
                 (installer-step-configuration-formatter (car matching)))
      (error "Expected one completed settings step with a formatter" id))
    (car matching)))

(define (hardware-fields root-uuid efi-uuid)
  `((label "GNU Guix")
    ,(comment ";; Keep the same network interface names after setup.\n")
    (kernel-arguments (cons "net.ifnames=0" %default-kernel-arguments))

    ,(vertical-space 1)
    ,(comment "\
;; Asahi has already installed m1n1 and U-Boot.
;; Update GRUB without changing them or the EFI boot order.\n")
    (bootloader
     (bootloader-configuration
      (bootloader grub-efi-removable-bootloader)
      (targets '("/boot/efi"))
      (keyboard-layout keyboard-layout)))
    (file-systems
     (cons* (file-system
             (device (uuid ,root-uuid 'btrfs))
             (mount-point "/")
             (needed-for-boot? #t)
             (type "btrfs"))
            (file-system
             (device (uuid ,efi-uuid 'fat32))
             (mount-point "/boot/efi")
             (needed-for-boot? #t)
             (type "vfat"))
            %base-file-systems))))

(define (mac-service-fields formatter selections)
  ;; Keep Guix's choices, fonts, and comments. The hardware adapter also
  ;; applies to later system reconfigurations.
  (let* ((fields (formatter selections))
         (desktop? (any desktop-system-service? selections))
         (packages (lambda (base)
                     `(packages (cons* btrfs-progs
                                       ,@(if desktop? '(gsettings-desktop-schemas) '())
                                       ,base)))))
    (append
     (if (any (match-lambda (('packages _) #t) (_ #f)) fields)
         '() (list (packages '%base-packages)))
     (map (match-lambda
            (('packages base) (packages base))
            (('services base)
             `(services
               (modify-services
                (cons* ,(comment "\
;; Use the Asahi Guix Channel's pre-built packages.\n")
                       (service asahi-substitutes-service-type)
                       ,(comment
                         ";; Save configuration sources for each generation.\n")
                       (service configuration-source-service-type
                                (configuration-source (current-filename)))
                       ,base)
                ,(comment
                  ";; Use a larger console font for the Mac's screen.\n")
                (console-font-service-type config => (console-font-terminus config))
                ,(comment
                  ";; guix pull uses these channel revisions by default.\n")
                (guix-service-type
                 config => (guix-configuration
                            (inherit config)
                            (guix (running-guix))
                            (channels (load (string-append
                                             (dirname (current-filename))
                                             "/channels.scm"))))))))
            (field field))
          fields))))

(define* (system-configuration steps results #:key root-uuid efi-uuid)
  "Return Scheme forms for Guix's configuration writer, using STEPS and RESULTS
from the installer. This function does not run steps, evaluate forms, or access
devices. The caller must check the target and make sure its UUIDs are unique.
Use Guix's formatters for desktop and service choices. Guix's installation
step sets account passwords."
  (for-each
   (lambda (id)
     (let ((answer (result-step results id)))
       (unless (or (not answer) (null? answer))
         (error "The prepared target does not accept this selection" id))))
   '(kernel partition))
  (let* ((settings
          (map (lambda (id)
                 (let ((step (setting-step steps results id)))
                   (if (eq? id 'services)
                       (installer-step
                        (inherit step)
                        (configuration-formatter
                         (lambda (selections)
                           (mac-service-fields
                            (installer-step-configuration-formatter step)
                            selections))))
                       step)))
               %settings))
         (fields (hardware-fields (checked-uuid root-uuid 'btrfs)
                                  (checked-uuid efi-uuid 'fat32)))
         (hardware
          (installer-step
           (id 'mac-hardware)
           (compute (lambda _ (error "Configuration steps are not executable")))
           (configuration-formatter (lambda _ fields)))))
    (unless (any (lambda (user) (not (string=? "root" (user-name user))))
                 (result-step results 'user))
      (error "Setup requires an ordinary administrative user"))
    (append
     `(,(comment
         ";; Load Hello Guix's hardware support from beside this file.\n")
       (add-to-load-path (string-append (dirname (current-filename))
                                        "/hello-guix/modules")))
     `((use-modules (gnu bootloader grub)
                    (gnu packages linux)
                    (gnu services base)
                    (guix channels)
                    (asahi guix services console-font)
                    (asahi guix services substitutes)
                    (hello-guix system hardware)
                    (hello-guix system runtime)
                    (hello-guix system configuration-retention)
                    ,@(if (any desktop-system-service? (result-step results 'services))
                          '((gnu packages gnome)) '())))
     (append-map
      (match-lambda
        (('operating-system fields ...)
         (list (comment
                ";; Add the Mac's hardware support to this system description.\n")
               `(with-asahi-hardware
                 (operating-system ,@fields))))
        (form (list form)))
      (format-configuration (append settings (list hardware))
                            (acons 'mac-hardware #t results))))))

(define (target-system-configuration steps results target)
  "Generate configuration forms from TARGET after validation.
The caller must also check that the target is available for installation."
  (unless (target? target)
    (error "Expected a validated target observation"))
  (system-configuration steps results
                        #:root-uuid (target-root-uuid target)
                        #:efi-uuid (target-efi-uuid target)))
