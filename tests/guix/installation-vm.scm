;; SPDX-FileCopyrightText: 2026 Harish Narayanan
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Use the production system and image recipe on a virtual disk with Asahi's layout.
;; Do not access host devices.

(use-modules (gnu packages)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages firmware)
             (gnu packages gnupg)
             (gnu system)
             (guix gexp)
             (guix packages)
             (guix modules))

(define here (dirname (current-filename)))
(define payload
  (primitive-load (string-append here "/../../packaging/guix/packages/setup-install.scm")))
(define image-builder
  (primitive-load (string-append here "/../../packaging/guix/images/ram-image.scm")))
(define setup (operating-system-with-provenance (package-source payload)))
(define image (image-builder 'hello-guix-vm (package-source payload)))
(define (tool package command)
  (file-append (specification->package package) command))

(with-extensions (list guile-json-3 guile-gcrypt)
 (with-imported-modules (source-module-closure '((guix build utils)))
  (computed-file "hello-guix-installation-vm"
    #~(begin
        (use-modules (guix build utils)
                     (json)
                     (ice-9 popen)
                     (gcrypt hash)
                     (gcrypt base16))
        (mkdir-p #$output)
        (chdir #$output)
        (invoke #$(tool "coreutils" "/bin/cp") "--sparse=always" #$image "disk.img")
        (chmod "disk.img" #o600)
        (define root-image
          (let* ((port (open-pipe* OPEN_READ #$(tool "util-linux" "/sbin/sfdisk")
                                  "--json" "disk.img"))
                 (table (assoc-ref (json->scm port) "partitiontable"))
                 (root (vector-ref (assoc-ref table "partitions") 1))
                 (sector (assoc-ref table "sectorsize"))
                 (size (* sector (assoc-ref root "size"))))
            (unless (zero? (close-pipe port)) (error "Cannot read initial root geometry"))
            (call-with-values open-sha256-port
              (lambda (out digest)
                (call-with-input-file "disk.img"
                  (lambda (input)
                    (seek input (* sector (assoc-ref root "start")) SEEK_SET)
                    (dump-port input out size)))
                (close-port out)
                `((bytes . ,size) (sha256 . ,(bytevector->base16-string (digest))))))))
        (truncate-file "disk.img" (* 20 (expt 2 30)))
        (invoke #$(tool "util-linux" "/sbin/sfdisk") "--relocate" "gpt-bak-std" "disk.img")
        (let ((port (open-pipe* OPEN_WRITE #$(tool "util-linux" "/sbin/sfdisk")
                                "--no-reread" "--no-tell-kernel" "-N" "2" "disk.img")))
          (display ",+\n" port)
          (unless (zero? (close-pipe port)) (error "Cannot grow the virtual root")))
        (let* ((port (open-pipe* OPEN_READ #$(tool "util-linux" "/sbin/sfdisk")
                               "--json" "disk.img"))
               (table (assoc-ref (json->scm port) "partitiontable"))
               (parts (assoc-ref table "partitions"))
               (efi (vector-ref parts 0)) (root (vector-ref parts 1))
               (sector (assoc-ref table "sectorsize"))
               (esp (format #f "disk.img@@~a" (* sector (assoc-ref efi "start"))))
               (id (string-downcase (assoc-ref efi "uuid"))))
          (unless (zero? (close-pipe port)) (error "Cannot read virtual partitions"))
          (call-with-output-file "efi-id" (lambda (p) (display id p)))
          (call-with-output-file "target.json"
            (lambda (p)
              (scm->json
               `((layout . "hello-guix-ram-v1") (partition_uuid . ,id)
                 (logical_sector_bytes . ,sector)
                 (start_sector . ,(assoc-ref efi "start"))
                 (sector_count . ,(assoc-ref efi "size"))
                 (root_partition_uuid . ,(string-downcase (assoc-ref root "uuid")))
                 (root_image . ,root-image)
                 (root_start_bytes . ,(* sector (assoc-ref root "start")))
                 (root_size_bytes . ,(* sector (assoc-ref root "size")))) p)))
          ;; QEMU does not need Apple firmware. Use a text file to test firmware
          ;; transfer without including device firmware in the test image.
          (mkdir "vendorfw")
          (call-with-output-file "vendorfw/hello-guix-test"
            (lambda (p) (display "VM firmware fixture\n" p)))
          (utime "vendorfw/hello-guix-test" 1 1)
          (utime "vendorfw" 1 1)
          (let ((port (open-pipe* OPEN_WRITE #$(tool "cpio" "/bin/cpio")
                                 "--reproducible" "-o" "-H" "newc" "-F" "firmware.cpio")))
            (display "vendorfw\nvendorfw/hello-guix-test\n" port)
            (unless (zero? (close-pipe port)) (error "Cannot create firmware fixture")))
          (call-with-output-file "ubootefi.var"
            (lambda (p) (display "HELLO GUIX VM VARIABLES\n" p)))
          (invoke #$(tool "mtools" "/bin/mmd") "-i" esp "::/asahi" "::/vendorfw")
          (for-each
           (lambda (pair)
             (invoke #$(tool "mtools" "/bin/mcopy") "-i" esp (car pair) (cdr pair)))
           '(("target.json" . "::/asahi/guix-boot.json")
             ("firmware.cpio" . "::/vendorfw/firmware.cpio")
             ("ubootefi.var" . "::/ubootefi.var")))
          (invoke #$(tool "mtools" "/bin/mcopy") "-i" esp
                  "::/m1n1/boot.bin" "boot.bin"))
        (with-output-to-file "boot.sha256"
          (lambda ()
            (invoke #$(tool "coreutils" "/bin/sha256sum")
                    "boot.bin" "firmware.cpio" "ubootefi.var")))
        ;; Use qcow2 so Guix does not hash and archive 20 GiB of empty space.
        (invoke #$(tool "qemu-minimal" "/bin/qemu-img") "convert"
                "-f" "raw" "-O" "qcow2" "disk.img" "disk.qcow2")
        (delete-file "disk.img")
        (copy-file #$(file-append setup "/kernel/Image") "linux")
        (copy-file #$(file-append setup "/initrd") "initrd")
        (call-with-output-file "system" (lambda (p) (display #$setup p)))
        (symlink #$(tool "qemu-minimal" "/bin/qemu-system-aarch64") "qemu")
        (symlink #$(tool "dtc" "/bin/fdtput") "fdtput")
        (symlink #$(tool "python" "/bin/python3") "python")
        (symlink #$(file-append ovmf-aarch64 "/share/firmware/ovmf_aarch64.bin") "firmware")
        ;; Supply the test on a second, read-only virtual disk.
        (call-with-output-file "checks.img" (const #t))
        (truncate-file "checks.img" (* 4 (expt 2 20)))
        (invoke #$(tool "dosfstools" "/sbin/mkfs.fat") "--invariant" "checks.img")
        (invoke #$(tool "mtools" "/bin/mcopy") "-m" "-i" "checks.img"
                #$(local-file "installation-ui.scm") "::/install.scm")
        (invoke #$(tool "mtools" "/bin/mcopy") "-m" "-i" "checks.img"
                #$(local-file "installation-boot.sh") "::/boot.sh")
        (invoke #$(tool "mtools" "/bin/mcopy") "-m" "-i" "checks.img"
                #$(local-file "../boot-bundle.sh") "::/boot-bundle.sh")
        (utime "boot.sha256" 1 1)
        (invoke #$(tool "mtools" "/bin/mcopy") "-m" "-i" "checks.img"
                "boot.sha256" "::/boot.sha256")))))
