// Unit tests for `carry_fs.c` (plain -Wall -Wextra -Werror, -DNDEBUG, ASan+UBSan, TSan).
// Verifies sfc_open/sfc_write/sfc_close (trunc + append + binary NUL + empty),
// sfc_utimes (sub-second precision), sfc_nlink, sfc_link (0/2 error codes),
// sfc_denied vs sfc_missing (follow=0/1, dangling symlink), sfc_dir_missing, sfc_dir_readable.

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "carry_fs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                          \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "carry_fs_test FAIL at %s:%d: %s\n", __FILE__,     \
                    __LINE__, #cond);                                          \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char tmpl[] = "/tmp/sfc_fs_test_XXXXXX";
    char *root = mkdtemp(tmpl);
    REQUIRE(root != NULL);

    char p_file[512];
    char p_link[512];
    char p_dangling[512];
    char p_sub[512];
    char p_missing[512];
    char p_noaccess_file[512];
    char p_noaccess_dir[512];

    snprintf(p_file, sizeof(p_file), "%s/data.bin", root);
    snprintf(p_link, sizeof(p_link), "%s/data.link", root);
    snprintf(p_dangling, sizeof(p_dangling), "%s/dangling", root);
    snprintf(p_sub, sizeof(p_sub), "%s/sub", root);
    snprintf(p_missing, sizeof(p_missing), "%s/missing", root);
    snprintf(p_noaccess_file, sizeof(p_noaccess_file), "%s/secret.txt", root);
    snprintf(p_noaccess_dir, sizeof(p_noaccess_dir), "%s/secret_dir", root);

    // 1. sfc_open / sfc_write / sfc_close: binary NUL, append, truncate, empty write.
    const uint8_t part1[] = {'A', 0x00, 'B', '\n'};
    const uint8_t part2[] = {'C', 'D'};
    int32_t fd = sfc_open(p_file, 0);
    REQUIRE(fd >= 0);
    REQUIRE(sfc_write(fd, part1, (int64_t)sizeof(part1)) == 0);
    REQUIRE(sfc_write(fd, NULL, 0) == 0);
    REQUIRE(sfc_write(fd, NULL, 4) == -1);
    REQUIRE(sfc_write(fd, part1, -1) == -1);
    REQUIRE(sfc_close(fd) == 0);

    fd = sfc_open(p_file, 1);
    REQUIRE(fd >= 0);
    REQUIRE(sfc_write(fd, part2, (int64_t)sizeof(part2)) == 0);
    REQUIRE(sfc_close(fd) == 0);

    FILE *f = fopen(p_file, "rb");
    REQUIRE(f != NULL);
    uint8_t buf[16] = {0};
    size_t got = fread(buf, 1, sizeof(buf), f);
    REQUIRE(fclose(f) == 0);
    REQUIRE(got == 6);
    REQUIRE(buf[0] == 'A' && buf[1] == 0x00 && buf[2] == 'B' && buf[3] == '\n' && buf[4] == 'C' && buf[5] == 'D');

    // Truncate overwrites.
    fd = sfc_open(p_file, 0);
    REQUIRE(fd >= 0);
    REQUIRE(sfc_write(fd, part2, (int64_t)sizeof(part2)) == 0);
    REQUIRE(sfc_close(fd) == 0);
    struct stat st;
    REQUIRE(lstat(p_file, &st) == 0);
    REQUIRE(st.st_size == 2);

    // 2. sfc_utimes: sub-second precision (both seconds and nanoseconds).
    REQUIRE(sfc_utimes(p_file, 1700000123.456) == 0);
    REQUIRE(lstat(p_file, &st) == 0);
    REQUIRE((int64_t)st.st_mtime == 1700000123LL);
#if defined(__APPLE__)
    long nsec = st.st_mtimespec.tv_nsec;
#else
    long nsec = st.st_mtim.tv_nsec;
