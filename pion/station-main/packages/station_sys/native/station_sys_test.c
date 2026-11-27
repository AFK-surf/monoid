// Comprehensive C11 unit, adversarial, and concurrency test suite for `station_sys.c`
// linked with `station_host.c`.
// Targets: Linux (x64/arm64), macOS (arm64), and native Windows (`_WIN32` / MinGW).
// Verified under -Wall -Wextra -Werror, -fsanitize=address,undefined, and -fsanitize=thread.

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#endif

#include "station_sys.h"
#include "../../../../station/packages/host_shim/native/station_host.h"

#undef NDEBUG
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

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

#ifdef _WIN32
// ===========================================================================
//                         WINDOWS NATIVE TEST SUITE
// ===========================================================================

static void win_make_temp_dir(char *out, size_t cap) {
    int64_t tlen = 0;
    char *tmp = (char *)sts_tmpdir(&tlen);
    assert(tmp != NULL && tlen > 0);
    static unsigned seq = 0;
    seq += 1;
    int n = snprintf(out, cap, "%.*s\\sts_test_%lu_%u", (int)tlen, tmp, (unsigned long)GetCurrentProcessId(), seq);
    sts_free(tmp);
    assert(n > 0 && (size_t)n < cap);
    int wn = MultiByteToWideChar(CP_UTF8, 0, out, -1, NULL, 0);
    assert(wn > 0);
    wchar_t *wout = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)wn);
    assert(wout != NULL);
    assert(MultiByteToWideChar(CP_UTF8, 0, out, -1, wout, wn) > 0);
    BOOL ok = CreateDirectoryW(wout, NULL);
    DWORD err = ok ? 0 : GetLastError();
    free(wout);
    if (!ok) {
        fprintf(stderr, "CreateDirectoryW(%s) failed: err=%lu\n", out, (unsigned long)err);
    }
    assert(ok != 0);
}

static void win_write_file_str(const char *path, const char *s, int append) {
    HANDLE h = CreateFileA(
        path,
        append ? FILE_APPEND_DATA : GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        append ? OPEN_ALWAYS : CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    assert(h != INVALID_HANDLE_VALUE);
    DWORD w = 0;
    size_t n = strlen(s);
    if (n > 0) {
        assert(WriteFile(h, s, (DWORD)n, &w, NULL) && w == (DWORD)n);
    }
    CloseHandle(h);
}

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

static void test_win_fs_watch(void) {
    drain_queue();
    char dir[256], f1[320];
    win_make_temp_dir(dir, sizeof(dir));
    snprintf(f1, sizeof(f1), "%s\\alpha.txt", dir);
    win_write_file_str(f1, "line1\n", 0);

    int64_t h = sts_fs_watch_open(101, dir);
    assert(h > 0);
    // In-place append to existing file must trigger event.
    win_write_file_str(f1, "line2\n", 1);
    assert(wait_for_fs_name(101, "alpha.txt") == 1);
    assert(sts_fs_watch_close(h) == 1);
    assert(sts_fs_watch_close(h) == 0);
    drain_queue();

    assert(sts_unlink(f1) == 1);
    assert(RemoveDirectoryA(dir) != 0);
    printf("  [PASS] win fs.watch (dir in-place append + close + unlink)\n");
}

static void test_win_flock(void) {
    char dir[256], lock_path[320];
    win_make_temp_dir(dir, sizeof(dir));
    snprintf(lock_path, sizeof(lock_path), "%s\\test.lock", dir);

    int64_t h1 = sts_flock_try(lock_path);
    assert(h1 > 0);
    assert(sts_flock_try(lock_path) == 0); // contended
    assert(sts_flock_unlock(h1) == 1);
    assert(sts_flock_unlock(h1) == 0);
    assert(sts_unlink(lock_path) == 1);
    assert(RemoveDirectoryA(dir) != 0);
    printf("  [PASS] win flock (LockFileEx contention + unlock + unlink)\n");
}

static void test_win_proc_and_pty(void) {
    drain_queue();
    // 1. Overlapped stdout/stderr/stdin + sts_proc_kill_handle(STS_SIG_PROBE)
    const uint8_t args[] = "/c\0echo WIN_OUT_OK & echo WIN_ERR_OK 1>&2\0";
    int64_t pid = 0;
    char err[256] = "";
    int64_t h = sts_proc_spawn(
        201, "cmd.exe", args, (int64_t)(sizeof(args) - 1), NULL, 0, NULL,
        STS_PROC_PIPE_STDOUT | STS_PROC_PIPE_STDERR, &pid, err, sizeof(err));
    assert(h > 0 && pid > 0);

    char out[512] = "", ebuf[512] = "";
    size_t olen = 0, elen = 0;
    int got_out_eof = 0, got_err_eof = 0, got_exit = 0;
    int32_t code = -1;
    int64_t deadline = sth_now_ms() + 8000;
    while ((!got_out_eof || !got_err_eof || !got_exit) && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 201 && len >= 10) {
            if (ev[9] == STS_EV_PROC_STDOUT) {
                size_t n = (size_t)(len - 10);
                if (olen + n < sizeof(out)) { memcpy(out + olen, ev + 10, n); olen += n; out[olen] = '\0'; }
            } else if (ev[9] == STS_EV_PROC_STDERR) {
                size_t n = (size_t)(len - 10);
                if (elen + n < sizeof(ebuf)) { memcpy(ebuf + elen, ev + 10, n); elen += n; ebuf[elen] = '\0'; }
            } else if (ev[9] == STS_EV_PROC_STDOUT_EOF) {
                got_out_eof = 1;
            } else if (ev[9] == STS_EV_PROC_STDERR_EOF) {
                got_err_eof = 1;
            } else if (ev[9] == STS_EV_PROC_EXIT) {
                code = read_i32_le(ev + 10);
                got_exit = 1;
            }
        }
        sth_free(ev);
    }
    assert(got_out_eof && got_err_eof && got_exit && code == 0);
    assert(contains_substr(out, olen, "WIN_OUT_OK"));
    assert(contains_substr(ebuf, elen, "WIN_ERR_OK"));
    assert(sts_proc_close(h) == 1);
    drain_queue();

    // 2. Full-queue non-blocking sts_proc_close (adversarial deadlock regression).
    // Pre-fill bounded queue to exact 2 MiB (32 * 64 KiB = STH_SYS_DATA_MOST, never self-blocks
    // consumer because sth_push_sys_bounded only blocks when already >= STH_SYS_DATA_MOST),
    // then spawn flooder and deterministically wait until reader parks in sth_push_sys_bounded.
    uint8_t junk[65536];
    memset(junk, 'x', sizeof(junk));
    for (int i = 0; i < 32; i++) {
        sth_push_sys_bounded(999, junk, sizeof(junk));
    }
    const uint8_t flood_args[] = "/c\0for /L %i in (1,1,8000) do @echo FLOOD_LINE_0123456789012345678901234567890123456789\0";
    int64_t fpid = 0;
    int64_t fh = sts_proc_spawn(
        202, "cmd.exe", flood_args, (int64_t)(sizeof(flood_args) - 1), NULL, 0, NULL,
        STS_PROC_PIPE_STDOUT, &fpid, err, sizeof(err));
    assert(fh > 0);
    for (int64_t wdl = sth_now_ms() + 5000; sth_now_ms() < wdl; ) {
        if (sts_bounded_push_inflight_for_test() > 0) break;
        SwitchToThread();
    }
    assert(sts_bounded_push_inflight_for_test() > 0);
    int64_t t0 = sth_now_ms();
    assert(sts_proc_kill_handle(fh, STS_SIG_KILL, 0) == 0);
    assert(sts_proc_close(fh) == 1);
    assert(sth_now_ms() - t0 < 500);
    for (int i = 0; i < 200; i++) {
        drain_queue();
        if (sts_active_workers() == 0) break;
        sts_wait_detached_for_test(25);
    }
    assert(sts_active_workers() == 0);
    drain_queue();
    assert(sts_wait_detached_for_test(5000) == 1);

    // 3. ConPTY: STS_SIG_PROBE must NOT kill the child; write + resize + close work.
    const uint8_t pty_args[] = "/k\0echo PTY_READY\0";
    int64_t ppid = 0;
    int64_t ph = sts_pty_spawn(
        501, "cmd.exe", pty_args, (int64_t)(sizeof(pty_args) - 1), NULL, 0, NULL,
        80, 24, 0, &ppid, err, sizeof(err));
    assert(ph > 0 && ppid > 0);
    assert(sts_pty_kill(ph, STS_SIG_PROBE) == 1);
    assert(sts_pty_kill(ph, STS_SIG_PROBE) == 1); // still alive after probe!
    assert(sts_pty_resize(ph, 100, 30) == 1);
    const char *exit_cmd = "exit\r\n";
    assert(sts_pty_write(ph, (const uint8_t *)exit_cmd, (int64_t)strlen(exit_cmd)) == 1);
    assert(sts_pty_close(ph) == 1);
    drain_queue();
    assert(sts_wait_detached_for_test(5000) == 1);
    printf("  [PASS] win proc + full-queue close + ConPTY STS_SIG_PROBE\n");
}

