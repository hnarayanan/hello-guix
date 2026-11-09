;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run on ordinary temporary files, or on the target VM's mounted FAT filesystem.

(use-modules (hello-guix system boot-files)
             (guix build utils)
             (srfi srfi-64))

(define (run-tests directory)
  (test-begin "boot-files")
  (define runner (test-runner-current))
  (define (path name) (string-append directory "/" name))
  (define (write-file name text)
    (call-with-output-file (path name) (lambda (port) (display text port))))
  (define (contents name)
    (call-with-input-file (path name) (@ (ice-9 textual-ports) get-string-all)))
  (write-file "boot.bin" "working")
  (write-file "candidate" "candidate")
  (test-equal "install" 'installed (install-boot-bundle (path "candidate") directory))
  (test-equal "candidate selected" "candidate" (contents "boot.bin"))
  (test-equal "previous bundle retained" "working" (contents "boot.bin.old"))
  (test-equal "repeat" 'unchanged (install-boot-bundle (path "candidate") directory))
  (test-equal "repeat retains backup" "working" (contents "boot.bin.old"))
  (test-equal "restore backup in place" 'installed
    (install-boot-bundle (path "boot.bin.old") directory))
  (test-equal "old bytes restored" "working" (contents "boot.bin"))
  (test-equal "candidate available for return" "candidate" (contents "boot.bin.old"))
  (write-file "empty" "")
  (test-error "empty input refused" #t (install-boot-bundle (path "empty") directory))
  (test-error "missing input refused" #t (install-boot-bundle (path "missing") directory))
  (test-equal "failed input preserves working file" "working" (contents "boot.bin"))
  ;; Make the final rename fail. Copy and fsync operations still run.
  ;; Both the active bundle and its backup must remain usable.
  (define module (resolve-module '(hello-guix system boot-files)))
  (define original-rename rename-file)
  (define rename-binding (module-variable module 'rename-file))
  (variable-set! rename-binding
    (lambda (from to)
      (if (string=? to (path "boot.bin")) (error "injected publication failure")
          (original-rename from to))))
  (test-error "failed publication" #t (install-boot-bundle (path "candidate") directory))
  (test-equal "live bundle intact" "working" (contents "boot.bin"))
  (test-equal "recovery copy intact" "working" (contents "boot.bin.old"))
  (variable-set! rename-binding original-rename)
  (test-equal "retry after failure" 'installed (install-boot-bundle (path "candidate") directory))
  (test-equal "retry backup" "working" (contents "boot.bin.old"))
  (check-boot-target "abc" "ABC" "vfat")
  (test-error "wrong EFI identity refused" #t (check-boot-target "abc" "def" "vfat"))
  (test-error "missing chosen identity refused" #t (check-boot-target "" "" "vfat"))
  (test-error "non-FAT mount refused" #t (check-boot-target "abc" "abc" "ext4"))
  (test-end "boot-files")
  (unless (= 0 (test-runner-fail-count runner)) (error "Boot-file tests failed")))

(define (run-destination-tests directory)
  (test-begin "boot-destination")
  (define runner (test-runner-current))
  (define base (canonicalize-path directory))
  (define root (string-append base "/root"))
  (define esp (string-append root "/boot/efi"))
  (define outside (string-append base "/outside"))
  (define source (string-append base "/candidate"))
  (define (put file text)
    (call-with-output-file file (lambda (port) (display text port))))
  (define (contents file)
    (call-with-input-file file (@ (ice-9 textual-ports) get-string-all)))
  (define binding
    (module-variable (resolve-module '(hello-guix system boot-files))
                     'mounted-boot-identity))
  (define original (variable-ref binding))
  (define probe-mode 'matching)
  (define probed '())
  (mkdir-p (string-append esp "/m1n1"))
  (mkdir-p (string-append outside "/m1n1"))
  (put source "candidate")
  (put (string-append esp "/m1n1/boot.bin") "working")
  (put (string-append outside "/m1n1/boot.bin") "outside")
  ;; Mock only mount inspection. The destination selection and durable writer
  ;; still operate on real ordinary temporary files, without root privileges.
  (dynamic-wind
    (lambda ()
      (variable-set! binding
        (lambda (findmnt path)
          (set! probed (cons path probed))
          (case probe-mode
            ((matching) (values "ABC" "vfat"))
            ((wrong-id) (values "DEF" "vfat"))
            ((not-fat) (values "ABC" "ext4"))
            ((not-mounted) (error "injected missing mount" path))))))
    (lambda ()
      (test-equal "alternate-root destination" esp
        (check-boot-destination "/boot/efi" root "abc" "unused-findmnt"))
      (test-equal "mount inspection uses alternate root" esp (car probed))
      (test-equal "live-root destination" esp
        (check-boot-destination esp "/" "abc" "unused-findmnt"))
      (test-equal "mount inspection uses live-root path" esp (car probed))
      (test-equal "prepared alternate-root installation" 'installed
        (install-target-boot source "/boot/efi" root "abc" "unused-findmnt"))
      (test-equal "alternate-root bundle selected" "candidate"
        (contents (string-append esp "/m1n1/boot.bin")))
      (test-equal "alternate-root backup retained" "working"
        (contents (string-append esp "/m1n1/boot.bin.old")))
      (test-equal "alternate-root repeat" 'unchanged
        (install-target-boot source "/boot/efi" root "abc" "unused-findmnt"))
      (for-each
       (lambda (mode)
         (set! probe-mode mode)
         (test-error (symbol->string mode) #t
           (install-target-boot source "/boot/efi" root "abc" "unused-findmnt"))
         (test-equal "rejection preserves current bundle" "candidate"
           (contents (string-append esp "/m1n1/boot.bin")))
         (test-equal "rejection preserves backup" "working"
           (contents (string-append esp "/m1n1/boot.bin.old"))))
       '(wrong-id not-fat not-mounted))
      (set! probe-mode 'matching)
      (let ((before probed))
        (test-error "missing target has no live-target fallback" #t
          (install-target-boot source "/missing" root "abc" "unused-findmnt"))
        (test-error "root target refused" #t
          (check-boot-destination "/" "/" "abc" "unused-findmnt"))
        (test-error "canonical root target refused" #t
          (check-boot-destination "//" "/" "abc" "unused-findmnt"))
        (test-error "alternate root itself refused" #t
          (check-boot-destination "//" root "abc" "unused-findmnt"))
        (symlink root (string-append root "/same-root"))
        (test-error "symlink to alternate root refused" #t
          (check-boot-destination "/same-root" root "abc" "unused-findmnt"))
        (let ((root-link (string-append base "/root-link")))
          (symlink "/" root-link)
          (test-error "symlink to live root refused" #t
            (check-boot-destination root-link "/" "abc" "unused-findmnt")))
        (test-error "relative root refused" #t
          (check-boot-destination "/boot/efi" "relative-root" "abc" "unused-findmnt"))
        (test-error "relative target refused" #t
          (install-target-boot source "boot/efi" root "abc" "unused-findmnt"))
        (test-error "parent traversal refused" #t
          (install-target-boot source "/../outside" root "abc" "unused-findmnt"))
        (symlink outside (string-append root "/escape"))
        (test-error "symlink escape refused" #t
          (install-target-boot source "/escape" root "abc" "unused-findmnt"))
        (test-equal "invalid paths rejected before mount inspection" before probed))
      (rename-file (string-append esp "/m1n1") (string-append esp "/retained"))
      (symlink (string-append outside "/m1n1") (string-append esp "/m1n1"))
      (test-error "m1n1 symlink refused" #t
        (install-target-boot source "/boot/efi" root "abc" "unused-findmnt"))
      (test-equal "outside files untouched" "outside"
        (contents (string-append outside "/m1n1/boot.bin"))))
    (lambda () (variable-set! binding original)))
  (test-end "boot-destination")
  (unless (= 0 (test-runner-fail-count runner))
    (error "Boot destination tests failed")))

(define (run-deployment-tests directory)
  (test-begin "boot-deployment-files")
  (define runner (test-runner-current))
  (define base (canonicalize-path directory))
  (define root (string-append base "/root"))
  (define esp (string-append root "/boot/efi"))
  (define boot-directory (string-append esp "/m1n1"))
  (define live (string-append boot-directory "/boot.bin"))
  (define previous (string-append boot-directory "/boot.bin.old"))
  (define accepted (string-append base "/accepted-generation"))
  (define captured (string-append base "/captured-working-boot.bin"))
  (define second (string-append base "/second-generation"))
  (define third (string-append base "/third-generation"))
  (define lock-file (string-append base "/boot.lock"))
  (define module (resolve-module '(hello-guix system boot-files)))
  (define probe-mode 'matching)
  (define installer-mode 'success)
  (define calls 0)
  (define events '())
  (define (put file text)
    (call-with-output-file file (lambda (port) (display text port))))
  (define (contents file)
    (call-with-input-file file (@ (ice-9 textual-ports) get-string-all)))
  (define (with-binding name value thunk)
    (let* ((binding (module-variable module name))
           (original (variable-ref binding)))
      (dynamic-wind
        (lambda () (variable-set! binding value))
        thunk
        (lambda () (variable-set! binding original)))))
  (define (probe findmnt path)
    (set! events (append events '(mount)))
    (case probe-mode
      ((matching) (values "ABC" "vfat"))
      ((wrong-id) (values "DEF" "vfat"))
      ((not-mounted) (error "injected missing mount"))))
  (define (installer package target destination-root)
    (set! calls (+ calls 1))
    (set! events (append events '(grub)))
    (test-equal "inherited package preserved" 'original-grub package)
    (test-equal "inherited target preserved" "/boot/efi" target)
    (test-equal "inherited root preserved" root destination-root)
    (when (= calls 1)
      (test-equal "inherited installer precedes bundle write" "prepared" (contents live))
      (call-with-input-file lock-file
        (lambda (port)
          (test-error "shared lock held during inherited installation" #t
            (flock port (logior LOCK_EX LOCK_NB))))))
    (case installer-mode
      ((failure) (error "injected inherited installer failure"))
      ((change-mount) (set! probe-mode 'wrong-id))))
  (define* (deploy source #:key (target "/boot/efi") (destination-root root))
    (install-asahi-bootloader installer 'original-grub source target
                             destination-root "unused-findmnt"
                             #:expected "abc" #:lock-file lock-file))
  (define (lock-available?)
    (let ((port (open-file lock-file "r")))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (catch 'system-error
            (lambda () (flock port (logior LOCK_EX LOCK_NB)) #t)
            (lambda arguments #f)))
        (lambda () (close-port port)))))
  (define (expect-refusal name thunk)
    (let ((before calls)
          (active (contents live))
          (backup (contents previous)))
      (test-error name #t (thunk))
      (test-assert "preflight refusal releases shared lock" (lock-available?))
      (test-equal "preflight refusal skips inherited installer" before calls)
      (test-equal "preflight refusal preserves active bundle" active (contents live))
      (test-equal "preflight refusal preserves backup" backup (contents previous))))
  (mkdir-p boot-directory)
  (put live "prepared")
  (put accepted "accepted")
  (put captured "prepared")
  (put second "second")
  (put third "third")
  (with-binding 'mounted-boot-identity probe
    (lambda ()
      ;; A false target must not even try the authority or lock paths.
      (test-equal "image target has no deployment effects" 'skipped
        (install-asahi-bootloader installer 'original-grub "/missing-source"
                                 #f "/missing-root" "/missing-findmnt"
                                 #:lock-file (string-append base "/missing/lock")))
      (test-equal "image target skips inherited installer" 0 calls)
      (test-equal "image target skips mount inspection" '() events)
      (test-assert "image target creates no lock" (not (file-exists? lock-file)))
      (test-equal "initial prepared installation" 'installed (deploy accepted))
      (test-equal "validation and deployment order" '(mount grub mount) events)
      (test-equal "initial selected bytes" "accepted" (contents live))
      (test-equal "initial prepared bytes retained" "prepared" (contents previous))
      (test-equal "identical bundle" 'unchanged (deploy accepted))
      (test-equal "identical bundle preserves backup" "prepared" (contents previous))
      (test-equal "second generation" 'installed (deploy second))
      (test-equal "third generation" 'installed (deploy third))
      (test-equal "previous write is not accepted generation" "second" (contents previous))
      (test-equal "accepted source survives repeated changes" "accepted" (contents accepted))
      ;; Use the retained generation, not the rotating .old file, for return.
      (test-equal "explicit return to retained generation" 'installed
        (install-asahi-bootloader (lambda arguments #t) #f accepted
                                 "/boot/efi" root "unused-findmnt"
                                 #:expected "abc" #:lock-file lock-file))
      (test-equal "accepted bytes restored" "accepted" (contents live))
      (test-equal "returned-from generation retained" "third" (contents previous))
      (expect-refusal "missing target refused before GRUB"
        (lambda () (deploy second #:target "/missing")))
      (expect-refusal "wrong root refused before GRUB"
        (lambda () (deploy second #:destination-root (string-append base "/missing-root"))))
      (set! probe-mode 'wrong-id)
      (expect-refusal "wrong identity refused before GRUB" (lambda () (deploy second)))
      (set! probe-mode 'not-mounted)
      (expect-refusal "unmounted target refused before GRUB" (lambda () (deploy second)))
      (set! probe-mode 'matching)
      (put (string-append base "/empty") "")
      (symlink second (string-append base "/source-link"))
      (for-each
       (lambda (name)
         (expect-refusal (string-append "invalid source: " name)
           (lambda () (deploy (string-append base "/" name)))))
       '("missing" "empty" "source-link"))
      (put live "")
      (expect-refusal "empty prepared bundle refused before GRUB" (lambda () (deploy second)))
      (put live "accepted")
      (set! installer-mode 'failure)
      (let ((before calls))
        (test-error "inherited failure propagates" #t (deploy second))
        (test-equal "inherited installer was reached" (+ before 1) calls))
      (test-assert "inherited failure releases shared lock" (lock-available?))
      (test-equal "inherited failure preserves bundle" "accepted" (contents live))
      (test-equal "inherited failure preserves backup" "third" (contents previous))
      (set! installer-mode 'change-mount)
      (test-error "identity rechecked after inherited installer" #t (deploy second))
      (test-equal "changed identity preserves bundle" "accepted" (contents live))
      (set! installer-mode 'success)
      (set! probe-mode 'matching)
      ;; Inject ENOSPC at the first copy; GRUB has run, but bundle files stay put.
      (with-binding 'copy-file
        (lambda arguments
          (throw 'system-error "copy-file" "~A" (list (strerror ENOSPC)) (list ENOSPC)))
        (lambda () (test-error "no-space copy failure propagates" #t (deploy second))))
      (test-assert "no-space failure releases shared lock" (lock-available?))
      (test-equal "no space preserves active bundle" "accepted" (contents live))
      (test-equal "no space preserves backup" "third" (contents previous))
      ;; This is an interrupted syscall, not a simulated machine power loss.
      (let ((original-rename rename-file))
        (with-binding 'rename-file
          (lambda (from to)
            (if (string=? to live)
                (throw 'system-error "rename-file" "~A" (list (strerror EINTR)) (list EINTR))
                (original-rename from to)))
          (lambda ()
            (test-error "interrupted publication propagates" #t (deploy second)))))
      (test-assert "interrupted publication releases shared lock" (lock-available?))
      (test-equal "interruption preserves active bundle" "accepted" (contents live))
      (test-equal "interruption retains a recovery copy" "accepted" (contents previous))
      (test-equal "interruption preserves accepted generation" "accepted" (contents accepted))
      (test-equal "retry after interrupted write" 'installed (deploy second))
      (test-equal "retry selects intended bytes" "second" (contents live))
      (test-equal "retry retains accepted bytes" "accepted" (contents previous))
      ;; Installation's working bytes can differ from its retained constructor
      ;; output. An explicit external return must select the captured bytes.
      (test-equal "explicit return to captured working bytes" 'installed
        (install-asahi-bootloader (lambda arguments #t) #f captured
                                 "/boot/efi" root "unused-findmnt"
                                 #:expected "abc" #:lock-file lock-file))
      (test-equal "captured bytes restored exactly" "prepared" (contents live))
      (test-equal "retained constructor output remains distinct" "accepted" (contents accepted))
      (call-with-input-file lock-file
        (lambda (port)
          (flock port (logior LOCK_EX LOCK_NB))
          (test-assert "shared lock released after deployment" #t)))))
  (test-end "boot-deployment-files")
  (unless (= 0 (test-runner-fail-count runner))
    (error "Boot deployment tests failed")))

(let* ((external (getenv "BOOT_TEST_DIRECTORY"))
       (directory (or external (mkdtemp "/tmp/hello-guix-boot-XXXXXX")))
       (destination (mkdtemp "/tmp/hello-guix-boot-target-XXXXXX"))
       (deployment (mkdtemp "/tmp/hello-guix-boot-deploy-XXXXXX")))
  (dynamic-wind
    (const #t)
    (lambda ()
      (run-tests directory)
      (run-destination-tests destination)
      (run-deployment-tests deployment))
    (lambda ()
      (unless external (delete-file-recursively directory))
      (delete-file-recursively destination)
      (delete-file-recursively deployment))))
