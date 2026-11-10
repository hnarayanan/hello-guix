;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Invoked only by the installation-target VM, with its own FAT partition.

(unless (string-contains
         (call-with-input-file "/proc/cmdline" get-string-all)
         "hello-guix-test=installation-target")
  (error "Boot return fixture requires the disposable target VM"))

(define (read file) (call-with-input-file file get-string-all))
(define (assert description value) (unless value (error description)))
(define active "/boot/efi/m1n1/boot.bin")
(define backup "/boot/efi/m1n1/boot.bin.old")
(define saved "/boot-baseline.bin")

;; The accepted installation can have different bytes from its retained bundle.
(call-with-output-file active (lambda (port) (display "accepted-A" port)))
(copy-file active saved)
(assert "Could not record saved baseline checksum"
        (zero? (with-output-to-file "/boot-return.SHA256SUMS"
                 (lambda () (system* checksum saved)))))
(assert "Saved baseline checksum does not verify"
        (zero? (system* checksum "--check" "/boot-return.SHA256SUMS")))
(call-with-output-file saved (lambda (port) (display "damaged backup" port)))
(assert "Damaged baseline checksum was accepted"
        (not (zero? (system* checksum "--check" "/boot-return.SHA256SUMS"))))
(copy-file active saved)
(assert "Restored baseline checksum does not verify"
        (zero? (system* checksum "--check" "/boot-return.SHA256SUMS")))
(install-b "GRUB-B" "/boot/efi" "/")
(assert "Forward B missing" (string=? "B" (read active)))
(assert "Accepted baseline not preserved on first write"
        (string=? "accepted-A" (read backup)))
(install-b "GRUB-B" "/boot/efi" "/")
(assert "Repeat changed backup" (string=? "accepted-A" (read backup)))
(install-c "GRUB-C" "/boot/efi" "/")
(assert "Forward C missing" (string=? "C" (read active)))
(assert "Previous write is now B" (string=? "B" (read backup)))

;; Native generation selection is tested separately; this exercises the actual
;; one-argument CLI and then exact-byte recovery through its explicit option.
(assert "Retained generation return failed" (zero? (system* restore system-a)))
(assert "Retained generation bytes missing" (string=? "retained-A" (read active)))
(assert "Exact saved return failed"
        (zero? (system* restore "--restore" saved system-a)))
(assert "Exact accepted bytes missing" (string=? "accepted-A" (read active)))
(assert "Retained bundle confused with accepted baseline"
        (string=? "retained-A" (read backup)))
(assert "Exact return repeat failed"
        (zero? (system* restore "--restore" saved system-a)))
(assert "Return repeat replaced backup" (string=? "retained-A" (read backup)))

(define (reject . arguments)
  (assert "Invalid return was accepted"
          (not (zero? (apply system* restore arguments))))
  (assert "Rejected return changed active bytes" (string=? "accepted-A" (read active)))
  (assert "Rejected return changed backup" (string=? "retained-A" (read backup))))
(reject "--restore" saved "/tmp")
(reject "--restore" saved no-kernel)
(reject "--restore" saved empty-kernel)
(reject "--restore" "/missing-baseline" system-a)
(call-with-output-file "/empty-baseline" (lambda (port) #t))
(reject "--restore" "/empty-baseline" system-a)
(symlink saved "/linked-baseline")
(reject "--restore" "/linked-baseline" system-a)
(reject without-bundle)
(assert "Explicit baseline cannot restore a generation without retained bundle"
        (zero? (system* restore "--restore" saved without-bundle)))
(assert "Bundle-less exact return changed bytes" (string=? "accepted-A" (read active)))

(assert "Bundle return unexpectedly replaced the newer GRUB installation"
        (string=? "GRUB-C" (read "/boot/efi/grub-fixture")))

;; Exercise the same real FAT filesystem at a different declared mount point.
(mkdir "/efi")
(assert "Could not move the fixture EFI mount"
        (zero? (system* mount-command "--move" "/boot/efi" "/efi")))
(set! active "/efi/m1n1/boot.bin")
(set! backup "/efi/m1n1/boot.bin.old")
(reject system-a) ; The default path must not discover or fall back to /efi.
(assert "Retained return at alternate mount point failed"
        (zero? (system* restore "--target" "/efi" system-a)))
(assert "Alternate retained bytes missing" (string=? "retained-A" (read active)))
(assert "Exact return at alternate mount point failed"
        (zero? (system* restore "--target" "/efi" "--restore" saved system-a)))
(assert "Alternate exact bytes missing" (string=? "accepted-A" (read active)))
(reject "--target" "/missing-efi" "--restore" saved system-a)
(reject "--target" "efi" "--restore" saved system-a)
(reject "--target" "/" "--restore" saved system-a)
(let ((chosen (getenv "BOOT_TEST_PARTUUID")))
  (setenv "BOOT_TEST_PARTUUID" "wrong-partition")
  (reject "--target" "/efi" "--restore" saved system-a)
  (setenv "BOOT_TEST_PARTUUID" chosen))
(assert "Could not restore the fixture EFI mount"
        (zero? (system* mount-command "--move" "/efi" "/boot/efi")))
(set! active "/boot/efi/m1n1/boot.bin")
(set! backup "/boot/efi/m1n1/boot.bin.old")

(setenv "BOOT_TEST_PARTUUID" "wrong-partition")
(assert "Wrong partition accepted by recovery CLI"
        (not (zero? (system* restore "--restore" saved system-a))))
(assert "Rejected return changed active bytes" (string=? "accepted-A" (read active)))
(assert "Wrong-partition rejection changed backup" (string=? "retained-A" (read backup)))
(display "HELLO-GUIX-BOOT-RETURN-PASS\n")