static void test_win_udp_and_info(void) {
    drain_queue();
    assert(sts_udp_bind(600, NULL, 0, NULL) < 0);
    assert(sts_udp_bind(600, "", 0, NULL) < 0);
    assert(sts_udp_bind(600, "127.0.0.1", -1, NULL) < 0);
    assert(sts_udp_bind(600, "127.0.0.1", 65536, NULL) < 0);
    int64_t p2 = 0;
    int64_t u2 = sts_udp_bind(602, "127.0.0.1", 0, &p2);
    assert(u2 > 0 && p2 > 0);
    const char *msg = "win_udp_once";
    assert(sts_udp_send_once("127.0.0.1", (int32_t)p2, (const uint8_t *)msg, (int64_t)strlen(msg)) == 0);
    int got = 0;
    int64_t deadline = sth_now_ms() + 5000;
    while (!got && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 602 && len >= 14 && ev[9] == STS_EV_UDP_RECV) {
            uint16_t src_port = read_u16_le(ev + 10);
            uint16_t alen = read_u16_le(ev + 12);
            assert(src_port > 0);
            assert(len >= (int64_t)(14 + alen));
            assert(alen == 9 && memcmp(ev + 14, "127.0.0.1", 9) == 0);
            if (contains_substr((const char *)(ev + 14 + alen), (size_t)(len - 14 - alen), msg)) got = 1;
        }
        sth_free(ev);
    }
    assert(got == 1);
    assert(sts_udp_close(u2) == 1);
    assert(sts_udp_close(u2) == 0);
    // Wait for worker exit, then drain entire queue and assert strictly 1 STS_EV_UDP_CLOSED.
    assert(sts_wait_detached_for_test(5000) == 1);
    int closed_cnt = 0;
    for (;;) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(0, &len);
        if (ev == NULL) break;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 602 && len == 10 && ev[9] == STS_EV_UDP_CLOSED) {
            closed_cnt += 1;
        }
        sth_free(ev);
    }
    assert(closed_cnt == 1);

    assert(sts_os_kind() == 2);
    assert(sts_env_set("STS_WIN_VAR", "ok_val") == 1);
    int64_t len = 0;
    char *v = (char *)sts_env_get("STS_WIN_VAR", &len);
    assert(v != NULL && len == 6 && memcmp(v, "ok_val", 6) == 0);
    sts_free(v);
    assert(sts_env_unset("STS_WIN_VAR") == 1);
    assert(sts_env_get("STS_WIN_VAR", &len) == NULL);

    char *ms = (char *)sts_machine_stats(&len);
    assert(ms != NULL && contains_substr(ms, (size_t)len, "\"cpus\":["));
    sts_free(ms);

    char *ifaces = (char *)sts_network_interfaces(&len);
    assert(ifaces != NULL && contains_substr(ifaces, (size_t)len, "\"address\":\"127.0.0.1\""));
    sts_free(ifaces);

    int32_t pids[1] = { (int32_t)GetCurrentProcessId() };
    char *usage = (char *)sts_process_usage(pids, 1, &len);
    assert(usage != NULL && contains_substr(usage, (size_t)len, "\"footprint\":"));
    sts_free(usage);

    assert(sts_signal_watch(401) == 1);
    assert(sts_signal_unwatch() == 1);
    printf("  [PASS] win udp + env + machine/ifaces/usage + signals\n");
}

static void test_win_cli_prims(void) {
    char dir[256];
    win_make_temp_dir(dir, sizeof(dir));

    // 200-byte basename atomic write + strict read roundtrip (independent short temp filename).
    char name200[201];
    memset(name200, 'a', 196);
    memcpy(name200 + 196, ".bin", 5);
    char long_file[512];
    int n = snprintf(long_file, sizeof(long_file), "%s\\%s", dir, name200);
    assert(n > 0 && (size_t)n < sizeof(long_file));
    const uint8_t payload[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
    assert(sts_write_file_atomic(long_file, payload, 4, -1) == 1);
    int64_t rlen = 0;
    int32_t rerr = 0;
    uint8_t *got = (uint8_t *)sts_read_file_strict(long_file, &rlen, &rerr);
    assert(got != NULL && rlen == 4 && rerr == 0 && memcmp(got, payload, 4) == 0);
    sts_free(got);
    assert(sts_unlink(long_file) == 1);

    // Drive-relative path atomic write (e.g. "C:sf_drive_rel_test_<pid>.bin"): temp file stays on same drive.
    {
        int64_t cwd_len = 0;
        char *cwd = (char *)sts_getcwd(&cwd_len);
        assert(cwd != NULL && cwd_len >= 2 && cwd[1] == ':');
        char drive_rel[64];
        snprintf(drive_rel, sizeof(drive_rel), "%c:sf_drive_rel_test_%lu.bin", cwd[0], (unsigned long)GetCurrentProcessId());
        sts_free(cwd);
        assert(sts_write_file_atomic(drive_rel, payload, 4, -1) == 1);
        int64_t dlen = 0;
        int32_t derr = 0;
        uint8_t *dgot = (uint8_t *)sts_read_file_strict(drive_rel, &dlen, &derr);
        assert(dgot != NULL && dlen == 4 && derr == 0 && memcmp(dgot, payload, 4) == 0);
        sts_free(dgot);
        assert(sts_unlink(drive_rel) == 1);
    }

    // Dangling directory symlink & dangling file symlink (`sts_is_dir_symlink` without following target).
    char dlink[320], flink[320];
    snprintf(dlink, sizeof(dlink), "%s\\dangling_dir_link", dir);
    snprintf(flink, sizeof(flink), "%s\\dangling_file_link", dir);
    if (sts_symlink("nonexistent_dir_target", dlink, 1) == 1) {
        assert(sts_is_dir_symlink(dlink) == 1);
        assert(RemoveDirectoryA(dlink) != 0);
    } else if (GetLastError() == ERROR_PRIVILEGE_NOT_HELD) {
        printf("  [SKIP] win dangling dir symlink (ERROR_PRIVILEGE_NOT_HELD)\n");
    } else {
        fprintf(stderr, "sts_symlink(dir) failed unexpectedly: err=%lu\n", (unsigned long)GetLastError());
        assert(0);
    }
    if (sts_symlink("nonexistent_file_target", flink, 0) == 1) {
        assert(sts_is_dir_symlink(flink) == 0);
        assert(DeleteFileA(flink) != 0);
    } else if (GetLastError() == ERROR_PRIVILEGE_NOT_HELD) {
        printf("  [SKIP] win dangling file symlink (ERROR_PRIVILEGE_NOT_HELD)\n");
    } else {
        fprintf(stderr, "sts_symlink(file) failed unexpectedly: err=%lu\n", (unsigned long)GetLastError());
        assert(0);
    }

    assert(RemoveDirectoryA(dir) != 0);
    printf("  [PASS] win cli prims (200B atomic write + dangling dir/file symlink)\n");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    test_win_fs_watch();
    test_win_flock();
    test_win_proc_and_pty();
    test_win_udp_and_info();
    test_win_cli_prims();
    assert(sts_wait_detached_for_test(5000) == 1);
    printf("station_sys_test (windows): ALL PASSED\n");
    return 0;
}

#else
// ===========================================================================
//                         POSIX TEST SUITE (Linux + macOS)
// ===========================================================================

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
// 0. Adversarial: parent fd 0/1 closed + STS_PROC_PIPE_STDERR only (run before threads!)
// ---------------------------------------------------------------------------

static void test_proc_closed_stdio_stderr(void) {
    pid_t helper = fork();
    assert(helper >= 0);
    if (helper == 0) {
        close(0);
        close(1);
        const char *script = "echo CLOSED_STDIO_ERR_OK >&2";
        size_t slen = strlen(script);
        uint8_t *args = (uint8_t *)malloc(3 + slen + 1);
        if (args == NULL) _exit(2);
        memcpy(args, "-c", 3);
        memcpy(args + 3, script, slen + 1);
        int64_t pid = 0;
        char err[256] = "";
        int64_t h = sts_proc_spawn(
            901, "/bin/sh", args, (int64_t)(3 + slen + 1), NULL, 0, NULL,
            STS_PROC_PIPE_STDERR, &pid, err, sizeof(err));
        free(args);
        if (h <= 0 || pid <= 0) _exit(3);
        char ebuf[256] = "";
        size_t elen = 0;
        int got_err_eof = 0, got_exit = 0;
        int64_t deadline = sth_now_ms() + 5000;
        while ((!got_err_eof || !got_exit) && sth_now_ms() < deadline) {
            int64_t len = 0;
            uint8_t *ev = (uint8_t *)sth_wait(500, &len);
            if (ev == NULL) continue;
            if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 901 && len >= 10) {
                if (ev[9] == STS_EV_PROC_STDERR) {
                    size_t n = (size_t)(len - 10);
                    if (elen + n < sizeof(ebuf)) {
                        memcpy(ebuf + elen, ev + 10, n);
                        elen += n;
                        ebuf[elen] = '\0';
                    }
                } else if (ev[9] == STS_EV_PROC_STDERR_EOF) {
                    got_err_eof = 1;
                } else if (ev[9] == STS_EV_PROC_EXIT) {
                    got_exit = 1;
                }
            }
            sth_free(ev);
        }
        sts_proc_close(h);
        sts_wait_detached_for_test(5000);
        _exit((got_err_eof && got_exit && contains_substr(ebuf, elen, "CLOSED_STDIO_ERR_OK")) ? 0 : 4);
    }
    int st = 0;
    pid_t wr;
    do {
        wr = waitpid(helper, &st, 0);
    } while (wr < 0 && errno == EINTR);
    assert(wr == helper && WIFEXITED(st) && WEXITSTATUS(st) == 0);
    printf("  [PASS] adv: closed parent fd 0/1 does not clobber child stderr\n");
}

