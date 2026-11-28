// Thin C bridge registering the compiled Pion `core_runtime` driver callbacks
// into `packages/core_abi/native/core_pion.c` (`apps/mbui/src/host/core_api.h`),
// wiring native event-driven wake (`mb_core_register_wake` / `mb_core_wake`),
// and forwarding screen/media callbacks directly in pure C without touching the Pion heap.

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#include "core_api.h"

// ── Process-lifetime exclusive data-directory ownership lock (`<dir>/.core.lock`) ──
// Guarantees at most ONE live `core_runtime` instance owns `<dir>` at any time:
// - Non-blocking `flock(LOCK_EX | LOCK_NB)` (POSIX) / UTF-16 `CreateFileW` + `LockFileEx` (Windows).
// - Second instance fails fast (`0` -> `data_dir_locked`) without blocking or touching any DB.
// - Released on `pion_core_runtime_stop()` or automatically by the OS kernel on crash / `SIGKILL`.
#define PION_ACCOUNTS_MAX_BYTES (16u * 1024u * 1024u)

static _Atomic int64_t g_owner_lock_next_id = 1;
static _Atomic int64_t g_owner_lock_active_id = 0;
#ifdef _WIN32
static HANDLE g_owner_lock_handle = INVALID_HANDLE_VALUE;
#else
static int g_owner_lock_fd = -1;
#endif

static uint8_t *g_accts_buf = NULL;
static size_t g_accts_len = 0;
static _Atomic uint64_t g_accts_write_seq = 0;
static _Atomic int g_test_fail_dir_fsync = 0;

void pion_core_test_set_fail_dir_fsync(int32_t enable) {
    atomic_store_explicit(&g_test_fail_dir_fsync, enable != 0 ? 1 : 0, memory_order_release);
}

static void join_dir_file(char *out, size_t cap, const char *dir, size_t dlen, const char *name) {
    size_t pos = dlen;
    if (pos + 2 + strlen(name) >= cap) {
        out[0] = '\0';
        return;
    }
    memcpy(out, dir, pos);
#ifdef _WIN32
    if (pos > 0 && out[pos - 1] != '/' && out[pos - 1] != '\\') {
        out[pos++] = '/';
    }
#else
    if (pos > 0 && out[pos - 1] != '/') {
        out[pos++] = '/';
    }
#endif
    size_t nlen = strlen(name);
    memcpy(out + pos, name, nlen + 1);
}

#ifdef _WIN32
static int ensure_dir_recursive_wide(const wchar_t *wdir) {
    if (wdir == NULL || wdir[0] == L'\0') {
        return -1;
    }
    size_t n = wcslen(wdir);
    if (n >= 4096) {
        return -1;
    }
    wchar_t buf[4096];
    memcpy(buf, wdir, (n + 1) * sizeof(wchar_t));
    while (n > 1 && (buf[n - 1] == L'/' || buf[n - 1] == L'\\')) {
        if (n == 3 && buf[1] == L':') {
            break;
        }
        buf[--n] = L'\0';
    }
    size_t start = 0;
    if (n >= 2 && buf[1] == L':') {
        start = (n >= 3 && (buf[2] == L'/' || buf[2] == L'\\')) ? 3 : 2;
    } else if (n >= 2 && (buf[0] == L'\\' || buf[0] == L'/') && (buf[1] == L'\\' || buf[1] == L'/')) {
        // UNC prefix: skip `\\server\share\`
        size_t p = 2;
        int parts = 0;
        while (p < n && parts < 2) {
            while (p < n && buf[p] != L'\\' && buf[p] != L'/') p++;
            while (p < n && (buf[p] == L'\\' || buf[p] == L'/')) p++;
            parts++;
        }
        start = p;
    } else if (buf[0] == L'/' || buf[0] == L'\\') {
        start = 1;
    }
    for (size_t i = start; i <= n; i++) {
        if (i == n || buf[i] == L'/' || buf[i] == L'\\') {
            if (i == start) {
                continue;
            }
            wchar_t saved = buf[i];
            buf[i] = L'\0';
            if (!CreateDirectoryW(buf, NULL)) {
                DWORD err = GetLastError();
                if (err != ERROR_ALREADY_EXISTS) {
                    buf[i] = saved;
                    return -1;
                }
            }
            buf[i] = saved;
        }
    }
    return 0;
}
#else
static int ensure_dir_recursive_posix(const char *dir) {
    if (dir == NULL || dir[0] == '\0') {
        return -1;
    }
    size_t n = strlen(dir);
    if (n >= 4096) {
        return -1;
    }
    char buf[4096];
    memcpy(buf, dir, n + 1);
    while (n > 1 && buf[n - 1] == '/') {
        buf[--n] = '\0';
    }
    size_t start = (buf[0] == '/') ? 1 : 0;
    for (size_t i = start; i <= n; i++) {
        if (i == n || buf[i] == '/') {
            if (i == start) {
                continue;
            }
            char saved = buf[i];
            buf[i] = '\0';
            if (mkdir(buf, 0700) != 0 && errno != EEXIST) {
                buf[i] = saved;
                return -1;
            }
            buf[i] = saved;
        }
    }
    return 0;
}

