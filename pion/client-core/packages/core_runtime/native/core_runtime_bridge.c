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

// Synchronous atomic C transaction for `<dir>/accounts` (`client/shell/src/fs_ops.rs:144-153`):
// - Acquires a process-wide mutex (`pthread_mutex_t` / `CRITICAL_SECTION`) AND an exclusive OS
//   file lock on `<dir>/.accounts.lock` (`flock` / UTF-16 `CreateFileW` + `LockFileEx`).
// - Synchronously reads `<dir>/accounts` into an owned buffer distinguishing Found (1),
//   Absent (0), and ReadError (-1).
// - Returns a strictly monotonic logical `tx_id >= 1` (NEVER exposing raw OS fd/HANDLE numbers).
// - `commit` writes `<dir>/accounts.partial.<pid>.<tx_id>` (`0600`), `fsync`s, and atomically
//   renames over `<dir>/accounts` BEFORE releasing the OS lock (zero Rust background disk thread!).
// - `end(tx_id)` validates `tx_id == active_id` before releasing; stale or duplicate `tx_id` calls
//   are guaranteed no-ops and can NEVER release a newer transaction's lock!
// - Because every transaction is synchronous and non-yielding, `mb_core_stop()` can NEVER strand
//   a held mutex, OS file lock, or cross-session semaphore.

#define ACCOUNTS_MAX_BYTES (16 * 1024 * 1024)

#ifdef _WIN32
static INIT_ONCE g_accts_tx_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_accts_tx_cs;
static BOOL CALLBACK init_accts_tx_cs_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    InitializeCriticalSection(&g_accts_tx_cs);
    return TRUE;
}
static int accts_mu_trylock(void) {
    InitOnceExecuteOnce(&g_accts_tx_once, init_accts_tx_cs_cb, NULL, NULL);
    return TryEnterCriticalSection(&g_accts_tx_cs) ? 0 : -1;
}
static void accts_mu_unlock(void) {
    LeaveCriticalSection(&g_accts_tx_cs);
}
#else
static pthread_mutex_t g_accts_tx_mu = PTHREAD_MUTEX_INITIALIZER;
static int accts_mu_trylock(void) {
    return pthread_mutex_trylock(&g_accts_tx_mu) == 0 ? 0 : -1;
}
static void accts_mu_unlock(void) {
    pthread_mutex_unlock(&g_accts_tx_mu);
}
#endif

static _Atomic int64_t g_accts_tx_next_id = 1;
static _Atomic int64_t g_accts_tx_active_id = 0;
static char g_accts_tx_dir[3840];
static size_t g_accts_tx_dir_len = 0;
#ifdef _WIN32
static HANDLE g_accts_tx_lock_handle = INVALID_HANDLE_VALUE;
#else
static int g_accts_tx_lock_fd = -1;
#endif
static int32_t g_accts_tx_status = 0;
static uint8_t *g_accts_tx_buf = NULL;
static size_t g_accts_tx_len = 0;

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

static void accts_tx_reset_buf(void) {
    if (g_accts_tx_buf != NULL) {
        free(g_accts_tx_buf);
        g_accts_tx_buf = NULL;
    }
    g_accts_tx_len = 0;
    g_accts_tx_status = 0;
}

static void accts_tx_read_file_locked(const char *accts_path) {
    accts_tx_reset_buf();
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, accts_path, -1, wpath, 4096) <= 0) {
        g_accts_tx_status = -1;
        return;
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
        g_accts_tx_status = (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
        return;
    }
    size_t cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        CloseHandle(h);
        g_accts_tx_status = -1;
        return;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= ACCOUNTS_MAX_BYTES) {
                free(buf);
                CloseHandle(h);
                g_accts_tx_status = -1;
                return;
            }
            size_t ncap = cap * 2;
            if (ncap > ACCOUNTS_MAX_BYTES) {
                ncap = ACCOUNTS_MAX_BYTES;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, ncap);
            if (nbuf == NULL) {
                free(buf);
                CloseHandle(h);
                g_accts_tx_status = -1;
                return;
            }
            buf = nbuf;
            cap = ncap;
        }
        DWORD got = 0;
        if (!ReadFile(h, buf + total, (DWORD)(cap - total), &got, NULL)) {
            free(buf);
            CloseHandle(h);
            g_accts_tx_status = -1;
            return;
        }
        if (got == 0) {
            break;
        }
        total += (size_t)got;
    }
    CloseHandle(h);
    g_accts_tx_buf = buf;
    g_accts_tx_len = total;
    g_accts_tx_status = 1;
