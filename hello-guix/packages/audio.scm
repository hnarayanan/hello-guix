;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix packages audio)
  #:use-module ((asahi guix packages audio) #:prefix asahi:)
  #:use-module (gnu packages linux)
  #:use-module ((gnu packages rust-apps) #:prefix guix:)
  #:use-module (guix build-system cargo)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hello-guix packages upstream)
  #:use-module (ice-9 match)
  #:export (asahi-audio speakersafetyd))

(define asahi-audio
  (package
    (inherit asahi:asahi-audio)
    ;; Upstream 5.0 relicensed the 4.2 sources under GPLv2-or-later.
    (license license:gpl2+)))

;; Registry inputs from speakersafetyd 3.0.0's published Cargo.lock. Keep the
;; complete lock, including target-specific crates, for Cargo's offline resolver.
(define %speakersafetyd-cargo-inputs
  (map
   (match-lambda
     ((name version checksum)
      (origin
        (method url-fetch)
        (uri (crate-uri name version))
        (file-name (string-append "rust-" name "-" version ".tar.gz"))
        (sha256 (base32 checksum)))))
   '(("alsa" "0.11.0"
      "0pdx9k0766lfwnflia3vaxl89rfjc4v3riym5jl71mnwkq24fac1")
     ("alsa-sys" "0.4.0"
      "010yyg1wp3dijm6574s3m0r23azab1scxv7b0zvd6p96b846jxdd")
     ("anstream" "1.0.0"
      "13d2bj0xfg012s4rmq44zc8zgy1q8k9yp7yhvfnarscnmwpj2jl2")
     ("anstyle" "1.0.14"
      "0030szmgj51fxkic1hpakxxgappxzwm6m154a3gfml83lq63l2wl")
     ("anstyle-parse" "1.0.0"
      "03hkv2690s0crssbnmfkr76kw1k7ah2i6s5amdy9yca2n8w7zkjj")
     ("anstyle-query" "1.1.5"
      "1p6shfpnbghs6jsa0vnqd8bb8gd7pjd0jr7w0j8jikakzmr8zi20")
     ("anstyle-wincon" "3.0.11"
      "0zblannm70sk3xny337mz7c6d8q8i24vhbqi42ld8v7q1wjnl7i9")
     ("bitflags" "2.13.2"
      "01hbgjwvid66850fzi76mvn5f2bqycx6sf165ng1kfjqq9bl1v9x")
     ("cfg-if" "1.0.5"
      "0026j56901nzjraap3da0a8njw42j66zcxnn6s2s9aa5bcblhxjf")
     ("clap" "4.6.7"
      "0il98y2rfw75984ck59znd4n592p07bxz8yy3a9blddb02rpd25a")
     ("clap-verbosity-flag" "3.0.4"
      "1513fiasgif7h7nxbnzs3ddkwm6n43lwcz5ph4w99zkjnbxb34lx")
     ("clap_builder" "4.6.7"
      "0kbhai5rv1vj9r4np52g2b9fmhvy3y82digs9v40c57bgbxrf1zc")
     ("clap_derive" "4.6.7"
      "1q36bgbkfb9rdz7jcvd0ffv0wwlyw0lg3z6iwdcybm0mjjvm3izr")
     ("clap_lex" "1.1.1"
      "11k4m4ngn39iz39lnq6nn6kyxzp62mnm1d86qfad3q0vlk33n4qw")
     ("colorchoice" "1.0.5"
      "0w75k89hw39p0mnnhlrwr23q50rza1yjki44qvh2mgrnj065a1qx")
     ("configparser" "3.3.0"
      "0998lfc9dg565w96817a5amd8zi6ar2sw1b5cgnp8ab2cz8x66h3")
     ("equivalent" "1.0.2"
      "03swzqznragy8n0x31lqc78g2af054jwivp7lkrbrc0khz74lyl7")
     ("errno" "0.3.14"
      "1szgccmh8vgryqyadg8xd58mnwwicf39zmin3bsn63df2wbbgjir")
     ("hashbrown" "0.17.1"
      "0jmqz7i4yl6cm7rbn0i2ffkfrmwi6xkmzkaldr2v8bcsx2v0jngd")
     ("heck" "0.5.0"
      "1sjmpsdl8czyh9ywl3qcsfsq9a307dg4ni2vnlwgnzzqhc4y0113")
     ("indexmap" "2.14.2"
      "0mf86hbjkkcd82cpq683bblbs0zwa8ndla96ci8p1ji6bl7ijknc")
     ("is_terminal_polyfill" "1.70.2"
      "15anlc47sbz0jfs9q8fhwf0h3vs2w4imc030shdnq54sny5i7jx6")
     ("libc" "0.2.189"
      "1whjfs375vlng2q6yrbzs73cvp5lm3w1n2gfqajb2vgf7zg3xbry")
     ("log" "0.4.34"
      "1ihkzn0m33ab79fcl4mkb04n5iwqzbxzyw7l7hazqkffaqzbvy7r")
     ("once_cell_polyfill" "1.70.2"
      "1zmla628f0sk3fhjdjqzgxhalr2xrfna958s632z65bjsfv8ljrq")
     ("pkg-config" "0.3.34"
      "0j05h08nzg0q8rf6lzw7nry0b7kn7x97vc9n4hwrl52fqzxn9d7n")
     ("proc-macro2" "1.0.107"
      "1nb6ly8kp65f724kj73ippc7lvydss24sm2vagk6qpklpg4pwplq")
     ("quote" "1.0.47"
      "00ch0yyzvv6s671ik0kcsbw8nigdaj2g3fr61kcahwx48aqlvgqz")
     ("signal-hook" "0.4.4"
      "0gdm8kmi1mcd30gkxcwagxiqiasq0fhdlvrfsnybv3chln6c585j")
     ("signal-hook-registry" "1.4.8"
      "06vc7pmnki6lmxar3z31gkyg9cw7py5x9g7px70gy2hil75nkny4")
     ("simple_logger" "5.2.0"
      "05qw0xv4ifhlpwd79gyrcqzndwynyrp6y6kyck7gj6v6jq78s0y7")
     ("strsim" "0.11.1"
      "0kzvqlw8hxqb7y598w1s0hxlnmi84sg5vsipp3yg5na5d1rvba3x")
     ("syn" "3.0.6"
      "1vmw7s58rzrs926nv5m06x7qbgswm1aa9iw3s1bj5var47kyi4w5")
     ("unicode-ident" "1.0.26"
      "0m3915ipi4zz7isncf5k1dz47ys0nq9j7l4l2n2rm03zaxwg8ifj")
     ("utf8parse" "0.2.2"
      "088807qwjq46azicqwbhlmzwrbkz7l4hpw43sdkdyyk524vdxaq6")
     ("windows-link" "0.2.1"
      "1rag186yfr3xx7piv5rg8b6im2dwcf8zldiflvb22xbzwli5507h")
     ("windows-sys" "0.61.2"
      "1z7k3y9b6b5h52kid57lvmvm05362zv1v8w0gc7xyv5xphlp44xf"))))

