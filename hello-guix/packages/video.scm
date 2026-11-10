;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix packages video)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages llvm)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages video)
  #:use-module (gnu packages xdisorg)
  #:use-module ((hello-guix packages desktop) #:prefix desktop:)
  #:use-module (guix build-system meson)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix search-paths))

(define-public avd-firmware
  (package
    (name "avd-firmware")
    (version "0.2")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/AsahiLinux/avd-fw/archive/refs/tags/v"
                           version ".tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "0g90qykipfgafjpsria9mmjik0w6kl56x94sc8d7flifddii6f5q"))))
    (build-system meson-build-system)
    (arguments
     (list
      #:tests? #f                      ;Upstream provides no test suite.
      #:strip-binaries? #f             ;These are raw Cortex-M3 firmware images.
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'set-release-version
            (lambda _
              ;; GitHub archives lack the Git metadata expected by version.sh.
              (substitute* "meson.build"
                (("    version: .*")
                 (string-append "    version: '" #$version "',\n")))))
          (replace 'configure
            (lambda _
              ;; This bare-metal target must not inherit the host ELF rpath
              ;; added by the ordinary Meson configure phase.
              (let ((source (getcwd)))
                (mkdir "../build")
                (chdir "../build")
                (invoke "meson" "setup"
                        (string-append "--prefix=" #$output)
                        "--buildtype=release" "--wrap-mode=nofallback"
                        (string-append "--cross-file=" source "/llvm.ini")
                        "-Dvideo-codecs=all" source))))
          (add-after 'install 'firmware-permissions
            (lambda _
              (for-each (lambda (file) (chmod file #o644))
                        (find-files #$output "\\.bin$")))))))
    (native-inputs (list clang-19 lld-19 llvm-19))
    (home-page "https://github.com/AsahiLinux/avd-fw")
    (synopsis "Free firmware for the Apple Video Decoder")
    (description
     "This package builds Asahi Linux's free replacement firmware for the
Apple Video Decoder's Cortex-M3 processor.  The Linux AVD driver loads the
appropriate image from lib/firmware/apple.  It includes the supported codec
implementations and is separate from Apple-supplied device firmware.")
    (license license:expat)))

(define-public asahi-va-driver
  (package
    (name "asahi-va-driver")
    (version "2.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/AsahiLinux/asahi-va-driver/archive/refs/tags/"
                           version ".tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "16k1js8kli87idc5akv7aaql6q0kkravlqyc327cma6z56n9k8xy"))))
    (build-system meson-build-system)
    (arguments
     (list #:configure-flags
           #~(list (string-append "-Ddriverdir=" #$output "/lib/dri"))))
    (native-inputs (list pkg-config))
    (inputs (list desktop:libdrm libva linux-libre-headers-latest))
    ;; Follow Guix's other VA-API backends: the profile supplies driver discovery.
    (native-search-paths
     (list (search-path-specification
            (variable "LIBVA_DRIVERS_PATH")
            (files '("lib/dri")))))
    (home-page "https://github.com/AsahiLinux/asahi-va-driver")
    (synopsis "VA-API video decoding through Apple's stateless V4L2 driver")
    (description
     "This VA-API backend translates video decoding requests into Linux's
stateless V4L2 interface, with support for Apple Silicon.  It works with the
Asahi AVD kernel driver and free AVD firmware.  The backend is installed as
asahi_drv_video.so for discovery through libva's normal driver path.")
    (license license:gpl3+)))