// ---------------------------------------------------------------------------
// 1. Non-recursive fs.watch test (including in-place append on existing file!)
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
    char sub[256], existing[256];
    snprintf(sub, sizeof(sub), "%s/sub", dir);
    snprintf(existing, sizeof(existing), "%s/existing.log", dir);
    assert(mkdir(sub, 0755) == 0);
    write_file_str(existing, "init\n");

    int64_t h = sts_fs_watch_open(101, dir);
    assert(h > 0);

    // Adversarial: in-place append to pre-existing file in watched dir MUST trigger event (validates macOS FSEvents!).
    int afd = open(existing, O_WRONLY | O_APPEND);
    assert(afd >= 0);
    assert(write(afd, "appended\n", 9) == 9);
    close(afd);
    assert(wait_for_fs_name(101, "existing.log") == 1);
    drain_queue();

    // Create, rename, and delete a direct child in `dir`.
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

    assert(unlink(existing) == 0);
    assert(rmdir(sub) == 0);
    assert(rmdir(dir) == 0);
    printf("  [PASS] fs.watch (dir in-place append + non-recursive + close)\n");
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
    assert(wait_for_fs_name(102, "events.log") == 1);
    drain_queue();

    // Rename/move away -> must emit STS_FS_RENAME with basename "events.log".
    assert(rename(fpath, fmoved) == 0);
    assert(wait_for_fs_event(102, STS_FS_RENAME, "events.log") == 1);

    assert(sts_fs_watch_close(h) == 1);
    drain_queue();
    assert(sts_unlink(fmoved) == 1);
    assert(rmdir(dir) == 0);
    printf("  [PASS] fs.watch (single-file append + rename + close)\n");
}

// ---------------------------------------------------------------------------
// 2. Async child process tests + Adversarial R3 tests
// ---------------------------------------------------------------------------

static void test_proc_pipes_exit_and_env_strip(void) {
    drain_queue();
    assert(sts_env_set("MallocSpaceEfficient", "1") == 1);
    assert(sts_env_set("STS_TEST_KEEP", "yes42") == 1);

    const char *script =
        "read line; "
        "echo \"OUT:$line:${MallocSpaceEfficient:-STRIPPED}:$STS_TEST_KEEP\"; "
        "echo \"ERR:$line\" >&2; "
        "exit 7";
    size_t slen = strlen(script);
    size_t alen = 3 + slen + 1;
    uint8_t *args = (uint8_t *)malloc(alen);
    assert(args != NULL);
    memcpy(args, "-c", 3);
    memcpy(args + 3, script, slen + 1);

    int64_t pid = 0;
    char err[256] = "";
    int64_t h = sts_proc_spawn(
        201, "/bin/sh", args, (int64_t)alen, NULL, 0, NULL,
        STS_PROC_NEW_PGID | STS_PROC_STRIP_MALLOC_SE | STS_PROC_PIPE_STDIN | STS_PROC_PIPE_STDOUT | STS_PROC_PIPE_STDERR,
        &pid, err, sizeof(err));
    free(args);
    assert(h > 0 && pid > 0);

    int64_t st_ms = sts_proc_start_time_ms((int32_t)pid);
    assert(st_ms > 1700000000000LL);
#ifdef __linux__
    assert(sts_proc_start_ticks((int32_t)pid) >= 0);
    int64_t bid_len = 0;
    void *bid = sts_boot_id(&bid_len);
    assert(bid != NULL && bid_len >= 16);
    sts_free(bid);
#endif

    // Handle-bound probe while child is alive.
    assert(sts_proc_kill_handle(h, STS_SIG_PROBE, 0) == 0);

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
                if (out_len + n < sizeof(out_buf)) { memcpy(out_buf + out_len, ev + 10, n); out_len += n; out_buf[out_len] = '\0'; }
            } else if (tag == STS_EV_PROC_STDERR) {
                size_t n = (size_t)(len - 10);
                if (err_len + n < sizeof(err_buf)) { memcpy(err_buf + err_len, ev + 10, n); err_len += n; err_buf[err_len] = '\0'; }
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
    // After exit is observed, handle-bound kill returns -ESRCH (never signals a reused PID).
    assert(sts_proc_kill_handle(h, STS_SIG_PROBE, 0) == -ESRCH);

    assert(sts_proc_close(h) == 1);
    assert(sts_env_unset("MallocSpaceEfficient") == 1);
    assert(sts_env_unset("STS_TEST_KEEP") == 1);
    drain_queue();

    // Test process group kill + signal exit reporting via handle-bound kill.
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
    assert(sts_proc_kill_handle(sh, STS_SIG_KILL, 1) == 0);

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
    assert(sts_wait_detached_for_test(5000) == 1);
    printf("  [PASS] async proc (pipes, handle kill, exit/sig, start_time_of, MallocSpaceEfficient strip)\n");
}

