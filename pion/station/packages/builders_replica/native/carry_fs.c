// Cross-platform C11 filesystem shim for Pion `builders_replica` (`replica-export`, `replica-carry`).
// 1:1 port of `station/mb/src/replica/carry.c` replacing MoonBit byte-array headers with Pion
// borrowed `const char *` (NUL-terminated UTF-8) and `const uint8_t * + int64_t byte_len`.

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "carry_fs.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>

static wchar_t *sfc_wide(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) {
        return NULL;
    }
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)n);
    if (w == NULL) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

static HANDLE sfc_opened(const char *path, DWORD access) {
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return INVALID_HANDLE_VALUE;
    }
    HANDLE h = CreateFileW(
        w,
        access,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL);
    DWORD err = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        SetLastError(err);
    }
    return h;
}
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#endif

int32_t sfc_open(const char *path, int32_t append) {
    if (path == NULL) {
        return -1;
    }
#ifdef _WIN32
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return -1;
    }
    int fd = _wopen(
        w,
        _O_WRONLY | _O_CREAT | _O_BINARY | (append ? _O_APPEND : _O_TRUNC),
        _S_IREAD | _S_IWRITE);
    free(w);
    return (int32_t)fd;
#else
    return (int32_t)open(
        path,
        O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC),
        0666);
#endif
}

int32_t sfc_write(int32_t fd, const uint8_t *data, int64_t byte_len) {
    if (byte_len < 0) {
        return -1;
    }
    if (byte_len == 0) {
        return 0;
    }
    if (data == NULL) {
        return -1;
    }
    size_t len = (size_t)byte_len;
    size_t done = 0;
    while (done < len) {
#ifdef _WIN32
        size_t rem = len - done;
        unsigned int chunk = rem > 0x40000000U ? 0x40000000U : (unsigned int)rem;
        int n = _write((int)fd, (const char *)data + done, chunk);
#else
        ssize_t n = write((int)fd, (const char *)data + done, len - done);
        if (n < 0 && errno == EINTR) {
            continue;
        }
#endif
        if (n <= 0) {
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

int32_t sfc_close(int32_t fd) {
#ifdef _WIN32
    return (int32_t)_close((int)fd);
#else
    return (int32_t)close((int)fd);
#endif
}

int32_t sfc_utimes(const char *path, double secs) {
    if (path == NULL) {
        return -1;
    }
#ifdef _WIN32
    HANDLE h = sfc_opened(path, FILE_WRITE_ATTRIBUTES);
    if (h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    int64_t ticks = (int64_t)(secs * 10000000.0) + 116444736000000000LL;
    FILETIME t;
    t.dwLowDateTime = (DWORD)(ticks & 0xFFFFFFFF);
    t.dwHighDateTime = (DWORD)((uint64_t)ticks >> 32);
    BOOL ok = SetFileTime(h, NULL, &t, &t);
    CloseHandle(h);
    return ok ? 0 : -1;
#else
    struct timespec ts[2];
    ts[0].tv_sec = (time_t)secs;
    ts[0].tv_nsec = (long)((secs - (double)ts[0].tv_sec) * 1e9);
    if (ts[0].tv_nsec < 0) {
        ts[0].tv_nsec += 1000000000L;
        ts[0].tv_sec -= 1;
    }
    ts[1] = ts[0];
    return utimensat(AT_FDCWD, path, ts, 0) == 0 ? 0 : -1;
#endif
}

int32_t sfc_nlink(const char *path) {
    if (path == NULL) {
        return -1;
    }
#ifdef _WIN32
    HANDLE h = sfc_opened(path, FILE_READ_ATTRIBUTES);
    if (h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    BY_HANDLE_FILE_INFORMATION info;
    BOOL ok = GetFileInformationByHandle(h, &info);
    CloseHandle(h);
    return ok ? (int32_t)info.nNumberOfLinks : -1;
#else
    struct stat st;
    if (lstat(path, &st) != 0) {
        return -1;
    }
    return (int32_t)st.st_nlink;
#endif
}

int32_t sfc_link(const char *from, const char *to) {
    if (from == NULL || to == NULL) {
        return 2;
    }
#ifdef _WIN32
    wchar_t *f = sfc_wide(from);
    wchar_t *t = sfc_wide(to);
    BOOL ok = f != NULL && t != NULL && CreateHardLinkW(t, f, NULL);
    DWORD e = ok ? 0 : GetLastError();
    free(f);
    free(t);
    if (ok) {
        return 0;
    }
    return (e == ERROR_NOT_SAME_DEVICE || e == ERROR_ACCESS_DENIED || e == ERROR_NOT_SUPPORTED ||
            e == ERROR_TOO_MANY_LINKS || e == ERROR_INVALID_FUNCTION)
               ? 1
               : 2;
#else
    if (link(from, to) == 0) {
        return 0;
    }
    int e = errno;
    return (e == EXDEV || e == EPERM || e == ENOTSUP || e == EMLINK || e == ENOSYS
#ifdef EOPNOTSUPP
            || e == EOPNOTSUPP
#endif
            )
               ? 1
               : 2;
#endif
}

int32_t sfc_denied(const char *path, int32_t dir) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    (void)dir;
    HANDLE h = sfc_opened(path, GENERIC_READ);
    if (h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
        return 0;
    }
    return GetLastError() == ERROR_ACCESS_DENIED ? 1 : 0;
#else
    if (dir) {
        DIR *d = opendir(path);
        if (d != NULL) {
            closedir(d);
            return 0;
        }
    } else {
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            return 0;
        }
    }
    return (errno == EACCES || errno == EPERM) ? 1 : 0;
#endif
}

int32_t sfc_missing(const char *path, int32_t follow) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return 0;
    }
    DWORD attr = GetFileAttributesW(w);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        DWORD e = GetLastError();
        free(w);
        return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
    }
    if (follow && (attr & FILE_ATTRIBUTE_REPARSE_POINT)) {
        HANDLE h = CreateFileW(
            w,
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            NULL);
        DWORD e = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
        if (h != INVALID_HANDLE_VALUE) {
            CloseHandle(h);
        }
        free(w);
        if (h != INVALID_HANDLE_VALUE) {
            return 0;
        }
        return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
    }
    free(w);
    return 0;
#else
    struct stat st;
    int rc = follow ? stat(path, &st) : lstat(path, &st);
    if (rc == 0) {
        return 0;
    }
    return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

int32_t sfc_dir_missing(const char *path) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return 0;
    }
    DWORD attr = GetFileAttributesW(w);
    DWORD e = (attr == INVALID_FILE_ATTRIBUTES) ? GetLastError() : 0;
    free(w);
    if (attr != INVALID_FILE_ATTRIBUTES) {
        return (attr & FILE_ATTRIBUTE_DIRECTORY) ? 0 : 1;
    }
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
#else
    DIR *d = opendir(path);
    if (d != NULL) {
        closedir(d);
        return 0;
    }
    return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

