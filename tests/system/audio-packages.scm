;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu)
             (gnu bootloader grub)
             (gnu home)
             (gnu services guix)
             (gnu services shepherd)
             (gnu services sound)
             ((gnu packages rust-apps) #:prefix guix:)
             (guix packages)
             (hello-guix packages upstream)
             ((asahi guix home services sound) #:prefix asahi:)
             ((asahi guix services sound) #:prefix asahi:)
             ((hello-guix packages audio) #:prefix current:)
             ((hello-guix packages desktop) #:prefix current:)
             (hello-guix system audio)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "audio-packages")
(define runner (test-runner-current))

(define base
  (operating-system
   (host-name "audio-fixture") (timezone "UTC") (locale "en_US.utf8")
   (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader) (targets '("/boot/efi"))))
   (file-systems (cons (file-system
                       (device (file-system-label "fixture"))
                       (mount-point "/") (type "ext4"))
                      %base-file-systems))
   (users (cons (user-account (name "alex") (group "users")) %base-user-accounts))))

(define (entry services type)
  (find (lambda (entry) (eq? (service-kind entry) type)) services))
(define (protection services)
  (find (lambda (entry)
          (eq? (service-type-name (service-kind entry)) 'speakersafetyd)) services))
(define (audio-home os)
  (cadar (service-value
          (entry (operating-system-user-services os) guix-home-service-type))))
(define (home-audio home)
  (entry (home-environment-user-services home) asahi:home-pipewire-service-type))
(define alsa-pipewire (@@ (asahi guix services sound) alsa-configuration-pipewire))
(define home-pipewire (@@ (asahi guix home services sound) home-pipewire-configuration-pipewire))
(define home-wireplumber (@@ (asahi guix home services sound) home-pipewire-configuration-wireplumber))
(define home-lsp (@@ (asahi guix home services sound) home-pipewire-configuration-lsp-plugins))
(define home-profile (@@ (asahi guix home services sound) home-pipewire-configuration-asahi-audio))

(define speaker-type (@@ (hello-guix system audio) speaker-protection-service-type))
(test-eq "an upstream package keeps the native service type"
  speakersafetyd-service-type
  (speaker-type guix:speakersafetyd guix:speakersafetyd))
(test-assert "a carried newer daemon gets the compatibility service"
  (not (eq? speakersafetyd-service-type
             (speaker-type (package (inherit guix:speakersafetyd) (version "3.0.0"))
                           guix:speakersafetyd))))
(if (upstream-current? guix:speakersafetyd "3.0.0")
    (test-eq "a sufficiently recent upstream daemon is used unchanged"
      guix:speakersafetyd current:speakersafetyd)
    (begin
      (test-equal "the carried speaker release is selected" "3.0.0"
        (package-version current:speakersafetyd))
      (test-assert "the carried speaker release discards old replacement metadata"
        (not (package-replacement current:speakersafetyd)))))

(define supported (with-asahi-audio base))
(define services (operating-system-user-services supported))
(define alsa (service-value (entry services asahi:alsa-service-type)))
(define session (service-value (home-audio (audio-home supported))))
(define speaker (protection services))
(test-eq "ALSA selects current PipeWire" current:pipewire (alsa-pipewire alsa))
(test-eq "ALSA and Home share one PipeWire" (alsa-pipewire alsa) (home-pipewire session))
(test-eq "Home selects current WirePlumber" current:wireplumber (home-wireplumber session))
(test-eq "Home selects current LV2 effects" current:lsp-plugins (home-lsp session))
(test-eq "Home selects current machine profiles" current:asahi-audio (home-profile session))
(test-eq "speaker protection selects current daemon" current:speakersafetyd
  (speakersafetyd-configuration-speakersafetyd (service-value speaker)))

;; Inspect the actual Shepherd start expression, including its privileges.
(define speaker-extension
  (find (lambda (extension)
          (eq? (service-extension-target extension) shepherd-root-service-type))
        (service-type-extensions (service-kind speaker))))
(define shepherd
  (car ((service-extension-compute speaker-extension) (service-value speaker))))
(define command (gexp->approximate-sexp (shepherd-service-start shepherd)))
(define (contains? value tree)
  (or (equal? value tree)
      (and (pair? tree) (or (contains? value (car tree))
                            (contains? value (cdr tree))))))
(test-assert "v3 launch omits removed blackbox argument"
  (not (contains? "--blackbox-path" command)))
(test-assert "v3 launch retains model configuration" (contains? "--config-path" command))
(test-assert "v3 launch retains gain limit" (contains? "--max-reduction" command))
(test-assert "v3 launch retains audio supplementary group" (contains? "audio" command))
(test-equal "protection waits for device management" '(user-processes udev)
  (shepherd-service-requirement shepherd))

(define custom-home-service
  (service asahi:home-pipewire-service-type
           (asahi:home-pipewire-configuration (enable-pulseaudio? #f))))
(test-eq "explicit Home configuration is preserved" custom-home-service
  (home-audio (with-asahi-home-audio
               (home-environment (services (list custom-home-service))))))
(define custom-alsa
  (service asahi:alsa-service-type
           ((@@ (asahi guix services sound) alsa-configuration)
            (extra-options "# Personal ALSA configuration\n"))))
(define custom-speaker
  (service speakersafetyd-service-type
           (speakersafetyd-configuration (maximum-gain-reduction 5))))
(define custom-services
  (operating-system-user-services
   (with-asahi-audio
    (operating-system (inherit base)
                      (services (list custom-alsa custom-speaker))))))
(test-eq "explicit ALSA configuration is preserved" custom-alsa
  (entry custom-services asahi:alsa-service-type))
(test-eq "explicit speaker configuration is preserved" custom-speaker
  (protection custom-services))

(define explicit-defaults
  (with-asahi-audio
   (operating-system (inherit base)
                     (services (list (service asahi:alsa-service-type)
                                     (service speakersafetyd-service-type))))))
(test-eq "implicit existing ALSA default moves forward" current:pipewire
  (alsa-pipewire
   (service-value (entry (operating-system-user-services explicit-defaults)
                         asahi:alsa-service-type))))
(test-eq "implicit existing speaker default moves forward" current:speakersafetyd
  (speakersafetyd-configuration-speakersafetyd
   (service-value (protection (operating-system-user-services explicit-defaults)))))
(test-eq "implicit existing Home default moves forward" current:pipewire
  (home-pipewire
   (service-value
    (home-audio (with-asahi-home-audio
                 (home-environment
                  (services (list (service asahi:home-pipewire-service-type)))))))))
(define twice (with-asahi-audio supported))
(test-eq "repeated adaptation keeps selected session" session
  (service-value (home-audio (audio-home twice))))
(test-equal "repeated adaptation adds no second protection daemon" 1
  (count (lambda (entry)
           (eq? (service-type-name (service-kind entry)) 'speakersafetyd))
         (operating-system-user-services twice)))

(test-end "audio-packages")
(exit (zero? (test-runner-fail-count runner)))
