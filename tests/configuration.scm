;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run through tests/guix/check-configuration.sh on Guix. All data is fictional.

(use-modules (gnu installer hardware)
             (gnu installer hostname)
             (gnu installer locale)
             (gnu installer newt keymap)
             (gnu installer services)
             (gnu installer steps)
             (gnu installer timezone)
             (gnu installer user)
             (gnu installer utils)
             (guix build utils)
             ((guix tests) #:select (mock))
             (hello-guix installer linux configuration)
             (hello-guix installer linux target)
             (hello-guix installer linux setup-state)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64))

(define (settings-step id formatter)
  (installer-step
   (id id)
   (compute (lambda _ (error "A configuration test must not run a UI step")))
   (configuration-formatter formatter)))

(define steps
  (list (settings-step 'locale locale->configuration)
        (settings-step 'timezone posix-tz->configuration)
        (settings-step 'keymap keyboard-layout->configuration)
        (settings-step 'hostname hostname->configuration)
        (settings-step 'user users->configuration)
        (settings-step 'services system-services->configuration)))

(define (choice name)
  (or (find (lambda (service) (string-prefix? name (system-service-name service)))
            (%system-services))
      (error "Upstream service choice missing" name)))

(define results
  `((locale . "en_GB.utf8")
    (timezone . "Europe/London")
    (keymap . ("us" #f #f))
    (hostname . "guix-example")
    (user . (,(user
               (name "root")
               (password (make-secret "ROOT-PASSWORD-MUST-NOT-APPEAR"))
               (home-directory "/root"))
             ,(user
               (name "alex")
               (real-name "Alex Example")
               (password (make-secret "USER-PASSWORD-MUST-NOT-APPEAR"))
               (home-directory "/home/alex"))))
    (kernel . ())
    (services . (,(choice "NetworkManager")))
    (partition . ())))

(define root-uuid "11111111-2222-4333-8444-555555555555")
(define efi-uuid "A1B2-C3D4")

(define* (generate #:optional (answers results) (formatters steps)
                   #:key (root root-uuid) (efi efi-uuid))
  (system-configuration formatters answers #:root-uuid root #:efi-uuid efi))

(define configuration (generate))
(define* (field name #:optional (forms configuration))
  (let ((os (find (lambda (form)
                    (and (pair? form) (eq? 'with-asahi-hardware (car form))))
                  forms)))
    (set! os (cadr os))
    (find (lambda (form) (and (pair? form) (eq? name (car form)))) (cdr os))))

(define (contains? value tree)
  (or (equal? value tree)
      (and (pair? tree)
           (or (contains? value (car tree)) (contains? value (cdr tree))))))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "mac-configuration")

(test-equal "language uses the upstream formatter"
  '(locale "en_GB.utf8") (field 'locale))
(test-equal "timezone is a choice, not a hardware default"
  '(timezone "Europe/London") (field 'timezone))
(test-equal "keyboard uses the upstream formatter"
  '(keyboard-layout (keyboard-layout "us")) (field 'keyboard-layout))
(test-equal "hostname is retained"
  '(host-name "guix-example") (field 'host-name))
(test-assert "administrative account is retained"
  (contains? '(supplementary-groups '("wheel" "netdev" "audio" "video"))
             (field 'users)))
(test-assert "upstream root account is implicit"
  (not (contains? '(name "root") (field 'users))))
(test-assert "the reusable adapter owns kernel and initrd selection"
  (and (contains? '(hello-guix system hardware) configuration)
       (not (field 'kernel)) (not (field 'initrd-modules))))
(test-assert "GRUB maintenance preserves m1n1 and U-Boot"
  (contains? '(bootloader grub-efi-removable-bootloader) (field 'bootloader)))
(test-equal "boot menu identifies the installed system"
  '(label "GNU Guix") (field 'label))
(test-assert "root uses its supplied filesystem UUID"
  (contains? `(device (uuid ,root-uuid 'btrfs)) (field 'file-systems)))
(test-assert "EFI uses its supplied FAT UUID, not an image label"
  (contains? `(device (uuid ,efi-uuid 'fat32)) (field 'file-systems)))
(test-assert "installed sources are retained with the generation"
  (contains? '(service configuration-source-service-type
                      (configuration-source (current-filename))) (field 'services)))
(test-assert "ordinary console services replace the setup environment"
  (and (contains? '%base-services (field 'services))
       (not (contains? 'asahi-installation-os configuration))))
(test-assert "generated configuration needs no installer module"
  (not (contains? '(hello-guix installer linux configuration) configuration)))
(test-equal "EFI UUID is canonicalized"
  (field 'file-systems) (field 'file-systems (generate #:efi "a1b2-c3d4")))

;; The test program validates this target in tests/target.scm first.
;; Check that Guix's configuration writer accepts it.
(test-equal "verified target reaches the ordinary configuration writer"
  configuration (target-system-configuration steps results verified-test-target))
(test-error "an unvalidated report cannot be passed as a target" 'misc-error
  (target-system-configuration steps results target-test-evidence))

(for-each
 (lambda (id)
   (test-error (string-append "missing answer is rejected: " (symbol->string id))
     'misc-error
     (generate (alist-delete id results)))
   (test-error (string-append "duplicate answer is rejected: " (symbol->string id))
     'misc-error
     (generate (acons id (assoc-ref results id) results))))
 '(locale timezone keymap hostname user services))
(test-error "duplicate formatter is rejected" 'misc-error
  (generate results (cons (car steps) steps)))
(test-error "missing formatter is rejected" 'misc-error
  (generate results (cdr steps)))
(test-error "an administrative user is required" 'misc-error
  (generate (acons 'user '() (alist-delete 'user results))))
(test-error "invalid root UUID is rejected" 'misc-error
  (generate #:root "/dev/nvme0n1p5"))
(test-error "missing EFI UUID is rejected" 'misc-error (generate #:efi #f))
(test-error "partition UUID is not a FAT UUID" 'misc-error (generate #:efi root-uuid))
(define (with-services selections)
  (generate (acons 'services selections (alist-delete 'services results))))
(define gnome (with-services (list (choice "GNOME") (choice "OpenSSH") (choice "Bluetooth"))))
(define connman (with-services (list (choice "Connman") (choice "OpenSSH"))))
(define dhcp (with-services (list (choice "DHCP client"))))
(define sway (with-services (list (choice "Sway"))))
(test-assert "GNOME and optional SSH are retained"
  (and (contains? '(service gnome-desktop-service-type) (field 'services gnome))
       (contains? '(service openssh-service-type) (field 'services gnome))
       (contains? '%desktop-services (field 'services gnome))))
(test-assert "Bluetooth is an explicit standard service choice"
  (and (contains? '(service bluetooth-service-type) (field 'services gnome))
       (not (contains? '(service bluetooth-service-type) (field 'services)))))
(test-assert "upstream desktop fonts are retained"
  (contains? '(specification->package "font-google-noto") (field 'packages gnome)))
(test-assert "console remains a console without forced SSH or desktop"
  (and (not (contains? '%desktop-services (field 'services)))
       (not (contains? 'guix-home-service-type (field 'services)))
       (not (contains? 'openssh-service-type (field 'services)))))
(test-assert "ConnMan remains the chosen network manager"
  (and (contains? '(service connman-service-type) (field 'services connman))
       (not (contains? 'network-manager-service-type (field 'services connman)))))
(test-assert "DHCP-only selection is not replaced with a wireless manager"
  (and (contains? '(service dhcpcd-service-type) (field 'services dhcp))
       (not (contains? 'iwd-service-type (field 'services dhcp)))
       (not (contains? 'network-manager-service-type (field 'services dhcp)))))
(test-assert "upstream window-manager packages survive"
  (contains? '(specification->package "sway") (field 'packages sway)))
(test-assert "only the firmware supplied by Asahi is exempt from the warning"
  (let ((modules (@@ (gnu installer hardware) %unsupported-linux-modules)))
    (and (not (member "brcmfmac" modules))
         (member "iwlwifi" modules)
         (member "amdgpu" modules))))
(test-error "partition choices cannot silently disappear" 'misc-error
  (generate (acons 'partition '(unexpected-partition-selection)
                   (alist-delete 'partition results))))

;; Test Guix's step runner without screen output or external commands.
;; If the user cancels the final page, Guix must return to the settings menu.
(define final-visits 0)
(define hostname-visits 0)
(define upstream-steps
  (map
   (lambda (id)
     (let ((formatter (find-step-by-id steps id)))
       (installer-step
        (id id)
        (compute
         (lambda _
           (case id
             ((final kernel partition)
              (error "An excluded or replaced step was executed" id))
             ((hostname)
              (set! hostname-visits (+ 1 hostname-visits))
              (if (= hostname-visits 1) "before-edit" "after-edit"))
             (else (or (result-step results id) #t)))))
        (configuration-formatter
         (and formatter (installer-step-configuration-formatter formatter))))))
   '(locale welcome timezone keymap hostname network substitutes
     user kernel services partition final)))
(define installation-steps (prepared-system-steps upstream-steps (const #t)))
(test-equal "real installation keeps upstream network and substitute discovery pages"
  '(locale welcome timezone keymap hostname network substitutes user services final)
  (map installer-step-id installation-steps))
(for-each
 (lambda (id)
   (test-assert (string-append "production page reused unchanged: " (symbol->string id))
     (eq? (find-step-by-id upstream-steps id)
          (find-step-by-id installation-steps id))))
 '(network substitutes user services))
(define selected-steps
  (prepared-system-steps upstream-steps
    (lambda (answers previous)
      (set! final-visits (+ 1 final-visits))
      (if (= final-visits 1)
          (abort-to-prompt 'installer-step 'abort)
          (system-configuration previous answers
            #:root-uuid root-uuid #:efi-uuid efi-uuid)))))
(test-equal "standard settings order is retained"
  '(locale welcome timezone keymap hostname network substitutes user services final)
  (map installer-step-id selected-steps))
(for-each
 (lambda (id)
   (test-assert (string-append "upstream page reused: " (symbol->string id))
     (eq? (find-step-by-id upstream-steps id)
          (find-step-by-id selected-steps id))))
 '(locale welcome timezone keymap hostname network substitutes user services))
(define navigation-result
  (run-installer-steps
   #:steps selected-steps #:dry-run? #t #:rewind-strategy 'menu
   #:menu-proc (lambda (available) (find-step-by-id available 'hostname))))
(test-equal "the final-page return uses Guix navigation" 2 final-visits)
(test-equal "edited answers reach the final configuration"
  '(host-name "after-edit")
  (field 'host-name (result-step navigation-result 'final)))
(test-equal "chosen keyboard reaches the final configuration"
  '(keyboard-layout (keyboard-layout "us"))
  (field 'keyboard-layout (result-step navigation-result 'final)))
(test-error "missing upstream page is rejected" 'misc-error
  (prepared-system-steps (cdr upstream-steps) (const #f)))
(test-error "duplicate upstream page is rejected" 'misc-error
  (prepared-system-steps (cons (car upstream-steps) upstream-steps) (const #f)))

;; Prepare the target after the interface and its error handler are ready.
;; Do not inspect devices while the installer creates the step list.
(define prepared? #f)
(define failing-preparation
  (prepared-system-steps upstream-steps (const #f)
    #:prepare (lambda ()
                (set! prepared? #t)
                (error "Simulated target preparation failure"))))
(test-assert "constructing steps does not prepare a target" (not prepared?))
(test-error "target failure reaches the installer caller" 'misc-error
  (run-installer-steps #:steps failing-preparation #:dry-run? #t))
(test-assert "preparation runs as an installer step" prepared?)

;; A child process writes to stdout and stderr, then fails.
;; Check that its output goes to the installer log. The error must reach
;; the caller, with the terminal output ports restored.
(let ((log (tmpfile)) (terminal (tmpfile)) (status #f) (restored? #f))
  (mock ((gnu installer utils) installer-log-port (lambda () log))
    (with-output-to-port terminal
      (lambda ()
        (with-error-to-port terminal
          (lambda ()
            (let* ((prepared
                    (prepared-system-steps upstream-steps (const #t)
                      #:prepare
                      (lambda ()
                        (invoke "sh" "-c"
                          "printf 'uuid progress\\n'; printf 'uuid warning\\n' >&2; exit 23"))))
                   (welcome (find-step-by-id prepared 'welcome)))
              (set! status
                (guard (c ((invoke-error? c) (invoke-error-exit-status c)))
                  ((installer-step-compute welcome)))))
            (set! restored? (and (eq? terminal (current-output-port))
                                (eq? terminal (current-error-port)))))))))
  (test-equal "preparation command failure reaches the caller" 23 status)
  (test-assert "UI output ports are restored after failure" restored?)
  (seek log 0 SEEK_SET)
  (test-equal "preparation captures both child output streams"
    "uuid progress\nuuid warning\n" (get-string-all log))
  (seek terminal 0 SEEK_SET)
  (test-equal "preparation does not draw over the UI" "" (get-string-all terminal))
  (close-port log)
  (close-port terminal))

;; Read the writer's output as Scheme data, without evaluation.
;; Guix checks the generated system in a later test.
(define output-directory
  (match (command-line)
    ((_ directory) directory)
    (_ (error "Expected one scratch output directory"))))
(define output-file (string-append output-directory "/example-system.scm"))
(when (file-exists? output-file)
  (error "Refusing to replace an existing configuration example"))
(configuration->file configuration #:file-name output-file)
(for-each
 (lambda (example)
   (configuration->file (cdr example)
     #:file-name (string-append output-directory "/" (car example) "-system.scm")))
 (list (cons "gnome" gnome) (cons "connman" connman)
       (cons "dhcp" dhcp) (cons "sway" sway)))
(define text (call-with-input-file output-file get-string-all))
(test-assert "generated configuration explains the Hello Guix additions"
  (every (lambda (explanation) (string-contains text explanation))
         '(";; Load Hello Guix's hardware support"
           ";; Add the Mac's hardware support to this system description."
           ";; Keep the same network interface names"
           ";; Asahi has already installed m1n1 and U-Boot."
           ";; Use the Asahi Guix Channel's pre-built packages."
           ";; Save configuration sources for each generation."
           ";; Use a larger console font for the Mac's screen."
           ";; guix pull uses these channel revisions by default.")))
(test-assert "plaintext passwords never reach the configuration"
  (and (not (string-contains text "ROOT-PASSWORD-MUST-NOT-APPEAR"))
       (not (string-contains text "USER-PASSWORD-MUST-NOT-APPEAR"))))
(test-assert "configuration file can be read back"
  (call-with-input-file output-file
    (lambda (port)
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (and (contains? '(host-name "guix-example") forms)
                   (contains? `(device (uuid ,root-uuid 'btrfs)) forms))
              (loop (cons form forms))))))))

;; Check that the setup guard rejects an installed system.
;; These checks use test data without file access.
(define setup-generation "/gnu/store/11111111111111111111111111111111-system")
(test-equal "matching booted setup generation is accepted" setup-generation
  (validate-setup-origin setup-generation setup-generation %installation-marker))
(for-each
 (lambda (case)
   (test-error (car case) 'misc-error
     (apply validate-setup-origin (cdr case))))
 (list
  (list "ordinary system without a marker is rejected" setup-generation setup-generation #f)
  (list "old or different setup marker is rejected" setup-generation setup-generation "other\n")
  (list "live reconfiguration is rejected" setup-generation "/gnu/store/22222222222222222222222222222222-system" %installation-marker)
  (list "non-store origin is rejected" "/tmp/system" "/tmp/system" %installation-marker)))

(test-assert "ordinary configuration does not inherit the setup marker"
  (not (string-contains text "hello-guix/setup")))

(test-end "mac-configuration")
(exit (and (zero? (test-runner-fail-count runner))
           (zero? (test-runner-xpass-count runner))))
