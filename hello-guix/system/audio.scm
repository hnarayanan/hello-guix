;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system audio)
  #:use-module (gnu home)
  #:use-module (gnu home services desktop)
  #:use-module ((gnu home services sound) #:prefix generic:)
  #:use-module (gnu services)
  #:use-module (gnu services dbus)
  #:use-module (gnu services desktop)
  #:use-module (gnu services guix)
  #:use-module (gnu services sound)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module ((gnu packages rust-apps) #:prefix guix:)
  #:use-module ((hello-guix packages audio) #:prefix platform:)
  #:use-module ((hello-guix packages desktop) #:prefix platform:)
  #:use-module (gnu system)
  #:use-module (gnu system shadow)
  #:use-module ((asahi guix home services sound) #:prefix asahi:)
  #:use-module ((asahi guix services sound) #:prefix asahi:)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (with-asahi-audio with-asahi-home-audio))

(define (services-of-type services type)
  (filter (lambda (service) (eq? (service-kind service) type)) services))

(define (at-most-one services type)
  (let ((matches (services-of-type services type)))
    (when (> (length matches) 1)
      (error "Duplicate service in Asahi audio configuration" (service-type-name type)))
    (and (pair? matches) (car matches))))

(define* (ensure-service services type #:optional configuration)
  (let ((existing (at-most-one services type)))
    ;; Explicit configurations belong to the user. Only implicit defaults move
    ;; with the supported package set.
    (if (and existing
             (or (not configuration)
                 (not (eq? (service-value existing)
                           (service-type-default-value type)))))
        services
        (let ((replacement
               (service type (or configuration (service-type-default-value type)))))
          (if existing
              (map (lambda (entry) (if (eq? entry existing) replacement entry)) services)
              (append services (list replacement)))))))

(define %alsa-configuration
  ;; The provider's ALSA record constructor is not exported.
  ((@@ (asahi guix services sound) alsa-configuration)
   (pipewire platform:pipewire)))

(define %home-audio-configuration
  (asahi:home-pipewire-configuration
   (asahi-audio platform:asahi-audio)
   (lsp-plugins platform:lsp-plugins)
   (pipewire platform:pipewire)
   (wireplumber platform:wireplumber)))

(define (speakersafetyd-v3-shepherd-service config)
  ;; Version 3 removed blackbox recording and its command-line option. Keep
  ;; Guix's service lifecycle and permissions, with the supported arguments.
  (shepherd-service
   (inherit ((@@ (gnu services sound) speakersafetyd-shepherd-service) config))
   (start
    #~(make-forkexec-constructor
       (list #$(file-append (speakersafetyd-configuration-speakersafetyd config)
                           "/bin/speakersafetyd")
             "--config-path" #$(speakersafetyd-configuration-configuration-directory config)
             "--max-reduction"
             (number->string #$(speakersafetyd-configuration-maximum-gain-reduction config)))
       #:group #$((@@ (gnu services sound) speakersafetyd-configuration-group) config)
       #:log-file #$((@@ (gnu services sound) speakersafetyd-configuration-log-file) config)
       #:supplementary-groups '("audio")
       #:user #$((@@ (gnu services sound) speakersafetyd-configuration-user) config)))))

(define (speaker-protection-service-type package upstream)
  ;; Adapt the old Guix service only while carrying our newer daemon. When
  ;; Guix supplies the package, its service owns the matching CLI as well.
  ;; The launch-expression check will expose an upstream package/service mismatch.
  (if (eq? package upstream)
      speakersafetyd-service-type
      (service-type
       (inherit speakersafetyd-service-type)
       (extensions
        (map (lambda (extension)
               (if (eq? (service-extension-target extension) shepherd-root-service-type)
                   (service-extension shepherd-root-service-type
                                      (compose list speakersafetyd-v3-shepherd-service))
                   extension))
             (service-type-extensions speakersafetyd-service-type)))
       (default-value
         (speakersafetyd-configuration
          (speakersafetyd package)
          (configuration-directory
           (file-append package "/share/speakersafetyd")))))))

(define %speaker-protection-service-type
  (speaker-protection-service-type platform:speakersafetyd guix:speakersafetyd))

(define (ensure-speaker-protection services)
  (if (eq? %speaker-protection-service-type speakersafetyd-service-type)
      (ensure-service services speakersafetyd-service-type)
      (let ((existing (at-most-one services speakersafetyd-service-type))
            (adapted (at-most-one services %speaker-protection-service-type)))
        (when (and existing adapted)
          (error "Both generic and adapted speaker protection are declared"))
        (if (and existing
                 (not (eq? (service-value existing)
                           (service-type-default-value speakersafetyd-service-type))))
            services
            (ensure-service (if existing (delq existing services) services)
                            %speaker-protection-service-type)))))

(define (check-default service)
  ;; Guix reuses the same object for each service's default value.
  ;; Convert only that default. A custom server script or routing configuration
  ;; needs a separate Asahi configuration to prevent loss of user settings.
  (unless (eq? (service-value service)
               (service-type-default-value (service-kind service)))
    (error "Automatic audio conversion supports the implicit service default only; configure the Asahi service explicitly"
           (service-type-name (service-kind service)))))

(define (check-extensions services replaced-types)
  ;; An extension can add a service that this adapter removed, or bypass
  ;; the Guix Home conversion. Require the user to adapt such extensions.
  (for-each
   (lambda (service)
     (for-each
      (lambda (extension)
        (when (memq (service-extension-target extension) replaced-types)
          (error "Audio adaptation cannot preserve this service extension"
                 (service-type-name (service-kind service))
                 (service-type-name (service-extension-target extension)))))
      (service-type-extensions (service-kind service))))
   services))

(define (with-asahi-home-audio home)
  "Add the Asahi audio session to HOME. Keep its other services.
Replace the default PipeWire service and select the supported packages for
implicit Asahi defaults. Preserve explicit Asahi settings. The user must
convert custom generic audio settings to Asahi settings."
  (let* ((initial-services (home-environment-user-services home))
         (generic (at-most-one initial-services generic:home-pipewire-service-type))
         (asahi (at-most-one initial-services asahi:home-pipewire-service-type)))
    (when (and generic asahi)
      (error "Both generic and Asahi PipeWire are declared in one Home"))
    (check-extensions initial-services (list generic:home-pipewire-service-type))
    (when generic (check-default generic))
    (let ((result
           (home-environment
            (inherit home)
            (services
             (ensure-service
              (ensure-service (if generic (delq generic initial-services) initial-services)
                              asahi:home-pipewire-service-type
                              %home-audio-configuration)
              home-dbus-service-type)))))
      (when (pair? (services-of-type (home-environment-services result)
                                     generic:home-pipewire-service-type))
        (error "A Home service dependency reintroduces generic PipeWire"))
      result)))

(define (ordinary-users os)
  (filter (lambda (user)
            (and (not (user-account-system? user))
                 (not (equal? (user-account-uid user) 0))
                 (not (string=? (user-account-name user) "root"))))
          (operating-system-user-accounts os)))

(define (adapt-homes services names)
  (let* ((owner (at-most-one services guix-home-service-type))
         (homes (if owner (service-value owner) '()))
         (existing (map car homes)))
    (unless (= (length existing) (length (delete-duplicates existing)))
      (error "Each user must have one Guix Home environment" existing))
    (let ((adapted
           (append
            (map (match-lambda
                   ((name home)
                    (list name (if (member name names)
                                   (with-asahi-home-audio home) home))))
                 homes)
            (map (lambda (name)
                   (list name (with-asahi-home-audio (home-environment))))
                 (lset-difference string=? names existing)))))
      (if (null? adapted) services
          (let ((replacement (service guix-home-service-type adapted)))
            (if owner
                (map (lambda (entry) (if (eq? entry owner) replacement entry)) services)
                (append services (list replacement))))))))

(define* (with-asahi-audio os #:key (home-users #f))
  "Configure Mac audio for any desktop or application choice.
HOME-USERS defaults to all ordinary accounts. Supply a list to select the
accounts whose Guix Home environments this system manages. Other users must
call with-asahi-home-audio in their separate Guix Home configurations.
This function does not read files from user home directories."
  (let* ((names (map user-account-name (ordinary-users os)))
         (selected (if home-users home-users names))
         (initial-services (operating-system-user-services os)))
    (unless (and (list? selected) (every string? selected)
                 (= (length selected) (length (delete-duplicates selected)))
                 (every (lambda (name) (member name names)) selected))
      (error "Audio Home users must be distinct ordinary accounts" selected))
    (for-each
     (lambda (type)
       (let ((service (at-most-one initial-services type)))
         (when service (check-default service))))
     (list alsa-service-type pulseaudio-service-type))
    (let* ((remaining
            (remove (lambda (service)
                      (memq (service-kind service)
                            (list alsa-service-type pulseaudio-service-type)))
                    initial-services))
           (homes (begin
                    (check-extensions remaining
                                      (list alsa-service-type pulseaudio-service-type
                                            guix-home-service-type))
                    (adapt-homes remaining selected)))
           (supported
            (fold (lambda (type result) (ensure-service result type))
                  (ensure-speaker-protection
                   (ensure-service homes asahi:alsa-service-type %alsa-configuration))
                  (list rtkit-service-type elogind-service-type)))
           (result (operating-system (inherit os) (services supported))))
      ;; Check services added through dependencies, including nested extensions.
      ;; They must not add the generic audio server after conversion.
      (let ((resolved (operating-system-services result)))
        (when (any (lambda (service)
                     (memq (service-kind service)
                           (list alsa-service-type pulseaudio-service-type)))
                   resolved)
          (error "A service dependency reintroduces generic audio"))
        (check-extensions resolved (list guix-home-service-type)))
      result)))