static void test_proc_adversarial(void) {
    drain_queue();
    char err[256] = "";

    // 1. Explicit empty env (STS_PROC_EXPLICIT_ENV with env_len=0) MUST NOT inherit parent env.
    assert(sts_env_set("STS_SECRET_PARENT_ENV", "leaked_if_bug") == 1);
    const char *env_script = "printf 'VAL=%s\\n' \"${STS_SECRET_PARENT_ENV:-EMPTY}\"";
    size_t el = strlen(env_script);
    uint8_t *eargs = (uint8_t *)malloc(3 + el + 1);
    memcpy(eargs, "-c", 3);
    memcpy(eargs + 3, env_script, el + 1);
    int64_t epid = 0;
    int64_t eh = sts_proc_spawn(
        210, "/bin/sh", eargs, (int64_t)(3 + el + 1), NULL, 0, NULL,
        STS_PROC_PIPE_STDOUT | STS_PROC_EXPLICIT_ENV, &epid, err, sizeof(err));
    free(eargs);
    assert(eh > 0);
    char eout[256] = "";
    size_t eout_len = 0;
    int got_out_eof = 0, got_eexit = 0;
    int64_t dl = sth_now_ms() + 5000;
    while ((!got_out_eof || !got_eexit) && sth_now_ms() < dl) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 210 && len >= 10) {
            if (ev[9] == STS_EV_PROC_STDOUT) {
                size_t n = (size_t)(len - 10);
                if (eout_len + n < sizeof(eout)) { memcpy(eout + eout_len, ev + 10, n); eout_len += n; eout[eout_len] = '\0'; }
            } else if (ev[9] == STS_EV_PROC_STDOUT_EOF) {
                got_out_eof = 1;
            } else if (ev[9] == STS_EV_PROC_EXIT) {
                got_eexit = 1;
            }
        }
        sth_free(ev);
    }
    assert(got_out_eof && got_eexit && contains_substr(eout, eout_len, "VAL=EMPTY"));
    assert(!contains_substr(eout, eout_len, "leaked_if_bug"));
    assert(sts_proc_close(eh) == 1);
    assert(sts_env_unset("STS_SECRET_PARENT_ENV") == 1);
    drain_queue();

    // 2. Bare program NOT in PATH must NOT execute same-named executable in child cwd.
    char dir[128], trap_bin[256];
    make_temp_dir(dir, sizeof(dir));
    snprintf(trap_bin, sizeof(trap_bin), "%s/sts_rogue_bin_xyz", dir);
    write_file_str(trap_bin, "#!/bin/sh\necho PWNED\n");
    assert(chmod(trap_bin, 0755) == 0);
    int64_t rpid = 0;
    int64_t rh = sts_proc_spawn(
        211, "sts_rogue_bin_xyz", NULL, 0, NULL, 0, dir,
        STS_PROC_PIPE_STDOUT, &rpid, err, sizeof(err));
    assert(rh < 0);
    assert(sts_unlink(trap_bin) == 1);
    assert(rmdir(dir) == 0);

    // 3. Relative cwd + relative PATH must resolve without double-prefixing `work/work/bin/tool`.
    char rdir[128], rwork[256], rbin[320], rtool[384], old_cwd[4096];
    assert(getcwd(old_cwd, sizeof(old_cwd)) != NULL);
    make_temp_dir(rdir, sizeof(rdir));
    snprintf(rwork, sizeof(rwork), "%s/work", rdir);
    snprintf(rbin, sizeof(rbin), "%s/bin", rwork);
    snprintf(rtool, sizeof(rtool), "%s/mytool", rbin);
    assert(mkdir(rwork, 0755) == 0);
    assert(mkdir(rbin, 0755) == 0);
    write_file_str(rtool, "#!/bin/sh\necho REL_PATH_OK\n");
    assert(chmod(rtool, 0755) == 0);
    assert(chdir(rdir) == 0);
    const uint8_t rel_env[] = "PATH=bin\0";
    int64_t rel_pid = 0;
    int64_t rel_h = sts_proc_spawn(
        214, "mytool", NULL, 0, rel_env, (int64_t)(sizeof(rel_env) - 1), "work",
        STS_PROC_PIPE_STDOUT | STS_PROC_EXPLICIT_ENV, &rel_pid, err, sizeof(err));
    assert(chdir(old_cwd) == 0);
    assert(rel_h > 0 && rel_pid > 0);
    char rout[256] = "";
    size_t rout_len = 0;
    int got_rout_eof = 0, got_rexit = 0;
    dl = sth_now_ms() + 5000;
    while ((!got_rout_eof || !got_rexit) && sth_now_ms() < dl) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 214 && len >= 10) {
            if (ev[9] == STS_EV_PROC_STDOUT) {
                size_t n = (size_t)(len - 10);
                if (rout_len + n < sizeof(rout)) { memcpy(rout + rout_len, ev + 10, n); rout_len += n; rout[rout_len] = '\0'; }
            } else if (ev[9] == STS_EV_PROC_STDOUT_EOF) {
                got_rout_eof = 1;
            } else if (ev[9] == STS_EV_PROC_EXIT) {
                assert(read_i32_le(ev + 10) == 0);
                got_rexit = 1;
            }
        }
        sth_free(ev);
    }
    assert(got_rout_eof && got_rexit && contains_substr(rout, rout_len, "REL_PATH_OK"));
    assert(sts_proc_close(rel_h) == 1);
    assert(sts_unlink(rtool) == 1);
    assert(rmdir(rbin) == 0);
    assert(rmdir(rwork) == 0);
    assert(rmdir(rdir) == 0);
    drain_queue();

    // 4. Opus N1: close a live child spamming stdout WITHOUT killing it -> closing stdout pipe
    //    immediately delivers SIGPIPE/EPIPE so child exits and reaper finishes cleanly.
    const char *spam_script = "while :; do echo spam-spam-spam-spam; done";
    size_t spl = strlen(spam_script);
    uint8_t *spargs = (uint8_t *)malloc(3 + spl + 1);
    memcpy(spargs, "-c", 3);
    memcpy(spargs + 3, spam_script, spl + 1);
    int64_t spid = 0;
    int64_t sph = sts_proc_spawn(
        215, "/bin/sh", spargs, (int64_t)(3 + spl + 1), NULL, 0, NULL,
        STS_PROC_PIPE_STDOUT, &spid, err, sizeof(err));
    free(spargs);
    assert(sph > 0 && spid > 0);
    // Wait for first stdout chunk so child is actively writing.
    int saw_spam = 0;
    dl = sth_now_ms() + 5000;
    while (!saw_spam && sth_now_ms() < dl) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 215 && len >= 10 && ev[9] == STS_EV_PROC_STDOUT) {
            saw_spam = 1;
        }
        sth_free(ev);
    }
    assert(saw_spam == 1);
    assert(sts_proc_close(sph) == 1);
    // Drain & wait for detached workers WITHOUT killing spid: EPIPE must terminate it!
    for (int i = 0; i < 100; i++) {
        drain_queue();
        if (sts_wait_detached_for_test(50) == 1) break;
    }
    assert(sts_wait_detached_for_test(5000) == 1);
    int st = 0;
    assert(waitpid((pid_t)spid, &st, WNOHANG) == -1 && errno == ECHILD);
    drain_queue();

    // 5. Full 2 MiB bounded queue deadlock regression: saturate exact 2 MiB (32 * 64 KiB =
    //    STH_SYS_DATA_MOST) so reader's first sth_push_sys_bounded is guaranteed to park,
    //    verify sts_proc_close returns < 100ms before draining, then drain and verify
    //    SIGPIPE + reaper finish cleanly with zero zombies.
    uint8_t junk[65536];
    memset(junk, 'Z', sizeof(junk));
    for (int i = 0; i < 32; i++) {
        sth_push_sys_bounded(999, junk, sizeof(junk));
    }
    const char *flood_script = "dd if=/dev/zero bs=65536 count=128 2>/dev/null";
    size_t fl = strlen(flood_script);
    uint8_t *fargs = (uint8_t *)malloc(3 + fl + 1);
    memcpy(fargs, "-c", 3);
    memcpy(fargs + 3, flood_script, fl + 1);
    int64_t fpid = 0;
    int64_t fh = sts_proc_spawn(
        212, "/bin/sh", fargs, (int64_t)(3 + fl + 1), NULL, 0, NULL,
        STS_PROC_NEW_PGID | STS_PROC_PIPE_STDOUT, &fpid, err, sizeof(err));
    free(fargs);
    assert(fh > 0 && fpid > 0);
    // Deterministically wait until reader thread is parked inside sth_push_sys_bounded.
    for (int64_t wdl = sth_now_ms() + 5000; sth_now_ms() < wdl; ) {
        if (sts_bounded_push_inflight_for_test() > 0) break;
        sched_yield();
    }
    assert(sts_bounded_push_inflight_for_test() > 0);
    int64_t t0 = sth_now_ms();
    assert(sts_proc_close(fh) == 1);
    assert(sth_now_ms() - t0 < 100); // MUST return immediately while queue is saturated!

    // Also test early close -> zero zombie (reaped by detached wait thread).
    const char *short_script = "exit 0";
    size_t shl = strlen(short_script);
    uint8_t *shargs = (uint8_t *)malloc(3 + shl + 1);
    memcpy(shargs, "-c", 3);
    memcpy(shargs + 3, short_script, shl + 1);
    int64_t zpid = 0;
    int64_t zh = sts_proc_spawn(
        213, "/bin/sh", shargs, (int64_t)(3 + shl + 1), NULL, 0, NULL,
        STS_PROC_PIPE_STDOUT, &zpid, err, sizeof(err));
    free(shargs);
    assert(zh > 0 && zpid > 0);
    assert(sts_proc_close(zh) == 1);

    // Shutdown completion contract: drain until sts_active_workers() == 0 AND queue is empty.
    for (int i = 0; i < 200; i++) {
        drain_queue();
        if (sts_active_workers() == 0) break;
        sts_wait_detached_for_test(25);
    }
    assert(sts_active_workers() == 0);
    drain_queue();
    assert(sts_wait_detached_for_test(5000) == 1);
    assert(waitpid((pid_t)fpid, &st, WNOHANG) == -1 && errno == ECHILD);
    assert(waitpid((pid_t)zpid, &st, WNOHANG) == -1 && errno == ECHILD);

    // 6. Deleted cwd regression (N6): when process cwd is removed, PATH lookup for
    //    absolute entries (e.g. /usr/bin/true) must still succeed with cwd=NULL.
    {
        int orig_cwd = open(".", O_RDONLY);
        assert(orig_cwd >= 0);
        char gone_dir[256];
        snprintf(gone_dir, sizeof(gone_dir), "/tmp/sts_n6_gone_%d_%lld", (int)getpid(), (long long)sth_now_ms());
        assert(mkdir(gone_dir, 0700) == 0);
        assert(chdir(gone_dir) == 0);
        assert(rmdir(gone_dir) == 0);
        int64_t n6_pid = 0;
        int64_t n6_h = sts_proc_spawn(
            216, "true", NULL, 0, NULL, 0, NULL, 0, &n6_pid, err, sizeof(err));
        assert(fchdir(orig_cwd) == 0);
        close(orig_cwd);
        assert(n6_h > 0 && n6_pid > 0);
        int n6_exited = 0, n6_code = -1;
        dl = sth_now_ms() + 5000;
        while (!n6_exited && sth_now_ms() < dl) {
            int64_t len = 0;
            uint8_t *ev = (uint8_t *)sth_wait(500, &len);
            if (ev == NULL) continue;
            if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 216 && len >= 18 && ev[9] == STS_EV_PROC_EXIT) {
                n6_code = read_i32_le(ev + 10);
                n6_exited = 1;
            }
            sth_free(ev);
        }
        assert(n6_exited == 1 && n6_code == 0);
        assert(sts_proc_close(n6_h) == 1);
        assert(sts_wait_detached_for_test(5000) == 1);
        drain_queue();
    }

    printf("  [PASS] adv: empty env, PATH/rel-cwd, deleted-cwd (N6), stdout-close EPIPE (N1), full-queue <100ms close, zero zombies\n");
}

