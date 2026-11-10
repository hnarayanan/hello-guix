;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix packages linux)
  #:use-module ((asahi guix packages linux) #:prefix asahi:)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (hello-guix packages upstream))

;; Keep the provider's kernel configuration and build integration. The release
;; source and its matching device trees advance together.
(define-public asahi-linux-7.3.3
  (package
    (inherit asahi:asahi-linux)
    (replacement #f)
    (version "7.3.3-1")
    (source
     (origin
       (inherit (package-source asahi:asahi-linux))
       (uri (git-reference
             (url "https://github.com/AsahiLinux/linux")
             (commit "asahi-7.3.3-1")))
       (file-name (git-file-name "linux-source" "asahi-7.3.3-1"))
       (sha256
        (base32 "1jb0wda74dm6pxkyd9g5ml7788dzj98ra0cdd6lma21jiw28fblp"))))))

(define-public asahi-linux
  (if (upstream-current? asahi:asahi-linux
                         (package-version asahi-linux-7.3.3))
      asahi:asahi-linux
      asahi-linux-7.3.3))