static int fsync_fd_strict(int fd) {
    int rc;
    do {
        rc = fsync(fd);
    } while (rc != 0 && errno == EINTR);
    return (rc == 0) ? 0 : -1;
}

static int fsync_dir_strict(const char *dir_path) {
    if (atomic_load_explicit(&g_test_fail_dir_fsync, memory_order_acquire) != 0) {
        errno = EIO;
        return -1;
    }
    int dfd = open(dir_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        return -1;
    }
    int rc = fsync_fd_strict(dfd);
    int saved = errno;
    if (close(dfd) != 0 && rc == 0) {
        return -1;
    }
    errno = saved;
    return rc;
}
#endif

// Acquire process-lifetime exclusive ownership of `<dir>/.core.lock` (0ms non-blocking):
// - returns handle >= 1 on success
// - returns 0 if already owned by another core instance (in-process or another process)
// - returns -1 on I/O, read-only (`EROFS`), or invalid path error
int64_t pion_core_dir_owner_lock_acquire(const char *dir, int64_t dir_len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840) {
        return -1;
    }
    int64_t expected = 0;
    if (!atomic_compare_exchange_strong(&g_owner_lock_active_id, &expected, -1)) {
        return 0;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';

    char lock_path[4096];
    join_dir_file(lock_path, sizeof(lock_path), dir_copy, (size_t)dir_len, ".core.lock");
    if (lock_path[0] == '\0') {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }

#ifdef _WIN32
    wchar_t wdir[3840];
    wchar_t wlock[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, dir_copy, -1, wdir, 3840) <= 0 ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, lock_path, -1, wlock, 4096) <= 0) {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }
    if (ensure_dir_recursive_wide(wdir) != 0) {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }
    HANDLE h = CreateFileW(
        wlock,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    if (h == INVALID_HANDLE_VALUE) {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &ov)) {
        DWORD err = GetLastError();
        CloseHandle(h);
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return (err == ERROR_LOCK_VIOLATION) ? 0 : -1;
    }
    g_owner_lock_handle = h;
#else
    if (ensure_dir_recursive_posix(dir_copy) != 0) {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }
    int fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int e = errno;
        close(fd);
        atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
        return (e == EWOULDBLOCK || e == EAGAIN) ? 0 : -1;
    }
    g_owner_lock_fd = fd;
#endif
    int64_t id = atomic_fetch_add_explicit(&g_owner_lock_next_id, 1, memory_order_relaxed);
    if (id <= 0) {
        id = 1;
    }
    atomic_store_explicit(&g_owner_lock_active_id, id, memory_order_release);
    return id;
}

void pion_core_dir_owner_lock_release(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    int64_t expected = handle;
    if (!atomic_compare_exchange_strong(&g_owner_lock_active_id, &expected, -1)) {
        return;
    }
#ifdef _WIN32
    if (g_owner_lock_handle != INVALID_HANDLE_VALUE) {
        HANDLE h = g_owner_lock_handle;
        g_owner_lock_handle = INVALID_HANDLE_VALUE;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        (void)UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
        (void)CloseHandle(h);
    }
#else
    if (g_owner_lock_fd >= 0) {
        int fd = g_owner_lock_fd;
        g_owner_lock_fd = -1;
        (void)flock(fd, LOCK_UN);
        (void)close(fd);
    }
#endif
    if (g_accts_buf != NULL) {
        free(g_accts_buf);
        g_accts_buf = NULL;
    }
    g_accts_len = 0;
    atomic_store_explicit(&g_owner_lock_active_id, 0, memory_order_release);
}