// ---------------------------------------------------------------------------
// 3. Control channel test (fd <= 4 rejection + socketpair line framing + EOF + close)
// ---------------------------------------------------------------------------

static void test_ctrl_channel(void) {
    drain_queue();
    // Must reject stdio 0..2 and launcher listening fds 3..4.
    for (int fd = 0; fd <= 4; fd++) {
        assert(sts_ctrl_open_fd(300, fd) < 0);
    }

    int sv[2] = { -1, -1 };
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    // Relocate sv[0] above fd 4 if needed (e.g. if fd 3 or 4 was free).
    if (sv[0] <= 4) {
        int nfd = fcntl(sv[0], F_DUPFD_CLOEXEC, 5);
        assert(nfd > 4);
        close(sv[0]);
        sv[0] = nfd;
    }

    int64_t h = sts_ctrl_open_fd(301, sv[0]);
    assert(h > 0);

    const char *out_msg = "{\"ready\":true}\n";
    assert(sts_ctrl_write(h, (const uint8_t *)out_msg, (int64_t)strlen(out_msg)) == 1);
    char peer_buf[64] = "";
    ssize_t pn = read(sv[1], peer_buf, sizeof(peer_buf) - 1);
    assert(pn == (ssize_t)strlen(out_msg));
    assert(memcmp(peer_buf, out_msg, (size_t)pn) == 0);

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
    assert(saw_eof && lines == 2);
    assert(strcmp(l0, "{\"op\":\"ping\"}") == 0);
    assert(strcmp(l1, "{\"op\":\"renew\"}") == 0);
    assert(l2[0] == '\0'); // unterminated "tail" without '\n' MUST be discarded on EOF

    assert(sts_ctrl_close(h) == 1);
    drain_queue();

    // Real pipe fd: writing a half-line without '\n' and closing write end must NOT deliver
    // any STS_EV_CTRL_LINE (only STS_EV_CTRL_EOF), preventing partial commands from firing.
    int pfd[2] = { -1, -1 };
    assert(pipe(pfd) == 0);
    if (pfd[0] <= 4) {
        int nfd = fcntl(pfd[0], F_DUPFD_CLOEXEC, 5);
        assert(nfd > 4);
        close(pfd[0]);
        pfd[0] = nfd;
    }
    int64_t hp = sts_ctrl_open_fd(304, pfd[0]);
    assert(hp > 0);
    const char *half_cmd = "{\"op\":\"handover\"}";
    assert(write(pfd[1], half_cmd, strlen(half_cmd)) == (ssize_t)strlen(half_cmd));
    close(pfd[1]);
    int pipe_lines = 0, pipe_eof = 0;
    deadline = sth_now_ms() + 5000;
    while (!pipe_eof && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 304 && len >= 10) {
            if (ev[9] == STS_EV_CTRL_LINE) pipe_lines += 1;
            else if (ev[9] == STS_EV_CTRL_EOF) pipe_eof = 1;
        }
        sth_free(ev);
    }
    assert(pipe_eof == 1 && pipe_lines == 0);
    assert(sts_ctrl_close(hp) == 1);
    drain_queue();

    // Closing while peer is open + writing to closed peer (SIGPIPE-safe).
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    if (sv[0] <= 4) {
        int nfd = fcntl(sv[0], F_DUPFD_CLOEXEC, 5);
        assert(nfd > 4);
        close(sv[0]);
        sv[0] = nfd;
    }
    int64_t h2 = sts_ctrl_open_fd(302, sv[0]);
    assert(h2 > 0);
    assert(sts_ctrl_close(h2) == 1);
    close(sv[1]);
    drain_queue();

    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    if (sv[0] <= 4) {
        int nfd = fcntl(sv[0], F_DUPFD_CLOEXEC, 5);
        assert(nfd > 4);
        close(sv[0]);
        sv[0] = nfd;
    }
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
    printf("  [PASS] ctrl channel (fd<=4 reject + line framing + EOF + close + SIGPIPE-safe)\n");
}

