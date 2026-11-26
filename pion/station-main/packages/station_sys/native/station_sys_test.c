// Comprehensive C11 unit & concurrency test suite for `station_sys.c` linked with `station_host.c`.
// Verified under -Wall -Wextra -Werror, -fsanitize=address,undefined, and -fsanitize=thread.
// Checks strict zero-leak of open fds (`sth_open_fd_count`) and threads (`sth_open_thread_count`).

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include "station_sys.h"
#include "../../../../station/packages/host_shim/native/station_host.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// Minimal stubs for `libstillfail_shell.a` symbols referenced by `station_host.c`.
typedef void (*sf_complete)(
    void *ctx,
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes);

void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx) {
    (void)data_dir;
    (void)complete;
    (void)ctx;
    return NULL;
}
void sf_shell_stop(void *shell) { (void)shell; }
void sf_shell_call(
    const void *shell, uint64_t id, const char *op,
    const uint8_t *json, size_t json_len,
    const uint8_t *bytes, size_t bytes_len, uint8_t has_bytes) {
    (void)shell; (void)id; (void)op; (void)json; (void)json_len;
    (void)bytes; (void)bytes_len; (void)has_bytes;
}
uint8_t *sf_shell_call_sync(
    const void *shell, const char *op, const uint8_t *json, size_t json_len, size_t *out_len) {
    (void)shell; (void)op; (void)json; (void)json_len;
    if (out_len) *out_len = 0;
    return NULL;
}
void sf_free(uint8_t *ptr, size_t len) {
    (void)len;
    free(ptr);
}

static uint64_t read_u64_le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)p[i]) << (8 * i);
    return v;
}

static int32_t read_i32_le(const uint8_t *p) {
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    return (int32_t)v;
}

static uint16_t read_u16_le(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void drain_queue(void) {
    for (;;) {
        int64_t len = 0;
        void *ev = sth_wait(0, &len);
        if (ev == NULL) break;
        sth_free(ev);
    }
}

static int contains_substr(const char *hay, size_t hay_len, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || hay == NULL || hay_len < nlen) return 0;
    for (size_t i = 0; i + nlen <= hay_len; i++) {
        if (memcmp(hay + i, needle, nlen) == 0) return 1;
    }
    return 0;
}

static void make_temp_dir(char *out, size_t cap) {
    snprintf(out, cap, "/tmp/sts_test_%d_XXXXXX", (int)getpid());
    char *r = mkdtemp(out);
    assert(r != NULL);
}

static void write_file_str(const char *path, const char *s) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    assert(fd >= 0);
    size_t n = strlen(s);
    if (n > 0) {
        ssize_t w = write(fd, s, n);
        assert(w == (ssize_t)n);
    }
    close(fd);
}

// ---------------------------------------------------------------------------
// 1. Non-recursive fs.watch test
// ---------------------------------------------------------------------------

static int wait_for_fs_name(uint64_t event_id, const char *needle) {
    int64_t deadline = sth_now_ms() + 5000;
    while (sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        int matched = 0;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == event_id && len >= 11 && ev[9] == STS_EV_FS_CHANGE) {
            if (contains_substr((const char *)(ev + 11), (size_t)(len - 11), needle)) {
                matched = 1;
            }
        }
        sth_free(ev);
        if (matched) return 1;
    }
    return 0;
}

