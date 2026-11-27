// Cross-platform C11 system primitives for Pion Station (`station_sys`).
// Targets: POSIX (macOS arm64, Linux x64/arm64) + Windows (`_WIN32` / MinGW).
//
// Core architectural invariants:
// 1. Foreign threads NEVER invoke Pion callbacks; they only enqueue native events
//    onto `host_shim`'s queue (`sth_push_sys` for control events, `sth_push_sys_bounded`
//    for bulk data events).
// 2. Streaming handles (`proc`, `pty`, `udp`) use refcounted detached teardown so
//    `close` returns immediately even when the bounded data queue is full, while
//    POSIX wait threads always reap children (zero zombies) and every detached
//    worker is tracked for deterministic test synchronization.
// 3. Control channel (`sts_ctrl_*`) only operates on the explicitly supplied control
//    fd (> 4, e.g. fd 5) or Windows named pipe — never touches stdio 0..2 or
//    launcher listening fds 3..4.

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
#define PSAPI_VERSION 2
#endif

#include "station_sys.h"
#include "../../../../station/packages/host_shim/native/station_host.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <io.h>
#include <iphlpapi.h>
#include <psapi.h>
#include <sys/stat.h>
#include <tlhelp32.h>
#else
#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/clonefile.h>
#include <sys/event.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <util.h>
#else
#include <pty.h>
#include <sys/inotify.h>
#include <sys/syscall.h>
#ifdef __linux__
#ifndef FICLONE
#define FICLONE _IOW(0x94, 9, int)
#endif
#endif
#endif
extern char **environ;
#endif

// ===========================================================================
// Common helpers (dynamic string buffer, LE encoding, safe string helpers)
// ===========================================================================

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} sbuf_t;

static int sb_reserve(sbuf_t *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) {
        return 1;
    }
    size_t cap = b->cap == 0 ? 256 : b->cap;
    while (cap < b->len + extra + 1) {
        cap *= 2;
    }
    char *grown = (char *)realloc(b->data, cap);
    if (grown == NULL) {
        return 0;
    }
    b->data = grown;
    b->cap = cap;
    return 1;
}

static void sb_add(sbuf_t *b, const char *s, size_t len) {
    if (!sb_reserve(b, len)) {
        return;
    }
    if (len > 0 && s != NULL) {
        memcpy(b->data + b->len, s, len);
    }
    b->len += len;
    b->data[b->len] = '\0';
}

static void sb_str(sbuf_t *b, const char *s) {
    if (s != NULL) {
        sb_add(b, s, strlen(s));
    }
}

#ifndef _WIN32
static void sb_fmt_i64(sbuf_t *b, long long v) {
    char tmp[48];
    int n = snprintf(tmp, sizeof(tmp), "%lld", v);
    if (n > 0) {
        sb_add(b, tmp, (size_t)n);
    }
}
#endif

static void sb_fmt_u64(sbuf_t *b, unsigned long long v) {
    char tmp[48];
    int n = snprintf(tmp, sizeof(tmp), "%llu", v);
    if (n > 0) {
        sb_add(b, tmp, (size_t)n);
    }
}

#ifndef _WIN32
static void sb_fmt_f64(sbuf_t *b, const char *fmt, double v) {
    char tmp[64];
    int n = snprintf(tmp, sizeof(tmp), fmt, v);
    if (n > 0) {
        sb_add(b, tmp, (size_t)n);
    }
}
#endif

static void sb_json_str(sbuf_t *b, const char *s) {
    sb_add(b, "\"", 1);
    if (s != NULL) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            char esc[8];
            if (*p == '"' || *p == '\\') {
                esc[0] = '\\';
                esc[1] = (char)*p;
                sb_add(b, esc, 2);
            } else if (*p < 0x20) {
                snprintf(esc, sizeof(esc), "\\u%04x", (unsigned)*p);
                sb_add(b, esc, 6);
            } else {
                sb_add(b, (const char *)p, 1);
            }
        }
    }
    sb_add(b, "\"", 1);
}

static const char *path_basename(const char *path) {
    if (path == NULL) return "";
    const char *sep = strrchr(path, '/');
#ifdef _WIN32
    const char *bslash = strrchr(path, '\\');
    if (bslash != NULL && (sep == NULL || bslash > sep)) {
        sep = bslash;
    }
#endif
    return sep != NULL ? sep + 1 : path;
}

static void *sb_finish(sbuf_t *b, int64_t *out_len) {
    if (b->data == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    void *res = b->data;
    if (out_len != NULL) {
        *out_len = (int64_t)b->len;
    }
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    return res;
}

static void *dup_bytes(const void *src, size_t len, int64_t *out_len) {
    if (out_len != NULL) {
        *out_len = (int64_t)len;
    }
    uint8_t *out = (uint8_t *)malloc(len + 1);
    if (out == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    if (len > 0 && src != NULL) {
        memcpy(out, src, len);
    }
    out[len] = 0;
    return out;
}

static char *sts_strdup(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    size_t n = strlen(s) + 1;
    char *out = (char *)malloc(n);
    if (out != NULL) {
        memcpy(out, s, n);
    }
    return out;
}

static void put_u16_le(uint8_t *at, uint16_t v) {
    at[0] = (uint8_t)(v & 0xffu);
    at[1] = (uint8_t)((v >> 8) & 0xffu);
}

static void put_i32_le(uint8_t *at, int32_t v) {
    uint32_t u = (uint32_t)v;
    at[0] = (uint8_t)(u & 0xffu);
    at[1] = (uint8_t)((u >> 8) & 0xffu);
    at[2] = (uint8_t)((u >> 16) & 0xffu);
    at[3] = (uint8_t)((u >> 24) & 0xffu);
}

static void copy_err(char *buf, int64_t cap, const char *msg) {
    if (buf == NULL || cap <= 0) {
        return;
    }
    if (msg == NULL) {
        buf[0] = '\0';
        return;
    }
    size_t n = strlen(msg);
    if ((int64_t)n >= cap) {
        n = (size_t)(cap - 1);
    }
    memcpy(buf, msg, n);
    buf[n] = '\0';
}

static int is_malloc_se_entry(const char *entry) {
    if (entry == NULL) {
        return 0;
    }
    static const char key[] = "MallocSpaceEfficient=";
    size_t klen = sizeof(key) - 1;
#ifdef _WIN32
    for (size_t i = 0; i < klen; i++) {
        if (entry[i] == '\0') {
            return 0;
        }
        if (tolower((unsigned char)entry[i]) != tolower((unsigned char)key[i])) {
            return 0;
        }
    }
    return 1;
#else
    return strncmp(entry, key, klen) == 0;
#endif
}

static void push_tag_ctrl(uint64_t event_id, uint8_t tag, const void *data, size_t len) {
    uint8_t stack_buf[256];
    uint8_t *buf = (len + 1 <= sizeof(stack_buf)) ? stack_buf : (uint8_t *)malloc(len + 1);
    if (buf == NULL) {
        return;
    }
    buf[0] = tag;
    if (len > 0 && data != NULL) {
        memcpy(buf + 1, data, len);
    }
    sth_push_sys(event_id, buf, len + 1);
    if (buf != stack_buf) {
        free(buf);
    }
}

static void push_exit_event(uint64_t event_id, uint8_t tag, int32_t exit_code, int32_t sig, const char *sig_name) {
    size_t slen = sig_name != NULL ? strlen(sig_name) : 0;
    uint8_t buf[128];
    if (slen > sizeof(buf) - 9) {
        slen = sizeof(buf) - 9;
    }
    buf[0] = tag;
    put_i32_le(buf + 1, exit_code);
    put_i32_le(buf + 5, sig);
    if (slen > 0) {
        memcpy(buf + 9, sig_name, slen);
    }
    sth_push_sys(event_id, buf, 9 + slen);
}

void sts_free(void *ptr) {
    free(ptr);
}

// ===========================================================================
// Global detached worker tracker (for deterministic test synchronization)
// ===========================================================================

static _Atomic int32_t g_bounded_push_inflight = 0;

static void push_sys_bounded_tracked(uint64_t event_id, const void *data, size_t len) {
    atomic_fetch_add_explicit(&g_bounded_push_inflight, 1, memory_order_acq_rel);
    sth_push_sys_bounded(event_id, data, len);
    atomic_fetch_sub_explicit(&g_bounded_push_inflight, 1, memory_order_release);
}

int32_t sts_bounded_push_inflight_for_test(void) {
    return atomic_load_explicit(&g_bounded_push_inflight, memory_order_acquire);
}

#ifdef _WIN32
static SRWLOCK g_det_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE g_det_cond = CONDITION_VARIABLE_INIT;
static int64_t g_io_workers = 0;
static int64_t g_reaper_workers = 0;

int32_t sts_active_workers(void) {
    AcquireSRWLockExclusive(&g_det_lock);
    int32_t n = (int32_t)g_io_workers;
    ReleaseSRWLockExclusive(&g_det_lock);
    return n;
}

static void sts_detached_begin(void) {
    AcquireSRWLockExclusive(&g_det_lock);
    g_io_workers += 1;
    ReleaseSRWLockExclusive(&g_det_lock);
}

static void sts_detached_end(void) {
    AcquireSRWLockExclusive(&g_det_lock);
    g_io_workers -= 1;
    if (g_io_workers == 0 && g_reaper_workers == 0) {
        WakeAllConditionVariable(&g_det_cond);
    }
    ReleaseSRWLockExclusive(&g_det_lock);
}

static void sts_reaper_begin(void) {
    AcquireSRWLockExclusive(&g_det_lock);
    g_reaper_workers += 1;
    ReleaseSRWLockExclusive(&g_det_lock);
}

static void sts_reaper_end(void) {
    AcquireSRWLockExclusive(&g_det_lock);
    g_reaper_workers -= 1;
    if (g_io_workers == 0 && g_reaper_workers == 0) {
        WakeAllConditionVariable(&g_det_cond);
    }
    ReleaseSRWLockExclusive(&g_det_lock);
}

int32_t sts_wait_detached_for_test(int64_t timeout_ms) {
    ULONGLONG start = GetTickCount64();
    AcquireSRWLockExclusive(&g_det_lock);
    while (g_io_workers > 0 || g_reaper_workers > 0) {
        if (timeout_ms <= 0) {
            break;
        }
        ULONGLONG elapsed = GetTickCount64() - start;
        if ((int64_t)elapsed >= timeout_ms) {
            break;
        }
        DWORD rem = (DWORD)(timeout_ms - (int64_t)elapsed);
        SleepConditionVariableSRW(&g_det_cond, &g_det_lock, rem, 0);
    }
    int ok = (g_io_workers == 0 && g_reaper_workers == 0) ? 1 : 0;
    ReleaseSRWLockExclusive(&g_det_lock);
    return ok;
}

static int win_spawn_detached_thread(LPTHREAD_START_ROUTINE fn, LPVOID arg) {
    sts_detached_begin();
    HANDLE h = CreateThread(NULL, 0, fn, arg, 0, NULL);
    if (h == NULL) {
        sts_detached_end();
        return 0;
    }
    CloseHandle(h);
    return 1;
}

static int win_spawn_reaper_thread(LPTHREAD_START_ROUTINE fn, LPVOID arg) {
    sts_reaper_begin();
    HANDLE h = CreateThread(NULL, 0, fn, arg, 0, NULL);
    if (h == NULL) {
        sts_reaper_end();
        return 0;
    }
    CloseHandle(h);
    return 1;
}
#else
static pthread_mutex_t g_det_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_det_cond;
static pthread_once_t g_det_once = PTHREAD_ONCE_INIT;
static int64_t g_io_workers = 0;
static int64_t g_reaper_workers = 0;

int32_t sts_active_workers(void) {
    pthread_mutex_lock(&g_det_lock);
    int32_t n = (int32_t)g_io_workers;
    pthread_mutex_unlock(&g_det_lock);
    return n;
}

static void sts_det_init_once(void) {
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
#ifndef __APPLE__
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
    pthread_cond_init(&g_det_cond, &attr);
    pthread_condattr_destroy(&attr);
}

static void sts_detached_begin(void) {
    pthread_once(&g_det_once, sts_det_init_once);
    pthread_mutex_lock(&g_det_lock);
    g_io_workers += 1;
    pthread_mutex_unlock(&g_det_lock);
}

static void sts_detached_end(void) {
    pthread_once(&g_det_once, sts_det_init_once);
    pthread_mutex_lock(&g_det_lock);
    g_io_workers -= 1;
    if (g_io_workers == 0 && g_reaper_workers == 0) {
        pthread_cond_broadcast(&g_det_cond);
    }
    pthread_mutex_unlock(&g_det_lock);
}

static void sts_reaper_begin(void) {
    pthread_once(&g_det_once, sts_det_init_once);
    pthread_mutex_lock(&g_det_lock);
    g_reaper_workers += 1;
    pthread_mutex_unlock(&g_det_lock);
}

static void sts_reaper_end(void) {
    pthread_once(&g_det_once, sts_det_init_once);
    pthread_mutex_lock(&g_det_lock);
    g_reaper_workers -= 1;
    if (g_io_workers == 0 && g_reaper_workers == 0) {
        pthread_cond_broadcast(&g_det_cond);
    }
    pthread_mutex_unlock(&g_det_lock);
}

int32_t sts_wait_detached_for_test(int64_t timeout_ms) {
    pthread_once(&g_det_once, sts_det_init_once);
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    pthread_mutex_lock(&g_det_lock);
    while (g_io_workers > 0 || g_reaper_workers > 0) {
        if (timeout_ms <= 0) {
            break;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed_ms = (int64_t)(now.tv_sec - start.tv_sec) * 1000LL +
                             (int64_t)(now.tv_nsec - start.tv_nsec) / 1000000LL;
        if (elapsed_ms >= timeout_ms) {
            break;
        }
        int64_t rem_ms = timeout_ms - elapsed_ms;
#ifdef __APPLE__
        struct timespec rel;
        rel.tv_sec = (time_t)(rem_ms / 1000LL);
        rel.tv_nsec = (long)((rem_ms % 1000LL) * 1000000LL);
        int rc = pthread_cond_timedwait_relative_np(&g_det_cond, &g_det_lock, &rel);
#else
        struct timespec dl = now;
        dl.tv_sec += (time_t)(rem_ms / 1000LL);
        dl.tv_nsec += (long)((rem_ms % 1000LL) * 1000000LL);
        if (dl.tv_nsec >= 1000000000L) {
            dl.tv_sec += 1;
            dl.tv_nsec -= 1000000000L;
        }
        int rc = pthread_cond_timedwait(&g_det_cond, &g_det_lock, &dl);
#endif
        if (rc == ETIMEDOUT) {
            break;
        }
    }
    int ok = (g_io_workers == 0 && g_reaper_workers == 0) ? 1 : 0;
    pthread_mutex_unlock(&g_det_lock);
    return ok;
}

static int spawn_detached_thread(void *(*fn)(void *), void *arg) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    sts_detached_begin();
    pthread_t th;
    int rc = pthread_create(&th, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        sts_detached_end();
        return 0;
    }
    return 1;
}

static int spawn_reaper_thread(void *(*fn)(void *), void *arg) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    sts_reaper_begin();
    pthread_t th;
    int rc = pthread_create(&th, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        sts_reaper_end();
        return 0;
    }
    return 1;
}
#endif

// ===========================================================================
// OS / Arch info
// ===========================================================================

int32_t sts_os_kind(void) {
#if defined(_WIN32)
    return 2;
#elif defined(__APPLE__)
    return 0;
#elif defined(__linux__)
    return 1;
#else
    return 3;
#endif
}

int32_t sts_arch_kind(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
    return 0;
#elif defined(__x86_64__) || defined(_M_X64)
    return 1;
#else
    return 2;
#endif
}

// ===========================================================================
// Generic synchronized handle registry (prevents UAF & double-close)
// ===========================================================================

#define STS_HANDLE_BUCKETS 128

typedef struct sts_hnode {
    int64_t id;
    int kind;
    void *ptr;
    struct sts_hnode *next;
} sts_hnode_t;

enum {
    STS_HK_FS_WATCH = 1,
    STS_HK_PROC     = 2,
    STS_HK_CTRL     = 3,
    STS_HK_FLOCK    = 4,
    STS_HK_PTY      = 5,
    STS_HK_UDP      = 6,
    STS_HK_FILE_RO  = 7
};

#ifdef _WIN32
static SRWLOCK g_ht_lock = SRWLOCK_INIT;
static void ht_lock(void) { AcquireSRWLockExclusive(&g_ht_lock); }
static void ht_unlock(void) { ReleaseSRWLockExclusive(&g_ht_lock); }
#else
static pthread_mutex_t g_ht_lock = PTHREAD_MUTEX_INITIALIZER;
static void ht_lock(void) { pthread_mutex_lock(&g_ht_lock); }
static void ht_unlock(void) { pthread_mutex_unlock(&g_ht_lock); }
#endif

static sts_hnode_t *g_ht_buckets[STS_HANDLE_BUCKETS];
static int64_t g_ht_next_id = 1;

static int64_t ht_insert(int kind, void *ptr) {
    sts_hnode_t *node = (sts_hnode_t *)malloc(sizeof(*node));
    if (node == NULL) {
        return -1;
    }
    ht_lock();
    int64_t id = g_ht_next_id++;
    if (g_ht_next_id <= 0) {
        g_ht_next_id = 1;
    }
    node->id = id;
    node->kind = kind;
    node->ptr = ptr;
    size_t b = (size_t)((uint64_t)id % STS_HANDLE_BUCKETS);
    node->next = g_ht_buckets[b];
    g_ht_buckets[b] = node;
    ht_unlock();
    return id;
}

static void *ht_take(int kind, int64_t id) {
    if (id <= 0) {
        return NULL;
    }
    size_t b = (size_t)((uint64_t)id % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t **pp = &g_ht_buckets[b];
    void *found = NULL;
    while (*pp != NULL) {
        if ((*pp)->id == id && (*pp)->kind == kind) {
            sts_hnode_t *node = *pp;
            *pp = node->next;
            found = node->ptr;
            free(node);
            break;
        }
        pp = &(*pp)->next;
    }
    ht_unlock();
    return found;
}

// ===========================================================================
// Common stdin chunk queue
// ===========================================================================

#define STS_STDIN_QUEUE_MAX (64u * 1024u * 1024u)
#define STS_CTRL_MAX_LINE   (16u * 1024u * 1024u)

typedef struct sts_chunk {
    struct sts_chunk *next;
    size_t len;
    size_t off;
    uint8_t data[];
} sts_chunk_t;

static void free_chunks(sts_chunk_t *head) {
    while (head != NULL) {
        sts_chunk_t *next = head->next;
        free(head);
        head = next;
    }
}

#ifdef _WIN32
// ===========================================================================
//                           WINDOWS IMPLEMENTATION
// ===========================================================================

static wchar_t *utf8_to_wide(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) {
        return NULL;
    }
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)n);
    if (w != NULL) {
        MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    }
    return w;
}

static char *wide_to_utf8_len(const wchar_t *w, int wlen) {
    if (w == NULL) {
        return NULL;
    }
    int n = WideCharToMultiByte(CP_UTF8, 0, w, wlen, NULL, 0, NULL, NULL);
    if (n <= 0) {
        return sts_strdup("");
    }
    char *s = (char *)malloc((size_t)n + 1);
    if (s != NULL) {
        WideCharToMultiByte(CP_UTF8, 0, w, wlen, s, n, NULL, NULL);
        s[n] = '\0';
    }
    return s;
}

static char *wide_to_utf8(const wchar_t *w) {
    return wide_to_utf8_len(w, -1);
}

static void win_err_str(DWORD code, char *buf, size_t cap) {
    wchar_t wbuf[512];
    DWORD n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL,
        code,
        0,
        wbuf,
        (DWORD)(sizeof(wbuf) / sizeof(wbuf[0])),
        NULL);
    while (n > 0 && (wbuf[n - 1] == L'\r' || wbuf[n - 1] == L'\n' || wbuf[n - 1] == L' ')) {
        wbuf[--n] = 0;
    }
    if (n == 0) {
        snprintf(buf, cap, "win32 error %lu", (unsigned long)code);
    } else {
        char *s = wide_to_utf8(wbuf);
        snprintf(buf, cap, "%s", s != NULL ? s : "win32 error");
        free(s);
    }
}

static uint64_t ft64(FILETIME t) {
    return ((uint64_t)t.dwHighDateTime << 32) | (uint64_t)t.dwLowDateTime;
}

static INIT_ONCE g_wsa_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK wsa_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    return TRUE;
}
static void ensure_wsa(void) {
    InitOnceExecuteOnce(&g_wsa_once, wsa_init_cb, NULL, NULL);
}

// ---------------------------------------------------------------------------
// 1. Windows non-recursive fs.watch (ReadDirectoryChangesW; supports dir & single file)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    HANDLE h_dir;
    HANDLE h_stop;
    HANDLE h_ready;
    int ready_ok;
    HANDLE h_thread;
    char *filter_name; // non-NULL when watching a single file
} win_fsw_t;

static int ascii_strcasecmp(const char *a, const char *b) {
    if (a == NULL || b == NULL) return a == b ? 0 : 1;
    while (*a != '\0' && *b != '\0') {
        int ca = tolower((unsigned char)*a);
        int cb = tolower((unsigned char)*b);
        if (ca != cb) return ca - cb;
        a++;
        b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

static DWORD WINAPI win_fsw_thread(LPVOID arg) {
    win_fsw_t *w = (win_fsw_t *)arg;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (h_io == NULL || buf == NULL) {
        free(buf);
        if (h_io != NULL) CloseHandle(h_io);
        w->ready_ok = 0;
        SetEvent(w->h_ready);
        return 0;
    }
    const DWORD filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                         FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                         FILE_NOTIFY_CHANGE_LAST_WRITE;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = h_io;
    BOOL first_ok = ReadDirectoryChangesW(w->h_dir, buf, 65536, FALSE, filter, NULL, &ov, NULL);
    w->ready_ok = first_ok ? 1 : 0;
    SetEvent(w->h_ready);
    if (!first_ok) {
        free(buf);
        CloseHandle(h_io);
        return 0;
    }
    for (;;) {
        HANDLE waits[2] = { h_io, w->h_stop };
        DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
        if (wr == WAIT_OBJECT_0 + 1) {
            CancelIoEx(w->h_dir, &ov);
            DWORD dummy = 0;
            GetOverlappedResult(w->h_dir, &ov, &dummy, TRUE);
            break;
        }
        if (wr != WAIT_OBJECT_0) {
            break;
        }
        DWORD bytes = 0;
        if (!GetOverlappedResult(w->h_dir, &ov, &bytes, FALSE)) {
            break;
        }
        if (bytes == 0) {
            uint8_t ovf[2] = { STS_EV_FS_CHANGE, STS_FS_OVERFLOW };
            sth_push_sys(w->event_id, ovf, sizeof(ovf));
        } else {
            size_t off = 0;
            const size_t hdr = offsetof(FILE_NOTIFY_INFORMATION, FileName);
            for (;;) {
                if (off + hdr > (size_t)bytes) {
                    break;
                }
                const FILE_NOTIFY_INFORMATION *fni = (const FILE_NOTIFY_INFORMATION *)(buf + off);
                if ((size_t)fni->FileNameLength > (size_t)bytes - off - hdr) {
                    break;
                }
                int wchars = (int)(fni->FileNameLength / sizeof(wchar_t));
                char *name = wide_to_utf8_len(fni->FileName, wchars);
                if (w->filter_name == NULL || (name != NULL && ascii_strcasecmp(name, w->filter_name) == 0)) {
                    size_t nlen = name != NULL ? strlen(name) : 0;
                    uint8_t kind = (fni->Action == FILE_ACTION_MODIFIED) ? STS_FS_CHANGE : STS_FS_RENAME;
                    uint8_t *msg = (uint8_t *)malloc(2 + nlen);
                    if (msg != NULL) {
                        msg[0] = STS_EV_FS_CHANGE;
                        msg[1] = kind;
                        if (nlen > 0) {
                            memcpy(msg + 2, name, nlen);
                        }
                        sth_push_sys(w->event_id, msg, 2 + nlen);
                        free(msg);
                    }
                }
                free(name);
                if (fni->NextEntryOffset == 0 ||
                    (fni->NextEntryOffset & 3u) != 0 ||
                    (size_t)fni->NextEntryOffset < hdr ||
                    (size_t)fni->NextEntryOffset > (size_t)bytes - off) {
                    break;
                }
                off += fni->NextEntryOffset;
            }
        }
        ResetEvent(h_io);
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = h_io;
        if (!ReadDirectoryChangesW(w->h_dir, buf, 65536, FALSE, filter, NULL, &ov, NULL)) {
            break;
        }
    }
    free(buf);
    CloseHandle(h_io);
    push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
    return 0;
}

int64_t sts_fs_watch_open(uint64_t event_id, const char *path) {
    if (path == NULL || path[0] == '\0') {
        return -1;
    }
    wchar_t *wpath = utf8_to_wide(path);
    if (wpath == NULL) {
        return -1;
    }
    DWORD attrs = GetFileAttributesW(wpath);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        free(wpath);
        return -1;
    }
    char *filter_name = NULL;
    wchar_t *wdir = wpath;
    if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        const char *base = path_basename(path);
        filter_name = sts_strdup(base);
        size_t dir_len = (size_t)(base - path);
        char *parent = NULL;
        if (dir_len == 0) {
            parent = sts_strdup(".");
        } else {
            parent = (char *)malloc(dir_len + 1);
            if (parent != NULL) {
                memcpy(parent, path, dir_len);
                parent[dir_len] = '\0';
            }
        }
        free(wpath);
        wdir = parent != NULL ? utf8_to_wide(parent) : NULL;
        free(parent);
        if (wdir == NULL || filter_name == NULL) {
            free(wdir);
            free(filter_name);
            return -1;
        }
    }
    HANDLE h_dir = CreateFileW(
        wdir,
        FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
        NULL);
    free(wdir);
    if (h_dir == INVALID_HANDLE_VALUE) {
        free(filter_name);
        return -1;
    }
    win_fsw_t *w = (win_fsw_t *)calloc(1, sizeof(*w));
    if (w == NULL) {
        free(filter_name);
        CloseHandle(h_dir);
        return -1;
    }
    w->event_id = event_id;
    w->h_dir = h_dir;
    w->filter_name = filter_name;
    w->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    w->h_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (w->h_stop == NULL || w->h_ready == NULL) {
        if (w->h_ready != NULL) CloseHandle(w->h_ready);
        if (w->h_stop != NULL) CloseHandle(w->h_stop);
        free(w->filter_name);
        CloseHandle(h_dir);
        free(w);
        return -1;
    }
    w->h_thread = CreateThread(NULL, 0, win_fsw_thread, w, 0, NULL);
    if (w->h_thread == NULL) {
        CloseHandle(w->h_ready);
        CloseHandle(w->h_stop);
        CloseHandle(h_dir);
        free(w->filter_name);
        free(w);
        return -1;
    }
    WaitForSingleObject(w->h_ready, INFINITE);
    CloseHandle(w->h_ready);
    w->h_ready = NULL;
    if (!w->ready_ok) {
        WaitForSingleObject(w->h_thread, INFINITE);
        CloseHandle(w->h_thread);
        CloseHandle(w->h_stop);
        CloseHandle(h_dir);
        free(w->filter_name);
        free(w);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_FS_WATCH, w);
    if (id < 0) {
        SetEvent(w->h_stop);
        WaitForSingleObject(w->h_thread, INFINITE);
        CloseHandle(w->h_thread);
        CloseHandle(w->h_stop);
        CloseHandle(w->h_dir);
        free(w->filter_name);
        free(w);
    }
    return id;
}

int32_t sts_fs_watch_close(int64_t handle) {
    win_fsw_t *w = (win_fsw_t *)ht_take(STS_HK_FS_WATCH, handle);
    if (w == NULL) {
        return 0;
    }
    SetEvent(w->h_stop);
    WaitForSingleObject(w->h_thread, INFINITE);
    CloseHandle(w->h_thread);
    CloseHandle(w->h_stop);
    CloseHandle(w->h_dir);
    free(w->filter_name);
    free(w);
    return 1;
}

// ---------------------------------------------------------------------------
// 2. Windows Async Child Process
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    HANDLE h_proc;
    HANDLE h_job;
    DWORD pid;
    HANDLE h_stop;
    _Atomic int closing;
    SRWLOCK kill_lock;
    int exited;

    HANDLE h_stdin;
    SRWLOCK stdin_lock;
    CONDITION_VARIABLE stdin_cond;
    sts_chunk_t *stdin_head;
    sts_chunk_t *stdin_tail;
    size_t stdin_queued;
    int stdin_eof;
    int stdin_aborted;

    HANDLE h_stdout;
    HANDLE h_stderr;
    SRWLOCK ref_lock;
    int refs;
} win_proc_t;

static _Atomic uint64_t g_win_pipe_seq = 1;

static int win_create_overlapped_pipe(int child_is_reader, int child_inheritable, HANDLE *out_parent, HANDLE *out_child) {
    uint64_t seq = atomic_fetch_add_explicit(&g_win_pipe_seq, 1, memory_order_relaxed);
    LARGE_INTEGER qpc;
    qpc.QuadPart = 0;
    QueryPerformanceCounter(&qpc);
    wchar_t name[160];
    swprintf(name, 160, L"\\\\.\\pipe\\stillfail-sts-%lu-%llx-%llx-%llu",
             (unsigned long)GetCurrentProcessId(),
             (unsigned long long)GetTickCount64(),
             (unsigned long long)qpc.QuadPart,
             (unsigned long long)seq);
    DWORD open_mode = (child_is_reader ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) |
                      FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE;
    HANDLE parent = CreateNamedPipeW(
        name,
        open_mode,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1,
        65536,
        65536,
        0,
        NULL);
    if (parent == INVALID_HANDLE_VALUE) {
        return 0;
    }
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, child_inheritable ? TRUE : FALSE };
    HANDLE child = CreateFileW(
        name,
        child_is_reader ? GENERIC_READ : GENERIC_WRITE,
        0,
        &sa,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    if (child == INVALID_HANDLE_VALUE) {
        CloseHandle(parent);
        return 0;
    }
    *out_parent = parent;
    *out_child = child;
    return 1;
}

static void win_proc_ref(win_proc_t *p) {
    AcquireSRWLockExclusive(&p->ref_lock);
    p->refs += 1;
    ReleaseSRWLockExclusive(&p->ref_lock);
}

static void win_proc_unref(win_proc_t *p) {
    AcquireSRWLockExclusive(&p->ref_lock);
    int last = (--p->refs == 0);
    ReleaseSRWLockExclusive(&p->ref_lock);
    if (!last) {
        return;
    }
    free_chunks(p->stdin_head);
    if (p->h_stdin != NULL) CloseHandle(p->h_stdin);
    if (p->h_stdout != NULL) CloseHandle(p->h_stdout);
    if (p->h_stderr != NULL) CloseHandle(p->h_stderr);
    if (p->h_proc != NULL) CloseHandle(p->h_proc);
    if (p->h_job != NULL) CloseHandle(p->h_job);
    if (p->h_stop != NULL) CloseHandle(p->h_stop);
    free(p);
}

typedef struct {
    win_proc_t *proc;
    HANDLE h_pipe;
    uint8_t data_tag;
    uint8_t eof_tag;
} win_pipe_arg_t;

static DWORD WINAPI win_pipe_reader_thread(LPVOID arg) {
    win_pipe_arg_t *pa = (win_pipe_arg_t *)arg;
    win_proc_t *p = pa->proc;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    int eof = 0;
    if (h_io != NULL && buf != NULL) {
        buf[0] = pa->data_tag;
        for (;;) {
            if (atomic_load_explicit(&p->closing, memory_order_acquire)) {
                break;
            }
            ResetEvent(h_io);
            OVERLAPPED ov;
            memset(&ov, 0, sizeof(ov));
            ov.hEvent = h_io;
            DWORD n = 0;
            BOOL ok = ReadFile(pa->h_pipe, buf + 1, 65536, &n, &ov);
            if (!ok) {
                DWORD err = GetLastError();
                if (err == ERROR_IO_PENDING) {
                    HANDLE waits[2] = { h_io, p->h_stop };
                    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                    if (wr == WAIT_OBJECT_0 + 1) {
                        CancelIoEx(pa->h_pipe, &ov);
                        DWORD dummy = 0;
                        GetOverlappedResult(pa->h_pipe, &ov, &dummy, TRUE);
                        break;
                    }
                    if (wr != WAIT_OBJECT_0 || !GetOverlappedResult(pa->h_pipe, &ov, &n, FALSE)) {
                        eof = 1;
                        break;
                    }
                } else {
                    eof = 1;
                    break;
                }
            }
            if (n == 0) {
                eof = 1;
                break;
            }
            if (atomic_load_explicit(&p->closing, memory_order_acquire)) {
                break;
            }
            push_sys_bounded_tracked(p->event_id, buf, (size_t)n + 1);
            if (atomic_load_explicit(&p->closing, memory_order_acquire)) {
                break;
            }
        }
    }
    free(buf);
    if (h_io != NULL) CloseHandle(h_io);
    if (eof && !atomic_load_explicit(&p->closing, memory_order_acquire)) {
        push_tag_ctrl(p->event_id, pa->eof_tag, NULL, 0);
    }
    free(pa);
    win_proc_unref(p);
    sts_detached_end();
    return 0;
}

static int win_write_overlapped(HANDLE h, HANDLE h_stop, HANDLE h_io, const uint8_t *data, size_t len) {
    size_t done = 0;
    while (done < len) {
        ResetEvent(h_io);
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = h_io;
        DWORD want = (len - done) > 0x7fffffffu ? 0x7fffffffu : (DWORD)(len - done);
        DWORD n = 0;
        BOOL wr = WriteFile(h, data + done, want, &n, &ov);
        if (!wr) {
            DWORD err = GetLastError();
            if (err == ERROR_IO_PENDING) {
                HANDLE waits[2] = { h_io, h_stop };
                DWORD wrc = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wrc == WAIT_OBJECT_0 + 1) {
                    CancelIoEx(h, &ov);
                    DWORD dummy = 0;
                    GetOverlappedResult(h, &ov, &dummy, TRUE);
                    return 0;
                }
                if (wrc != WAIT_OBJECT_0 || !GetOverlappedResult(h, &ov, &n, FALSE)) {
                    return 0;
                }
            } else {
                return 0;
            }
        }
        if (n == 0) {
            return 0;
        }
        done += (size_t)n;
    }
    return 1;
}

static DWORD WINAPI win_stdin_thread(LPVOID arg) {
    win_proc_t *p = (win_proc_t *)arg;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    for (;;) {
        AcquireSRWLockExclusive(&p->stdin_lock);
        while (!p->stdin_aborted && p->stdin_head == NULL && !p->stdin_eof) {
            SleepConditionVariableSRW(&p->stdin_cond, &p->stdin_lock, INFINITE, 0);
        }
        if (p->stdin_aborted || h_io == NULL) {
            sts_chunk_t *drop = p->stdin_head;
            p->stdin_head = p->stdin_tail = NULL;
            p->stdin_queued = 0;
            ReleaseSRWLockExclusive(&p->stdin_lock);
            free_chunks(drop);
            break;
        }
        if (p->stdin_head != NULL) {
            sts_chunk_t *ch = p->stdin_head;
            p->stdin_head = ch->next;
            if (p->stdin_head == NULL) p->stdin_tail = NULL;
            p->stdin_queued -= ch->len;
            HANDLE h = p->h_stdin;
            ReleaseSRWLockExclusive(&p->stdin_lock);

            int ok = win_write_overlapped(h, p->h_stop, h_io, ch->data, ch->len);
            free(ch);
            if (!ok) {
                AcquireSRWLockExclusive(&p->stdin_lock);
                p->stdin_aborted = 1;
                sts_chunk_t *drop = p->stdin_head;
                p->stdin_head = p->stdin_tail = NULL;
                p->stdin_queued = 0;
                ReleaseSRWLockExclusive(&p->stdin_lock);
                free_chunks(drop);
                break;
            }
            continue;
        }
        if (p->stdin_eof) {
            ReleaseSRWLockExclusive(&p->stdin_lock);
            break;
        }
        ReleaseSRWLockExclusive(&p->stdin_lock);
    }
    if (h_io != NULL) CloseHandle(h_io);
    AcquireSRWLockExclusive(&p->stdin_lock);
    if (p->h_stdin != NULL) {
        CloseHandle(p->h_stdin);
        p->h_stdin = NULL;
    }
    ReleaseSRWLockExclusive(&p->stdin_lock);
    win_proc_unref(p);
    sts_detached_end();
    return 0;
}

static DWORD WINAPI win_wait_thread(LPVOID arg) {
    win_proc_t *p = (win_proc_t *)arg;
    HANDLE waits[2] = { p->h_proc, p->h_stop };
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
    if (wr == WAIT_OBJECT_0) {
        DWORD code = 1;
        GetExitCodeProcess(p->h_proc, &code);
        AcquireSRWLockExclusive(&p->kill_lock);
        p->exited = 1;
        if (!atomic_load_explicit(&p->closing, memory_order_acquire)) {
            push_exit_event(p->event_id, STS_EV_PROC_EXIT, (int32_t)code, 0, "");
        }
        ReleaseSRWLockExclusive(&p->kill_lock);
        AcquireSRWLockExclusive(&p->stdin_lock);
        p->stdin_aborted = 1;
        WakeConditionVariable(&p->stdin_cond);
        ReleaseSRWLockExclusive(&p->stdin_lock);
    }
    win_proc_unref(p);
    sts_reaper_end();
    return 0;
}

static void win_quote_arg(sbuf_t *b, const char *a) {
    if (a == NULL || (*a != '\0' && strpbrk(a, " \t\n\v\"") == NULL)) {
        sb_str(b, a != NULL ? a : "");
        return;
    }
    sb_str(b, "\"");
    for (const char *p = a;; p++) {
        size_t slashes = 0;
        while (*p == '\\') {
            p++;
            slashes++;
        }
        if (*p == '\0') {
            for (size_t i = 0; i < slashes * 2; i++) sb_str(b, "\\");
            break;
        } else if (*p == '"') {
            for (size_t i = 0; i < slashes * 2 + 1; i++) sb_str(b, "\\");
            sb_add(b, p, 1);
        } else {
            for (size_t i = 0; i < slashes; i++) sb_str(b, "\\");
            sb_add(b, p, 1);
        }
    }
    sb_str(b, "\"");
}

static wchar_t *win_build_env_block(const uint8_t *env_nul, int64_t env_len, int strip_mse, int explicit_env, int *out_ok) {
    *out_ok = 1;
    if (!explicit_env && env_len <= 0 && !strip_mse) {
        return NULL;
    }
    if (explicit_env && env_len <= 0) {
        wchar_t *empty = (wchar_t *)calloc(2, sizeof(wchar_t));
        if (empty == NULL) *out_ok = 0;
        return empty;
    }
    sbuf_t utf8 = { 0, 0, 0 };
    if (env_len > 0 && env_nul != NULL) {
        int64_t i = 0;
        while (i < env_len) {
            const char *entry = (const char *)(env_nul + i);
            size_t n = strnlen(entry, (size_t)(env_len - i));
            if (n > 0 && !(strip_mse && is_malloc_se_entry(entry))) {
                if (!sb_reserve(&utf8, n + 1)) {
                    free(utf8.data);
                    *out_ok = 0;
                    return NULL;
                }
                sb_add(&utf8, entry, n);
                sb_add(&utf8, "", 1);
            }
            i += (int64_t)n + 1;
        }
    } else if (!explicit_env) {
        wchar_t *block = GetEnvironmentStringsW();
        if (block != NULL) {
            for (wchar_t *p = block; *p != 0; p += wcslen(p) + 1) {
                char *s = wide_to_utf8(p);
                if (s != NULL) {
                    if (!(strip_mse && is_malloc_se_entry(s))) {
                        size_t sl = strlen(s);
                        if (!sb_reserve(&utf8, sl + 1)) {
                            free(s);
                            FreeEnvironmentStringsW(block);
                            free(utf8.data);
                            *out_ok = 0;
                            return NULL;
                        }
                        sb_add(&utf8, s, sl + 1);
                    }
                    free(s);
                }
            }
            FreeEnvironmentStringsW(block);
        }
    }
    if (utf8.len == 0) {
        free(utf8.data);
        wchar_t *empty = (wchar_t *)calloc(2, sizeof(wchar_t));
        if (empty == NULL) *out_ok = 0;
        return empty;
    }
    if (!sb_reserve(&utf8, 1)) {
        free(utf8.data);
        *out_ok = 0;
        return NULL;
    }
    sb_add(&utf8, "", 1);
    int wn = MultiByteToWideChar(CP_UTF8, 0, utf8.data, (int)utf8.len, NULL, 0);
    if (wn <= 0) {
        free(utf8.data);
        *out_ok = 0;
        return NULL;
    }
    wchar_t *wenv = (wchar_t *)calloc((size_t)wn + 2, sizeof(wchar_t));
    if (wenv == NULL) {
        free(utf8.data);
        *out_ok = 0;
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8.data, (int)utf8.len, wenv, wn);
    free(utf8.data);
    return wenv;
}

static HANDLE win_open_nul(void) {
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    return CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
}

int64_t sts_proc_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap) {
    if (program == NULL || program[0] == '\0') {
        copy_err(err_buf, err_cap, "empty program");
        return -1;
    }
    sbuf_t cmd = { 0, 0, 0 };
    win_quote_arg(&cmd, program);
    if (args_nul != NULL && args_len > 0) {
        int64_t i = 0;
        while (i < args_len) {
            const char *a = (const char *)(args_nul + i);
            size_t n = strnlen(a, (size_t)(args_len - i));
            sb_str(&cmd, " ");
            win_quote_arg(&cmd, a);
            i += (int64_t)n + 1;
        }
    }
    wchar_t *wline = utf8_to_wide(cmd.data ? cmd.data : "");
    free(cmd.data);
    int env_ok = 1;
    wchar_t *wenv = win_build_env_block(
        env_nul,
        env_len,
        (flags & STS_PROC_STRIP_MALLOC_SE) != 0,
        (flags & STS_PROC_EXPLICIT_ENV) != 0,
        &env_ok);
    wchar_t *wcwd = (cwd != NULL && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;
    if (wline == NULL || !env_ok || (cwd != NULL && cwd[0] != '\0' && wcwd == NULL)) {
        free(wline);
        free(wenv);
        free(wcwd);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }

    HANDLE child_h[3] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE };
    HANDLE mine_h[3] = { NULL, NULL, NULL };
    int pipe_flags[3] = {
        (flags & STS_PROC_PIPE_STDIN) != 0,
        (flags & STS_PROC_PIPE_STDOUT) != 0,
        (flags & STS_PROC_PIPE_STDERR) != 0
    };
    int pipes_ok = 1;
    for (int i = 0; i < 3; i++) {
        if (pipe_flags[i]) {
            HANDLE parent = NULL, child = NULL;
            if (!win_create_overlapped_pipe(i == 0, 1, &parent, &child)) {
                pipes_ok = 0;
                break;
            }
            mine_h[i] = parent;
            child_h[i] = child;
        } else {
            child_h[i] = win_open_nul();
            if (child_h[i] == INVALID_HANDLE_VALUE) {
                pipes_ok = 0;
                break;
            }
        }
    }

    SIZE_T attr_size = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attr_list = NULL;
    if (pipes_ok) {
        InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
        attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
        if (attr_list == NULL ||
            !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) ||
            !UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, child_h, sizeof(child_h), NULL, NULL)) {
            free(attr_list);
            attr_list = NULL;
            pipes_ok = 0;
        }
    }

    STARTUPINFOEXW siex;
    PROCESS_INFORMATION pi;
    memset(&siex, 0, sizeof(siex));
    memset(&pi, 0, sizeof(pi));
    siex.StartupInfo.cb = sizeof(siex);
    siex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    siex.StartupInfo.hStdInput = child_h[0];
    siex.StartupInfo.hStdOutput = child_h[1];
    siex.StartupInfo.hStdError = child_h[2];
    siex.lpAttributeList = attr_list;

    DWORD cflags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW |
                   ((flags & STS_PROC_NEW_PGID) ? (CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED) : 0);
    BOOL ok = pipes_ok && CreateProcessW(NULL, wline, NULL, NULL, TRUE, cflags, wenv, wcwd, &siex.StartupInfo, &pi);
    DWORD err = ok ? 0 : GetLastError();

    if (attr_list != NULL) {
        DeleteProcThreadAttributeList(attr_list);
        free(attr_list);
    }
    for (int i = 0; i < 3; i++) {
        if (child_h[i] != INVALID_HANDLE_VALUE) {
            CloseHandle(child_h[i]);
        }
    }
    free(wline);
    free(wenv);
    free(wcwd);

    if (!ok) {
        for (int i = 0; i < 3; i++) {
            if (mine_h[i] != NULL) CloseHandle(mine_h[i]);
        }
        char msg[256];
        win_err_str(err ? err : ERROR_NOT_ENOUGH_MEMORY, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    HANDLE h_job = NULL;
    if ((flags & STS_PROC_NEW_PGID) != 0) {
        /* Fail-closed Job Object assignment BEFORE ResumeThread (without KILL_ON_JOB_CLOSE
         * so closing the handle or station handover never kills detached lasting jobs). */
        h_job = CreateJobObjectW(NULL, NULL);
        if (h_job == NULL || !AssignProcessToJobObject(h_job, pi.hProcess)) {
            DWORD jerr = GetLastError();
            TerminateProcess(pi.hProcess, 1);
            if (h_job != NULL) CloseHandle(h_job);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            for (int i = 0; i < 3; i++) {
                if (mine_h[i] != NULL) CloseHandle(mine_h[i]);
            }
            char msg[256];
            win_err_str(jerr ? jerr : ERROR_ACCESS_DENIED, msg, sizeof(msg));
            copy_err(err_buf, err_cap, msg);
            return -1;
        }
        if (ResumeThread(pi.hThread) == (DWORD)-1) {
            DWORD rerr = GetLastError();
            if (h_job != NULL) {
                TerminateJobObject(h_job, 1);
                CloseHandle(h_job);
            }
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            for (int i = 0; i < 3; i++) {
                if (mine_h[i] != NULL) CloseHandle(mine_h[i]);
            }
            char msg[256];
            win_err_str(rerr ? rerr : ERROR_ACCESS_DENIED, msg, sizeof(msg));
            copy_err(err_buf, err_cap, msg);
            return -1;
        }
    }
    CloseHandle(pi.hThread);

    win_proc_t *p = (win_proc_t *)calloc(1, sizeof(*p));
    if (p == NULL) {
        if (h_job != NULL) {
            TerminateJobObject(h_job, 1);
            CloseHandle(h_job);
        } else {
            TerminateProcess(pi.hProcess, 1);
        }
        for (int i = 0; i < 3; i++) {
            if (mine_h[i] != NULL) CloseHandle(mine_h[i]);
        }
        CloseHandle(pi.hProcess);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    p->event_id = event_id;
    p->h_proc = pi.hProcess;
    p->h_job = h_job;
    p->pid = pi.dwProcessId;
    p->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    p->h_stdin = mine_h[0];
    p->h_stdout = mine_h[1];
    p->h_stderr = mine_h[2];
    InitializeSRWLock(&p->kill_lock);
    InitializeSRWLock(&p->stdin_lock);
    InitializeConditionVariable(&p->stdin_cond);
    InitializeSRWLock(&p->ref_lock);
    p->refs = 1;

    int workers_ok = (p->h_stop != NULL);
    if (workers_ok && p->h_stdin != NULL) {
        win_proc_ref(p);
        if (!win_spawn_detached_thread(win_stdin_thread, p)) {
            win_proc_unref(p);
            workers_ok = 0;
        }
    }
    if (workers_ok && p->h_stdout != NULL) {
        win_pipe_arg_t *pa = (win_pipe_arg_t *)malloc(sizeof(*pa));
        if (pa == NULL) {
            workers_ok = 0;
        } else {
            pa->proc = p;
            pa->h_pipe = p->h_stdout;
            pa->data_tag = STS_EV_PROC_STDOUT;
            pa->eof_tag = STS_EV_PROC_STDOUT_EOF;
            win_proc_ref(p);
            if (!win_spawn_detached_thread(win_pipe_reader_thread, pa)) {
                free(pa);
                win_proc_unref(p);
                workers_ok = 0;
            }
        }
    }
    if (workers_ok && p->h_stderr != NULL) {
        win_pipe_arg_t *pa = (win_pipe_arg_t *)malloc(sizeof(*pa));
        if (pa == NULL) {
            workers_ok = 0;
        } else {
            pa->proc = p;
            pa->h_pipe = p->h_stderr;
            pa->data_tag = STS_EV_PROC_STDERR;
            pa->eof_tag = STS_EV_PROC_STDERR_EOF;
            win_proc_ref(p);
            if (!win_spawn_detached_thread(win_pipe_reader_thread, pa)) {
                free(pa);
                win_proc_unref(p);
                workers_ok = 0;
            }
        }
    }
    int64_t id = workers_ok ? ht_insert(STS_HK_PROC, p) : -1;
    if (id > 0) {
        win_proc_ref(p);
        if (!win_spawn_reaper_thread(win_wait_thread, p)) {
            win_proc_unref(p);
            (void)ht_take(STS_HK_PROC, id);
            id = -1;
        }
    }
    if (id < 0) {
        AcquireSRWLockExclusive(&p->kill_lock);
        atomic_store_explicit(&p->closing, 1, memory_order_release);
        if (p->h_job != NULL) {
            TerminateJobObject(p->h_job, 1);
        }
        TerminateProcess(p->h_proc, 1);
        ReleaseSRWLockExclusive(&p->kill_lock);
        if (p->h_stop != NULL) SetEvent(p->h_stop);
        AcquireSRWLockExclusive(&p->stdin_lock);
        p->stdin_aborted = 1;
        WakeConditionVariable(&p->stdin_cond);
        ReleaseSRWLockExclusive(&p->stdin_lock);
        win_proc_unref(p);
        copy_err(err_buf, err_cap, "worker spawn failed");
        return -1;
    }
    if (out_pid != NULL) {
        *out_pid = (int64_t)p->pid;
    }
    return id;
}

static win_proc_t *win_proc_get(int64_t handle) {
    if (handle <= 0) return NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    win_proc_t *p = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_PROC) {
            p = (win_proc_t *)cur->ptr;
            AcquireSRWLockExclusive(&p->ref_lock);
            p->refs += 1;
            ReleaseSRWLockExclusive(&p->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    return p;
}

int32_t sts_proc_write_stdin(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    win_proc_t *p = win_proc_get(handle);
    if (p == NULL) return 0;
    AcquireSRWLockExclusive(&p->stdin_lock);
    if (p->h_stdin == NULL || p->stdin_eof || p->stdin_aborted) {
        ReleaseSRWLockExclusive(&p->stdin_lock);
        win_proc_unref(p);
        return 0;
    }
    if (len == 0) {
        ReleaseSRWLockExclusive(&p->stdin_lock);
        win_proc_unref(p);
        return 1;
    }
    size_t ulen = (size_t)len;
    if (ulen > STS_STDIN_QUEUE_MAX || p->stdin_queued > STS_STDIN_QUEUE_MAX - ulen) {
        ReleaseSRWLockExclusive(&p->stdin_lock);
        win_proc_unref(p);
        return 0;
    }
    sts_chunk_t *ch = (sts_chunk_t *)malloc(sizeof(*ch) + ulen);
    if (ch == NULL) {
        ReleaseSRWLockExclusive(&p->stdin_lock);
        win_proc_unref(p);
        return 0;
    }
    ch->next = NULL;
    ch->len = ulen;
    ch->off = 0;
    memcpy(ch->data, data, ulen);
    if (p->stdin_tail != NULL) p->stdin_tail->next = ch;
    else p->stdin_head = ch;
    p->stdin_tail = ch;
    p->stdin_queued += ulen;
    WakeConditionVariable(&p->stdin_cond);
    ReleaseSRWLockExclusive(&p->stdin_lock);
    win_proc_unref(p);
    return 1;
}

int32_t sts_proc_close_stdin(int64_t handle) {
    win_proc_t *p = win_proc_get(handle);
    if (p == NULL) return 0;
    AcquireSRWLockExclusive(&p->stdin_lock);
    p->stdin_eof = 1;
    WakeConditionVariable(&p->stdin_cond);
    ReleaseSRWLockExclusive(&p->stdin_lock);
    win_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill_handle(int64_t handle, int32_t sig, int32_t group) {
    if (sig == STS_SIG_STOP || sig == STS_SIG_CONT) {
        return -1;
    }
    win_proc_t *p = win_proc_get(handle);
    if (p == NULL) return -1;
    AcquireSRWLockExclusive(&p->kill_lock);
    if (p->exited) {
        int32_t rc = -1;
        if (group && sig != STS_SIG_PROBE && p->h_job != NULL) {
            rc = TerminateJobObject(p->h_job, 1) ? 0 : -1;
        }
        ReleaseSRWLockExclusive(&p->kill_lock);
        win_proc_unref(p);
        return rc;
    }
    int32_t rc = -1;
    if (sig == STS_SIG_PROBE) {
        rc = (WaitForSingleObject(p->h_proc, 0) == WAIT_TIMEOUT) ? 0 : -1;
    } else if (group) {
        if (p->h_job != NULL) {
            rc = TerminateJobObject(p->h_job, 1) ? 0 : -1;
        } else {
            rc = TerminateProcess(p->h_proc, 1) ? 0 : -1;
        }
    } else {
        rc = TerminateProcess(p->h_proc, 1) ? 0 : -1;
    }
    ReleaseSRWLockExclusive(&p->kill_lock);
    win_proc_unref(p);
    return rc;
}

int32_t sts_proc_close(int64_t handle) {
    win_proc_t *p = (win_proc_t *)ht_take(STS_HK_PROC, handle);
    if (p == NULL) return 0;
    AcquireSRWLockExclusive(&p->kill_lock);
    atomic_store_explicit(&p->closing, 1, memory_order_release);
    ReleaseSRWLockExclusive(&p->kill_lock);
    SetEvent(p->h_stop);
    AcquireSRWLockExclusive(&p->stdin_lock);
    p->stdin_aborted = 1;
    WakeConditionVariable(&p->stdin_cond);
    ReleaseSRWLockExclusive(&p->stdin_lock);
    win_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill(int32_t pid, int32_t sig, int32_t group) {
    if (pid <= 0) return -1;
    if (sig == STS_SIG_STOP || sig == STS_SIG_CONT) {
        return -1;
    }
    if (sig == STS_SIG_PROBE) {
        HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
        if (h == NULL) return GetLastError() == ERROR_ACCESS_DENIED ? 0 : -1;
        int alive = (WaitForSingleObject(h, 0) == WAIT_TIMEOUT);
        CloseHandle(h);
        return alive ? 0 : -1;
    }
    if (group) {
        wchar_t line[96];
        swprintf(line, 96, L"taskkill /T /F /PID %d", (int)pid);
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        memset(&si, 0, sizeof(si));
        memset(&pi, 0, sizeof(pi));
        si.cb = sizeof(si);
        if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
            return -1;
        }
        WaitForSingleObject(pi.hProcess, 30000);
        DWORD code = 1;
        GetExitCodeProcess(pi.hProcess, &code);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return code == 0 ? 0 : -1;
    }
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
    if (h == NULL) return -1;
    BOOL ok = TerminateProcess(h, 1);
    CloseHandle(h);
    return ok ? 0 : -1;
}

int64_t sts_proc_start_time_ms(int32_t pid) {
    if (pid <= 0) return -1;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (h == NULL) return -1;
    FILETIME create_t, exit_t, kernel_t, user_t;
    BOOL ok = GetProcessTimes(h, &create_t, &exit_t, &kernel_t, &user_t);
    CloseHandle(h);
    if (!ok) return -1;
    uint64_t v = ft64(create_t);
    if (v < 116444736000000000ULL) return -1;
    return (int64_t)((v - 116444736000000000ULL) / 10000ULL);
}

int64_t sts_proc_start_ticks(int32_t pid) {
    (void)pid;
    return -1;
}

void *sts_boot_id(int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    return NULL;
}

// ---------------------------------------------------------------------------
// 3. Windows Launcher Control Channel (Named Pipe)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    HANDLE h_pipe;
    HANDLE h_stop;
    HANDLE h_thread;
    SRWLOCK write_lock;
    SRWLOCK ref_lock;
    int refs;
} win_ctrl_t;

static void win_ctrl_unref(win_ctrl_t *c) {
    AcquireSRWLockExclusive(&c->ref_lock);
    int last = (--c->refs == 0);
    ReleaseSRWLockExclusive(&c->ref_lock);
    if (!last) return;
    if (c->h_pipe != INVALID_HANDLE_VALUE) CloseHandle(c->h_pipe);
    if (c->h_stop != NULL) CloseHandle(c->h_stop);
    free(c);
}

static DWORD WINAPI win_ctrl_reader_thread(LPVOID arg) {
    win_ctrl_t *c = (win_ctrl_t *)arg;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (h_io == NULL) {
        push_tag_ctrl(c->event_id, STS_EV_CTRL_EOF, NULL, 0);
        return 0;
    }
    sbuf_t line = { 0, 0, 0 };
    char buf[4096];
    int eof = 0;
    int line_overflow = 0;
    for (;;) {
        ResetEvent(h_io);
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = h_io;
        DWORD n = 0;
        BOOL ok = ReadFile(c->h_pipe, buf, sizeof(buf), &n, &ov);
        if (!ok) {
            DWORD err = GetLastError();
            if (err == ERROR_IO_PENDING) {
                HANDLE waits[2] = { h_io, c->h_stop };
                DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wr == WAIT_OBJECT_0 + 1) {
                    CancelIoEx(c->h_pipe, &ov);
                    DWORD dummy = 0;
                    GetOverlappedResult(c->h_pipe, &ov, &dummy, TRUE);
                    break;
                }
                if (wr != WAIT_OBJECT_0 || !GetOverlappedResult(c->h_pipe, &ov, &n, FALSE)) {
                    eof = 1;
                    break;
                }
            } else {
                eof = 1;
                break;
            }
        }
        if (n == 0) {
            eof = 1;
            break;
        }
        for (DWORD i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                if (line_overflow) {
                    const char *ovf = "__CTRL_LINE_OVERFLOW__";
                    push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, ovf, strlen(ovf));
                    line_overflow = 0;
                    line.len = 0;
                } else {
                    size_t ll = line.len;
                    if (ll > 0 && line.data[ll - 1] == '\r') ll -= 1;
                    push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data ? line.data : "", ll);
                    line.len = 0;
                }
            } else if (!line_overflow) {
                if (line.len >= STS_CTRL_MAX_LINE) {
                    free(line.data);
                    line.data = NULL;
                    line.len = 0;
                    line.cap = 0;
                    line_overflow = 1;
                } else {
                    sb_add(&line, buf + i, 1);
                }
            }
        }
    }
    if (eof) {
        // Discard any unterminated partial frame at EOF (never deliver as a complete line).
        push_tag_ctrl(c->event_id, STS_EV_CTRL_EOF, NULL, 0);
    }
    free(line.data);
    CloseHandle(h_io);
    return 0;
}

int64_t sts_ctrl_open_fd(uint64_t event_id, int32_t fd) {
    (void)event_id;
    (void)fd;
    return -1;
}

int64_t sts_ctrl_open_pipe(uint64_t event_id, const char *pipe_name) {
    if (pipe_name == NULL || pipe_name[0] == '\0') return -1;
    wchar_t *wname = utf8_to_wide(pipe_name);
    if (wname == NULL) return -1;
    HANDLE h = CreateFileW(wname, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    free(wname);
    if (h == INVALID_HANDLE_VALUE) return -1;
    win_ctrl_t *c = (win_ctrl_t *)calloc(1, sizeof(*c));
    if (c == NULL) {
        CloseHandle(h);
        return -1;
    }
    c->event_id = event_id;
    c->h_pipe = h;
    c->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    InitializeSRWLock(&c->write_lock);
    InitializeSRWLock(&c->ref_lock);
    c->refs = 1;
    c->h_thread = CreateThread(NULL, 0, win_ctrl_reader_thread, c, 0, NULL);
    if (c->h_thread == NULL) {
        win_ctrl_unref(c);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_CTRL, c);
    if (id < 0) {
        SetEvent(c->h_stop);
        WaitForSingleObject(c->h_thread, INFINITE);
        CloseHandle(c->h_thread);
        win_ctrl_unref(c);
    }
    return id;
}

int32_t sts_ctrl_write(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (data == NULL) return 0;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    win_ctrl_t *c = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_CTRL) {
            c = (win_ctrl_t *)cur->ptr;
            AcquireSRWLockExclusive(&c->ref_lock);
            c->refs += 1;
            ReleaseSRWLockExclusive(&c->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    if (c == NULL) return 0;

    AcquireSRWLockExclusive(&c->write_lock);
    HANDLE h_ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    int ok = 1;
    size_t done = 0;
    while (h_ev != NULL && done < (size_t)len) {
        ResetEvent(h_ev);
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = h_ev;
        DWORD want = ((size_t)len - done) > 0x7fffffffu ? 0x7fffffffu : (DWORD)((size_t)len - done);
        DWORD n = 0;
        BOOL wr = WriteFile(c->h_pipe, data + done, want, &n, &ov);
        if (!wr) {
            if (GetLastError() == ERROR_IO_PENDING) {
                HANDLE waits[2] = { h_ev, c->h_stop };
                DWORD wrc = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wrc == WAIT_OBJECT_0 + 1) {
                    CancelIoEx(c->h_pipe, &ov);
                    DWORD dummy = 0;
                    GetOverlappedResult(c->h_pipe, &ov, &dummy, TRUE);
                    ok = 0;
                    break;
                }
                if (wrc != WAIT_OBJECT_0 || !GetOverlappedResult(c->h_pipe, &ov, &n, FALSE)) {
                    ok = 0;
                    break;
                }
            } else {
                ok = 0;
                break;
            }
        }
        if (n == 0) {
            ok = 0;
            break;
        }
        done += (size_t)n;
    }
    if (h_ev != NULL) CloseHandle(h_ev);
    else ok = 0;
    ReleaseSRWLockExclusive(&c->write_lock);
    win_ctrl_unref(c);
    return ok;
}

int32_t sts_ctrl_close(int64_t handle) {
    win_ctrl_t *c = (win_ctrl_t *)ht_take(STS_HK_CTRL, handle);
    if (c == NULL) return 0;
    SetEvent(c->h_stop);
    WaitForSingleObject(c->h_thread, INFINITE);
    CloseHandle(c->h_thread);
    win_ctrl_unref(c);
    return 1;
}

// ---------------------------------------------------------------------------
// 4. Windows Signals (SetConsoleCtrlHandler)
// ---------------------------------------------------------------------------

static SRWLOCK g_win_sig_lock = SRWLOCK_INIT;
static uint64_t g_win_sig_event_id = 0;
static int g_win_sig_active = 0;

static BOOL WINAPI win_ctrl_handler(DWORD kind) {
    int32_t sig = STS_SIG_TERM;
    const char *name = "SIGTERM";
    if (kind == CTRL_C_EVENT) {
        sig = STS_SIG_INT;
        name = "SIGINT";
    } else if (kind == CTRL_BREAK_EVENT) {
        sig = 21;
        name = "SIGBREAK";
    }
    size_t nlen = strlen(name);
    uint8_t msg[64];
    msg[0] = STS_EV_SIGNAL;
    put_i32_le(msg + 1, sig);
    memcpy(msg + 5, name, nlen);
    AcquireSRWLockExclusive(&g_win_sig_lock);
    int active = g_win_sig_active;
    if (active) {
        sth_push_sys(g_win_sig_event_id, msg, 5 + nlen);
    }
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    return active ? TRUE : FALSE;
}

int32_t sts_signal_watch(uint64_t event_id) {
    AcquireSRWLockExclusive(&g_win_sig_lock);
    g_win_sig_event_id = event_id;
    int ok = 1;
    if (!g_win_sig_active) {
        if (SetConsoleCtrlHandler(win_ctrl_handler, TRUE)) {
            g_win_sig_active = 1;
        } else {
            ok = 0;
        }
    }
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    return ok;
}

int32_t sts_signal_unwatch(void) {
    AcquireSRWLockExclusive(&g_win_sig_lock);
    if (g_win_sig_active) {
        SetConsoleCtrlHandler(win_ctrl_handler, FALSE);
        g_win_sig_active = 0;
    }
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    return 1;
}

// ---------------------------------------------------------------------------
// 5. Windows Advisory File Lock (LockFileEx non-blocking)
// ---------------------------------------------------------------------------

int64_t sts_flock_try(const char *path) {
    if (path == NULL || path[0] == '\0') return -1;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return -1;
    HANDLE h = CreateFileW(
        w,
        GENERIC_READ | FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return -1;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &ov)) {
        DWORD err = GetLastError();
        CloseHandle(h);
        return (err == ERROR_LOCK_VIOLATION) ? 0 : -1;
    }
    int64_t id = ht_insert(STS_HK_FLOCK, (void *)h);
    if (id < 0) {
        UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
        CloseHandle(h);
    }
    return id;
}

int32_t sts_flock_unlock(int64_t handle) {
    HANDLE h = (HANDLE)ht_take(STS_HK_FLOCK, handle);
    if (h == NULL) return 0;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
    return CloseHandle(h) ? 1 : 0;
}

int32_t sts_unlink(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    BOOL ok = DeleteFileW(w);
    free(w);
    return ok ? 1 : 0;
}

int32_t sts_rmdir(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    BOOL ok = RemoveDirectoryW(w);
    free(w);
    return ok ? 1 : 0;
}

void *sts_readlink(const char *path, int64_t *out_len) {
    (void)path;
    if (out_len != NULL) *out_len = 0;
    return NULL;
}

static int32_t sts_win_map_err(DWORD err) {
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND || err == ERROR_INVALID_NAME) return -2;
    if (err == ERROR_ACCESS_DENIED || err == ERROR_SHARING_VIOLATION || err == ERROR_PRIVILEGE_NOT_HELD) return -3;
    if (err == ERROR_DIRECTORY) return -4;
    return -1;
}

void *sts_realpath_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    HANDLE h = CreateFileW(
        w,
        0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL);
    DWORD open_err = GetLastError();
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        if (out_err != NULL) *out_err = sts_win_map_err(open_err);
        return NULL;
    }
    DWORD need = GetFinalPathNameByHandleW(h, NULL, 0, FILE_NAME_NORMALIZED);
    if (need == 0) {
        DWORD e = GetLastError();
        CloseHandle(h);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return NULL;
    }
    wchar_t *buf = (wchar_t *)malloc((size_t)(need + 1) * sizeof(wchar_t));
    if (buf == NULL) {
        CloseHandle(h);
        return NULL;
    }
    DWORD got = GetFinalPathNameByHandleW(h, buf, need + 1, FILE_NAME_NORMALIZED);
    DWORD gerr = GetLastError();
    CloseHandle(h);
    if (got == 0 || got > need) {
        free(buf);
        if (out_err != NULL) *out_err = sts_win_map_err(gerr);
        return NULL;
    }
    wchar_t *src = buf;
    if (wcsncmp(src, L"\\\\?\\UNC\\", 8) == 0) {
        src[6] = L'\\';
        src += 6;
    } else if (wcsncmp(src, L"\\\\?\\", 4) == 0) {
        src += 4;
    }
    char *u8 = wide_to_utf8(src);
    free(buf);
    if (u8 == NULL) return NULL;
    void *res = dup_bytes(u8, strlen(u8), out_len);
    free(u8);
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_realpath(const char *path, int64_t *out_len) {
    return sts_realpath_err(path, out_len, NULL);
}

void *sts_lstat_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(w, GetFileExInfoStandard, &fad)) {
        DWORD e = GetLastError();
        free(w);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return NULL;
    }
    const char *kind = (fad.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? "link"
                     : (fad.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "dir"
                     : "file";
    uint64_t fsz = ((uint64_t)fad.nFileSizeHigh << 32) | (uint64_t)fad.nFileSizeLow;
    uint64_t ft = ((uint64_t)fad.ftLastWriteTime.dwHighDateTime << 32) | (uint64_t)fad.ftLastWriteTime.dwLowDateTime;
    int64_t mtime_ms = (ft >= 116444736000000000ULL) ? (int64_t)((ft - 116444736000000000ULL) / 10000ULL) : 0;
    uint64_t dev = 0, ino = 0;
    HANDLE h = CreateFileW(
        w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(w);
    if (h != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION bi;
        if (GetFileInformationByHandle(h, &bi)) {
            dev = (uint64_t)bi.dwVolumeSerialNumber;
            ino = ((uint64_t)bi.nFileIndexHigh << 32) | (uint64_t)bi.nFileIndexLow;
        }
        CloseHandle(h);
    }
    char buf[192];
    int n = snprintf(
        buf, sizeof(buf), "%s|%llu|0|%lld|%llu|%llu",
        kind, (unsigned long long)fsz, (long long)mtime_ms,
        (unsigned long long)dev, (unsigned long long)ino);
    void *res = n > 0 ? dup_bytes(buf, (size_t)n, out_len) : NULL;
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_lstat(const char *path, int64_t *out_len) {
    return sts_lstat_err(path, out_len, NULL);
}

void *sts_stat_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    HANDLE h = CreateFileW(
        w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD open_err = GetLastError();
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        if (out_err != NULL) *out_err = sts_win_map_err(open_err);
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION bi;
    if (!GetFileInformationByHandle(h, &bi)) {
        DWORD e = GetLastError();
        CloseHandle(h);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return NULL;
    }
    CloseHandle(h);
    const char *kind = (bi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "dir" : "file";
    uint64_t fsz = (bi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                     ? 0ULL
                     : (((uint64_t)bi.nFileSizeHigh << 32) | (uint64_t)bi.nFileSizeLow);
    uint64_t ft = ((uint64_t)bi.ftLastWriteTime.dwHighDateTime << 32) | (uint64_t)bi.ftLastWriteTime.dwLowDateTime;
    int64_t mtime_ms = (ft >= 116444736000000000ULL) ? (int64_t)((ft - 116444736000000000ULL) / 10000ULL) : 0;
    uint64_t dev = (uint64_t)bi.dwVolumeSerialNumber;
    uint64_t ino = ((uint64_t)bi.nFileIndexHigh << 32) | (uint64_t)bi.nFileIndexLow;
    unsigned int mode = (bi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 0755u : 0644u;
    char buf[192];
    int n = snprintf(
        buf, sizeof(buf), "%s|%llu|0|%lld|%llu|%llu|%u",
        kind, (unsigned long long)fsz, (long long)mtime_ms,
        (unsigned long long)dev, (unsigned long long)ino, mode);
    void *res = n > 0 ? dup_bytes(buf, (size_t)n, out_len) : NULL;
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_stat(const char *path, int64_t *out_len) {
    return sts_stat_err(path, out_len, NULL);
}

int32_t sts_chmod(const char *path, int32_t mode) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    int rc = _wchmod(w, (mode & 0200) ? (_S_IREAD | _S_IWRITE) : _S_IREAD);
    free(w);
    return rc == 0 ? 1 : 0;
}

int32_t sts_truncate_in_place(const char *path, int64_t size) {
    if (path == NULL || path[0] == '\0' || size < 0) return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    HANDLE h = CreateFileW(
        w, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER li;
    li.QuadPart = size;
    BOOL ok = SetFilePointerEx(h, li, NULL, FILE_BEGIN) && SetEndOfFile(h);
    CloseHandle(h);
    return ok ? 1 : 0;
}

void *sts_read_range(const char *path, int64_t offset, int64_t len, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0) return NULL;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    HANDLE h = CreateFileW(
        w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    if (len == 0) {
        CloseHandle(h);
        return dup_bytes("", 0, out_len);
    }
    LARGE_INTEGER li;
    li.QuadPart = offset;
    if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN)) {
        CloseHandle(h);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)len);
    if (buf == NULL) {
        CloseHandle(h);
        return NULL;
    }
    int64_t total = 0;
    while (total < len) {
        DWORD chunk = (DWORD)((len - total) > 0x7fffffffLL ? 0x7fffffffLL : (len - total));
        DWORD got = 0;
        if (!ReadFile(h, buf + total, chunk, &got, NULL) || got == 0) break;
        total += (int64_t)got;
    }
    CloseHandle(h);
    if (out_len != NULL) *out_len = total;
    return buf;
}

static int32_t sts_win_map_open_err(const wchar_t *w, DWORD err, int32_t dir_code) {
    if (err == ERROR_ACCESS_DENIED && w != NULL) {
        DWORD attrs = GetFileAttributesW(w);
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            return dir_code;
        }
    }
    return sts_win_map_err(err);
}

static int sts_win_is_name_surrogate_reparse(const FILE_ATTRIBUTE_TAG_INFO *ati) {
    /* Bit 29 (0x20000000) is IsReparseTagNameSurrogate: matches symlinks, junctions,
     * and mount points while allowing non-surrogate tags like OneDrive IO_REPARSE_TAG_CLOUD_*
     * and Windows Dedup IO_REPARSE_TAG_DEDUP. */
    return ((ati->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) &&
           ((ati->ReparseTag & 0x20000000U) != 0);
}

void *sts_read_range_meta(
    const char *path,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_total_size,
    int64_t *out_mtime_ms,
    int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_total_size != NULL) *out_total_size = 0;
    if (out_mtime_ms != NULL) *out_mtime_ms = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) {
        if (out_err != NULL) *out_err = -6;
        return NULL;
    }
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    HANDLE h = CreateFileW(
        w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD open_err = GetLastError();
    if (h == INVALID_HANDLE_VALUE) {
        int32_t mapped = sts_win_map_open_err(w, open_err, -4);
        free(w);
        if (out_err != NULL) *out_err = mapped;
        return NULL;
    }
    free(w);
    if (GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -5;
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION bi;
    if (!GetFileInformationByHandle(h, &bi)) {
        DWORD e = GetLastError();
        CloseHandle(h);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return NULL;
    }
    if ((bi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -4;
        return NULL;
    }
    uint64_t fsz = ((uint64_t)bi.nFileSizeHigh << 32) | (uint64_t)bi.nFileSizeLow;
    uint64_t ft = ((uint64_t)bi.ftLastWriteTime.dwHighDateTime << 32) | (uint64_t)bi.ftLastWriteTime.dwLowDateTime;
    int64_t mtime_ms = (ft >= 116444736000000000ULL) ? (int64_t)((ft - 116444736000000000ULL) / 10000ULL) : 0;
    if (out_total_size != NULL) *out_total_size = (int64_t)fsz;
    if (out_mtime_ms != NULL) *out_mtime_ms = mtime_ms;
    if (len == 0 || (uint64_t)offset >= fsz) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = 0;
        return dup_bytes("", 0, out_len);
    }
    uint64_t avail = fsz - (uint64_t)offset;
    int64_t want = (uint64_t)len < avail ? len : (int64_t)avail;
    uint8_t *buf = (uint8_t *)malloc((size_t)(want > 0 ? want : 1));
    if (buf == NULL) {
        CloseHandle(h);
        return NULL;
    }
    int64_t total = 0;
    while (total < want) {
        uint64_t cur = (uint64_t)offset + (uint64_t)total;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.Offset = (DWORD)(cur & 0xFFFFFFFFULL);
        ov.OffsetHigh = (DWORD)((cur >> 32) & 0xFFFFFFFFULL);
        DWORD chunk = (DWORD)((want - total) > 0x7fffffffLL ? 0x7fffffffLL : (want - total));
        DWORD got = 0;
        if (!ReadFile(h, buf + total, chunk, &got, &ov)) {
            DWORD e = GetLastError();
            if (e == ERROR_HANDLE_EOF) break;
            free(buf);
            CloseHandle(h);
            if (out_err != NULL) *out_err = sts_win_map_err(e);
            return NULL;
        }
        if (got == 0) break;
        total += (int64_t)got;
    }
    CloseHandle(h);
    if (out_len != NULL) *out_len = total;
    if (out_err != NULL) *out_err = 0;
    return buf;
}

int32_t sts_write_at(
    const char *path,
    int64_t offset,
    const uint8_t *data,
    int64_t len,
    int32_t create,
    int32_t has_at_least,
    int64_t at_least,
    int32_t has_truncate,
    int64_t truncate_to,
    int32_t do_sync,
    int64_t *out_size,
    int32_t *out_short) {
    if (out_size != NULL) *out_size = 0;
    if (out_short != NULL) *out_short = 0;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) return -6;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return -1;
    DWORD disp = create ? OPEN_ALWAYS : OPEN_EXISTING;
    HANDLE h = CreateFileW(
        w, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, disp, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD open_err = GetLastError();
    if (h == INVALID_HANDLE_VALUE) {
        int32_t mapped = sts_win_map_open_err(w, open_err, -5);
        free(w);
        return mapped;
    }
    free(w);
    if (GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        return -5;
    }
    FILE_ATTRIBUTE_TAG_INFO ati;
    if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ati, sizeof(ati))) {
        DWORD e = GetLastError();
        CloseHandle(h);
        return sts_win_map_err(e);
    }
    if ((ati.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 || sts_win_is_name_surrogate_reparse(&ati)) {
        CloseHandle(h);
        return -5;
    }
    if (create) {
        LARGE_INTEGER zero;
        zero.QuadPart = 0;
        if (!SetFilePointerEx(h, zero, NULL, FILE_BEGIN) || !SetEndOfFile(h)) {
            DWORD e = GetLastError();
            CloseHandle(h);
            return sts_win_map_err(e);
        }
    }
    LARGE_INTEGER cur_sz;
    if (!GetFileSizeEx(h, &cur_sz)) {
        DWORD e = GetLastError();
        CloseHandle(h);
        return sts_win_map_err(e);
    }
    if (has_at_least && (int64_t)cur_sz.QuadPart < at_least) {
        if (out_size != NULL) *out_size = (int64_t)cur_sz.QuadPart;
        if (out_short != NULL) *out_short = 1;
        CloseHandle(h);
        return 0;
    }
    int64_t written = 0;
    while (written < len) {
        uint64_t cur = (uint64_t)offset + (uint64_t)written;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.Offset = (DWORD)(cur & 0xFFFFFFFFULL);
        ov.OffsetHigh = (DWORD)((cur >> 32) & 0xFFFFFFFFULL);
        DWORD chunk = (DWORD)((len - written) > 0x7fffffffLL ? 0x7fffffffLL : (len - written));
        DWORD put = 0;
        if (!WriteFile(h, data + written, chunk, &put, &ov)) {
            DWORD e = GetLastError();
            CloseHandle(h);
            return sts_win_map_err(e);
        }
        if (put == 0) {
            CloseHandle(h);
            return -1;
        }
        written += (int64_t)put;
    }
    if (has_truncate && truncate_to >= 0) {
        LARGE_INTEGER li;
        li.QuadPart = truncate_to;
        if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN) || !SetEndOfFile(h)) {
            DWORD e = GetLastError();
            CloseHandle(h);
            return sts_win_map_err(e);
        }
    }
    if (do_sync) {
        if (!FlushFileBuffers(h)) {
            DWORD e = GetLastError();
            CloseHandle(h);
            return sts_win_map_err(e);
        }
    }
    LARGE_INTEGER end_sz;
    if (!GetFileSizeEx(h, &end_sz)) {
        DWORD e = GetLastError();
        CloseHandle(h);
        return sts_win_map_err(e);
    }
    if (out_size != NULL) *out_size = (int64_t)end_sz.QuadPart;
    CloseHandle(h);
    return 0;
}

int32_t sts_sync_file(const char *path) {
    if (path == NULL || path[0] == '\0') return -6;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return -1;
    HANDLE h = CreateFileW(
        w, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD open_err = GetLastError();
    if (h == INVALID_HANDLE_VALUE) {
        int32_t mapped = sts_win_map_open_err(w, open_err, -5);
        free(w);
        return mapped;
    }
    free(w);
    if (GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        return -5;
    }
    FILE_ATTRIBUTE_TAG_INFO ati;
    if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ati, sizeof(ati))) {
        DWORD e = GetLastError();
        CloseHandle(h);
        return sts_win_map_err(e);
    }
    if ((ati.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 || sts_win_is_name_surrogate_reparse(&ati)) {
        CloseHandle(h);
        return -5;
    }
    BOOL ok = FlushFileBuffers(h);
    DWORD ferr = GetLastError();
    CloseHandle(h);
    return ok ? 0 : sts_win_map_err(ferr);
}

typedef struct {
    HANDLE h;
    int refs;
    int closed;
} win_file_ro_t;

int64_t sts_file_open_ro(const char *path, int64_t *out_size, int32_t *out_err) {
    if (out_size != NULL) *out_size = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') {
        if (out_err != NULL) *out_err = -6;
        return -1;
    }
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return -1;
    HANDLE h = CreateFileW(
        w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD open_err = GetLastError();
    if (h == INVALID_HANDLE_VALUE) {
        int32_t mapped = sts_win_map_open_err(w, open_err, -4);
        free(w);
        if (out_err != NULL) *out_err = mapped;
        return -1;
    }
    free(w);
    if (GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -5;
        return -1;
    }
    FILE_ATTRIBUTE_TAG_INFO ati;
    if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ati, sizeof(ati))) {
        DWORD e = GetLastError();
        CloseHandle(h);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return -1;
    }
    if ((ati.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -4;
        return -1;
    }
    if (sts_win_is_name_surrogate_reparse(&ati)) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -5;
        return -1;
    }
    LARGE_INTEGER li;
    if (!GetFileSizeEx(h, &li)) {
        DWORD e = GetLastError();
        CloseHandle(h);
        if (out_err != NULL) *out_err = sts_win_map_err(e);
        return -1;
    }
    win_file_ro_t *f = (win_file_ro_t *)malloc(sizeof(*f));
    if (f == NULL) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = -1;
        return -1;
    }
    f->h = h;
    f->refs = 1;
    f->closed = 0;
    int64_t id = ht_insert(STS_HK_FILE_RO, f);
    if (id < 0) {
        CloseHandle(h);
        free(f);
        if (out_err != NULL) *out_err = -1;
        return -1;
    }
    if (out_size != NULL) *out_size = (int64_t)li.QuadPart;
    if (out_err != NULL) *out_err = 0;
    return id;
}

void *sts_file_pread(int64_t handle, int64_t offset, int64_t len, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (handle <= 0 || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) {
        if (out_err != NULL) *out_err = -6;
        return NULL;
    }
    win_file_ro_t *f = NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    for (sts_hnode_t *cur = g_ht_buckets[b]; cur != NULL; cur = cur->next) {
        if (cur->id == handle && cur->kind == STS_HK_FILE_RO) {
            win_file_ro_t *cand = (win_file_ro_t *)cur->ptr;
            if (!cand->closed) {
                cand->refs += 1;
                f = cand;
            }
            break;
        }
    }
    ht_unlock();
    if (f == NULL) {
        if (out_err != NULL) *out_err = -2;
        return NULL;
    }
    void *res = NULL;
    int32_t err = 0;
    if (len == 0) {
        res = dup_bytes("", 0, out_len);
        if (res == NULL) err = -1;
    } else {
        uint8_t *buf = (uint8_t *)malloc((size_t)len);
        if (buf == NULL) {
            err = -1;
        } else {
            int64_t total = 0;
            while (total < len) {
                uint64_t cur = (uint64_t)offset + (uint64_t)total;
                OVERLAPPED ov;
                memset(&ov, 0, sizeof(ov));
                ov.Offset = (DWORD)(cur & 0xFFFFFFFFULL);
                ov.OffsetHigh = (DWORD)((cur >> 32) & 0xFFFFFFFFULL);
                DWORD chunk = (DWORD)((len - total) > 0x7fffffffLL ? 0x7fffffffLL : (len - total));
                DWORD got = 0;
                if (!ReadFile(f->h, buf + total, chunk, &got, &ov)) {
                    DWORD e = GetLastError();
                    if (e == ERROR_HANDLE_EOF) break;
                    free(buf);
                    buf = NULL;
                    err = sts_win_map_err(e);
                    break;
                }
                if (got == 0) break;
                total += (int64_t)got;
            }
            if (buf != NULL) {
                if (out_len != NULL) *out_len = total;
                res = buf;
            }
        }
    }
    int should_free = 0;
    ht_lock();
    f->refs -= 1;
    if (f->refs == 0) should_free = 1;
    ht_unlock();
    if (should_free) {
        CloseHandle(f->h);
        free(f);
    }
    if (out_err != NULL) *out_err = err;
    return res;
}

int32_t sts_file_close(int64_t handle) {
    if (handle <= 0) return 0;
    win_file_ro_t *f = NULL;
    int should_free = 0;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t **pp = &g_ht_buckets[b];
    while (*pp != NULL) {
        sts_hnode_t *cur = *pp;
        if (cur->id == handle && cur->kind == STS_HK_FILE_RO) {
            *pp = cur->next;
            f = (win_file_ro_t *)cur->ptr;
            free(cur);
            f->closed = 1;
            f->refs -= 1;
            if (f->refs == 0) should_free = 1;
            break;
        }
        pp = &cur->next;
    }
    ht_unlock();
    if (f == NULL) return 0;
    if (should_free) {
        CloseHandle(f->h);
        free(f);
    }
    return 1;
}

int32_t sts_mkdir_exclusive(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    BOOL ok = CreateDirectoryW(w, NULL);
    free(w);
    return ok ? 1 : 0;
}

int32_t sts_getuid(void) { return -1; }
int32_t sts_geteuid(void) { return -1; }

static int sts_win_rel_safe(const char *rel) {
    if (rel == NULL || rel[0] == '\0' || rel[0] == '/' || rel[0] == '\\') return 0;
    const char *p = rel;
    while (*p != '\0') {
        while (*p == '/' || *p == '\\') p++;
        if (*p == '\0') break;
        const char *seg = p;
        while (*p != '\0' && *p != '/' && *p != '\\') {
            if (*p == ':') return 0;
            p++;
        }
        size_t n = (size_t)(p - seg);
        if ((n == 1 && seg[0] == '.') || (n == 2 && seg[0] == '.' && seg[1] == '.')) return 0;
    }
    return 1;
}

static HANDLE sts_win_open_dir_locked(const char *dir_utf8) {
    wchar_t *w = utf8_to_wide(dir_utf8);
    if (w == NULL) return INVALID_HANDLE_VALUE;
    // Omit FILE_SHARE_DELETE so no concurrent rename/unlink can swap this directory while we walk/open the leaf.
    HANDLE h = CreateFileW(
        w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(h, &info)
        || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0
        || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        CloseHandle(h);
        return INVALID_HANDLE_VALUE;
    }
    return h;
}

static void sts_win_close_handles(HANDLE *handles, size_t count) {
    for (size_t i = count; i > 0; i--) {
        if (handles[i - 1] != INVALID_HANDLE_VALUE) {
            CloseHandle(handles[i - 1]);
        }
    }
}

static int sts_win_verify_leaf_under_parent(HANDLE leaf_h, HANDLE parent_h) {
    wchar_t leaf_path[1024];
    wchar_t parent_path[1024];
    DWORD ll = GetFinalPathNameByHandleW(leaf_h, leaf_path, 1024, FILE_NAME_NORMALIZED);
    DWORD pl = GetFinalPathNameByHandleW(parent_h, parent_path, 1024, FILE_NAME_NORMALIZED);
    if (ll == 0 || ll >= 1024 || pl == 0 || pl >= 1024) return 0;
    while (pl > 0 && (parent_path[pl - 1] == L'\\' || parent_path[pl - 1] == L'/')) pl--;
    if (ll <= pl) return 0;
    if (_wcsnicmp(leaf_path, parent_path, pl) != 0) return 0;
    if (leaf_path[pl] != L'\\' && leaf_path[pl] != L'/') return 0;
    // Leaf must be a direct child of the locked immediate parent directory (no extra separators).
    for (DWORD i = pl + 1; i < ll; i++) {
        if (leaf_path[i] == L'\\' || leaf_path[i] == L'/') return 0;
    }
    return 1;
}

static char *sts_win_walk_lock_parents(
    const char *root,
    const char *rel,
    int create_parents,
    HANDLE *dir_handles,
    size_t max_handles,
    size_t *out_count) {
    *out_count = 0;
    if (root == NULL || root[0] == '\0' || !sts_win_rel_safe(rel) || max_handles == 0) return NULL;
    HANDLE rh = sts_win_open_dir_locked(root);
    if (rh == INVALID_HANDLE_VALUE) return NULL;
    dir_handles[(*out_count)++] = rh;
    size_t rlen = strlen(root), lrel = strlen(rel);
    char *cur = (char *)malloc(rlen + lrel + 4);
    if (cur == NULL) {
        sts_win_close_handles(dir_handles, *out_count);
        *out_count = 0;
        return NULL;
    }
    memcpy(cur, root, rlen);
    size_t cur_len = rlen;
    while (cur_len > 0 && (cur[cur_len - 1] == '\\' || cur[cur_len - 1] == '/')) cur_len--;
    cur[cur_len] = '\0';
    const char *p = rel;
    while (*p != '\0') {
        while (*p == '/' || *p == '\\') p++;
        if (*p == '\0') break;
        const char *seg = p;
        while (*p != '\0' && *p != '/' && *p != '\\') p++;
        size_t slen = (size_t)(p - seg);
        const char *rest = p;
        while (*rest == '/' || *rest == '\\') rest++;
        cur[cur_len++] = '\\';
        memcpy(cur + cur_len, seg, slen);
        cur_len += slen;
        cur[cur_len] = '\0';
        if (*rest == '\0') {
            return cur;
        }
        if (*out_count >= max_handles) {
            free(cur);
            sts_win_close_handles(dir_handles, *out_count);
            *out_count = 0;
            return NULL;
        }
        if (create_parents) {
            wchar_t *wd = utf8_to_wide(cur);
            if (wd != NULL) {
                (void)CreateDirectoryW(wd, NULL);
                free(wd);
            }
        }
        HANDLE dh = sts_win_open_dir_locked(cur);
        if (dh == INVALID_HANDLE_VALUE) {
            free(cur);
            sts_win_close_handles(dir_handles, *out_count);
            *out_count = 0;
            return NULL;
        }
        dir_handles[(*out_count)++] = dh;
        p = rest;
    }
    free(cur);
    sts_win_close_handles(dir_handles, *out_count);
    *out_count = 0;
    return NULL;
}

void *sts_read_under_nofollow(
    const char *root,
    const char *rel,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_size) {
    if (out_len != NULL) *out_len = 0;
    if (out_size != NULL) *out_size = 0;
    if (root == NULL || offset < 0 || len < 0) return NULL;
    HANDLE parents[128];
    size_t n_parents = 0;
    char *full = sts_win_walk_lock_parents(root, rel, 0, parents, 128, &n_parents);
    if (full == NULL) return NULL;
    wchar_t *w = utf8_to_wide(full);
    free(full);
    if (w == NULL) {
        sts_win_close_handles(parents, n_parents);
        return NULL;
    }
    HANDLE h = CreateFileW(
        w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        sts_win_close_handles(parents, n_parents);
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION info;
    int valid = GetFileInformationByHandle(h, &info)
        && (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) == 0
        && n_parents > 0
        && sts_win_verify_leaf_under_parent(h, parents[n_parents - 1]);
    sts_win_close_handles(parents, n_parents);
    if (!valid) {
        CloseHandle(h);
        return NULL;
    }
    int64_t fsize = ((int64_t)info.nFileSizeHigh << 32) | (int64_t)info.nFileSizeLow;
    if (out_size != NULL) *out_size = fsize;
    if (offset > fsize) {
        CloseHandle(h);
        return NULL;
    }
    int64_t want = (offset + len > fsize) ? (fsize - offset) : len;
    if (want <= 0) {
        CloseHandle(h);
        return dup_bytes("", 0, out_len);
    }
    LARGE_INTEGER li;
    li.QuadPart = offset;
    if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN)) {
        CloseHandle(h);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)want);
    if (buf == NULL) {
        CloseHandle(h);
        return NULL;
    }
    int64_t total = 0;
    while (total < want) {
        DWORD chunk = (DWORD)((want - total) > 0x7fffffffLL ? 0x7fffffffLL : (want - total));
        DWORD got = 0;
        if (!ReadFile(h, buf + total, chunk, &got, NULL) || got == 0) break;
        total += (int64_t)got;
    }
    CloseHandle(h);
    if (out_len != NULL) *out_len = total;
    return buf;
}

int32_t sts_write_under_nofollow(
    const char *root,
    const char *rel,
    const uint8_t *data,
    int64_t len,
    int64_t offset,
    int32_t mode,
    int32_t truncate_end) {
    (void)mode;
    if (root == NULL || len < 0 || offset < 0) return 0;
    HANDLE parents[128];
    size_t n_parents = 0;
    char *full = sts_win_walk_lock_parents(root, rel, 1, parents, 128, &n_parents);
    if (full == NULL) return 0;
    wchar_t *w = utf8_to_wide(full);
    free(full);
    if (w == NULL) {
        sts_win_close_handles(parents, n_parents);
        return 0;
    }
    HANDLE h = CreateFileW(
        w, GENERIC_WRITE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        sts_win_close_handles(parents, n_parents);
        return 0;
    }
    BY_HANDLE_FILE_INFORMATION info;
    int valid = GetFileInformationByHandle(h, &info)
        && (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) == 0
        && n_parents > 0
        && sts_win_verify_leaf_under_parent(h, parents[n_parents - 1]);
    sts_win_close_handles(parents, n_parents);
    if (!valid) {
        CloseHandle(h);
        return 0;
    }
    int64_t fsize = ((int64_t)info.nFileSizeHigh << 32) | (int64_t)info.nFileSizeLow;
    if (offset > fsize) {
        CloseHandle(h);
        return -2;
    }
    LARGE_INTEGER li;
    li.QuadPart = offset;
    if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN)) {
        CloseHandle(h);
        return 0;
    }
    int64_t done = 0;
    while (done < len) {
        DWORD chunk = (DWORD)((len - done) > 0x7fffffffLL ? 0x7fffffffLL : (len - done));
        DWORD wrote = 0;
        if (!WriteFile(h, data + done, chunk, &wrote, NULL)) {
            CloseHandle(h);
            return 0;
        }
        done += (int64_t)wrote;
    }
    if (truncate_end != 0) {
        if (!SetEndOfFile(h)) {
            CloseHandle(h);
            return 0;
        }
    }
    CloseHandle(h);
    return 1;
}

int32_t sts_write_file_mode(
    const char *path,
    const uint8_t *data,
    int64_t len,
    int32_t mode,
    int32_t append) {
    (void)mode;
    if (path == NULL || path[0] == '\0' || len < 0) return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    HANDLE h = CreateFileW(
        w,
        append ? FILE_APPEND_DATA : GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        append ? OPEN_ALWAYS : CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int64_t off = 0;
    BOOL ok = TRUE;
    while (off < len) {
        DWORD chunk = (DWORD)((len - off) > 0x7fffffffLL ? 0x7fffffffLL : (len - off));
        DWORD wrote = 0;
        if (!WriteFile(h, data + off, chunk, &wrote, NULL)) {
            ok = FALSE;
            break;
        }
        off += (int64_t)wrote;
    }
    CloseHandle(h);
    return ok ? 1 : 0;
}

void *sts_read_dir(const char *path, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (path == NULL || path[0] == '\0') return NULL;
    size_t plen = strlen(path);
    char *pat = (char *)malloc(plen + 4);
    if (pat == NULL) return NULL;
    memcpy(pat, path, plen);
    if (plen > 0 && pat[plen - 1] != '/' && pat[plen - 1] != '\\') {
        pat[plen++] = '\\';
    }
    pat[plen++] = '*';
    pat[plen] = '\0';
    wchar_t *w = utf8_to_wide(pat);
    free(pat);
    if (w == NULL) return NULL;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(w, &fd);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    sbuf_t b = { 0, 0, 0 };
    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
        char *u8 = wide_to_utf8(fd.cFileName);
        if (u8 != NULL) {
            sb_add(&b, u8, strlen(u8));
            sb_add(&b, "\0", 1);
            free(u8);
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return sb_finish(&b, out_len);
}

int32_t sts_mkdir_p(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    size_t len = strlen(path);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) return 0;
    memcpy(copy, path, len + 1);
    for (size_t i = 1; i <= len; i++) {
        if (copy[i] == '/' || copy[i] == '\\' || copy[i] == '\0') {
            char saved = copy[i];
            copy[i] = '\0';
            if (copy[0] != '\0' && !(i == 2 && copy[1] == ':')) {
                wchar_t *w = utf8_to_wide(copy);
                if (w != NULL) {
                    CreateDirectoryW(w, NULL);
                    free(w);
                }
            }
            copy[i] = saved;
        }
    }
    free(copy);
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    DWORD attr = GetFileAttributesW(w);
    free(w);
    return (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) ? 1 : 0;
}

int32_t sts_rename(const char *old_path, const char *new_path) {
    if (old_path == NULL || new_path == NULL) return 0;
    wchar_t *wo = utf8_to_wide(old_path);
    wchar_t *wn = utf8_to_wide(new_path);
    if (wo == NULL || wn == NULL) {
        free(wo);
        free(wn);
        return 0;
    }
    BOOL ok = MoveFileExW(wo, wn, MOVEFILE_REPLACE_EXISTING);
    free(wo);
    free(wn);
    return ok ? 1 : 0;
}

int32_t sts_random_bytes(uint8_t *buf, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (buf == NULL) return 0;
    NTSTATUS st = BCryptGenRandom(NULL, buf, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return st == 0 ? 1 : 0;
}

int32_t sts_mkdir_mode(const char *path, int32_t mode) {
    (void)mode;
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    BOOL ok = CreateDirectoryW(w, NULL);
    DWORD gle = ok ? 0 : GetLastError();
    free(w);
    if (ok) return 1;
    if (gle == ERROR_ALREADY_EXISTS) return -2;
    if (gle == ERROR_ACCESS_DENIED) return -3;
    if (gle == ERROR_PATH_NOT_FOUND) return -4;
    return 0;
}

int32_t sts_symlink(const char *target, const char *link_path, int32_t is_dir) {
    if (target == NULL || link_path == NULL || link_path[0] == '\0') return 0;
    wchar_t *wt = utf8_to_wide(target);
    wchar_t *wl = utf8_to_wide(link_path);
    if (wt == NULL || wl == NULL) {
        free(wt);
        free(wl);
        return 0;
    }
    DWORD base_flags = is_dir ? 0x1u : 0u; // SYMBOLIC_LINK_FLAG_DIRECTORY
    DWORD unpriv_flag = 0x2u;              // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
    BOOLEAN ok = CreateSymbolicLinkW(wl, wt, base_flags | unpriv_flag);
    if (!ok && GetLastError() == ERROR_INVALID_PARAMETER) {
        ok = CreateSymbolicLinkW(wl, wt, base_flags);
    }
    free(wt);
    free(wl);
    return ok ? 1 : 0;
}

int32_t sts_is_dir_symlink(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return 0;
    DWORD attr = GetFileAttributesW(w);
    free(w);
    if (attr == INVALID_FILE_ATTRIBUTES) return 0;
    return ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0 && (attr & FILE_ATTRIBUTE_DIRECTORY) != 0) ? 1 : 0;
}

void *sts_getcwd(int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    DWORD need = GetCurrentDirectoryW(0, NULL);
    if (need == 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)(need + 1) * sizeof(wchar_t));
    if (w == NULL) return NULL;
    DWORD got = GetCurrentDirectoryW(need + 1, w);
    if (got == 0 || got > need) {
        free(w);
        return NULL;
    }
    char *u8 = wide_to_utf8(w);
    free(w);
    if (u8 == NULL) return NULL;
    if (out_len != NULL) *out_len = (int64_t)strlen(u8);
    return u8;
}

void *sts_read_file_strict(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = 3;
    if (path == NULL || path[0] == '\0') return NULL;
    wchar_t *w = utf8_to_wide(path);
    if (w == NULL) return NULL;
    HANDLE h = CreateFileW(
        w,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    DWORD gle = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        if (out_err != NULL) {
            if (gle == ERROR_FILE_NOT_FOUND || gle == ERROR_PATH_NOT_FOUND) *out_err = 1;
            else if (gle == ERROR_ACCESS_DENIED) *out_err = 2;
            else *out_err = 3;
        }
        return NULL;
    }
    LARGE_INTEGER fsz;
    if (!GetFileSizeEx(h, &fsz) || fsz.QuadPart < 0 || fsz.QuadPart > (1LL << 30)) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = 3;
        return NULL;
    }
    size_t sz = (size_t)fsz.QuadPart;
    uint8_t *buf = (uint8_t *)malloc(sz + 1);
    if (buf == NULL) {
        CloseHandle(h);
        if (out_err != NULL) *out_err = 3;
        return NULL;
    }
    size_t off = 0;
    while (off < sz) {
        DWORD chunk = (DWORD)((sz - off) > 0x7fffffffULL ? 0x7fffffffULL : (sz - off));
        DWORD got = 0;
        if (!ReadFile(h, buf + off, chunk, &got, NULL)) {
            free(buf);
            CloseHandle(h);
            if (out_err != NULL) *out_err = 3;
            return NULL;
        }
        if (got == 0) break;
        off += (size_t)got;
    }
    CloseHandle(h);
    buf[off] = 0;
    if (out_len != NULL) *out_len = (int64_t)off;
    if (out_err != NULL) *out_err = 0;
    return buf;
}

int32_t sts_write_file_atomic(const char *path, const uint8_t *data, int64_t len, int32_t mode) {
    (void)mode;
    if (path == NULL || path[0] == '\0' || len < 0) return 0;
    const char *last_sep = NULL;
    for (const char *p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') last_sep = p;
    }
    size_t dir_len = 0;
    if (last_sep != NULL) {
        dir_len = (size_t)(last_sep - path) + 1;
    } else if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':') {
        // Drive-relative Windows path (e.g. "D:result.bin"): preserve "D:" prefix
        // so the temp file stays on the same volume and in the same target directory.
        dir_len = 2;
    }
    wchar_t *wdst = utf8_to_wide(path);
    if (wdst == NULL) return 0;

    static const char hx[] = "0123456789abcdef";
    HANDLE h = INVALID_HANDLE_VALUE;
    wchar_t *wtmp = NULL;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            free(wdst);
            return 0;
        }
        char hex[17];
        for (int i = 0; i < 8; i++) {
            hex[i * 2] = hx[(rnd[i] >> 4) & 0xF];
            hex[i * 2 + 1] = hx[rnd[i] & 0xF];
        }
        hex[16] = '\0';
        size_t tmp_cap = dir_len + 64;
        char *tmp = (char *)malloc(tmp_cap);
        if (tmp == NULL) {
            free(wdst);
            return 0;
        }
        snprintf(tmp, tmp_cap, "%.*s.sf-tmp.%lu.%s", (int)dir_len, path, (unsigned long)GetCurrentProcessId(), hex);
        wtmp = utf8_to_wide(tmp);
        free(tmp);
        if (wtmp == NULL) {
            free(wdst);
            return 0;
        }
        h = CreateFileW(wtmp, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) break;
        DWORD gle = GetLastError();
        free(wtmp);
        wtmp = NULL;
        if (gle != ERROR_FILE_EXISTS) {
            free(wdst);
            return 0;
        }
    }
    if (h == INVALID_HANDLE_VALUE || wtmp == NULL) {
        free(wtmp);
        free(wdst);
        return 0;
    }
    int64_t off = 0;
    BOOL ok = TRUE;
    while (off < len) {
        DWORD chunk = (DWORD)((len - off) > 0x7fffffffLL ? 0x7fffffffLL : (len - off));
        DWORD wrote = 0;
        if (!WriteFile(h, data + off, chunk, &wrote, NULL)) {
            ok = FALSE;
            break;
        }
        off += (int64_t)wrote;
    }
    if (ok) ok = FlushFileBuffers(h);
    CloseHandle(h);
    if (ok) ok = MoveFileExW(wtmp, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!ok) DeleteFileW(wtmp);
    free(wtmp);
    free(wdst);
    return ok ? 1 : 0;
}

int32_t sts_clones_at(const char *dir_path) {
    (void)dir_path;
    return 0;
}

int32_t sts_same_cloneable_volume(const char *dir_a, const char *dir_b) {
    (void)dir_a;
    (void)dir_b;
    return 0;
}

static int32_t sts_win_check_reparse_path(const wchar_t *wpath, int *out_is_dir) {
    if (out_is_dir != NULL) *out_is_dir = 0;
    DWORD attr = GetFileAttributesW(wpath);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        return sts_win_map_err(GetLastError());
    }
    if ((attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        if (out_is_dir != NULL) *out_is_dir = 1;
    }
    if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        HANDLE h = CreateFileW(
            wpath,
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            NULL);
        if (h == INVALID_HANDLE_VALUE) {
            return sts_win_map_err(GetLastError());
        }
        FILE_ATTRIBUTE_TAG_INFO ati;
        BOOL got = GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ati, sizeof(ati));
        DWORD gle = got ? 0 : GetLastError();
        CloseHandle(h);
        if (!got) return sts_win_map_err(gle);
        if (sts_win_is_name_surrogate_reparse(&ati)) return -5;
    }
    return 0;
}

int32_t sts_clone_file(const char *src, const char *dst, int32_t excl) {
    if (src == NULL || src[0] == '\0' || dst == NULL || dst[0] == '\0') return -1;
    wchar_t *wsrc = utf8_to_wide(src);
    wchar_t *wdst = utf8_to_wide(dst);
    if (wsrc == NULL || wdst == NULL) {
        free(wsrc);
        free(wdst);
        return -1;
    }
    int src_is_dir = 0;
    int32_t sc = sts_win_check_reparse_path(wsrc, &src_is_dir);
    if (sc != 0) {
        free(wsrc);
        free(wdst);
        return sc;
    }
    if (src_is_dir) {
        free(wsrc);
        free(wdst);
        return -4;
    }
    if (excl != 0) {
        BOOL ok = CopyFileW(wsrc, wdst, TRUE);
        DWORD gle = ok ? 0 : GetLastError();
        free(wsrc);
        free(wdst);
        if (ok) return 2;
        if (gle == ERROR_FILE_EXISTS || gle == ERROR_ALREADY_EXISTS) return -7;
        return sts_win_map_err(gle);
    }
    int dst_is_dir = 0;
    int32_t dc = sts_win_check_reparse_path(wdst, &dst_is_dir);
    if (dc == -5) {
        free(wsrc);
        free(wdst);
        return -5;
    }
    if (dc == 0 && dst_is_dir) {
        free(wsrc);
        free(wdst);
        return -4;
    }
    uint8_t rnd[8];
    if (!sts_random_bytes(rnd, 8)) {
        free(wsrc);
        free(wdst);
        return -1;
    }
    static const char hx[] = "0123456789abcdef";
    char hex[17];
    for (int i = 0; i < 8; i++) {
        hex[i * 2] = hx[(rnd[i] >> 4) & 0xF];
        hex[i * 2 + 1] = hx[rnd[i] & 0xF];
    }
    hex[16] = '\0';
    const char *slash1 = strrchr(dst, '/');
    const char *slash2 = strrchr(dst, '\\');
    const char *slash = (slash1 != NULL && (slash2 == NULL || slash1 > slash2)) ? slash1 : slash2;
    size_t dir_len = slash != NULL ? (size_t)(slash - dst) + 1 : 0;
    size_t tmp_cap = dir_len + 64;
    char *tmp_utf8 = (char *)malloc(tmp_cap);
    if (tmp_utf8 == NULL) {
        free(wsrc);
        free(wdst);
        return -1;
    }
    snprintf(tmp_utf8, tmp_cap, "%.*s.sf-clone.%lu.%s", (int)dir_len, dst, (unsigned long)GetCurrentProcessId(), hex);
    wchar_t *wtmp = utf8_to_wide(tmp_utf8);
    free(tmp_utf8);
    if (wtmp == NULL) {
        free(wsrc);
        free(wdst);
        return -1;
    }
    BOOL ok = CopyFileW(wsrc, wtmp, TRUE);
    DWORD gle = ok ? 0 : GetLastError();
    if (ok) {
        ok = MoveFileExW(wtmp, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        if (!ok) {
            gle = GetLastError();
            DeleteFileW(wtmp);
        }
    }
    free(wtmp);
    free(wsrc);
    free(wdst);
    if (ok) return 2;
    if (gle == ERROR_FILE_EXISTS || gle == ERROR_ALREADY_EXISTS) return -7;
    return sts_win_map_err(gle);
}

int32_t sts_clone_file_only(const char *src, const char *dst, int32_t excl) {
    (void)src;
    (void)dst;
    (void)excl;
    return -8;
}

int32_t sts_clone_tree(const char *src_dir, const char *dst_dir) {
    (void)src_dir;
    (void)dst_dir;
    return -8;
}

// ---------------------------------------------------------------------------
// 6. Windows peer_process (unsupported -> NULL)
// ---------------------------------------------------------------------------

void *sts_peer_process(int32_t fd, int64_t *out_len) {
    (void)fd;
    if (out_len != NULL) *out_len = 0;
    return NULL;
}

// ---------------------------------------------------------------------------
// 7. Windows process_usage
// ---------------------------------------------------------------------------

void *sts_process_usage(const int32_t *pids, int32_t count, int64_t *out_len) {
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "[");
    for (int32_t i = 0; i < count; i++) {
        if (i > 0) sb_str(&b, ",");
        int32_t pid = pids != NULL ? pids[i] : 0;
        if (pid <= 0) {
            sb_str(&b, "null");
            continue;
        }
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, FALSE, (DWORD)pid);
        if (h == NULL) {
            h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
        }
        if (h == NULL) {
            sb_str(&b, "null");
            continue;
        }
        FILETIME ct, et, kt, ut;
        uint64_t cpu_ns = 0;
        int has_times = GetProcessTimes(h, &ct, &et, &kt, &ut) ? 1 : 0;
        if (has_times) {
            cpu_ns = (ft64(kt) + ft64(ut)) * 100ULL;
        }
        PROCESS_MEMORY_COUNTERS pmc;
        memset(&pmc, 0, sizeof(pmc));
        uint64_t footprint = 0;
        int has_mem = K32GetProcessMemoryInfo(h, &pmc, sizeof(pmc)) ? 1 : 0;
        if (has_mem) {
            footprint = (uint64_t)pmc.WorkingSetSize;
        }
        IO_COUNTERS ioc;
        memset(&ioc, 0, sizeof(ioc));
        uint64_t disk_r = 0, disk_w = 0;
        if (GetProcessIoCounters(h, &ioc)) {
            disk_r = (uint64_t)ioc.ReadTransferCount;
            disk_w = (uint64_t)ioc.WriteTransferCount;
        }
        CloseHandle(h);
        if (!has_times && !has_mem) {
            sb_str(&b, "null");
            continue;
        }
        sb_str(&b, "{\"cpuNs\":");
        sb_fmt_u64(&b, (unsigned long long)cpu_ns);
        sb_str(&b, ",\"footprint\":");
        sb_fmt_u64(&b, (unsigned long long)footprint);
        sb_str(&b, ",\"wakeups\":0,\"energyNj\":0,\"diskRead\":");
        sb_fmt_u64(&b, (unsigned long long)disk_r);
        sb_str(&b, ",\"diskWritten\":");
        sb_fmt_u64(&b, (unsigned long long)disk_w);
        sb_str(&b, "}");
    }
    sb_str(&b, "]");
    return sb_finish(&b, out_len);
}

// ---------------------------------------------------------------------------
// 8. Windows ConPTY
// ---------------------------------------------------------------------------

typedef void *sts_hpcon_t;
typedef HRESULT(WINAPI *fn_create_pcon)(COORD, HANDLE, HANDLE, DWORD, sts_hpcon_t *);
typedef HRESULT(WINAPI *fn_resize_pcon)(sts_hpcon_t, COORD);
typedef void(WINAPI *fn_close_pcon)(sts_hpcon_t);
#define STS_PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE ((DWORD_PTR)0x00020016)

typedef struct {
    uint64_t event_id;
    sts_hpcon_t hpc;
    fn_resize_pcon p_resize;
    fn_close_pcon p_close;
    HANDLE h_in_w;
    HANDLE h_out_r;
    HANDLE h_proc;
    HANDLE h_job;
    HANDLE h_stop;
    _Atomic int closing;
    SRWLOCK resize_lock;
    SRWLOCK write_lock;
    CONDITION_VARIABLE write_cond;
    sts_chunk_t *write_head;
    sts_chunk_t *write_tail;
    size_t write_queued;
    int write_aborted;
    SRWLOCK ref_lock;
    int refs;
} win_pty_t;

static void win_pty_ref(win_pty_t *pt) {
    AcquireSRWLockExclusive(&pt->ref_lock);
    pt->refs += 1;
    ReleaseSRWLockExclusive(&pt->ref_lock);
}

static void win_pty_unref(win_pty_t *pt) {
    AcquireSRWLockExclusive(&pt->ref_lock);
    int last = (--pt->refs == 0);
    ReleaseSRWLockExclusive(&pt->ref_lock);
    if (!last) return;
    free_chunks(pt->write_head);
    if (pt->h_in_w != NULL) CloseHandle(pt->h_in_w);
    if (pt->h_out_r != NULL) CloseHandle(pt->h_out_r);
    if (pt->hpc != NULL) {
        pt->p_close(pt->hpc);
        pt->hpc = NULL;
    }
    if (pt->h_proc != NULL) CloseHandle(pt->h_proc);
    if (pt->h_job != NULL) CloseHandle(pt->h_job);
    if (pt->h_stop != NULL) CloseHandle(pt->h_stop);
    free(pt);
}

static DWORD WINAPI win_pty_write_thread(LPVOID arg) {
    win_pty_t *pt = (win_pty_t *)arg;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    for (;;) {
        AcquireSRWLockExclusive(&pt->write_lock);
        while (!pt->write_aborted && pt->write_head == NULL) {
            SleepConditionVariableSRW(&pt->write_cond, &pt->write_lock, INFINITE, 0);
        }
        if (pt->write_aborted || h_io == NULL) {
            sts_chunk_t *drop = pt->write_head;
            pt->write_head = pt->write_tail = NULL;
            pt->write_queued = 0;
            ReleaseSRWLockExclusive(&pt->write_lock);
            free_chunks(drop);
            break;
        }
        sts_chunk_t *ch = pt->write_head;
        pt->write_head = ch->next;
        if (pt->write_head == NULL) pt->write_tail = NULL;
        pt->write_queued -= ch->len;
        HANDLE h = pt->h_in_w;
        ReleaseSRWLockExclusive(&pt->write_lock);

        int ok = win_write_overlapped(h, pt->h_stop, h_io, ch->data, ch->len);
        free(ch);
        if (!ok) {
            AcquireSRWLockExclusive(&pt->write_lock);
            pt->write_aborted = 1;
            sts_chunk_t *drop = pt->write_head;
            pt->write_head = pt->write_tail = NULL;
            pt->write_queued = 0;
            ReleaseSRWLockExclusive(&pt->write_lock);
            free_chunks(drop);
            break;
        }
    }
    if (h_io != NULL) CloseHandle(h_io);
    win_pty_unref(pt);
    sts_detached_end();
    return 0;
}

static DWORD WINAPI win_pty_read_thread(LPVOID arg) {
    win_pty_t *pt = (win_pty_t *)arg;
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    int eof = 0;
    if (h_io != NULL && buf != NULL) {
        buf[0] = STS_EV_PTY_DATA;
        for (;;) {
            if (atomic_load_explicit(&pt->closing, memory_order_acquire)) {
                break;
            }
            ResetEvent(h_io);
            OVERLAPPED ov;
            memset(&ov, 0, sizeof(ov));
            ov.hEvent = h_io;
            DWORD n = 0;
            BOOL ok = ReadFile(pt->h_out_r, buf + 1, 65536, &n, &ov);
            if (!ok) {
                DWORD err = GetLastError();
                if (err == ERROR_IO_PENDING) {
                    HANDLE waits[2] = { h_io, pt->h_stop };
                    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                    if (wr == WAIT_OBJECT_0 + 1) {
                        CancelIoEx(pt->h_out_r, &ov);
                        DWORD dummy = 0;
                        GetOverlappedResult(pt->h_out_r, &ov, &dummy, TRUE);
                        break;
                    }
                    if (wr != WAIT_OBJECT_0 || !GetOverlappedResult(pt->h_out_r, &ov, &n, FALSE)) {
                        eof = 1;
                        break;
                    }
                } else {
                    eof = 1;
                    break;
                }
            }
            if (n == 0) {
                eof = 1;
                break;
            }
            if (atomic_load_explicit(&pt->closing, memory_order_acquire)) {
                break;
            }
            push_sys_bounded_tracked(pt->event_id, buf, (size_t)n + 1);
            if (atomic_load_explicit(&pt->closing, memory_order_acquire)) {
                break;
            }
        }
    }
    free(buf);
    if (h_io != NULL) CloseHandle(h_io);
    if (eof && !atomic_load_explicit(&pt->closing, memory_order_acquire)) {
        push_tag_ctrl(pt->event_id, STS_EV_PTY_EOF, NULL, 0);
    }
    win_pty_unref(pt);
    sts_detached_end();
    return 0;
}

static DWORD WINAPI win_pty_wait_thread(LPVOID arg) {
    win_pty_t *pt = (win_pty_t *)arg;
    HANDLE waits[2] = { pt->h_proc, pt->h_stop };
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
    if (wr == WAIT_OBJECT_0) {
        DWORD code = 1;
        GetExitCodeProcess(pt->h_proc, &code);
        AcquireSRWLockExclusive(&pt->write_lock);
        pt->write_aborted = 1;
        WakeConditionVariable(&pt->write_cond);
        if (!atomic_load_explicit(&pt->closing, memory_order_acquire)) {
            push_exit_event(pt->event_id, STS_EV_PTY_EXIT, (int32_t)code, 0, "");
        }
        ReleaseSRWLockExclusive(&pt->write_lock);
    }
    win_pty_unref(pt);
    sts_reaper_end();
    return 0;
}

int64_t sts_pty_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    int32_t cols,
    int32_t rows,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap) {
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    fn_create_pcon p_create = NULL;
    fn_resize_pcon p_resize = NULL;
    fn_close_pcon p_close = NULL;
    if (k32 != NULL) {
        void *f1 = (void *)GetProcAddress(k32, "CreatePseudoConsole");
        void *f2 = (void *)GetProcAddress(k32, "ResizePseudoConsole");
        void *f3 = (void *)GetProcAddress(k32, "ClosePseudoConsole");
        memcpy(&p_create, &f1, sizeof(p_create));
        memcpy(&p_resize, &f2, sizeof(p_resize));
        memcpy(&p_close, &f3, sizeof(p_close));
    }
    if (p_create == NULL || p_resize == NULL || p_close == NULL) {
        copy_err(err_buf, err_cap, "ConPTY unavailable");
        return -1;
    }
    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL;
    if (!win_create_overlapped_pipe(1, 0, &in_w, &in_r) ||
        !win_create_overlapped_pipe(0, 0, &out_r, &out_w)) {
        if (in_r) CloseHandle(in_r);
        if (in_w) CloseHandle(in_w);
        if (out_r) CloseHandle(out_r);
        if (out_w) CloseHandle(out_w);
        copy_err(err_buf, err_cap, "CreateNamedPipe failed");
        return -1;
    }
    COORD sz;
    sz.X = (SHORT)(cols > 0 ? cols : 80);
    sz.Y = (SHORT)(rows > 0 ? rows : 24);
    sts_hpcon_t hpc = NULL;
    HRESULT hr = p_create(sz, in_r, out_w, 0, &hpc);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (FAILED(hr)) {
        CloseHandle(in_w);
        CloseHandle(out_r);
        copy_err(err_buf, err_cap, "CreatePseudoConsole failed");
        return -1;
    }

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    LPPROC_THREAD_ATTRIBUTE_LIST attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (attr_list == NULL || !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) ||
        !UpdateProcThreadAttribute(attr_list, 0, STS_PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, sizeof(hpc), NULL, NULL)) {
        free(attr_list);
        CloseHandle(in_w);
        CloseHandle(out_r);
        p_close(hpc);
        copy_err(err_buf, err_cap, "ProcThreadAttribute failed");
        return -1;
    }

    sbuf_t cmd = { 0, 0, 0 };
    win_quote_arg(&cmd, program);
    if (args_nul != NULL && args_len > 0) {
        int64_t i = 0;
        while (i < args_len) {
            const char *a = (const char *)(args_nul + i);
            size_t n = strnlen(a, (size_t)(args_len - i));
            sb_str(&cmd, " ");
            win_quote_arg(&cmd, a);
            i += (int64_t)n + 1;
        }
    }
    wchar_t *wline = utf8_to_wide(cmd.data ? cmd.data : "");
    free(cmd.data);
    int env_ok = 1;
    wchar_t *wenv = win_build_env_block(
        env_nul,
        env_len,
        (flags & STS_PROC_STRIP_MALLOC_SE) != 0,
        (flags & STS_PROC_EXPLICIT_ENV) != 0,
        &env_ok);
    wchar_t *wcwd = (cwd != NULL && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;

    STARTUPINFOEXW siex;
    PROCESS_INFORMATION pi;
    memset(&siex, 0, sizeof(siex));
    memset(&pi, 0, sizeof(pi));
    siex.StartupInfo.cb = sizeof(siex);
    siex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    siex.StartupInfo.hStdInput = NULL;
    siex.StartupInfo.hStdOutput = NULL;
    siex.StartupInfo.hStdError = NULL;
    siex.lpAttributeList = attr_list;

    BOOL ok = (wline != NULL) && env_ok && (cwd == NULL || cwd[0] == '\0' || wcwd != NULL) && CreateProcessW(
        NULL,
        wline,
        NULL,
        NULL,
        FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
        wenv,
        wcwd,
        &siex.StartupInfo,
        &pi);
    DWORD err = ok ? 0 : GetLastError();
    DeleteProcThreadAttributeList(attr_list);
    free(attr_list);
    free(wline);
    free(wenv);
    free(wcwd);

    if (!ok) {
        CloseHandle(in_w);
        CloseHandle(out_r);
        p_close(hpc);
        char msg[256];
        win_err_str(err ? err : ERROR_NOT_ENOUGH_MEMORY, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    /* Fail-closed Job Object assignment BEFORE ResumeThread (without KILL_ON_JOB_CLOSE). */
    HANDLE h_job = CreateJobObjectW(NULL, NULL);
    if (h_job == NULL || !AssignProcessToJobObject(h_job, pi.hProcess)) {
        DWORD jerr = GetLastError();
        TerminateProcess(pi.hProcess, 1);
        if (h_job != NULL) CloseHandle(h_job);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        CloseHandle(in_w);
        CloseHandle(out_r);
        p_close(hpc);
        char msg[256];
        win_err_str(jerr ? jerr : ERROR_ACCESS_DENIED, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    if (ResumeThread(pi.hThread) == (DWORD)-1) {
        DWORD rerr = GetLastError();
        TerminateJobObject(h_job, 1);
        CloseHandle(h_job);
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        CloseHandle(in_w);
        CloseHandle(out_r);
        p_close(hpc);
        char msg[256];
        win_err_str(rerr ? rerr : ERROR_ACCESS_DENIED, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    CloseHandle(pi.hThread);

    win_pty_t *pt = (win_pty_t *)calloc(1, sizeof(*pt));
    if (pt == NULL) {
        TerminateJobObject(h_job, 1);
        CloseHandle(h_job);
        CloseHandle(in_w);
        CloseHandle(out_r);
        p_close(hpc);
        CloseHandle(pi.hProcess);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    pt->event_id = event_id;
    pt->hpc = hpc;
    pt->p_resize = p_resize;
    pt->p_close = p_close;
    pt->h_in_w = in_w;
    pt->h_out_r = out_r;
    pt->h_proc = pi.hProcess;
    pt->h_job = h_job;
    pt->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    InitializeSRWLock(&pt->resize_lock);
    InitializeSRWLock(&pt->write_lock);
    InitializeConditionVariable(&pt->write_cond);
    InitializeSRWLock(&pt->ref_lock);
    pt->refs = 1;

    int workers_ok = (pt->h_stop != NULL);
    if (workers_ok) {
        win_pty_ref(pt);
        if (!win_spawn_detached_thread(win_pty_write_thread, pt)) {
            win_pty_unref(pt);
            workers_ok = 0;
        }
    }
    if (workers_ok) {
        win_pty_ref(pt);
        if (!win_spawn_detached_thread(win_pty_read_thread, pt)) {
            win_pty_unref(pt);
            workers_ok = 0;
        }
    }
    int64_t id = workers_ok ? ht_insert(STS_HK_PTY, pt) : -1;
    if (id > 0) {
        win_pty_ref(pt);
        if (!win_spawn_reaper_thread(win_pty_wait_thread, pt)) {
            win_pty_unref(pt);
            (void)ht_take(STS_HK_PTY, id);
            id = -1;
        }
    }
    if (id < 0) {
        AcquireSRWLockExclusive(&pt->write_lock);
        atomic_store_explicit(&pt->closing, 1, memory_order_release);
        pt->write_aborted = 1;
        WakeConditionVariable(&pt->write_cond);
        ReleaseSRWLockExclusive(&pt->write_lock);
        if (pt->h_job != NULL) {
            TerminateJobObject(pt->h_job, 1);
        }
        TerminateProcess(pt->h_proc, 1);
        if (pt->h_stop != NULL) SetEvent(pt->h_stop);
        win_pty_unref(pt);
        copy_err(err_buf, err_cap, "worker spawn failed");
        return -1;
    }
    if (out_pid != NULL) {
        *out_pid = (int64_t)pi.dwProcessId;
    }
    return id;
}

static win_pty_t *win_pty_get(int64_t handle) {
    if (handle <= 0) return NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    win_pty_t *pt = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_PTY) {
            pt = (win_pty_t *)cur->ptr;
            AcquireSRWLockExclusive(&pt->ref_lock);
            pt->refs += 1;
            ReleaseSRWLockExclusive(&pt->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    return pt;
}

int32_t sts_pty_write(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (data == NULL) return 0;
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    AcquireSRWLockExclusive(&pt->write_lock);
    if (pt->write_aborted) {
        ReleaseSRWLockExclusive(&pt->write_lock);
        win_pty_unref(pt);
        return 0;
    }
    size_t ulen = (size_t)len;
    if (ulen > STS_STDIN_QUEUE_MAX || pt->write_queued > STS_STDIN_QUEUE_MAX - ulen) {
        ReleaseSRWLockExclusive(&pt->write_lock);
        win_pty_unref(pt);
        return 0;
    }
    sts_chunk_t *ch = (sts_chunk_t *)malloc(sizeof(*ch) + ulen);
    if (ch == NULL) {
        ReleaseSRWLockExclusive(&pt->write_lock);
        win_pty_unref(pt);
        return 0;
    }
    ch->next = NULL;
    ch->len = ulen;
    ch->off = 0;
    memcpy(ch->data, data, ulen);
    if (pt->write_tail != NULL) pt->write_tail->next = ch;
    else pt->write_head = ch;
    pt->write_tail = ch;
    pt->write_queued += ulen;
    WakeConditionVariable(&pt->write_cond);
    ReleaseSRWLockExclusive(&pt->write_lock);
    win_pty_unref(pt);
    return 1;
}

int32_t sts_pty_resize(int64_t handle, int32_t cols, int32_t rows) {
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    COORD sz;
    sz.X = (SHORT)(cols > 0 ? cols : 80);
    sz.Y = (SHORT)(rows > 0 ? rows : 24);
    AcquireSRWLockExclusive(&pt->resize_lock);
    HRESULT hr = (!atomic_load_explicit(&pt->closing, memory_order_acquire) && pt->hpc != NULL)
                     ? pt->p_resize(pt->hpc, sz)
                     : E_FAIL;
    ReleaseSRWLockExclusive(&pt->resize_lock);
    win_pty_unref(pt);
    return SUCCEEDED(hr) ? 1 : 0;
}

int32_t sts_pty_kill(int64_t handle, int32_t sig) {
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    if (sig == STS_SIG_PROBE) {
        DWORD wr = WaitForSingleObject(pt->h_proc, 0);
        win_pty_unref(pt);
        if (wr == WAIT_TIMEOUT) return 1;
        if (wr == WAIT_OBJECT_0) return 0;
        return -1;
    }
    BOOL ok = (pt->h_job != NULL) ? TerminateJobObject(pt->h_job, 1) : TerminateProcess(pt->h_proc, 1);
    win_pty_unref(pt);
    return ok ? 1 : 0;
}

int32_t sts_pty_close(int64_t handle) {
    win_pty_t *pt = (win_pty_t *)ht_take(STS_HK_PTY, handle);
    if (pt == NULL) return 0;
    AcquireSRWLockExclusive(&pt->write_lock);
    atomic_store_explicit(&pt->closing, 1, memory_order_release);
    pt->write_aborted = 1;
    WakeConditionVariable(&pt->write_cond);
    ReleaseSRWLockExclusive(&pt->write_lock);
    SetEvent(pt->h_stop);
    win_pty_unref(pt);
    return 1;
}

// ---------------------------------------------------------------------------
// 9. Windows UDP dgram
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    SOCKET sock;
    int family;
    WSAEVENT ev_io;
    WSAEVENT ev_stop;
    _Atomic int closing;
    SRWLOCK ref_lock;
    int refs;
} win_udp_t;

static void win_udp_ref(win_udp_t *u) {
    AcquireSRWLockExclusive(&u->ref_lock);
    u->refs += 1;
    ReleaseSRWLockExclusive(&u->ref_lock);
}

static void win_udp_unref(win_udp_t *u) {
    AcquireSRWLockExclusive(&u->ref_lock);
    int last = (--u->refs == 0);
    ReleaseSRWLockExclusive(&u->ref_lock);
    if (!last) return;
    if (u->sock != INVALID_SOCKET) closesocket(u->sock);
    if (u->ev_io != WSA_INVALID_EVENT) WSACloseEvent(u->ev_io);
    if (u->ev_stop != WSA_INVALID_EVENT) WSACloseEvent(u->ev_stop);
    free(u);
}

static DWORD WINAPI win_udp_recv_thread(LPVOID arg) {
    win_udp_t *u = (win_udp_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (buf != NULL) {
        WSAEVENT waits[2] = { u->ev_io, u->ev_stop };
        for (;;) {
            if (atomic_load_explicit(&u->closing, memory_order_acquire)) {
                break;
            }
            DWORD wr = WSAWaitForMultipleEvents(2, waits, FALSE, INFINITE, FALSE);
            if (wr == WSA_WAIT_EVENT_0 + 1 || wr == WSA_WAIT_FAILED) {
                break;
            }
            WSAResetEvent(u->ev_io);
            for (;;) {
                if (atomic_load_explicit(&u->closing, memory_order_acquire)) {
                    break;
                }
                struct sockaddr_storage ss;
                int slen = (int)sizeof(ss);
                int n = recvfrom(u->sock, (char *)buf, 65536, 0, (struct sockaddr *)&ss, &slen);
                if (n < 0) {
                    break;
                }
                char addr_str[INET6_ADDRSTRLEN] = "";
                uint16_t src_port = 0;
                if (ss.ss_family == AF_INET) {
                    struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
                    inet_ntop(AF_INET, &s4->sin_addr, addr_str, sizeof(addr_str));
                    src_port = ntohs(s4->sin_port);
                } else if (ss.ss_family == AF_INET6) {
                    struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
                    inet_ntop(AF_INET6, &s6->sin6_addr, addr_str, sizeof(addr_str));
                    src_port = ntohs(s6->sin6_port);
                }
                size_t alen = strlen(addr_str);
                size_t total = 5 + alen + (size_t)n;
                uint8_t *msg = (uint8_t *)malloc(total);
                if (msg != NULL) {
                    msg[0] = STS_EV_UDP_RECV;
                    put_u16_le(msg + 1, src_port);
                    put_u16_le(msg + 3, (uint16_t)alen);
                    memcpy(msg + 5, addr_str, alen);
                    if (n > 0) memcpy(msg + 5 + alen, buf, (size_t)n);
                    push_sys_bounded_tracked(u->event_id, msg, total);
                    free(msg);
                }
            }
        }
        free(buf);
    }
    push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
    win_udp_unref(u);
    sts_detached_end();
    return 0;
}

int64_t sts_udp_bind(uint64_t event_id, const char *addr, int32_t port, int64_t *out_port) {
    if (addr == NULL || addr[0] == '\0' || port < 0 || port > 65535) return -1;
    ensure_wsa();
    int is_v6 = strchr(addr, ':') != NULL;
    int family = is_v6 ? AF_INET6 : AF_INET;
    SOCKET s = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return -1;

    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    int slen = 0;
    if (is_v6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            closesocket(s);
            return -1;
        }
        slen = (int)sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            closesocket(s);
            return -1;
        }
        slen = (int)sizeof(*s4);
    }
    if (bind(s, (struct sockaddr *)&ss, slen) != 0) {
        closesocket(s);
        return -1;
    }
    int bound_len = (int)sizeof(ss);
    if (getsockname(s, (struct sockaddr *)&ss, &bound_len) == 0 && out_port != NULL) {
        if (ss.ss_family == AF_INET) {
            *out_port = (int64_t)ntohs(((struct sockaddr_in *)&ss)->sin_port);
        } else if (ss.ss_family == AF_INET6) {
            *out_port = (int64_t)ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
        }
    }
    win_udp_t *u = (win_udp_t *)calloc(1, sizeof(*u));
    if (u == NULL) {
        closesocket(s);
        return -1;
    }
    u->event_id = event_id;
    u->sock = s;
    u->family = family;
    u->ev_io = WSACreateEvent();
    u->ev_stop = WSACreateEvent();
    InitializeSRWLock(&u->ref_lock);
    u->refs = 1;
    if (u->ev_io == WSA_INVALID_EVENT || u->ev_stop == WSA_INVALID_EVENT ||
        WSAEventSelect(s, u->ev_io, FD_READ) != 0) {
        win_udp_unref(u);
        return -1;
    }
    win_udp_ref(u);
    if (!win_spawn_detached_thread(win_udp_recv_thread, u)) {
        win_udp_unref(u);
        win_udp_unref(u);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_UDP, u);
    if (id < 0) {
        atomic_store_explicit(&u->closing, 1, memory_order_release);
        WSASetEvent(u->ev_stop);
        win_udp_unref(u);
    }
    return id;
}

int32_t sts_udp_send_to(int64_t handle, const char *addr, int32_t port, const uint8_t *data, int64_t len) {
    if (addr == NULL || port <= 0 || port > 65535 || len < 0) return -1;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    win_udp_t *u = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_UDP) {
            u = (win_udp_t *)cur->ptr;
            AcquireSRWLockExclusive(&u->ref_lock);
            u->refs += 1;
            ReleaseSRWLockExclusive(&u->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    if (u == NULL) return -1;

    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    int slen = 0;
    if (u->family == AF_INET6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            win_udp_unref(u);
            return -1;
        }
        slen = (int)sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            win_udp_unref(u);
            return -1;
        }
        slen = (int)sizeof(*s4);
    }
    int rc = sendto(u->sock, (const char *)(data ? data : (const uint8_t *)""), (int)len, 0, (struct sockaddr *)&ss, slen);
    int werr = rc < 0 ? WSAGetLastError() : 0;
    win_udp_unref(u);
    if (rc >= 0) return 0;
    if (werr == WSAEHOSTUNREACH) return STS_ERR_HOSTUNREACH;
    if (werr == WSAENETUNREACH) return STS_ERR_NETUNREACH;
    return -(werr > 0 ? werr : 1);
}

int32_t sts_udp_close(int64_t handle) {
    win_udp_t *u = (win_udp_t *)ht_take(STS_HK_UDP, handle);
    if (u == NULL) return 0;
    atomic_store_explicit(&u->closing, 1, memory_order_release);
    WSASetEvent(u->ev_stop);
    win_udp_unref(u);
    return 1;
}

int32_t sts_udp_send_once(const char *addr, int32_t port, const uint8_t *data, int64_t len) {
    if (addr == NULL || addr[0] == '\0' || port <= 0 || port > 65535 || len < 0) return -1;
    ensure_wsa();
    int is_v6 = strchr(addr, ':') != NULL;
    int family = is_v6 ? AF_INET6 : AF_INET;
    SOCKET s = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return -1;
    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    int slen = 0;
    if (is_v6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            closesocket(s);
            return -1;
        }
        slen = (int)sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            closesocket(s);
            return -1;
        }
        slen = (int)sizeof(*s4);
    }
    int rc = sendto(s, (const char *)(data ? data : (const uint8_t *)""), (int)len, 0, (struct sockaddr *)&ss, slen);
    int werr = rc < 0 ? WSAGetLastError() : 0;
    closesocket(s);
    if (rc >= 0) return 0;
    if (werr == WSAEHOSTUNREACH) return STS_ERR_HOSTUNREACH;
    if (werr == WSAENETUNREACH) return STS_ERR_NETUNREACH;
    return -(werr > 0 ? werr : 1);
}

// ---------------------------------------------------------------------------
// 10. Windows Machine / OS info
// ---------------------------------------------------------------------------

void *sts_hostname(int64_t *out_len) {
    wchar_t w[256];
    DWORD n = 256;
    if (!GetComputerNameExW(ComputerNameDnsHostname, w, &n)) {
        return dup_bytes("", 0, out_len);
    }
    char *s = wide_to_utf8(w);
    void *out = dup_bytes(s ? s : "", s ? strlen(s) : 0, out_len);
    free(s);
    return out;
}

void *sts_homedir(int64_t *out_len) {
    wchar_t w[32768];
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", w, 32768);
    if (n == 0 || n >= 32768) {
        return dup_bytes("C:\\", 3, out_len);
    }
    char *s = wide_to_utf8(w);
    void *out = dup_bytes(s ? s : "C:\\", s ? strlen(s) : 3, out_len);
    free(s);
    return out;
}

void *sts_tmpdir(int64_t *out_len) {
    wchar_t w[MAX_PATH + 2];
    DWORD n = GetTempPathW(MAX_PATH + 1, w);
    if (n == 0) {
        return dup_bytes("C:\\Windows\\Temp", 15, out_len);
    }
    if (n > 3 && (w[n - 1] == L'\\' || w[n - 1] == L'/')) {
        w[n - 1] = 0;
    }
    char *s = wide_to_utf8(w);
    void *out = dup_bytes(s ? s : "", s ? strlen(s) : 0, out_len);
    free(s);
    return out;
}

void *sts_env_all(int64_t *out_len) {
    wchar_t *block = GetEnvironmentStringsW();
    sbuf_t b = { 0, 0, 0 };
    for (wchar_t *p = block; p != NULL && *p != 0; p += wcslen(p) + 1) {
        if (*p == L'=') continue;
        char *s = wide_to_utf8(p);
        if (s != NULL) {
            sb_add(&b, s, strlen(s) + 1);
            free(s);
        }
    }
    if (block != NULL) FreeEnvironmentStringsW(block);
    return sb_finish(&b, out_len);
}

void *sts_env_get(const char *name, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (name == NULL || name[0] == '\0') {
        return NULL;
    }
    wchar_t *wn = utf8_to_wide(name);
    if (wn == NULL) {
        return NULL;
    }
    DWORD cap = 256;
    wchar_t *wv = NULL;
    for (int tries = 0; tries < 4; tries++) {
        free(wv);
        wv = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)cap);
        if (wv == NULL) {
            free(wn);
            return NULL;
        }
        SetLastError(0);
        DWORD got = GetEnvironmentVariableW(wn, wv, cap);
        if (got == 0) {
            DWORD err = GetLastError();
            free(wv);
            free(wn);
            if (err == ERROR_ENVVAR_NOT_FOUND) {
                return NULL;
            }
            return dup_bytes("", 0, out_len);
        }
        if (got < cap) {
            free(wn);
            char *s = wide_to_utf8_len(wv, (int)got);
            free(wv);
            if (s == NULL) {
                return NULL;
            }
            if (out_len != NULL) *out_len = (int64_t)strlen(s);
            return s;
        }
        cap = got + 1;
    }
    free(wv);
    free(wn);
    return NULL;
}

int32_t sts_env_set(const char *name, const char *value) {
    if (name == NULL || name[0] == '\0' || value == NULL) return 0;
    wchar_t *wn = utf8_to_wide(name);
    wchar_t *wv = utf8_to_wide(value);
    int ok = (wn != NULL && wv != NULL && SetEnvironmentVariableW(wn, wv)) ? 1 : 0;
    free(wn);
    free(wv);
    return ok;
}

int32_t sts_env_unset(const char *name) {
    if (name == NULL || name[0] == '\0') return 0;
    wchar_t *wn = utf8_to_wide(name);
    int ok = (wn != NULL && SetEnvironmentVariableW(wn, NULL)) ? 1 : 0;
    free(wn);
    return ok;
}

int32_t sts_is_executable(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    wchar_t *w = utf8_to_wide(path);
    DWORD attrs = w != NULL ? GetFileAttributesW(w) : INVALID_FILE_ATTRIBUTES;
    free(w);
    return (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)) ? 1 : 0;
}

void *sts_disk_of(const char *path, int64_t *out_len) {
    if (path == NULL || path[0] == '\0') {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    wchar_t *w = utf8_to_wide(path);
    ULARGE_INTEGER avail, total, free_b;
    int ok = (w != NULL && GetDiskFreeSpaceExW(w, &avail, &total, &free_b)) ? 1 : 0;
    free(w);
    if (!ok) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{\"free\":");
    sb_fmt_u64(&b, (unsigned long long)avail.QuadPart);
    sb_str(&b, ",\"total\":");
    sb_fmt_u64(&b, (unsigned long long)total.QuadPart);
    sb_str(&b, "}");
    return sb_finish(&b, out_len);
}

void *sts_machine_stats(int64_t *out_len) {
    sbuf_t b = { 0, 0, 0 };
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    unsigned n = si.dwNumberOfProcessors ? si.dwNumberOfProcessors : 1;
    FILETIME idle, kernel, user;
    uint64_t idle_ms = 0, sys_ms = 0, user_ms = 0;
    if (GetSystemTimes(&idle, &kernel, &user)) {
        idle_ms = ft64(idle) / 10000ULL;
        sys_ms = (ft64(kernel) - ft64(idle)) / 10000ULL;
        user_ms = ft64(user) / 10000ULL;
    }
    sb_str(&b, "{\"cpus\":[");
    for (unsigned i = 0; i < n; i++) {
        if (i > 0) sb_str(&b, ",");
        sb_str(&b, "{\"model\":\"\",\"speed\":0,\"times\":{\"user\":");
        sb_fmt_u64(&b, (unsigned long long)(user_ms / n));
        sb_str(&b, ",\"nice\":0,\"sys\":");
        sb_fmt_u64(&b, (unsigned long long)(sys_ms / n));
        sb_str(&b, ",\"idle\":");
        sb_fmt_u64(&b, (unsigned long long)(idle_ms / n));
        sb_str(&b, ",\"irq\":0}}");
    }
    MEMORYSTATUSEX mem;
    memset(&mem, 0, sizeof(mem));
    mem.dwLength = sizeof(mem);
    GlobalMemoryStatusEx(&mem);
    sb_str(&b, "],\"totalmem\":");
    sb_fmt_u64(&b, (unsigned long long)mem.ullTotalPhys);
    sb_str(&b, ",\"freemem\":");
    sb_fmt_u64(&b, (unsigned long long)mem.ullAvailPhys);
    sb_str(&b, ",\"loadavg\":[0,0,0],\"uptime\":");
    sb_fmt_u64(&b, (unsigned long long)(GetTickCount64() / 1000ULL));
    sb_str(&b, "}");
    return sb_finish(&b, out_len);
}

void *sts_psi_pressure(int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    return NULL;
}

void *sts_network_interfaces(int64_t *out_len) {
    ensure_wsa();
    ULONG size = 16 * 1024;
    IP_ADAPTER_ADDRESSES *list = NULL;
    ULONG rc = ERROR_BUFFER_OVERFLOW;
    for (int tries = 0; tries < 3 && rc == ERROR_BUFFER_OVERFLOW; tries++) {
        free(list);
        list = (IP_ADAPTER_ADDRESSES *)malloc(size);
        if (list == NULL) {
            return dup_bytes("[]", 2, out_len);
        }
        rc = GetAdaptersAddresses(
            AF_UNSPEC,
            GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            NULL,
            list,
            &size);
    }
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "[");
    int first = 1;
    if (rc == NO_ERROR) {
        for (IP_ADAPTER_ADDRESSES *a = list; a != NULL; a = a->Next) {
            if (a->OperStatus != IfOperStatusUp) continue;
            int is_loop = (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) ? 1 : 0;
            char *name = wide_to_utf8(a->FriendlyName);
            for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u != NULL; u = u->Next) {
                if (u->Address.lpSockaddr == NULL) continue;
                int family = u->Address.lpSockaddr->sa_family;
                char addr_text[INET6_ADDRSTRLEN] = "";
                char mask_text[INET6_ADDRSTRLEN] = "";
                if (family == AF_INET) {
                    inet_ntop(AF_INET, &((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr, addr_text, sizeof(addr_text));
                    uint32_t prefix = u->OnLinkPrefixLength;
                    uint32_t mask = (prefix == 0) ? 0u : (prefix >= 32 ? 0xffffffffu : (~0u << (32u - prefix)));
                    struct in_addr ma;
                    ma.s_addr = htonl(mask);
                    inet_ntop(AF_INET, &ma, mask_text, sizeof(mask_text));
                } else if (family == AF_INET6) {
                    inet_ntop(AF_INET6, &((struct sockaddr_in6 *)u->Address.lpSockaddr)->sin6_addr, addr_text, sizeof(addr_text));
                    uint8_t m6[16];
                    memset(m6, 0, sizeof(m6));
                    unsigned prefix = u->OnLinkPrefixLength > 128 ? 128 : u->OnLinkPrefixLength;
                    for (unsigned bit = 0; bit < prefix; bit++) {
                        m6[bit / 8] |= (uint8_t)(0x80u >> (bit % 8));
                    }
                    inet_ntop(AF_INET6, m6, mask_text, sizeof(mask_text));
                } else {
                    continue;
                }
                if (!first) sb_str(&b, ",");
                first = 0;
                sb_str(&b, "{\"name\":");
                sb_json_str(&b, name != NULL ? name : "");
                sb_str(&b, family == AF_INET ? ",\"family\":\"IPv4\",\"address\":" : ",\"family\":\"IPv6\",\"address\":");
                sb_json_str(&b, addr_text);
                sb_str(&b, ",\"netmask\":");
                sb_json_str(&b, mask_text);
                sb_str(&b, is_loop ? ",\"internal\":true}" : ",\"internal\":false}");
            }
            free(name);
        }
    }
    free(list);
    sb_str(&b, "]");
    return sb_finish(&b, out_len);
}

#else
// ===========================================================================
//                            POSIX IMPLEMENTATION
// ===========================================================================

static pthread_once_t g_sigpipe_once = PTHREAD_ONCE_INIT;
static void ignore_sigpipe_once(void) {
    signal(SIGPIPE, SIG_IGN);
}
static void ensure_sigpipe_ignored(void) {
    pthread_once(&g_sigpipe_once, ignore_sigpipe_once);
}

static int child_dup2_stdio(int src, int dst) {
    if (src < 0) return -1;
    if (src == dst) {
        return fcntl(dst, F_SETFD, 0) < 0 ? -1 : 0;
    }
    return dup2(src, dst) < 0 ? -1 : 0;
}

static int relocate_fd_above_2(int *fd) {
    if (fd == NULL || *fd < 0 || *fd > 2) return 0;
    int nfd = fcntl(*fd, F_DUPFD_CLOEXEC, 3);
    if (nfd < 0) return -1;
    close(*fd);
    *fd = nfd;
    return 0;
}

static int posix_max_open_fd_hint(void) {
#ifdef __APPLE__
    int sz = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (sz > 0) {
        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)sz);
        if (fds != NULL) {
            int got = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, sz);
            int max_fd = 256;
            if (got > 0) {
                int count = got / (int)sizeof(struct proc_fdinfo);
                for (int i = 0; i < count; i++) {
                    if (fds[i].proc_fd > max_fd) {
                        max_fd = fds[i].proc_fd;
                    }
                }
            }
            free(fds);
            return max_fd + 128;
        }
    }
#endif
    long max_fd = sysconf(_SC_OPEN_MAX);
    if (max_fd < 256 || max_fd > 65536) {
        max_fd = 65536;
    }
    return (int)max_fd;
}

static void set_cloexec_from(int min_fd, int max_fd_hint) {
#if defined(__linux__) && defined(SYS_close_range)
    (void)max_fd_hint;
    // CLOSE_RANGE_CLOEXEC = (1U << 2) since Linux 5.11; leaves rep_p[1] open until execve.
    if (syscall(SYS_close_range, (unsigned int)min_fd, ~0U, (unsigned int)(1U << 2)) == 0) {
        return;
    }
#endif
    int limit = max_fd_hint > min_fd ? max_fd_hint : 65536;
    for (int fd = min_fd; fd <= limit; fd++) {
        (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
}

static int make_wakeup_pipe(int fds[2]) {
#if defined(__linux__)
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    return 0;
#else
    if (pipe(fds) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        int fl = fcntl(fds[i], F_GETFL, 0);
        if (fl >= 0) {
            fcntl(fds[i], F_SETFL, fl | O_NONBLOCK);
        }
    }
    return 0;
#endif
}

static void wake_pipe_signal(int write_fd) {
    if (write_fd < 0) return;
    uint8_t b = 1;
    ssize_t r;
    do {
        r = write(write_fd, &b, 1);
    } while (r < 0 && errno == EINTR);
}

static void wake_pipe_drain(int read_fd) {
    if (read_fd < 0) return;
    uint8_t buf[64];
    while (read(read_fd, buf, sizeof(buf)) > 0) {
    }
}

static void close_fd_pair(int fds[2]) {
    if (fds[0] >= 0) {
        close(fds[0]);
        fds[0] = -1;
    }
    if (fds[1] >= 0) {
        close(fds[1]);
        fds[1] = -1;
    }
}

static int cloexec_pipe(int fds[2]) {
#if defined(__linux__)
    if (pipe2(fds, O_CLOEXEC) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    return 0;
#else
    if (pipe(fds) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
}

static void posix_err_str(int err, char *buf, size_t cap) {
#if defined(__linux__) && defined(_GNU_SOURCE) && !defined(__ANDROID__)
    // GNU strerror_r returns char* (may or may not use buf).
    char tmp[128];
    const char *s = strerror_r(err, tmp, sizeof(tmp));
    snprintf(buf, cap, "%s", s != NULL ? s : "error");
#else
    if (strerror_r(err, buf, cap) != 0) {
        snprintf(buf, cap, "errno %d", err);
    }
#endif
}

static int posix_signal_of(int32_t sig) {
    switch (sig) {
        case STS_SIG_PROBE: return 0;
        case STS_SIG_HUP:   return SIGHUP;
        case STS_SIG_INT:   return SIGINT;
        case STS_SIG_KILL:  return SIGKILL;
        case STS_SIG_TERM:  return SIGTERM;
        case STS_SIG_USR1:  return SIGUSR1;
        case STS_SIG_USR2:  return SIGUSR2;
        case STS_SIG_STOP:  return SIGSTOP;
        case STS_SIG_CONT:  return SIGCONT;
        default:            return (int)sig;
    }
}

static const char *posix_signal_name(int sig) {
    switch (sig) {
        case SIGHUP:  return "SIGHUP";
        case SIGINT:  return "SIGINT";
        case SIGQUIT: return "SIGQUIT";
        case SIGILL:  return "SIGILL";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGKILL: return "SIGKILL";
        case SIGSEGV: return "SIGSEGV";
        case SIGPIPE: return "SIGPIPE";
        case SIGALRM: return "SIGALRM";
        case SIGTERM: return "SIGTERM";
        case SIGUSR1: return "SIGUSR1";
        case SIGUSR2: return "SIGUSR2";
        case SIGSTOP: return "SIGSTOP";
        case SIGCONT: return "SIGCONT";
        default:      return "SIGUNKNOWN";
    }
}

// ---------------------------------------------------------------------------
// 1. POSIX Non-Recursive Directory fs.watch
// ---------------------------------------------------------------------------

#ifdef __APPLE__
static void emit_fs_event(uint64_t event_id, uint8_t kind, const char *name) {
    size_t nlen = name != NULL ? strlen(name) : 0;
    uint8_t stack_buf[256];
    uint8_t *msg = (2 + nlen <= sizeof(stack_buf)) ? stack_buf : (uint8_t *)malloc(2 + nlen);
    if (msg == NULL) return;
    msg[0] = STS_EV_FS_CHANGE;
    msg[1] = kind;
    if (nlen > 0) memcpy(msg + 2, name, nlen);
    sth_push_sys(event_id, msg, 2 + nlen);
    if (msg != stack_buf) free(msg);
}

typedef struct {
    uint64_t event_id;
    char *watch_dir;
    size_t watch_dir_len;
    char *file_basename; // non-NULL when watching a single file
    int is_file;
    _Atomic int closing;
    FSEventStreamRef stream;
    dispatch_queue_t queue;
} posix_fsw_t;

static void mac_fsw_noop(void *ctx) {
    (void)ctx;
}

static void mac_fsw_callback(
    ConstFSEventStreamRef stream_ref,
    void *client_info,
    size_t num_events,
    void *event_paths,
    const FSEventStreamEventFlags event_flags[],
    const FSEventStreamEventId event_ids[]) {
    (void)stream_ref;
    (void)event_ids;
    posix_fsw_t *w = (posix_fsw_t *)client_info;
    if (w == NULL || atomic_load_explicit(&w->closing, memory_order_acquire)) {
        return;
    }
    const char **paths = (const char **)event_paths;
    for (size_t i = 0; i < num_events; i++) {
        FSEventStreamEventFlags fl = event_flags[i];
        const char *p = paths[i];
        if (fl & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)) {
            emit_fs_event(w->event_id, STS_FS_OVERFLOW, "");
            continue;
        }
        if (fl & kFSEventStreamEventFlagMustScanSubDirs) {
            int covers_watch = (p == NULL);
            if (!covers_watch) {
                size_t plen = strlen(p);
                while (plen > 1 && p[plen - 1] == '/') plen -= 1;
                if ((plen == w->watch_dir_len && strncmp(p, w->watch_dir, plen) == 0) ||
                    (plen < w->watch_dir_len && strncmp(p, w->watch_dir, plen) == 0 &&
                     (plen == 1 || w->watch_dir[plen] == '/'))) {
                    covers_watch = 1;
                }
            }
            if (covers_watch) {
                emit_fs_event(w->event_id, STS_FS_OVERFLOW, "");
            }
            continue;
        }
        if (p == NULL) continue;
        const char *rel = NULL;
        if (w->watch_dir_len == 1 && w->watch_dir[0] == '/') {
            if (p[0] == '/') rel = p + 1;
        } else if (strncmp(p, w->watch_dir, w->watch_dir_len) == 0) {
            if (p[w->watch_dir_len] == '/') {
                rel = p + w->watch_dir_len + 1;
            } else if (p[w->watch_dir_len] == '\0') {
                // Event on the watched directory itself; ignore when watching a single file.
                if (!w->is_file) {
                    uint8_t kind = (fl & (kFSEventStreamEventFlagItemCreated |
                                          kFSEventStreamEventFlagItemRemoved |
                                          kFSEventStreamEventFlagItemRenamed))
                                       ? STS_FS_RENAME
                                       : STS_FS_CHANGE;
                    emit_fs_event(w->event_id, kind, "");
                }
                continue;
            }
        }
        if (rel == NULL || rel[0] == '\0') continue;
        // Strip trailing slash on directory notifications.
        size_t rlen = strlen(rel);
        while (rlen > 0 && rel[rlen - 1] == '/') {
            rlen -= 1;
        }
        if (rlen == 0) continue;
        // Non-recursive: skip events in subdirectories.
        if (memchr(rel, '/', rlen) != NULL) continue;
        char name_stack[256];
        char *name_buf = (rlen + 1 <= sizeof(name_stack)) ? name_stack : (char *)malloc(rlen + 1);
        if (name_buf == NULL) continue;
        memcpy(name_buf, rel, rlen);
        name_buf[rlen] = '\0';
        if (!w->is_file || (w->file_basename != NULL && strcmp(name_buf, w->file_basename) == 0)) {
            uint8_t kind = (fl & (kFSEventStreamEventFlagItemCreated |
                                  kFSEventStreamEventFlagItemRemoved |
                                  kFSEventStreamEventFlagItemRenamed))
                               ? STS_FS_RENAME
                               : STS_FS_CHANGE;
            emit_fs_event(w->event_id, kind, name_buf);
        }
        if (name_buf != name_stack) free(name_buf);
    }
}

int64_t sts_fs_watch_open(uint64_t event_id, const char *path) {
    if (path == NULL || path[0] == '\0') return -1;
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    int is_file = !S_ISDIR(st.st_mode);
    char resolved[PATH_MAX];
    if (realpath(path, resolved) == NULL) return -1;

    char *watch_dir = NULL;
    char *file_basename = NULL;
    if (is_file) {
        const char *base = path_basename(resolved);
        file_basename = sts_strdup(base);
        size_t dir_len = (size_t)(base - resolved);
        if (dir_len == 0) {
            watch_dir = sts_strdup(".");
        } else {
            while (dir_len > 1 && resolved[dir_len - 1] == '/') {
                dir_len -= 1;
            }
            watch_dir = (char *)malloc(dir_len + 1);
            if (watch_dir != NULL) {
                memcpy(watch_dir, resolved, dir_len);
                watch_dir[dir_len] = '\0';
            }
        }
    } else {
        size_t len = strlen(resolved);
        while (len > 1 && resolved[len - 1] == '/') {
            len -= 1;
        }
        watch_dir = (char *)malloc(len + 1);
        if (watch_dir != NULL) {
            memcpy(watch_dir, resolved, len);
            watch_dir[len] = '\0';
        }
    }
    if (watch_dir == NULL || (is_file && file_basename == NULL)) {
        free(watch_dir);
        free(file_basename);
        return -1;
    }

    posix_fsw_t *w = (posix_fsw_t *)calloc(1, sizeof(*w));
    if (w == NULL) {
        free(watch_dir);
        free(file_basename);
        return -1;
    }
    w->event_id = event_id;
    w->watch_dir = watch_dir;
    w->watch_dir_len = strlen(watch_dir);
    w->file_basename = file_basename;
    w->is_file = is_file;
    atomic_store_explicit(&w->closing, 0, memory_order_relaxed);

    CFStringRef cf_path = CFStringCreateWithCString(NULL, w->watch_dir, kCFStringEncodingUTF8);
    if (cf_path == NULL) {
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
        return -1;
    }
    CFArrayRef paths = CFArrayCreate(NULL, (const void **)&cf_path, 1, &kCFTypeArrayCallBacks);
    CFRelease(cf_path);
    if (paths == NULL) {
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
        return -1;
    }

    FSEventStreamContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.info = w;
    w->stream = FSEventStreamCreate(
        NULL,
        mac_fsw_callback,
        &ctx,
        paths,
        kFSEventStreamEventIdSinceNow,
        0.02,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
    CFRelease(paths);
    if (w->stream == NULL) {
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
        return -1;
    }
    w->queue = dispatch_queue_create("fail.still.station_sys.fswatch", DISPATCH_QUEUE_SERIAL);
    if (w->queue == NULL) {
        FSEventStreamRelease(w->stream);
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
        return -1;
    }
    FSEventStreamSetDispatchQueue(w->stream, w->queue);
    if (!FSEventStreamStart(w->stream)) {
        FSEventStreamInvalidate(w->stream);
        FSEventStreamRelease(w->stream);
        dispatch_sync_f(w->queue, NULL, mac_fsw_noop);
        dispatch_release(w->queue);
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
        return -1;
    }

    int64_t id = ht_insert(STS_HK_FS_WATCH, w);
    if (id < 0) {
        atomic_store_explicit(&w->closing, 1, memory_order_release);
        FSEventStreamStop(w->stream);
        FSEventStreamInvalidate(w->stream);
        FSEventStreamRelease(w->stream);
        dispatch_sync_f(w->queue, NULL, mac_fsw_noop);
        dispatch_release(w->queue);
        free(w->watch_dir);
        free(w->file_basename);
        free(w);
    }
    return id;
}

int32_t sts_fs_watch_close(int64_t handle) {
    posix_fsw_t *w = (posix_fsw_t *)ht_take(STS_HK_FS_WATCH, handle);
    if (w == NULL) return 0;
    atomic_store_explicit(&w->closing, 1, memory_order_release);
    FSEventStreamStop(w->stream);
    FSEventStreamInvalidate(w->stream);
    FSEventStreamRelease(w->stream);
    dispatch_sync_f(w->queue, NULL, mac_fsw_noop);
    dispatch_release(w->queue);
    push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
    free(w->watch_dir);
    free(w->file_basename);
    free(w);
    return 1;
}

#else // Linux inotify

typedef struct {
    uint64_t event_id;
    char *file_basename; // non-NULL when watching a single file
    int ifd;
    int wd;
    int wake[2];
    _Atomic int closing;
    pthread_t thread;
} posix_fsw_t;

static void *posix_fsw_thread(void *arg) {
    posix_fsw_t *w = (posix_fsw_t *)arg;
    uint8_t buf[16384] __attribute__((aligned(__alignof__(struct inotify_event))));
    struct pollfd pfds[2];
    pfds[0].fd = w->ifd;
    pfds[0].events = POLLIN;
    pfds[1].fd = w->wake[0];
    pfds[1].events = POLLIN;

    for (;;) {
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        int rc = poll(pfds, 2, -1);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || pfds[1].revents != 0) break;
        if (pfds[0].revents & POLLIN) {
            for (;;) {
                ssize_t len = read(w->ifd, buf, sizeof(buf));
                if (len < 0 && errno == EINTR) continue;
                if (len <= 0) break;
                ssize_t off = 0;
                while (off + (ssize_t)sizeof(struct inotify_event) <= len) {
                    const struct inotify_event *ev = (const struct inotify_event *)(buf + off);
                    size_t step = sizeof(struct inotify_event) + (size_t)ev->len;
                    if (off + (ssize_t)step > len) break;
                    if (ev->mask & IN_Q_OVERFLOW) {
                        uint8_t ovf[2] = { STS_EV_FS_CHANGE, STS_FS_OVERFLOW };
                        sth_push_sys(w->event_id, ovf, sizeof(ovf));
                    } else if (ev->mask & IN_IGNORED) {
                        if (!atomic_load_explicit(&w->closing, memory_order_acquire)) {
                            uint8_t err_msg[2] = { STS_EV_FS_CHANGE, STS_FS_ERROR };
                            sth_push_sys(w->event_id, err_msg, sizeof(err_msg));
                        }
                    } else {
                        const char *name = (ev->len > 0) ? ev->name : (w->file_basename != NULL ? w->file_basename : "");
                        size_t nlen = (ev->len > 0) ? strnlen(name, ev->len) : strlen(name);
                        uint8_t kind = (ev->mask & (IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF))
                                           ? STS_FS_RENAME
                                           : STS_FS_CHANGE;
                        uint8_t stack_msg[256];
                        uint8_t *msg = (2 + nlen <= sizeof(stack_msg)) ? stack_msg : (uint8_t *)malloc(2 + nlen);
                        if (msg != NULL) {
                            msg[0] = STS_EV_FS_CHANGE;
                            msg[1] = kind;
                            if (nlen > 0) memcpy(msg + 2, name, nlen);
                            sth_push_sys(w->event_id, msg, 2 + nlen);
                            if (msg != stack_msg) free(msg);
                        }
                    }
                    off += (ssize_t)step;
                }
            }
        }
    }
    push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
    return NULL;
}

int64_t sts_fs_watch_open(uint64_t event_id, const char *path) {
    if (path == NULL || path[0] == '\0') return -1;
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    int is_file = !S_ISDIR(st.st_mode);
    int ifd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (ifd < 0) return -1;
    uint32_t mask = IN_CREATE | IN_DELETE | IN_MODIFY | IN_ATTRIB |
                    IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE |
                    IN_DELETE_SELF | IN_MOVE_SELF;
    int wd = inotify_add_watch(ifd, path, mask);
    if (wd < 0) {
        close(ifd);
        return -1;
    }
    posix_fsw_t *w = (posix_fsw_t *)calloc(1, sizeof(*w));
    if (w == NULL) {
        close(ifd);
        return -1;
    }
    w->event_id = event_id;
    w->file_basename = is_file ? sts_strdup(path_basename(path)) : NULL;
    w->ifd = ifd;
    w->wd = wd;
    w->wake[0] = w->wake[1] = -1;
    atomic_store_explicit(&w->closing, 0, memory_order_relaxed);
    if ((is_file && w->file_basename == NULL) ||
        make_wakeup_pipe(w->wake) != 0 ||
        pthread_create(&w->thread, NULL, posix_fsw_thread, w) != 0) {
        close_fd_pair(w->wake);
        close(ifd);
        free(w->file_basename);
        free(w);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_FS_WATCH, w);
    if (id < 0) {
        atomic_store_explicit(&w->closing, 1, memory_order_release);
        wake_pipe_signal(w->wake[1]);
        pthread_join(w->thread, NULL);
        close_fd_pair(w->wake);
        close(ifd);
        free(w->file_basename);
        free(w);
    }
    return id;
}

int32_t sts_fs_watch_close(int64_t handle) {
    posix_fsw_t *w = (posix_fsw_t *)ht_take(STS_HK_FS_WATCH, handle);
    if (w == NULL) return 0;
    atomic_store_explicit(&w->closing, 1, memory_order_release);
    wake_pipe_signal(w->wake[1]);
    pthread_join(w->thread, NULL);
    close_fd_pair(w->wake);
    close(w->ifd);
    free(w->file_basename);
    free(w);
    return 1;
}
#endif

// ---------------------------------------------------------------------------
// 2. POSIX Async Child Process
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    pid_t pid;
    _Atomic int closing;
    pthread_mutex_t kill_lock;
    int exited;
    int kill_revoked;

    int stdin_fd;
    int stdin_wake[2];
    pthread_mutex_t stdin_lock;
    sts_chunk_t *stdin_head;
    sts_chunk_t *stdin_tail;
    size_t stdin_queued;
    int stdin_eof;
    int stdin_aborted;

    int stdout_fd;
    int stderr_fd;
    int pipes_wake[2];

    pthread_mutex_t ref_lock;
    int refs;
} posix_proc_t;

static void posix_proc_ref(posix_proc_t *p) {
    pthread_mutex_lock(&p->ref_lock);
    p->refs += 1;
    pthread_mutex_unlock(&p->ref_lock);
}

static void posix_proc_unref(posix_proc_t *p) {
    pthread_mutex_lock(&p->ref_lock);
    int last = (--p->refs == 0);
    pthread_mutex_unlock(&p->ref_lock);
    if (!last) return;
    free_chunks(p->stdin_head);
    if (p->stdin_fd >= 0) close(p->stdin_fd);
    if (p->stdout_fd >= 0) close(p->stdout_fd);
    if (p->stderr_fd >= 0) close(p->stderr_fd);
    close_fd_pair(p->stdin_wake);
    close_fd_pair(p->pipes_wake);
    pthread_mutex_destroy(&p->kill_lock);
    pthread_mutex_destroy(&p->stdin_lock);
    pthread_mutex_destroy(&p->ref_lock);
    free(p);
}

static posix_proc_t *posix_proc_get(int64_t handle) {
    if (handle <= 0) return NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    posix_proc_t *p = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_PROC) {
            p = (posix_proc_t *)cur->ptr;
            pthread_mutex_lock(&p->ref_lock);
            p->refs += 1;
            pthread_mutex_unlock(&p->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    return p;
}

static void *posix_pipes_thread(void *arg) {
    posix_proc_t *p = (posix_proc_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    if (buf != NULL) {
        int fds[2] = { p->stdout_fd, p->stderr_fd };
        int open_cnt = (fds[0] >= 0) + (fds[1] >= 0);

        while (open_cnt > 0 && !atomic_load_explicit(&p->closing, memory_order_acquire)) {
            struct pollfd pfds[3];
            int which[3];
            int nfds = 0;
            pfds[nfds].fd = p->pipes_wake[0];
            pfds[nfds].events = POLLIN;
            pfds[nfds].revents = 0;
            which[nfds++] = -1;
            for (int i = 0; i < 2; i++) {
                if (fds[i] >= 0) {
                    pfds[nfds].fd = fds[i];
                    pfds[nfds].events = POLLIN;
                    pfds[nfds].revents = 0;
                    which[nfds++] = i;
                }
            }
            int rc = poll(pfds, (nfds_t)nfds, -1);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0 || pfds[0].revents != 0) break;
            for (int k = 1; k < nfds; k++) {
                if (atomic_load_explicit(&p->closing, memory_order_acquire)) break;
                if (pfds[k].revents == 0) continue;
                int idx = which[k];
                ssize_t got = read(fds[idx], buf + 1, 65536);
                if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                if (got <= 0) {
                    close(fds[idx]);
                    fds[idx] = -1;
                    if (idx == 0) p->stdout_fd = -1;
                    else p->stderr_fd = -1;
                    open_cnt -= 1;
                    if (!atomic_load_explicit(&p->closing, memory_order_acquire)) {
                        push_tag_ctrl(p->event_id, idx == 0 ? STS_EV_PROC_STDOUT_EOF : STS_EV_PROC_STDERR_EOF, NULL, 0);
                    }
                } else {
                    buf[0] = (uint8_t)(idx == 0 ? STS_EV_PROC_STDOUT : STS_EV_PROC_STDERR);
                    push_sys_bounded_tracked(p->event_id, buf, (size_t)got + 1);
                    if (atomic_load_explicit(&p->closing, memory_order_acquire)) break;
                }
            }
        }
        free(buf);
        for (int i = 0; i < 2; i++) {
            if (fds[i] >= 0) {
                close(fds[i]);
                fds[i] = -1;
            }
        }
        p->stdout_fd = -1;
        p->stderr_fd = -1;
    } else {
        if (p->stdout_fd >= 0) { close(p->stdout_fd); p->stdout_fd = -1; }
        if (p->stderr_fd >= 0) { close(p->stderr_fd); p->stderr_fd = -1; }
    }
    posix_proc_unref(p);
    sts_detached_end();
    return NULL;
}

static void *posix_stdin_thread(void *arg) {
    posix_proc_t *p = (posix_proc_t *)arg;
    sigset_t ps;
    sigemptyset(&ps);
    sigaddset(&ps, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &ps, NULL);

    for (;;) {
        pthread_mutex_lock(&p->stdin_lock);
        if (p->stdin_aborted) {
            sts_chunk_t *drop = p->stdin_head;
            p->stdin_head = p->stdin_tail = NULL;
            p->stdin_queued = 0;
            pthread_mutex_unlock(&p->stdin_lock);
            free_chunks(drop);
            break;
        }
        sts_chunk_t *ch = p->stdin_head;
        if (ch != NULL) {
            p->stdin_head = ch->next;
            if (p->stdin_head == NULL) p->stdin_tail = NULL;
            p->stdin_queued -= ch->len;
            int fd = p->stdin_fd;
            pthread_mutex_unlock(&p->stdin_lock);

            int ok = 1;
            while (ch->off < ch->len) {
                ssize_t n = write(fd, ch->data + ch->off, ch->len - ch->off);
                if (n > 0) {
                    ch->off += (size_t)n;
                    continue;
                }
                if (n < 0 && errno == EINTR) continue;
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    struct pollfd pfds[2];
                    pfds[0].fd = p->stdin_wake[0];
                    pfds[0].events = POLLIN;
                    pfds[0].revents = 0;
                    pfds[1].fd = fd;
                    pfds[1].events = POLLOUT;
                    pfds[1].revents = 0;
                    int prc = poll(pfds, 2, -1);
                    if (prc < 0 && errno == EINTR) continue;
                    if (prc < 0) {
                        ok = 0;
                        break;
                    }
                    if (pfds[0].revents != 0) {
                        wake_pipe_drain(p->stdin_wake[0]);
                        pthread_mutex_lock(&p->stdin_lock);
                        int ab = p->stdin_aborted;
                        pthread_mutex_unlock(&p->stdin_lock);
                        if (ab) {
                            ok = 0;
                            break;
                        }
                    }
                    if (pfds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                        ok = 0;
                        break;
                    }
                    continue;
                }
                ok = 0;
                break;
            }
            free(ch);
            if (!ok) {
                pthread_mutex_lock(&p->stdin_lock);
                p->stdin_aborted = 1;
                sts_chunk_t *drop = p->stdin_head;
                p->stdin_head = p->stdin_tail = NULL;
                p->stdin_queued = 0;
                pthread_mutex_unlock(&p->stdin_lock);
                free_chunks(drop);
                break;
            }
            continue;
        }
        if (p->stdin_eof) {
            pthread_mutex_unlock(&p->stdin_lock);
            break;
        }
        pthread_mutex_unlock(&p->stdin_lock);

        struct pollfd pfd;
        pfd.fd = p->stdin_wake[0];
        pfd.events = POLLIN;
        pfd.revents = 0;
        int prc = poll(&pfd, 1, -1);
        if (prc > 0) {
            wake_pipe_drain(p->stdin_wake[0]);
        }
    }

    pthread_mutex_lock(&p->stdin_lock);
    if (p->stdin_fd >= 0) {
        close(p->stdin_fd);
        p->stdin_fd = -1;
    }
    pthread_mutex_unlock(&p->stdin_lock);
    posix_proc_unref(p);
    sts_detached_end();
    return NULL;
}

static int posix_wait_exited_nowait(pid_t pid) {
    for (;;) {
        siginfo_t si;
        memset(&si, 0, sizeof(si));
        int wid = waitid(P_PID, (id_t)pid, &si, WEXITED | WNOWAIT);
        if (wid < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (si.si_pid == pid &&
            (si.si_code == CLD_EXITED || si.si_code == CLD_KILLED || si.si_code == CLD_DUMPED)) {
            return 0;
        }
        // macOS XNU wakes waitid(WEXITED | WNOWAIT) on CLD_STOPPED / CLD_CONTINUED
        // despite WEXITED alone; consume only stop/continue without reaping an exit.
        siginfo_t drain;
        memset(&drain, 0, sizeof(drain));
        int dr = waitid(P_PID, (id_t)pid, &drain, WSTOPPED | WCONTINUED | WNOHANG);
        if (dr < 0 || drain.si_pid == 0) {
            return -1;
        }
    }
}

static void *posix_wait_thread(void *arg) {
    posix_proc_t *p = (posix_proc_t *)arg;
    int wid = posix_wait_exited_nowait(p->pid);

    int status = 0;
    pid_t wr = -1;
    if (wid == 0) {
        pthread_mutex_lock(&p->kill_lock);
        p->exited = 1;
        do {
            wr = waitpid(p->pid, &status, WNOHANG);
        } while (wr < 0 && errno == EINTR);
        pthread_mutex_unlock(&p->kill_lock);
        if (wr == 0) {
            do {
                wr = waitpid(p->pid, &status, 0);
            } while (wr < 0 && errno == EINTR);
        }
    } else {
        // waitid failed (non-EINTR): revoke handle-based kill permission BEFORE reaping
        // so there is zero PID-reuse window, then block in waitpid without holding kill_lock.
        pthread_mutex_lock(&p->kill_lock);
        p->kill_revoked = 1;
        pthread_mutex_unlock(&p->kill_lock);
        do {
            wr = waitpid(p->pid, &status, 0);
        } while (wr < 0 && errno == EINTR);
        pthread_mutex_lock(&p->kill_lock);
        p->exited = 1;
        pthread_mutex_unlock(&p->kill_lock);
    }

    pthread_mutex_lock(&p->stdin_lock);
    p->stdin_aborted = 1;
    pthread_mutex_unlock(&p->stdin_lock);
    wake_pipe_signal(p->stdin_wake[1]);

    pthread_mutex_lock(&p->kill_lock);
    if (wr == p->pid && !atomic_load_explicit(&p->closing, memory_order_acquire)) {
        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            push_exit_event(p->event_id, STS_EV_PROC_EXIT, -1, (int32_t)sig, posix_signal_name(sig));
        } else {
            push_exit_event(p->event_id, STS_EV_PROC_EXIT, (int32_t)WEXITSTATUS(status), 0, "");
        }
    }
    pthread_mutex_unlock(&p->kill_lock);
    posix_proc_unref(p);
    sts_reaper_end();
    return NULL;
}

static void free_str_vec(char **v) {
    if (v == NULL) return;
    for (size_t i = 0; v[i] != NULL; i++) {
        free(v[i]);
    }
    free(v);
}

static char **build_argv(const char *program, const uint8_t *args_nul, int64_t args_len) {
    size_t count = 1;
    if (args_nul != NULL && args_len > 0) {
        int64_t i = 0;
        while (i < args_len) {
            size_t n = strnlen((const char *)(args_nul + i), (size_t)(args_len - i));
            count += 1;
            i += (int64_t)n + 1;
        }
    }
    char **argv = (char **)calloc(count + 1, sizeof(char *));
    if (argv == NULL) return NULL;
    size_t k = 0;
    argv[k] = sts_strdup(program);
    if (argv[k] == NULL) {
        free_str_vec(argv);
        return NULL;
    }
    k += 1;
    if (args_nul != NULL && args_len > 0) {
        int64_t i = 0;
        while (i < args_len) {
            const char *a = (const char *)(args_nul + i);
            size_t n = strnlen(a, (size_t)(args_len - i));
            char *copy = (char *)malloc(n + 1);
            if (copy == NULL) {
                free_str_vec(argv);
                return NULL;
            }
            memcpy(copy, a, n);
            copy[n] = '\0';
            argv[k++] = copy;
            i += (int64_t)n + 1;
        }
    }
    argv[k] = NULL;
    return argv;
}

static char **build_envp(const uint8_t *env_nul, int64_t env_len, int strip_mse, int explicit_env, int *out_ok) {
    *out_ok = 1;
    if (!explicit_env && (env_nul == NULL || env_len <= 0) && !strip_mse) {
        return NULL;
    }
    size_t cap = 32;
    size_t len = 0;
    char **envp = (char **)calloc(cap, sizeof(char *));
    if (envp == NULL) {
        *out_ok = 0;
        return NULL;
    }

    if (explicit_env && (env_nul == NULL || env_len <= 0)) {
        envp[0] = NULL;
        return envp;
    }

    if (env_nul != NULL && env_len > 0) {
        int64_t i = 0;
        while (i < env_len) {
            const char *e = (const char *)(env_nul + i);
            size_t n = strnlen(e, (size_t)(env_len - i));
            if (n > 0) {
                char *copy = (char *)malloc(n + 1);
                if (copy == NULL) {
                    free_str_vec(envp);
                    *out_ok = 0;
                    return NULL;
                }
                memcpy(copy, e, n);
                copy[n] = '\0';
                if (strip_mse && is_malloc_se_entry(copy)) {
                    free(copy);
                } else {
                    if (len + 2 > cap) {
                        cap *= 2;
                        char **grown = (char **)realloc(envp, cap * sizeof(char *));
                        if (grown == NULL) {
                            free(copy);
                            free_str_vec(envp);
                            *out_ok = 0;
                            return NULL;
                        }
                        envp = grown;
                    }
                    envp[len++] = copy;
                    envp[len] = NULL;
                }
            }
            i += (int64_t)n + 1;
        }
    } else if (!explicit_env && environ != NULL) {
        for (char **e = environ; *e != NULL; e++) {
            if (strip_mse && is_malloc_se_entry(*e)) continue;
            if (len + 2 > cap) {
                cap *= 2;
                char **grown = (char **)realloc(envp, cap * sizeof(char *));
                if (grown == NULL) {
                    free_str_vec(envp);
                    *out_ok = 0;
                    return NULL;
                }
                envp = grown;
            }
            char *dup = sts_strdup(*e);
            if (dup == NULL) {
                free_str_vec(envp);
                *out_ok = 0;
                return NULL;
            }
            envp[len++] = dup;
            envp[len] = NULL;
        }
    }
    envp[len] = NULL;
    return envp;
}

static char *resolve_program_for_cwd(const char *program, char **envp, const char *cwd, int *out_err) {
    if (out_err != NULL) *out_err = 0;
    if (strchr(program, '/') != NULL) {
        char *dup = sts_strdup(program);
        if (dup == NULL && out_err != NULL) *out_err = ENOMEM;
        return dup;
    }
    const char *path = NULL;
    if (envp != NULL) {
        for (char **e = envp; *e != NULL; e++) {
            if (strncmp(*e, "PATH=", 5) == 0) {
                path = *e + 5;
                break;
            }
        }
        if (path == NULL) {
            if (out_err != NULL) *out_err = ENOENT;
            return NULL;
        }
    } else {
        path = getenv("PATH");
        if (path == NULL) path = "/usr/bin:/bin";
    }
    size_t pl = strlen(program);
    char *dyn_base = NULL;
    const char *base_dir = NULL;
    int base_resolved = 0;
    int base_err = 0;
    if (cwd != NULL && cwd[0] == '/') {
        base_dir = cwd;
        base_resolved = 1;
    }

    int saved_err = 0;
    const char *p = path;
    for (;;) {
        const char *end = strchr(p, ':');
        size_t dl = end != NULL ? (size_t)(end - p) : strlen(p);
        char *full = NULL;
        if (dl > 0 && p[0] == '/') {
            full = (char *)malloc(dl + 1 + pl + 1);
            if (full != NULL) {
                memcpy(full, p, dl);
                full[dl] = '/';
                memcpy(full + dl + 1, program, pl + 1);
            }
        } else {
            // Lazily resolve process cwd only when a relative PATH entry is encountered;
            // if getcwd fails (e.g. deleted cwd), skip relative entries and keep searching absolute ones.
            if (!base_resolved) {
                base_resolved = 1;
                size_t cap = PATH_MAX;
                char *gbuf = NULL;
                for (;;) {
                    char *next = (char *)realloc(gbuf, cap);
                    if (next == NULL) {
                        free(gbuf);
                        base_err = ENOMEM;
                        gbuf = NULL;
                        break;
                    }
                    gbuf = next;
                    if (getcwd(gbuf, cap) != NULL) {
                        break;
                    }
                    if (errno != ERANGE || cap >= (1u << 20)) {
                        base_err = errno;
                        free(gbuf);
                        gbuf = NULL;
                        break;
                    }
                    cap *= 2;
                }
                if (gbuf != NULL) {
                    if (cwd != NULL && cwd[0] != '\0') {
                        size_t gl = strlen(gbuf);
                        size_t cl = strlen(cwd);
                        dyn_base = (char *)malloc(gl + 1 + cl + 1);
                        if (dyn_base == NULL) {
                            free(gbuf);
                            base_err = ENOMEM;
                        } else {
                            memcpy(dyn_base, gbuf, gl);
                            dyn_base[gl] = '/';
                            memcpy(dyn_base + gl + 1, cwd, cl + 1);
                            free(gbuf);
                            base_dir = dyn_base;
                        }
                    } else {
                        dyn_base = gbuf;
                        base_dir = dyn_base;
                    }
                }
            }
            if (base_dir == NULL) {
                if (saved_err == 0 && base_err != 0) saved_err = base_err;
                if (end == NULL) break;
                p = end + 1;
                continue;
            }
            size_t bl = strlen(base_dir);
            if (dl == 0) {
                full = (char *)malloc(bl + 1 + pl + 1);
                if (full != NULL) {
                    memcpy(full, base_dir, bl);
                    full[bl] = '/';
                    memcpy(full + bl + 1, program, pl + 1);
                }
            } else {
                full = (char *)malloc(bl + 1 + dl + 1 + pl + 1);
                if (full != NULL) {
                    memcpy(full, base_dir, bl);
                    full[bl] = '/';
                    memcpy(full + bl + 1, p, dl);
                    full[bl + 1 + dl] = '/';
                    memcpy(full + bl + 1 + dl + 1, program, pl + 1);
                }
            }
        }
        if (full == NULL) {
            free(dyn_base);
            if (out_err != NULL) *out_err = ENOMEM;
            return NULL;
        }
        struct stat st;
        if (stat(full, &st) == 0) {
            if (S_ISREG(st.st_mode)) {
                if (access(full, X_OK) == 0) {
                    free(dyn_base);
                    return full;
                }
                saved_err = EACCES;
            } else {
                saved_err = EACCES;
            }
        }
        free(full);
        if (end == NULL) break;
        p = end + 1;
    }
    free(dyn_base);
    if (out_err != NULL) *out_err = saved_err ? saved_err : ENOENT;
    return NULL;
}

static void reset_child_signals(void) {
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGUSR1, SIG_DFL);
    signal(SIGUSR2, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
}

int64_t sts_proc_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap) {
    if (program == NULL || program[0] == '\0') {
        copy_err(err_buf, err_cap, "empty program");
        return -1;
    }
    ensure_sigpipe_ignored();
    const char *dir = (cwd != NULL && cwd[0] != '\0') ? cwd : NULL;
    char **argv = build_argv(program, args_nul, args_len);
    int env_ok = 1;
    char **envp = build_envp(
        env_nul,
        env_len,
        (flags & STS_PROC_STRIP_MALLOC_SE) != 0,
        (flags & STS_PROC_EXPLICIT_ENV) != 0,
        &env_ok);
    if (argv == NULL || !env_ok) {
        free_str_vec(argv);
        free_str_vec(envp);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    int resolve_err = 0;
    char *exec_path = resolve_program_for_cwd(program, envp, dir, &resolve_err);
    if (exec_path == NULL) {
        free_str_vec(argv);
        free_str_vec(envp);
        char msg[256];
        posix_err_str(resolve_err ? resolve_err : ENOENT, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    int in_p[2] = { -1, -1 }, out_p[2] = { -1, -1 }, err_p[2] = { -1, -1 }, rep_p[2] = { -1, -1 };
    int fail = 0;
    if ((flags & STS_PROC_PIPE_STDIN) && cloexec_pipe(in_p) != 0) fail = errno;
    if (!fail && (flags & STS_PROC_PIPE_STDOUT) && cloexec_pipe(out_p) != 0) fail = errno;
    if (!fail && (flags & STS_PROC_PIPE_STDERR) && cloexec_pipe(err_p) != 0) fail = errno;
    if (!fail && cloexec_pipe(rep_p) != 0) fail = errno;

    int max_fd_hint = posix_max_open_fd_hint();
    pid_t pid = -1;
    if (!fail) pid = fork();
    if (pid == 0) {
        if (relocate_fd_above_2(&rep_p[1]) != 0 ||
            relocate_fd_above_2(&in_p[0]) != 0 ||
            relocate_fd_above_2(&out_p[1]) != 0 ||
            relocate_fd_above_2(&err_p[1]) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        int need_null = (in_p[0] < 0 || out_p[1] < 0 || err_p[1] < 0);
        int null_fd = -1;
        if (need_null) {
            null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
            if (null_fd < 0 || relocate_fd_above_2(&null_fd) != 0) {
                int e = errno;
                if (write(rep_p[1], &e, sizeof(e)) < 0) {}
                _exit(127);
            }
        }
        if ((flags & STS_PROC_NEW_PGID) && setpgid(0, 0) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        if (child_dup2_stdio(in_p[0] >= 0 ? in_p[0] : null_fd, 0) != 0 ||
            child_dup2_stdio(out_p[1] >= 0 ? out_p[1] : null_fd, 1) != 0 ||
            child_dup2_stdio(err_p[1] >= 0 ? err_p[1] : null_fd, 2) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        set_cloexec_from(3, max_fd_hint);
        reset_child_signals();
        if (dir != NULL && chdir(dir) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        if (envp != NULL) {
            execve(exec_path, argv, envp);
        } else {
            execv(exec_path, argv);
        }
        int e = errno;
        if (write(rep_p[1], &e, sizeof(e)) < 0) {}
        _exit(127);
    }

    if (pid < 0 && !fail) fail = errno;
    if (rep_p[1] >= 0) close(rep_p[1]);
    if (!fail) {
        int e = 0;
        ssize_t n;
        do {
            n = read(rep_p[0], &e, sizeof(e));
        } while (n < 0 && errno == EINTR);
        if (n == (ssize_t)sizeof(e)) {
            fail = e;
            int st = 0;
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        }
    }
    if (rep_p[0] >= 0) close(rep_p[0]);
    if (in_p[0] >= 0) close(in_p[0]);
    if (out_p[1] >= 0) close(out_p[1]);
    if (err_p[1] >= 0) close(err_p[1]);
    free(exec_path);
    free_str_vec(argv);
    free_str_vec(envp);

    if (fail != 0) {
        if (in_p[1] >= 0) close(in_p[1]);
        if (out_p[0] >= 0) close(out_p[0]);
        if (err_p[0] >= 0) close(err_p[0]);
        char msg[256];
        posix_err_str(fail, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    posix_proc_t *p = (posix_proc_t *)calloc(1, sizeof(*p));
    if (p == NULL) {
        kill((flags & STS_PROC_NEW_PGID) ? -pid : pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        if (in_p[1] >= 0) close(in_p[1]);
        if (out_p[0] >= 0) close(out_p[0]);
        if (err_p[0] >= 0) close(err_p[0]);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    p->event_id = event_id;
    p->pid = pid;
    atomic_store_explicit(&p->closing, 0, memory_order_relaxed);
    p->stdin_fd = in_p[1];
    p->stdout_fd = out_p[0];
    p->stderr_fd = err_p[0];
    p->stdin_wake[0] = p->stdin_wake[1] = -1;
    p->pipes_wake[0] = p->pipes_wake[1] = -1;
    pthread_mutex_init(&p->kill_lock, NULL);
    pthread_mutex_init(&p->stdin_lock, NULL);
    pthread_mutex_init(&p->ref_lock, NULL);
    p->refs = 1;

    int workers_ok = 1;
    if (p->stdin_fd >= 0) {
        int fl = fcntl(p->stdin_fd, F_GETFL, 0);
        if (fl >= 0) fcntl(p->stdin_fd, F_SETFL, fl | O_NONBLOCK);
        if (make_wakeup_pipe(p->stdin_wake) != 0) {
            workers_ok = 0;
        } else {
            posix_proc_ref(p);
            if (!spawn_detached_thread(posix_stdin_thread, p)) {
                posix_proc_unref(p);
                workers_ok = 0;
            }
        }
    }
    if (workers_ok && (p->stdout_fd >= 0 || p->stderr_fd >= 0)) {
        if (make_wakeup_pipe(p->pipes_wake) != 0) {
            workers_ok = 0;
        } else {
            posix_proc_ref(p);
            if (!spawn_detached_thread(posix_pipes_thread, p)) {
                posix_proc_unref(p);
                workers_ok = 0;
            }
        }
    }

    int64_t id = workers_ok ? ht_insert(STS_HK_PROC, p) : -1;
    if (id >= 0) {
        posix_proc_ref(p);
        if (!spawn_reaper_thread(posix_wait_thread, p)) {
            posix_proc_unref(p);
            ht_take(STS_HK_PROC, id);
            id = -1;
        }
    }
    if (id < 0) {
        pthread_mutex_lock(&p->kill_lock);
        atomic_store_explicit(&p->closing, 1, memory_order_release);
        pthread_mutex_unlock(&p->kill_lock);
        kill((flags & STS_PROC_NEW_PGID) ? -pid : pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        pthread_mutex_lock(&p->stdin_lock);
        p->stdin_aborted = 1;
        pthread_mutex_unlock(&p->stdin_lock);
        wake_pipe_signal(p->stdin_wake[1]);
        wake_pipe_signal(p->pipes_wake[1]);
        posix_proc_unref(p);
        copy_err(err_buf, err_cap, "worker spawn failed");
        return -1;
    }
    if (out_pid != NULL) {
        *out_pid = (int64_t)pid;
    }
    return id;
}

int32_t sts_proc_write_stdin(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    posix_proc_t *p = posix_proc_get(handle);
    if (p == NULL) return 0;
    pthread_mutex_lock(&p->stdin_lock);
    if (p->stdin_fd < 0 || p->stdin_eof || p->stdin_aborted) {
        pthread_mutex_unlock(&p->stdin_lock);
        posix_proc_unref(p);
        return 0;
    }
    if (len == 0) {
        pthread_mutex_unlock(&p->stdin_lock);
        posix_proc_unref(p);
        return 1;
    }
    size_t ulen = (size_t)len;
    if (ulen > STS_STDIN_QUEUE_MAX || p->stdin_queued > STS_STDIN_QUEUE_MAX - ulen) {
        pthread_mutex_unlock(&p->stdin_lock);
        posix_proc_unref(p);
        return 0;
    }
    sts_chunk_t *ch = (sts_chunk_t *)malloc(sizeof(*ch) + ulen);
    if (ch == NULL) {
        pthread_mutex_unlock(&p->stdin_lock);
        posix_proc_unref(p);
        return 0;
    }
    ch->next = NULL;
    ch->len = ulen;
    ch->off = 0;
    memcpy(ch->data, data, ulen);
    if (p->stdin_tail != NULL) p->stdin_tail->next = ch;
    else p->stdin_head = ch;
    p->stdin_tail = ch;
    p->stdin_queued += ulen;
    pthread_mutex_unlock(&p->stdin_lock);
    wake_pipe_signal(p->stdin_wake[1]);
    posix_proc_unref(p);
    return 1;
}

int32_t sts_proc_close_stdin(int64_t handle) {
    posix_proc_t *p = posix_proc_get(handle);
    if (p == NULL) return 0;
    pthread_mutex_lock(&p->stdin_lock);
    p->stdin_eof = 1;
    pthread_mutex_unlock(&p->stdin_lock);
    wake_pipe_signal(p->stdin_wake[1]);
    posix_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill_handle(int64_t handle, int32_t sig, int32_t group) {
    posix_proc_t *p = posix_proc_get(handle);
    if (p == NULL) return -ESRCH;
    pthread_mutex_lock(&p->kill_lock);
    int32_t res;
    if (p->exited) {
        res = -ESRCH;
    } else if (p->kill_revoked) {
        res = -ENOTSUP;
    } else {
        int rc = kill(group ? -p->pid : p->pid, posix_signal_of(sig));
        res = (rc == 0) ? 0 : -errno;
    }
    pthread_mutex_unlock(&p->kill_lock);
    posix_proc_unref(p);
    return res;
}

int32_t sts_proc_close(int64_t handle) {
    posix_proc_t *p = (posix_proc_t *)ht_take(STS_HK_PROC, handle);
    if (p == NULL) return 0;
    pthread_mutex_lock(&p->kill_lock);
    atomic_store_explicit(&p->closing, 1, memory_order_release);
    pthread_mutex_unlock(&p->kill_lock);
    pthread_mutex_lock(&p->stdin_lock);
    p->stdin_aborted = 1;
    pthread_mutex_unlock(&p->stdin_lock);
    wake_pipe_signal(p->stdin_wake[1]);
    wake_pipe_signal(p->pipes_wake[1]);
    posix_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill(int32_t pid, int32_t sig, int32_t group) {
    if (pid <= 0) return -1;
    int rc = kill(group ? -(pid_t)pid : (pid_t)pid, posix_signal_of(sig));
    return rc == 0 ? 0 : -errno;
}

int64_t sts_proc_start_ticks(int32_t pid) {
    if (pid <= 0) return -1;
#ifdef __APPLE__
    (void)pid;
    return -1;
#else
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (f == NULL) return -1;
    char buf[4096];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return -1;
    buf[n] = '\0';
    // Skip past last ')' of comm field.
    char *rp = strrchr(buf, ')');
    if (rp == NULL || rp[1] != ' ') return -1;
    // After ") ", fields start at field 3 (state). Field 22 is starttime (index 19 from field 3).
    const char *p = rp + 2;
    unsigned long long starttime = 0;
    int field = 3;
    while (*p != '\0') {
        while (*p == ' ') p++;
        if (*p == '\0') break;
        if (field == 22) {
            starttime = strtoull(p, NULL, 10);
            break;
        }
        while (*p != '\0' && *p != ' ') p++;
        field += 1;
    }
    if (field != 22) return -1;
    return (int64_t)starttime;
#endif
}

void *sts_boot_id(int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
#ifdef __APPLE__
    return NULL;
#else
    FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
    if (f == NULL) return NULL;
    char buf[128];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ' || buf[n - 1] == '\t')) {
        n--;
    }
    if (n == 0) return NULL;
    return dup_bytes(buf, n, out_len);
#endif
}

int64_t sts_proc_start_time_ms(int32_t pid) {
    if (pid <= 0) return -1;
#ifdef __APPLE__
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int got = proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (got <= 0) return -1;
    return (int64_t)info.pbi_start_tvsec * 1000LL + (int64_t)(info.pbi_start_tvusec / 1000);
#else
    int64_t ticks = sts_proc_start_ticks(pid);
    if (ticks < 0) return -1;
    unsigned long long starttime = (unsigned long long)ticks;
    long clk = sysconf(_SC_CLK_TCK);
    if (clk <= 0) clk = 100;
    // Read btime from /proc/stat.
    FILE *sf = fopen("/proc/stat", "r");
    if (sf == NULL) return -1;
    char line[256];
    unsigned long long btime = 0;
    while (fgets(line, sizeof(line), sf) != NULL) {
        if (strncmp(line, "btime ", 6) == 0) {
            btime = strtoull(line + 6, NULL, 10);
            break;
        }
    }
    fclose(sf);
    if (btime == 0) return -1;
    return (int64_t)(btime * 1000ULL + (starttime * 1000ULL) / (unsigned long long)clk);
#endif
}

// ---------------------------------------------------------------------------
// 3. POSIX Launcher Control Channel (fd e.g. fd 5; never touches fds 3/4)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    int fd;
    int wake[2];
    pthread_t thread;
    pthread_mutex_t write_lock;
    pthread_mutex_t ref_lock;
    int refs;
} posix_ctrl_t;

static void posix_ctrl_unref(posix_ctrl_t *c) {
    pthread_mutex_lock(&c->ref_lock);
    int last = (--c->refs == 0);
    pthread_mutex_unlock(&c->ref_lock);
    if (!last) return;
    if (c->fd >= 0) close(c->fd);
    close_fd_pair(c->wake);
    pthread_mutex_destroy(&c->write_lock);
    pthread_mutex_destroy(&c->ref_lock);
    free(c);
}

static void *posix_ctrl_thread(void *arg) {
    posix_ctrl_t *c = (posix_ctrl_t *)arg;
    sbuf_t line = { 0, 0, 0 };
    char buf[4096];
    struct pollfd pfds[2];
    pfds[0].fd = c->fd;
    pfds[0].events = POLLIN;
    pfds[1].fd = c->wake[0];
    pfds[1].events = POLLIN;
    int eof = 0;
    int line_overflow = 0;

    for (;;) {
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        int rc = poll(pfds, 2, -1);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || pfds[1].revents != 0) break;
        if (pfds[0].revents != 0) {
            ssize_t n = read(c->fd, buf, sizeof(buf));
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (n <= 0) {
                eof = 1;
                break;
            }
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == '\n') {
                    if (line_overflow) {
                        const char *ovf = "__CTRL_LINE_OVERFLOW__";
                        push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, ovf, strlen(ovf));
                        line_overflow = 0;
                        line.len = 0;
                    } else {
                        size_t ll = line.len;
                        if (ll > 0 && line.data[ll - 1] == '\r') ll -= 1;
                        push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data ? line.data : "", ll);
                        line.len = 0;
                    }
                } else if (!line_overflow) {
                    if (line.len >= STS_CTRL_MAX_LINE) {
                        free(line.data);
                        line.data = NULL;
                        line.len = 0;
                        line.cap = 0;
                        line_overflow = 1;
                    } else {
                        sb_add(&line, buf + i, 1);
                    }
                }
            }
        }
    }
    if (eof) {
        // Discard any unterminated partial frame at EOF (never deliver as a complete line).
        push_tag_ctrl(c->event_id, STS_EV_CTRL_EOF, NULL, 0);
    }
    free(line.data);
    return NULL;
}

int64_t sts_ctrl_open_fd(uint64_t event_id, int32_t fd) {
    if (fd <= 4) return -1;
    ensure_sigpipe_ignored();
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);

    posix_ctrl_t *c = (posix_ctrl_t *)calloc(1, sizeof(*c));
    if (c == NULL) return -1;
    c->event_id = event_id;
    c->fd = (int)fd;
    c->wake[0] = c->wake[1] = -1;
    pthread_mutex_init(&c->write_lock, NULL);
    pthread_mutex_init(&c->ref_lock, NULL);
    c->refs = 1;
    if (make_wakeup_pipe(c->wake) != 0 ||
        pthread_create(&c->thread, NULL, posix_ctrl_thread, c) != 0) {
        c->fd = -1; // caller keeps fd if open failed
        posix_ctrl_unref(c);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_CTRL, c);
    if (id < 0) {
        wake_pipe_signal(c->wake[1]);
        pthread_join(c->thread, NULL);
        c->fd = -1;
        posix_ctrl_unref(c);
    }
    return id;
}

int64_t sts_ctrl_open_pipe(uint64_t event_id, const char *pipe_name) {
    (void)event_id;
    (void)pipe_name;
    return -1;
}

int32_t sts_ctrl_write(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (data == NULL) return 0;
    ensure_sigpipe_ignored();
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    posix_ctrl_t *c = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_CTRL) {
            c = (posix_ctrl_t *)cur->ptr;
            pthread_mutex_lock(&c->ref_lock);
            c->refs += 1;
            pthread_mutex_unlock(&c->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    if (c == NULL) return 0;

    pthread_mutex_lock(&c->write_lock);
    size_t done = 0;
    int ok = 1;
    while (done < (size_t)len) {
        ssize_t n = write(c->fd, data + done, (size_t)len - done);
        if (n > 0) {
            done += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd;
            pfd.fd = c->fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            if (poll(&pfd, 1, 5000) <= 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                ok = 0;
                break;
            }
            continue;
        }
        ok = 0;
        break;
    }
    pthread_mutex_unlock(&c->write_lock);
    posix_ctrl_unref(c);
    return ok;
}

int32_t sts_ctrl_close(int64_t handle) {
    posix_ctrl_t *c = (posix_ctrl_t *)ht_take(STS_HK_CTRL, handle);
    if (c == NULL) return 0;
    wake_pipe_signal(c->wake[1]);
    pthread_join(c->thread, NULL);
    posix_ctrl_unref(c);
    return 1;
}

// ---------------------------------------------------------------------------
// 4. POSIX Process Signals (self-pipe + dedicated reader thread)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    int sig_pipe[2];
    int wake[2];
    pthread_t thread;
} posix_sig_gen_t;

static const int k_watched_sigs[5] = { SIGTERM, SIGINT, SIGUSR1, SIGUSR2, SIGHUP };
static pthread_mutex_t g_sig_mu = PTHREAD_MUTEX_INITIALIZER;
static posix_sig_gen_t *g_sig_gen = NULL;
static _Atomic int g_sig_wr_fd = -1;
static _Atomic int g_sig_inflight = 0;
static struct sigaction g_prev_sa[5];

static void posix_on_signal(int sig) {
    int saved = errno;
    atomic_fetch_add_explicit(&g_sig_inflight, 1, memory_order_seq_cst);
    int fd = atomic_load_explicit(&g_sig_wr_fd, memory_order_seq_cst);
    if (fd >= 0) {
        uint8_t s = (uint8_t)sig;
        if (write(fd, &s, 1) < 0) {}
    }
    atomic_fetch_sub_explicit(&g_sig_inflight, 1, memory_order_seq_cst);
    errno = saved;
}

static void *posix_sig_thread(void *arg) {
    posix_sig_gen_t *gen = (posix_sig_gen_t *)arg;
    struct pollfd pfds[2];
    pfds[0].fd = gen->sig_pipe[0];
    pfds[0].events = POLLIN;
    pfds[1].fd = gen->wake[0];
    pfds[1].events = POLLIN;

    for (;;) {
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        int rc = poll(pfds, 2, -1);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || pfds[1].revents != 0) break;
        if (pfds[0].revents & POLLIN) {
            uint8_t s = 0;
            while (read(gen->sig_pipe[0], &s, 1) == 1) {
                const char *name = posix_signal_name((int)s);
                size_t nlen = strlen(name);
                uint8_t msg[64];
                msg[0] = STS_EV_SIGNAL;
                put_i32_le(msg + 1, (int32_t)s);
                memcpy(msg + 5, name, nlen);
                sth_push_sys(gen->event_id, msg, 5 + nlen);
            }
        }
    }
    return NULL;
}

static void posix_signal_unwatch_locked(void) {
    posix_sig_gen_t *gen = g_sig_gen;
    if (gen == NULL) return;
    for (int i = 0; i < 5; i++) {
        sigaction(k_watched_sigs[i], &g_prev_sa[i], NULL);
    }
    atomic_store_explicit(&g_sig_wr_fd, -1, memory_order_seq_cst);
    while (atomic_load_explicit(&g_sig_inflight, memory_order_seq_cst) > 0) {
        sched_yield();
    }
    wake_pipe_signal(gen->wake[1]);
    pthread_join(gen->thread, NULL);
    close_fd_pair(gen->sig_pipe);
    close_fd_pair(gen->wake);
    free(gen);
    g_sig_gen = NULL;
}

int32_t sts_signal_watch(uint64_t event_id) {
    pthread_mutex_lock(&g_sig_mu);
    posix_signal_unwatch_locked();
    posix_sig_gen_t *gen = (posix_sig_gen_t *)calloc(1, sizeof(*gen));
    if (gen == NULL) {
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    gen->event_id = event_id;
    gen->sig_pipe[0] = gen->sig_pipe[1] = -1;
    gen->wake[0] = gen->wake[1] = -1;
    if (make_wakeup_pipe(gen->sig_pipe) != 0 || make_wakeup_pipe(gen->wake) != 0) {
        close_fd_pair(gen->sig_pipe);
        close_fd_pair(gen->wake);
        free(gen);
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    if (pthread_create(&gen->thread, NULL, posix_sig_thread, gen) != 0) {
        close_fd_pair(gen->sig_pipe);
        close_fd_pair(gen->wake);
        free(gen);
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    atomic_store_explicit(&g_sig_wr_fd, gen->sig_pipe[1], memory_order_seq_cst);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = posix_on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    for (int i = 0; i < 5; i++) {
        sigaction(k_watched_sigs[i], &sa, &g_prev_sa[i]);
    }
    g_sig_gen = gen;
    pthread_mutex_unlock(&g_sig_mu);
    return 1;
}

int32_t sts_signal_unwatch(void) {
    pthread_mutex_lock(&g_sig_mu);
    posix_signal_unwatch_locked();
    pthread_mutex_unlock(&g_sig_mu);
    return 1;
}

// ---------------------------------------------------------------------------
// 5. POSIX Advisory File Lock (flock LOCK_EX | LOCK_NB)
// ---------------------------------------------------------------------------

int64_t sts_flock_try(const char *path) {
    if (path == NULL || path[0] == '\0') return -1;
    int fd = open(path, O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int rc;
    do {
        rc = flock(fd, LOCK_EX | LOCK_NB);
    } while (rc != 0 && errno == EINTR);
    if (rc != 0) {
        int e = errno;
        close(fd);
        return (e == EWOULDBLOCK || e == EAGAIN) ? 0 : -1;
    }
    int *pfd = (int *)malloc(sizeof(*pfd));
    if (pfd == NULL) {
        flock(fd, LOCK_UN);
        close(fd);
        return -1;
    }
    *pfd = fd;
    int64_t id = ht_insert(STS_HK_FLOCK, pfd);
    if (id < 0) {
        flock(fd, LOCK_UN);
        close(fd);
        free(pfd);
    }
    return id;
}

int32_t sts_flock_unlock(int64_t handle) {
    int *pfd = (int *)ht_take(STS_HK_FLOCK, handle);
    if (pfd == NULL) return 0;
    int fd = *pfd;
    free(pfd);
    flock(fd, LOCK_UN);
    return close(fd) == 0 ? 1 : 0;
}

int32_t sts_unlink(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    return unlink(path) == 0 ? 1 : 0;
}

int32_t sts_rmdir(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    return rmdir(path) == 0 ? 1 : 0;
}

void *sts_readlink(const char *path, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (path == NULL || path[0] == '\0') return NULL;
    size_t cap = 512;
    while (cap <= 65536) {
        char *buf = (char *)malloc(cap);
        if (buf == NULL) return NULL;
        ssize_t n = readlink(path, buf, cap);
        if (n < 0) {
            free(buf);
            return NULL;
        }
        if ((size_t)n < cap) {
            void *res = dup_bytes(buf, (size_t)n, out_len);
            free(buf);
            return res;
        }
        free(buf);
        cap *= 2;
    }
    return NULL;
}

static int32_t sts_posix_map_errno(int e) {
    if (e == ENOENT || e == ENOTDIR) return -2;
    if (e == EACCES || e == EPERM || e == EROFS) return -3;
    if (e == EISDIR) return -4;
    if (e == ELOOP || e == ENXIO) return -5;
    return -1;
}

static int sts_posix_open_retry(const char *path, int flags, mode_t mode) {
    int fd;
    do {
        fd = open(path, flags, mode);
    } while (fd < 0 && errno == EINTR);
    return fd;
}

static int sts_path_is_part_temp(const char *path) {
    if (path == NULL) return 0;
    size_t n = strlen(path);
    return n >= 5 && memcmp(path + n - 5, ".part", 5) == 0;
}

void *sts_realpath_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    char *resolved = realpath(path, NULL);
    if (resolved == NULL) {
        if (out_err != NULL) *out_err = sts_posix_map_errno(errno);
        return NULL;
    }
    void *res = dup_bytes(resolved, strlen(resolved), out_len);
    free(resolved);
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_realpath(const char *path, int64_t *out_len) {
    return sts_realpath_err(path, out_len, NULL);
}

void *sts_lstat_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    struct stat st;
    if (lstat(path, &st) != 0) {
        if (out_err != NULL) *out_err = sts_posix_map_errno(errno);
        return NULL;
    }
    const char *kind = S_ISREG(st.st_mode) ? "file"
                     : S_ISDIR(st.st_mode) ? "dir"
                     : S_ISLNK(st.st_mode) ? "link"
                     : "other";
#ifdef __APPLE__
    int64_t mtime_ms = (int64_t)st.st_mtimespec.tv_sec * 1000LL + (int64_t)(st.st_mtimespec.tv_nsec / 1000000L);
#else
    int64_t mtime_ms = (int64_t)st.st_mtim.tv_sec * 1000LL + (int64_t)(st.st_mtim.tv_nsec / 1000000L);
#endif
    char buf[192];
    int n = snprintf(
        buf, sizeof(buf), "%s|%lld|%d|%lld|%llu|%llu|%u",
        kind,
        (long long)st.st_size,
        (st.st_mode & 0111) != 0 ? 1 : 0,
        (long long)mtime_ms,
        (unsigned long long)st.st_dev,
        (unsigned long long)st.st_ino,
        (unsigned int)(st.st_mode & 07777));
    void *res = n > 0 ? dup_bytes(buf, (size_t)n, out_len) : NULL;
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_lstat(const char *path, int64_t *out_len) {
    return sts_lstat_err(path, out_len, NULL);
}

void *sts_stat_err(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') return NULL;
    struct stat st;
    if (stat(path, &st) != 0) {
        if (out_err != NULL) *out_err = sts_posix_map_errno(errno);
        return NULL;
    }
    const char *kind = S_ISREG(st.st_mode) ? "file"
                     : S_ISDIR(st.st_mode) ? "dir"
                     : S_ISLNK(st.st_mode) ? "link"
                     : "other";
#ifdef __APPLE__
    int64_t mtime_ms = (int64_t)st.st_mtimespec.tv_sec * 1000LL + (int64_t)(st.st_mtimespec.tv_nsec / 1000000L);
#else
    int64_t mtime_ms = (int64_t)st.st_mtim.tv_sec * 1000LL + (int64_t)(st.st_mtim.tv_nsec / 1000000L);
#endif
    char buf[192];
    int n = snprintf(
        buf, sizeof(buf), "%s|%lld|%d|%lld|%llu|%llu|%u",
        kind,
        (long long)st.st_size,
        (st.st_mode & 0111) != 0 ? 1 : 0,
        (long long)mtime_ms,
        (unsigned long long)st.st_dev,
        (unsigned long long)st.st_ino,
        (unsigned int)(st.st_mode & 07777));
    void *res = n > 0 ? dup_bytes(buf, (size_t)n, out_len) : NULL;
    if (res != NULL && out_err != NULL) *out_err = 0;
    return res;
}

void *sts_stat(const char *path, int64_t *out_len) {
    return sts_stat_err(path, out_len, NULL);
}

int32_t sts_chmod(const char *path, int32_t mode) {
    if (path == NULL || path[0] == '\0') return 0;
    return chmod(path, (mode_t)mode) == 0 ? 1 : 0;
}

int32_t sts_truncate_in_place(const char *path, int64_t size) {
    if (path == NULL || path[0] == '\0' || size < 0) return 0;
    int rc;
    do {
        rc = truncate(path, (off_t)size);
    } while (rc < 0 && errno == EINTR);
    return rc == 0 ? 1 : 0;
}

void *sts_read_range(const char *path, int64_t offset, int64_t len, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0) return NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    if (len == 0) {
        close(fd);
        return dup_bytes("", 0, out_len);
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)len);
    if (buf == NULL) {
        close(fd);
        return NULL;
    }
    int64_t total = 0;
    while (total < len) {
        ssize_t got = pread(fd, buf + total, (size_t)(len - total), (off_t)(offset + total));
        if (got < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return NULL;
        }
        if (got == 0) break;
        total += (int64_t)got;
    }
    close(fd);
    if (out_len != NULL) *out_len = total;
    return buf;
}

void *sts_read_range_meta(
    const char *path,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_total_size,
    int64_t *out_mtime_ms,
    int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_total_size != NULL) *out_total_size = 0;
    if (out_mtime_ms != NULL) *out_mtime_ms = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) {
        if (out_err != NULL) *out_err = -6;
        return NULL;
    }
    int fd = sts_posix_open_retry(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0) {
        if (out_err != NULL) *out_err = sts_posix_map_errno(errno);
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        if (out_err != NULL) *out_err = sts_posix_map_errno(e);
        return NULL;
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        if (out_err != NULL) *out_err = -4;
        return NULL;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        if (out_err != NULL) *out_err = -5;
        return NULL;
    }
#ifdef __APPLE__
    int64_t mtime_ms = (int64_t)st.st_mtimespec.tv_sec * 1000LL + (int64_t)(st.st_mtimespec.tv_nsec / 1000000L);
#else
    int64_t mtime_ms = (int64_t)st.st_mtim.tv_sec * 1000LL + (int64_t)(st.st_mtim.tv_nsec / 1000000L);
#endif
    int64_t fsz = (int64_t)st.st_size;
    if (out_total_size != NULL) *out_total_size = fsz;
    if (out_mtime_ms != NULL) *out_mtime_ms = mtime_ms;
    if (len == 0 || offset >= fsz) {
        close(fd);
        if (out_err != NULL) *out_err = 0;
        return dup_bytes("", 0, out_len);
    }
    int64_t avail = fsz - offset;
    int64_t want = len < avail ? len : avail;
    uint8_t *buf = (uint8_t *)malloc((size_t)(want > 0 ? want : 1));
    if (buf == NULL) {
        close(fd);
        return NULL;
    }
    int64_t total = 0;
    while (total < want) {
        ssize_t got = pread(fd, buf + total, (size_t)(want - total), (off_t)(offset + total));
        if (got < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            free(buf);
            close(fd);
            if (out_err != NULL) *out_err = sts_posix_map_errno(e);
            return NULL;
        }
        if (got == 0) break;
        total += (int64_t)got;
    }
    close(fd);
    if (out_len != NULL) *out_len = total;
    if (out_err != NULL) *out_err = 0;
    return buf;
}

int32_t sts_write_at(
    const char *path,
    int64_t offset,
    const uint8_t *data,
    int64_t len,
    int32_t create,
    int32_t has_at_least,
    int64_t at_least,
    int32_t has_truncate,
    int64_t truncate_to,
    int32_t do_sync,
    int64_t *out_size,
    int32_t *out_short) {
    if (out_size != NULL) *out_size = 0;
    if (out_short != NULL) *out_short = 0;
    if (path == NULL || path[0] == '\0' || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) return -6;
    int flags = O_RDWR | O_NONBLOCK | O_CLOEXEC | (create ? (O_CREAT | O_TRUNC) : 0);
    if (sts_path_is_part_temp(path)) {
        flags |= O_NOFOLLOW;
    }
    int fd = sts_posix_open_retry(path, flags, (mode_t)0644);
    if (fd < 0) {
        return sts_posix_map_errno(errno);
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return sts_posix_map_errno(e);
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        return -4;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        return -5;
    }
    if (has_at_least && (int64_t)st.st_size < at_least) {
        if (out_size != NULL) *out_size = (int64_t)st.st_size;
        if (out_short != NULL) *out_short = 1;
        close(fd);
        return 0;
    }
    int64_t written = 0;
    while (written < len) {
        ssize_t put = pwrite(fd, data + written, (size_t)(len - written), (off_t)(offset + written));
        if (put < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            close(fd);
            return sts_posix_map_errno(e);
        }
        if (put == 0) {
            close(fd);
            return -1;
        }
        written += (int64_t)put;
    }
    if (has_truncate && truncate_to >= 0) {
        int trc;
        do {
            trc = ftruncate(fd, (off_t)truncate_to);
        } while (trc < 0 && errno == EINTR);
        if (trc != 0) {
            int e = errno;
            close(fd);
            return sts_posix_map_errno(e);
        }
    }
    if (do_sync) {
        int src;
        do {
            src = fsync(fd);
        } while (src < 0 && errno == EINTR);
        if (src != 0) {
            int e = errno;
            close(fd);
            return sts_posix_map_errno(e);
        }
    }
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return sts_posix_map_errno(e);
    }
    if (out_size != NULL) *out_size = (int64_t)st.st_size;
    if (close(fd) != 0) {
        return sts_posix_map_errno(errno);
    }
    return 0;
}

int32_t sts_sync_file(const char *path) {
    if (path == NULL || path[0] == '\0') return -6;
    int fd = sts_posix_open_retry(path, O_RDWR | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0 && (errno == EACCES || errno == EROFS)) {
        fd = sts_posix_open_retry(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    }
    if (fd < 0) {
        return sts_posix_map_errno(errno);
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return sts_posix_map_errno(e);
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        return -4;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        return -5;
    }
    int rc;
    do {
        rc = fsync(fd);
    } while (rc < 0 && errno == EINTR);
    int e = errno;
    close(fd);
    return rc == 0 ? 0 : sts_posix_map_errno(e);
}

typedef struct {
    int fd;
    int refs;
    int closed;
} posix_file_ro_t;

int64_t sts_file_open_ro(const char *path, int64_t *out_size, int32_t *out_err) {
    if (out_size != NULL) *out_size = 0;
    if (out_err != NULL) *out_err = -1;
    if (path == NULL || path[0] == '\0') {
        if (out_err != NULL) *out_err = -6;
        return -1;
    }
    int fd = sts_posix_open_retry(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0) {
        int e = errno;
        if (out_err != NULL) {
            *out_err = (e == ELOOP) ? -5 : sts_posix_map_errno(e);
        }
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        if (out_err != NULL) *out_err = sts_posix_map_errno(e);
        return -1;
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        if (out_err != NULL) *out_err = -4;
        return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        if (out_err != NULL) *out_err = -5;
        return -1;
    }
    posix_file_ro_t *f = (posix_file_ro_t *)malloc(sizeof(*f));
    if (f == NULL) {
        close(fd);
        return -1;
    }
    f->fd = fd;
    f->refs = 1;
    f->closed = 0;
    int64_t id = ht_insert(STS_HK_FILE_RO, f);
    if (id < 0) {
        close(fd);
        free(f);
        return -1;
    }
    if (out_size != NULL) *out_size = (int64_t)st.st_size;
    if (out_err != NULL) *out_err = 0;
    return id;
}

void *sts_file_pread(int64_t handle, int64_t offset, int64_t len, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = -1;
    if (handle <= 0 || offset < 0 || len < 0 ||
        len > (int64_t)INT32_MAX || offset > INT64_MAX - len) {
        if (out_err != NULL) *out_err = -6;
        return NULL;
    }
    posix_file_ro_t *f = NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    for (sts_hnode_t *cur = g_ht_buckets[b]; cur != NULL; cur = cur->next) {
        if (cur->id == handle && cur->kind == STS_HK_FILE_RO) {
            posix_file_ro_t *cand = (posix_file_ro_t *)cur->ptr;
            if (!cand->closed) {
                cand->refs += 1;
                f = cand;
            }
            break;
        }
    }
    ht_unlock();
    if (f == NULL) {
        if (out_err != NULL) *out_err = -2;
        return NULL;
    }
    void *res = NULL;
    int32_t err = 0;
    if (len == 0) {
        res = dup_bytes("", 0, out_len);
        if (res == NULL) err = -1;
    } else {
        uint8_t *buf = (uint8_t *)malloc((size_t)len);
        if (buf == NULL) {
            err = -1;
        } else {
            int64_t total = 0;
            while (total < len) {
                ssize_t got = pread(f->fd, buf + total, (size_t)(len - total), (off_t)(offset + total));
                if (got < 0) {
                    if (errno == EINTR) continue;
                    int e = errno;
                    free(buf);
                    buf = NULL;
                    err = sts_posix_map_errno(e);
                    break;
                }
                if (got == 0) break;
                total += (int64_t)got;
            }
            if (buf != NULL) {
                if (out_len != NULL) *out_len = total;
                res = buf;
            }
        }
    }
    int should_free = 0;
    ht_lock();
    f->refs -= 1;
    if (f->refs == 0) should_free = 1;
    ht_unlock();
    if (should_free) {
        close(f->fd);
        free(f);
    }
    if (out_err != NULL) *out_err = err;
    return res;
}

int32_t sts_file_close(int64_t handle) {
    if (handle <= 0) return 0;
    posix_file_ro_t *f = NULL;
    int should_free = 0;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t **pp = &g_ht_buckets[b];
    while (*pp != NULL) {
        sts_hnode_t *cur = *pp;
        if (cur->id == handle && cur->kind == STS_HK_FILE_RO) {
            *pp = cur->next;
            f = (posix_file_ro_t *)cur->ptr;
            free(cur);
            f->closed = 1;
            f->refs -= 1;
            if (f->refs == 0) should_free = 1;
            break;
        }
        pp = &cur->next;
    }
    ht_unlock();
    if (f == NULL) return 0;
    if (should_free) {
        close(f->fd);
        free(f);
    }
    return 1;
}

int32_t sts_mkdir_exclusive(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    return mkdir(path, (mode_t)0700) == 0 ? 1 : 0;
}

int32_t sts_getuid(void) { return (int32_t)getuid(); }
int32_t sts_geteuid(void) { return (int32_t)geteuid(); }

int32_t sts_write_file_mode(
    const char *path,
    const uint8_t *data,
    int64_t len,
    int32_t mode,
    int32_t append) {
    if (path == NULL || path[0] == '\0' || len < 0) return 0;
    int flags = O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC);
    mode_t m = mode > 0 ? (mode_t)mode : (mode_t)0600;
    int fd = open(path, flags, m);
    if (fd < 0) return 0;
    int64_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, (size_t)(len - off));
        if (w < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return 0;
        }
        off += (int64_t)w;
    }
    return close(fd) == 0 ? 1 : 0;
}

static int sts_open_dir_nofollow_walk(const char *root, const char *rel, int create_parents, char *leaf_out, size_t leaf_cap) {
    if (root == NULL || root[0] == '\0' || rel == NULL || rel[0] == '\0') return -1;
    if (rel[0] == '/' || rel[0] == '\\') return -1;
    int dirfd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0) return -1;
    const char *p = rel;
    while (*p != '\0') {
        while (*p == '/' || *p == '\\') p++;
        if (*p == '\0') {
            close(dirfd);
            return -1;
        }
        const char *seg = p;
        while (*p != '\0' && *p != '/' && *p != '\\') p++;
        size_t seglen = (size_t)(p - seg);
        if (seglen == 0 || seglen >= leaf_cap) {
            close(dirfd);
            return -1;
        }
        if ((seglen == 1 && seg[0] == '.') || (seglen == 2 && seg[0] == '.' && seg[1] == '.')) {
            close(dirfd);
            return -1;
        }
        const char *rest = p;
        while (*rest == '/' || *rest == '\\') rest++;
        if (*rest == '\0') {
            memcpy(leaf_out, seg, seglen);
            leaf_out[seglen] = '\0';
            return dirfd;
        }
        char comp[512];
        if (seglen >= sizeof(comp)) {
            close(dirfd);
            return -1;
        }
        memcpy(comp, seg, seglen);
        comp[seglen] = '\0';
        if (create_parents) {
            (void)mkdirat(dirfd, comp, 0755);
        }
        int nextfd = openat(dirfd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(dirfd);
        if (nextfd < 0) return -1;
        dirfd = nextfd;
        p = rest;
    }
    close(dirfd);
    return -1;
}

void *sts_read_under_nofollow(
    const char *root,
    const char *rel,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_size) {
    if (out_len != NULL) *out_len = 0;
    if (out_size != NULL) *out_size = 0;
    if (offset < 0 || len < 0) return NULL;
    char leaf[512];
    int dirfd = sts_open_dir_nofollow_walk(root, rel, 0, leaf, sizeof(leaf));
    if (dirfd < 0) return NULL;
    int fd = openat(dirfd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    close(dirfd);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }
    int64_t fsize = (int64_t)st.st_size;
    if (out_size != NULL) *out_size = fsize;
    if (offset > fsize) {
        close(fd);
        return NULL;
    }
    int64_t want = len;
    if (offset + want > fsize) want = fsize - offset;
    if (want <= 0) {
        close(fd);
        return dup_bytes("", 0, out_len);
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)want);
    if (buf == NULL) {
        close(fd);
        return NULL;
    }
    int64_t total = 0;
    while (total < want) {
        ssize_t got = pread(fd, buf + total, (size_t)(want - total), (off_t)(offset + total));
        if (got < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return NULL;
        }
        if (got == 0) break;
        total += (int64_t)got;
    }
    close(fd);
    if (out_len != NULL) *out_len = total;
    return buf;
}

int32_t sts_write_under_nofollow(
    const char *root,
    const char *rel,
    const uint8_t *data,
    int64_t len,
    int64_t offset,
    int32_t mode,
    int32_t truncate_end) {
    if (len < 0 || offset < 0) return 0;
    char leaf[512];
    int dirfd = sts_open_dir_nofollow_walk(root, rel, 1, leaf, sizeof(leaf));
    if (dirfd < 0) return 0;
    mode_t m = mode > 0 ? (mode_t)mode : (mode_t)0600;
    int fd = openat(dirfd, leaf, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, m);
    close(dirfd);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return 0;
    }
    if (offset > (int64_t)st.st_size) {
        close(fd);
        return -2;
    }
    int64_t done = 0;
    while (done < len) {
        ssize_t w = pwrite(fd, data + done, (size_t)(len - done), (off_t)(offset + done));
        if (w < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return 0;
        }
        done += (int64_t)w;
    }
    if (truncate_end != 0) {
        int trc;
        do {
            trc = ftruncate(fd, (off_t)(offset + len));
        } while (trc < 0 && errno == EINTR);
        if (trc != 0) {
            close(fd);
            return 0;
        }
    }
    return close(fd) == 0 ? 1 : 0;
}

void *sts_read_dir(const char *path, int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    if (path == NULL || path[0] == '\0') return NULL;
    DIR *d = opendir(path);
    if (d == NULL) return NULL;
    sbuf_t b = { 0, 0, 0 };
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        sb_add(&b, ent->d_name, strlen(ent->d_name));
        sb_add(&b, "\0", 1);
    }
    closedir(d);
    return sb_finish(&b, out_len);
}

int32_t sts_mkdir_p(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    size_t len = strlen(path);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) return 0;
    memcpy(copy, path, len + 1);
    for (size_t i = 1; i <= len; i++) {
        if (copy[i] == '/' || copy[i] == '\0') {
            char saved = copy[i];
            copy[i] = '\0';
            if (copy[0] != '\0') {
                if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
                    struct stat st;
                    if (stat(copy, &st) != 0 || !S_ISDIR(st.st_mode)) {
                        free(copy);
                        return 0;
                    }
                }
            }
            copy[i] = saved;
        }
    }
    free(copy);
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) ? 1 : 0;
}

int32_t sts_rename(const char *old_path, const char *new_path) {
    if (old_path == NULL || new_path == NULL) return 0;
    return rename(old_path, new_path) == 0 ? 1 : 0;
}

int32_t sts_random_bytes(uint8_t *buf, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (buf == NULL) return 0;
#ifdef __APPLE__
    arc4random_buf(buf, (size_t)len);
    return 1;
#else
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    int64_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, buf + off, (size_t)(len - off));
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return 0;
        }
        if (n == 0) {
            close(fd);
            return 0;
        }
        off += (int64_t)n;
    }
    close(fd);
    return 1;
#endif
}

int32_t sts_mkdir_mode(const char *path, int32_t mode) {
    if (path == NULL || path[0] == '\0') return 0;
    mode_t m = mode > 0 ? (mode_t)(mode & 0777) : (mode_t)0700;
    if (mkdir(path, m) == 0) {
        return 1;
    }
    if (errno == EEXIST) return -2;
    if (errno == EACCES || errno == EPERM) return -3;
    if (errno == ENOENT) return -4;
    return 0;
}

int32_t sts_symlink(const char *target, const char *link_path, int32_t is_dir) {
    (void)is_dir;
    if (target == NULL || link_path == NULL || link_path[0] == '\0') return 0;
    return symlink(target, link_path) == 0 ? 1 : 0;
}

int32_t sts_is_dir_symlink(const char *path) {
    (void)path;
    return 0;
}

void *sts_getcwd(int64_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    char buf[4096];
    if (getcwd(buf, sizeof(buf)) == NULL) return NULL;
    size_t n = strlen(buf);
    char *out = (char *)malloc(n + 1);
    if (out == NULL) return NULL;
    memcpy(out, buf, n + 1);
    if (out_len != NULL) *out_len = (int64_t)n;
    return out;
}

void *sts_read_file_strict(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) *out_len = 0;
    if (out_err != NULL) *out_err = 3;
    if (path == NULL || path[0] == '\0') return NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        if (out_err != NULL) {
            if (errno == ENOENT || errno == ENOTDIR) *out_err = 1;
            else if (errno == EACCES || errno == EPERM) *out_err = 2;
            else *out_err = 3;
        }
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        if (out_err != NULL) *out_err = 3;
        return NULL;
    }
    if (st.st_size < 0 || (uint64_t)st.st_size > (1ULL << 30)) {
        close(fd);
        if (out_err != NULL) *out_err = 3;
        return NULL;
    }
    size_t cap = (size_t)st.st_size;
    uint8_t *buf = (uint8_t *)malloc(cap + 1);
    if (buf == NULL) {
        close(fd);
        if (out_err != NULL) *out_err = 3;
        return NULL;
    }
    size_t off = 0;
    while (off < cap) {
        ssize_t n = read(fd, buf + off, cap - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            if (out_err != NULL) *out_err = 3;
            return NULL;
        }
        if (n == 0) break;
        off += (size_t)n;
    }
    close(fd);
    buf[off] = 0;
    if (out_len != NULL) *out_len = (int64_t)off;
    if (out_err != NULL) *out_err = 0;
    return buf;
}

int32_t sts_write_file_atomic(const char *path, const uint8_t *data, int64_t len, int32_t mode) {
    if (path == NULL || path[0] == '\0' || len < 0) return 0;
    const char *slash = strrchr(path, '/');
    size_t dir_len = slash != NULL ? (size_t)(slash - path) + 1 : 0;
    int enforce_mode = mode >= 0;
    mode_t open_mode = enforce_mode ? (mode_t)(mode & 0777) : (mode_t)0666;

    static const char hx[] = "0123456789abcdef";
    size_t tmp_cap = dir_len + 64;
    char *tmp = (char *)malloc(tmp_cap);
    if (tmp == NULL) return 0;
    int fd = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            free(tmp);
            return 0;
        }
        char hex[17];
        for (int i = 0; i < 8; i++) {
            hex[i * 2] = hx[(rnd[i] >> 4) & 0xF];
            hex[i * 2 + 1] = hx[rnd[i] & 0xF];
        }
        hex[16] = '\0';
        snprintf(tmp, tmp_cap, "%.*s.sf-tmp.%ld.%s", (int)dir_len, path, (long)getpid(), hex);
        fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, open_mode);
        if (fd >= 0) break;
        if (errno != EEXIST) {
            free(tmp);
            return 0;
        }
    }
    if (fd < 0) {
        free(tmp);
        return 0;
    }
    if (enforce_mode && fchmod(fd, open_mode) != 0) {
        close(fd);
        unlink(tmp);
        free(tmp);
        return 0;
    }
    int64_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, (size_t)(len - off));
        if (w < 0) {
            if (errno == EINTR) continue;
            close(fd);
            unlink(tmp);
            free(tmp);
            return 0;
        }
        off += (int64_t)w;
    }
    if (fsync(fd) != 0) {
        close(fd);
        unlink(tmp);
        free(tmp);
        return 0;
    }
    if (close(fd) != 0) {
        unlink(tmp);
        free(tmp);
        return 0;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        free(tmp);
        return 0;
    }
    free(tmp);
    return 1;
}

static int32_t sts_clone_errno_map(int err) {
    if (err == ENOENT || err == ENOTDIR) return -2;
    if (err == EACCES || err == EPERM) return -3;
    if (err == EISDIR) return -4;
    if (err == ELOOP) return -5;
    if (err == EEXIST) return -7;
    return -1;
}

static int sts_copy_fd_stream(int src_fd, int dst_fd) {
    const size_t cap = 256u * 1024u;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        errno = ENOMEM;
        return -1;
    }
    for (;;) {
        ssize_t n = read(src_fd, buf, cap);
        if (n < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            free(buf);
            errno = saved;
            return -1;
        }
        if (n == 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dst_fd, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                int saved = errno;
                free(buf);
                errno = saved;
                return -1;
            }
            off += w;
        }
    }
    free(buf);
    return 0;
}

static void sts_hex16(uint8_t rnd[8], char out[17]) {
    static const char hx[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        out[i * 2] = hx[(rnd[i] >> 4) & 0xF];
        out[i * 2 + 1] = hx[rnd[i] & 0xF];
    }
    out[16] = '\0';
}

int32_t sts_clones_at(const char *dir_path) {
    if (dir_path == NULL || dir_path[0] == '\0') return -1;
#ifdef __APPLE__
    struct statfs sfs;
    if (statfs(dir_path, &sfs) != 0) return -1;
    return strcmp(sfs.f_fstypename, "apfs") == 0 ? 1 : 0;
#elif defined(__linux__)
    uint8_t rnd[8];
    if (!sts_random_bytes(rnd, 8)) return -1;
    char hex[17];
    sts_hex16(rnd, hex);
    size_t dlen = strlen(dir_path);
    size_t cap = dlen + 64;
    char *pa = (char *)malloc(cap);
    char *pb = (char *)malloc(cap);
    if (pa == NULL || pb == NULL) {
        free(pa);
        free(pb);
        return -1;
    }
    const char *sep = (dlen > 0 && dir_path[dlen - 1] == '/') ? "" : "/";
    snprintf(pa, cap, "%s%s.sf-cow-probe.%ld.%s.a", dir_path, sep, (long)getpid(), hex);
    snprintf(pb, cap, "%s%s.sf-cow-probe.%ld.%s.b", dir_path, sep, (long)getpid(), hex);
    int fd_a = open(pa, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd_a < 0) {
        free(pa);
        free(pb);
        return -1;
    }
    if (write(fd_a, "x", 1) != 1) {
        close(fd_a);
        unlink(pa);
        free(pa);
        free(pb);
        return -1;
    }
    int fd_b = open(pb, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd_b < 0) {
        close(fd_a);
        unlink(pa);
        free(pa);
        free(pb);
        return -1;
    }
    int rc = ioctl(fd_b, FICLONE, fd_a);
    int saved = errno;
    close(fd_b);
    close(fd_a);
    unlink(pb);
    unlink(pa);
    free(pa);
    free(pb);
    if (rc == 0) return 1;
    if (saved == EOPNOTSUPP || saved == ENOSYS || saved == EXDEV || saved == EINVAL || saved == ENOTTY) return 0;
    return -1;
#else
    (void)dir_path;
    return 0;
#endif
}

int32_t sts_same_cloneable_volume(const char *dir_a, const char *dir_b) {
    if (dir_a == NULL || dir_a[0] == '\0' || dir_b == NULL || dir_b[0] == '\0') return 0;
    struct stat sa;
    struct stat sb;
    if (stat(dir_a, &sa) != 0 || stat(dir_b, &sb) != 0) return 0;
    if (sa.st_dev != sb.st_dev) return 0;
    return sts_clones_at(dir_b) == 1 ? 1 : 0;
}

int32_t sts_clone_file(const char *src, const char *dst, int32_t excl) {
    if (src == NULL || src[0] == '\0' || dst == NULL || dst[0] == '\0') return -1;
    struct stat sst;
    if (lstat(src, &sst) != 0) return sts_clone_errno_map(errno);
    if (S_ISDIR(sst.st_mode)) return -4;
    if (!S_ISREG(sst.st_mode)) return -5;
    if (excl == 0) {
        struct stat dst_st;
        if (lstat(dst, &dst_st) == 0 && S_ISDIR(dst_st.st_mode)) return -4;
    }
    mode_t fmode = sst.st_mode & 0777;
    const char *slash = strrchr(dst, '/');
    size_t dir_len = slash != NULL ? (size_t)(slash - dst) + 1 : 0;

#ifdef __APPLE__
    if (excl != 0) {
        if (clonefile(src, dst, CLONE_NOFOLLOW) == 0) {
            (void)utimes(dst, NULL);
            return 1;
        }
        int ce = errno;
        if (ce == EEXIST) return -7;
        if (ce != EXDEV && ce != ENOTSUP && ce != EINVAL && ce != EOPNOTSUPP) {
            return sts_clone_errno_map(ce);
        }
        int src_fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (src_fd < 0) return sts_clone_errno_map(errno);
        struct stat fst;
        if (fstat(src_fd, &fst) != 0 || !S_ISREG(fst.st_mode)) {
            close(src_fd);
            return -5;
        }
        int dst_fd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fmode);
        if (dst_fd < 0) {
            int de = errno;
            close(src_fd);
            return sts_clone_errno_map(de);
        }
        (void)fchmod(dst_fd, fmode);
        if (sts_copy_fd_stream(src_fd, dst_fd) != 0) {
            int se = errno;
            close(dst_fd);
            close(src_fd);
            unlink(dst);
            return sts_clone_errno_map(se);
        }
        if (close(dst_fd) != 0) {
            int se = errno;
            close(src_fd);
            unlink(dst);
            return sts_clone_errno_map(se);
        }
        close(src_fd);
        return 2;
    }

    size_t tmp_cap = dir_len + 64;
    char *tmp = (char *)malloc(tmp_cap);
    if (tmp == NULL) return -1;
    int cloned = 0;
    int fallback_copy = 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            free(tmp);
            return -1;
        }
        char hex[17];
        sts_hex16(rnd, hex);
        snprintf(tmp, tmp_cap, "%.*s.sf-clone.%ld.%s", (int)dir_len, dst, (long)getpid(), hex);
        if (clonefile(src, tmp, CLONE_NOFOLLOW) == 0) {
            cloned = 1;
            break;
        }
        int ce = errno;
        if (ce == EEXIST) continue;
        if (ce == EXDEV || ce == ENOTSUP || ce == EINVAL || ce == EOPNOTSUPP) {
            fallback_copy = 1;
            break;
        }
        free(tmp);
        return sts_clone_errno_map(ce);
    }
    if (cloned) {
        (void)utimes(tmp, NULL);
        if (rename(tmp, dst) != 0) {
            int re = errno;
            unlink(tmp);
            free(tmp);
            return sts_clone_errno_map(re);
        }
        free(tmp);
        return 1;
    }
    if (!fallback_copy) {
        free(tmp);
        return -1;
    }
    int src_fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (src_fd < 0) {
        free(tmp);
        return sts_clone_errno_map(errno);
    }
    struct stat fst;
    if (fstat(src_fd, &fst) != 0 || !S_ISREG(fst.st_mode)) {
        close(src_fd);
        free(tmp);
        return -5;
    }
    int dst_fd = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            close(src_fd);
            free(tmp);
            return -1;
        }
        char hex[17];
        sts_hex16(rnd, hex);
        snprintf(tmp, tmp_cap, "%.*s.sf-clone.%ld.%s", (int)dir_len, dst, (long)getpid(), hex);
        dst_fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fmode);
        if (dst_fd >= 0) break;
        if (errno != EEXIST) {
            int de = errno;
            close(src_fd);
            free(tmp);
            return sts_clone_errno_map(de);
        }
    }
    if (dst_fd < 0) {
        close(src_fd);
        free(tmp);
        return -1;
    }
    (void)fchmod(dst_fd, fmode);
    if (sts_copy_fd_stream(src_fd, dst_fd) != 0) {
        int se = errno;
        close(dst_fd);
        close(src_fd);
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(se);
    }
    if (close(dst_fd) != 0) {
        int se = errno;
        close(src_fd);
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(se);
    }
    close(src_fd);
    if (rename(tmp, dst) != 0) {
        int re = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(re);
    }
    free(tmp);
    return 2;
#else
    int src_fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (src_fd < 0) return sts_clone_errno_map(errno);
    struct stat fst;
    if (fstat(src_fd, &fst) != 0 || !S_ISREG(fst.st_mode)) {
        close(src_fd);
        return -5;
    }
    if (excl != 0) {
        int dst_fd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fmode);
        if (dst_fd < 0) {
            int de = errno;
            close(src_fd);
            return sts_clone_errno_map(de);
        }
        (void)fchmod(dst_fd, fmode);
        int32_t kind = 2;
#ifdef __linux__
        if (ioctl(dst_fd, FICLONE, src_fd) == 0) {
            kind = 1;
        } else
#endif
        {
            if (sts_copy_fd_stream(src_fd, dst_fd) != 0) {
                int se = errno;
                close(dst_fd);
                close(src_fd);
                unlink(dst);
                return sts_clone_errno_map(se);
            }
        }
        if (close(dst_fd) != 0) {
            int se = errno;
            close(src_fd);
            unlink(dst);
            return sts_clone_errno_map(se);
        }
        close(src_fd);
        return kind;
    }

    size_t tmp_cap = dir_len + 64;
    char *tmp = (char *)malloc(tmp_cap);
    if (tmp == NULL) {
        close(src_fd);
        return -1;
    }
    int dst_fd = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            close(src_fd);
            free(tmp);
            return -1;
        }
        char hex[17];
        sts_hex16(rnd, hex);
        snprintf(tmp, tmp_cap, "%.*s.sf-clone.%ld.%s", (int)dir_len, dst, (long)getpid(), hex);
        dst_fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fmode);
        if (dst_fd >= 0) break;
        if (errno != EEXIST) {
            int de = errno;
            close(src_fd);
            free(tmp);
            return sts_clone_errno_map(de);
        }
    }
    if (dst_fd < 0) {
        close(src_fd);
        free(tmp);
        return -1;
    }
    (void)fchmod(dst_fd, fmode);
    int32_t kind = 2;
#ifdef __linux__
    if (ioctl(dst_fd, FICLONE, src_fd) == 0) {
        kind = 1;
    } else
#endif
    {
        if (sts_copy_fd_stream(src_fd, dst_fd) != 0) {
            int se = errno;
            close(dst_fd);
            close(src_fd);
            unlink(tmp);
            free(tmp);
            return sts_clone_errno_map(se);
        }
    }
    if (close(dst_fd) != 0) {
        int se = errno;
        close(src_fd);
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(se);
    }
    close(src_fd);
    if (rename(tmp, dst) != 0) {
        int re = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(re);
    }
    free(tmp);
    return kind;
#endif
}

int32_t sts_clone_file_only(const char *src, const char *dst, int32_t excl) {
    if (src == NULL || src[0] == '\0' || dst == NULL || dst[0] == '\0') return -1;
    struct stat sst;
    if (lstat(src, &sst) != 0) return sts_clone_errno_map(errno);
    if (S_ISDIR(sst.st_mode)) return -4;
    if (!S_ISREG(sst.st_mode)) return -5;
    if (excl == 0) {
        struct stat dst_st;
        if (lstat(dst, &dst_st) == 0 && S_ISDIR(dst_st.st_mode)) return -4;
    }
    const char *slash = strrchr(dst, '/');
    size_t dir_len = slash != NULL ? (size_t)(slash - dst) + 1 : 0;

#ifdef __APPLE__
    size_t tmp_cap = dir_len + 64;
    char *tmp = (char *)malloc(tmp_cap);
    if (tmp == NULL) return -1;
    int cloned = 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            free(tmp);
            return -1;
        }
        char hex[17];
        sts_hex16(rnd, hex);
        snprintf(tmp, tmp_cap, "%.*s.sf-clone.%ld.%s", (int)dir_len, dst, (long)getpid(), hex);
        if (clonefile(src, tmp, CLONE_NOFOLLOW) == 0) {
            cloned = 1;
            break;
        }
        int ce = errno;
        if (ce == EEXIST) continue;
        free(tmp);
        if (ce == EXDEV || ce == ENOTSUP || ce == EINVAL || ce == EOPNOTSUPP || ce == ENOSYS) return -8;
        return sts_clone_errno_map(ce);
    }
    if (!cloned) {
        free(tmp);
        return -1;
    }
    if (utimes(tmp, NULL) != 0) {
        int ue = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(ue);
    }
    int sync_fd = sts_posix_open_retry(tmp, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0);
    if (sync_fd < 0 && (errno == EACCES || errno == EROFS)) {
        sync_fd = sts_posix_open_retry(tmp, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0);
    }
    if (sync_fd < 0) {
        int oe = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(oe);
    }
    int frc;
    do {
        frc = fsync(sync_fd);
    } while (frc < 0 && errno == EINTR);
    if (frc != 0) {
        int fe = errno;
        close(sync_fd);
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(fe);
    }
    if (close(sync_fd) != 0) {
        int ce = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(ce);
    }
    if (excl != 0) {
        int lrc = link(tmp, dst);
        int le = lrc == 0 ? 0 : errno;
        unlink(tmp);
        free(tmp);
        if (lrc != 0) return sts_clone_errno_map(le);
        return 1;
    }
    if (rename(tmp, dst) != 0) {
        int re = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(re);
    }
    free(tmp);
    return 1;
#elif defined(__linux__)
    mode_t fmode = sst.st_mode & 0777;
    int src_fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (src_fd < 0) return sts_clone_errno_map(errno);
    struct stat fst;
    if (fstat(src_fd, &fst) != 0 || !S_ISREG(fst.st_mode)) {
        close(src_fd);
        return -5;
    }
    size_t tmp_cap = dir_len + 64;
    char *tmp = (char *)malloc(tmp_cap);
    if (tmp == NULL) {
        close(src_fd);
        return -1;
    }
    int tmp_fd = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t rnd[8];
        if (!sts_random_bytes(rnd, 8)) {
            close(src_fd);
            free(tmp);
            return -1;
        }
        char hex[17];
        sts_hex16(rnd, hex);
        snprintf(tmp, tmp_cap, "%.*s.sf-clone.%ld.%s", (int)dir_len, dst, (long)getpid(), hex);
        tmp_fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fmode);
        if (tmp_fd >= 0) break;
        if (errno != EEXIST) {
            int de = errno;
            close(src_fd);
            free(tmp);
            return sts_clone_errno_map(de);
        }
    }
    if (tmp_fd < 0) {
        close(src_fd);
        free(tmp);
        return -1;
    }
    if (ioctl(tmp_fd, FICLONE, src_fd) != 0) {
        int ie = errno;
        close(tmp_fd);
        unlink(tmp);
        close(src_fd);
        free(tmp);
        if (ie == EXDEV || ie == EOPNOTSUPP || ie == ENOTSUP || ie == EINVAL || ie == ENOSYS || ie == ENOTTY || ie == EPERM) {
            return -8;
        }
        return sts_clone_errno_map(ie);
    }
    if (fchmod(tmp_fd, fmode) != 0) {
        int me = errno;
        close(tmp_fd);
        unlink(tmp);
        close(src_fd);
        free(tmp);
        return sts_clone_errno_map(me);
    }
    if (fsync(tmp_fd) != 0) {
        int fe = errno;
        close(tmp_fd);
        unlink(tmp);
        close(src_fd);
        free(tmp);
        return sts_clone_errno_map(fe);
    }
    if (close(tmp_fd) != 0) {
        int ce = errno;
        unlink(tmp);
        close(src_fd);
        free(tmp);
        return sts_clone_errno_map(ce);
    }
    close(src_fd);
    if (excl != 0) {
        int lrc = link(tmp, dst);
        int le = lrc == 0 ? 0 : errno;
        unlink(tmp);
        free(tmp);
        if (lrc != 0) return sts_clone_errno_map(le);
        return 1;
    }
    if (rename(tmp, dst) != 0) {
        int re = errno;
        unlink(tmp);
        free(tmp);
        return sts_clone_errno_map(re);
    }
    free(tmp);
    return 1;
#else
    (void)dir_len;
    return -8;
#endif
}

#ifdef __linux__
static int32_t sts_clone_tree_linux_rec(const char *src_dir, const char *dst_dir, int depth) {
    if (depth > 128) return -1;
    DIR *d = opendir(src_dir);
    if (d == NULL) return sts_clone_errno_map(errno);
    size_t slen = strlen(src_dir);
    size_t dlen = strlen(dst_dir);
    const char *ssep = (slen > 0 && src_dir[slen - 1] == '/') ? "" : "/";
    const char *dsep = (dlen > 0 && dst_dir[dlen - 1] == '/') ? "" : "/";
    struct dirent *ent;
    for (;;) {
        errno = 0;
        ent = readdir(d);
        if (ent == NULL) {
            if (errno != 0) {
                int re = errno;
                closedir(d);
                return sts_clone_errno_map(re);
            }
            break;
        }
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        size_t nlen = strlen(ent->d_name);
        char *sp = (char *)malloc(slen + nlen + 2);
        char *dp = (char *)malloc(dlen + nlen + 2);
        if (sp == NULL || dp == NULL) {
            free(sp);
            free(dp);
            closedir(d);
            return -1;
        }
        snprintf(sp, slen + nlen + 2, "%s%s%s", src_dir, ssep, ent->d_name);
        snprintf(dp, dlen + nlen + 2, "%s%s%s", dst_dir, dsep, ent->d_name);
        struct stat st;
        if (lstat(sp, &st) != 0) {
            int e = errno;
            free(sp);
            free(dp);
            closedir(d);
            return sts_clone_errno_map(e);
        }
        struct timespec ts[2];
        ts[0] = st.st_atim;
        ts[1] = st.st_mtim;
        if (S_ISLNK(st.st_mode)) {
            size_t lcap = st.st_size > 0 ? (size_t)st.st_size + 1 : 4096;
            char *target = (char *)malloc(lcap);
            if (target == NULL) {
                free(sp);
                free(dp);
                closedir(d);
                return -1;
            }
            ssize_t rlen = readlink(sp, target, lcap - 1);
            if (rlen < 0) {
                int e = errno;
                free(target);
                free(sp);
                free(dp);
                closedir(d);
                return sts_clone_errno_map(e);
            }
            target[rlen] = '\0';
            if (symlink(target, dp) != 0) {
                int e = errno;
                free(target);
                free(sp);
                free(dp);
                closedir(d);
                return sts_clone_errno_map(e);
            }
            (void)utimensat(AT_FDCWD, dp, ts, AT_SYMLINK_NOFOLLOW);
            free(target);
        } else if (S_ISDIR(st.st_mode)) {
            mode_t orig_mode = st.st_mode & 0777;
            if (mkdir(dp, orig_mode | 0700) != 0) {
                if (errno != EEXIST) {
                    int e = errno;
                    free(sp);
                    free(dp);
                    closedir(d);
                    return sts_clone_errno_map(e);
                }
                struct stat est;
                if (lstat(dp, &est) != 0 || !S_ISDIR(est.st_mode)) {
                    free(sp);
                    free(dp);
                    closedir(d);
                    return -7;
                }
                (void)chmod(dp, orig_mode | 0700);
            }
            int32_t sub_rc = sts_clone_tree_linux_rec(sp, dp, depth + 1);
            if (sub_rc != 1) {
                free(sp);
                free(dp);
                closedir(d);
                return sub_rc;
            }
            (void)chmod(dp, orig_mode);
            (void)utimensat(AT_FDCWD, dp, ts, 0);
        } else if (S_ISREG(st.st_mode)) {
            mode_t orig_mode = st.st_mode & 0777;
            int sfd = open(sp, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (sfd < 0) {
                int e = errno;
                free(sp);
                free(dp);
                closedir(d);
                return sts_clone_errno_map(e);
            }
            int dfd = open(dp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, orig_mode);
            if (dfd < 0) {
                int e = errno;
                close(sfd);
                free(sp);
                free(dp);
                closedir(d);
                return sts_clone_errno_map(e);
            }
            if (ioctl(dfd, FICLONE, sfd) != 0) {
                close(dfd);
                close(sfd);
                unlink(dp);
                free(sp);
                free(dp);
                closedir(d);
                return -8;
            }
            (void)fchmod(dfd, orig_mode);
            (void)futimens(dfd, ts);
            close(dfd);
            close(sfd);
        } else {
            free(sp);
            free(dp);
            closedir(d);
            return -5;
        }
        free(sp);
        free(dp);
    }
    closedir(d);
    return 1;
}
#endif

static char *sts_nearest_existing_ancestor_dup(const char *path) {
    char *cur = strdup(path);
    if (cur == NULL) return NULL;
    for (;;) {
        size_t len = strlen(cur);
        while (len > 1 && cur[len - 1] == '/') cur[--len] = '\0';
        struct stat st;
        if (stat(cur, &st) == 0) return cur;
        char *slash = strrchr(cur, '/');
        if (slash == NULL) {
            free(cur);
            char *dot = strdup(".");
            if (dot != NULL && stat(dot, &st) == 0) return dot;
            free(dot);
            return NULL;
        }
        if (slash == cur) {
            if (cur[1] == '\0') {
                free(cur);
                return NULL;
            }
            cur[1] = '\0';
        } else {
            *slash = '\0';
        }
    }
}

int32_t sts_clone_tree(const char *src_dir, const char *dst_dir) {
    if (src_dir == NULL || src_dir[0] == '\0' || dst_dir == NULL || dst_dir[0] == '\0') return -1;
    char *ancestor = sts_nearest_existing_ancestor_dup(dst_dir);
    if (ancestor == NULL) return -8;
    int32_t same = sts_same_cloneable_volume(src_dir, ancestor);
    free(ancestor);
    if (same != 1) return -8;
    if (!sts_mkdir_p(dst_dir)) return -1;
#ifdef __APPLE__
    DIR *d = opendir(src_dir);
    if (d == NULL) return sts_clone_errno_map(errno);
    size_t slen = strlen(src_dir);
    size_t dst_len = strlen(dst_dir);
    const char *ssep = (slen > 0 && src_dir[slen - 1] == '/') ? "" : "/";
    const char *dsep = (dst_len > 0 && dst_dir[dst_len - 1] == '/') ? "" : "/";
    struct dirent *ent;
    for (;;) {
        errno = 0;
        ent = readdir(d);
        if (ent == NULL) {
            if (errno != 0) {
                int re = errno;
                closedir(d);
                return sts_clone_errno_map(re);
            }
            break;
        }
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        size_t nlen = strlen(ent->d_name);
        char *sp = (char *)malloc(slen + nlen + 2);
        char *dp = (char *)malloc(dst_len + nlen + 2);
        if (sp == NULL || dp == NULL) {
            free(sp);
            free(dp);
            closedir(d);
            return -1;
        }
        snprintf(sp, slen + nlen + 2, "%s%s%s", src_dir, ssep, ent->d_name);
        snprintf(dp, dst_len + nlen + 2, "%s%s%s", dst_dir, dsep, ent->d_name);
        if (clonefile(sp, dp, CLONE_NOFOLLOW) != 0) {
            int ce = errno;
            free(sp);
            free(dp);
            closedir(d);
            if (ce == EXDEV || ce == ENOTSUP || ce == EOPNOTSUPP) return -8;
            return sts_clone_errno_map(ce);
        }
        free(sp);
        free(dp);
    }
    closedir(d);
    return 1;
#elif defined(__linux__)
    return sts_clone_tree_linux_rec(src_dir, dst_dir, 0);
#else
    return -8;
#endif
}

// ---------------------------------------------------------------------------
// 6. POSIX Unix Peer Process Identity (aligned with local.rs:199-228)
// ---------------------------------------------------------------------------

void *sts_peer_process(int32_t fd, int64_t *out_len) {
    if (fd < 0) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
#if defined(__APPLE__)
    pid_t pid = 0;
    socklen_t len = sizeof(pid);
    if (getsockopt((int)fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 || pid <= 0) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    uint8_t token[32];
    len = sizeof(token);
    int has_tok = (getsockopt((int)fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &len) == 0 && len == sizeof(token));
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{\"pid\":");
    sb_fmt_i64(&b, (long long)pid);
    sb_str(&b, ",\"auditToken\":");
    if (has_tok) {
        char hex[65];
        for (int i = 0; i < 32; i++) {
            snprintf(hex + 2 * i, 3, "%02x", (unsigned)token[i]);
        }
        sb_json_str(&b, hex);
    } else {
        sb_str(&b, "null");
    }
    sb_str(&b, "}");
    return sb_finish(&b, out_len);
#elif defined(__linux__)
    struct ucred cred;
    memset(&cred, 0, sizeof(cred));
    socklen_t len = sizeof(cred);
    if (getsockopt((int)fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0 || cred.pid <= 0) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{\"pid\":");
    sb_fmt_i64(&b, (long long)cred.pid);
    sb_str(&b, ",\"auditToken\":null}");
    return sb_finish(&b, out_len);
#else
    (void)fd;
    if (out_len != NULL) *out_len = 0;
    return NULL;
#endif
}

// ---------------------------------------------------------------------------
// 7. POSIX Process Resource Usage (aligned with usage.rs)
// ---------------------------------------------------------------------------

void *sts_process_usage(const int32_t *pids, int32_t count, int64_t *out_len) {
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "[");
    for (int32_t i = 0; i < count; i++) {
        if (i > 0) sb_str(&b, ",");
        int32_t pid = pids != NULL ? pids[i] : 0;
        if (pid <= 0) {
            sb_str(&b, "null");
            continue;
        }
#if defined(__APPLE__)
        struct rusage_info_v6 info;
        memset(&info, 0, sizeof(info));
        if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&info) != 0) {
            sb_str(&b, "null");
            continue;
        }
        mach_timebase_info_data_t base = { 1, 1 };
        mach_timebase_info(&base);
        double ticks = (double)(info.ri_user_time + info.ri_system_time);
        double cpu_ns = ticks * (double)base.numer / (double)(base.denom ? base.denom : 1);
        sb_str(&b, "{\"cpuNs\":");
        sb_fmt_f64(&b, "%.0f", cpu_ns);
        sb_str(&b, ",\"footprint\":");
        sb_fmt_u64(&b, (unsigned long long)info.ri_phys_footprint);
        sb_str(&b, ",\"wakeups\":");
        sb_fmt_u64(&b, (unsigned long long)info.ri_interrupt_wkups);
        sb_str(&b, ",\"energyNj\":");
        sb_fmt_u64(&b, (unsigned long long)info.ri_energy_nj);
        sb_str(&b, ",\"diskRead\":");
        sb_fmt_u64(&b, (unsigned long long)info.ri_diskio_bytesread);
        sb_str(&b, ",\"diskWritten\":");
        sb_fmt_u64(&b, (unsigned long long)info.ri_diskio_byteswritten);
        sb_str(&b, "}");
#elif defined(__linux__)
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        FILE *f = fopen(path, "r");
        if (f == NULL) {
            sb_str(&b, "null");
            continue;
        }
        char buf[4096];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        if (n == 0) {
            sb_str(&b, "null");
            continue;
        }
        buf[n] = '\0';
        char *rp = strrchr(buf, ')');
        if (rp == NULL || rp[1] != ' ') {
            sb_str(&b, "null");
            continue;
        }
        const char *p = rp + 2;
        unsigned long long utime = 0, stime = 0;
        int field = 3;
        while (*p != '\0') {
            while (*p == ' ') p++;
            if (*p == '\0') break;
            if (field == 14) utime = strtoull(p, NULL, 10);
            else if (field == 15) {
                stime = strtoull(p, NULL, 10);
                break;
            }
            while (*p != '\0' && *p != ' ') p++;
            field += 1;
        }
        long clk = sysconf(_SC_CLK_TCK);
        if (clk <= 0) clk = 100;
        unsigned long long cpu_ns = ((utime + stime) * 1000000000ULL) / (unsigned long long)clk;

        unsigned long long footprint = 0;
        snprintf(path, sizeof(path), "/proc/%d/statm", (int)pid);
        FILE *mf = fopen(path, "r");
        if (mf != NULL) {
            unsigned long sz = 0, res = 0;
            if (fscanf(mf, "%lu %lu", &sz, &res) == 2) {
                long ps = sysconf(_SC_PAGESIZE);
                if (ps <= 0) ps = 4096;
                footprint = (unsigned long long)res * (unsigned long long)ps;
            }
            fclose(mf);
        }

        unsigned long long disk_r = 0, disk_w = 0;
        snprintf(path, sizeof(path), "/proc/%d/io", (int)pid);
        FILE *iof = fopen(path, "r");
        if (iof != NULL) {
            char line[256];
            while (fgets(line, sizeof(line), iof) != NULL) {
                if (strncmp(line, "read_bytes:", 11) == 0) {
                    disk_r = strtoull(line + 11, NULL, 10);
                } else if (strncmp(line, "write_bytes:", 12) == 0) {
                    disk_w = strtoull(line + 12, NULL, 10);
                }
            }
            fclose(iof);
        }

        sb_str(&b, "{\"cpuNs\":");
        sb_fmt_u64(&b, cpu_ns);
        sb_str(&b, ",\"footprint\":");
        sb_fmt_u64(&b, footprint);
        sb_str(&b, ",\"wakeups\":0,\"energyNj\":0,\"diskRead\":");
        sb_fmt_u64(&b, disk_r);
        sb_str(&b, ",\"diskWritten\":");
        sb_fmt_u64(&b, disk_w);
        sb_str(&b, "}");
#else
        sb_str(&b, "null");
#endif
    }
    sb_str(&b, "]");
    return sb_finish(&b, out_len);
}

// ---------------------------------------------------------------------------
// 8. POSIX PTY (openpty + TIOCSWINSZ)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    pid_t pid;
    _Atomic int closing;
    pthread_mutex_t kill_lock;
    int exited;
    int kill_revoked;
    int master_fd;
    int read_wake[2];
    pthread_mutex_t write_lock;
    pthread_mutex_t ref_lock;
    int refs;
} posix_pty_t;

static void posix_pty_ref(posix_pty_t *pt) {
    pthread_mutex_lock(&pt->ref_lock);
    pt->refs += 1;
    pthread_mutex_unlock(&pt->ref_lock);
}

static void posix_pty_unref(posix_pty_t *pt) {
    pthread_mutex_lock(&pt->ref_lock);
    int last = (--pt->refs == 0);
    pthread_mutex_unlock(&pt->ref_lock);
    if (!last) return;
    if (pt->master_fd >= 0) close(pt->master_fd);
    close_fd_pair(pt->read_wake);
    pthread_mutex_destroy(&pt->kill_lock);
    pthread_mutex_destroy(&pt->write_lock);
    pthread_mutex_destroy(&pt->ref_lock);
    free(pt);
}

static posix_pty_t *posix_pty_get(int64_t handle) {
    if (handle <= 0) return NULL;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    posix_pty_t *pt = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_PTY) {
            pt = (posix_pty_t *)cur->ptr;
            pthread_mutex_lock(&pt->ref_lock);
            pt->refs += 1;
            pthread_mutex_unlock(&pt->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    return pt;
}

static void *posix_pty_read_thread(void *arg) {
    posix_pty_t *pt = (posix_pty_t *)arg;
    int mfd = pt->master_fd;
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    if (buf != NULL && mfd >= 0) {
        buf[0] = STS_EV_PTY_DATA;
        struct pollfd pfds[2];
        pfds[0].fd = mfd;
        pfds[0].events = POLLIN;
        pfds[1].fd = pt->read_wake[0];
        pfds[1].events = POLLIN;

        for (;;) {
            if (atomic_load_explicit(&pt->closing, memory_order_acquire)) break;
            pfds[0].revents = 0;
            pfds[1].revents = 0;
            int rc = poll(pfds, 2, -1);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0 || pfds[1].revents != 0) break;
            if (pfds[0].revents != 0) {
                ssize_t got = read(mfd, buf + 1, 65536);
                if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                if (got <= 0) {
                    if (!atomic_load_explicit(&pt->closing, memory_order_acquire)) {
                        push_tag_ctrl(pt->event_id, STS_EV_PTY_EOF, NULL, 0);
                    }
                    break;
                }
                push_sys_bounded_tracked(pt->event_id, buf, (size_t)got + 1);
                if (atomic_load_explicit(&pt->closing, memory_order_acquire)) break;
            }
        }
    }
    free(buf);
    // Close master_fd immediately on reader exit (not deferred to last unref) so an
    // interactive child waiting on the terminal receives SIGHUP and exits promptly.
    pthread_mutex_lock(&pt->write_lock);
    if (pt->master_fd >= 0) {
        close(pt->master_fd);
        pt->master_fd = -1;
    }
    pthread_mutex_unlock(&pt->write_lock);
    posix_pty_unref(pt);
    sts_detached_end();
    return NULL;
}

static void *posix_pty_wait_thread(void *arg) {
    posix_pty_t *pt = (posix_pty_t *)arg;
    int wid = posix_wait_exited_nowait(pt->pid);

    int status = 0;
    pid_t wr = -1;
    if (wid == 0) {
        pthread_mutex_lock(&pt->kill_lock);
        pt->exited = 1;
        do {
            wr = waitpid(pt->pid, &status, WNOHANG);
        } while (wr < 0 && errno == EINTR);
        pthread_mutex_unlock(&pt->kill_lock);
        if (wr == 0) {
            do {
                wr = waitpid(pt->pid, &status, 0);
            } while (wr < 0 && errno == EINTR);
        }
    } else {
        // waitid failed (non-EINTR): revoke handle-based kill permission BEFORE reaping
        // so there is zero PID-reuse window, then block in waitpid without holding kill_lock.
        pthread_mutex_lock(&pt->kill_lock);
        pt->kill_revoked = 1;
        pthread_mutex_unlock(&pt->kill_lock);
        do {
            wr = waitpid(pt->pid, &status, 0);
        } while (wr < 0 && errno == EINTR);
        pthread_mutex_lock(&pt->kill_lock);
        pt->exited = 1;
        pthread_mutex_unlock(&pt->kill_lock);
    }

    pthread_mutex_lock(&pt->kill_lock);
    if (wr == pt->pid && !atomic_load_explicit(&pt->closing, memory_order_acquire)) {
        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            push_exit_event(pt->event_id, STS_EV_PTY_EXIT, -1, (int32_t)sig, posix_signal_name(sig));
        } else {
            push_exit_event(pt->event_id, STS_EV_PTY_EXIT, (int32_t)WEXITSTATUS(status), 0, "");
        }
    }
    pthread_mutex_unlock(&pt->kill_lock);
    posix_pty_unref(pt);
    sts_reaper_end();
    return NULL;
}

int64_t sts_pty_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    int32_t cols,
    int32_t rows,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap) {
    if (program == NULL || program[0] == '\0') {
        copy_err(err_buf, err_cap, "empty program");
        return -1;
    }
    ensure_sigpipe_ignored();
    const char *dir = (cwd != NULL && cwd[0] != '\0') ? cwd : NULL;
    char **argv = build_argv(program, args_nul, args_len);
    int env_ok = 1;
    char **envp = build_envp(
        env_nul,
        env_len,
        (flags & STS_PROC_STRIP_MALLOC_SE) != 0,
        (flags & STS_PROC_EXPLICIT_ENV) != 0,
        &env_ok);
    if (argv == NULL || !env_ok) {
        free_str_vec(argv);
        free_str_vec(envp);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    int resolve_err = 0;
    char *exec_path = resolve_program_for_cwd(program, envp, dir, &resolve_err);
    if (exec_path == NULL) {
        free_str_vec(argv);
        free_str_vec(envp);
        char msg[256];
        posix_err_str(resolve_err ? resolve_err : ENOENT, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);

    int master_fd = -1, slave_fd = -1;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) != 0) {
        int e = errno;
        free(exec_path);
        free_str_vec(argv);
        free_str_vec(envp);
        char msg[256];
        posix_err_str(e, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    fcntl(master_fd, F_SETFD, FD_CLOEXEC);
    fcntl(slave_fd, F_SETFD, FD_CLOEXEC);

    int rep_p[2] = { -1, -1 };
    int fail = 0;
    if (cloexec_pipe(rep_p) != 0) fail = errno;

    int max_fd_hint = posix_max_open_fd_hint();
    pid_t pid = -1;
    if (!fail) pid = fork();
    if (pid == 0) {
        if (relocate_fd_above_2(&rep_p[1]) != 0 ||
            relocate_fd_above_2(&slave_fd) != 0 ||
            relocate_fd_above_2(&master_fd) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        if (setsid() < 0 || ioctl(slave_fd, TIOCSCTTY, 0) < 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        if (child_dup2_stdio(slave_fd, 0) != 0 ||
            child_dup2_stdio(slave_fd, 1) != 0 ||
            child_dup2_stdio(slave_fd, 2) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        close(master_fd);
        close(slave_fd);
        set_cloexec_from(3, max_fd_hint);
        reset_child_signals();
        if (dir != NULL && chdir(dir) != 0) {
            int e = errno;
            if (write(rep_p[1], &e, sizeof(e)) < 0) {}
            _exit(127);
        }
        if (envp != NULL) execve(exec_path, argv, envp);
        else execv(exec_path, argv);
        int e = errno;
        if (write(rep_p[1], &e, sizeof(e)) < 0) {}
        _exit(127);
    }

    if (pid < 0 && !fail) fail = errno;
    close(slave_fd);
    if (rep_p[1] >= 0) close(rep_p[1]);
    if (!fail) {
        int e = 0;
        ssize_t n;
        do {
            n = read(rep_p[0], &e, sizeof(e));
        } while (n < 0 && errno == EINTR);
        if (n == (ssize_t)sizeof(e)) {
            fail = e;
            int st = 0;
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        }
    }
    if (rep_p[0] >= 0) close(rep_p[0]);
    free(exec_path);
    free_str_vec(argv);
    free_str_vec(envp);

    if (fail != 0) {
        close(master_fd);
        char msg[256];
        posix_err_str(fail, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }

    int fl = fcntl(master_fd, F_GETFL, 0);
    if (fl >= 0) fcntl(master_fd, F_SETFL, fl | O_NONBLOCK);

    posix_pty_t *pt = (posix_pty_t *)calloc(1, sizeof(*pt));
    if (pt == NULL) {
        kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(master_fd);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    pt->event_id = event_id;
    pt->pid = pid;
    atomic_store_explicit(&pt->closing, 0, memory_order_relaxed);
    pt->master_fd = master_fd;
    pt->read_wake[0] = pt->read_wake[1] = -1;
    pthread_mutex_init(&pt->kill_lock, NULL);
    pthread_mutex_init(&pt->write_lock, NULL);
    pthread_mutex_init(&pt->ref_lock, NULL);
    pt->refs = 1;

    int workers_ok = (make_wakeup_pipe(pt->read_wake) == 0);
    if (workers_ok) {
        posix_pty_ref(pt);
        if (!spawn_detached_thread(posix_pty_read_thread, pt)) {
            posix_pty_unref(pt);
            workers_ok = 0;
        }
    }
    int64_t id = workers_ok ? ht_insert(STS_HK_PTY, pt) : -1;
    if (id >= 0) {
        posix_pty_ref(pt);
        if (!spawn_reaper_thread(posix_pty_wait_thread, pt)) {
            posix_pty_unref(pt);
            ht_take(STS_HK_PTY, id);
            id = -1;
        }
    }
    if (id < 0) {
        pthread_mutex_lock(&pt->kill_lock);
        atomic_store_explicit(&pt->closing, 1, memory_order_release);
        pthread_mutex_unlock(&pt->kill_lock);
        kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        wake_pipe_signal(pt->read_wake[1]);
        posix_pty_unref(pt);
        copy_err(err_buf, err_cap, "worker spawn failed");
        return -1;
    }
    if (out_pid != NULL) {
        *out_pid = (int64_t)pid;
    }
    return id;
}

int32_t sts_pty_write(int64_t handle, const uint8_t *data, int64_t len) {
    if (len < 0) return 0;
    if (len == 0) return 1;
    if (data == NULL) return 0;
    ensure_sigpipe_ignored();
    posix_pty_t *pt = posix_pty_get(handle);
    if (pt == NULL) return 0;
    pthread_mutex_lock(&pt->write_lock);
    if (pt->master_fd < 0) {
        pthread_mutex_unlock(&pt->write_lock);
        posix_pty_unref(pt);
        return 0;
    }
    size_t done = 0;
    int ok = 1;
    while (done < (size_t)len) {
        ssize_t n = write(pt->master_fd, data + done, (size_t)len - done);
        if (n > 0) {
            done += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd;
            pfd.fd = pt->master_fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            if (poll(&pfd, 1, 5000) <= 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                ok = 0;
                break;
            }
            continue;
        }
        ok = 0;
        break;
    }
    pthread_mutex_unlock(&pt->write_lock);
    posix_pty_unref(pt);
    return ok;
}

int32_t sts_pty_resize(int64_t handle, int32_t cols, int32_t rows) {
    posix_pty_t *pt = posix_pty_get(handle);
    if (pt == NULL) return 0;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    pthread_mutex_lock(&pt->write_lock);
    int rc = (pt->master_fd >= 0) ? ioctl(pt->master_fd, TIOCSWINSZ, &ws) : -1;
    pthread_mutex_unlock(&pt->write_lock);
    posix_pty_unref(pt);
    return rc == 0 ? 1 : 0;
}

int32_t sts_pty_kill(int64_t handle, int32_t sig) {
    posix_pty_t *pt = posix_pty_get(handle);
    if (pt == NULL) return -ESRCH;
    pthread_mutex_lock(&pt->kill_lock);
    int32_t res;
    if (pt->exited) {
        res = -ESRCH;
    } else if (pt->kill_revoked) {
        res = -ENOTSUP;
    } else {
        res = (kill(-pt->pid, posix_signal_of(sig)) == 0) ? 1 : -errno;
    }
    pthread_mutex_unlock(&pt->kill_lock);
    posix_pty_unref(pt);
    return res;
}

int32_t sts_pty_close(int64_t handle) {
    posix_pty_t *pt = (posix_pty_t *)ht_take(STS_HK_PTY, handle);
    if (pt == NULL) return 0;
    pthread_mutex_lock(&pt->kill_lock);
    atomic_store_explicit(&pt->closing, 1, memory_order_release);
    pthread_mutex_unlock(&pt->kill_lock);
    wake_pipe_signal(pt->read_wake[1]);
    posix_pty_unref(pt);
    return 1;
}

// ---------------------------------------------------------------------------
// 9. POSIX Minimal UDP dgram (for mesh/lan.ts)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t event_id;
    int sock;
    int family;
    int wake[2];
    _Atomic int closing;
    pthread_mutex_t ref_lock;
    int refs;
} posix_udp_t;

static void posix_udp_ref(posix_udp_t *u) {
    pthread_mutex_lock(&u->ref_lock);
    u->refs += 1;
    pthread_mutex_unlock(&u->ref_lock);
}

static void posix_udp_unref(posix_udp_t *u) {
    pthread_mutex_lock(&u->ref_lock);
    int last = (--u->refs == 0);
    pthread_mutex_unlock(&u->ref_lock);
    if (!last) return;
    if (u->sock >= 0) close(u->sock);
    close_fd_pair(u->wake);
    pthread_mutex_destroy(&u->ref_lock);
    free(u);
}

static void *posix_udp_recv_thread(void *arg) {
    posix_udp_t *u = (posix_udp_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (buf != NULL) {
        struct pollfd pfds[2];
        pfds[0].fd = u->sock;
        pfds[0].events = POLLIN;
        pfds[1].fd = u->wake[0];
        pfds[1].events = POLLIN;

        for (;;) {
            if (atomic_load_explicit(&u->closing, memory_order_acquire)) break;
            pfds[0].revents = 0;
            pfds[1].revents = 0;
            int rc = poll(pfds, 2, -1);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0 || pfds[1].revents != 0) break;
            if (pfds[0].revents & POLLIN) {
                struct sockaddr_storage ss;
                socklen_t slen = sizeof(ss);
                ssize_t n = recvfrom(u->sock, buf, 65536, 0, (struct sockaddr *)&ss, &slen);
                if (n < 0) continue;
                char addr_str[INET6_ADDRSTRLEN] = "";
                uint16_t src_port = 0;
                if (ss.ss_family == AF_INET) {
                    struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
                    inet_ntop(AF_INET, &s4->sin_addr, addr_str, sizeof(addr_str));
                    src_port = ntohs(s4->sin_port);
                } else if (ss.ss_family == AF_INET6) {
                    struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
                    inet_ntop(AF_INET6, &s6->sin6_addr, addr_str, sizeof(addr_str));
                    src_port = ntohs(s6->sin6_port);
                }
                size_t alen = strlen(addr_str);
                size_t total = 5 + alen + (size_t)n;
                uint8_t *msg = (uint8_t *)malloc(total);
                if (msg != NULL) {
                    msg[0] = STS_EV_UDP_RECV;
                    put_u16_le(msg + 1, src_port);
                    put_u16_le(msg + 3, (uint16_t)alen);
                    memcpy(msg + 5, addr_str, alen);
                    if (n > 0) memcpy(msg + 5 + alen, buf, (size_t)n);
                    push_sys_bounded_tracked(u->event_id, msg, total);
                    free(msg);
                }
            }
        }
        free(buf);
    }
    push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
    posix_udp_unref(u);
    sts_detached_end();
    return NULL;
}

int64_t sts_udp_bind(uint64_t event_id, const char *addr, int32_t port, int64_t *out_port) {
    if (addr == NULL || addr[0] == '\0' || port < 0 || port > 65535) return -1;
    int is_v6 = strchr(addr, ':') != NULL;
    int family = is_v6 ? AF_INET6 : AF_INET;
    int s = socket(family, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    fcntl(s, F_SETFD, FD_CLOEXEC);
    int fl = fcntl(s, F_GETFL, 0);
    if (fl >= 0) fcntl(s, F_SETFL, fl | O_NONBLOCK);

    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    socklen_t slen = 0;
    if (is_v6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            close(s);
            return -1;
        }
        slen = sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            close(s);
            return -1;
        }
        slen = sizeof(*s4);
    }
    if (bind(s, (struct sockaddr *)&ss, slen) != 0) {
        close(s);
        return -1;
    }
    socklen_t blen = sizeof(ss);
    if (getsockname(s, (struct sockaddr *)&ss, &blen) == 0 && out_port != NULL) {
        if (ss.ss_family == AF_INET) {
            *out_port = (int64_t)ntohs(((struct sockaddr_in *)&ss)->sin_port);
        } else if (ss.ss_family == AF_INET6) {
            *out_port = (int64_t)ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
        }
    }

    posix_udp_t *u = (posix_udp_t *)calloc(1, sizeof(*u));
    if (u == NULL) {
        close(s);
        return -1;
    }
    u->event_id = event_id;
    u->sock = s;
    u->family = family;
    u->wake[0] = u->wake[1] = -1;
    atomic_store_explicit(&u->closing, 0, memory_order_relaxed);
    pthread_mutex_init(&u->ref_lock, NULL);
    u->refs = 1;
    if (make_wakeup_pipe(u->wake) != 0) {
        posix_udp_unref(u);
        return -1;
    }
    posix_udp_ref(u);
    if (!spawn_detached_thread(posix_udp_recv_thread, u)) {
        posix_udp_unref(u);
        posix_udp_unref(u);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_UDP, u);
    if (id < 0) {
        atomic_store_explicit(&u->closing, 1, memory_order_release);
        wake_pipe_signal(u->wake[1]);
        posix_udp_unref(u);
    }
    return id;
}

int32_t sts_udp_send_to(int64_t handle, const char *addr, int32_t port, const uint8_t *data, int64_t len) {
    if (addr == NULL || port <= 0 || port > 65535 || len < 0) return -1;
    size_t b = (size_t)((uint64_t)handle % STS_HANDLE_BUCKETS);
    ht_lock();
    sts_hnode_t *cur = g_ht_buckets[b];
    posix_udp_t *u = NULL;
    while (cur != NULL) {
        if (cur->id == handle && cur->kind == STS_HK_UDP) {
            u = (posix_udp_t *)cur->ptr;
            pthread_mutex_lock(&u->ref_lock);
            u->refs += 1;
            pthread_mutex_unlock(&u->ref_lock);
            break;
        }
        cur = cur->next;
    }
    ht_unlock();
    if (u == NULL) return -1;

    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    socklen_t slen = 0;
    if (u->family == AF_INET6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            posix_udp_unref(u);
            return -1;
        }
        slen = sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            posix_udp_unref(u);
            return -1;
        }
        slen = sizeof(*s4);
    }
    ssize_t rc;
    do {
        rc = sendto(u->sock, data != NULL ? data : (const uint8_t *)"", (size_t)len, 0, (struct sockaddr *)&ss, slen);
    } while (rc < 0 && errno == EINTR);
    int err = rc < 0 ? errno : 0;
    posix_udp_unref(u);
    if (rc >= 0) return 0;
    if (err == EHOSTUNREACH) return STS_ERR_HOSTUNREACH;
    if (err == ENETUNREACH) return STS_ERR_NETUNREACH;
    return -(err > 0 ? err : 1);
}

int32_t sts_udp_close(int64_t handle) {
    posix_udp_t *u = (posix_udp_t *)ht_take(STS_HK_UDP, handle);
    if (u == NULL) return 0;
    atomic_store_explicit(&u->closing, 1, memory_order_release);
    wake_pipe_signal(u->wake[1]);
    posix_udp_unref(u);
    return 1;
}

int32_t sts_udp_send_once(const char *addr, int32_t port, const uint8_t *data, int64_t len) {
    if (addr == NULL || addr[0] == '\0' || port <= 0 || port > 65535 || len < 0) return -1;
    int is_v6 = strchr(addr, ':') != NULL;
    int family = is_v6 ? AF_INET6 : AF_INET;
    int s = socket(family, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    fcntl(s, F_SETFD, FD_CLOEXEC);

    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    socklen_t slen = 0;
    if (is_v6) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss;
        s6->sin6_family = AF_INET6;
        s6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, addr, &s6->sin6_addr) != 1) {
            close(s);
            return -1;
        }
        slen = sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, addr, &s4->sin_addr) != 1) {
            close(s);
            return -1;
        }
        slen = sizeof(*s4);
    }
    ssize_t rc;
    do {
        rc = sendto(s, data != NULL ? data : (const uint8_t *)"", (size_t)len, 0, (struct sockaddr *)&ss, slen);
    } while (rc < 0 && errno == EINTR);
    int err = rc < 0 ? errno : 0;
    close(s);
    if (rc >= 0) return 0;
    if (err == EHOSTUNREACH) return STS_ERR_HOSTUNREACH;
    if (err == ENETUNREACH) return STS_ERR_NETUNREACH;
    return -(err > 0 ? err : 1);
}

// ---------------------------------------------------------------------------
// 10. POSIX Machine / OS Info
// ---------------------------------------------------------------------------

void *sts_hostname(int64_t *out_len) {
    char name[256];
    if (gethostname(name, sizeof(name)) != 0) {
        return dup_bytes("", 0, out_len);
    }
    name[sizeof(name) - 1] = '\0';
    return dup_bytes(name, strlen(name), out_len);
}

void *sts_homedir(int64_t *out_len) {
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
        return dup_bytes(home, strlen(home), out_len);
    }
    struct passwd *pw = getpwuid(getuid());
    if (pw != NULL && pw->pw_dir != NULL) {
        return dup_bytes(pw->pw_dir, strlen(pw->pw_dir), out_len);
    }
    return dup_bytes("/", 1, out_len);
}

void *sts_tmpdir(int64_t *out_len) {
    const char *names[3] = { "TMPDIR", "TMP", "TEMP" };
    for (int i = 0; i < 3; i++) {
        const char *t = getenv(names[i]);
        if (t != NULL && t[0] != '\0') {
            size_t n = strlen(t);
            if (n > 1 && t[n - 1] == '/') n -= 1;
            return dup_bytes(t, n, out_len);
        }
    }
    return dup_bytes("/tmp", 4, out_len);
}

void *sts_env_all(int64_t *out_len) {
    sbuf_t b = { 0, 0, 0 };
    for (char **e = environ; e != NULL && *e != NULL; e++) {
        sb_add(&b, *e, strlen(*e) + 1);
    }
    return sb_finish(&b, out_len);
}

void *sts_env_get(const char *name, int64_t *out_len) {
    if (name == NULL || name[0] == '\0') {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    const char *v = getenv(name);
    if (v == NULL) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    return dup_bytes(v, strlen(v), out_len);
}

int32_t sts_env_set(const char *name, const char *value) {
    if (name == NULL || name[0] == '\0' || value == NULL) return 0;
    return setenv(name, value, 1) == 0 ? 1 : 0;
}

int32_t sts_env_unset(const char *name) {
    if (name == NULL || name[0] == '\0') return 0;
    return unsetenv(name) == 0 ? 1 : 0;
}

int32_t sts_is_executable(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    struct stat st;
    return (stat(path, &st) == 0 && S_ISREG(st.st_mode) && (st.st_mode & 0111) != 0) ? 1 : 0;
}

void *sts_disk_of(const char *path, int64_t *out_len) {
    if (path == NULL || path[0] == '\0') {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    struct statvfs s;
    if (statvfs(path, &s) != 0) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{\"free\":");
    sb_fmt_f64(&b, "%.0f", (double)s.f_bavail * (double)s.f_frsize);
    sb_str(&b, ",\"total\":");
    sb_fmt_f64(&b, "%.0f", (double)s.f_blocks * (double)s.f_frsize);
    sb_str(&b, "}");
    return sb_finish(&b, out_len);
}

#ifdef __APPLE__
static void posix_cpu_part(sbuf_t *b) {
    char model[256] = "";
    size_t sz = sizeof(model);
    sysctlbyname("machdep.cpu.brand_string", model, &sz, NULL, 0);
    uint64_t freq = 0;
    sz = sizeof(freq);
    if (sysctlbyname("hw.cpufrequency", &freq, &sz, NULL, 0) != 0) freq = 0;
    natural_t count = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t info_count = 0;
    long ticks = sysconf(_SC_CLK_TCK);
    double ms = ticks > 0 ? 1000.0 / (double)ticks : 10.0;
    sb_str(b, "\"cpus\":[");
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &info_count) == KERN_SUCCESS) {
        for (natural_t i = 0; i < count; i++) {
            unsigned *t = (unsigned *)info + CPU_STATE_MAX * i;
            if (i > 0) sb_str(b, ",");
            sb_str(b, "{\"model\":");
            sb_json_str(b, model);
            sb_str(b, ",\"speed\":");
            sb_fmt_u64(b, (unsigned long long)(freq / 1000000ULL));
            sb_str(b, ",\"times\":{\"user\":");
            sb_fmt_f64(b, "%.0f", (double)t[CPU_STATE_USER] * ms);
            sb_str(b, ",\"nice\":");
            sb_fmt_f64(b, "%.0f", (double)t[CPU_STATE_NICE] * ms);
            sb_str(b, ",\"sys\":");
            sb_fmt_f64(b, "%.0f", (double)t[CPU_STATE_SYSTEM] * ms);
            sb_str(b, ",\"idle\":");
            sb_fmt_f64(b, "%.0f", (double)t[CPU_STATE_IDLE] * ms);
            sb_str(b, ",\"irq\":0}}");
        }
        vm_deallocate(mach_task_self(), (vm_address_t)info, info_count * sizeof(integer_t));
    }
    sb_str(b, "]");
}

static void posix_mem_part(sbuf_t *b) {
    uint64_t total = 0;
    size_t sz = sizeof(total);
    sysctlbyname("hw.memsize", &total, &sz, NULL, 0);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    double free_b = 0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) == KERN_SUCCESS) {
        free_b = (double)(vm.free_count + vm.inactive_count) * (double)vm_page_size;
    }
    sb_str(b, ",\"totalmem\":");
    sb_fmt_u64(b, (unsigned long long)total);
    sb_str(b, ",\"freemem\":");
    sb_fmt_f64(b, "%.0f", free_b);
    struct timeval boot;
    sz = sizeof(boot);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    double up = 0;
    if (sysctl(mib, 2, &boot, &sz, NULL, 0) == 0) {
        up = (double)(time(NULL) - boot.tv_sec);
    }
    sb_str(b, ",\"uptime\":");
    sb_fmt_f64(b, "%.0f", up);
}
#else
static void posix_cpu_part(sbuf_t *b) {
    char model[256] = "";
    double speed = 0;
    FILE *f = fopen("/proc/cpuinfo", "r");
    char line[512];
    if (f != NULL) {
        while (fgets(line, sizeof(line), f) != NULL) {
            char *colon = strchr(line, ':');
            if (colon == NULL) continue;
            if (model[0] == '\0' && (strncmp(line, "model name", 10) == 0 || strncmp(line, "Model", 5) == 0)) {
                char *v = colon + 1;
                while (*v == ' ' || *v == '\t') v++;
                size_t n = strcspn(v, "\n");
                if (n >= sizeof(model)) n = sizeof(model) - 1;
                memcpy(model, v, n);
                model[n] = '\0';
            } else if (speed == 0 && strncmp(line, "cpu MHz", 7) == 0) {
                speed = atof(colon + 1);
            }
        }
        fclose(f);
    }
    long ticks = sysconf(_SC_CLK_TCK);
    double ms = ticks > 0 ? 1000.0 / (double)ticks : 10.0;
    sb_str(b, "\"cpus\":[");
    f = fopen("/proc/stat", "r");
    int first = 1;
    if (f != NULL) {
        while (fgets(line, sizeof(line), f) != NULL) {
            if (strncmp(line, "cpu", 3) != 0 || line[3] < '0' || line[3] > '9') continue;
            unsigned long long user = 0, nice = 0, sys = 0, idle = 0, iowait = 0, irq = 0;
            char *p = line + 3;
            while (*p != '\0' && *p != ' ') p++;
            sscanf(p, "%llu %llu %llu %llu %llu %llu", &user, &nice, &sys, &idle, &iowait, &irq);
            if (!first) sb_str(b, ",");
            first = 0;
            sb_str(b, "{\"model\":");
            sb_json_str(b, model[0] != '\0' ? model : "unknown");
            sb_str(b, ",\"speed\":");
            sb_fmt_f64(b, "%.0f", speed);
            sb_str(b, ",\"times\":{\"user\":");
            sb_fmt_f64(b, "%.0f", (double)user * ms);
            sb_str(b, ",\"nice\":");
            sb_fmt_f64(b, "%.0f", (double)nice * ms);
            sb_str(b, ",\"sys\":");
            sb_fmt_f64(b, "%.0f", (double)sys * ms);
            sb_str(b, ",\"idle\":");
            sb_fmt_f64(b, "%.0f", (double)idle * ms);
            sb_str(b, ",\"irq\":");
            sb_fmt_f64(b, "%.0f", (double)irq * ms);
            sb_str(b, "}}");
        }
        fclose(f);
    }
    sb_str(b, "]");
}

static double linux_meminfo_bytes(const char *key) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (f == NULL) return -1.0;
    char line[256];
    double v = -1.0;
    size_t kl = strlen(key);
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, key, kl) == 0 && line[kl] == ':') {
            v = atof(line + kl + 1) * 1024.0;
            break;
        }
    }
    fclose(f);
    return v;
}

static void posix_mem_part(sbuf_t *b) {
    double total = linux_meminfo_bytes("MemTotal");
    double avail = linux_meminfo_bytes("MemAvailable");
    if (avail < 0) avail = linux_meminfo_bytes("MemFree");
    sb_str(b, ",\"totalmem\":");
    sb_fmt_f64(b, "%.0f", total < 0 ? 0.0 : total);
    sb_str(b, ",\"freemem\":");
    sb_fmt_f64(b, "%.0f", avail < 0 ? 0.0 : avail);
    double up = 0;
    FILE *f = fopen("/proc/uptime", "r");
    if (f != NULL) {
        if (fscanf(f, "%lf", &up) != 1) up = 0;
        fclose(f);
    }
    sb_str(b, ",\"uptime\":");
    sb_fmt_f64(b, "%.0f", up);
}
#endif

void *sts_machine_stats(int64_t *out_len) {
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{");
    posix_cpu_part(&b);
    posix_mem_part(&b);
    double load[3] = { 0.0, 0.0, 0.0 };
    if (getloadavg(load, 3) != 3) {
        load[0] = load[1] = load[2] = 0.0;
    }
    sb_str(&b, ",\"loadavg\":[");
    sb_fmt_f64(&b, "%.6f", load[0]);
    sb_str(&b, ",");
    sb_fmt_f64(&b, "%.6f", load[1]);
    sb_str(&b, ",");
    sb_fmt_f64(&b, "%.6f", load[2]);
    sb_str(&b, "]}");
    return sb_finish(&b, out_len);
}

#ifdef __linux__
static int parse_psi_total(const char *path, const char *which, unsigned long long *out_val) {
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    char line[256];
    size_t wlen = strlen(which);
    int found = 0;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, which, wlen) == 0 && line[wlen] == ' ') {
            const char *t = strstr(line, "total=");
            if (t != NULL) {
                *out_val = strtoull(t + 6, NULL, 10);
                found = 1;
                break;
            }
        }
    }
    fclose(f);
    return found;
}
#endif

void *sts_psi_pressure(int64_t *out_len) {
#ifdef __linux__
    unsigned long long cpu_some = 0, mem_some = 0, mem_full = 0;
    if (!parse_psi_total("/proc/pressure/cpu", "some", &cpu_some) ||
        !parse_psi_total("/proc/pressure/memory", "some", &mem_some) ||
        !parse_psi_total("/proc/pressure/memory", "full", &mem_full)) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    unsigned long long compact_stalls = 0, alloc_stalls = 0;
    FILE *vf = fopen("/proc/vmstat", "r");
    if (vf != NULL) {
        char line[256];
        while (fgets(line, sizeof(line), vf) != NULL) {
            if (strncmp(line, "compact_stall ", 14) == 0) {
                compact_stalls = strtoull(line + 14, NULL, 10);
            } else if (strncmp(line, "allocstall_", 11) == 0) {
                const char *sp = strchr(line, ' ');
                if (sp != NULL) {
                    alloc_stalls += strtoull(sp + 1, NULL, 10);
                }
            }
        }
        fclose(vf);
    }
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "{\"cpuSome\":");
    sb_fmt_u64(&b, cpu_some);
    sb_str(&b, ",\"memorySome\":");
    sb_fmt_u64(&b, mem_some);
    sb_str(&b, ",\"memoryFull\":");
    sb_fmt_u64(&b, mem_full);
    sb_str(&b, ",\"compactStalls\":");
    sb_fmt_u64(&b, compact_stalls);
    sb_str(&b, ",\"allocStalls\":");
    sb_fmt_u64(&b, alloc_stalls);
    sb_str(&b, "}");
    return sb_finish(&b, out_len);
#else
    if (out_len != NULL) *out_len = 0;
    return NULL;
#endif
}

void *sts_network_interfaces(int64_t *out_len) {
    struct ifaddrs *list = NULL;
    sbuf_t b = { 0, 0, 0 };
    sb_str(&b, "[");
    if (getifaddrs(&list) == 0) {
        int first = 1;
        for (struct ifaddrs *a = list; a != NULL; a = a->ifa_next) {
            if (a->ifa_addr == NULL || !(a->ifa_flags & IFF_UP)) continue;
            int family = a->ifa_addr->sa_family;
            char addr_text[INET6_ADDRSTRLEN] = "";
            char mask_text[INET6_ADDRSTRLEN] = "";
            if (family == AF_INET) {
                inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, addr_text, sizeof(addr_text));
                if (a->ifa_netmask != NULL && a->ifa_netmask->sa_family == AF_INET) {
                    inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_netmask)->sin_addr, mask_text, sizeof(mask_text));
                }
            } else if (family == AF_INET6) {
                inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ifa_addr)->sin6_addr, addr_text, sizeof(addr_text));
                if (a->ifa_netmask != NULL && a->ifa_netmask->sa_family == AF_INET6) {
                    inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ifa_netmask)->sin6_addr, mask_text, sizeof(mask_text));
                }
            } else {
                continue;
            }
            if (!first) sb_str(&b, ",");
            first = 0;
            sb_str(&b, "{\"name\":");
            sb_json_str(&b, a->ifa_name != NULL ? a->ifa_name : "");
            sb_str(&b, family == AF_INET ? ",\"family\":\"IPv4\",\"address\":" : ",\"family\":\"IPv6\",\"address\":");
            sb_json_str(&b, addr_text);
            sb_str(&b, ",\"netmask\":");
            sb_json_str(&b, mask_text);
            sb_str(&b, (a->ifa_flags & IFF_LOOPBACK) ? ",\"internal\":true}" : ",\"internal\":false}");
        }
        freeifaddrs(list);
    }
    sb_str(&b, "]");
    return sb_finish(&b, out_len);
}

#endif // _WIN32

static int sts_ipv4_host_is_loopback_or_unspec(uint32_t ip_host) {
    if ((ip_host >> 24) == 127u) return 1; // 127.0.0.0/8
    if (ip_host == 0u) return 1;           // 0.0.0.0
    return 0;
}

static int sts_ipv6_bytes_is_loopback_or_unspec(const uint8_t *b) {
    int all_zero = 1;
    for (int i = 0; i < 16; i++) {
        if (b[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    if (all_zero) return 1; // ::
    int v6_lo = 1;
    for (int i = 0; i < 15; i++) {
        if (b[i] != 0) {
            v6_lo = 0;
            break;
        }
    }
    if (v6_lo && b[15] == 1) return 1; // ::1
    int v4_mapped = 1;
    for (int i = 0; i < 10; i++) {
        if (b[i] != 0) {
            v4_mapped = 0;
            break;
        }
    }
    if (v4_mapped && b[10] == 0xff && b[11] == 0xff) {
        if (b[12] == 127) return 1; // ::ffff:127.0.0.0/104
        if (b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] == 0) return 1; // ::ffff:0.0.0.0
    }
    return 0;
}

static int sts_sockaddr_is_loopback_or_unspec(const struct sockaddr *sa) {
    if (sa == NULL) return 0;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        return sts_ipv4_host_is_loopback_or_unspec(ntohl(sin->sin_addr.s_addr));
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        return sts_ipv6_bytes_is_loopback_or_unspec((const uint8_t *)sin6->sin6_addr.s6_addr);
    }
    return 0;
}

static int sts_is_localhost_name(const char *s) {
    if (s == NULL) return 0;
    size_t len = strlen(s);
    if (len == 10 && s[9] == '.') len = 9;
    if (len != 9) return 0;
    const char *want = "localhost";
    for (size_t i = 0; i < 9; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c - 'A' + 'a');
        if (c != (unsigned char)want[i]) return 0;
    }
    return 1;
}

// Pure user-space BSD/POSIX `inet_aton`-compatible IPv4 parser supporting 1–4 dot-separated
// decimal, octal (`0...`), and hex (`0x...`) components (e.g. `2130706433`, `0x7f000001`, `0177.0.0.1`).
static int sts_parse_ipv4_compat(const char *s, uint32_t *out_host) {
    if (s == NULL || s[0] == '\0' || out_host == NULL) return 0;
    uint32_t parts[4];
    int nparts = 0;
    const char *p = s;
    for (;;) {
        if (nparts >= 4) return 0;
        if (*p == '\0') return 0;
        uint64_t val = 0;
        int base = 10;
        int digits = 0;
        if (*p == '0') {
            if (p[1] == 'x' || p[1] == 'X') {
                base = 16;
                p += 2;
            } else {
                base = 8;
                digits = 1;
                p += 1;
            }
        }
        while (*p != '\0' && *p != '.') {
            unsigned char c = (unsigned char)*p;
            uint64_t d;
            if (c >= '0' && c <= '9') d = (uint64_t)(c - '0');
            else if (base == 16 && c >= 'a' && c <= 'f') d = (uint64_t)(c - 'a' + 10);
            else if (base == 16 && c >= 'A' && c <= 'F') d = (uint64_t)(c - 'A' + 10);
            else return 0;
            if (d >= (uint64_t)base) return 0;
            val = val * (uint64_t)base + d;
            if (val > 0xFFFFFFFFULL) return 0;
            digits = 1;
            p++;
        }
        if (!digits) return 0;
        parts[nparts++] = (uint32_t)val;
        if (*p == '\0') break;
        if (*p == '.') {
            p++;
            if (*p == '\0') return 0;
        }
    }
    if (nparts == 1) {
        *out_host = parts[0];
        return 1;
    }
    if (nparts == 2) {
        if (parts[0] > 0xFFu || parts[1] > 0xFFFFFFu) return 0;
        *out_host = (parts[0] << 24) | parts[1];
        return 1;
    }
    if (nparts == 3) {
        if (parts[0] > 0xFFu || parts[1] > 0xFFu || parts[2] > 0xFFFFu) return 0;
        *out_host = (parts[0] << 24) | (parts[1] << 16) | parts[2];
        return 1;
    }
    if (parts[0] > 0xFFu || parts[1] > 0xFFu || parts[2] > 0xFFu || parts[3] > 0xFFu) return 0;
    *out_host = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    return 1;
}

static int32_t sts_copy_ip_out(const char *ip, char *out_ip, size_t out_cap) {
    size_t flen = strlen(ip);
    if (flen == 0 || flen + 1 > out_cap) return -1;
    memcpy(out_ip, ip, flen + 1);
    return 1;
}

int32_t sts_resolve_host_for_tunnel(
    const char *host,
    int32_t reject_loopback_or_unspec,
    char *out_ip,
    size_t out_cap) {
    if (host == NULL || host[0] == '\0' || out_ip == NULL || out_cap < 2) {
        return -1;
    }
    out_ip[0] = '\0';
    size_t hlen = strlen(host);
    char clean[512];
    const char *lookup_host = host;
    int bracketed = 0;
    if (hlen >= 2 && host[0] == '[' && host[hlen - 1] == ']') {
        size_t inner = hlen - 2;
        if (inner == 0 || inner >= sizeof(clean)) return -1;
        memcpy(clean, host + 1, inner);
        clean[inner] = '\0';
        lookup_host = clean;
        bracketed = 1;
    }
    if (!bracketed && sts_is_localhost_name(lookup_host)) {
        if (reject_loopback_or_unspec != 0) return -2;
        return sts_copy_ip_out("127.0.0.1", out_ip, out_cap);
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, lookup_host, &v6) == 1) {
        if (reject_loopback_or_unspec != 0 &&
            sts_ipv6_bytes_is_loopback_or_unspec((const uint8_t *)v6.s6_addr)) {
            return -2;
        }
        char buf[INET6_ADDRSTRLEN];
        if (inet_ntop(AF_INET6, &v6, buf, sizeof(buf)) == NULL) return -1;
        return sts_copy_ip_out(buf, out_ip, out_cap);
    }
    if (bracketed) {
        return -1;
    }
    struct in_addr v4;
    uint32_t v4_host = 0;
    // Parse IPv4 with `sts_parse_ipv4_compat` BEFORE `inet_pton(AF_INET, ...)`:
    // macOS BSD `inet_pton` accepts leading-zero octets as decimal (`0177.0.0.1` -> `177.0.0.1`),
    // whereas `getaddrinfo`/`inet_aton` treats `0177` as octal `127` (`127.0.0.1`).
    if (sts_parse_ipv4_compat(lookup_host, &v4_host)) {
        if (reject_loopback_or_unspec != 0 && sts_ipv4_host_is_loopback_or_unspec(v4_host)) {
            return -2;
        }
        v4.s_addr = htonl(v4_host);
        char buf[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &v4, buf, sizeof(buf)) == NULL) return -1;
        return sts_copy_ip_out(buf, out_ip, out_cap);
    }
    if (inet_pton(AF_INET, lookup_host, &v4) == 1) {
        if (reject_loopback_or_unspec != 0 &&
            sts_ipv4_host_is_loopback_or_unspec(ntohl(v4.s_addr))) {
            return -2;
        }
        char buf[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &v4, buf, sizeof(buf)) == NULL) return -1;
        return sts_copy_ip_out(buf, out_ip, out_cap);
    }
    // Non-literal hostname: caller must dispatch `sts_resolve_host_for_tunnel_async`.
    return 0;
}

typedef struct {
    uint64_t event_id;
    int32_t reject_loopback_or_unspec;
    char *host;
} sts_dns_task_t;

static void sts_dns_emit_result(uint64_t event_id, int32_t rc, const char *ip) {
    size_t ip_len = (rc == 1 && ip != NULL) ? strlen(ip) : 0;
    uint8_t payload[5 + INET6_ADDRSTRLEN];
    if (ip_len > INET6_ADDRSTRLEN) ip_len = INET6_ADDRSTRLEN;
    payload[0] = (uint8_t)STS_EV_DNS_RESOLVED;
    uint32_t u = (uint32_t)rc;
    payload[1] = (uint8_t)(u & 0xFFu);
    payload[2] = (uint8_t)((u >> 8) & 0xFFu);
    payload[3] = (uint8_t)((u >> 16) & 0xFFu);
    payload[4] = (uint8_t)((u >> 24) & 0xFFu);
    if (ip_len > 0) {
        memcpy(payload + 5, ip, ip_len);
    }
    sth_push_sys(event_id, payload, (int64_t)(5 + ip_len));
}

static void sts_dns_run_task(sts_dns_task_t *task) {
#ifdef _WIN32
    static atomic_int g_sts_resolve_wsa = 0;
    if (atomic_load(&g_sts_resolve_wsa) == 0) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
            atomic_store(&g_sts_resolve_wsa, 1);
        }
    }
#endif
    char first_ip[INET6_ADDRSTRLEN];
    first_ip[0] = '\0';
    int32_t out_rc = sts_resolve_host_for_tunnel(
        task->host,
        task->reject_loopback_or_unspec,
        first_ip,
        sizeof(first_ip));
    if (out_rc == 0) {
        out_rc = -1;
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = NULL;
        int gai_rc = getaddrinfo(task->host, NULL, &hints, &res);
        if (gai_rc == 0 && res != NULL) {
            int blocked = 0;
            for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
                if (ai->ai_addr == NULL) continue;
                if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) continue;
                if (task->reject_loopback_or_unspec != 0 &&
                    sts_sockaddr_is_loopback_or_unspec(ai->ai_addr)) {
                    blocked = 1;
                    break;
                }
                if (first_ip[0] == '\0') {
                    if (ai->ai_family == AF_INET) {
                        const struct sockaddr_in *sin = (const struct sockaddr_in *)ai->ai_addr;
                        if (inet_ntop(AF_INET, &sin->sin_addr, first_ip, sizeof(first_ip)) == NULL) {
                            first_ip[0] = '\0';
                        }
                    } else if (ai->ai_family == AF_INET6) {
                        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ai->ai_addr;
                        if (inet_ntop(AF_INET6, &sin6->sin6_addr, first_ip, sizeof(first_ip)) == NULL) {
                            first_ip[0] = '\0';
                        }
                    }
                }
            }
            freeaddrinfo(res);
            if (blocked) {
                out_rc = -2;
            } else if (first_ip[0] != '\0') {
                out_rc = 1;
            }
        }
    }
    sts_dns_emit_result(task->event_id, out_rc, first_ip);
    free(task->host);
    free(task);
}

#ifdef _WIN32
static DWORD WINAPI sts_dns_worker_win(LPVOID arg) {
    sts_dns_run_task((sts_dns_task_t *)arg);
    sts_detached_end();
    return 0;
}
#else
static void *sts_dns_worker_posix(void *arg) {
    sts_dns_run_task((sts_dns_task_t *)arg);
    sts_detached_end();
    return NULL;
}
#endif

int32_t sts_resolve_host_for_tunnel_async(
    uint64_t event_id,
    const char *host,
    int32_t reject_loopback_or_unspec) {
    if (host == NULL || host[0] == '\0') return 0;
    size_t hlen = strlen(host);
    if (hlen >= 512) return 0;
    sts_dns_task_t *task = (sts_dns_task_t *)calloc(1, sizeof(sts_dns_task_t));
    if (task == NULL) return 0;
    task->host = (char *)malloc(hlen + 1);
    if (task->host == NULL) {
        free(task);
        return 0;
    }
    memcpy(task->host, host, hlen + 1);
    task->event_id = event_id;
    task->reject_loopback_or_unspec = reject_loopback_or_unspec;
#ifdef _WIN32
    if (!win_spawn_detached_thread(sts_dns_worker_win, task)) {
        free(task->host);
        free(task);
        return 0;
    }
#else
    if (!spawn_detached_thread(sts_dns_worker_posix, task)) {
        free(task->host);
        free(task);
        return 0;
    }
#endif
    return 1;
}

#ifdef _WIN32
#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
#define PROC_THREAD_ATTRIBUTE_JOB_LIST ((SIZE_T)0x0002000D)
#endif

typedef struct {
    wchar_t *data;
    size_t len;
    size_t cap;
} sts_wbuf_t;

static int sts_wbuf_push(sts_wbuf_t *b, wchar_t c) {
    if (b->len + 1 >= b->cap) {
        size_t next_cap = b->cap == 0 ? 256 : b->cap * 2;
        wchar_t *next = (wchar_t *)realloc(b->data, next_cap * sizeof(wchar_t));
        if (next == NULL) return 0;
        b->data = next;
        b->cap = next_cap;
    }
    b->data[b->len++] = c;
    b->data[b->len] = L'\0';
    return 1;
}

static int sts_wbuf_append_arg(sts_wbuf_t *b, const wchar_t *arg) {
    int need_quotes = arg[0] == L'\0';
    for (const wchar_t *p = arg; !need_quotes && *p != L'\0'; p++) {
        if (*p == L' ' || *p == L'\t' || *p == L'\n' || *p == L'\v' || *p == L'"') {
            need_quotes = 1;
        }
    }
    if (!need_quotes) {
        for (const wchar_t *p = arg; *p != L'\0'; p++) {
            if (!sts_wbuf_push(b, *p)) return 0;
        }
        return 1;
    }
    if (!sts_wbuf_push(b, L'"')) return 0;
    size_t slashes = 0;
    for (const wchar_t *p = arg; *p != L'\0'; p++) {
        if (*p == L'\\') {
            slashes++;
        } else if (*p == L'"') {
            for (size_t i = 0; i < slashes * 2 + 1; i++) {
                if (!sts_wbuf_push(b, L'\\')) return 0;
            }
            slashes = 0;
            if (!sts_wbuf_push(b, L'"')) return 0;
        } else {
            for (size_t i = 0; i < slashes; i++) {
                if (!sts_wbuf_push(b, L'\\')) return 0;
            }
            slashes = 0;
            if (!sts_wbuf_push(b, *p)) return 0;
        }
    }
    for (size_t i = 0; i < slashes * 2; i++) {
        if (!sts_wbuf_push(b, L'\\')) return 0;
    }
    return sts_wbuf_push(b, L'"');
}
#endif

int32_t sts_exec_replace(
    const char *program,
    const uint8_t *argv_nul,
    int64_t argv_len) {
    if (program == NULL || program[0] == '\0' || argv_len < 0) {
        return 127;
    }
    if (argv_len > 0 && argv_nul == NULL) {
        return 127;
    }

    size_t total = (size_t)argv_len;
    size_t argc = 0;
    size_t pos = 0;
    while (pos < total) {
        const uint8_t *nul = (const uint8_t *)memchr(argv_nul + pos, '\0', total - pos);
        if (nul == NULL) break;
        argc++;
        pos = (size_t)(nul - argv_nul) + 1;
    }

    size_t alloc_argc = argc > 0 ? argc : 1;
    char **argv = (char **)malloc((alloc_argc + 1) * sizeof(char *));
    if (argv == NULL) {
        fprintf(stderr, "stillfail-station-pion: out of memory preparing exec\n");
        return 127;
    }
    size_t idx = 0;
    if (argc == 0) {
        argv[idx++] = (char *)program;
    } else {
        pos = 0;
        while (pos < total && idx < argc) {
            const uint8_t *nul = (const uint8_t *)memchr(argv_nul + pos, '\0', total - pos);
            if (nul == NULL) break;
            argv[idx++] = (char *)(argv_nul + pos);
            pos = (size_t)(nul - argv_nul) + 1;
        }
    }
    argv[idx] = NULL;

#ifdef _WIN32
    wchar_t *wprog = utf8_to_wide(program);
    if (wprog == NULL) {
        free(argv);
        fprintf(stderr, "stillfail-station-pion: invalid UTF-8 program path\n");
        return 127;
    }
    sts_wbuf_t cmd = { NULL, 0, 0 };
    for (size_t i = 0; i < idx; i++) {
        if (i > 0 && !sts_wbuf_push(&cmd, L' ')) {
            free(cmd.data);
            free(wprog);
            free(argv);
            fprintf(stderr, "stillfail-station-pion: out of memory building command line\n");
            return 127;
        }
        wchar_t *warg = utf8_to_wide(argv[i]);
        int ok = warg != NULL && sts_wbuf_append_arg(&cmd, warg);
        free(warg);
        if (!ok) {
            free(cmd.data);
            free(wprog);
            free(argv);
            fprintf(stderr, "stillfail-station-pion: failed formatting Windows arguments\n");
            return 127;
        }
    }
    free(argv);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job == NULL) {
        fprintf(stderr, "stillfail-station-pion: CreateJobObjectW failed (error %lu)\n", (unsigned long)GetLastError());
        free(cmd.data);
        free(wprog);
        return 127;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli;
    ZeroMemory(&jeli, sizeof(jeli));
    jeli.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) {
        fprintf(stderr, "stillfail-station-pion: SetInformationJobObject failed (error %lu)\n", (unsigned long)GetLastError());
        CloseHandle(job);
        free(cmd.data);
        free(wprog);
        return 127;
    }

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    if (attr_size == 0) {
        fprintf(stderr, "stillfail-station-pion: InitializeProcThreadAttributeList sizing failed (error %lu)\n", (unsigned long)GetLastError());
        CloseHandle(job);
        free(cmd.data);
        free(wprog);
        return 127;
    }
    LPPROC_THREAD_ATTRIBUTE_LIST attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (attr_list == NULL || !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size)) {
        fprintf(stderr, "stillfail-station-pion: InitializeProcThreadAttributeList failed (error %lu)\n", (unsigned long)GetLastError());
        free(attr_list);
        CloseHandle(job);
        free(cmd.data);
        free(wprog);
        return 127;
    }
    if (!UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(HANDLE), NULL, NULL)) {
        fprintf(stderr, "stillfail-station-pion: UpdateProcThreadAttribute(JOB_LIST) failed (error %lu)\n", (unsigned long)GetLastError());
        DeleteProcThreadAttributeList(attr_list);
        free(attr_list);
        CloseHandle(job);
        free(cmd.data);
        free(wprog);
        return 127;
    }

    STARTUPINFOEXW siex;
    PROCESS_INFORMATION pi;
    ZeroMemory(&siex, sizeof(siex));
    siex.StartupInfo.cb = sizeof(siex);
    siex.lpAttributeList = attr_list;
    ZeroMemory(&pi, sizeof(pi));
    BOOL created = CreateProcessW(
        wprog, cmd.data, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &siex.StartupInfo, &pi);
    DWORD create_err = created ? 0 : GetLastError();
    DeleteProcThreadAttributeList(attr_list);
    free(attr_list);
    free(cmd.data);
    free(wprog);
    if (!created) {
        fprintf(stderr, "stillfail-station-pion: CreateProcessW(%s) failed (error %lu)\n", program, (unsigned long)create_err);
        CloseHandle(job);
        return 127;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(job);
    return (int32_t)code;
#else
    fflush(stdout);
    fflush(stderr);
    execv(program, argv);
    int err = errno;
    fprintf(stderr, "stillfail-station-pion: execv(%s) failed: %s\n", program, strerror(err));
    free(argv);
    return 127;
#endif
}

#include "station_js_lower.h"