// ---------------------------------------------------------------------------
// 4. Process signals (SIGUSR2 + SIGHUP + concurrent watch/unwatch race)
// ---------------------------------------------------------------------------

static void *sig_race_worker(void *arg) {
    uint64_t base = *(uint64_t *)arg;
    for (int i = 0; i < 12; i++) {
        assert(sts_signal_watch(base + (uint64_t)i) == 1);
        assert(sts_signal_unwatch() == 1);
    }
    return NULL;
}

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

    // Concurrent watch/unwatch race under TSan (per-generation pipe isolation).
    pthread_t t1, t2;
    uint64_t b1 = 410, b2 = 450;
    assert(pthread_create(&t1, NULL, sig_race_worker, &b1) == 0);
    assert(pthread_create(&t2, NULL, sig_race_worker, &b2) == 0);
    assert(pthread_join(t1, NULL) == 0);
    assert(pthread_join(t2, NULL) == 0);
    assert(sts_signal_unwatch() == 1);

    drain_queue();
    printf("  [PASS] signals (SIGUSR2, SIGHUP, concurrent watch/unwatch race)\n");
}

// ---------------------------------------------------------------------------
// 5. Advisory file lock (flock_try / flock_unlock / unlink)
// ---------------------------------------------------------------------------

static void test_flock(void) {
    char dir[128], lock_path[256];
    make_temp_dir(dir, sizeof(dir));
    snprintf(lock_path, sizeof(lock_path), "%s/test.lock", dir);

    int64_t h1 = sts_flock_try(lock_path);
    assert(h1 > 0);
    int64_t h2 = sts_flock_try(lock_path);
    assert(h2 == 0);

    assert(sts_flock_unlock(h1) == 1);
    assert(sts_flock_unlock(h1) == 0);

    int64_t h3 = sts_flock_try(lock_path);
    assert(h3 > 0);
    assert(sts_flock_unlock(h3) == 1);

    assert(sts_unlink(lock_path) == 1);
    assert(sts_unlink(lock_path) == 0);
    assert(rmdir(dir) == 0);
    printf("  [PASS] flock (try/contention/unlock/reacquire/unlink)\n");
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
// 8. PTY echo + resize + exit + early close zero-zombie
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
                if (out_len + n < sizeof(out)) { memcpy(out + out_len, ev + 10, n); out_len += n; out[out_len] = '\0'; }
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

    // Early close on PTY child -> must still reap (zero zombie).
    const char *zscript = "exit 0";
    size_t zl = strlen(zscript);
    uint8_t *zargs = (uint8_t *)malloc(3 + zl + 1);
    memcpy(zargs, "-c", 3);
    memcpy(zargs + 3, zscript, zl + 1);
    int64_t zpid = 0;
    int64_t zh = sts_pty_spawn(
        502, "/bin/sh", zargs, (int64_t)(3 + zl + 1), NULL, 0, NULL,
        80, 24, 0, &zpid, err, sizeof(err));
    free(zargs);
    assert(zh > 0 && zpid > 0);
    assert(sts_pty_close(zh) == 1);

    // Opus N2: close a PTY whose interactive child is blocked in `read x` WITHOUT killing it ->
    // closing master_fd immediately sends SIGHUP so child exits and reaper finishes cleanly.
    const char *iscript = "read x; echo got";
    size_t il = strlen(iscript);
    uint8_t *iargs = (uint8_t *)malloc(3 + il + 1);
    memcpy(iargs, "-c", 3);
    memcpy(iargs + 3, iscript, il + 1);
    int64_t ipid = 0;
    int64_t ih = sts_pty_spawn(
        503, "/bin/sh", iargs, (int64_t)(3 + il + 1), NULL, 0, NULL,
        80, 24, 0, &ipid, err, sizeof(err));
    free(iargs);
    assert(ih > 0 && ipid > 0);
    assert(sts_pty_close(ih) == 1);

    for (int i = 0; i < 100; i++) {
        drain_queue();
        if (sts_wait_detached_for_test(50) == 1) break;
    }
    assert(sts_wait_detached_for_test(5000) == 1);
    drain_queue();
    int st = 0;
    assert(waitpid((pid_t)zpid, &st, WNOHANG) == -1 && errno == ECHILD);
    assert(waitpid((pid_t)ipid, &st, WNOHANG) == -1 && errno == ECHILD);
    printf("  [PASS] pty (echo, resize, exit, interactive-close SIGHUP (N2), zero-zombie)\n");
}

// ---------------------------------------------------------------------------
// 9. UDP loopback send/recv + bind NULL/empty rejection + send_once + close
// ---------------------------------------------------------------------------

static void test_udp(void) {
    drain_queue();
    assert(sts_udp_bind(600, NULL, 0, NULL) < 0);
    assert(sts_udp_bind(600, "", 0, NULL) < 0);
    assert(sts_udp_bind(600, "127.0.0.1", -1, NULL) < 0);
    assert(sts_udp_bind(600, "127.0.0.1", 65536, NULL) < 0);

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

    // Ephemeral one-shot send (for mesh/lan.ts multicast/broadcast without persistent bind).
    const char *once = "udp_send_once_ok";
    assert(sts_udp_send_once("127.0.0.1", (int32_t)p2, (const uint8_t *)once, (int64_t)strlen(once)) == 0);
    int got_once = 0;
    deadline = sth_now_ms() + 5000;
    while (!got_once && sth_now_ms() < deadline) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(500, &len);
        if (ev == NULL) continue;
        if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 602 && len >= 14 && ev[9] == STS_EV_UDP_RECV) {
            if (contains_substr((const char *)ev, (size_t)len, once)) got_once = 1;
        }
        sth_free(ev);
    }
    assert(got_once);

    assert(sts_udp_close(u1) == 1);
    assert(sts_udp_close(u2) == 1);
    assert(sts_udp_close(u2) == 0); // double close is a no-op
    // Wait for both UDP reader threads to exit, then drain entire queue and assert strictly 1 closed per ID.
    assert(sts_wait_detached_for_test(5000) == 1);
    int closed_601 = 0, closed_602 = 0;
    for (;;) {
        int64_t len = 0;
        uint8_t *ev = (uint8_t *)sth_wait(0, &len);
        if (ev == NULL) break;
        if (ev[0] == STH_EV_SYS && len == 10 && ev[9] == STS_EV_UDP_CLOSED) {
            uint64_t eid = read_u64_le(ev + 1);
            if (eid == 601) closed_601 += 1;
            if (eid == 602) closed_602 += 1;
        }
        sth_free(ev);
    }
    assert(closed_601 == 1 && closed_602 == 1);
    printf("  [PASS] udp (bind/port guard, loopback send/recv, send_once, explicit UdpClosed)\n");
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

    assert(sts_is_executable("/bin/sh") == 1);
    assert(sts_is_executable("/tmp") == 0);
    assert(sts_is_executable("/nonexistent_sts_path_xyz") == 0);

    char *disk = (char *)sts_disk_of("/tmp", &len);
    assert(disk != NULL && len > 0);
    assert(contains_substr(disk, (size_t)len, "\"free\":"));
    assert(contains_substr(disk, (size_t)len, "\"total\":"));
    sts_free(disk);

    char *ms = (char *)sts_machine_stats(&len);
    assert(ms != NULL && len > 0);
    assert(contains_substr(ms, (size_t)len, "\"cpus\":["));
    assert(contains_substr(ms, (size_t)len, "\"totalmem\":"));
    assert(contains_substr(ms, (size_t)len, "\"freemem\":"));
    assert(contains_substr(ms, (size_t)len, "\"loadavg\":["));
    assert(contains_substr(ms, (size_t)len, "\"uptime\":"));
    sts_free(ms);

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
    setvbuf(stdout, NULL, _IONBF, 0);
    // Run fork-based closed-stdio test BEFORE spawning any threads (TSan-safe).
    test_proc_closed_stdio_stderr();

    // Warm up one joinable thread so runtimes like libtsan initialize any lazy internal
    // background thread before capturing the strict baseline fd & thread counts.
    pthread_t warm;
    assert(pthread_create(&warm, NULL, noop_thread, NULL) == 0);
    assert(pthread_join(warm, NULL) == 0);
