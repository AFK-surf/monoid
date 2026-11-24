// Cross-platform C11 filesystem shim for Pion `footprint` worker (POSIX + _WIN32).
// Mirrors station/mb/src/footprint/footprint.c semantics exactly:
// - lstat without following symlinks (dev, ino, nlink, 512-byte blocks; on Windows, fails explicitly
//   if FileAttributeTagInfo reparse-tag query fails instead of silently misclassifying)
// - readdir excluding "."/"..", sorted by strcmp on POSIX (matching libuv scandir)
// - exists / is_dir following symlinks (on Windows, sfp_is_dir opens the target handle with
//   FILE_FLAG_BACKUP_SEMANTICS so broken directory symlinks reliably return 0)
// - head: non-blocking regular-file-only read (O_NONBLOCK + fstat S_ISREG on POSIX;
//   FILE_TYPE_DISK + !DIRECTORY on Windows), never blocking on FIFOs or devices
// - monotonic millisecond clock for maxDurationMs budget

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "footprint_fs.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} sfp_names_t;

static int sfp_names_add(sfp_names_t *n, const char *s, size_t len) {
    if (n->len + len + 1 > n->cap) {
        size_t cap = n->cap == 0 ? 4096 : n->cap;
        while (n->len + len + 1 > cap) {
            if (cap > ((size_t)-1) / 2) {
                return -1;
            }
            cap *= 2;
        }
        char *grown = (char *)realloc(n->data, cap);
        if (grown == NULL) {
            return -1;
        }
        n->data = grown;
        n->cap = cap;
    }
    if (len > 0) {
        memcpy(n->data + n->len, s, len);
    }
    n->data[n->len + len] = '\0';
    n->len += len + 1;
    return 0;
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

static wchar_t *sfp_wide(const char *s, const wchar_t *suffix) {
    if (s == NULL) {
        return NULL;
    }
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) {
        return NULL;
    }
    size_t extra = suffix == NULL ? 0 : wcslen(suffix);
    if ((size_t)n > ((size_t)-1) / sizeof(wchar_t) - extra) {
        return NULL;
    }
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * ((size_t)n + extra));
    if (w == NULL) {
        return NULL;
    }
    int written = MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    if (written <= 0 || written > n) {
        free(w);
        return NULL;
    }
    if (suffix != NULL) {
        memcpy(w + (size_t)written - 1, suffix, (extra + 1) * sizeof(wchar_t));
    }
    return w;
}

static int32_t sfp_failed(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
        case ERROR_INVALID_NAME:
        case ERROR_BAD_NETPATH:
        case ERROR_BAD_PATHNAME:
        case ERROR_INVALID_DRIVE:
        case ERROR_MOD_NOT_FOUND:
            return SFP_ENOENT;
        case ERROR_ACCESS_DENIED:
        case ERROR_PRIVILEGE_NOT_HELD:
            return SFP_EPERM;
        case ERROR_NOACCESS:
        case ERROR_CANT_ACCESS_FILE:
            return SFP_EACCES;
        case ERROR_DIRECTORY:
            return SFP_ENOTDIR;
        case ERROR_CANT_RESOLVE_FILENAME:
            return SFP_ELOOP;
        case ERROR_FILENAME_EXCED_RANGE:
            return SFP_ENAMETOOLONG;
        default:
            return SFP_EIO;
    }
}

int32_t sfp_lstat(const char *path, int64_t *out5) {
    if (path == NULL || out5 == NULL) {
        return SFP_EIO;
    }
    wchar_t *w = sfp_wide(path, NULL);
    if (w == NULL) {
        return SFP_ENOENT;
    }
    HANDLE h = CreateFileW(
        w,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        return sfp_failed(GetLastError());
    }
    BY_HANDLE_FILE_INFORMATION info;
    FILE_STANDARD_INFO standard;
    if (!GetFileInformationByHandle(h, &info) ||
        !GetFileInformationByHandleEx(h, FileStandardInfo, &standard, sizeof(standard))) {
        DWORD e = GetLastError();
        CloseHandle(h);
        return sfp_failed(e);
    }
    int32_t kind = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? SFP_DIR : SFP_FILE;
    if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        FILE_ATTRIBUTE_TAG_INFO tag;
        if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof(tag))) {
            DWORD e = GetLastError();
            CloseHandle(h);
            return sfp_failed(e);
        }
        if (tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT) {
            kind = SFP_LINK;
        }
    }
    CloseHandle(h);
    out5[0] = (int64_t)kind;
    out5[1] = (int64_t)info.dwVolumeSerialNumber;
    out5[2] = (int64_t)(((uint64_t)info.nFileIndexHigh << 32) | (uint64_t)info.nFileIndexLow);
    out5[3] = (int64_t)info.nNumberOfLinks;
    out5[4] = (int64_t)(standard.AllocationSize.QuadPart >> 9);
    return SFP_OK;
}

