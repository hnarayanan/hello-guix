;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Check target identification with test data. Do not inspect host devices.

(use-modules (hello-guix installer linux target)
             (srfi srfi-1)
             (srfi srfi-64))

(define (replace-field row key value) (acons key value (alist-delete key row)))
(define test-efi-id "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
(define test-root-id "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
(define test-root-uuid "11111111-2222-4333-8444-555555555555")
(define test-efi-uuid "A1B2-C3D4")
(define test-disk '(("name" . "/dev/nvme0n1") ("type" . "disk") ("pttype" . "gpt")))
(define test-efi
  `(("name" . "/dev/nvme0n1p7") ("type" . "part") ("pkname" . "/dev/nvme0n1")
    ("start" . 2048) ("size" . 536870912)
    ("parttype" . "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
    ("partuuid" . ,test-efi-id) ("fstype" . "vfat") ("uuid" . ,test-efi-uuid)))
(define test-root
  `(("name" . "/dev/nvme0n1p8") ("type" . "part") ("pkname" . "/dev/nvme0n1")
    ("start" . 1050624) ("size" . 17179869184)
    ("parttype" . "0fc63daf-8483-4772-8e79-3d69d8477de4")
    ("partuuid" . ,test-root-id) ("fstype" . "btrfs") ("uuid" . ,test-root-uuid)))
(define test-root-mount
  '(("target" . "/") ("source" . "none") ("fstype" . "overlay") ("fsroot" . "/")
    ("options" . "rw,lowerdir=/real-root,upperdir=/rw-root/upper,workdir=/rw-root/work")))
(define test-ram-mount
  '(("target" . "/dev/hello-guix") ("source" . "tmpfs") ("fstype" . "tmpfs")
    ("fsroot" . "/") ("options" . "rw")))
(define test-record
  `(("layout" . "hello-guix-ram-v1") ("partition_uuid" . ,test-efi-id)
    ("logical_sector_bytes" . 4096) ("start_sector" . 256) ("sector_count" . 131072)
    ("root_partition_uuid" . ,test-root-id)
    ("root_start_bytes" . 537919488) ("root_size_bytes" . 17179869184)))
(define target-test-evidence
  `((chosen-efi . ,test-efi-id) (record . ,test-record)
    (loop-backing-file . "/dev/hello-guix/root.squashfs")
    (devices . ,(vector test-disk test-root test-efi))
    (mounts . ,(vector test-root-mount test-ram-mount))))
(define* (target-evidence #:key (root test-root) (efi test-efi) (disk test-disk)
                         (root-mount test-root-mount) (ram-mount test-ram-mount)
                         (record test-record) (extra-devices '()) (extra-mounts '()))
  (fold (lambda (pair row) (replace-field row (car pair) (cdr pair))) target-test-evidence
        `((record . ,record)
          (devices . ,(list->vector (append (list disk root efi) extra-devices)))
          (mounts . ,(list->vector (append (list root-mount ram-mount) extra-mounts))))))

(test-begin "mac-target")
(define target-runner (test-runner-current))
(define verified-test-target (validate-target target-test-evidence))
(test-assert "RAM setup and its assigned destination are accepted" (target? verified-test-target))
(test-equal "root UUID retained" test-root-uuid (target-root-uuid verified-test-target))
(test-equal "EFI UUID retained" test-efi-uuid (target-efi-uuid verified-test-target))
(test-equal "partition renumbering does not change identities" test-root-uuid
  (target-root-uuid (validate-target
    (target-evidence #:root (replace-field test-root "name" "/dev/nvme0n1p2")
                     #:efi (replace-field test-efi "name" "/dev/nvme0n1p9")))))
(test-equal "case-insensitive chosen UUID" (target->sexp verified-test-target)
  (target->sexp (validate-target
    (replace-field target-test-evidence 'chosen-efi (string-upcase test-efi-id)))))
(test-assert "512-byte logical sectors use the same byte geometry"
  (target? (validate-target
    (target-evidence #:record
      (fold (lambda (pair row) (replace-field row (car pair) (cdr pair))) test-record
            '(("logical_sector_bytes" . 512) ("start_sector" . 2048)
              ("sector_count" . 1048576)))))))

(define other-root
  (fold (lambda (pair row) (replace-field row (car pair) (cdr pair))) test-root
        '(("name" . "/dev/nvme0n1p4") ("start" . 50000000)
          ("partuuid" . "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb")
          ("uuid" . "22222222-3333-4444-8555-666666666666"))))
(test-equal "existing second installation is left alone" (target->sexp verified-test-target)
  (target->sexp (validate-target (target-evidence #:extra-devices (list other-root)))))
(for-each
 (lambda (case) (test-error (car case) 'misc-error (validate-target (cdr case))))
 (list
  (cons "missing chosen identity" (replace-field target-test-evidence 'chosen-efi #f))
  (cons "another boot environment" (replace-field target-test-evidence 'chosen-efi test-root-id))
  (cons "old setup layout" (target-evidence #:record (replace-field test-record "layout" "old")))
  (cons "record refers to another EFI" (target-evidence #:record (replace-field test-record "partition_uuid" test-root-id)))
  (cons "missing target" (target-evidence #:record (replace-field test-record "root_partition_uuid" test-root-uuid)))
  (cons "disk-backed live system" (target-evidence #:root-mount (replace-field test-root-mount "fstype" "btrfs")))
  (cons "image file still on disk" (target-evidence #:ram-mount (replace-field test-ram-mount "fstype" "vfat")))
  (cons "loop uses disk copy" (replace-field target-test-evidence 'loop-backing-file "/boot/efi/hello-guix/root.squashfs"))
  (cons "target mounted elsewhere" (target-evidence #:extra-mounts
    '((("target" . "/elsewhere") ("source" . "/dev/nvme0n1p8")))))
  (cons "EFI still mounted" (target-evidence #:extra-mounts
    '((("target" . "/boot/efi") ("source" . "/dev/nvme0n1p7")))))
  (cons "/mnt occupied" (target-evidence #:extra-mounts
    '((("target" . "/mnt") ("source" . "tmpfs")))))
  (cons "/mnt descendant occupied" (target-evidence #:extra-mounts
    '((("target" . "/mnt/boot") ("source" . "tmpfs")))))
  (cons "mapped target" (target-evidence #:root (replace-field test-root "type" "crypt")))
  (cons "another disk" (target-evidence #:efi (replace-field test-efi "pkname" "/dev/nvme1n1")))
  (cons "non GPT" (target-evidence #:disk (replace-field test-disk "pttype" "dos")))
  (cons "wrong root filesystem" (target-evidence #:root (replace-field test-root "fstype" "ext4")))
  (cons "wrong root partition type" (target-evidence #:root (replace-field test-root "parttype" (assoc-ref test-efi "parttype"))))
  (cons "wrong EFI filesystem" (target-evidence #:efi (replace-field test-efi "fstype" "ext4")))
  (cons "root moved" (target-evidence #:root (replace-field test-root "start" 2000000)))
  (cons "root resized" (target-evidence #:root (replace-field test-root "size" 17000000000)))
  (cons "EFI moved" (target-evidence #:efi (replace-field test-efi "start" 4096)))
  (cons "EFI resized" (target-evidence #:efi (replace-field test-efi "size" 500000000)))
  (cons "bad sector units" (target-evidence #:record (replace-field test-record "logical_sector_bytes" 8192)))
  (cons "missing root UUID" (target-evidence #:root (replace-field test-root "uuid" #f)))
  (cons "missing EFI UUID" (target-evidence #:efi (replace-field test-efi "uuid" #f)))
  (cons "cloned root UUID" (target-evidence #:extra-devices (list (replace-field other-root "uuid" test-root-uuid))))
  (cons "cloned root partition ID" (target-evidence #:extra-devices (list (replace-field other-root "partuuid" test-root-id))))
  (cons "cloned EFI ID" (target-evidence #:extra-devices (list (replace-field other-root "partuuid" test-efi-id))))
  (cons "duplicate device path" (target-evidence #:extra-devices (list test-root)))
  (cons "incomplete metadata on possible clone" (target-evidence #:extra-devices (list (replace-field other-root "uuid" #f))))))
(test-end "mac-target")
(and (zero? (test-runner-fail-count target-runner))
     (zero? (test-runner-xpass-count target-runner)))
