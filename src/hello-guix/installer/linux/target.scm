;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (hello-guix installer linux target)
  #:use-module (gnu system uuid)
  #:use-module (guix build utils)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (validate-target
            inspect-target
            prepare-target
            target?
            target-root
            target-efi
            target-root-uuid
            target-efi-partuuid
            target-efi-uuid
            target->sexp))

;; This record identifies a checked destination. It does not permit writes.
;; Keep the constructor private so callers must use validate-target.
(define-record-type <target>
  (make-target disk root root-partuuid root-uuid efi efi-partuuid efi-uuid)
  target?
  (disk target-disk)
  (root target-root)
  (root-partuuid target-root-partuuid)
  (root-uuid target-root-uuid)
  (efi target-efi)
  (efi-partuuid target-efi-partuuid)
  (efi-uuid target-efi-uuid))

(define (one description items)
  (unless (= 1 (length items))
    (error "Expected exactly one" description (length items)))
  (car items))

(define* (canonical-uuid value #:optional (type 'dce))
  (unless (and (string? value) (string->uuid value type))
    (error "Missing or invalid UUID" value type))
  (uuid->string (string->uuid value type) type))

(define (same-id? a b)
  (and (string? a) (string? b) (string-ci=? a b)))

(define (matching records key value)
  (filter (lambda (record) (equal? value (assoc-ref record key))) records))

(define (unique-id devices key value)
  (one key (filter (lambda (device)
                    (same-id? value (assoc-ref device key)))
                  devices)))

(define* (validate-target evidence #:key (unique-root? #t))
  "Check Asahi's recorded destination using EVIDENCE from inspect-target.
Check that setup runs from RAM and that device identities and byte ranges match.
Do not select a destination by the active root, label, or partition number.

EVIDENCE uses symbol keys. Its JSON objects use string keys. Its device and
mount lists are vectors. This function does not access devices."
  (define (require condition message)
    (unless condition (error message)))
  (let* ((devices (vector->list (assoc-ref evidence 'devices)))
         (mounts (vector->list (assoc-ref evidence 'mounts)))
         (record (assoc-ref evidence 'record))
         (chosen (canonical-uuid (assoc-ref evidence 'chosen-efi)))
         (root (unique-id devices "partuuid"
                          (canonical-uuid (assoc-ref record "root_partition_uuid"))))
         (efi (unique-id devices "partuuid" chosen))
         (disk-name (assoc-ref root "pkname"))
         (disk (one "parent disk" (matching devices "name" disk-name)))
         (live (one "live root" (matching mounts "target" "/")))
         (ram (one "RAM image storage" (matching mounts "target" "/dev/hello-guix"))))
    (require (equal? "hello-guix-ram-v1" (assoc-ref record "layout"))
             "The destination record has an unsupported layout")
    (require (same-id? chosen (assoc-ref record "partition_uuid"))
             "The destination record refers to another EFI partition")
    (require (equal? "overlay" (assoc-ref live "fstype"))
             "The running root is not the RAM installer's overlay")
    (require (equal? "tmpfs" (assoc-ref ram "fstype"))
             "The setup image is not stored in RAM")
    (require (equal? "/dev/hello-guix/root.squashfs" (assoc-ref evidence 'loop-backing-file))
             "The loop device is not using the RAM copy of the setup image")
    (require (= (length devices)
                (length (delete-duplicates (map (lambda (d) (assoc-ref d "name")) devices))))
             "Device inventory contains duplicate paths")
    (require (and (equal? "disk" (assoc-ref disk "type"))
                  (equal? "gpt" (assoc-ref disk "pttype")))
             "The destination is not on a GPT disk")
    (require (and (equal? "part" (assoc-ref root "type"))
                  (equal? "part" (assoc-ref efi "type")))
             "The destination root and EFI must be ordinary disk partitions")
    (require (equal? disk-name (assoc-ref efi "pkname"))
             "The destination root and EFI are on different disks")
    (require (equal? "btrfs" (assoc-ref root "fstype")) "The destination root is not Btrfs")
    (require (equal? "vfat" (assoc-ref efi "fstype")) "The destination EFI is not FAT")
    (require (same-id? "0fc63daf-8483-4772-8e79-3d69d8477de4" (assoc-ref root "parttype"))
             "The destination root has the wrong GPT partition type")
    (require (same-id? "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" (assoc-ref efi "parttype"))
             "The destination EFI has the wrong GPT partition type")
    (let ((sector (assoc-ref record "logical_sector_bytes")))
      (require (member sector '(512 4096)) "The recorded disk sector size is unsupported")
      ;; lsblk START is in 512-byte kernel sectors, including on Apple's disks.
      (require (= (* 512 (assoc-ref root "start")) (assoc-ref record "root_start_bytes"))
               "The destination root has moved since macOS preparation")
      (require (= (assoc-ref root "size") (assoc-ref record "root_size_bytes"))
               "The destination root has changed size since macOS preparation")
      (require (= (* 512 (assoc-ref efi "start")) (* sector (assoc-ref record "start_sector")))
               "The destination EFI has moved since macOS preparation")
      (require (= (assoc-ref efi "size") (* sector (assoc-ref record "sector_count")))
               "The destination EFI has changed size since macOS preparation")
      (require (>= (assoc-ref root "size") (* 8 (expt 2 30)))
               "The destination root is smaller than 8 GiB"))
    (for-each
     (lambda (mount)
       (when (or (member (assoc-ref mount "source")
                         (list (assoc-ref root "name") (assoc-ref efi "name")))
                 (equal? "/mnt" (assoc-ref mount "target"))
                 (string-prefix? "/mnt/" (assoc-ref mount "target")))
         (error "The installation target is already mounted")))
     mounts)
    (let ((root-uuid (canonical-uuid (assoc-ref root "uuid") 'btrfs))
          (efi-uuid (canonical-uuid (assoc-ref efi "uuid") 'fat32))
          (root-partuuid (canonical-uuid (assoc-ref root "partuuid"))))
      ;; Missing metadata on another Linux or EFI partition could hide a
      ;; duplicate filesystem UUID. Require enough data to check for duplicates.
      (for-each
       (lambda (device)
         (when (any (lambda (type) (same-id? type (assoc-ref device "parttype")))
                    '("0fc63daf-8483-4772-8e79-3d69d8477de4"
                      "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"))
           (unless (and (string? (assoc-ref device "uuid"))
                        (string? (assoc-ref device "fstype")))
             (error "Incomplete filesystem metadata" (assoc-ref device "name")))))
       devices)
      ;; Copies of the empty root image share a filesystem UUID before preparation.
      ;; The GPT partition UUIDs and the EFI filesystem UUID must be unique.
      (when unique-root? (unique-id devices "uuid" root-uuid))
      (unique-id devices "uuid" efi-uuid)
      (make-target disk-name (assoc-ref root "name") root-partuuid root-uuid
                   (assoc-ref efi "name") chosen efi-uuid))))

(define (target->sexp target)
  `((disk . ,(target-disk target))
    (root (device . ,(target-root target))
          (partuuid . ,(target-root-partuuid target))
          (uuid . ,(target-root-uuid target)))
    (efi (device . ,(target-efi target))
         (partuuid . ,(target-efi-partuuid target))
         (uuid . ,(target-efi-uuid target)))))

(define (command-output command . arguments)
  (let* ((port (apply open-pipe* OPEN_READ command arguments))
         (text (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? status)
      (error "Read-only inspection command failed" command arguments status))
    text))

(define (command-json command . arguments)
  (json-string->scm (apply command-output command arguments)))

(define (image-sha256 file size)
  (call-with-values open-sha256-port
    (lambda (output digest)
      (dynamic-wind
        (const #t)
        (lambda ()
          (call-with-input-file file (lambda (input) (dump-port input output size))))
        (lambda () (close-port output)))
      (bytevector->base16-string (digest)))))

(define (prepare-target inspect btrfs btrfstune)
  "Give only the verified empty image its partition's unique UUID.
INSPECT accepts #:unique-root? and returns the target and its evidence.
Btrfs records interrupted UUID changes itself; no separate journal is needed."
  (unless (zero? (geteuid)) (error "Root preparation requires the RAM installer"))
  (call-with-values (lambda () (inspect #:unique-root? #f))
    (lambda (target evidence)
      (let* ((device (target-root target))
             (uuid (target-root-partuuid target))
             (record (assoc-ref evidence 'record))
             (image (assoc-ref record "root_image"))
             (size (assoc-ref image "bytes"))
             (super (command-output btrfs "inspect-internal" "dump-super" device))
             (changing? (string-contains super "CHANGING_FSID")))
        (unless (and (integer? size) (positive? size)
                     (<= size (assoc-ref record "root_size_bytes"))
                     (string? (assoc-ref image "sha256")))
          (error "Missing empty root image record"))
        (unless (and (same-id? uuid (target-root-uuid target)) (not changing?))
          ;; Change the UUID only if the bytes match the empty image.
          ;; To continue an interrupted change, require the expected GPT UUID.
          (unless (or (and changing? (same-id? uuid (target-root-uuid target)))
                      (and (not changing?)
                           (equal? (assoc-ref image "sha256") (image-sha256 device size))))
            (error "The destination is neither the empty image nor its interrupted UUID change"))
          (when (any (lambda (d) (same-id? uuid (assoc-ref d "uuid")))
                     (filter (lambda (d) (not (equal? device (assoc-ref d "name"))))
                             (vector->list (assoc-ref evidence 'devices))))
            (error "The destination UUID is already in use" uuid))
          (call-with-values (lambda () (inspect #:unique-root? #f))
            (lambda (_ again)
              (unless (equal? evidence again) (error "The prepared target changed"))))
          (invoke btrfs "device" "scan" "--forget" device)
          ;; -U checks for duplicate UUIDs, even during recovery.
          ;; -u continues the change recorded by CHANGING_FSID. Use it only
          ;; after the recorded UUID matches the expected UUID.
          (if changing?
              (invoke btrfstune "-f" "-u" device)
              (invoke btrfstune "-f" "-U" uuid device)))
        ;; Read the new filesystem UUID from disk. The udev cache can be out of date.
        (call-with-values inspect
          (lambda (prepared _)
            (unless (same-id? uuid (target-root-uuid prepared))
              (error "Root UUID preparation did not complete"))
            prepared))))))

(define* (inspect-target #:key (lsblk "lsblk") (findmnt "findmnt") (unique-root? #t))
  "Read the device and mount data twice. Reject any changes between the readings.
Return two values: the validated target and the data used to identify it."
  (define (text-file name)
    (string-trim-both (call-with-input-file name get-string-all)))
  (define (collect)
    `((chosen-efi . ,(string-trim-right
                      (text-file "/proc/device-tree/chosen/asahi,efi-system-partition") #\nul))
      (record . ,(json-string->scm (text-file "/dev/hello-guix/target.json")))
      (loop-backing-file . ,(text-file "/sys/class/block/loop0/loop/backing_file"))
      (devices . ,(assoc-ref
                   (command-json lsblk "--json" "--list" "--paths" "--bytes"
                     "--properties-by" "blkid" "--output"
                     "NAME,TYPE,PKNAME,PTTYPE,PARTTYPE,PARTUUID,FSTYPE,UUID,START,SIZE")
                   "blockdevices"))
      (mounts . ,(assoc-ref
                  (command-json findmnt "--json" "--list" "--nofsroot" "--canonicalize" "--output"
                                "TARGET,SOURCE,FSTYPE,FSROOT,OPTIONS")
                  "filesystems"))))
  (let* ((before (collect))
         (target (validate-target before #:unique-root? unique-root?)) (after (collect)))
    (unless (equal? before after)
      (error "Mounts or device identities changed during inspection; retry"))
    (values target before)))