void *sfp_readdir(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) {
        *out_len = 0;
    }
    if (out_err != NULL) {
        *out_err = SFP_OK;
    }
    if (path == NULL) {
        if (out_err != NULL) {
            *out_err = SFP_ENOENT;
        }
        return NULL;
    }
    sfp_names_t n = { NULL, 0, 0 };
    wchar_t *w = sfp_wide(path, L"\\*");
    if (w == NULL) {
        if (out_err != NULL) {
            *out_err = SFP_ENOENT;
        }
        return NULL;
    }
    WIN32_FIND_DATAW found;
    HANDLE h = FindFirstFileExW(w, FindExInfoBasic, &found, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        if (out_err != NULL) {
            *out_err = (e == ERROR_FILE_NOT_FOUND) ? SFP_ENOENT : sfp_failed(e);
        }
        return NULL;
    }
    int32_t err = SFP_OK;
    for (;;) {
        const wchar_t *name = found.cFileName;
        if (wcscmp(name, L".") != 0 && wcscmp(name, L"..") != 0) {
            int len = WideCharToMultiByte(CP_UTF8, 0, name, -1, NULL, 0, NULL, NULL);
            if (len <= 0) {
                err = SFP_EIO;
                break;
            }
            if (len > 1) {
                char *u = (char *)malloc((size_t)len);
                if (u == NULL) {
                    err = SFP_EIO;
                    break;
                }
                int written = WideCharToMultiByte(CP_UTF8, 0, name, -1, u, len, NULL, NULL);
                if (written <= 0 || written > len) {
                    free(u);
                    err = SFP_EIO;
                    break;
                }
                if (written > 1 && sfp_names_add(&n, u, (size_t)written - 1) != 0) {
                    free(u);
                    err = SFP_EIO;
                    break;
                }
                free(u);
            }
        }
        if (!FindNextFileW(h, &found)) {
            DWORD last_err = GetLastError();
            if (last_err != ERROR_NO_MORE_FILES) {
                err = sfp_failed(last_err);
            }
            break;
        }
    }
    FindClose(h);
    if (err != SFP_OK) {
        free(n.data);
        if (out_err != NULL) {
            *out_err = err;
        }
        return NULL;
    }
    if (out_len != NULL) {
        *out_len = (int64_t)n.len;
    }
    return n.data;
}

int32_t sfp_exists(const char *path) {
    wchar_t *w = sfp_wide(path, NULL);
    if (w == NULL) {
        return 0;
    }
    HANDLE h = CreateFileW(
        w,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        return 0;
    }
    CloseHandle(h);
    return 1;
}

int32_t sfp_is_dir(const char *path) {
    wchar_t *w = sfp_wide(path, NULL);
    if (w == NULL) {
        return 0;
    }
    HANDLE h = CreateFileW(
        w,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        return 0;
    }
    BY_HANDLE_FILE_INFORMATION info;
    int32_t is_dir = (GetFileInformationByHandle(h, &info) &&
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) ? 1 : 0;
    CloseHandle(h);
    return is_dir;
}

static long sfp_head_read(const char *path, char *buf, size_t most) {
    wchar_t *w = sfp_wide(path, NULL);
    if (w == NULL) {
        return -1;
    }
    HANDLE h = CreateFileW(
        w,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(h) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(h, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        CloseHandle(h);
        return -1;
    }
    size_t got = 0;
    while (got < most) {
        DWORD n = 0;
        if (!ReadFile(h, buf + got, (DWORD)(most - got), &n, NULL)) {
            CloseHandle(h);
            return -1;
        }
        if (n == 0) {
            break;
        }
        got += (size_t)n;
    }
    CloseHandle(h);
    return (long)got;
}

int64_t sfp_now_ms(void) {
    return (int64_t)GetTickCount64();
}

int32_t sfp_is_windows(void) {
    return 1;
}

#else

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int32_t sfp_failed(int e) {
    switch (e) {
        case ENOENT: return SFP_ENOENT;
        case EACCES: return SFP_EACCES;
        case EPERM: return SFP_EPERM;
        case ENOTDIR: return SFP_ENOTDIR;
        case ELOOP: return SFP_ELOOP;
        case ENAMETOOLONG: return SFP_ENAMETOOLONG;
        default: return SFP_EIO;
    }
}

int32_t sfp_lstat(const char *path, int64_t *out5) {
    if (path == NULL || out5 == NULL) {
        return SFP_EIO;
    }
    struct stat st;
    if (lstat(path, &st) != 0) {
        return sfp_failed(errno);
    }
    out5[0] = S_ISLNK(st.st_mode) ? SFP_LINK
            : S_ISDIR(st.st_mode) ? SFP_DIR
            : S_ISREG(st.st_mode) ? SFP_FILE
            : SFP_OTHER;
    out5[1] = (int64_t)st.st_dev;
    out5[2] = (int64_t)st.st_ino;
    out5[3] = (int64_t)st.st_nlink;
    out5[4] = (int64_t)st.st_blocks;
    return SFP_OK;
}

static int sfp_by_name(const void *a, const void *b) {
    const char *sa = *(const char *const *)a;
    const char *sb = *(const char *const *)b;
    return strcmp(sa, sb);
}

static char *sfp_strdup(const char *s) {
    size_t len = strlen(s);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, s, len + 1);
    return copy;
}

