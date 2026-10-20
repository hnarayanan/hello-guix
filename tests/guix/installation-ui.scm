;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run inside the disposable VM, using Guix's own installer test protocol.

(use-modules (gnu installer tests)
             (gnu services herd)
             (guix build utils)
             (guix store)
             (gcrypt hash)
             (ice-9 textual-ports)
             (ice-9 pretty-print)
             (ice-9 match)
             (srfi srfi-1))

(unless (and (zero? (getuid))
             (string-prefix? "linux,dummy-virt"
               (call-with-input-file "/proc/device-tree/model" get-string-all))
             (file-exists? "/dev/vda2")
             (file-exists? "/dev/hello-guix/target.json"))
  (error "This check requires the disposable installation VM"))
(setvbuf (current-output-port) 'none)
(setvbuf (current-error-port) 'none)

;; Stop the installer on tty1 before the test starts another instance.
;; QEMU has no keyboard input for kmscon here. Wait for tty1 first, because
;; the serial login can start before the graphical console.
(wait-for-service 'term-tty1)
(invoke "herd" "stop" "term-tty1")

;; Guix can reuse setup packages during installation if its database records them.
;; Without these records, Guix would download the packages again.
(with-store store
  (let ((items (requisites store (list (canonicalize-path "/run/booted-system")))))
    (unless (and (pair? items) (every (lambda (item) (valid-path? store item)) items))
      (error "The live system's package store is not registered"))))

;; Run the activation scripts twice. Guix sets the generic firmware path first.
;; Then the Asahi service adds firmware from EFI and sets the final search path.
(define (firmware-state)
  (map (lambda (path) (cons path (file-sha256 path)))
       (find-files "/run/asahi-guix/firmware")))
(define firmware-before (firmware-state))
(unless (file-exists? "/run/asahi-guix/firmware/hello-guix-test")
  (error "Vendor firmware fixture was not activated"))
(for-each
 (lambda (_)
   (invoke "/run/booted-system/activate")
   (unless (and (equal? firmware-before (firmware-state))
                (equal? "/run/asahi-guix/firmware"
                  (string-trim-both (call-with-input-file
                    "/sys/module/firmware_class/parameters/path" get-string-all)))
                (= 1 (count (lambda (line) (string-contains line " /run/asahi-guix/firmware "))
                       (string-split (call-with-input-file "/proc/mounts" get-string-all) #\newline))))
     (error "Firmware reactivation changed its contents, lookup path or mount count")))
 '(1 2))
(display "HELLO-GUIX-LIVE-STATE-PASS\n")

;; Run the packaged installer with a terminal. This test supplies only the answers.
;; Keep the questions, formatters, and installation procedures unchanged.
(define child (primitive-fork))
(when (zero? child)
  (let ((null (open-input-file "/dev/null")))
    (dup2 (fileno null) 0)
    (setenv "TERM" "xterm")
    (execlp "script" "script" "-q" "-e" "-f" "-c"
            "stty rows 50 cols 100; exec guix-system-installer" "/tmp/hello-guix-ui.log")))

(define socket
  (let loop ((remaining 120))
    (catch 'system-error open-installer-socket
      (lambda _
        (when (zero? remaining) (error "Installer did not open its test socket"))
        (sleep 1)
        (loop (- remaining 1))))))

(choose-locale+keyboard socket #:location "United States"
                        #:timezone '("Europe" "London")
                        #:keyboard '("English (US)" "English (US)"))
(enter-host-name+passwords socket #:host-name "hello-guix-vm"
                          #:root-password "vm-password"
                          #:users '(("alex" "vm-password")))
(choose-services socket #:choose-network-service? (const #f)
                 #:choose-network-management-tool?
                 (lambda (service) (string-contains service "NetworkManager"))
                 #:choose-misc-service? (const #f))

;; Cancel the review to unmount the destination. Return to the review to mount it again.
(converse socket
  ;; Guix's read-line consumes the newline from the previous reply here.
  ;; Do not send another reply: it would accept the review.
  ((starting-final-step) (values))
  ((file-dialog (title "Configuration file") (text _) (file _)) #f)
  ((list-selection (title "Installation menu") (multiple-choices? #f) (items ,items))
   (begin
     (when (file-exists? "/mnt/etc/config.scm")
       (error "Cancellation left the destination mounted"))
     (display "HELLO-GUIX-REVIEW-CANCEL-PASS\n")
     (last items)))
  ((starting-final-step) (values))
  ((file-dialog (title "Configuration file") (text _) (file ,file))
   (begin
     ;; Add a serial console through the editable configuration, as Guix's VM tests do.
     ;; Keep the hardware adapter and all selected services.
     (let ((forms (call-with-input-file file
                    (lambda (p)
                      (let loop ((forms '()))
                        (let ((form (read p)))
                          (if (eof-object? form) (reverse forms)
                              (loop (cons form forms)))))))))
       (call-with-output-file file
         (lambda (p)
           (for-each
            (lambda (form)
              (pretty-print
               (match form
                 (('with-asahi-hardware ('operating-system fields ...))
                  `(with-asahi-hardware
                    (operating-system
                     ,@(map (match-lambda
                              (('kernel-arguments args)
                               `(kernel-arguments (cons "console=ttyAMA0" ,args)))
                              (field field)) fields))))
                 (_ form)) p)) forms))))
     (when (file-exists? "/mnt/etc/resolv.conf")
       (error "Setup's resolver was copied into the destination"))
     #t))
  ((pause) (values)))
(complete-installation socket)
(when (file-exists? "/mnt/etc/config.scm")
  (error "Completion was reported before the destination was unmounted"))
(display "HELLO-GUIX-INSTALL-PASS\n")