static void test_fs_watch_non_recursive(void) {
    drain_queue();
    char dir[128];
    make_temp_dir(dir, sizeof(dir));
    char sub[256];
    snprintf(sub, sizeof(sub), "%s/sub", dir);
    assert(mkdir(sub, 0755) == 0);

    int64_t h = sts_fs_watch_open(101, dir);
    assert(h > 0);

    // Create, rename, and delete a direct child in `dir` (step-by-step so coalesced kqueue sees each).
    char f1[256], f2[256];
    snprintf(f1, sizeof(f1), "%s/alpha.txt", dir);
    snprintf(f2, sizeof(f2), "%s/beta.txt", dir);
    write_file_str(f1, "hello");
    assert(wait_for_fs_name(101, "alpha.txt") == 1);

    assert(rename(f1, f2) == 0);
    assert(wait_for_fs_name(101, "beta.txt") == 1);

    assert(unlink(f2) == 0);
    assert(wait_for_fs_name(101, "beta.txt") == 1);
    drain_queue();

    // Deep change inside `sub/deep.txt` MUST NOT trigger non-recursive watcher on `dir`.
    char deep[512];
    snprintf(deep, sizeof(deep), "%s/deep.txt", sub);
    write_file_str(deep, "nested");
    assert(unlink(deep) == 0);

    int64_t len = 0;
    uint8_t *ev = (uint8_t *)sth_wait(150, &len);
    while (ev != NULL) {
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 101 && len >= 11 && ev[9] == STS_EV_FS_CHANGE) {
            assert(!contains_substr((const char *)(ev + 11), (size_t)(len - 11), "deep.txt"));
        }
        sth_free(ev);
        ev = (uint8_t *)sth_wait(0, &len);
    }

    assert(sts_fs_watch_close(h) == 1);
    assert(sts_fs_watch_close(h) == 0); // double close safely rejected
    drain_queue();

    assert(rmdir(sub) == 0);
    assert(rmdir(dir) == 0);
    printf("  [PASS] fs.watch (non-recursive + close)\n");
}

static int wait_for_fs_event(uint64_t event_id, uint8_t want_kind, const char *needle) {
    int64_t deadline = sth_now_ms() + 5000;
    while (sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        int matched = 0;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == event_id && len >= 11 && ev[9] == STS_EV_FS_CHANGE) {
            if (ev[10] == want_kind && contains_substr((const char *)(ev + 11), (size_t)(len - 11), needle)) {
                matched = 1;
            }
        }
        sth_free(ev);
        if (matched) return 1;
    }
    return 0;
}

static void test_fs_watch_single_file(void) {
    drain_queue();
    char dir[128], fpath[256], fmoved[256];
    make_temp_dir(dir, sizeof(dir));
    snprintf(fpath, sizeof(fpath), "%s/events.log", dir);
    snprintf(fmoved, sizeof(fmoved), "%s/events.log.old", dir);
    write_file_str(fpath, "line1\n");

    int64_t h = sts_fs_watch_open(102, fpath);
    assert(h > 0);

    // Append in-place -> must emit STS_FS_CHANGE with basename "events.log".
    int fd = open(fpath, O_WRONLY | O_APPEND);
    assert(fd >= 0);
    assert(write(fd, "line2\n", 6) == 6);
    close(fd);
    assert(wait_for_fs_event(102, STS_FS_CHANGE, "events.log") == 1);
    drain_queue();

    // Rename/move away -> must emit STS_FS_RENAME with basename "events.log".
    assert(rename(fpath, fmoved) == 0);
    assert(wait_for_fs_event(102, STS_FS_RENAME, "events.log") == 1);

    assert(sts_fs_watch_close(h) == 1);
    drain_queue();
    assert(unlink(fmoved) == 0);
    assert(rmdir(dir) == 0);
    printf("  [PASS] fs.watch (single-file append + rename + close)\n");
}

// ---------------------------------------------------------------------------
// 2. Async child process tests
// ---------------------------------------------------------------------------

