// Unit tests for `footprint_fs.c` (plain, -DNDEBUG, ASan+UBSan, TSan).
// Verifies lstat, hardlink dev/ino/nlink, symlink non-following, sorted readdir,
// exists/is_dir, non-blocking FIFO rejection in sfp_head, and monotonic clock.

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "footprint_fs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                            \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "footprint_fs_test FAIL at %s:%d: %s\n", __FILE__,   \
                    __LINE__, #cond);                                            \
            exit(1);                                                             \
        }                                                                        \
    } while (0)

#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>

static void write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "wb");
    REQUIRE(f != NULL);
    size_t len = strlen(content);
    if (len > 0) {
        size_t written = fwrite(content, 1, len, f);
        REQUIRE(written == len);
    }
    int rc = fclose(f);
    REQUIRE(rc == 0);
}

int main(void) {
    char tmpl[] = "/tmp/sfp_fs_test_XXXXXX";
    char *root = mkdtemp(tmpl);
    REQUIRE(root != NULL);

    char p_file[512];
    char p_link[512];
    char p_sym[512];
    char p_sub[512];
    char p_fifo[512];
    char p_fifo_sym[512];
    char p_missing[512];

    snprintf(p_file, sizeof(p_file), "%s/b_file.txt", root);
    snprintf(p_link, sizeof(p_link), "%s/a_hardlink.txt", root);
    snprintf(p_sym, sizeof(p_sym), "%s/c_symlink", root);
    snprintf(p_sub, sizeof(p_sub), "%s/d_subdir", root);
    snprintf(p_fifo, sizeof(p_fifo), "%s/e_fifo", root);
    snprintf(p_fifo_sym, sizeof(p_fifo_sym), "%s/f_fifo_sym", root);
    snprintf(p_missing, sizeof(p_missing), "%s/does_not_exist", root);

    write_file(p_file, "hello footprint\nline2\n");
    int rc_link = link(p_file, p_link);
    REQUIRE(rc_link == 0);
    int rc_sym = symlink(p_file, p_sym);
    REQUIRE(rc_sym == 0);
    int rc_mkdir = mkdir(p_sub, 0755);
    REQUIRE(rc_mkdir == 0);
    int rc_fifo = mkfifo(p_fifo, 0644);
    REQUIRE(rc_fifo == 0);
    int rc_fifo_sym = symlink(p_fifo, p_fifo_sym);
    REQUIRE(rc_fifo_sym == 0);

    // 1. lstat on regular file & hardlink: same (dev, ino), nlink >= 2.
    int64_t st_file[5] = {0};
    int64_t st_link[5] = {0};
    REQUIRE(sfp_lstat(p_file, st_file) == SFP_OK);
    REQUIRE(sfp_lstat(p_link, st_link) == SFP_OK);
    REQUIRE(st_file[0] == SFP_FILE);
    REQUIRE(st_link[0] == SFP_FILE);
    REQUIRE(st_file[1] == st_link[1]);
    REQUIRE(st_file[2] == st_link[2]);
    REQUIRE(st_file[3] >= 2);
    REQUIRE(st_link[3] >= 2);

    // 2. lstat on symlink does not follow target.
    int64_t st_sym[5] = {0};
    REQUIRE(sfp_lstat(p_sym, st_sym) == SFP_OK);
    REQUIRE(st_sym[0] == SFP_LINK);

    // 3. lstat on directory & missing path.
    int64_t st_sub[5] = {0};
    REQUIRE(sfp_lstat(p_sub, st_sub) == SFP_OK);
    REQUIRE(st_sub[0] == SFP_DIR);
    REQUIRE(sfp_lstat(p_missing, st_sub) == SFP_ENOENT);

    // 4. exists & is_dir follow symlinks.
    REQUIRE(sfp_exists(p_file) == 1);
    REQUIRE(sfp_exists(p_sym) == 1);
    REQUIRE(sfp_exists(p_missing) == 0);
    REQUIRE(sfp_is_dir(p_sub) == 1);
    REQUIRE(sfp_is_dir(p_file) == 0);
    REQUIRE(sfp_is_dir(p_missing) == 0);

    // 5. readdir returns sorted NUL-separated names without "." or "..".
    int64_t rlen = 0;
    int32_t rerr = -1;
    char *raw = (char *)sfp_readdir(root, &rlen, &rerr);
    REQUIRE(rerr == SFP_OK);
    REQUIRE(raw != NULL);
    REQUIRE(rlen > 0);
    const char *expected[] = {
        "a_hardlink.txt",
        "b_file.txt",
        "c_symlink",
        "d_subdir",
        "e_fifo",
        "f_fifo_sym",
    };
    int64_t pos = 0;
    for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); i++) {
        REQUIRE(pos < rlen);
        REQUIRE(strcmp(raw + pos, expected[i]) == 0);
        pos += (int64_t)strlen(raw + pos) + 1;
    }
    REQUIRE(pos == rlen);
    sfp_free(raw);

    // readdir on missing path sets SFP_ENOENT.
    rlen = -1;
    rerr = 0;
    REQUIRE(sfp_readdir(p_missing, &rlen, &rerr) == NULL);
    REQUIRE(rerr == SFP_ENOENT);
    REQUIRE(rlen == 0);

    // 6. sfp_head reads regular file and symlink to regular file, and rejects FIFO/dir immediately.
    int64_t hlen = 0;
    int32_t herr = -1;
    char *head = (char *)sfp_head(p_file, 5, &hlen, &herr);
    REQUIRE(herr == 0);
    REQUIRE(hlen == 5);
    REQUIRE(head != NULL && memcmp(head, "hello", 5) == 0);
    sfp_free(head);

    head = (char *)sfp_head(p_sym, 512, &hlen, &herr);
    REQUIRE(herr == 0);
    REQUIRE(hlen == (int64_t)strlen("hello footprint\nline2\n"));
    REQUIRE(head != NULL && memcmp(head, "hello footprint\nline2\n", (size_t)hlen) == 0);
    sfp_free(head);

    // Non-blocking FIFO rejection (no writer attached): must return immediately with herr == 1.
    REQUIRE(sfp_head(p_fifo, 512, &hlen, &herr) == NULL);
    REQUIRE(herr == 1);
    REQUIRE(hlen == 0);
    REQUIRE(sfp_head(p_fifo_sym, 512, &hlen, &herr) == NULL);
    REQUIRE(herr == 1);
    REQUIRE(hlen == 0);
    REQUIRE(sfp_head(p_sub, 512, &hlen, &herr) == NULL);
    REQUIRE(herr == 1);
    REQUIRE(hlen == 0);

    // 7. Monotonic clock returns non-decreasing values.
    int64_t t1 = sfp_now_ms();
    int64_t t2 = sfp_now_ms();
    REQUIRE(t1 > 0);
    REQUIRE(t2 >= t1);
    REQUIRE(sfp_is_windows() == 0);

    // Cleanup.
    unlink(p_fifo_sym);
    unlink(p_fifo);
    rmdir(p_sub);
    unlink(p_sym);
    unlink(p_link);
    unlink(p_file);
    rmdir(root);

    printf("footprint_fs_test ok\n");
    return 0;
}
#else
int main(void) {
    REQUIRE(sfp_is_windows() == 1);
    REQUIRE(sfp_now_ms() >= 0);
    printf("footprint_fs_test ok (win32)\n");
    return 0;
}
#endif
