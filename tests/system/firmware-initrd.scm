;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; No disks, networking, real firmware, activation or installed system.

(use-modules (gnu packages base)
             (gnu packages linux)
             (gnu packages virtualization)
             (gnu system linux-initrd)
             (guix gexp)
             (guix modules)
             (hello-guix system firmware))

(define source
  (computed-file "early-firmware-fixture"
    #~(begin
        (use-modules (rnrs io ports))
        (mkdir #$output)
        (mkdir (string-append #$output "/brcm"))
        (call-with-output-file (string-append #$output "/brcm/fixture.bin")
          (lambda (port) (put-bytevector port #vu8(0 1 2 255)))
          #:binary #t)
        (symlink "fixture.bin" (string-append #$output "/brcm/alias.bin"))
        ;; Distinct hardlink groups must not be conflated by cpio's reset
        ;; inode numbers. The adapter must materialize independent copies.
        (link (string-append #$output "/brcm/fixture.bin")
              (string-append #$output "/brcm/hard.bin"))
        (call-with-output-file (string-append #$output "/brcm/second.bin")
          (lambda (port) (put-bytevector port #vu8(3 4 5 254)))
          #:binary #t)
        (link (string-append #$output "/brcm/second.bin")
              (string-append #$output "/brcm/second-hard.bin")))))

(define initrd
  (expression->initrd
   (with-imported-modules
       (source-module-closure '((gnu build linux-boot) (guix build syscalls)))
     #~(begin
         (use-modules (gnu build linux-boot)
                      (guix build syscalls)
                      (rnrs io ports))
         ;; These reads happen at /init entry, before any mounts, module
         ;; loading, root switch or activation can make firmware available.
         (define success?
           (catch #t
             (lambda ()
               (for-each
                (lambda (name expected)
                  (unless (equal? expected
                                  (call-with-input-file
                                      (string-append "/lib/firmware/brcm/" name)
                                    get-bytevector-all #:binary #t))
                    (error "Early firmware bytes differ" name)))
                '("fixture.bin" "alias.bin" "hard.bin" "second.bin" "second-hard.bin")
                '(#vu8(0 1 2 255) #vu8(0 1 2 255) #vu8(0 1 2 255)
                  #vu8(3 4 5 254) #vu8(3 4 5 254)))
               #t)
             (lambda arguments
               (format #t "Early firmware check failed: ~s~%" arguments)
               #f)))
         (display (if success? "HELLO-GUIX-FIRMWARE-PASS\n"
                      "HELLO-GUIX-FIRMWARE-FAIL\n"))
         (force-output)
         (mount-essential-file-systems)
         (sync)
         (reboot RB_POWER_OFF)))))

(file-union "early-firmware-check"
 `(("kernel" ,(file-append linux-libre "/Image"))
   ("initrd" ,(initrd-with-firmware initrd (apple-silicon-firmware source)))
   ("qemu" ,(file-append qemu-minimal "/bin/qemu-system-aarch64"))
   ("timeout" ,(file-append coreutils "/bin/timeout"))))