static void test_proc_pipes_exit_and_env_strip(void) {
    drain_queue();
    // Set MallocSpaceEfficient in parent env and verify STS_PROC_STRIP_MALLOC_SE strips it.
    assert(sts_env_set("MallocSpaceEfficient", "1") == 1);
    assert(sts_env_set("STS_TEST_KEEP", "yes42") == 1);

    const char *script =
        "read line; "
        "echo \"OUT:$line:${MallocSpaceEfficient:-STRIPPED}:$STS_TEST_KEEP\"; "
        "echo \"ERR:$line\" >&2; "
        "exit 7";
    // NUL-separated args: "-c\0<script>\0"
    size_t slen = strlen(script);
    size_t alen = 3 + slen + 1;
    uint8_t *args = (uint8_t *)malloc(alen);
    assert(args != NULL);
    memcpy(args, "-c", 3);
    memcpy(args + 3, script, slen + 1);

    int64_t pid = 0;
    char err[256] = "";
    int64_t h = sts_proc_spawn(
        201,
        "/bin/sh",
        args, (int64_t)alen,
        NULL, 0,
        NULL,
        STS_PROC_NEW_PGID | STS_PROC_STRIP_MALLOC_SE | STS_PROC_PIPE_STDIN | STS_PROC_PIPE_STDOUT | STS_PROC_PIPE_STDERR,
        &pid,
        err, sizeof(err));
    free(args);
    assert(h > 0 && pid > 0);

    // Check start_time_of(pid).
    int64_t st_ms = sts_proc_start_time_ms((int32_t)pid);
    assert(st_ms > 1700000000000LL);

    // Write stdin and close stdin to trigger child read + exit.
    const char *msg = "ping99\n";
    assert(sts_proc_write_stdin(h, (const uint8_t *)msg, (int64_t)strlen(msg)) == 1);
    assert(sts_proc_close_stdin(h) == 1);

    char out_buf[512] = "";
    size_t out_len = 0;
    char err_buf[512] = "";
    size_t err_len = 0;
    int got_out_eof = 0, got_err_eof = 0, got_exit = 0;
    int32_t exit_code = -999;

    int64_t deadline = sth_now_ms() + 5000;
    while ((!got_out_eof || !got_err_eof || !got_exit) && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 201 && len >= 10) {
            uint8_t tag = ev[9];
            if (tag == STS_EV_PROC_STDOUT) {
                size_t n = (size_t)(len - 10);
                if (out_len + n < sizeof(out_buf)) {
                    memcpy(out_buf + out_len, ev + 10, n);
                    out_len += n;
                    out_buf[out_len] = '\0';
                }
            } else if (tag == STS_EV_PROC_STDERR) {
                size_t n = (size_t)(len - 10);
                if (err_len + n < sizeof(err_buf)) {
                    memcpy(err_buf + err_len, ev + 10, n);
                    err_len += n;
                    err_buf[err_len] = '\0';
                }
            } else if (tag == STS_EV_PROC_STDOUT_EOF) {
                got_out_eof = 1;
            } else if (tag == STS_EV_PROC_STDERR_EOF) {
                got_err_eof = 1;
            } else if (tag == STS_EV_PROC_EXIT) {
                assert(len >= 18);
                exit_code = read_i32_le(ev + 10);
                got_exit = 1;
            }
        }
        sth_free(ev);
    }
    assert(got_out_eof && got_err_eof && got_exit);
    assert(exit_code == 7);
    assert(contains_substr(out_buf, out_len, "OUT:ping99:STRIPPED:yes42"));
    assert(contains_substr(err_buf, err_len, "ERR:ping99"));

    assert(sts_proc_close(h) == 1);
    assert(sts_env_unset("MallocSpaceEfficient") == 1);
    assert(sts_env_unset("STS_TEST_KEEP") == 1);
    drain_queue();

    // Test process group kill + signal exit reporting.
    const char *sleep_script = "sleep 30";
    size_t sslen = strlen(sleep_script);
    uint8_t *sargs = (uint8_t *)malloc(3 + sslen + 1);
    memcpy(sargs, "-c", 3);
    memcpy(sargs + 3, sleep_script, sslen + 1);
    int64_t spid = 0;
    int64_t sh = sts_proc_spawn(
        202, "/bin/sh", sargs, (int64_t)(3 + sslen + 1), NULL, 0, NULL,
        STS_PROC_NEW_PGID | STS_PROC_PIPE_STDOUT, &spid, err, sizeof(err));
    free(sargs);
    assert(sh > 0 && spid > 0);
    assert(sts_proc_kill((int32_t)spid, STS_SIG_KILL, 1) == 0);

    int got_sig_exit = 0;
    int32_t term_sig = 0;
    deadline = sth_now_ms() + 5000;
    while (!got_sig_exit && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 202 && len >= 18 && ev[9] == STS_EV_PROC_EXIT) {
            assert(read_i32_le(ev + 10) == -1);
            term_sig = read_i32_le(ev + 14);
            got_sig_exit = 1;
        }
        sth_free(ev);
    }
    assert(got_sig_exit && term_sig == SIGKILL);
    assert(sts_proc_close(sh) == 1);
    drain_queue();
    printf("  [PASS] async proc (pipes, pgid kill, exit/sig, start_time_of, MallocSpaceEfficient strip)\n");
}

