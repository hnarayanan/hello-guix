;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Introduction commits establish trust in each channel.
;; The commit fields select the tested versions to build and install.
(list
 (channel
  (name 'guix)
  (url "https://git.guix.gnu.org/guix.git")
  (branch "master")
  (commit "9a7fb4173f9b503c4cafedaa0aa4bdd9d83fc5dc")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
 (channel
  (name 'asahi)
  (url "https://codeberg.org/asahi-guix/channel")
  (branch "main")
  (commit "ee2e7465c0137224bcc0ad3b3d0d02109cb3a6c7")
  (introduction
   (make-channel-introduction
    "3eeb493b037bea44f225c4314c5556aa25aff36c"
    (openpgp-fingerprint
     "D226 A339 D8DF 4481 5DDE  0CA0 3DDA 5252 7D2A C199")))))