// ── Synchronous atomic `<dir>/accounts` read / write / inplace-shrink / remove under exclusive `.core.lock` ──
// Returns 1 = Found (use `data`/`len`), 0 = Absent (`ENOENT`), -1 = I/O, >16 MiB, or invalid path error.
int32_t pion_core_accounts_read(const char *dir, int64_t dir_len) {
    if (g_accts_buf != NULL) {
        free(g_accts_buf);
        g_accts_buf = NULL;
    }
    g_accts_len = 0;
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840) {
        return -1;
    }
    char accts_path[4096];
    join_dir_file(accts_path, sizeof(accts_path), dir, (size_t)dir_len, "accounts");
    if (accts_path[0] == '\0') {
        return -1;
    }
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, accts_path, -1, wpath, 4096) <= 0) {
        return -1;
    }
    HANDLE h = CreateFileW(
        wpath,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
    }
    size_t cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        CloseHandle(h);
        return -1;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= PION_ACCOUNTS_MAX_BYTES) {
                uint8_t probe = 0;
                DWORD got_extra = 0;
                if (!ReadFile(h, &probe, 1, &got_extra, NULL) || got_extra > 0) {
                    free(buf);
                    CloseHandle(h);
                    return -1;
                }
                break;
            }
            size_t ncap = cap * 2;
            if (ncap > PION_ACCOUNTS_MAX_BYTES) {
                ncap = PION_ACCOUNTS_MAX_BYTES;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, ncap);
            if (nbuf == NULL) {
                free(buf);
                CloseHandle(h);
                return -1;
            }
            buf = nbuf;
            cap = ncap;
        }
        DWORD got = 0;
        if (!ReadFile(h, buf + total, (DWORD)(cap - total), &got, NULL)) {
            free(buf);
            CloseHandle(h);
            return -1;
        }
        if (got == 0) {
            break;
        }
        total += (size_t)got;
    }
    CloseHandle(h);
    g_accts_buf = buf;
    g_accts_len = total;
    return 1;
#else
    int fd = open(accts_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return (errno == ENOENT) ? 0 : -1;
    }
    size_t cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        close(fd);
        return -1;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= PION_ACCOUNTS_MAX_BYTES) {
                uint8_t probe = 0;
                ssize_t extra;
                do {
                    extra = read(fd, &probe, 1);
                } while (extra < 0 && errno == EINTR);
                if (extra != 0) {
                    free(buf);
                    close(fd);
                    return -1;
                }
                break;
            }
            size_t ncap = cap * 2;
            if (ncap > PION_ACCOUNTS_MAX_BYTES) {
                ncap = PION_ACCOUNTS_MAX_BYTES;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, ncap);
            if (nbuf == NULL) {
                free(buf);
                close(fd);
                return -1;
            }
            buf = nbuf;
            cap = ncap;
        }
        ssize_t n = read(fd, buf + total, cap - total);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buf);
            close(fd);
            return -1;
        }
        if (n == 0) {
            break;
        }
        total += (size_t)n;
    }
    close(fd);
    g_accts_buf = buf;
    g_accts_len = total;
    return 1;
#endif
}

const uint8_t *pion_core_accounts_data(void) {
    return g_accts_buf;
}

int64_t pion_core_accounts_len(void) {
    return (int64_t)g_accts_len;
}