// ---------------------------------------------------------------------------
// 3. Control channel test (socketpair bidirectional line framing + EOF + close)
// ---------------------------------------------------------------------------

static void test_ctrl_channel(void) {
    drain_queue();
    int sv[2] = { -1, -1 };
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);

    int64_t h = sts_ctrl_open_fd(301, sv[0]);
    assert(h > 0);

    // Write from station -> peer.
    const char *out_msg = "{\"ready\":true}\n";
    assert(sts_ctrl_write(h, (const uint8_t *)out_msg, (int64_t)strlen(out_msg)) == 1);
    char peer_buf[64] = "";
    ssize_t pn = read(sv[1], peer_buf, sizeof(peer_buf) - 1);
    assert(pn == (ssize_t)strlen(out_msg));
    assert(memcmp(peer_buf, out_msg, (size_t)pn) == 0);

    // Send 2 lines (one LF, one CRLF) + partial tail from peer -> station, then close peer.
    const char *in_msg = "{\"op\":\"ping\"}\n{\"op\":\"renew\"}\r\ntail";
    assert(write(sv[1], in_msg, strlen(in_msg)) == (ssize_t)strlen(in_msg));
    close(sv[1]);

    int lines = 0, saw_eof = 0;
    char l0[64] = "", l1[64] = "", l2[64] = "";
    int64_t deadline = sth_now_ms() + 5000;
    while (!saw_eof && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 301 && len >= 10) {
            if (ev[9] == STS_EV_CTRL_LINE) {
                size_t n = (size_t)(len - 10);
                if (lines == 0 && n < sizeof(l0)) { memcpy(l0, ev + 10, n); l0[n] = '\0'; }
                else if (lines == 1 && n < sizeof(l1)) { memcpy(l1, ev + 10, n); l1[n] = '\0'; }
                else if (lines == 2 && n < sizeof(l2)) { memcpy(l2, ev + 10, n); l2[n] = '\0'; }
                lines += 1;
            } else if (ev[9] == STS_EV_CTRL_EOF) {
                saw_eof = 1;
            }
        }
        sth_free(ev);
    }
    assert(saw_eof && lines == 3);
    assert(strcmp(l0, "{\"op\":\"ping\"}") == 0);
    assert(strcmp(l1, "{\"op\":\"renew\"}") == 0);
    assert(strcmp(l2, "tail") == 0);

    assert(sts_ctrl_close(h) == 1);
    drain_queue();

    // Also test closing while peer is still open (wakeup on blocked poll).
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    int64_t h2 = sts_ctrl_open_fd(302, sv[0]);
    assert(h2 > 0);
    assert(sts_ctrl_close(h2) == 1);
    close(sv[1]);
    drain_queue();

    // Test writing to a closed peer returns 0 and does NOT kill process with SIGPIPE.
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    int64_t h3 = sts_ctrl_open_fd(303, sv[0]);
    assert(h3 > 0);
    close(sv[1]);
    int saw_eof3 = 0;
    deadline = sth_now_ms() + 5000;
    while (!saw_eof3 && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 303 && len >= 10 && ev[9] == STS_EV_CTRL_EOF) {
            saw_eof3 = 1;
        }
        sth_free(ev);
    }
    assert(saw_eof3 == 1);
    const char *dead_msg = "after-close\n";
    assert(sts_ctrl_write(h3, (const uint8_t *)dead_msg, (int64_t)strlen(dead_msg)) == 0);
    assert(sts_ctrl_close(h3) == 1);
    drain_queue();
    printf("  [PASS] ctrl channel (line framing + EOF + close wakeup + SIGPIPE-safe closed write)\n");
}

// ---------------------------------------------------------------------------
// 4. Process signals (SIGUSR2 + SIGHUP + unwatch)
// ---------------------------------------------------------------------------