#else
    int fd = open(accts_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        g_accts_tx_status = (errno == ENOENT) ? 0 : -1;
        return;
    }
    size_t cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        close(fd);
        g_accts_tx_status = -1;
        return;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= ACCOUNTS_MAX_BYTES) {
                free(buf);
                close(fd);
                g_accts_tx_status = -1;
                return;
            }
            size_t ncap = cap * 2;
            if (ncap > ACCOUNTS_MAX_BYTES) {
                ncap = ACCOUNTS_MAX_BYTES;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, ncap);
            if (nbuf == NULL) {
                free(buf);
                close(fd);
                g_accts_tx_status = -1;
                return;
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
            g_accts_tx_status = -1;
            return;
        }
        if (n == 0) {
            break;
        }
        total += (size_t)n;
    }
    close(fd);
    g_accts_tx_buf = buf;
    g_accts_tx_len = total;
    g_accts_tx_status = 1;
#endif
}

// Non-blocking attempt to start an atomic `<dir>/accounts` transaction:
// - returns tx_id >= 1 on success (holds process mutex + exclusive OS file lock)
// - returns 0 if currently contended (process mutex or OS file lock held elsewhere)
// - returns -1 on I/O or invalid path error
int64_t pion_core_accounts_tx_try_begin(const char *dir, int64_t dir_len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= (int64_t)sizeof(g_accts_tx_dir)) {
        return -1;
    }
    if (accts_mu_trylock() != 0) {
        return 0;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';

    char lock_path[4096];
    join_dir_file(lock_path, sizeof(lock_path), dir_copy, (size_t)dir_len, ".accounts.lock");
    if (lock_path[0] == '\0') {
        accts_mu_unlock();
        return -1;
    }

#ifdef _WIN32
    wchar_t wdir[3840];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, dir_copy, -1, wdir, 3840) > 0) {
        (void)CreateDirectoryW(wdir, NULL);
    }
    wchar_t wlock[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, lock_path, -1, wlock, 4096) <= 0) {
        accts_mu_unlock();
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
        accts_mu_unlock();
        return -1;
    }
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &ov)) {
        DWORD err = GetLastError();
        CloseHandle(h);
        accts_mu_unlock();
        return (err == ERROR_LOCK_VIOLATION) ? 0 : -1;
    }
    g_accts_tx_lock_handle = h;
#else
    (void)mkdir(dir_copy, 0700);
    int fd = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) {
        accts_mu_unlock();
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int e = errno;
        close(fd);
        accts_mu_unlock();
        return (e == EWOULDBLOCK || e == EAGAIN) ? 0 : -1;
    }
    g_accts_tx_lock_fd = fd;
#endif

    memcpy(g_accts_tx_dir, dir_copy, (size_t)dir_len + 1);
    g_accts_tx_dir_len = (size_t)dir_len;

    char accts_path[4096];
    join_dir_file(accts_path, sizeof(accts_path), g_accts_tx_dir, g_accts_tx_dir_len, "accounts");
    accts_tx_read_file_locked(accts_path);

    int64_t tx_id = atomic_fetch_add_explicit(&g_accts_tx_next_id, 1, memory_order_relaxed);
    atomic_store_explicit(&g_accts_tx_active_id, tx_id, memory_order_release);
    return tx_id;
}

// Bounded short-backoff wrapper ONLY for synchronous startup reads (<= 500ms total; NEVER blocks forever):
// - returns tx_id >= 1 on success, 0 on busy timeout, -1 on I/O error
int64_t pion_core_accounts_tx_begin_bounded(const char *dir, int64_t dir_len, int32_t max_wait_ms) {
    if (max_wait_ms < 0) {
        max_wait_ms = 0;
    }
    if (max_wait_ms > 500) {
        max_wait_ms = 500;
    }
    int32_t waited = 0;
    int32_t step = 10;
    for (;;) {
        int64_t tx_id = pion_core_accounts_tx_try_begin(dir, dir_len);
        if (tx_id != 0 || waited >= max_wait_ms) {
            return tx_id;
        }
        int32_t sleep_ms = step;
        if (waited + sleep_ms > max_wait_ms) {
            sleep_ms = max_wait_ms - waited;
        }
#ifdef _WIN32
        Sleep((DWORD)sleep_ms);
#else
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)sleep_ms * 1000000L;
        (void)nanosleep(&req, NULL);
#endif
        waited += sleep_ms;
        if (step < 80) {
            step *= 2;
        }
    }
}

int32_t pion_core_accounts_tx_status(int64_t tx_id) {
    if (tx_id <= 0 || atomic_load_explicit(&g_accts_tx_active_id, memory_order_acquire) != tx_id) {
        return -2;
    }
    return g_accts_tx_status;
}

const uint8_t *pion_core_accounts_tx_data(int64_t tx_id) {
    if (tx_id <= 0 || atomic_load_explicit(&g_accts_tx_active_id, memory_order_acquire) != tx_id) {
        return NULL;
    }
    return g_accts_tx_status == 1 ? g_accts_tx_buf : NULL;
}

