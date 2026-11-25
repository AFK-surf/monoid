// What the gathering and placing of a retired station's files (carry.mbt) ask of the system that the shell
// (client/shell) does not give: a file written a line at a time (a session's list, what a placing made), a file's
// times set as Node's utimesSync sets them, how many names a file has (lstat's nlink), a hard link that says why it
// could not be made, and whether what did not open was refused (EACCES, EPERM) rather than gone. Each path is UTF-8,
// ended by a NUL.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>

static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t *w = malloc(sizeof(wchar_t) * n);
  if (w != NULL) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static HANDLE opened(const char *path, DWORD access) {
  wchar_t *w = wide(path);
  if (w == NULL) return INVALID_HANDLE_VALUE;
  HANDLE h = CreateFileW(w, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(w);
  return h;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#endif

/// `path` opened for writing (made where it is not): appended to with `append`, else emptied first. Its descriptor, or
/// -1.
int sfc_open(moonbit_bytes_t path, int append) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return -1;
  int fd = _wopen(w, _O_WRONLY | _O_CREAT | _O_BINARY | (append ? _O_APPEND : _O_TRUNC), _S_IREAD | _S_IWRITE);
  free(w);
  return fd;
#else
  return open((const char *)path, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0666);
#endif
}

/// All of `data` written to `fd`: 0, or -1 where it could not be.
int sfc_write(int fd, moonbit_bytes_t data) {
  size_t len = Moonbit_array_length(data);
  size_t done = 0;
  while (done < len) {
#ifdef _WIN32
    int n = _write(fd, (const char *)data + done, (unsigned)(len - done));
#else
    ssize_t n = write(fd, (const char *)data + done, len - done);
    if (n < 0 && errno == EINTR) continue;
#endif
    if (n <= 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

int sfc_close(int fd) {
#ifdef _WIN32
  return _close(fd);
#else
  return close(fd);
#endif
}

/// `path`'s access and modification times set to `secs` (seconds since 1970) as Node's utimesSync(path, secs, secs)
/// sets them (libuv 1.53's uv__fs_to_timespec, to the nanosecond the double gives): 0, or -1.
int sfc_utimes(moonbit_bytes_t path, double secs) {
#ifdef _WIN32
  // (libuv's uv__fs_utime_w: 100 ns since 1601)
  HANDLE h = opened((const char *)path, FILE_WRITE_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) return -1;
  int64_t ticks = (int64_t)(secs * 10000000.0) + 116444736000000000LL;
  FILETIME t;
  t.dwLowDateTime = (DWORD)(ticks & 0xFFFFFFFF);
  t.dwHighDateTime = (DWORD)(ticks >> 32);
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
  return utimensat(AT_FDCWD, (const char *)path, ts, 0) == 0 ? 0 : -1;
#endif
}

/// How many names the file at `path` has (lstat's nlink, a link itself not followed); -1 where it cannot be told.
int sfc_nlink(moonbit_bytes_t path) {
#ifdef _WIN32
  HANDLE h = opened((const char *)path, FILE_READ_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) return -1;
  BY_HANDLE_FILE_INFORMATION info;
  BOOL ok = GetFileInformationByHandle(h, &info);
  CloseHandle(h);
  return ok ? (int)info.nNumberOfLinks : -1;
#else
  struct stat st;
  if (lstat((const char *)path, &st) != 0) return -1;
  return (int)st.st_nlink;
#endif
}

/// A hard link `to` of `from`: 0 made; 1 where the disk makes none there (EXDEV, EPERM, ENOTSUP, EMLINK, ENOSYS: what
/// carry-reference.ts's putFile copied instead); 2 any other failure (`to` there already, `from` gone).
int sfc_link(moonbit_bytes_t from, moonbit_bytes_t to) {
#ifdef _WIN32
  wchar_t *f = wide((const char *)from);
  wchar_t *t = wide((const char *)to);
  BOOL ok = f != NULL && t != NULL && CreateHardLinkW(t, f, NULL);
  DWORD e = ok ? 0 : GetLastError();
  free(f);
  free(t);
  if (ok) return 0;
  return e == ERROR_NOT_SAME_DEVICE || e == ERROR_ACCESS_DENIED || e == ERROR_NOT_SUPPORTED || e == ERROR_TOO_MANY_LINKS ||
                 e == ERROR_INVALID_FUNCTION
             ? 1
             : 2;
#else
  if (link((const char *)from, (const char *)to) == 0) return 0;
  int e = errno;
  return e == EXDEV || e == EPERM || e == ENOTSUP || e == EMLINK || e == ENOSYS
#ifdef EOPNOTSUPP
                 || e == EOPNOTSUPP
#endif
             ? 1
             : 2;
#endif
}

/// Whether `path` (a directory with `dir`) is refused to this process as it is opened to be read (EACCES, EPERM), not
/// gone or read: what carry-reference.ts's gathering counted as unreadable.
int sfc_denied(moonbit_bytes_t path, int dir) {
#ifdef _WIN32
  (void)dir;
  HANDLE h = opened((const char *)path, GENERIC_READ);
  if (h != INVALID_HANDLE_VALUE) {
    CloseHandle(h);
    return 0;
  }
  return GetLastError() == ERROR_ACCESS_DENIED ? 1 : 0;
#else
  if (dir) {
    DIR *d = opendir((const char *)path);
    if (d != NULL) {
      closedir(d);
      return 0;
    }
  } else {
    int fd = open((const char *)path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
      close(fd);
      return 0;
    }
  }
  return errno == EACCES || errno == EPERM ? 1 : 0;
#endif
}

/// Whether `path` is confirmed absent (ENOENT / ENOTDIR on POSIX; FILE_NOT_FOUND / PATH_NOT_FOUND / INVALID_NAME on
/// Windows) rather than unreadable (EACCES / EIO / other). `follow`: stat vs lstat.
int sfc_missing(moonbit_bytes_t path, int follow) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  DWORD attr = GetFileAttributesW(w);
  if (attr == INVALID_FILE_ATTRIBUTES) {
    DWORD e = GetLastError();
    free(w);
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
  }
  if (follow && (attr & FILE_ATTRIBUTE_REPARSE_POINT)) {
    HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD e = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    free(w);
    if (h != INVALID_HANDLE_VALUE) return 0;
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
  }
  free(w);
  return 0;
#else
  struct stat st;
  int rc = follow ? stat((const char *)path, &st) : lstat((const char *)path, &st);
  if (rc == 0) return 0;
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Whether directory `path` is confirmed absent or not a directory (ENOENT / ENOTDIR) when opened for listing, rather
/// than unreadable (EACCES / EIO / other).
int sfc_dir_missing(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  DWORD attr = GetFileAttributesW(w);
  free(w);
  if (attr != INVALID_FILE_ATTRIBUTES) return (attr & FILE_ATTRIBUTE_DIRECTORY) ? 0 : 1;
  DWORD e = GetLastError();
  return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
#else
  DIR *d = opendir((const char *)path);
  if (d != NULL) {
    closedir(d);
    return 0;
  }
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Lightweight check whether directory `path` can be opened for listing (without reading/sorting entries):
/// returns 1 if readable OR confirmed missing/not-a-dir (ENOENT / ENOTDIR), 0 if unreadable (EACCES / EIO / other).
int sfc_dir_readable(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  HANDLE h = CreateFileW(w, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  DWORD e = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
  if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  free(w);
  if (h != INVALID_HANDLE_VALUE) return 1;
  return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME || e == ERROR_DIRECTORY) ? 1 : 0;
#else
  DIR *d = opendir((const char *)path);
  if (d != NULL) {
    closedir(d);
    return 1;
  }
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Whether `path` is a regular file, links followed: what the shell's `fs.stat` says as "file" (Rust's
/// `fs::metadata(path).is_file()`, Node's `statSync(path).isFile()`), asked without a message to the shell, for a
/// replica's `sources` that asks it of every file a place lacks. 1 a file, 0 not one, -1 not known here: on Windows a
/// path of MAX_PATH or more, which the shell asks in its verbatim form (`\\?\`) and this does not.
int sfc_is_file(moonbit_bytes_t path) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
  if (n <= 0 || n >= MAX_PATH) return -1;
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return -1;
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
  HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return 0;
  BY_HANDLE_FILE_INFORMATION info;
  int ok = GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) &&
           (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
  CloseHandle(h);
  return ok ? 1 : 0;
#else
  struct stat st;
  return (stat((const char *)path, &st) == 0 && S_ISREG(st.st_mode)) ? 1 : 0;
#endif
}

/// Racy-git style metadata stamp for `path` (regular file, readable):
///   - empty Bytes (len 0): error, unreadable, non-regular, or Windows MAX_PATH -> caller must not use cache
///   - 1 byte `[0x00]`: confirmed missing (ENOENT / ENOTDIR / FILE_NOT_FOUND)
///   - `[0x01, ascii_stamp...]`: clean (non-racy, >= 50ms since ctime/ChangeTime)
///   - `[0x02, ascii_stamp...]`: racy (< 50ms since ctime/ChangeTime or clock skew) -> verify with `sfc_file_fnv64`
moonbit_bytes_t sfc_file_stamp(moonbit_bytes_t path) {
  char buf[256];
  int status = -1;
  int len = 0;
#ifdef _WIN32
  int wn = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
  if (wn <= 0 || wn >= MAX_PATH) return moonbit_make_bytes(0, 0);
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return moonbit_make_bytes(0, 0);
  HANDLE h = CreateFileW(w, FILE_READ_DATA | FILE_READ_ATTRIBUTES,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  DWORD err = (h == INVALID_HANDLE_VALUE) ? GetLastError() : 0;
  free(w);
  if (h == INVALID_HANDLE_VALUE) {
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND || err == ERROR_INVALID_NAME) {
      moonbit_bytes_t out = moonbit_make_bytes(1, 0);
      out[0] = 0;
      return out;
    }
    return moonbit_make_bytes(0, 0);
  }
  BY_HANDLE_FILE_INFORMATION info;
  FILE_BASIC_INFO basic;
  BOOL ok = GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) &&
            (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
            GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic));
  CloseHandle(h);
  if (!ok) return moonbit_make_bytes(0, 0);
  uint64_t fsize = ((uint64_t)info.nFileSizeHigh << 32) | (uint64_t)info.nFileSizeLow;
  uint64_t mtime = ((uint64_t)info.ftLastWriteTime.dwHighDateTime << 32) | (uint64_t)info.ftLastWriteTime.dwLowDateTime;
  uint64_t ctime = (uint64_t)basic.ChangeTime.QuadPart;
  len = snprintf(buf, sizeof(buf), "%lu:%lu:%lu:%llu:%llu:%llu",
                 (unsigned long)info.dwVolumeSerialNumber,
                 (unsigned long)info.nFileIndexHigh,
                 (unsigned long)info.nFileIndexLow,
                 (unsigned long long)fsize,
                 (unsigned long long)mtime,
                 (unsigned long long)ctime);
  if (len <= 0 || len >= (int)sizeof(buf)) return moonbit_make_bytes(0, 0);
  FILETIME ft_now;
  GetSystemTimeAsFileTime(&ft_now);
  uint64_t now_100ns = ((uint64_t)ft_now.dwHighDateTime << 32) | (uint64_t)ft_now.dwLowDateTime;
  int is_racy = (now_100ns < ctime) || (now_100ns - ctime < 500000ULL);
  status = is_racy ? 2 : 1;
#else
  struct stat st;
  if (stat((const char *)path, &st) != 0) {
    if (errno == ENOENT || errno == ENOTDIR) {
      moonbit_bytes_t out = moonbit_make_bytes(1, 0);
      out[0] = 0;
      return out;
    }
    return moonbit_make_bytes(0, 0);
  }
  if (!S_ISREG(st.st_mode) || access((const char *)path, R_OK) != 0) {
    return moonbit_make_bytes(0, 0);
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
  len = snprintf(buf, sizeof(buf), "%llu:%llu:%lld:%lld:%ld:%lld:%ld:%u",
                 (unsigned long long)st.st_dev,
                 (unsigned long long)st.st_ino,
                 (long long)st.st_size,
                 (long long)m_sec, m_nsec,
                 (long long)c_sec, c_nsec,
                 (unsigned int)st.st_mode);
  if (len <= 0 || len >= (int)sizeof(buf)) return moonbit_make_bytes(0, 0);
  struct timespec now;
  int is_racy = 0;
  if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
    is_racy = 1;
  } else {
    int64_t diff_sec = (int64_t)now.tv_sec - c_sec;
    if (diff_sec < 0) {
      is_racy = 1;
    } else if (diff_sec == 0) {
      if ((int64_t)now.tv_nsec - (int64_t)c_nsec < 50000000LL) is_racy = 1;
    } else if (diff_sec == 1) {
      if (1000000000LL + (int64_t)now.tv_nsec - (int64_t)c_nsec < 50000000LL) is_racy = 1;
    }
  }
  status = is_racy ? 2 : 1;
#endif
  moonbit_bytes_t out = moonbit_make_bytes(1 + len, 0);
  out[0] = (uint8_t)status;
  memcpy(out + 1, buf, (size_t)len);
  return out;
}

/// Streaming 64-bit FNV-1a hash of raw file bytes (64 KiB stack buffer): returns 8 little-endian bytes, or empty Bytes
/// on any open/read error.
moonbit_bytes_t sfc_file_fnv64(moonbit_bytes_t path) {
  uint64_t h = 14695981039346656037ULL;
  uint8_t buf[65536];
#ifdef _WIN32
  int wn = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
  if (wn <= 0 || wn >= MAX_PATH) return moonbit_make_bytes(0, 0);
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return moonbit_make_bytes(0, 0);
  HANDLE fh = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (fh == INVALID_HANDLE_VALUE) return moonbit_make_bytes(0, 0);
  for (;;) {
    DWORD got = 0;
    if (!ReadFile(fh, buf, (DWORD)sizeof(buf), &got, NULL)) {
      CloseHandle(fh);
      return moonbit_make_bytes(0, 0);
    }
    if (got == 0) break;
    for (DWORD i = 0; i < got; i++) {
      h ^= (uint64_t)buf[i];
      h *= 1099511628211ULL;
    }
  }
  CloseHandle(fh);
#else
  int fd = open((const char *)path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return moonbit_make_bytes(0, 0);
  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return moonbit_make_bytes(0, 0);
    }
    if (n == 0) break;
    for (ssize_t i = 0; i < n; i++) {
      h ^= (uint64_t)buf[i];
      h *= 1099511628211ULL;
    }
  }
  close(fd);
#endif
  moonbit_bytes_t out = moonbit_make_bytes(8, 0);
  for (int i = 0; i < 8; i++) {
    out[i] = (uint8_t)((h >> (i * 8)) & 0xFFU);
  }
  return out;
}