static void test_signals(void) {
    drain_queue();
    assert(sts_signal_watch(401) == 1);
    assert(raise(SIGUSR2) == 0);
    assert(raise(SIGHUP) == 0);

    int saw_usr2 = 0, saw_hup = 0;
    int64_t deadline = sth_now_ms() + 5000;
    while ((!saw_usr2 || !saw_hup) && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 401 && len >= 14 && ev[9] == STS_EV_SIGNAL) {
            int32_t s = read_i32_le(ev + 10);
            if (s == SIGUSR2 && contains_substr((const char *)(ev + 14), (size_t)(len - 14), "SIGUSR2")) saw_usr2 = 1;
            if (s == SIGHUP && contains_substr((const char *)(ev + 14), (size_t)(len - 14), "SIGHUP")) saw_hup = 1;
        }
        sth_free(ev);
    }
    assert(saw_usr2 && saw_hup);
    assert(sts_signal_unwatch() == 1);
    drain_queue();
    printf("  [PASS] signals (SIGUSR2, SIGHUP, unwatch)\n");
}

// ---------------------------------------------------------------------------
// 5. Advisory file lock (flock_try / flock_unlock)
// ---------------------------------------------------------------------------

static void test_flock(void) {
    char dir[128], lock_path[256];
    make_temp_dir(dir, sizeof(dir));
    snprintf(lock_path, sizeof(lock_path), "%s/test.lock", dir);

    int64_t h1 = sts_flock_try(lock_path);
    assert(h1 > 0);
    // Second handle on same file must fail with 0 (contended).
    int64_t h2 = sts_flock_try(lock_path);
    assert(h2 == 0);

    assert(sts_flock_unlock(h1) == 1);
    assert(sts_flock_unlock(h1) == 0); // double unlock rejected

    int64_t h3 = sts_flock_try(lock_path);
    assert(h3 > 0);
    assert(sts_flock_unlock(h3) == 1);

    assert(unlink(lock_path) == 0);
    assert(rmdir(dir) == 0);
    printf("  [PASS] flock (try/contention/unlock/reacquire)\n");
}

// ---------------------------------------------------------------------------
// 6. Unix peer_process
// ---------------------------------------------------------------------------

static void test_peer_process(void) {
    int sv[2] = { -1, -1 };
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    int64_t len = 0;
    char *json = (char *)sts_peer_process(sv[0], &len);
    assert(json != NULL && len > 0);
    char expected[64];
    snprintf(expected, sizeof(expected), "\"pid\":%d", (int)getpid());
    assert(contains_substr(json, (size_t)len, expected));
    sts_free(json);
    close(sv[0]);
    close(sv[1]);
    printf("  [PASS] peer_process (AF_UNIX socketpair -> self pid)\n");
}

// ---------------------------------------------------------------------------
// 7. process_usage
// ---------------------------------------------------------------------------

static void test_process_usage(void) {
    int32_t pids[2] = { (int32_t)getpid(), 99999999 };
    int64_t len = 0;
    char *json = (char *)sts_process_usage(pids, 2, &len);
    assert(json != NULL && len > 0);
    assert(contains_substr(json, (size_t)len, "\"cpuNs\":"));
    assert(contains_substr(json, (size_t)len, "\"footprint\":"));
    assert(!contains_substr(json, (size_t)len, "\"footprint\":0,"));
    assert(contains_substr(json, (size_t)len, ",null]"));
    sts_free(json);
    printf("  [PASS] process_usage (self footprint > 0 + missing pid null)\n");
}

// ---------------------------------------------------------------------------
// 8. PTY echo + resize + exit
// ---------------------------------------------------------------------------