#endif
    REQUIRE(nsec >= 455000000L && nsec <= 457000000L);
    REQUIRE(sfc_utimes(p_missing, 1700000000.0) == -1);

    // 3. sfc_nlink and sfc_link (0 on success, 1 on EPERM/EXDEV fallback, 2 on EEXIST and ENOENT).
    REQUIRE(sfc_nlink(p_file) == 1);
    REQUIRE(sfc_nlink(p_missing) == -1);
    REQUIRE(sfc_link(p_file, p_link) == 0);
    REQUIRE(sfc_nlink(p_file) == 2);
    REQUIRE(sfc_nlink(p_link) == 2);
    REQUIRE(sfc_link(p_file, p_link) == 2); // EEXIST must return 2 (never 1)
    REQUIRE(sfc_link(p_missing, p_link) == 2); // ENOENT must return 2

    // 4. sfc_missing (follow=0 vs follow=1 on dangling symlink).
    REQUIRE(symlink(p_missing, p_dangling) == 0);
    REQUIRE(sfc_missing(p_file, 0) == 0);
    REQUIRE(sfc_missing(p_file, 1) == 0);
    REQUIRE(sfc_missing(p_missing, 0) == 1);
    REQUIRE(sfc_missing(p_missing, 1) == 1);
    REQUIRE(sfc_missing(p_dangling, 0) == 0); // link itself exists
    REQUIRE(sfc_missing(p_dangling, 1) == 1); // target is missing

    // 5. sfc_dir_missing, sfc_dir_readable, and deterministic sfc_link == 1 (EPERM on directory hardlink).
    REQUIRE(mkdir(p_sub, 0755) == 0);
    char p_dir_link[512];
    snprintf(p_dir_link, sizeof(p_dir_link), "%s/sub_hardlink", root);
    REQUIRE(sfc_link(p_sub, p_dir_link) == 1); // EPERM on directory hardlink -> fallback-to-copy (1)
    REQUIRE(sfc_dir_missing(p_sub) == 0);
    REQUIRE(sfc_dir_missing(p_missing) == 1);
    REQUIRE(sfc_dir_missing(p_file) == 1); // regular file is ENOTDIR -> missing as dir
    REQUIRE(sfc_dir_readable(p_sub) == 1);
    REQUIRE(sfc_dir_readable(p_missing) == 1);
    REQUIRE(sfc_dir_readable(p_file) == 1);

    // 6. sfc_denied vs sfc_missing on chmod 0000 (skip if running as root).
    fd = sfc_open(p_noaccess_file, 0);
    REQUIRE(fd >= 0);
    REQUIRE(sfc_write(fd, part2, 2) == 0);
    REQUIRE(sfc_close(fd) == 0);
    REQUIRE(mkdir(p_noaccess_dir, 0755) == 0);

    if (geteuid() != 0) {
        REQUIRE(chmod(p_noaccess_file, 0000) == 0);
        REQUIRE(chmod(p_noaccess_dir, 0000) == 0);
        REQUIRE(sfc_denied(p_noaccess_file, 0) == 1);
        REQUIRE(sfc_denied(p_missing, 0) == 0);
        REQUIRE(sfc_denied(p_noaccess_dir, 1) == 1);
        REQUIRE(sfc_denied(p_missing, 1) == 0);
        REQUIRE(sfc_missing(p_noaccess_file, 0) == 0);
        REQUIRE(sfc_dir_missing(p_noaccess_dir) == 0);
        REQUIRE(sfc_dir_readable(p_noaccess_dir) == 0);
        REQUIRE(chmod(p_noaccess_file, 0644) == 0);
        REQUIRE(chmod(p_noaccess_dir, 0755) == 0);
    }

    // 7. sfc_is_file (regular file, symlink to file, dir, symlink to dir, dangling, missing, NULL).
    char p_file_sym[512];
    char p_dir_sym[512];
    snprintf(p_file_sym, sizeof(p_file_sym), "%s/sym_to_file", root);
    snprintf(p_dir_sym, sizeof(p_dir_sym), "%s/sym_to_dir", root);
    REQUIRE(symlink(p_file, p_file_sym) == 0);
    REQUIRE(symlink(p_sub, p_dir_sym) == 0);
    REQUIRE(sfc_is_file(p_file) == 1);
    REQUIRE(sfc_is_file(p_file_sym) == 1);
    REQUIRE(sfc_is_file(p_sub) == 0);
    REQUIRE(sfc_is_file(p_dir_sym) == 0);
    REQUIRE(sfc_is_file(p_dangling) == 0);
    REQUIRE(sfc_is_file(p_missing) == 0);
    REQUIRE(sfc_is_file(NULL) == 0);
    REQUIRE(unlink(p_file_sym) == 0);
    REQUIRE(unlink(p_dir_sym) == 0);

    // 8. sfc_file_stamp & sfc_file_fnv64 (racy-git stamp, 50ms window, FNV-1a vectors, chmod 000, atomic replace).
    {
        uint8_t stamp1[256] = {0};
        uint8_t stamp2[256] = {0};
        uint64_t h = 0;
        REQUIRE(sfc_file_stamp(p_missing, stamp1, (int32_t)sizeof(stamp1)) == 0);
        REQUIRE(sfc_file_stamp(p_sub, stamp1, (int32_t)sizeof(stamp1)) == -1);
        REQUIRE(sfc_file_stamp(NULL, stamp1, (int32_t)sizeof(stamp1)) == -1);
        REQUIRE(sfc_file_stamp(p_file, NULL, 256) == -1);
        REQUIRE(sfc_file_stamp(p_file, stamp1, 4) == -1);

        char p_fnv[512];
        snprintf(p_fnv, sizeof(p_fnv), "%s/fnv.txt", root);
        fd = sfc_open(p_fnv, 0);
        REQUIRE(fd >= 0);
        REQUIRE(sfc_close(fd) == 0);
        REQUIRE(sfc_file_fnv64(p_fnv, &h) == 0);
        REQUIRE(h == 14695981039346656037ULL);

        const uint8_t foobar[] = {'f', 'o', 'o', 'b', 'a', 'r'};
        fd = sfc_open(p_fnv, 0);
        REQUIRE(fd >= 0);
        REQUIRE(sfc_write(fd, foobar, 6) == 0);
        REQUIRE(sfc_close(fd) == 0);
        REQUIRE(sfc_file_fnv64(p_fnv, &h) == 0);
        REQUIRE(h == 0x85944171f73967e8ULL);
        REQUIRE(sfc_file_fnv64(p_missing, &h) == -1);
        REQUIRE(sfc_file_fnv64(NULL, &h) == -1);
        REQUIRE(sfc_file_fnv64(p_fnv, NULL) == -1);

        int32_t rc1 = sfc_file_stamp(p_fnv, stamp1, (int32_t)sizeof(stamp1));
        REQUIRE(rc1 == 1 || rc1 == 2);
        REQUIRE(strlen((const char *)stamp1) > 10);

        // Atomic replace with equal-length content and preserved mtime must change stamp (ino/ctime).
        char p_fnv_tmp[512];
        snprintf(p_fnv_tmp, sizeof(p_fnv_tmp), "%s/fnv.tmp", root);
        const uint8_t foobaz[] = {'f', 'o', 'o', 'b', 'a', 'z'};
        fd = sfc_open(p_fnv_tmp, 0);
        REQUIRE(fd >= 0);
        REQUIRE(sfc_write(fd, foobaz, 6) == 0);
        REQUIRE(sfc_close(fd) == 0);
        REQUIRE(rename(p_fnv_tmp, p_fnv) == 0);
        int32_t rc2 = sfc_file_stamp(p_fnv, stamp2, (int32_t)sizeof(stamp2));
        REQUIRE(rc2 == 1 || rc2 == 2);
        REQUIRE(strcmp((const char *)stamp1, (const char *)stamp2) != 0);

        if (geteuid() != 0) {
            REQUIRE(chmod(p_fnv, 0000) == 0);
            REQUIRE(sfc_file_stamp(p_fnv, stamp1, (int32_t)sizeof(stamp1)) == -1);
            REQUIRE(sfc_file_fnv64(p_fnv, &h) == -1);
            REQUIRE(chmod(p_fnv, 0644) == 0);
        }
        REQUIRE(unlink(p_fnv) == 0);
    }

    // 9. NULL safety.
    REQUIRE(sfc_open(NULL, 0) == -1);
    REQUIRE(sfc_utimes(NULL, 0.0) == -1);
    REQUIRE(sfc_nlink(NULL) == -1);
    REQUIRE(sfc_link(NULL, p_link) == 2);
    REQUIRE(sfc_denied(NULL, 0) == 0);
    REQUIRE(sfc_missing(NULL, 0) == 0);
    REQUIRE(sfc_dir_missing(NULL) == 0);
    REQUIRE(sfc_dir_readable(NULL) == 0);

    // Cleanup.
    REQUIRE(unlink(p_file) == 0);
    REQUIRE(unlink(p_link) == 0);
    REQUIRE(unlink(p_dangling) == 0);
    REQUIRE(unlink(p_noaccess_file) == 0);
    REQUIRE(rmdir(p_sub) == 0);
    REQUIRE(rmdir(p_noaccess_dir) == 0);
    REQUIRE(rmdir(root) == 0);

    printf("carry_fs_test OK\n");
    return 0;
}
#else
int main(void) {
    printf("carry_fs_test skipped on _WIN32\n");
    return 0;
}
#endif