int64_t pion_core_accounts_tx_len(int64_t tx_id) {
    if (tx_id <= 0 || atomic_load_explicit(&g_accts_tx_active_id, memory_order_acquire) != tx_id) {
        return 0;
    }
    return g_accts_tx_status == 1 ? (int64_t)g_accts_tx_len : 0;
}

int32_t pion_core_accounts_tx_commit(int64_t tx_id, const uint8_t *bytes, int64_t len) {
    if (tx_id <= 0 || atomic_load_explicit(&g_accts_tx_active_id, memory_order_acquire) != tx_id) {
        return -1;
    }
    if (len < 0 || (len > 0 && bytes == NULL)) {
        return -1;
    }
    char accts_path[4096];
    join_dir_file(accts_path, sizeof(accts_path), g_accts_tx_dir, g_accts_tx_dir_len, "accounts");
    char tmp_name[128];
#ifdef _WIN32
    snprintf(tmp_name, sizeof(tmp_name), "accounts.partial.%lu.%lld",
             (unsigned long)GetCurrentProcessId(), (long long)tx_id);
#else
    snprintf(tmp_name, sizeof(tmp_name), "accounts.partial.%ld.%lld",
             (long)getpid(), (long long)tx_id);
#endif
    char tmp_path[4096];
    join_dir_file(tmp_path, sizeof(tmp_path), g_accts_tx_dir, g_accts_tx_dir_len, tmp_name);
    if (accts_path[0] == '\0' || tmp_path[0] == '\0') {
        return -1;
    }

#ifdef _WIN32
    wchar_t wtmp[4096];
    wchar_t wdst[4096];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, tmp_path, -1, wtmp, 4096) <= 0 ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, accts_path, -1, wdst, 4096) <= 0) {
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
    if (fsync(fd) != 0) {
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
    int dfd = open(g_accts_tx_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd >= 0) {
        (void)fsync(dfd);
        (void)close(dfd);
    }
    return 0;
#endif
}

void pion_core_accounts_tx_end(int64_t tx_id) {
    if (tx_id <= 0 || atomic_load_explicit(&g_accts_tx_active_id, memory_order_acquire) != tx_id) {
        return;
    }
    atomic_store_explicit(&g_accts_tx_active_id, 0, memory_order_release);
    accts_tx_reset_buf();
    g_accts_tx_dir[0] = '\0';
    g_accts_tx_dir_len = 0;
#ifdef _WIN32
    if (g_accts_tx_lock_handle != INVALID_HANDLE_VALUE) {
        HANDLE h = g_accts_tx_lock_handle;
        g_accts_tx_lock_handle = INVALID_HANDLE_VALUE;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        (void)UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
        (void)CloseHandle(h);
    }
#else
    if (g_accts_tx_lock_fd >= 0) {
        int fd = g_accts_tx_lock_fd;
        g_accts_tx_lock_fd = -1;
        (void)flock(fd, LOCK_UN);
        (void)close(fd);
    }
#endif
    accts_mu_unlock();
}

void pion_core_log_warn(const char *msg, int64_t len) {
    if (msg != NULL && len > 0) {
        fprintf(stderr, "[pion-core] %.*s\n", (int)len, msg);
    }
}

// ── Atomic per-account sidecar file I/O (zero dependency on `.accounts.lock` or SQLite) ──
// Used as durable fallback backup for Cloud-401 rejected tuples whenever SQLite `meta` write fails.
static uint8_t *g_sidecar_buf = NULL;
static size_t g_sidecar_len = 0;

static int is_safe_sidecar_name(const char *name, size_t len) {
    if (name == NULL || len == 0 || len > 160) {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)name[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) {
            return 0;
        }
    }
    if (strstr(name, "..") != NULL) {
        return 0;
    }
    return 1;
}

// Returns: 1 = found (use data/len accessors), 0 = absent (ENOENT), -1 = I/O or invalid path error.
int32_t pion_core_sidecar_read(const char *dir, int64_t dir_len, const char *name, int64_t name_len) {
    if (g_sidecar_buf != NULL) {
        free(g_sidecar_buf);
        g_sidecar_buf = NULL;
    }
    g_sidecar_len = 0;
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840 || name == NULL || name_len <= 0 || name_len > 160) {
        return -1;
    }
    char name_copy[192];
    memcpy(name_copy, name, (size_t)name_len);
    name_copy[name_len] = '\0';
    if (!is_safe_sidecar_name(name_copy, (size_t)name_len)) {
        return -1;
    }
    char path[4096];
    join_dir_file(path, sizeof(path), dir, (size_t)dir_len, name_copy);
    if (path[0] == '\0') {
        return -1;
    }