static void test_pty(void) {
    drain_queue();
    const char *script = "read line; echo \"PTY:$line\"; exit 0";
    size_t slen = strlen(script);
    uint8_t *args = (uint8_t *)malloc(3 + slen + 1);
    memcpy(args, "-c", 3);
    memcpy(args + 3, script, slen + 1);

    int64_t pid = 0;
    char err[256] = "";
    int64_t h = sts_pty_spawn(
        501, "/bin/sh", args, (int64_t)(3 + slen + 1), NULL, 0, NULL,
        80, 24, 0, &pid, err, sizeof(err));
    free(args);
    assert(h > 0 && pid > 0);

    assert(sts_pty_resize(h, 120, 40) == 1);
    const char *input = "hello_pty\n";
    assert(sts_pty_write(h, (const uint8_t *)input, (int64_t)strlen(input)) == 1);

    char out[1024] = "";
    size_t out_len = 0;
    int got_exit = 0;
    int32_t code = -1;
    int64_t deadline = sth_now_ms() + 5000;
    while ((!got_exit || !contains_substr(out, out_len, "PTY:hello_pty")) && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 501 && len >= 10) {
            if (ev[9] == STS_EV_PTY_DATA) {
                size_t n = (size_t)(len - 10);
                if (out_len + n < sizeof(out)) {
                    memcpy(out + out_len, ev + 10, n);
                    out_len += n;
                    out[out_len] = '\0';
                }
            } else if (ev[9] == STS_EV_PTY_EXIT) {
                code = read_i32_le(ev + 10);
                got_exit = 1;
            }
        }
        sth_free(ev);
    }
    assert(got_exit && code == 0);
    assert(contains_substr(out, out_len, "PTY:hello_pty"));
    assert(sts_pty_close(h) == 1);
    drain_queue();
    printf("  [PASS] pty (echo, resize, exit, close)\n");
}

// ---------------------------------------------------------------------------
// 9. UDP loopback send/recv + close
// ---------------------------------------------------------------------------

static void test_udp(void) {
    drain_queue();
    int64_t p1 = 0, p2 = 0;
    int64_t u1 = sts_udp_bind(601, "127.0.0.1", 0, &p1);
    int64_t u2 = sts_udp_bind(602, "127.0.0.1", 0, &p2);
    assert(u1 > 0 && p1 > 0);
    assert(u2 > 0 && p2 > 0);

    const char *payload = "udp_hello_lan";
    assert(sts_udp_send_to(u1, "127.0.0.1", (int32_t)p2, (const uint8_t *)payload, (int64_t)strlen(payload)) == 0);

    int got_pkt = 0;
    int64_t deadline = sth_now_ms() + 5000;
    while (!got_pkt && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 602 && len >= 14 && ev[9] == STS_EV_UDP_RECV) {
            uint16_t src_port = read_u16_le(ev + 10);
            uint16_t alen = read_u16_le(ev + 12);
            assert(src_port == (uint16_t)p1);
            assert(len >= (int64_t)(14 + alen));
            assert(alen == 9 && memcmp(ev + 14, "127.0.0.1", 9) == 0);
            size_t plen = (size_t)(len - 14 - alen);
            assert(plen == strlen(payload) && memcmp(ev + 14 + alen, payload, plen) == 0);
            got_pkt = 1;
        }
        sth_free(ev);
    }
    assert(got_pkt);
    assert(sts_udp_close(u1) == 1);
    assert(sts_udp_close(u2) == 1);
    drain_queue();
    printf("  [PASS] udp (loopback send/recv + close)\n");
}

// ---------------------------------------------------------------------------
// 10. Machine / OS info
// ---------------------------------------------------------------------------