int32_t pion_core_accounts_write_atomic(
    const char *dir,
    int64_t dir_len,
    const uint8_t *bytes,
    int64_t len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840 || len < 0 ||
        (uint64_t)len > (uint64_t)PION_ACCOUNTS_MAX_BYTES || (len > 0 && bytes == NULL)) {
        return -1;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';

    char accts_path[4096];
    join_dir_file(accts_path, sizeof(accts_path), dir_copy, (size_t)dir_len, "accounts");
    uint64_t seq = atomic_fetch_add_explicit(&g_accts_write_seq, 1, memory_order_relaxed) + 1;
    char tmp_name[128];
#ifdef _WIN32
    snprintf(tmp_name, sizeof(tmp_name), "accounts.partial.%lu.%llu",
             (unsigned long)GetCurrentProcessId(), (unsigned long long)seq);
#else
    snprintf(tmp_name, sizeof(tmp_name), "accounts.partial.%ld.%llu",
             (long)getpid(), (unsigned long long)seq);
#endif
    char tmp_path[4096];
    join_dir_file(tmp_path, sizeof(tmp_path), dir_copy, (size_t)dir_len, tmp_name);
    if (accts_path[0] == '\0' || tmp_path[0] == '\0') {
        return -1;
    }

#ifdef _WIN32
    wchar_t wdir[3840];
    wchar_t wtmp[4096];
    wchar_t wdst[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, dir_copy, -1, wdir, 3840) <= 0 ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, tmp_path, -1, wtmp, 4096) <= 0 ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, accts_path, -1, wdst, 4096) <= 0) {
        return -1;
    }
    if (ensure_dir_recursive_wide(wdir) != 0) {
        return -1;
    }
    (void)DeleteFileW(wtmp);
    HANDLE h = CreateFileW(wtmp, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    size_t off = 0;
    while (off < (size_t)len) {
        DWORD wrote = 0;
        if (!WriteFile(h, bytes + off, (DWORD)((size_t)len - off), &wrote, NULL) || wrote == 0) {
            CloseHandle(h);
            (void)DeleteFileW(wtmp);
            return -1;
        }
        off += (size_t)wrote;
    }
    if (!FlushFileBuffers(h)) {
        CloseHandle(h);
        (void)DeleteFileW(wtmp);
        return -1;
    }
    CloseHandle(h);
    if (!MoveFileExW(wtmp, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        (void)DeleteFileW(wtmp);
        return -1;
    }
    return 0;
#else
    if (ensure_dir_recursive_posix(dir_copy) != 0) {
        return -1;
    }
    (void)unlink(tmp_path);
    int fd = open(tmp_path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        return -1;
    }
    size_t off = 0;
    while (off < (size_t)len) {
        ssize_t n = write(fd, bytes + off, (size_t)len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            (void)unlink(tmp_path);
            return -1;
        }
        off += (size_t)n;
    }
    if (fsync_fd_strict(fd) != 0) {
        close(fd);
        (void)unlink(tmp_path);
        return -1;
    }
    if (close(fd) != 0) {
        (void)unlink(tmp_path);
        return -1;
    }
    if (rename(tmp_path, accts_path) != 0) {
        (void)unlink(tmp_path);
        return -1;
    }
    if (fsync_dir_strict(dir_copy) != 0) {
        return -2;
    }
    return 0;
#endif
}

// Zero-block atomic removal of `<dir>/accounts` (used as ENOSPC-safe fallback when clearing the last account).
// Returns 0 = confirmed durable, -1 = unlink failed before removal, -2 = unlink succeeded but dir fsync failed.
int32_t pion_core_accounts_remove_atomic(const char *dir, int64_t dir_len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840) {
        return -1;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';
    char accts_path[4096];
    join_dir_file(accts_path, sizeof(accts_path), dir_copy, (size_t)dir_len, "accounts");
    if (accts_path[0] == '\0') {
        return -1;
    }
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, accts_path, -1, wpath, 4096) <= 0) {
        return -1;
    }
    if (DeleteFileW(wpath)) {
        return 0;
    }
    DWORD err = GetLastError();
    return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
#else
    if (unlink(accts_path) != 0 && errno != ENOENT) {
        return -1;
    }
    if (fsync_dir_strict(dir_copy) != 0) {
        return -2;
    }
    return 0;
#endif
}

// Explicitly fsync `<dir>` to reconcile a post-replace `-2` (uncertain dir fsync) state.
int32_t pion_core_accounts_sync_dir(const char *dir, int64_t dir_len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840) {
        return -1;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';
#ifdef _WIN32
    if (atomic_load_explicit(&g_test_fail_dir_fsync, memory_order_acquire) != 0) {
        return -1;
    }
    wchar_t wdir[3840];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, dir_copy, -1, wdir, 3840) <= 0) {
        return -1;
    }
    DWORD attrs = GetFileAttributesW(wdir);
    return (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) ? 0 : -1;
#else
    return (fsync_dir_strict(dir_copy) == 0) ? 0 : -1;
#endif
}

void pion_core_log_warn(const char *msg, int64_t len) {
    if (msg != NULL && len > 0) {
        fprintf(stderr, "[pion-core] %.*s\n", (int)len, msg);
    }
}

int64_t pion_core_wall_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return 0;
    }
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000L);
}

int32_t pion_core_utc_offset_min(int64_t ms) {
    time_t sec = (time_t)(ms / 1000LL);
    struct tm lt;
    if (localtime_r(&sec, &lt) == NULL) {
        return 0;
    }
    return (int32_t)(lt.tm_gmtoff / 60L);
}

// Exported by `packages/core_runtime/src/core_runtime.pion` (`pub extern "C" fn`; Pion `Int` is `int32_t`)
extern void pion_pkg_core_runtime_init_consts(void);
extern int32_t pion_core_runtime_start(
    const char *data_dir,
    int64_t data_dir_len,
    const char *cloud_origin,
    int64_t cloud_origin_len,
    int32_t beta);
extern void pion_core_runtime_send(
    const char *json,
    int64_t len,
    const uint8_t *bytes,
    int64_t blen);
extern void pion_core_runtime_stop(void);
extern int64_t pion_core_runtime_on_wake(void);

// Exported by `pion/base/packages/shell/native/shell_pion.c` (pure C, thread-safe)
typedef void (*bsh_say_fn)(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len);
typedef uint8_t (*bsh_media_fn)(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len);