#ifdef _WIN32
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
    }
    size_t cap = 1024;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        CloseHandle(h);
        return -1;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= 65536) {
                free(buf);
                CloseHandle(h);
                return -1;
            }
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (nb == NULL) {
                free(buf);
                CloseHandle(h);
                return -1;
            }
            buf = nb;
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
    g_sidecar_buf = buf;
    g_sidecar_len = total;
    return 1;
#else
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return (errno == ENOENT) ? 0 : -1;
    }
    size_t cap = 1024;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        close(fd);
        return -1;
    }
    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap >= 65536) {
                free(buf);
                close(fd);
                return -1;
            }
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (nb == NULL) {
                free(buf);
                close(fd);
                return -1;
            }
            buf = nb;
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
    g_sidecar_buf = buf;
    g_sidecar_len = total;
    return 1;
#endif
}

const uint8_t *pion_core_sidecar_data(void) {
    return g_sidecar_buf;
}

int64_t pion_core_sidecar_len(void) {
    return (int64_t)g_sidecar_len;
}

// Atomically write `<dir>/<name>` via temp + fsync + rename (returns 0 on ok, -1 on error).
int32_t pion_core_sidecar_write_atomic(
    const char *dir,
    int64_t dir_len,
    const char *name,
    int64_t name_len,
    const uint8_t *bytes,
    int64_t len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840 || name == NULL || name_len <= 0 || name_len > 160 ||
        len < 0 || len > 65536 || (len > 0 && bytes == NULL)) {
        return -1;
    }
    char name_copy[192];
    memcpy(name_copy, name, (size_t)name_len);
    name_copy[name_len] = '\0';
    if (!is_safe_sidecar_name(name_copy, (size_t)name_len)) {
        return -1;
    }
    char dir_copy[3840];
    memcpy(dir_copy, dir, (size_t)dir_len);
    dir_copy[dir_len] = '\0';

    char final_path[4096];
    join_dir_file(final_path, sizeof(final_path), dir_copy, (size_t)dir_len, name_copy);
    if (final_path[0] == '\0') {
        return -1;
    }
    static _Atomic uint64_t s_sidecar_seq = 0;
    uint64_t seq = atomic_fetch_add_explicit(&s_sidecar_seq, 1, memory_order_relaxed) + 1;
    char tmp_name[256];
#ifdef _WIN32
    snprintf(tmp_name, sizeof(tmp_name), "%s.tmp.%lu.%llu",
             name_copy, (unsigned long)GetCurrentProcessId(), (unsigned long long)seq);
#else
    snprintf(tmp_name, sizeof(tmp_name), "%s.tmp.%lld.%llu",
             name_copy, (long long)getpid(), (unsigned long long)seq);
#endif
    char tmp_path[4096];
    join_dir_file(tmp_path, sizeof(tmp_path), dir_copy, (size_t)dir_len, tmp_name);
    if (tmp_path[0] == '\0') {
        return -1;
    }
#ifdef _WIN32
    HANDLE h = CreateFileA(tmp_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    size_t off = 0;
    while (off < (size_t)len) {
        DWORD wrote = 0;
        if (!WriteFile(h, bytes + off, (DWORD)((size_t)len - off), &wrote, NULL) || wrote == 0) {
            CloseHandle(h);
            DeleteFileA(tmp_path);
            return -1;
        }
        off += (size_t)wrote;
    }
    (void)FlushFileBuffers(h);
    CloseHandle(h);
    if (!MoveFileExA(tmp_path, final_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileA(tmp_path);
        return -1;
    }
    return 0;
#else
    (void)mkdir(dir_copy, 0700);
    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
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
    if (fsync(fd) != 0) {
        close(fd);
        (void)unlink(tmp_path);
        return -1;
    }
    close(fd);
    if (rename(tmp_path, final_path) != 0) {
        (void)unlink(tmp_path);
        return -1;
    }
    int dfd = open(dir_copy, O_RDONLY | O_CLOEXEC);
    if (dfd >= 0) {
        (void)fsync(dfd);
        close(dfd);
    }
    return 0;
#endif
}

int32_t pion_core_sidecar_remove(const char *dir, int64_t dir_len, const char *name, int64_t name_len) {
    if (dir == NULL || dir_len <= 0 || dir_len >= 3840 || name == NULL || name_len <= 0 || name_len > 160) {
        return -1;
    }
    char name_copy[192];
    memcpy(name_copy, name, (size_t)name_len);
    name_copy[name_len] = '\0';
    if (!is_safe_sidecar_name(name_copy, (size_t)name_len)) {
        return -1;
    }
    char path[4096];
    join_dir_file(path, sizeof(path), dir, (size_t)dir_len, name_copy);
    if (path[0] == '\0') {
        return -1;
    }
#ifdef _WIN32
    if (DeleteFileA(path)) {
        return 0;
    }
    DWORD err = GetLastError();
    return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
#else
    if (unlink(path) == 0 || errno == ENOENT) {
        return 0;
    }
    return -1;
#endif
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