#ifdef __linux__
    // Wait briefly for the joined thread's /proc/self/task entry to disappear.
    for (int64_t dl = sth_now_ms() + 200; sth_now_ms() < dl; ) {
        int32_t tc = sth_open_thread_count();
        if (tc <= 1) break;
        sched_yield();
    }
#endif

    int32_t fd_before = sth_open_fd_count();
    int32_t th_before = sth_open_thread_count();
    assert(fd_before >= 3);
    assert(th_before >= 1);

    test_fs_watch_non_recursive();
    test_fs_watch_single_file();
    test_proc_pipes_exit_and_env_strip();
    test_proc_adversarial();
    test_ctrl_channel();
    test_signals();
    test_flock();
    test_peer_process();
    test_process_usage();
    test_pty();
    test_udp();
    test_machine_and_os_info();

    // Test new fs/random/signal primitives: rmdir, realpath, lstat (with ino), truncate, read_range, write_file_mode, random_bytes
    {
        char root[256];
        snprintf(root, sizeof(root), "/tmp/sts_fs_test_%d_%lld", (int)getpid(), (long long)sth_now_ms());
        char sub[300], file_p[320], link_p[320];
        snprintf(sub, sizeof(sub), "%s/a/b", root);
        snprintf(file_p, sizeof(file_p), "%s/data.log", sub);
        snprintf(link_p, sizeof(link_p), "%s/sym", root);
        assert(sts_mkdir_p(sub) == 1);
        const char *msg = "0123456789ABCDEF";
        assert(sts_write_file_mode(file_p, (const uint8_t *)msg, 16, 0600, 0) == 1);
        int64_t rlen = 0;
        char *chunk = (char *)sts_read_range(file_p, 10, 6, &rlen);
        assert(chunk != NULL && rlen == 6 && memcmp(chunk, "ABCDEF", 6) == 0);
        sts_free(chunk);
        int64_t llen = 0;
        char *lst1 = (char *)sts_lstat(file_p, &llen);
        assert(lst1 != NULL && llen > 0 && strncmp(lst1, "file|16|", 8) == 0);
        assert(sts_truncate_in_place(file_p, 0) == 1);
        int64_t llen2 = 0;
        char *lst2 = (char *)sts_lstat(file_p, &llen2);
        assert(lst2 != NULL && strncmp(lst2, "file|0|", 7) == 0);
        sts_free(lst1);
        sts_free(lst2);
        assert(symlink(sub, link_p) == 0);
        int64_t rllen = 0;
        char *rl = (char *)sts_readlink(link_p, &rllen);
        assert(rl != NULL && rllen == (int64_t)strlen(sub) && memcmp(rl, sub, (size_t)rllen) == 0);
        sts_free(rl);
        // Dangling symlink: readlink succeeds, realpath returns NULL.
        char dangle_p[320];
        snprintf(dangle_p, sizeof(dangle_p), "%s/dangle", root);
        assert(symlink("/nonexistent_sts_target_xyz", dangle_p) == 0);
        int64_t dllen = 0;
        char *dl = (char *)sts_readlink(dangle_p, &dllen);
        assert(dl != NULL && dllen == 27 && memcmp(dl, "/nonexistent_sts_target_xyz", 27) == 0);
        sts_free(dl);
        int64_t drplen = 0;
        assert(sts_realpath(dangle_p, &drplen) == NULL);
        assert(sts_unlink(dangle_p) == 1);
        int64_t rplen = 0;
        char *rp = (char *)sts_realpath(link_p, &rplen);
        assert(rp != NULL && rplen > 0);
        sts_free(rp);
        int64_t dlen = 0;
        char *ents = (char *)sts_read_dir(sub, &dlen);
        assert(ents != NULL && dlen > 0);
        sts_free(ents);
        assert(sts_unlink(link_p) == 1);
        assert(sts_unlink(file_p) == 1);
        assert(sts_rmdir(sub) == 1);
        char parent_a[300];
        snprintf(parent_a, sizeof(parent_a), "%s/a", root);
        assert(sts_rmdir(parent_a) == 1);
        assert(sts_rmdir(root) == 1);

        uint8_t r1[24], r2[24];
        memset(r1, 0, sizeof(r1));
        memset(r2, 0, sizeof(r2));
        assert(sts_random_bytes(r1, 24) == 1);
        assert(sts_random_bytes(r2, 24) == 1);
        assert(memcmp(r1, r2, 24) != 0);

        // Verify STS_SIG_STOP / STS_SIG_CONT pause and resume a child without killing it.
        const char *sc_script = "sleep 30";
        size_t sc_len = strlen(sc_script);
        uint8_t *sc_args = (uint8_t *)malloc(3 + sc_len + 1);
        memcpy(sc_args, "-c", 3);
        memcpy(sc_args + 3, sc_script, sc_len + 1);
        int64_t sc_pid = 0;
        char sc_err[128] = "";
        int64_t sc_h = sts_proc_spawn(
            701, "/bin/sh", sc_args, (int64_t)(3 + sc_len + 1), NULL, 0, NULL,
            STS_PROC_NEW_PGID, &sc_pid, sc_err, sizeof(sc_err));
        free(sc_args);
        assert(sc_h > 0 && sc_pid > 0);
        assert(sts_proc_kill_handle(sc_h, STS_SIG_STOP, 1) == 0);
        assert(sts_proc_kill((int32_t)sc_pid, STS_SIG_PROBE, 1) == 0);
        assert(sts_proc_kill_handle(sc_h, STS_SIG_CONT, 1) == 0);
        assert(sts_proc_kill((int32_t)sc_pid, STS_SIG_PROBE, 1) == 0);
        assert(sts_proc_kill_handle(sc_h, STS_SIG_KILL, 1) == 0);
        int64_t sc_dl = sth_now_ms() + 5000;
        int sc_exited = 0;
        while (!sc_exited && sth_now_ms() < sc_dl) {
            int64_t evlen = 0;
            uint8_t *ev = (uint8_t *)sth_wait(200, &evlen);
            if (ev == NULL) continue;
            if (ev[0] == STH_EV_SYS && read_u64_le(ev + 1) == 701 && evlen >= 18 && ev[9] == STS_EV_PROC_EXIT) {
                sc_exited = 1;
            }
            sth_free(ev);
        }
        assert(sc_exited == 1);
        assert(sts_proc_close(sc_h) == 1);
    }

    drain_queue();
    // FD-level TOCTOU-safe read/write under root (`sts_read_under_nofollow` / `sts_write_under_nofollow`).
    {
        char root_dir[256];
        snprintf(root_dir, sizeof(root_dir), "/tmp/sts-nofollow-%d", (int)getpid());
        assert(sts_mkdir_p(root_dir) == 1);
        const uint8_t msg1[] = "hello ";
        const uint8_t msg2[] = "world!";
        assert(sts_write_under_nofollow(root_dir, "sub/a.txt", msg1, 6, 0, 0600, 0) == 1);
        assert(sts_write_under_nofollow(root_dir, "sub/a.txt", msg2, 6, 99, 0600, 1) == -2);
        assert(sts_write_under_nofollow(root_dir, "sub/a.txt", msg2, 6, 6, 0600, 1) == 1);
        // Same-offset retry and shorter overwrite at offset 0 with truncate_end=1.
        assert(sts_write_under_nofollow(root_dir, "sub/a.txt", msg2, 6, 6, 0600, 1) == 1);
        int64_t rlen = 0, rsz = 0;
        void *rbuf = sts_read_under_nofollow(root_dir, "sub/a.txt", 0, 64, &rlen, &rsz);
        assert(rbuf != NULL && rlen == 12 && rsz == 12);
        assert(memcmp(rbuf, "hello world!", 12) == 0);
        sts_free(rbuf);
        assert(sts_write_under_nofollow(root_dir, "sub/a.txt", (const uint8_t *)"hi", 2, 0, 0600, 1) == 1);
        rbuf = sts_read_under_nofollow(root_dir, "sub/a.txt", 0, 64, &rlen, &rsz);
        assert(rbuf != NULL && rlen == 2 && rsz == 2 && memcmp(rbuf, "hi", 2) == 0);
        sts_free(rbuf);
        assert(sts_read_under_nofollow(root_dir, "../etc/passwd", 0, 16, &rlen, &rsz) == NULL);
        char link_path[320];
        snprintf(link_path, sizeof(link_path), "%s/sym.txt", root_dir);
        assert(symlink("/etc/hosts", link_path) == 0);
        assert(sts_read_under_nofollow(root_dir, "sym.txt", 0, 16, &rlen, &rsz) == NULL);
        assert(sts_write_under_nofollow(root_dir, "sym.txt", msg1, 6, 0, 0600, 1) == 0);
        unlink(link_path);
        // FIFO leaf MUST fail immediately via O_NONBLOCK + !S_ISREG without hanging.
        char fifo_path[320];
        snprintf(fifo_path, sizeof(fifo_path), "%s/pipe.fifo", root_dir);
        assert(mkfifo(fifo_path, 0600) == 0);
        assert(sts_read_under_nofollow(root_dir, "pipe.fifo", 0, 16, &rlen, &rsz) == NULL);
        assert(sts_write_under_nofollow(root_dir, "pipe.fifo", msg1, 6, 0, 0600, 1) == 0);
        unlink(fifo_path);
        char sub_file[320], sub_dir[320];
        snprintf(sub_file, sizeof(sub_file), "%s/sub/a.txt", root_dir);
        snprintf(sub_dir, sizeof(sub_dir), "%s/sub", root_dir);
        unlink(sub_file);
        rmdir(sub_dir);
        rmdir(root_dir);
    }

    // 10. Atomic sts_mkdir_mode, sts_symlink, sts_getcwd, sts_read_file_strict, sts_write_file_atomic
    {
        int64_t cwd_len = 0;
        char *cwd = (char *)sts_getcwd(&cwd_len);
        assert(cwd != NULL && cwd_len > 0 && cwd[0] == '/');
        sts_free(cwd);

        char tmp_dir[256];
        snprintf(tmp_dir, sizeof(tmp_dir), "/tmp/sts_cli_prims_%ld", (long)getpid());
        rmdir(tmp_dir);
        assert(sts_mkdir_mode(tmp_dir, 0700) == 1);
        assert(sts_mkdir_mode(tmp_dir, 0700) == -2); // EEXIST
        struct stat dst;
        assert(stat(tmp_dir, &dst) == 0 && (dst.st_mode & 0777) == 0700);

        char sec_file[320];
        snprintf(sec_file, sizeof(sec_file), "%s/secret.bin", tmp_dir);
        const uint8_t bin_payload[4] = { 0x00, 0xFF, 0x7F, 0x80 };
        assert(sts_write_file_atomic(sec_file, bin_payload, 4, 0600) == 1);
        assert(stat(sec_file, &dst) == 0 && (dst.st_mode & 0777) == 0600 && dst.st_size == 4);

        int64_t flen = 0;
        int32_t ferr = 0;
        uint8_t *got = (uint8_t *)sts_read_file_strict(sec_file, &flen, &ferr);
        assert(got != NULL && flen == 4 && ferr == 0 && memcmp(got, bin_payload, 4) == 0);
        sts_free(got);

        char missing_file[320];
        snprintf(missing_file, sizeof(missing_file), "%s/missing.bin", tmp_dir);
        assert(sts_read_file_strict(missing_file, &flen, &ferr) == NULL && ferr == 1); // ENOENT

        if (geteuid() != 0) {
            assert(chmod(sec_file, 0000) == 0);
            assert(sts_read_file_strict(sec_file, &flen, &ferr) == NULL && ferr == 2); // EACCES
            assert(chmod(sec_file, 0600) == 0);
        }

        char sym_p[320];
        snprintf(sym_p, sizeof(sym_p), "%s/link.bin", tmp_dir);
        assert(sts_symlink("./secret.bin", sym_p, 0) == 1);
        assert(sts_is_dir_symlink(sym_p) == 0);
        int64_t rl_len = 0;
        char *rl = (char *)sts_readlink(sym_p, &rl_len);
        assert(rl != NULL && rl_len == 12 && strcmp(rl, "./secret.bin") == 0);
        sts_free(rl);

        // Long basename (240 B & 255 B = NAME_MAX) atomic write must never fail with ENAMETOOLONG.
        const size_t long_lens[2] = { 240, 255 };
        for (int li = 0; li < 2; li++) {
            size_t blen = long_lens[li];
            char bname[256];
            memset(bname, 'x', blen - 4);
            memcpy(bname + blen - 4, ".bin", 4);
            bname[blen] = '\0';
            char lpath[640];
            snprintf(lpath, sizeof(lpath), "%s/%s", tmp_dir, bname);
            assert(sts_write_file_atomic(lpath, bin_payload, 4, -1) == 1);
            int64_t llen = 0;
            int32_t lerr = 0;
            uint8_t *lgot = (uint8_t *)sts_read_file_strict(lpath, &llen, &lerr);
            assert(lgot != NULL && llen == 4 && lerr == 0 && memcmp(lgot, bin_payload, 4) == 0);
            sts_free(lgot);
            assert(unlink(lpath) == 0);
        }

        // Negative mode (-1) must respect process umask without fchmod override.
        {
            char um_file[320];
            snprintf(um_file, sizeof(um_file), "%s/umask_test.cfg", tmp_dir);
            mode_t saved_um = umask(0077);
            assert(sts_write_file_atomic(um_file, bin_payload, 4, -1) == 1);
            assert(stat(um_file, &dst) == 0 && (dst.st_mode & 0777) == 0600);
            assert(unlink(um_file) == 0);
            umask(0022);
            assert(sts_write_file_atomic(um_file, bin_payload, 4, -1) == 1);
            assert(stat(um_file, &dst) == 0 && (dst.st_mode & 0777) == 0644);
            assert(unlink(um_file) == 0);
            umask(saved_um);
        }

        unlink(sym_p);
        unlink(sec_file);
        rmdir(tmp_dir);
    }

    assert(sts_wait_detached_for_test(5000) == 1);
    drain_queue();