int32_t sfc_dir_readable(const char *path) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return 0;
    }
    HANDLE h = CreateFileW(
        w,
        FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL);
    DWORD e = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
    if (h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
    }
    free(w);
    if (h != INVALID_HANDLE_VALUE) {
        return 1;
    }
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME || e == ERROR_DIRECTORY)
               ? 1
               : 0;
#else
    DIR *d = opendir(path);
    if (d != NULL) {
        closedir(d);
        return 1;
    }
    return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

int32_t sfc_is_file(const char *path) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (n <= 0 || n >= MAX_PATH) {
        return -1;
    }
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return -1;
    }
    DWORD attr = GetFileAttributesW(w);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        DWORD e = GetLastError();
        free(w);
        return e == ERROR_FILENAME_EXCED_RANGE ? -1 : 0;
    }
    if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
        free(w);
        return (attr & FILE_ATTRIBUTE_DIRECTORY) == 0 ? 1 : 0;
    }
    HANDLE h = CreateFileW(
        w,
        0,
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
    int ok = GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) &&
             (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
    CloseHandle(h);
    return ok ? 1 : 0;
#else
    struct stat st;
    return (stat(path, &st) == 0 && S_ISREG(st.st_mode)) ? 1 : 0;
#endif
}

int32_t sfc_file_stamp(const char *path, uint8_t *out_buf, int32_t cap) {
    if (path == NULL || out_buf == NULL || cap <= 1) {
        return -1;
    }
#ifdef _WIN32
    int wn = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wn <= 0 || wn >= MAX_PATH) {
        return -1;
    }
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return -1;
    }
    HANDLE h = CreateFileW(
        w,
        FILE_READ_DATA | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    DWORD err = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND || err == ERROR_INVALID_NAME) ? 0 : -1;
    }
    BY_HANDLE_FILE_INFORMATION info;
    FILE_BASIC_INFO basic;
    BOOL ok = GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) &&
              (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
              GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic));
    CloseHandle(h);
    if (!ok) {
        return -1;
    }
    uint64_t fsize = ((uint64_t)info.nFileSizeHigh << 32) | (uint64_t)info.nFileSizeLow;
    uint64_t mtime = ((uint64_t)info.ftLastWriteTime.dwHighDateTime << 32) | (uint64_t)info.ftLastWriteTime.dwLowDateTime;
    uint64_t ctime = (uint64_t)basic.ChangeTime.QuadPart;
    int len = snprintf(
        (char *)out_buf,
        (size_t)cap,
        "%lu:%lu:%lu:%llu:%llu:%llu",
        (unsigned long)info.dwVolumeSerialNumber,
        (unsigned long)info.nFileIndexHigh,
        (unsigned long)info.nFileIndexLow,
        (unsigned long long)fsize,
        (unsigned long long)mtime,
        (unsigned long long)ctime);
    if (len <= 0 || len >= cap) {
        return -1;
    }
    FILETIME ft_now;
    GetSystemTimeAsFileTime(&ft_now);
    uint64_t now_100ns = ((uint64_t)ft_now.dwHighDateTime << 32) | (uint64_t)ft_now.dwLowDateTime;
    int is_racy = (now_100ns < ctime) || (now_100ns - ctime < 500000ULL);
    return is_racy ? 2 : 1;
