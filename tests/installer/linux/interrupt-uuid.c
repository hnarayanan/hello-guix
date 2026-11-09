/* SPDX-FileCopyrightText: 2026 Harish Narayanan
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Stop btrfstune in the VM after it writes the first new superblock to disk.
 * Interrupt it before it rewrites the trees or clears CHANGING_FSID. */
#define _GNU_SOURCE
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

ssize_t pwrite64(int fd, const void *data, size_t size, off64_t offset)
{
    ssize_t written = syscall(SYS_pwrite64, fd, data, size, offset);
    if (written == (ssize_t) size && offset == 65536 && size >= 4096
        && memcmp((const char *) data + 64, "_BHRfS_M", 8) == 0) {
        fsync(fd);
        _exit(77);
    }
    return written;
}

ssize_t pwrite(int fd, const void *data, size_t size, off_t offset)
{
    return pwrite64(fd, data, size, offset);
}
