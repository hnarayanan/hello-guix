;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix packages desktop)
  #:use-module ((gnu packages gl) #:prefix gl:)
  #:use-module ((gnu packages gnome) #:prefix gnome:)
  #:use-module ((gnu packages linux) #:prefix linux:)
  #:use-module ((gnu packages llvm) #:prefix llvm:)
  #:use-module ((gnu packages music) #:prefix music:)
  #:use-module ((gnu packages networking) #:prefix networking:)
  #:use-module ((gnu packages slang) #:prefix slang:)
  #:use-module ((gnu packages xdisorg) #:prefix xdisorg:)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hello-guix packages upstream)
  #:export (libdrm mesa bluez pipewire wireplumber lsp-plugins
            network-manager))

;; These stable releases are ahead of the corresponding Guix recipes.  Keep
;; Guix's build instructions and integration, overriding only release inputs
;; and changes required by those inputs.  Retire each override when Guix
;; supplies the same release or a newer supported one.

(define libdrm
  (if (upstream-current? xdisorg:libdrm "2.4.134")
      xdisorg:libdrm
      (package
        (inherit xdisorg:libdrm)
        (replacement #f)
        (version "2.4.134")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://gitlab.freedesktop.org/mesa/drm/-/archive/libdrm-"
                 version "/drm-libdrm-" version ".tar.gz"))
           (file-name (string-append "libdrm-" version ".tar.gz"))
           (sha256
            (base32 "1qlw1179sykb80jd30n2dfy2xiydds5fj4awrcr141hc9f1y863b"))))
        (arguments
         (substitute-keyword-arguments (package-arguments xdisorg:libdrm)
           ((#:phases phases)
            #~(modify-phases #$phases
                ;; This upstream correction is already present in 2.4.134.
                (delete 'build-intel-by-default))))))))

(define mesa
  (if (upstream-current? gl:mesa "26.2.6")
      gl:mesa
      (package
        (inherit gl:mesa)
        (replacement #f)
        (version "26.2.6")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-"
                 version "/mesa-mesa-" version ".tar.gz"))
           (file-name (string-append "mesa-" version ".tar.gz"))
           (sha256
            (base32 "19as05zx9bizr5d091ymrc9gf09xj8yrm6f2zvijhyrrq9s5hcvy"))))
        (propagated-inputs
         (modify-inputs (package-propagated-inputs gl:mesa)
           (replace "libdrm" libdrm))))))

(define bluez
  (if (upstream-current? linux:bluez "5.88")
      linux:bluez
      (package
        (inherit linux:bluez)
        (replacement #f)
        (version "5.88")
        (source
         (origin
           (method url-fetch)
           (uri (string-append "mirror://kernel.org/linux/bluetooth/bluez-"
                               version ".tar.xz"))
           (sha256
            (base32 "18rvcnhxjja81xjcm5yx2321ggh3zyyb62n55iqyxc7qnngc6lk9"))))
        (arguments
         (substitute-keyword-arguments (package-arguments linux:bluez)
           ((#:configure-flags flags)
            #~(cons
               ;; OBEX installs a session service even without systemd. Its
               ;; default directory belongs to the D-Bus input, not BlueZ.
               (string-append "--with-dbussessionbusdir="
                              #$output "/share/dbus-1/services")
               #$flags)))))))

(define pipewire
  (if (upstream-current? linux:pipewire "1.6.11")
      linux:pipewire
      (package
        (inherit linux:pipewire)
        (replacement #f)
        (version "1.6.11")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/"
                 version "/pipewire-" version ".tar.gz"))
           (sha256
            (base32 "0n856phrl39ciqlk5b7lpn4mivz3xw9d9abha3897k3ky550rxzk"))))
        (inputs
         (modify-inputs (package-inputs linux:pipewire)
           (replace "bluez" bluez)
           (replace "libdrm" libdrm))))))

(define wireplumber
  (if (upstream-current? linux:wireplumber "0.5.19")
      linux:wireplumber
      (package
        (inherit linux:wireplumber)
        (replacement #f)
        (version "0.5.19")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/"
                 version "/wireplumber-" version ".tar.gz"))
           (sha256
            (base32 "03z879h44a6r26xkxb7zn1zrblyp8xz2mbayq01sjv2s7ap4wigr"))))
        (inputs
         (modify-inputs (package-inputs linux:wireplumber)
           (replace "pipewire" pipewire))))))

(define lsp-plugins
  (if (upstream-current? music:lsp-plugins "1.2.37")
      music:lsp-plugins
      (package
        (inherit music:lsp-plugins)
        (replacement #f)
        (version "1.2.37")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://github.com/lsp-plugins/lsp-plugins/releases/download/"
                 version "/lsp-plugins-src-" version ".tar.gz"))
           (sha256
            (base32 "1x1d1pqqnz97c6crydkr6bw30wr3nwmawaajjvdkf6ml96r24zxf"))))
        ;; The inherited install phase already separates the standalone programs.
        (outputs '("out" "doc" "lv2" "bin" "debug"))
        (arguments
         (substitute-keyword-arguments (package-arguments music:lsp-plugins)
           ((#:make-flags flags)
            ;; The XDG sub-make otherwise overrides the configured directory.
            #~(cons (string-append "ETCDIR=" #$output "/etc") #$flags))
           ((#:phases phases)
            #~(modify-phases #$phases
                (replace 'configure
                  (lambda _
                    ;; These are now features, rather than TEST/STRICT switches.
                    (invoke "make" "config"
                            (string-append
                             "FEATURES=clap doc jack ladspa lv2 standalone "
                             "strict test ui vst2 xdg")
                            (string-append "PREFIX=" #$output)
                            (string-append "ETCDIR=" #$output "/etc"))))))))
        (inputs
         (modify-inputs (package-inputs music:lsp-plugins)
           (replace "mesa" mesa))))))

(define libndp
  (if (upstream-current? networking:libndp "1.9")
      networking:libndp
      (package
        (inherit networking:libndp)
        (replacement #f)
        (version "1.9")
        (source
         (origin
           (method url-fetch)
           ;; Upstream's HTTPS certificate does not cover libndp.org.  The fixed
           ;; content hash pins this release from its published endpoint.
           (uri (string-append "http://libndp.org/files/libndp-"
                               version ".tar.gz"))
           (sha256
            (base32 "1m1dvn1102xz1hgnaxsdr2c14fbzcfam743na9hrnfnw05723ax8")))))))

(define network-manager
  (if (upstream-current? gnome:network-manager "1.58.1")
      gnome:network-manager
      (package
        (inherit gnome:network-manager)
        (replacement #f)
        (version "1.58.1")
        (source
         (origin
           (method url-fetch)
           (uri (string-append
                 "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/"
                 version "/downloads/NetworkManager-" version ".tar.xz"))
           ;; Both Guix integration patches apply unchanged to this release.
           (patches (origin-patches (package-source gnome:network-manager)))
           (sha256
            (base32 "0kfid13cbcgvbcd2wwbdkl2yjzmr85s974dyblz3s4lqs77n8a16"))))
        (arguments
         (substitute-keyword-arguments (package-arguments gnome:network-manager)
           ((#:configure-flags flags)
            #~(append
               (list "-Dbpf-compiler=clang"
                     ;; Guix uses Shepherd; no systemd generator is installed.
                     "-Dsystemdsystemgeneratordir=no"
                     ;; Terminal authentication needs Guix's setuid helper.
                     "-Dpolkit_agent_helper_1=/run/privileged/bin/polkit-agent-helper-1")
               (map (lambda (flag)
                      ;; The inherited flags close over the old release number.
                      (if (string-prefix? "-Dc_link_args=" flag)
                          (string-append "-Dc_link_args=-Wl,-rpath="
                                         #$output "/lib:"
                                         #$output "/lib/NetworkManager/" #$version)
                          flag))
                    #$flags)))))
        ;; CLAT uses libndp >= 1.9 and a BPF program; nmtui now links S-Lang directly.
        (inputs
         (modify-inputs (package-inputs gnome:network-manager)
           (replace "libndp" libndp)
           (append linux:libbpf slang:slang)))
        (native-inputs
         (modify-inputs (package-native-inputs gnome:network-manager)
           (append llvm:clang-18 linux:bpftool))))))
