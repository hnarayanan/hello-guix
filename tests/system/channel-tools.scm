;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Tools for a local signed-channel fixture, separate from installed profiles.

(use-modules (gnu packages base)
             (gnu packages bash)
             (gnu packages gnupg)
             (gnu packages version-control)
             (guix gexp))

(file-union "channel-authentication-tools"
  `(("bash" ,(file-append bash-minimal "/bin/bash"))
    ("bin" ,(file-append coreutils "/bin"))
    ("cmp" ,(file-append diffutils "/bin/cmp"))
    ("git" ,(file-append git-minimal "/bin/git"))
    ("gpg" ,(file-append gnupg "/bin/gpg"))
    ("gpgconf" ,(file-append gnupg "/bin/gpgconf"))
    ("timeout" ,(file-append coreutils "/bin/timeout"))))
