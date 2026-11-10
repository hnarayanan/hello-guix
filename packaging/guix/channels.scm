;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Introduction commits establish trust in each channel.
;; The commit fields record release-build inputs and the legacy installer's
;; default channels. Channel-backed installations use separate branch-following
;; defaults. This candidate is under verification.
(list
 (channel
  (name 'guix)
  (url "https://git.guix.gnu.org/guix.git")
  (branch "master")
  (commit "7c39b1b1a0ad114ab5ceab0c53fb84dd0f990d9f")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
 (channel
  (name 'asahi)
  (url "https://codeberg.org/asahi-guix/channel")
  (branch "main")
  (commit "b9132769b361431e999f7d166d715ef4c6e101d2")
  (introduction
   (make-channel-introduction
    "3eeb493b037bea44f225c4314c5556aa25aff36c"
    (openpgp-fingerprint
     "D226 A339 D8DF 4481 5DDE  0CA0 3DDA 5252 7D2A C199")))))
