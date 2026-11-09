;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu home)
             (gnu home services)
             (gnu home services shells)
             (gnu home services shepherd)
             (gnu services shepherd)
             (gnu services guix)
             (gnu services sound)
             (gnu services desktop)
             (gnu services networking)
             (gnu services linux)
             (gnu packages linux)
             (gnu packages emacs)
             (gnu packages librewolf)
             (gnu packages window-management)
             (gnu system keyboard)
             (gnu system linux-initrd)
             (gnu system shadow)
             (asahi guix packages linux)
             (asahi guix initrd)
             ((asahi guix services sound) #:prefix asahi:)
             ((asahi guix home services sound) #:prefix asahi:)
             ((gnu home services sound) #:prefix generic:)
             (hello-guix system hardware)
             (hello-guix system audio)
             (hello-guix system boot)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix derivations)
             (guix monads)
             (guix grafts)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "asahi-hardware")
(define runner (test-runner-current))
(define console
  (operating-system
   (host-name "fixture") (timezone "Europe/London") (locale "en_GB.utf8")
   (bootloader (bootloader-configuration (bootloader grub-efi-removable-bootloader) (targets '("/boot/efi"))))
   (file-systems (cons (file-system (device (file-system-label "fictional"))
                                   (mount-point "/") (type "btrfs")) %base-file-systems))
   (users (cons* (user-account (name "alex") (group "users"))
                 (user-account (name "sam") (group "users")) %base-user-accounts))))
(define (entries os type)
  (filter (lambda (entry) (eq? (service-kind entry) type)) (operating-system-user-services os)))
(define (value os type) (service-value (car (entries os type))))
(define (home os name) (cadr (assoc name (value os guix-home-service-type))))
(define (home-entries home type)
  (filter (lambda (entry) (eq? (service-kind entry) type)) (home-environment-user-services home)))
(define supported (with-asahi-hardware console))
(test-eq "Asahi kernel" asahi-linux (operating-system-kernel supported))
(test-eq "retained boot bundle uses the selected kernel" (operating-system-kernel supported)
         (value supported asahi-boot-service-type))
(test-equal "module order" asahi-initrd-modules (operating-system-initrd-modules supported))
(define native-loader grub-efi-removable-bootloader)
(define supported-loader
  (bootloader-configuration-bootloader (operating-system-bootloader supported)))
(for-each
 (lambda (field)
   (test-equal (string-append "GRUB " (car field) " preserved")
               ((cdr field) native-loader) ((cdr field) supported-loader)))
 (list (cons "name" bootloader-name)
       (cons "package" bootloader-package)
       (cons "configuration file" bootloader-configuration-file)
       (cons "configuration generator" bootloader-configuration-file-generator)
       (cons "disk-image installer" bootloader-disk-image-installer)))
(test-assert "GRUB installer includes Asahi deployment"
  (not (eq? (bootloader-installer native-loader)
            (bootloader-installer supported-loader))))
(test-equal "EFI targets preserved"
  (bootloader-configuration-targets (operating-system-bootloader console))
  (bootloader-configuration-targets (operating-system-bootloader supported)))
(test-eq "filesystems untouched" (operating-system-file-systems console) (operating-system-file-systems supported))
(test-equal "packages untouched" (operating-system-packages console) (operating-system-packages supported))
(test-equal "locale untouched" "en_GB.utf8" (operating-system-locale supported))
(test-equal "accounts untouched" (operating-system-users console) (operating-system-users supported))
(test-equal "only ordinary Homes" '("alex" "sam") (map car (value supported guix-home-service-type)))
(test-equal "audio without a desktop" 1 (length (home-entries (home supported "alex") asahi:home-pipewire-service-type)))
(test-equal "speaker protection" 1 (length (entries supported speakersafetyd-service-type)))
(test-equal "audio opt out" '() (entries (with-asahi-hardware console #:audio? #f) guix-home-service-type))
(test-equal "explicit Home ownership" '("sam")
            (map car (value (with-asahi-hardware console #:home-users '("sam")) guix-home-service-type)))
(test-error "root cannot own an audio Home" #t (with-asahi-hardware console #:home-users '("root")))
(test-error "unknown Home user" #t (with-asahi-hardware console #:home-users '("missing")))
(test-error "duplicate Home user" #t (with-asahi-hardware console #:home-users '("sam" "sam")))

;; User boot-menu and console choices remain ordinary GRUB configuration.
(define custom-boot
  (bootloader-configuration
   (bootloader native-loader)
   (targets '("/efi"))
   (menu-entries (list (menu-entry (label "Recovery")
                                  (chain-loader "/EFI/BOOT/BOOTAA64.EFI"))))
   (default-entry 1)
   (timeout 17)
   (keyboard-layout (keyboard-layout "gb"))
   (terminal-outputs '(console serial))
   (terminal-inputs '(serial))
   (serial-unit 1)
   (serial-speed 115200)
   (device-tree-support? #f)
   (extra-initrd "/boot/extra-initrd")))
(define custom-boot-supported
  (operating-system-bootloader
   (with-asahi-hardware (operating-system (inherit console)
                         (bootloader custom-boot)))))
(for-each
 (lambda (field)
   (test-equal (string-append "boot configuration " (car field) " preserved")
               ((cdr field) custom-boot) ((cdr field) custom-boot-supported)))
 (list (cons "targets" bootloader-configuration-targets)
       (cons "menu" bootloader-configuration-menu-entries)
       (cons "default entry" bootloader-configuration-default-entry)
       (cons "timeout" bootloader-configuration-timeout)
       (cons "keyboard" bootloader-configuration-keyboard-layout)
       (cons "theme" bootloader-configuration-theme)
       (cons "outputs" bootloader-configuration-terminal-outputs)
       (cons "inputs" bootloader-configuration-terminal-inputs)
       (cons "serial unit" bootloader-configuration-serial-unit)
       (cons "serial speed" bootloader-configuration-serial-speed)
       (cons "device tree policy" bootloader-configuration-device-tree-support?)
       (cons "extra initrd" bootloader-configuration-extra-initrd)))
(test-equal "image sentinel preserved" '(#f)
  (bootloader-configuration-targets
   (with-asahi-bootloader (bootloader-configuration
                          (inherit custom-boot) (targets '(#f))) asahi-linux)))
(for-each
 (lambda (targets)
   (test-error "exactly one absolute EFI target required" #t
     (with-asahi-bootloader (bootloader-configuration
                            (inherit custom-boot) (targets targets)) asahi-linux)))
 '(() ("/efi" "/boot/efi") ("efi")))
(test-error "non-removable GRUB requires explicit integration" #t
  (with-asahi-hardware
   (operating-system (inherit console)
    (bootloader (bootloader-configuration
                 (inherit custom-boot) (bootloader grub-efi-bootloader))))))
(test-error "custom same-name GRUB is not silently replaced" #t
  (with-asahi-hardware
   (operating-system (inherit console)
    (bootloader (bootloader-configuration
                 (inherit custom-boot)
                 (bootloader (bootloader (inherit native-loader)
                              (installer #~(lambda arguments #t)))))))))
(test-eq "explicit Asahi kernel retained" asahi-linux
  (operating-system-kernel
   (with-asahi-hardware (operating-system (inherit console) (kernel asahi-linux)))))
(test-error "custom kernel still requires explicit integration" #t
  (with-asahi-hardware
   (operating-system (inherit console)
    (kernel (package (inherit asahi-linux) (name "custom-asahi"))))))

(define service-accounts
  (operating-system (inherit console)
   (services
    (cons (simple-service 'additional-accounts account-service-type
                          (list (user-account (name "taylor") (group "users") (system? #f))
                                (user-account (name "robot") (group "users") (system? #t))))
          %base-services))))
(test-equal "service-contributed ordinary users receive audio; system users do not"
  '("alex" "sam" "taylor")
  (sort (map car (value (with-asahi-hardware service-accounts) guix-home-service-type)) string<?))
(test-equal "service-contributed account can own its Home explicitly" '("taylor")
  (map car (value (with-asahi-hardware service-accounts #:home-users '("taylor"))
                 guix-home-service-type)))
(test-error "service-contributed system account cannot own an audio Home" #t
  (with-asahi-hardware service-accounts #:home-users '("robot")))

(define personal (home-environment
                  (packages (list emacs-minimal))
                  (services (list (service home-bash-service-type)
                                  (service generic:home-pipewire-service-type)))))
(define with-home
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service guix-home-service-type (list (list "alex" personal))) %base-services)))))
(test-equal "Home packages preserved" (home-environment-packages personal)
            (home-environment-packages (home with-home "alex")))
(test-eq "Home unrelated service preserved" (car (home-environment-user-services personal))
         (car (home-entries (home with-home "alex") home-bash-service-type)))
(test-equal "one environment per user" 2 (length (value with-home guix-home-service-type)))
(test-equal "generic Home PipeWire converted" '() (home-entries (home with-home "alex") generic:home-pipewire-service-type))
(test-error "custom generic Home audio needs a port" #t
            (with-asahi-home-audio
             (home-environment (services (list (service generic:home-pipewire-service-type
                                                       (generic:home-pipewire-configuration (extra-content "custom"))))))))
(define custom (service asahi:home-pipewire-service-type
                        (asahi:home-pipewire-configuration (enable-pulseaudio? #f))))
(test-eq "explicit Asahi Home settings preserved" custom
         (car (home-entries (with-asahi-home-audio (home-environment (services (list custom))))
                            asahi:home-pipewire-service-type)))
(test-error "duplicate Home owners" #t
            (with-asahi-hardware
             (operating-system (inherit console)
              (services (cons (service guix-home-service-type (list (list "alex" personal) (list "alex" personal)))
                              %base-services)))))

(define desktop (operating-system (inherit console)
                 (services (cons (service gnome-desktop-service-type) %desktop-services))))
(define supported-desktop (with-asahi-hardware desktop))
(test-equal "GNOME retained" 1 (length (entries supported-desktop gnome-desktop-service-type)))
(test-equal "generic PulseAudio removed" '() (entries supported-desktop pulseaudio-service-type))
(test-equal "generic ALSA removed" '() (entries supported-desktop alsa-service-type))
(test-equal "Asahi ALSA present" 1 (length (entries supported-desktop asahi:alsa-service-type)))
(test-equal "one iwd" 1 (length (entries supported-desktop iwd-service-type)))
(test-equal "wpa-supplicant removed" '() (entries supported-desktop wpa-supplicant-service-type))
(test-equal "NM uses iwd" '(iwd) (network-manager-configuration-shepherd-requirement (value supported-desktop network-manager-service-type)))
(test-error "custom PulseAudio needs a port" #t
            (with-asahi-hardware
             (operating-system (inherit console)
              (services (cons (service pulseaudio-service-type
                                       (pulseaudio-configuration (extra-script-files '(("x" . "y"))))) %base-services)))))
(test-error "extension cannot revive generic audio" #t
            (with-asahi-hardware
             (operating-system (inherit console)
              (services (cons (simple-service 'custom-audio alsa-service-type (list (alsa-configuration))) %base-services)))))
(test-error "extension cannot bypass Home adaptation" #t
            (with-asahi-hardware
             (operating-system (inherit console)
              (services (cons (simple-service 'extra-home guix-home-service-type (list (list "alex" personal))) %base-services)))))

(define custom-network
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service network-manager-service-type
                             (network-manager-configuration (dns "none")
                              (shepherd-requirement '(wpa-supplicant networking)))) %base-services)))))
(test-equal "NM unrelated dependency retained" '(iwd networking)
            (network-manager-configuration-shepherd-requirement (value custom-network network-manager-service-type)))
(test-equal "NM DNS policy retained" "none" (network-manager-configuration-dns (value custom-network network-manager-service-type)))
(test-equal "static console has no added manager" '() (entries supported network-manager-service-type))
(test-equal "DHCP remains unchanged" 1
            (length (entries (with-asahi-hardware
                              (operating-system (inherit console) (services (cons (service dhcpcd-service-type) %base-services))))
                             dhcpcd-service-type)))
(test-equal "custom early module retained" '("test-module")
            (lset-difference string=? (operating-system-initrd-modules
                                      (with-asahi-hardware (operating-system (inherit console)
                                                           (initrd-modules (cons "test-module" (base-initrd-modules linux-libre))))))
                             asahi-initrd-modules))

(test-equal "console audio has login lifecycle" 1 (length (entries supported elogind-service-type)))
(define custom-login (service elogind-service-type
                             (elogind-configuration (handle-lid-switch 'ignore))))
(test-eq "personal login policy preserved" custom-login
         (car (entries (with-asahi-hardware
                        (operating-system (inherit console)
                         (services (cons custom-login %base-services)))) elogind-service-type)))
(define (session-services home)
  (home-shepherd-configuration-services
   (service-value (fold-services (home-environment-services home)
                                 #:target-type home-shepherd-service-type))))
(define audio-session (session-services (home supported "alex")))
(for-each (lambda (name)
            (test-equal (string-append "one session service: " (symbol->string name)) 1
                        (count (lambda (entry) (memq name (shepherd-service-provision entry))) audio-session)))
          '(pipewire wireplumber pipewire-pulseaudio dbus))
(test-assert "session Shepherd graph valid" (begin (assert-valid-graph audio-session) #t))

(define connman
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service connman-service-type
                             (connman-configuration (shepherd-requirement '(wpa-supplicant networking)))) %base-services)))))
(test-equal "ConnMan unrelated dependency retained" '(iwd networking)
            (connman-configuration-shepherd-requirement (value connman connman-service-type)))
(define requested-module
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service kernel-module-loader-service-type '("tun")) %base-services)))))
(test-equal "other kernel modules retained" '("asahi" "appledrm" "tun")
            (value requested-module kernel-module-loader-service-type))

(define (system-services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                 #:target-type shepherd-root-service-type))))
(test-assert "console Shepherd dependencies resolve"
             (begin (assert-valid-graph (system-services supported)) #t))
(test-assert "desktop Shepherd dependencies resolve"
             (begin (assert-valid-graph (system-services supported-desktop)) #t))
(define browser-only (with-asahi-hardware
                      (operating-system (inherit console)
                       (packages (cons librewolf %base-packages)))))
(test-equal "browser gets the same audio session without GNOME"
            (map shepherd-service-provision audio-session)
            (map shepherd-service-provision (session-services (home browser-only "alex"))))
(test-eq "browser is the ordinary Guix package" librewolf
         (car (operating-system-packages browser-only)))
(define sway-system (with-asahi-hardware
                     (operating-system (inherit console)
                      (packages (cons sway %base-packages))
                      (services %desktop-services))))
(test-equal "another desktop uses the same audio session"
            (map shepherd-service-provision audio-session)
            (map shepherd-service-provision (session-services (home sway-system "alex"))))
(test-error "custom initrd needs an explicit integration" #t
            (with-asahi-hardware
             (operating-system (inherit console) (initrd (lambda _ #f)))))
(test-error "external modules require matching the kernel" #t
            (with-asahi-hardware
             (operating-system (inherit console)
              (kernel-loadable-modules (list linux-libre)))))
(test-error "boot service must match the adapted kernel" #t
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service asahi-boot-service-type linux-libre) %base-services)))))

(define kernel-observer
  (service-type
   (name 'observe-kernel)
   (description "Observe evaluation of an inherited service field.")
   (extensions '())
   (default-value #f)))
(define observes-kernel
  (with-asahi-hardware
   (operating-system (inherit console)
    (services (cons (service kernel-observer
                             (operating-system-kernel this-operating-system))
                    %base-services)))))
(test-eq "inherited service thunk sees adapted kernel" asahi-linux
         (value observes-kernel kernel-observer))

(define twice (with-asahi-hardware supported))
(test-eq "idempotent bootloader configuration"
         (operating-system-bootloader supported) (operating-system-bootloader twice))
(test-equal "idempotent service kinds" (map service-kind (operating-system-user-services supported))
            (map service-kind (operating-system-user-services twice)))
(test-equal "idempotent initrd" (operating-system-initrd-modules supported) (operating-system-initrd-modules twice))
(test-equal "idempotent Homes" '("alex" "sam") (map car (value twice guix-home-service-type)))

(define gnome-removed
  (with-asahi-hardware
   (operating-system
    (inherit supported-desktop)
    (services
     (remove (lambda (entry) (eq? (service-kind entry) gnome-desktop-service-type))
             (operating-system-user-services supported-desktop))))))
(test-equal "remove GNOME from adapted record retains audio"
            (map shepherd-service-provision audio-session)
            (map shepherd-service-provision (session-services (home gnome-removed "alex"))))

;; Calculate system derivations without building packages or activating hardware.
;; After a desktop change, check the original declaration again.
;; Its derivation must be the same as before.
(with-store store
  (set-build-options store #:use-substitutes? #f)
  (define (derive os)
    (derivation-file-name (run-with-store store (operating-system-derivation os) #:system "aarch64-linux")))
  (parameterize ((%graft? #f))
    (define first (derive supported))
    (test-equal "double adaptation has same derivation" first (derive twice))
    (define gnome (derive supported-desktop))
    (test-assert "GNOME derives" (string-suffix? ".drv" gnome))
    (test-equal "remove desktop and replay console" first (derive (with-asahi-hardware console)))
    (test-equal "replay desktop" gnome (derive (with-asahi-hardware desktop)))
    (define browser (derive browser-only))
    (test-assert "browser-only derives" (string-suffix? ".drv" browser))
    (define sway (derive sway-system))
    (test-assert "Sway derives" (string-suffix? ".drv" sway))
    (call-with-output-file "hardware-derivations.scm"
      (lambda (port)
        (write `((console . ,first) (gnome . ,gnome)
                 (browser . ,browser) (sway . ,sway)) port)
        (newline port)))))
(test-end "asahi-hardware")
(exit (= 0 (test-runner-fail-count runner)))
