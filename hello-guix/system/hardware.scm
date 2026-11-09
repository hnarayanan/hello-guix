;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix system hardware)
  #:use-module (gnu services)
  #:use-module (gnu services linux)
  #:use-module (gnu services networking)
  #:use-module (gnu system)
  #:use-module (gnu system linux-initrd)
  #:use-module (gnu packages linux)
  #:use-module (asahi guix initrd)
  #:use-module (asahi guix packages linux)
  #:use-module (asahi guix services firmware)
  #:use-module (asahi guix services udev)
  #:use-module (hello-guix system audio)
  #:use-module (hello-guix system boot)
  #:use-module (srfi srfi-1)
  #:export (with-asahi-hardware))

(define (add-service services addition)
  (let ((matches (filter (lambda (service)
                           (eq? (service-kind service) (service-kind addition)))
                         services)))
    (when (> (length matches) 1)
      (error "Duplicate hardware service" (service-type-name (service-kind addition))))
    (if (null? matches) (append services (list addition)) services)))

;; Use iwd in both systems so the installed system can use setup's network profiles.
;; This service requirement also selects iwd as the backend for NetworkManager
;; or ConnMan. No separate backend setting is necessary.
(define (iwd-requirements requirements)
  (let ((replaced (wpa-supplicant-configuration-shepherd-provision
                   (service-type-default-value wpa-supplicant-service-type))))
    (cons 'iwd (remove (lambda (name) (or (eq? name 'iwd) (memq name replaced)))
                       requirements))))

(define (network-services services)
  (let ((managed? (any (lambda (service)
                        (memq (service-kind service)
                              (list network-manager-service-type connman-service-type)))
                      services)))
    (if (not managed?) services
        (add-service
         (filter-map
          (lambda (entry)
            (let ((type (service-kind entry)) (config (service-value entry)))
              (cond
               ((eq? type wpa-supplicant-service-type)
                (unless (eq? config (service-type-default-value type))
                  (error "Cannot replace a configured wpa-supplicant service with iwd"))
                #f)
               ((eq? type network-manager-service-type)
                (service type
                         (network-manager-configuration
                          (inherit config)
                          (shepherd-requirement
                           (iwd-requirements
                            (network-manager-configuration-shepherd-requirement config))))))
               ((eq? type connman-service-type)
                (service type
                         (connman-configuration
                          (inherit config)
                          (shepherd-requirement
                           (iwd-requirements
                            (connman-configuration-shepherd-requirement config))))))
               (else entry))))
          services)
         (service iwd-service-type)))))

(define (hardware-services services)
  (let ((modules (filter (lambda (entry)
                           (eq? (service-kind entry) kernel-module-loader-service-type))
                         services)))
    (when (> (length modules) 1) (error "Duplicate kernel module loader service"))
    (let* ((loader (service kernel-module-loader-service-type
                            (delete-duplicates
                             (append '("asahi" "appledrm")
                                     (if (null? modules) '() (service-value (car modules)))))))
           (updated (if (null? modules) (append services (list loader))
                        (map (lambda (entry) (if (eq? entry (car modules)) loader entry)) services))))
      (fold (lambda (addition result) (add-service result addition))
            (network-services updated)
            (list (service asahi-firmware-service-type) %udev-mtd-by-name-service)))))

(define* (with-asahi-hardware os #:key (audio? #t) (home-users #f))
  "Return OS with the Asahi kernel, firmware, and hardware services from the
selected channels. Keep its bootloader, storage identities, applications,
and personal settings. Keep a matching boot bundle in the system generation.
Install that bundle on EFI separately.

Enable audio by default, including without a desktop. Set AUDIO? to #f to
disable audio setup. Pass HOME-USERS to with-asahi-audio to select the Guix
Home environments this system manages. This function does not inspect the
active system."
  (unless (and (memq (operating-system-kernel os) (list linux-libre asahi-linux))
               (eq? (operating-system-initrd os) base-initrd)
               (not (operating-system-hurd os)))
    (error "This hardware adapter requires the standard Linux initrd and default or Asahi kernel"))
  (when (and (not (eq? (operating-system-kernel os) asahi-linux))
             (pair? (operating-system-kernel-loadable-modules os)))
    (error "Rebuild external kernel modules for Asahi before changing the kernel"))
  (let* ((extra-modules
          (lset-difference string=? (operating-system-initrd-modules os)
                           (base-initrd-modules (operating-system-kernel os))))
         (base
          (operating-system
           (inherit os)
           (kernel asahi-linux)
           (initrd-modules (delete-duplicates (append asahi-initrd-modules extra-modules)))))
         (result
          (operating-system
           (inherit base)
           (services
            (let ((services (hardware-services (operating-system-user-services base)))
                  (kernel (operating-system-kernel base)))
              (when (any (lambda (entry)
                           (and (eq? (service-kind entry) asahi-boot-service-type)
                                (not (eq? (service-value entry) kernel))))
                         services)
                (error "The boot service must use the system's Asahi kernel"))
              (add-service services (service asahi-boot-service-type kernel)))))))
    (if audio? (with-asahi-audio result #:home-users home-users) result)))
