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

(define (ensure-service services type)
  (if (at-most-one services type) services (append services (list (service type)))))

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
Replace the default PipeWire service. Keep an existing Asahi PipeWire service
unchanged. The user must convert custom generic audio settings to Asahi settings."
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
                              asahi:home-pipewire-service-type)
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
            (fold (lambda (type result) (ensure-service result type)) homes
                  (list asahi:alsa-service-type rtkit-service-type
                        speakersafetyd-service-type elogind-service-type)))
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
