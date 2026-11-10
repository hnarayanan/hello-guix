;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Follow upstream for runtime development. Release image inputs are recorded
;; separately in channels.scm; a built system retains its own exact channels.
(cons
 (channel
  (name 'asahi)
  (url "https://codeberg.org/asahi-guix/channel")
  (branch "main")
  (introduction
   (make-channel-introduction
    "3eeb493b037bea44f225c4314c5556aa25aff36c"
    (openpgp-fingerprint
     "D226 A339 D8DF 4481 5DDE  0CA0 3DDA 5252 7D2A C199"))))
 %default-channels)