#else
    struct stat st;
    if (stat(path, &st) != 0) {
        return (errno == ENOENT || errno == ENOTDIR) ? 0 : -1;
    }
    if (!S_ISREG(st.st_mode) || access(path, R_OK) != 0) {
        return -1;
    }
#ifdef __APPLE__
    int64_t m_sec = (int64_t)st.st_mtimespec.tv_sec;
    long m_nsec = st.st_mtimespec.tv_nsec;
    int64_t c_sec = (int64_t)st.st_ctimespec.tv_sec;
    long c_nsec = st.st_ctimespec.tv_nsec;
#else
    int64_t m_sec = (int64_t)st.st_mtim.tv_sec;
    long m_nsec = st.st_mtim.tv_nsec;
    int64_t c_sec = (int64_t)st.st_ctim.tv_sec;
    long c_nsec = st.st_ctim.tv_nsec;
#endif
    int len = snprintf(
        (char *)out_buf,
        (size_t)cap,
        "%llu:%llu:%lld:%lld:%ld:%lld:%ld:%u",
        (unsigned long long)st.st_dev,
        (unsigned long long)st.st_ino,
        (long long)st.st_size,
        (long long)m_sec,
        m_nsec,
        (long long)c_sec,
        c_nsec,
        (unsigned int)st.st_mode);
    if (len <= 0 || len >= cap) {
        return -1;
    }
    struct timespec now;
    int is_racy = 0;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
        is_racy = 1;
    } else {
        int64_t diff_sec = (int64_t)now.tv_sec - c_sec;
        if (diff_sec < 0) {
            is_racy = 1;
        } else if (diff_sec == 0) {
            if ((int64_t)now.tv_nsec - (int64_t)c_nsec < 50000000LL) {
                is_racy = 1;
            }
        } else if (diff_sec == 1) {
            if (1000000000LL + (int64_t)now.tv_nsec - (int64_t)c_nsec < 50000000LL) {
                is_racy = 1;
            }
        }
    }
    return is_racy ? 2 : 1;
#endif
}

int32_t sfc_file_fnv64(const char *path, uint64_t *out_hash) {
    if (path == NULL || out_hash == NULL) {
        return -1;
    }
    uint64_t h = 14695981039346656037ULL;
    uint8_t buf[65536];
#ifdef _WIN32
    int wn = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wn <= 0 || wn >= MAX_PATH) {
        return -1;
    }
    wchar_t *w = sfc_wide(path);
    if (w == NULL) {
        return -1;
    }
    HANDLE fh = CreateFileW(
        w,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    free(w);
    if (fh == INVALID_HANDLE_VALUE) {
        return -1;
    }
    for (;;) {
        DWORD got = 0;
        if (!ReadFile(fh, buf, (DWORD)sizeof(buf), &got, NULL)) {
            CloseHandle(fh);
            return -1;
        }
        if (got == 0) {
            break;
        }
        for (DWORD i = 0; i < got; i++) {
            h ^= (uint64_t)buf[i];
            h *= 1099511628211ULL;
        }
    }
    CloseHandle(fh);
#else
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
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
        for (ssize_t i = 0; i < n; i++) {
            h ^= (uint64_t)buf[i];
            h *= 1099511628211ULL;
        }
    }
    close(fd);
#endif
    uint8_t le[8];
    for (int i = 0; i < 8; i++) {
        le[i] = (uint8_t)((h >> (i * 8)) & 0xFFU);
    }
    memcpy(out_hash, le, sizeof(le));
    return 0;
}
