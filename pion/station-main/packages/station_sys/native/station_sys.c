// Cross-platform C11 system primitives for Pion Station (`station_sys`).
// Targets: POSIX (macOS arm64, Linux x64/arm64) + Windows (`_WIN32` / MinGW).
//
// Core architectural invariants:
// 1. Foreign threads NEVER invoke Pion callbacks; they only enqueue native events
//    onto `host_shim`'s queue (`sth_push_sys` for control events, `sth_push_sys_bounded`
//    for bulk data events).
// 2. Every handle's `close` explicitly wakes any blocked reader/writer/waiter thread
//    and joins it before returning (zero orphan threads, zero leaked fds/handles,
//    zero deadlocks).
// 3. Control channel (`sts_ctrl_*`) only operates on the explicitly supplied control
//    fd (e.g. fd 5) or Windows named pipe — never touches Unix listening fds 3/4.

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
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <psapi.h>
#include <tlhelp32.h>
#else
#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
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
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <util.h>
#else
#include <pty.h>
#include <sys/inotify.h>
#include <sys/syscall.h>
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
    const char *slash = strrchr(path, '/');
    const char *bslash = strrchr(path, '\\');
    const char *sep = slash;
    if (bslash != NULL && (sep == NULL || bslash > sep)) {
        sep = bslash;
    }
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
    uint8_t *out = (uint8_t *)malloc(len > 0 ? len : 1);
    if (out == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    if (len > 0 && src != NULL) {
        memcpy(out, src, len);
    }
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
    STS_HK_UDP      = 6
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
    if (h_io == NULL) {
        push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
        return 0;
    }
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (buf == NULL) {
        CloseHandle(h_io);
        push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
        return 0;
    }
    for (;;) {
        ResetEvent(h_io);
        OVERLAPPED ov;
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = h_io;
        DWORD filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                       FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                       FILE_NOTIFY_CHANGE_LAST_WRITE;
        BOOL ok = ReadDirectoryChangesW(w->h_dir, buf, 65536, FALSE, filter, NULL, &ov, NULL);
        if (!ok) {
            break;
        }
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
            continue;
        }
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
            if (fni->NextEntryOffset == 0 || (size_t)fni->NextEntryOffset > (size_t)bytes - off) {
                break;
            }
            off += fni->NextEntryOffset;
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
    if (w->h_stop == NULL) {
        free(w->filter_name);
        CloseHandle(h_dir);
        free(w);
        return -1;
    }
    w->h_thread = CreateThread(NULL, 0, win_fsw_thread, w, 0, NULL);
    if (w->h_thread == NULL) {
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
    DWORD pid;
    HANDLE h_stop;
    _Atomic int closing;

    HANDLE h_stdin;
    SRWLOCK stdin_lock;
    CONDITION_VARIABLE stdin_cond;
    sts_chunk_t *stdin_head;
    sts_chunk_t *stdin_tail;
    size_t stdin_queued;
    int stdin_eof;
    int stdin_aborted;
    HANDLE th_stdin;

    HANDLE h_stdout;
    HANDLE th_stdout;
    HANDLE h_stderr;
    HANDLE th_stderr;
    HANDLE th_wait;
    SRWLOCK ref_lock;
    int refs;
} win_proc_t;

static _Atomic uint64_t g_win_pipe_seq = 1;

static int win_create_overlapped_read_pipe(HANDLE *out_read, HANDLE *out_write_inheritable) {
    uint64_t seq = atomic_fetch_add_explicit(&g_win_pipe_seq, 1, memory_order_relaxed);
    wchar_t name[128];
    swprintf(name, 128, L"\\\\.\\pipe\\stillfail-sts-pipe-%lu-%llu",
             (unsigned long)GetCurrentProcessId(), (unsigned long long)seq);
    HANDLE r = CreateNamedPipeW(
        name,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        1,
        65536,
        65536,
        0,
        NULL);
    if (r == INVALID_HANDLE_VALUE) {
        return 0;
    }
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE w = CreateFileW(
        name,
        GENERIC_WRITE,
        0,
        &sa,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    if (w == INVALID_HANDLE_VALUE) {
        CloseHandle(r);
        return 0;
    }
    *out_read = r;
    *out_write_inheritable = w;
    return 1;
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
    HANDLE h_io = CreateEventW(NULL, TRUE, FALSE, NULL);
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    int eof = 0;
    if (h_io != NULL && buf != NULL) {
        buf[0] = pa->data_tag;
        for (;;) {
            if (atomic_load_explicit(&pa->proc->closing, memory_order_acquire)) {
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
                    HANDLE waits[2] = { h_io, pa->proc->h_stop };
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
            if (atomic_load_explicit(&pa->proc->closing, memory_order_acquire)) {
                break;
            }
            sth_push_sys_bounded(pa->proc->event_id, buf, (size_t)n + 1);
        }
    }
    free(buf);
    if (h_io != NULL) CloseHandle(h_io);
    if (eof && !atomic_load_explicit(&pa->proc->closing, memory_order_acquire)) {
        push_tag_ctrl(pa->proc->event_id, pa->eof_tag, NULL, 0);
    }
    free(pa);
    return 0;
}

static DWORD WINAPI win_stdin_thread(LPVOID arg) {
    win_proc_t *p = (win_proc_t *)arg;
    for (;;) {
        AcquireSRWLockExclusive(&p->stdin_lock);
        while (!p->stdin_aborted && p->stdin_head == NULL && !p->stdin_eof) {
            SleepConditionVariableSRW(&p->stdin_cond, &p->stdin_lock, INFINITE, 0);
        }
        if (p->stdin_aborted) {
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

            size_t done = 0;
            int ok = 1;
            while (done < ch->len) {
                DWORD want = (ch->len - done) > 0x7fffffffu ? 0x7fffffffu : (DWORD)(ch->len - done);
                DWORD n = 0;
                if (!WriteFile(h, ch->data + done, want, &n, NULL) || n == 0) {
                    ok = 0;
                    break;
                }
                done += (size_t)n;
            }
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
    AcquireSRWLockExclusive(&p->stdin_lock);
    if (p->h_stdin != NULL) {
        CloseHandle(p->h_stdin);
        p->h_stdin = NULL;
    }
    ReleaseSRWLockExclusive(&p->stdin_lock);
    return 0;
}

static DWORD WINAPI win_wait_thread(LPVOID arg) {
    win_proc_t *p = (win_proc_t *)arg;
    HANDLE waits[2] = { p->h_proc, p->h_stop };
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
    if (wr == WAIT_OBJECT_0) {
        DWORD code = 1;
        GetExitCodeProcess(p->h_proc, &code);
        AcquireSRWLockExclusive(&p->stdin_lock);
        p->stdin_aborted = 1;
        WakeConditionVariable(&p->stdin_cond);
        ReleaseSRWLockExclusive(&p->stdin_lock);
        push_exit_event(p->event_id, STS_EV_PROC_EXIT, (int32_t)code, 0, "");
    }
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

static wchar_t *win_build_env_block(const uint8_t *env_nul, int64_t env_len, int strip_mse) {
    if (env_len <= 0 && !strip_mse) {
        return NULL;
    }
    sbuf_t utf8 = { 0, 0, 0 };
    if (env_len > 0 && env_nul != NULL) {
        int64_t i = 0;
        while (i < env_len) {
            const char *entry = (const char *)(env_nul + i);
            size_t n = strnlen(entry, (size_t)(env_len - i));
            if (n > 0 && !(strip_mse && is_malloc_se_entry(entry))) {
                sb_add(&utf8, entry, n);
                sb_add(&utf8, "", 1);
            }
            i += (int64_t)n + 1;
        }
    } else {
        wchar_t *block = GetEnvironmentStringsW();
        if (block != NULL) {
            for (wchar_t *p = block; *p != 0; p += wcslen(p) + 1) {
                char *s = wide_to_utf8(p);
                if (s != NULL) {
                    if (!(strip_mse && is_malloc_se_entry(s))) {
                        sb_add(&utf8, s, strlen(s) + 1);
                    }
                    free(s);
                }
            }
            FreeEnvironmentStringsW(block);
        }
    }
    sb_add(&utf8, "", 1);
    int wn = MultiByteToWideChar(CP_UTF8, 0, utf8.data ? utf8.data : "\0", (int)(utf8.len > 0 ? utf8.len : 1), NULL, 0);
    wchar_t *wenv = (wchar_t *)calloc((size_t)wn + 2, sizeof(wchar_t));
    if (wenv != NULL && utf8.data != NULL && utf8.len > 0) {
        MultiByteToWideChar(CP_UTF8, 0, utf8.data, (int)utf8.len, wenv, wn);
    }
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
    wchar_t *wenv = win_build_env_block(env_nul, env_len, (flags & STS_PROC_STRIP_MALLOC_SE) != 0);
    wchar_t *wcwd = (cwd != NULL && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;

    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE child_h[3] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE };
    HANDLE mine_h[3] = { NULL, NULL, NULL };
    int pipe_flags[3] = {
        (flags & STS_PROC_PIPE_STDIN) != 0,
        (flags & STS_PROC_PIPE_STDOUT) != 0,
        (flags & STS_PROC_PIPE_STDERR) != 0
    };
    for (int i = 0; i < 3; i++) {
        if (pipe_flags[i]) {
            HANDLE r = NULL, w = NULL;
            if (i == 0) {
                if (!CreatePipe(&r, &w, &sa, 0)) {
                    child_h[i] = INVALID_HANDLE_VALUE;
                } else {
                    child_h[i] = r;
                    mine_h[i] = w;
                    SetHandleInformation(w, HANDLE_FLAG_INHERIT, 0);
                }
            } else {
                if (!win_create_overlapped_read_pipe(&r, &w)) {
                    child_h[i] = INVALID_HANDLE_VALUE;
                } else {
                    child_h[i] = w;
                    mine_h[i] = r;
                }
            }
        } else {
            child_h[i] = win_open_nul();
        }
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = child_h[0];
    si.hStdOutput = child_h[1];
    si.hStdError = child_h[2];

    DWORD cflags = CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW |
                   ((flags & STS_PROC_NEW_PGID) ? CREATE_NEW_PROCESS_GROUP : 0);
    BOOL ok = (wline != NULL) && CreateProcessW(NULL, wline, NULL, NULL, TRUE, cflags, wenv, wcwd, &si, &pi);
    DWORD err = ok ? 0 : GetLastError();

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
        win_err_str(err, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    CloseHandle(pi.hThread);

    win_proc_t *p = (win_proc_t *)calloc(1, sizeof(*p));
    if (p == NULL) {
        for (int i = 0; i < 3; i++) {
            if (mine_h[i] != NULL) CloseHandle(mine_h[i]);
        }
        CloseHandle(pi.hProcess);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    p->event_id = event_id;
    p->h_proc = pi.hProcess;
    p->pid = pi.dwProcessId;
    p->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    p->h_stdin = mine_h[0];
    p->h_stdout = mine_h[1];
    p->h_stderr = mine_h[2];
    InitializeSRWLock(&p->stdin_lock);
    InitializeConditionVariable(&p->stdin_cond);
    InitializeSRWLock(&p->ref_lock);
    p->refs = 1;

    if (p->h_stdin != NULL) {
        p->th_stdin = CreateThread(NULL, 0, win_stdin_thread, p, 0, NULL);
    }
    if (p->h_stdout != NULL) {
        win_pipe_arg_t *pa = (win_pipe_arg_t *)malloc(sizeof(*pa));
        if (pa != NULL) {
            pa->proc = p;
            pa->h_pipe = p->h_stdout;
            pa->data_tag = STS_EV_PROC_STDOUT;
            pa->eof_tag = STS_EV_PROC_STDOUT_EOF;
            p->th_stdout = CreateThread(NULL, 0, win_pipe_reader_thread, pa, 0, NULL);
        }
    }
    if (p->h_stderr != NULL) {
        win_pipe_arg_t *pa = (win_pipe_arg_t *)malloc(sizeof(*pa));
        if (pa != NULL) {
            pa->proc = p;
            pa->h_pipe = p->h_stderr;
            pa->data_tag = STS_EV_PROC_STDERR;
            pa->eof_tag = STS_EV_PROC_STDERR_EOF;
            p->th_stderr = CreateThread(NULL, 0, win_pipe_reader_thread, pa, 0, NULL);
        }
    }
    p->th_wait = CreateThread(NULL, 0, win_wait_thread, p, 0, NULL);

    int64_t id = ht_insert(STS_HK_PROC, p);
    if (id < 0) {
        atomic_store_explicit(&p->closing, 1, memory_order_release);
        SetEvent(p->h_stop);
        AcquireSRWLockExclusive(&p->stdin_lock);
        p->stdin_aborted = 1;
        WakeConditionVariable(&p->stdin_cond);
        ReleaseSRWLockExclusive(&p->stdin_lock);
        if (p->th_stdin != NULL) {
            WaitForSingleObject(p->th_stdin, INFINITE);
            CloseHandle(p->th_stdin);
        }
        if (p->th_stdout != NULL) {
            WaitForSingleObject(p->th_stdout, INFINITE);
            CloseHandle(p->th_stdout);
        }
        if (p->th_stderr != NULL) {
            WaitForSingleObject(p->th_stderr, INFINITE);
            CloseHandle(p->th_stderr);
        }
        if (p->th_wait != NULL) {
            WaitForSingleObject(p->th_wait, INFINITE);
            CloseHandle(p->th_wait);
        }
        win_proc_unref(p);
        copy_err(err_buf, err_cap, "oom");
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

int32_t sts_proc_close(int64_t handle) {
    win_proc_t *p = (win_proc_t *)ht_take(STS_HK_PROC, handle);
    if (p == NULL) return 0;
    atomic_store_explicit(&p->closing, 1, memory_order_release);
    SetEvent(p->h_stop);
    AcquireSRWLockExclusive(&p->stdin_lock);
    p->stdin_aborted = 1;
    WakeConditionVariable(&p->stdin_cond);
    ReleaseSRWLockExclusive(&p->stdin_lock);
    if (p->th_stdin != NULL) {
        WaitForSingleObject(p->th_stdin, INFINITE);
        CloseHandle(p->th_stdin);
    }
    if (p->th_stdout != NULL) {
        WaitForSingleObject(p->th_stdout, INFINITE);
        CloseHandle(p->th_stdout);
    }
    if (p->th_stderr != NULL) {
        WaitForSingleObject(p->th_stderr, INFINITE);
        CloseHandle(p->th_stderr);
    }
    if (p->th_wait != NULL) {
        WaitForSingleObject(p->th_wait, INFINITE);
        CloseHandle(p->th_wait);
    }
    win_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill(int32_t pid, int32_t sig, int32_t group) {
    if (pid <= 0) return -1;
    if (sig == STS_SIG_PROBE) {
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
        if (h == NULL) return GetLastError() == ERROR_ACCESS_DENIED ? 0 : -1;
        DWORD code = 0;
        int alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
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
                size_t ll = line.len;
                if (ll > 0 && line.data[ll - 1] == '\r') ll -= 1;
                push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data ? line.data : "", ll);
                line.len = 0;
            } else {
                sb_add(&line, buf + i, 1);
            }
        }
    }
    if (eof) {
        if (line.len > 0) {
            size_t ll = line.len;
            if (line.data[ll - 1] == '\r') ll -= 1;
            push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data, ll);
        }
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
    AcquireSRWLockExclusive(&g_win_sig_lock);
    int active = g_win_sig_active;
    uint64_t eid = g_win_sig_event_id;
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    if (!active) return FALSE;
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
    sth_push_sys(eid, msg, 5 + nlen);
    return TRUE;
}

int32_t sts_signal_watch(uint64_t event_id) {
    AcquireSRWLockExclusive(&g_win_sig_lock);
    g_win_sig_event_id = event_id;
    int already = g_win_sig_active;
    g_win_sig_active = 1;
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    if (!already) {
        if (!SetConsoleCtrlHandler(win_ctrl_handler, TRUE)) {
            AcquireSRWLockExclusive(&g_win_sig_lock);
            g_win_sig_active = 0;
            ReleaseSRWLockExclusive(&g_win_sig_lock);
            return 0;
        }
    }
    return 1;
}

int32_t sts_signal_unwatch(void) {
    AcquireSRWLockExclusive(&g_win_sig_lock);
    int was = g_win_sig_active;
    g_win_sig_active = 0;
    ReleaseSRWLockExclusive(&g_win_sig_lock);
    if (was) {
        SetConsoleCtrlHandler(win_ctrl_handler, FALSE);
    }
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
    HANDLE h_stop;
    _Atomic int closing;
    HANDLE th_read;
    HANDLE th_wait;
    SRWLOCK write_lock;
    SRWLOCK ref_lock;
    int refs;
} win_pty_t;

static void win_pty_unref(win_pty_t *pt) {
    AcquireSRWLockExclusive(&pt->ref_lock);
    int last = (--pt->refs == 0);
    ReleaseSRWLockExclusive(&pt->ref_lock);
    if (!last) return;
    if (pt->h_in_w != NULL) CloseHandle(pt->h_in_w);
    if (pt->h_out_r != NULL) CloseHandle(pt->h_out_r);
    if (pt->h_proc != NULL) CloseHandle(pt->h_proc);
    if (pt->h_stop != NULL) CloseHandle(pt->h_stop);
    free(pt);
}

static DWORD WINAPI win_pty_read_thread(LPVOID arg) {
    win_pty_t *pt = (win_pty_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    if (buf != NULL) {
        buf[0] = STS_EV_PTY_DATA;
        DWORD n = 0;
        while (ReadFile(pt->h_out_r, buf + 1, 65536, &n, NULL) && n > 0) {
            if (!atomic_load_explicit(&pt->closing, memory_order_acquire)) {
                sth_push_sys_bounded(pt->event_id, buf, (size_t)n + 1);
            }
            // When closing == 1, keep draining ReadFile and discarding bytes so
            // ClosePseudoConsole can flush and close the pipe without deadlocking.
        }
        free(buf);
    }
    if (!atomic_load_explicit(&pt->closing, memory_order_acquire)) {
        push_tag_ctrl(pt->event_id, STS_EV_PTY_EOF, NULL, 0);
    }
    return 0;
}

static DWORD WINAPI win_pty_wait_thread(LPVOID arg) {
    win_pty_t *pt = (win_pty_t *)arg;
    HANDLE waits[2] = { pt->h_proc, pt->h_stop };
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
    if (wr == WAIT_OBJECT_0) {
        DWORD code = 1;
        GetExitCodeProcess(pt->h_proc, &code);
        push_exit_event(pt->event_id, STS_EV_PTY_EXIT, (int32_t)code, 0, "");
    }
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
    if (!CreatePipe(&in_r, &in_w, NULL, 0) || !CreatePipe(&out_r, &out_w, NULL, 0)) {
        if (in_r) CloseHandle(in_r);
        if (in_w) CloseHandle(in_w);
        if (out_r) CloseHandle(out_r);
        if (out_w) CloseHandle(out_w);
        copy_err(err_buf, err_cap, "CreatePipe failed");
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
        p_close(hpc);
        CloseHandle(in_w);
        CloseHandle(out_r);
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
    wchar_t *wenv = win_build_env_block(env_nul, env_len, (flags & STS_PROC_STRIP_MALLOC_SE) != 0);
    wchar_t *wcwd = (cwd != NULL && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;

    STARTUPINFOEXW siex;
    PROCESS_INFORMATION pi;
    memset(&siex, 0, sizeof(siex));
    memset(&pi, 0, sizeof(pi));
    siex.StartupInfo.cb = sizeof(siex);
    siex.lpAttributeList = attr_list;

    BOOL ok = (wline != NULL) && CreateProcessW(
        NULL,
        wline,
        NULL,
        NULL,
        FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
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
        p_close(hpc);
        CloseHandle(in_w);
        CloseHandle(out_r);
        char msg[256];
        win_err_str(err, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    CloseHandle(pi.hThread);

    win_pty_t *pt = (win_pty_t *)calloc(1, sizeof(*pt));
    if (pt == NULL) {
        p_close(hpc);
        CloseHandle(in_w);
        CloseHandle(out_r);
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
    pt->h_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    InitializeSRWLock(&pt->write_lock);
    InitializeSRWLock(&pt->ref_lock);
    pt->refs = 1;
    pt->th_read = CreateThread(NULL, 0, win_pty_read_thread, pt, 0, NULL);
    pt->th_wait = CreateThread(NULL, 0, win_pty_wait_thread, pt, 0, NULL);
    int64_t id = ht_insert(STS_HK_PTY, pt);
    if (id < 0) {
        atomic_store_explicit(&pt->closing, 1, memory_order_release);
        SetEvent(pt->h_stop);
        AcquireSRWLockExclusive(&pt->write_lock);
        if (pt->hpc != NULL) {
            pt->p_close(pt->hpc);
            pt->hpc = NULL;
        }
        ReleaseSRWLockExclusive(&pt->write_lock);
        if (pt->th_read != NULL) {
            WaitForSingleObject(pt->th_read, INFINITE);
            CloseHandle(pt->th_read);
        }
        if (pt->th_wait != NULL) {
            WaitForSingleObject(pt->th_wait, INFINITE);
            CloseHandle(pt->th_wait);
        }
        win_pty_unref(pt);
        copy_err(err_buf, err_cap, "oom");
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
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    AcquireSRWLockExclusive(&pt->write_lock);
    size_t done = 0;
    int ok = 1;
    while (done < (size_t)len) {
        DWORD want = ((size_t)len - done) > 0x7fffffffu ? 0x7fffffffu : (DWORD)((size_t)len - done);
        DWORD n = 0;
        if (!WriteFile(pt->h_in_w, data + done, want, &n, NULL) || n == 0) {
            ok = 0;
            break;
        }
        done += (size_t)n;
    }
    ReleaseSRWLockExclusive(&pt->write_lock);
    win_pty_unref(pt);
    return ok;
}

int32_t sts_pty_resize(int64_t handle, int32_t cols, int32_t rows) {
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    COORD sz;
    sz.X = (SHORT)(cols > 0 ? cols : 80);
    sz.Y = (SHORT)(rows > 0 ? rows : 24);
    AcquireSRWLockExclusive(&pt->write_lock);
    HRESULT hr = pt->hpc != NULL ? pt->p_resize(pt->hpc, sz) : E_FAIL;
    ReleaseSRWLockExclusive(&pt->write_lock);
    win_pty_unref(pt);
    return SUCCEEDED(hr) ? 1 : 0;
}

int32_t sts_pty_kill(int64_t handle, int32_t sig) {
    (void)sig;
    win_pty_t *pt = win_pty_get(handle);
    if (pt == NULL) return 0;
    BOOL ok = TerminateProcess(pt->h_proc, 1);
    win_pty_unref(pt);
    return ok ? 1 : 0;
}

int32_t sts_pty_close(int64_t handle) {
    win_pty_t *pt = (win_pty_t *)ht_take(STS_HK_PTY, handle);
    if (pt == NULL) return 0;
    atomic_store_explicit(&pt->closing, 1, memory_order_release);
    SetEvent(pt->h_stop);
    AcquireSRWLockExclusive(&pt->write_lock);
    if (pt->hpc != NULL) {
        pt->p_close(pt->hpc);
        pt->hpc = NULL;
    }
    ReleaseSRWLockExclusive(&pt->write_lock);
    if (pt->th_read != NULL) {
        WaitForSingleObject(pt->th_read, INFINITE);
        CloseHandle(pt->th_read);
    }
    if (pt->th_wait != NULL) {
        WaitForSingleObject(pt->th_wait, INFINITE);
        CloseHandle(pt->th_wait);
    }
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
    HANDLE h_thread;
    SRWLOCK ref_lock;
    int refs;
} win_udp_t;

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
    if (buf == NULL) {
        push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
        return 0;
    }
    WSAEVENT waits[2] = { u->ev_io, u->ev_stop };
    for (;;) {
        DWORD wr = WSAWaitForMultipleEvents(2, waits, FALSE, INFINITE, FALSE);
        if (wr == WSA_WAIT_EVENT_0 + 1 || wr == WSA_WAIT_FAILED) {
            break;
        }
        WSAResetEvent(u->ev_io);
        for (;;) {
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
                sth_push_sys_bounded(u->event_id, msg, total);
                free(msg);
            }
        }
    }
    free(buf);
    push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
    return 0;
}

int64_t sts_udp_bind(uint64_t event_id, const char *addr, int32_t port, int64_t *out_port) {
    ensure_wsa();
    const char *bind_addr = (addr != NULL && addr[0] != '\0') ? addr : "0.0.0.0";
    int is_v6 = strchr(bind_addr, ':') != NULL;
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
        if (inet_pton(AF_INET6, bind_addr, &s6->sin6_addr) != 1) {
            closesocket(s);
            return -1;
        }
        slen = (int)sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, bind_addr, &s4->sin_addr) != 1) {
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
    u->h_thread = CreateThread(NULL, 0, win_udp_recv_thread, u, 0, NULL);
    if (u->h_thread == NULL) {
        win_udp_unref(u);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_UDP, u);
    if (id < 0) {
        WSASetEvent(u->ev_stop);
        WaitForSingleObject(u->h_thread, INFINITE);
        CloseHandle(u->h_thread);
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
    return -(werr > 0 ? werr : 1);
}

int32_t sts_udp_close(int64_t handle) {
    win_udp_t *u = (win_udp_t *)ht_take(STS_HK_UDP, handle);
    if (u == NULL) return 0;
    WSASetEvent(u->ev_stop);
    WaitForSingleObject(u->h_thread, INFINITE);
    CloseHandle(u->h_thread);
    win_udp_unref(u);
    return 1;
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
    if (name == NULL || name[0] == '\0') {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    wchar_t *wn = utf8_to_wide(name);
    if (wn == NULL) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    DWORD need = GetEnvironmentVariableW(wn, NULL, 0);
    if (need == 0 && GetLastError() == ERROR_ENVVAR_NOT_FOUND) {
        free(wn);
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    wchar_t *wv = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)(need + 1));
    if (wv == NULL) {
        free(wn);
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    GetEnvironmentVariableW(wn, wv, need + 1);
    free(wn);
    char *s = wide_to_utf8(wv);
    free(wv);
    if (s == NULL) {
        if (out_len != NULL) *out_len = 0;
        return NULL;
    }
    if (out_len != NULL) *out_len = (int64_t)strlen(s);
    return s;
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

static void child_dup2_stdio(int src, int dst) {
    if (src < 0) return;
    if (src == dst) {
        fcntl(dst, F_SETFD, 0);
    } else {
        dup2(src, dst);
    }
}

static int make_wakeup_pipe(int fds[2]) {
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
    if (pipe(fds) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
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
        default:      return "SIGUNKNOWN";
    }
}

// Wait for child `pid` to exit OR `wake_fd` to become readable (zero polling).
// Returns 1 if child exited (status written to `*out_status`), 0 if woken early.
static int wait_pid_or_wake(pid_t pid, int wake_fd, int *out_status) {
#if defined(__linux__) && defined(__NR_pidfd_open)
    int pidfd = (int)syscall(__NR_pidfd_open, pid, 0);
    if (pidfd >= 0) {
        fcntl(pidfd, F_SETFD, FD_CLOEXEC);
        struct pollfd pfds[2];
        pfds[0].fd = pidfd;
        pfds[0].events = POLLIN;
        pfds[1].fd = wake_fd;
        pfds[1].events = POLLIN;
        for (;;) {
            pfds[0].revents = 0;
            pfds[1].revents = 0;
            int rc = poll(pfds, 2, -1);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0) {
                close(pidfd);
                return 0;
            }
            if (pfds[0].revents != 0) {
                close(pidfd);
                int st = 0;
                pid_t wr;
                do {
                    wr = waitpid(pid, &st, 0);
                } while (wr < 0 && errno == EINTR);
                if (out_status != NULL) *out_status = st;
                return wr == pid ? 1 : 0;
            }
            if (pfds[1].revents != 0) {
                close(pidfd);
                return 0;
            }
        }
    }
    // ESRCH means child already exited before pidfd_open; reap it immediately.
    int st = 0;
    pid_t wr;
    do {
        wr = waitpid(pid, &st, 0);
    } while (wr < 0 && errno == EINTR);
    if (out_status != NULL) *out_status = st;
    return wr == pid ? 1 : 0;
#elif defined(__APPLE__)
    int kq = kqueue();
    if (kq >= 0) {
        fcntl(kq, F_SETFD, FD_CLOEXEC);
        struct kevent evs[2];
        EV_SET(&evs[0], (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        EV_SET(&evs[1], (uintptr_t)wake_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
        if (kevent(kq, evs, 2, NULL, 0, NULL) == 0) {
            for (;;) {
                struct kevent out;
                int n = kevent(kq, NULL, 0, &out, 1, NULL);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) {
                    close(kq);
                    return 0;
                }
                if (out.filter == EVFILT_PROC) {
                    close(kq);
                    int st = 0;
                    pid_t wr;
                    do {
                        wr = waitpid(pid, &st, 0);
                    } while (wr < 0 && errno == EINTR);
                    if (out_status != NULL) *out_status = st;
                    return wr == pid ? 1 : 0;
                }
                if (out.filter == EVFILT_READ) {
                    close(kq);
                    return 0;
                }
            }
        }
        close(kq);
    }
    int st = 0;
    pid_t wr;
    do {
        wr = waitpid(pid, &st, 0);
    } while (wr < 0 && errno == EINTR);
    if (out_status != NULL) *out_status = st;
    return wr == pid ? 1 : 0;
#else
    (void)wake_fd;
    int st = 0;
    pid_t wr;
    do {
        wr = waitpid(pid, &st, 0);
    } while (wr < 0 && errno == EINTR);
    if (out_status != NULL) *out_status = st;
    return wr == pid ? 1 : 0;
#endif
}

// ---------------------------------------------------------------------------
// 1. POSIX Non-Recursive Directory fs.watch
// ---------------------------------------------------------------------------

#ifdef __APPLE__
typedef struct {
    char *name;
    ino_t ino;
    off_t size;
    time_t mtime_sec;
    long mtime_nsec;
} dir_entry_t;

typedef struct {
    dir_entry_t *items;
    size_t len;
    size_t cap;
} dir_snap_t;

static void dir_snap_free(dir_snap_t *s) {
    for (size_t i = 0; i < s->len; i++) {
        free(s->items[i].name);
    }
    free(s->items);
    s->items = NULL;
    s->len = s->cap = 0;
}

static void dir_snap_take(const char *dir_path, dir_snap_t *out) {
    out->items = NULL;
    out->len = 0;
    out->cap = 0;
    DIR *d = opendir(dir_path);
    if (d == NULL) return;
    struct dirent *ent = NULL;
    size_t dlen = strlen(dir_path);
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        size_t nlen = strlen(ent->d_name);
        char *full = (char *)malloc(dlen + 1 + nlen + 1);
        if (full == NULL) continue;
        memcpy(full, dir_path, dlen);
        full[dlen] = '/';
        memcpy(full + dlen + 1, ent->d_name, nlen + 1);
        struct stat st;
        int ok = (lstat(full, &st) == 0);
        free(full);
        if (!ok) continue;
        if (out->len == out->cap) {
            size_t ncap = out->cap == 0 ? 16 : out->cap * 2;
            dir_entry_t *ni = (dir_entry_t *)realloc(out->items, ncap * sizeof(*ni));
            if (ni == NULL) break;
            out->items = ni;
            out->cap = ncap;
        }
        out->items[out->len].name = sts_strdup(ent->d_name);
        out->items[out->len].ino = st.st_ino;
        out->items[out->len].size = st.st_size;
        out->items[out->len].mtime_sec = st.st_mtimespec.tv_sec;
        out->items[out->len].mtime_nsec = st.st_mtimespec.tv_nsec;
        out->len += 1;
    }
    closedir(d);
}

static const dir_entry_t *dir_snap_find(const dir_snap_t *s, const char *name) {
    for (size_t i = 0; i < s->len; i++) {
        if (s->items[i].name != NULL && strcmp(s->items[i].name, name) == 0) {
            return &s->items[i];
        }
    }
    return NULL;
}

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
    char *dir_path;
    char *file_basename; // non-NULL when watching a single file
    int is_file;
    int kq;
    int dir_fd;
    int wake[2];
    dir_snap_t snap;
    pthread_t thread;
} posix_fsw_t;

static void *posix_fsw_thread(void *arg) {
    posix_fsw_t *w = (posix_fsw_t *)arg;

    for (;;) {
        struct kevent ev;
        int n = kevent(w->kq, NULL, 0, &ev, 1, NULL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        if (ev.filter == EVFILT_READ && (int)ev.ident == w->wake[0]) {
            break;
        }
        if (ev.filter == EVFILT_VNODE) {
            if (w->is_file) {
                uint8_t kind = (ev.fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) ? STS_FS_RENAME : STS_FS_CHANGE;
                emit_fs_event(w->event_id, kind, w->file_basename != NULL ? w->file_basename : "");
                continue;
            }
            dir_snap_t next;
            dir_snap_take(w->dir_path, &next);
            int emitted = 0;
            for (size_t i = 0; i < next.len; i++) {
                const dir_entry_t *prev = dir_snap_find(&w->snap, next.items[i].name);
                if (prev == NULL) {
                    emit_fs_event(w->event_id, STS_FS_RENAME, next.items[i].name);
                    emitted = 1;
                } else if (prev->ino != next.items[i].ino) {
                    emit_fs_event(w->event_id, STS_FS_RENAME, next.items[i].name);
                    emitted = 1;
                } else if (prev->size != next.items[i].size ||
                           prev->mtime_sec != next.items[i].mtime_sec ||
                           prev->mtime_nsec != next.items[i].mtime_nsec) {
                    emit_fs_event(w->event_id, STS_FS_CHANGE, next.items[i].name);
                    emitted = 1;
                }
            }
            for (size_t i = 0; i < w->snap.len; i++) {
                if (dir_snap_find(&next, w->snap.items[i].name) == NULL) {
                    emit_fs_event(w->event_id, STS_FS_RENAME, w->snap.items[i].name);
                    emitted = 1;
                }
            }
            if (!emitted) {
                emit_fs_event(w->event_id, (ev.fflags & (NOTE_DELETE | NOTE_RENAME)) ? STS_FS_RENAME : STS_FS_CHANGE, "");
            }
            dir_snap_free(&w->snap);
            w->snap = next;
        }
    }
    dir_snap_free(&w->snap);
    push_tag_ctrl(w->event_id, STS_EV_FS_CLOSED, NULL, 0);
    return NULL;
}

int64_t sts_fs_watch_open(uint64_t event_id, const char *path) {
    if (path == NULL || path[0] == '\0') return -1;
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    int is_file = !S_ISDIR(st.st_mode);
    int target_fd = open(path, O_EVTONLY | O_CLOEXEC);
    if (target_fd < 0) return -1;
    int kq = kqueue();
    if (kq < 0) {
        close(target_fd);
        return -1;
    }
    fcntl(kq, F_SETFD, FD_CLOEXEC);
    posix_fsw_t *w = (posix_fsw_t *)calloc(1, sizeof(*w));
    if (w == NULL) {
        close(kq);
        close(target_fd);
        return -1;
    }
    w->event_id = event_id;
    w->dir_path = sts_strdup(path);
    w->is_file = is_file;
    w->file_basename = is_file ? sts_strdup(path_basename(path)) : NULL;
    w->kq = kq;
    w->dir_fd = target_fd;
    w->wake[0] = w->wake[1] = -1;
    if (w->dir_path == NULL || (is_file && w->file_basename == NULL) || make_wakeup_pipe(w->wake) != 0) {
        free(w->dir_path);
        free(w->file_basename);
        close(kq);
        close(target_fd);
        free(w);
        return -1;
    }
    if (!is_file) {
        dir_snap_take(w->dir_path, &w->snap);
    }
    struct kevent evs[2];
    EV_SET(&evs[0], (uintptr_t)target_fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND | NOTE_REVOKE, 0, NULL);
    EV_SET(&evs[1], (uintptr_t)w->wake[0], EVFILT_READ, EV_ADD, 0, 0, NULL);
    if (kevent(kq, evs, 2, NULL, 0, NULL) != 0 ||
        pthread_create(&w->thread, NULL, posix_fsw_thread, w) != 0) {
        dir_snap_free(&w->snap);
        close_fd_pair(w->wake);
        close(kq);
        close(target_fd);
        free(w->dir_path);
        free(w->file_basename);
        free(w);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_FS_WATCH, w);
    if (id < 0) {
        wake_pipe_signal(w->wake[1]);
        pthread_join(w->thread, NULL);
        close_fd_pair(w->wake);
        close(kq);
        close(target_fd);
        free(w->dir_path);
        free(w->file_basename);
        free(w);
    }
    return id;
}

int32_t sts_fs_watch_close(int64_t handle) {
    posix_fsw_t *w = (posix_fsw_t *)ht_take(STS_HK_FS_WATCH, handle);
    if (w == NULL) return 0;
    wake_pipe_signal(w->wake[1]);
    pthread_join(w->thread, NULL);
    close_fd_pair(w->wake);
    close(w->kq);
    close(w->dir_fd);
    free(w->dir_path);
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
                    if (!(ev->mask & IN_IGNORED)) {
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

    int stdin_fd;
    int stdin_wake[2];
    pthread_mutex_t stdin_lock;
    sts_chunk_t *stdin_head;
    sts_chunk_t *stdin_tail;
    size_t stdin_queued;
    int stdin_eof;
    int stdin_aborted;
    int has_stdin_th;
    pthread_t th_stdin;

    int stdout_fd;
    int stderr_fd;
    int pipes_wake[2];
    int has_pipes_th;
    pthread_t th_pipes;

    int wait_wake[2];
    int has_wait_th;
    pthread_t th_wait;

    pthread_mutex_t ref_lock;
    int refs;
} posix_proc_t;

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
    close_fd_pair(p->wait_wake);
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
    if (buf == NULL) return NULL;
    int fds[2] = { p->stdout_fd, p->stderr_fd };
    int open_cnt = (fds[0] >= 0) + (fds[1] >= 0);

    while (open_cnt > 0) {
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
                push_tag_ctrl(p->event_id, idx == 0 ? STS_EV_PROC_STDOUT_EOF : STS_EV_PROC_STDERR_EOF, NULL, 0);
            } else {
                buf[0] = (uint8_t)(idx == 0 ? STS_EV_PROC_STDOUT : STS_EV_PROC_STDERR);
                sth_push_sys_bounded(p->event_id, buf, (size_t)got + 1);
            }
        }
    }
    free(buf);
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
    return NULL;
}

static void *posix_wait_thread(void *arg) {
    posix_proc_t *p = (posix_proc_t *)arg;
    int status = 0;
    if (wait_pid_or_wake(p->pid, p->wait_wake[0], &status)) {
        pthread_mutex_lock(&p->stdin_lock);
        p->stdin_aborted = 1;
        pthread_mutex_unlock(&p->stdin_lock);
        wake_pipe_signal(p->stdin_wake[1]);

        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            push_exit_event(p->event_id, STS_EV_PROC_EXIT, -1, (int32_t)sig, posix_signal_name(sig));
        } else {
            push_exit_event(p->event_id, STS_EV_PROC_EXIT, (int32_t)WEXITSTATUS(status), 0, "");
        }
    }
    return NULL;
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
    argv[k++] = sts_strdup(program);
    if (args_nul != NULL && args_len > 0) {
        int64_t i = 0;
        while (i < args_len) {
            const char *a = (const char *)(args_nul + i);
            size_t n = strnlen(a, (size_t)(args_len - i));
            char *copy = (char *)malloc(n + 1);
            if (copy != NULL) {
                memcpy(copy, a, n);
                copy[n] = '\0';
            }
            argv[k++] = copy;
            i += (int64_t)n + 1;
        }
    }
    argv[k] = NULL;
    return argv;
}

static char **build_envp(const uint8_t *env_nul, int64_t env_len, int strip_mse) {
    if ((env_nul == NULL || env_len <= 0) && !strip_mse) {
        return NULL;
    }
    size_t cap = 32;
    size_t len = 0;
    char **envp = (char **)calloc(cap, sizeof(char *));
    if (envp == NULL) return NULL;

    if (env_nul != NULL && env_len > 0) {
        int64_t i = 0;
        while (i < env_len) {
            const char *e = (const char *)(env_nul + i);
            size_t n = strnlen(e, (size_t)(env_len - i));
            if (n > 0) {
                char *copy = (char *)malloc(n + 1);
                if (copy != NULL) {
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
                                break;
                            }
                            envp = grown;
                        }
                        envp[len++] = copy;
                    }
                }
            }
            i += (int64_t)n + 1;
        }
    } else if (environ != NULL) {
        for (char **e = environ; *e != NULL; e++) {
            if (strip_mse && is_malloc_se_entry(*e)) continue;
            if (len + 2 > cap) {
                cap *= 2;
                char **grown = (char **)realloc(envp, cap * sizeof(char *));
                if (grown == NULL) break;
                envp = grown;
            }
            envp[len++] = sts_strdup(*e);
        }
    }
    envp[len] = NULL;
    return envp;
}

static void free_str_vec(char **v) {
    if (v == NULL) return;
    for (size_t i = 0; v[i] != NULL; i++) {
        free(v[i]);
    }
    free(v);
}

static char *resolve_program(const char *program, char **envp) {
    if (strchr(program, '/') != NULL) {
        return sts_strdup(program);
    }
    const char *path = NULL;
    if (envp != NULL) {
        for (char **e = envp; *e != NULL; e++) {
            if (strncmp(*e, "PATH=", 5) == 0) {
                path = *e + 5;
                break;
            }
        }
    } else {
        path = getenv("PATH");
    }
    if (path == NULL) path = "/usr/bin:/bin";
    size_t pl = strlen(program);
    while (*path != '\0') {
        const char *end = strchr(path, ':');
        size_t dl = end != NULL ? (size_t)(end - path) : strlen(path);
        char *full = (char *)malloc((dl > 0 ? dl : 1) + 1 + pl + 1);
        if (full == NULL) break;
        if (dl == 0) {
            full[0] = '.';
            dl = 1;
        } else {
            memcpy(full, path, dl);
        }
        full[dl] = '/';
        memcpy(full + dl + 1, program, pl + 1);
        if (access(full, X_OK) == 0) {
            return full;
        }
        free(full);
        if (end == NULL) break;
        path = end + 1;
    }
    return sts_strdup(program);
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
    char **argv = build_argv(program, args_nul, args_len);
    char **envp = build_envp(env_nul, env_len, (flags & STS_PROC_STRIP_MALLOC_SE) != 0);
    char *exec_path = resolve_program(program, envp);
    const char *dir = (cwd != NULL && cwd[0] != '\0') ? cwd : NULL;

    int in_p[2] = { -1, -1 }, out_p[2] = { -1, -1 }, err_p[2] = { -1, -1 }, rep_p[2] = { -1, -1 };
    int fail = 0;
    if ((flags & STS_PROC_PIPE_STDIN) && cloexec_pipe(in_p) != 0) fail = errno;
    if (!fail && (flags & STS_PROC_PIPE_STDOUT) && cloexec_pipe(out_p) != 0) fail = errno;
    if (!fail && (flags & STS_PROC_PIPE_STDERR) && cloexec_pipe(err_p) != 0) fail = errno;
    if (!fail && cloexec_pipe(rep_p) != 0) fail = errno;

    pid_t pid = -1;
    if (!fail) pid = fork();
    if (pid == 0) {
        if (flags & STS_PROC_NEW_PGID) {
            setpgid(0, 0);
        }
        int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
        child_dup2_stdio(in_p[0] >= 0 ? in_p[0] : null_fd, 0);
        child_dup2_stdio(out_p[1] >= 0 ? out_p[1] : null_fd, 1);
        child_dup2_stdio(err_p[1] >= 0 ? err_p[1] : null_fd, 2);
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
            waitpid(pid, &st, 0);
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
        if (in_p[1] >= 0) close(in_p[1]);
        if (out_p[0] >= 0) close(out_p[0]);
        if (err_p[0] >= 0) close(err_p[0]);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    p->event_id = event_id;
    p->pid = pid;
    p->stdin_fd = in_p[1];
    p->stdout_fd = out_p[0];
    p->stderr_fd = err_p[0];
    p->stdin_wake[0] = p->stdin_wake[1] = -1;
    p->pipes_wake[0] = p->pipes_wake[1] = -1;
    p->wait_wake[0] = p->wait_wake[1] = -1;
    pthread_mutex_init(&p->stdin_lock, NULL);
    pthread_mutex_init(&p->ref_lock, NULL);
    p->refs = 1;

    if (p->stdin_fd >= 0) {
        int fl = fcntl(p->stdin_fd, F_GETFL, 0);
        if (fl >= 0) fcntl(p->stdin_fd, F_SETFL, fl | O_NONBLOCK);
        if (make_wakeup_pipe(p->stdin_wake) == 0 &&
            pthread_create(&p->th_stdin, NULL, posix_stdin_thread, p) == 0) {
            p->has_stdin_th = 1;
        }
    }
    if (p->stdout_fd >= 0 || p->stderr_fd >= 0) {
        if (make_wakeup_pipe(p->pipes_wake) == 0 &&
            pthread_create(&p->th_pipes, NULL, posix_pipes_thread, p) == 0) {
            p->has_pipes_th = 1;
        }
    }
    if (make_wakeup_pipe(p->wait_wake) == 0 &&
        pthread_create(&p->th_wait, NULL, posix_wait_thread, p) == 0) {
        p->has_wait_th = 1;
    }

    int64_t id = ht_insert(STS_HK_PROC, p);
    if (id < 0) {
        pthread_mutex_lock(&p->stdin_lock);
        p->stdin_aborted = 1;
        pthread_mutex_unlock(&p->stdin_lock);
        wake_pipe_signal(p->stdin_wake[1]);
        wake_pipe_signal(p->pipes_wake[1]);
        wake_pipe_signal(p->wait_wake[1]);
        if (p->has_stdin_th) pthread_join(p->th_stdin, NULL);
        if (p->has_pipes_th) pthread_join(p->th_pipes, NULL);
        if (p->has_wait_th) pthread_join(p->th_wait, NULL);
        posix_proc_unref(p);
        copy_err(err_buf, err_cap, "oom");
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

int32_t sts_proc_close(int64_t handle) {
    posix_proc_t *p = (posix_proc_t *)ht_take(STS_HK_PROC, handle);
    if (p == NULL) return 0;
    pthread_mutex_lock(&p->stdin_lock);
    p->stdin_aborted = 1;
    pthread_mutex_unlock(&p->stdin_lock);
    wake_pipe_signal(p->stdin_wake[1]);
    wake_pipe_signal(p->pipes_wake[1]);
    wake_pipe_signal(p->wait_wake[1]);
    if (p->has_stdin_th) pthread_join(p->th_stdin, NULL);
    if (p->has_pipes_th) pthread_join(p->th_pipes, NULL);
    if (p->has_wait_th) pthread_join(p->th_wait, NULL);
    posix_proc_unref(p);
    return 1;
}

int32_t sts_proc_kill(int32_t pid, int32_t sig, int32_t group) {
    if (pid <= 0) return -1;
    int rc = kill(group ? -(pid_t)pid : (pid_t)pid, posix_signal_of(sig));
    return rc == 0 ? 0 : -errno;
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
                    size_t ll = line.len;
                    if (ll > 0 && line.data[ll - 1] == '\r') ll -= 1;
                    push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data ? line.data : "", ll);
                    line.len = 0;
                } else {
                    sb_add(&line, buf + i, 1);
                }
            }
        }
    }
    if (eof) {
        if (line.len > 0) {
            size_t ll = line.len;
            if (line.data[ll - 1] == '\r') ll -= 1;
            push_tag_ctrl(c->event_id, STS_EV_CTRL_LINE, line.data, ll);
        }
        push_tag_ctrl(c->event_id, STS_EV_CTRL_EOF, NULL, 0);
    }
    free(line.data);
    return NULL;
}

int64_t sts_ctrl_open_fd(uint64_t event_id, int32_t fd) {
    if (fd < 0) return -1;
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

static const int k_watched_sigs[5] = { SIGTERM, SIGINT, SIGUSR1, SIGUSR2, SIGHUP };
static pthread_mutex_t g_sig_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_sig_active = 0;
static uint64_t g_sig_event_id = 0;
static int g_sig_pipe[2] = { -1, -1 };
static int g_sig_wake[2] = { -1, -1 };
static _Atomic int g_sig_wr_fd = -1;
static _Atomic int g_sig_inflight = 0;
static struct sigaction g_prev_sa[5];
static pthread_t g_sig_thread;

static void posix_on_signal(int sig) {
    int saved = errno;
    atomic_fetch_add_explicit(&g_sig_inflight, 1, memory_order_acq_rel);
    int fd = atomic_load_explicit(&g_sig_wr_fd, memory_order_acquire);
    if (fd >= 0) {
        uint8_t s = (uint8_t)sig;
        if (write(fd, &s, 1) < 0) {}
    }
    atomic_fetch_sub_explicit(&g_sig_inflight, 1, memory_order_release);
    errno = saved;
}

static void *posix_sig_thread(void *arg) {
    uint64_t eid = *(uint64_t *)arg;
    free(arg);
    struct pollfd pfds[2];
    pfds[0].fd = g_sig_pipe[0];
    pfds[0].events = POLLIN;
    pfds[1].fd = g_sig_wake[0];
    pfds[1].events = POLLIN;

    for (;;) {
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        int rc = poll(pfds, 2, -1);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || pfds[1].revents != 0) break;
        if (pfds[0].revents & POLLIN) {
            uint8_t s = 0;
            while (read(g_sig_pipe[0], &s, 1) == 1) {
                const char *name = posix_signal_name((int)s);
                size_t nlen = strlen(name);
                uint8_t msg[64];
                msg[0] = STS_EV_SIGNAL;
                put_i32_le(msg + 1, (int32_t)s);
                memcpy(msg + 5, name, nlen);
                sth_push_sys(eid, msg, 5 + nlen);
            }
        }
    }
    return NULL;
}

int32_t sts_signal_watch(uint64_t event_id) {
    pthread_mutex_lock(&g_sig_mu);
    if (g_sig_active) {
        pthread_mutex_unlock(&g_sig_mu);
        sts_signal_unwatch();
        pthread_mutex_lock(&g_sig_mu);
    }
    if (make_wakeup_pipe(g_sig_pipe) != 0) {
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    if (make_wakeup_pipe(g_sig_wake) != 0) {
        close_fd_pair(g_sig_pipe);
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    uint64_t *arg = (uint64_t *)malloc(sizeof(*arg));
    if (arg == NULL) {
        close_fd_pair(g_sig_pipe);
        close_fd_pair(g_sig_wake);
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    *arg = event_id;
    atomic_store_explicit(&g_sig_wr_fd, g_sig_pipe[1], memory_order_release);
    if (pthread_create(&g_sig_thread, NULL, posix_sig_thread, arg) != 0) {
        free(arg);
        atomic_store_explicit(&g_sig_wr_fd, -1, memory_order_release);
        close_fd_pair(g_sig_pipe);
        close_fd_pair(g_sig_wake);
        pthread_mutex_unlock(&g_sig_mu);
        return 0;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = posix_on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    for (int i = 0; i < 5; i++) {
        sigaction(k_watched_sigs[i], &sa, &g_prev_sa[i]);
    }
    g_sig_event_id = event_id;
    g_sig_active = 1;
    pthread_mutex_unlock(&g_sig_mu);
    return 1;
}

int32_t sts_signal_unwatch(void) {
    pthread_mutex_lock(&g_sig_mu);
    if (!g_sig_active) {
        pthread_mutex_unlock(&g_sig_mu);
        return 1;
    }
    for (int i = 0; i < 5; i++) {
        sigaction(k_watched_sigs[i], &g_prev_sa[i], NULL);
    }
    atomic_store_explicit(&g_sig_wr_fd, -1, memory_order_release);
    while (atomic_load_explicit(&g_sig_inflight, memory_order_acquire) > 0) {
        sched_yield();
    }
    wake_pipe_signal(g_sig_wake[1]);
    pthread_t th = g_sig_thread;
    g_sig_active = 0;
    pthread_mutex_unlock(&g_sig_mu);

    pthread_join(th, NULL);

    pthread_mutex_lock(&g_sig_mu);
    close_fd_pair(g_sig_pipe);
    close_fd_pair(g_sig_wake);
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
    int master_fd;
    int read_wake[2];
    int wait_wake[2];
    int has_read_th;
    int has_wait_th;
    pthread_t th_read;
    pthread_t th_wait;
    pthread_mutex_t write_lock;
    pthread_mutex_t ref_lock;
    int refs;
} posix_pty_t;

static void posix_pty_unref(posix_pty_t *pt) {
    pthread_mutex_lock(&pt->ref_lock);
    int last = (--pt->refs == 0);
    pthread_mutex_unlock(&pt->ref_lock);
    if (!last) return;
    if (pt->master_fd >= 0) close(pt->master_fd);
    close_fd_pair(pt->read_wake);
    close_fd_pair(pt->wait_wake);
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
    uint8_t *buf = (uint8_t *)malloc(1 + 65536);
    if (buf == NULL) return NULL;
    buf[0] = STS_EV_PTY_DATA;
    struct pollfd pfds[2];
    pfds[0].fd = pt->master_fd;
    pfds[0].events = POLLIN;
    pfds[1].fd = pt->read_wake[0];
    pfds[1].events = POLLIN;

    for (;;) {
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        int rc = poll(pfds, 2, -1);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || pfds[1].revents != 0) break;
        if (pfds[0].revents != 0) {
            ssize_t got = read(pt->master_fd, buf + 1, 65536);
            if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (got <= 0) {
                push_tag_ctrl(pt->event_id, STS_EV_PTY_EOF, NULL, 0);
                break;
            }
            sth_push_sys_bounded(pt->event_id, buf, (size_t)got + 1);
        }
    }
    free(buf);
    return NULL;
}

static void *posix_pty_wait_thread(void *arg) {
    posix_pty_t *pt = (posix_pty_t *)arg;
    int status = 0;
    if (wait_pid_or_wake(pt->pid, pt->wait_wake[0], &status)) {
        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            push_exit_event(pt->event_id, STS_EV_PTY_EXIT, -1, (int32_t)sig, posix_signal_name(sig));
        } else {
            push_exit_event(pt->event_id, STS_EV_PTY_EXIT, (int32_t)WEXITSTATUS(status), 0, "");
        }
    }
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
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);

    int master_fd = -1, slave_fd = -1;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) != 0) {
        char msg[256];
        posix_err_str(errno, msg, sizeof(msg));
        copy_err(err_buf, err_cap, msg);
        return -1;
    }
    fcntl(master_fd, F_SETFD, FD_CLOEXEC);
    fcntl(slave_fd, F_SETFD, FD_CLOEXEC);

    char **argv = build_argv(program, args_nul, args_len);
    char **envp = build_envp(env_nul, env_len, (flags & STS_PROC_STRIP_MALLOC_SE) != 0);
    char *exec_path = resolve_program(program, envp);
    const char *dir = (cwd != NULL && cwd[0] != '\0') ? cwd : NULL;

    int rep_p[2] = { -1, -1 };
    int fail = 0;
    if (cloexec_pipe(rep_p) != 0) fail = errno;

    pid_t pid = -1;
    if (!fail) pid = fork();
    if (pid == 0) {
        setsid();
        ioctl(slave_fd, TIOCSCTTY, 0);
        child_dup2_stdio(slave_fd, 0);
        child_dup2_stdio(slave_fd, 1);
        child_dup2_stdio(slave_fd, 2);
        close(master_fd);
        if (slave_fd > 2) close(slave_fd);
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
            waitpid(pid, &st, 0);
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
        close(master_fd);
        copy_err(err_buf, err_cap, "oom");
        return -1;
    }
    pt->event_id = event_id;
    pt->pid = pid;
    pt->master_fd = master_fd;
    pt->read_wake[0] = pt->read_wake[1] = -1;
    pt->wait_wake[0] = pt->wait_wake[1] = -1;
    pthread_mutex_init(&pt->write_lock, NULL);
    pthread_mutex_init(&pt->ref_lock, NULL);
    pt->refs = 1;

    if (make_wakeup_pipe(pt->read_wake) == 0 &&
        pthread_create(&pt->th_read, NULL, posix_pty_read_thread, pt) == 0) {
        pt->has_read_th = 1;
    }
    if (make_wakeup_pipe(pt->wait_wake) == 0 &&
        pthread_create(&pt->th_wait, NULL, posix_pty_wait_thread, pt) == 0) {
        pt->has_wait_th = 1;
    }
    int64_t id = ht_insert(STS_HK_PTY, pt);
    if (id < 0) {
        wake_pipe_signal(pt->read_wake[1]);
        wake_pipe_signal(pt->wait_wake[1]);
        if (pt->has_read_th) pthread_join(pt->th_read, NULL);
        if (pt->has_wait_th) pthread_join(pt->th_wait, NULL);
        posix_pty_unref(pt);
        copy_err(err_buf, err_cap, "oom");
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
    int rc = ioctl(pt->master_fd, TIOCSWINSZ, &ws);
    posix_pty_unref(pt);
    return rc == 0 ? 1 : 0;
}

int32_t sts_pty_kill(int64_t handle, int32_t sig) {
    posix_pty_t *pt = posix_pty_get(handle);
    if (pt == NULL) return 0;
    int rc = kill(-pt->pid, posix_signal_of(sig));
    posix_pty_unref(pt);
    return rc == 0 ? 1 : 0;
}

int32_t sts_pty_close(int64_t handle) {
    posix_pty_t *pt = (posix_pty_t *)ht_take(STS_HK_PTY, handle);
    if (pt == NULL) return 0;
    wake_pipe_signal(pt->read_wake[1]);
    wake_pipe_signal(pt->wait_wake[1]);
    if (pt->has_read_th) pthread_join(pt->th_read, NULL);
    if (pt->has_wait_th) pthread_join(pt->th_wait, NULL);
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
    pthread_t thread;
    pthread_mutex_t ref_lock;
    int refs;
} posix_udp_t;

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
    if (buf == NULL) {
        push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
        return NULL;
    }
    struct pollfd pfds[2];
    pfds[0].fd = u->sock;
    pfds[0].events = POLLIN;
    pfds[1].fd = u->wake[0];
    pfds[1].events = POLLIN;

    for (;;) {
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
                sth_push_sys_bounded(u->event_id, msg, total);
                free(msg);
            }
        }
    }
    free(buf);
    push_tag_ctrl(u->event_id, STS_EV_UDP_CLOSED, NULL, 0);
    return NULL;
}

int64_t sts_udp_bind(uint64_t event_id, const char *addr, int32_t port, int64_t *out_port) {
    const char *bind_addr = (addr != NULL && addr[0] != '\0') ? addr : "0.0.0.0";
    int is_v6 = strchr(bind_addr, ':') != NULL;
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
        if (inet_pton(AF_INET6, bind_addr, &s6->sin6_addr) != 1) {
            close(s);
            return -1;
        }
        slen = sizeof(*s6);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
        s4->sin_family = AF_INET;
        s4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, bind_addr, &s4->sin_addr) != 1) {
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
    pthread_mutex_init(&u->ref_lock, NULL);
    u->refs = 1;
    if (make_wakeup_pipe(u->wake) != 0 ||
        pthread_create(&u->thread, NULL, posix_udp_recv_thread, u) != 0) {
        posix_udp_unref(u);
        return -1;
    }
    int64_t id = ht_insert(STS_HK_UDP, u);
    if (id < 0) {
        wake_pipe_signal(u->wake[1]);
        pthread_join(u->thread, NULL);
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
    return -(err > 0 ? err : 1);
}

int32_t sts_udp_close(int64_t handle) {
    posix_udp_t *u = (posix_udp_t *)ht_take(STS_HK_UDP, handle);
    if (u == NULL) return 0;
    wake_pipe_signal(u->wake[1]);
    pthread_join(u->thread, NULL);
    posix_udp_unref(u);
    return 1;
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