extern void bsh_on_wake(void (*woke)(void *), void *ctx);
extern void bsh_on_say(bsh_say_fn say, void *ctx);
extern void bsh_on_media(bsh_media_fn media, void *ctx);
extern int32_t bsh_screen_ack(double call, double ts);
extern int32_t bsh_screen_input(double call, const uint8_t *json, size_t len);

// Driver & native wake ABI from `packages/core_abi/native/core_pion.c`
typedef void (*mb_core_driver_start_fn)(const char *, const char *, int, void *);
typedef void (*mb_core_driver_send_fn)(const char *, size_t, const uint8_t *, size_t, void *);
typedef void (*mb_core_driver_stop_fn)(void *);
typedef int (*mb_core_driver_screen_ack_fn)(double, double, void *);
typedef int (*mb_core_driver_screen_input_fn)(double, const uint8_t *, size_t, void *);
typedef int64_t (*mb_core_driver_wake_fn)(void *user_ctx);

typedef struct mb_core_driver {
    mb_core_driver_start_fn on_start;
    mb_core_driver_send_fn on_send;
    mb_core_driver_stop_fn on_stop;
    mb_core_driver_screen_ack_fn on_screen_ack;
    mb_core_driver_screen_input_fn on_screen_input;
    void *user_ctx;
} mb_core_driver_t;

extern void mb_core_register_driver(const mb_core_driver_t *driver);
extern void mb_core_register_wake(mb_core_driver_wake_fn on_wake, void *user_ctx);
extern void mb_core_wake(void);
extern int mb_core_emit(const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len);

static pthread_once_t g_pion_consts_once = PTHREAD_ONCE_INIT;
static _Atomic int g_bridge_active = 0;

static void init_pion_consts_once(void) {
    pion_pkg_core_runtime_init_consts();
}

static int64_t bridge_on_wake(void *user_ctx) {
    (void)user_ctx;
    if (!atomic_load(&g_bridge_active)) {
        return -1;
    }
    return pion_core_runtime_on_wake();
}

static void bridge_on_shell_wake(void *ctx) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return;
    }
    mb_core_wake();
}

static void bridge_on_shell_say(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return;
    }
    (void)mb_core_emit((const char *)json, json_len, bytes, bytes_len);
}

static uint8_t bridge_on_shell_media(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return 0;
    }
    return mb_core_deliver_media(call, (int)kind, (int)key, seq, ts, bytes, bytes_len) ? 1 : 0;
}

static void bridge_on_start(const char *data_dir, const char *cloud_origin, int beta, void *user_ctx) {
    (void)user_ctx;
    (void)pthread_once(&g_pion_consts_once, init_pion_consts_once);
    atomic_store(&g_bridge_active, 1);
    int64_t dlen = data_dir != NULL ? (int64_t)strlen(data_dir) : 0;
    int64_t clen = cloud_origin != NULL ? (int64_t)strlen(cloud_origin) : 0;
    int32_t ok = pion_core_runtime_start(data_dir, dlen, cloud_origin, clen, (int32_t)beta);
    if (ok != 0) {
        bsh_on_wake(bridge_on_shell_wake, NULL);
        bsh_on_say(bridge_on_shell_say, NULL);
        bsh_on_media(bridge_on_shell_media, NULL);
        mb_core_wake();
    }
}

static void bridge_on_send(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *user_ctx) {
    (void)user_ctx;
    pion_core_runtime_send(json, (int64_t)len, bytes, (int64_t)blen);
}

static void bridge_on_stop(void *user_ctx) {
    (void)user_ctx;
    atomic_store(&g_bridge_active, 0);
    bsh_on_media(NULL, NULL);
    bsh_on_say(NULL, NULL);
    bsh_on_wake(NULL, NULL);
    pion_core_runtime_stop();
}

static int bridge_on_screen_ack(double call, double ts, void *user_ctx) {
    (void)user_ctx;
    return (int)bsh_screen_ack(call, ts);
}

static int bridge_on_screen_input(double call, const uint8_t *json, size_t len, void *user_ctx) {
    (void)user_ctx;
    return (int)bsh_screen_input(call, json, len);
}

void mb_core_attach_pion_runtime(void) {
    mb_core_driver_t drv = {
        bridge_on_start,
        bridge_on_send,
        bridge_on_stop,
        bridge_on_screen_ack,
        bridge_on_screen_input,
        NULL,
    };
    mb_core_register_driver(&drv);
    mb_core_register_wake(bridge_on_wake, NULL);
}