static void test_machine_and_os_info(void) {
    assert(sts_os_kind() == 0 || sts_os_kind() == 1);
    assert(sts_arch_kind() == 0 || sts_arch_kind() == 1);

    int64_t len = 0;
    char *host = (char *)sts_hostname(&len);
    assert(host != NULL && len > 0);
    sts_free(host);

    char *home = (char *)sts_homedir(&len);
    assert(home != NULL && len > 0);
    sts_free(home);

    char *tmp = (char *)sts_tmpdir(&len);
    assert(tmp != NULL && len > 0);
    sts_free(tmp);

    // Env roundtrip.
    assert(sts_env_set("STS_UNIT_VAR", "val_123") == 1);
    char *v = (char *)sts_env_get("STS_UNIT_VAR", &len);
    assert(v != NULL && len == 7 && memcmp(v, "val_123", 7) == 0);
    sts_free(v);

    char *env_all = (char *)sts_env_all(&len);
    assert(env_all != NULL && len > 0);
    assert(contains_substr(env_all, (size_t)len, "STS_UNIT_VAR=val_123"));
    sts_free(env_all);

    assert(sts_env_unset("STS_UNIT_VAR") == 1);
    v = (char *)sts_env_get("STS_UNIT_VAR", &len);
    assert(v == NULL && len == 0);

    // is_executable.
    assert(sts_is_executable("/bin/sh") == 1);
    assert(sts_is_executable("/tmp") == 0);
    assert(sts_is_executable("/nonexistent_sts_path_xyz") == 0);

    // disk_of.
    char *disk = (char *)sts_disk_of("/tmp", &len);
    assert(disk != NULL && len > 0);
    assert(contains_substr(disk, (size_t)len, "\"free\":"));
    assert(contains_substr(disk, (size_t)len, "\"total\":"));
    sts_free(disk);

    // machine_stats.
    char *ms = (char *)sts_machine_stats(&len);
    assert(ms != NULL && len > 0);
    assert(contains_substr(ms, (size_t)len, "\"cpus\":["));
    assert(contains_substr(ms, (size_t)len, "\"totalmem\":"));
    assert(contains_substr(ms, (size_t)len, "\"freemem\":"));
    assert(contains_substr(ms, (size_t)len, "\"loadavg\":["));
    assert(contains_substr(ms, (size_t)len, "\"uptime\":"));
    sts_free(ms);

    // psi_pressure (Linux with /proc/pressure/cpu).
    char *psi = (char *)sts_psi_pressure(&len);
#ifdef __linux__
    if (access("/proc/pressure/cpu", R_OK) == 0 && access("/proc/pressure/memory", R_OK) == 0) {
        assert(psi != NULL && len > 0);
        assert(contains_substr(psi, (size_t)len, "\"cpuSome\":"));
        assert(contains_substr(psi, (size_t)len, "\"memorySome\":"));
        assert(contains_substr(psi, (size_t)len, "\"memoryFull\":"));
        assert(contains_substr(psi, (size_t)len, "\"compactStalls\":"));
        assert(contains_substr(psi, (size_t)len, "\"allocStalls\":"));
    }
#endif
    sts_free(psi);

    // network_interfaces: must return valid JSON array containing 127.0.0.1 loopback (internal:true).
    char *ifaces = (char *)sts_network_interfaces(&len);
    assert(ifaces != NULL && len > 2);
    assert(ifaces[0] == '[' && ifaces[len - 1] == ']');
    assert(contains_substr(ifaces, (size_t)len, "\"address\":\"127.0.0.1\""));
    assert(contains_substr(ifaces, (size_t)len, "\"family\":\"IPv4\""));
    assert(contains_substr(ifaces, (size_t)len, "\"netmask\":"));
    assert(contains_substr(ifaces, (size_t)len, "\"internal\":true"));
    sts_free(ifaces);

    printf("  [PASS] machine/os info (env, is_executable, disk_of, machine_stats, psi_pressure, network_interfaces)\n");
}

static void *noop_thread(void *arg) {
    return arg;
}

int main(void) {
    // Warm up one joinable thread so runtimes like libtsan initialize any lazy internal
    // background thread before capturing the strict exact baseline fd & thread counts.
    pthread_t warm;
    assert(pthread_create(&warm, NULL, noop_thread, NULL) == 0);
    assert(pthread_join(warm, NULL) == 0);

    // Capture exact baseline fd & thread counts before running any tests.
    int32_t fd_before = sth_open_fd_count();
    int32_t th_before = sth_open_thread_count();
    assert(fd_before >= 3);
    assert(th_before >= 1);

    test_fs_watch_non_recursive();
    test_fs_watch_single_file();
    test_proc_pipes_exit_and_env_strip();
    test_ctrl_channel();
    test_signals();
    test_flock();
    test_peer_process();
    test_process_usage();
    test_pty();
    test_udp();
    test_machine_and_os_info();

    drain_queue();
    int32_t fd_after = sth_open_fd_count();
    int32_t th_after = sth_open_thread_count();
    if (fd_after != fd_before || th_after != th_before) {
        fprintf(stderr, "LEAK DETECTED: fds %d -> %d, threads %d -> %d\n",
                fd_before, fd_after, th_before, th_after);
        return 1;
    }
    printf("station_sys_test: ALL PASSED (fds=%d->%d, threads=%d->%d)\n",
           fd_before, fd_after, th_before, th_after);
    return 0;
}