(define speakersafetyd
  (if (upstream-current? guix:speakersafetyd "3.0.0")
      guix:speakersafetyd
      (package
        (inherit guix:speakersafetyd)
        (replacement #f)
        (version "3.0.0")
        (source
         (origin
           (method url-fetch)
           (uri (crate-uri "speakersafetyd" version))
           (file-name (string-append "speakersafetyd-" version ".tar.gz"))
           (sha256
            (base32 "1sjzx22jfs2yvs1il86kxrpsc1ml60305p2fd7863hxb30xd5bq4"))))
        (arguments
         (substitute-keyword-arguments (package-arguments guix:speakersafetyd)
           ((#:phases phases)
            #~(modify-phases #$phases
                (replace 'fix-paths
                  (lambda _
                    (setenv "PREFIX" #$output)))
                (replace 'prepare-to-install
                  (lambda _
                    ;; Cargo installs the binary; Shepherd supplies the service.
                    (install-file "95-speakersafetyd.rules"
                                  (string-append #$output "/lib/udev/rules.d"))
                    (copy-recursively "conf/apple"
                                      (string-append #$output
                                                     "/share/speakersafetyd/apple"))))))))
        (inputs (cons alsa-lib %speakersafetyd-cargo-inputs))
        (license license:gpl2))))
