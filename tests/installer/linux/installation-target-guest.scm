;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run only inside the test VM. These paths refer to its temporary virtual disk.

(use-modules (hello-guix installer linux installation-files)
             (hello-guix installer linux target)
             (guix build utils)
             (guix build syscalls)
             (ice-9 textual-ports)
             (gcrypt hash)
             (gcrypt base16)
             (srfi srfi-1))

(unless (string-contains
         (call-with-input-file "/proc/cmdline" get-string-all)
         "hello-guix-test=installation-target")
  (error "This fixture must be started by check-vm.sh installation-target"))

(catch #t
  (lambda ()
    (define (put path text)
      (mkdir-p (dirname path))
      (call-with-output-file path (lambda (port) (display text port))))
    (define (assert description value)
      (unless value (error description)))
    (define (refused? thunk)
      (catch #t (lambda () (thunk) #f) (lambda _ #t)))
    (define device "/dev/vda2")
    (define efi-device "/dev/vda1")
    (define image-size (* 128 (expt 2 20)))
    (define image-hash #f)
    (define json-command (@@ (hello-guix installer linux target) command-json))
    (define output (@@ (hello-guix installer linux target) command-output))
    (define digest (@@ (hello-guix installer linux target) image-sha256))
    (define* (observe #:key (unique-root? #t))
      (let* ((devices (assoc-ref
                       (json-command (getenv "LSBLK") "--json" "--list" "--paths" "--bytes"
                         "--properties-by" "blkid" "--output"
                         "NAME,TYPE,PKNAME,PTTYPE,PARTTYPE,PARTUUID,FSTYPE,UUID,START,SIZE")
                       "blockdevices"))
             (root (find (lambda (d) (equal? device (assoc-ref d "name"))) (vector->list devices)))
             (efi (find (lambda (d) (equal? efi-device (assoc-ref d "name"))) (vector->list devices)))
             (mounts (vector->list (assoc-ref
                        (json-command (getenv "FINDMNT") "--json" "--list" "--nofsroot" "--canonicalize"
                                      "--output" "TARGET,SOURCE,FSTYPE") "filesystems")))
             (evidence
              `((chosen-efi . ,(assoc-ref efi "partuuid"))
                (loop-backing-file . "/dev/hello-guix/root.squashfs")
                (record . (("layout" . "hello-guix-ram-v1")
                           ("partition_uuid" . ,(assoc-ref efi "partuuid"))
                           ("logical_sector_bytes" . 512)
                           ("start_sector" . ,(assoc-ref efi "start"))
                           ("sector_count" . ,(/ (assoc-ref efi "size") 512))
                           ("root_partition_uuid" . ,(assoc-ref root "partuuid"))
                           ("root_start_bytes" . ,(* 512 (assoc-ref root "start")))
                           ("root_size_bytes" . ,(assoc-ref root "size"))
                           ("root_image" . (("bytes" . ,image-size) ("sha256" . ,image-hash)))))
                (devices . ,devices)
                ;; Simulate only the RAM root. Read device identities,
                ;; partition locations, sizes, and other mounts from the VM.
                (mounts . ,(list->vector
                            (append '((("target" . "/") ("fstype" . "overlay"))
                                      (("target" . "/dev/hello-guix") ("fstype" . "tmpfs")))
                                    (remove (lambda (m) (equal? "/" (assoc-ref m "target"))) mounts)))))))
        (values (validate-target evidence #:unique-root? unique-root?) evidence)))
    (define (inspect) (call-with-values observe (lambda (target _) target)))
    (define (prepare) (prepare-target observe (getenv "BTRFS") (getenv "BTRFSTUNE")))
    (define (copy-image destination)
      (call-with-input-file "/empty.img"
        (lambda (input)
          (let ((out (open-file destination "r+b")))
            (dump-port input out image-size) (force-output out) (fsync out) (close-port out)))))
    (define target #f)
    (define (install thunk)
      (call-with-installation-target target inspect
        (getenv "BTRFS") thunk))
    (define (released?)
      (not (zero? (system* (getenv "FINDMNT") "--mountpoint" "/mnt" "--noheadings"))))

    (let wait ((left 20))
      (unless (file-exists? "/dev/vda")
        (when (zero? left) (error "Missing disposable VM disk"))
        (sleep 1) (wait (1- left))))
    (invoke (getenv "PARTED") "--script" "/dev/vda" "mklabel" "gpt"
            "mkpart" "ESP" "fat32" "1MiB" "257MiB" "set" "1" "esp" "on"
            "mkpart" "target" "btrfs" "257MiB" "9GiB"
            "mkpart" "ESP" "fat32" "9GiB" "9473MiB" "set" "3" "esp" "on"
            "mkpart" "target" "btrfs" "9473MiB" "100%")
    (sleep 1)
    (invoke (getenv "MKFS_FAT") "-F" "32" "/dev/vda1")
    (sleep 1)
    (invoke (getenv "MKFS_FAT") "-F" "32" "/dev/vda3")
    (put "/empty/.hello-guix-empty" "(hello-guix-empty-root 1)\n")
    (put "/empty.img" "")
    (truncate-file "/empty.img" image-size)
    (invoke (getenv "MKFS_BTRFS") "--rootdir" "/empty" "/empty.img")
    (set! image-hash (bytevector->base16-string (file-sha256 "/empty.img")))
    (copy-image "/dev/vda2")
    (copy-image "/dev/vda4")
    (assert "Unprepared clones were accepted" (refused? inspect))
    ;; Even a change outside the filesystem metadata invalidates the template.
    (let ((port (open-file "/dev/vda2" "r+b")))
      (display "changed" port) (close-port port))
    (assert "Changed image was rewritten" (refused? prepare))
    (copy-image "/dev/vda2")
    (setenv "LD_PRELOAD" (getenv "INTERRUPT_UUID"))
    (assert "Interrupted UUID change was hidden" (refused? prepare))
    (unsetenv "LD_PRELOAD")
    (assert "Fault injection did not interrupt a real UUID change"
      (string-contains (output (getenv "BTRFS") "inspect-internal" "dump-super" device)
                       "CHANGING_FSID"))
    (set! target (prepare))
    (let ((before (digest device image-size)))
      (prepare)
      (assert "Repeated preparation rewrote the completed UUID"
        (equal? before (digest device image-size)))
      (set! device "/dev/vda4") (set! efi-device "/dev/vda3")
      (let ((other (prepare)))
        (format #t "First copy: ~a / ~a~%Second copy: ~a / ~a~%"
                (target-root-uuid target) (target-efi-uuid target)
                (target-root-uuid other) (target-efi-uuid other))
        (assert "Root identities still collide"
          (not (equal? (target-root-uuid target) (target-root-uuid other))))
        (assert "EFI identities collide"
          (not (equal? (target-efi-uuid target) (target-efi-uuid other)))))
      (set! device "/dev/vda2") (set! efi-device "/dev/vda1")
      (assert "Preparing the second copy changed the first"
        (equal? before (digest device image-size))))
    (display "HELLO-GUIX-TWO-IDENTITIES-PASS\n")
    ;; A mount can use a symbolic link instead of the device's canonical path.
    ;; Detect it even outside /mnt before the installer prepares the target.
    (mkdir "/alias-mount")
    (symlink efi-device "/dev/hello-guix-efi-alias")
    (mount "/dev/hello-guix-efi-alias" "/alias-mount" "vfat" 0 "iocharset=iso8859-1")
    (assert "EFI mounted through an alias was accepted" (refused? inspect))
    (umount "/alias-mount")
    (display "HELLO-GUIX-MOUNT-ALIAS-PASS\n")
    (mkdir "/mnt")
    (mkdir "/other")
    (mount "/dev/vda4" "/other" "btrfs")
    (mount device "/mnt" "btrfs")
    (put "/mnt/unexpected" "must not overwrite\n")
    (assert "Mounting the first copy exposed it through the second"
      (not (file-exists? "/other/unexpected")))
    (assert "The second copy lost its marker" (file-exists? "/other/.hello-guix-empty"))
    (umount "/mnt")
    (umount "/other")
    (put "/etc/resolv.conf" "# Generated by Connection Manager\nsearch lan\n")
    (put "/var/lib/iwd/Example.psk" "fictional network profile\n")
    (assert "Nonempty target was accepted" (refused? (lambda () (install (const #t)))))
    (assert "Refused target remained mounted" (released?))
    (mount "/dev/vda2" "/mnt" "btrfs")
    (delete-file "/mnt/unexpected")
    (umount "/mnt")
    (assert "Installation failure was swallowed"
      (catch 'simulated-installation-failure
       (lambda ()
         (install
          (lambda ()
            (assert "Setup resolver crossed the boundary"
              (not (file-exists? "/mnt/etc/resolv.conf")))
            (assert "Wi-Fi credentials missing"
              (file-exists? "/mnt/var/lib/iwd/Example.psk"))
            (assert "Wi-Fi credentials not private"
              (= #o600 (stat:perms (stat "/mnt/var/lib/iwd/Example.psk"))))
            (assert "Filesystem did not grow"
              (> (* (file-system-block-size (statfs "/mnt"))
                    (file-system-block-count (statfs "/mnt"))) (* 8 (expt 2 30))))
            (throw 'simulated-installation-failure)))
         #f)
       (lambda _ #t)))
    (assert "Failed installation remained mounted" (released?))
    (assert "Matching interrupted installation could not continue"
      (eq? 'completed
        (install (lambda ()
                   (mkdir-p "/mnt/var/guix/profiles")
                   (symlink "/nonexistent-system-fixture" "/mnt/var/guix/profiles/system")
                   'completed))))
    (assert "Completed target remained mounted" (released?))
    (assert "Existing system was accepted for overwrite"
      (refused? (lambda () (install (const #t)))))
    (assert "Existing system refusal left target mounted" (released?))
    ;; Test the boot updater on this disk's FAT filesystem.
    ;; Include an interrupted update and recovery of the previous bundle.
    (mkdir "/boot-test")
    (mount efi-device "/boot-test" "vfat" 0 "iocharset=iso8859-1")
    (mkdir "/boot-test/files")
    (setenv "BOOT_TEST_DIRECTORY" "/boot-test/files")
    (primitive-load (getenv "BOOT_FILES_TEST"))
    (umount "/boot-test")
    (mount efi-device "/boot-test" "vfat" 0 "iocharset=iso8859-1")
    (assert "Boot publication did not survive remount"
      (and (string=? "candidate" (call-with-input-file "/boot-test/files/boot.bin" get-string-all))
           (string=? "working" (call-with-input-file "/boot-test/files/boot.bin.old" get-string-all))))
    (umount "/boot-test")
    (display "HELLO-GUIX-TARGET-PASS\n"))
  (lambda args
    (write args) (newline) (display "HELLO-GUIX-TARGET-FAIL\n")))
(force-output) (sync) (sleep 1) (reboot RB_POWER_OFF)