void *sfp_readdir(const char *path, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) {
        *out_len = 0;
    }
    if (out_err != NULL) {
        *out_err = SFP_OK;
    }
    if (path == NULL) {
        if (out_err != NULL) {
            *out_err = SFP_ENOENT;
        }
        return NULL;
    }
    DIR *d = opendir(path);
    if (d == NULL) {
        if (out_err != NULL) {
            *out_err = sfp_failed(errno);
        }
        return NULL;
    }
    char **all = NULL;
    size_t count = 0;
    size_t cap = 0;
    int32_t err = SFP_OK;
    struct dirent *e = NULL;
    for (;;) {
        errno = 0;
        e = readdir(d);
        if (e == NULL) {
            if (errno != 0) {
                err = sfp_failed(errno);
            }
            break;
        }
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        if (count == cap) {
            size_t next_cap = cap == 0 ? 64 : cap * 2;
            char **grown = (char **)realloc(all, sizeof(char *) * next_cap);
            if (grown == NULL) {
                err = SFP_EIO;
                break;
            }
            all = grown;
            cap = next_cap;
        }
        char *dup = sfp_strdup(e->d_name);
        if (dup == NULL) {
            err = SFP_EIO;
            break;
        }
        all[count++] = dup;
    }
    closedir(d);

    if (err == SFP_OK && count > 1) {
        qsort(all, count, sizeof(char *), sfp_by_name);
    }
    sfp_names_t n = { NULL, 0, 0 };
    for (size_t i = 0; i < count; i++) {
        if (err == SFP_OK) {
            if (sfp_names_add(&n, all[i], strlen(all[i])) != 0) {
                err = SFP_EIO;
            }
        }
        free(all[i]);
    }
    free(all);
    if (err != SFP_OK) {
        free(n.data);
        if (out_err != NULL) {
            *out_err = err;
        }
        return NULL;
    }
    if (out_len != NULL) {
        *out_len = (int64_t)n.len;
    }
    return n.data;
}

int32_t sfp_exists(const char *path) {
    if (path == NULL) {
        return 0;
    }
    struct stat st;
    return stat(path, &st) == 0 ? 1 : 0;
}

int32_t sfp_is_dir(const char *path) {
    if (path == NULL) {
        return 0;
    }
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) ? 1 : 0;
}

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif

static long sfp_head_read(const char *path, char *buf, size_t most) {
    if (path == NULL) {
        return -1;
    }
    int fd;
    do {
        fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    size_t got = 0;
    while (got < most) {
        ssize_t n = read(fd, buf + got, most - got);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return -1;
        }
        if (n == 0) {
            break;
        }
        got += (size_t)n;
    }
    close(fd);
    return (long)got;
}

int64_t sfp_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000L);
}

int32_t sfp_is_windows(void) {
    return 0;
}

#endif

void *sfp_head(const char *path, int32_t most, int64_t *out_len, int32_t *out_err) {
    if (out_len != NULL) {
        *out_len = 0;
    }
    if (out_err != NULL) {
        *out_err = 0;
    }
    char buf[4096];
    if (most > (int32_t)sizeof(buf)) {
        most = (int32_t)sizeof(buf);
    }
    if (most < 0) {
        most = 0;
    }
    long got = sfp_head_read(path, buf, (size_t)most);
    if (got < 0) {
        if (out_err != NULL) {
            *out_err = 1;
        }
        return NULL;
    }
    if (got == 0) {
        return NULL;
    }
    void *out = malloc((size_t)got);
    if (out == NULL) {
        if (out_err != NULL) {
            *out_err = 1;
        }
        return NULL;
    }
    memcpy(out, buf, (size_t)got);
    if (out_len != NULL) {
        *out_len = (int64_t)got;
    }
    return out;
}

void sfp_free(void *ptr) {
    free(ptr);
}