#ifdef __linux__
    // Detached threads call sts_detached_end() right before returning; allow the kernel
    // a moment to remove their /proc/self/task entries.
    for (int64_t dl = sth_now_ms() + 500; sth_now_ms() < dl; ) {
        if (sth_open_thread_count() <= th_before) break;
        sched_yield();
    }
#endif

    int32_t fd_after = sth_open_fd_count();
    int32_t th_after = sth_open_thread_count();
#ifdef __APPLE__
    // On macOS, CoreServices FSEvents uses libdispatch whose internal Mach workqueue
    // pool may retain 1-2 idle worker threads briefly; exact detached-worker count == 0
    // is already proven by sts_wait_detached_for_test(5000) == 1 above.
    if (fd_after != fd_before || th_after > th_before + 4) {
        fprintf(stderr, "LEAK DETECTED (macOS): fds %d -> %d, threads %d -> %d\n",
                fd_before, fd_after, th_before, th_after);
        return 1;
    }
#else
    if (fd_after != fd_before || th_after > th_before) {
        fprintf(stderr, "LEAK DETECTED: fds %d -> %d, threads %d -> %d\n",
                fd_before, fd_after, th_before, th_after);
        return 1;
    }
#endif
    printf("station_sys_test: ALL PASSED (fds=%d->%d, threads=%d->%d)\n",
           fd_before, fd_after, th_before, th_after);
    return 0;
}
#endif
