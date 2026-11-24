// What the measure of a directory's size (footprint.mbt) asks of the system: an entry's lstat as Node's bigint lstat
// gives it (what it is, dev, ino, nlink, blocks), a directory's names as Node's readdir lists them, and whether a path
// is there as existsSync says (its links followed), whether it is a directory as stat says, and a file's first bytes
// (test/footprint-reference.ts `answerNow`'s three looks, for what is made again). Each path is UTF-8, ended by a NUL. Called on the program's one
// thread, a call each entry: none of it goes through the shell's JSON.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

/// What failed, as footprint.mbt names it (Node's codes): 0 none, 1 ENOENT, 2 EACCES, 3 EPERM, 4 ENOTDIR, 5 ELOOP,
/// 6 ENAMETOOLONG, 7 anything else (EIO).
enum { SFF_OK = 0, SFF_ENOENT = 1, SFF_EACCES = 2, SFF_EPERM = 3, SFF_ENOTDIR = 4, SFF_ELOOP = 5, SFF_ENAMETOOLONG = 6, SFF_EIO = 7 };

/// What an entry is (out[0]): 0 something else, 1 a file, 2 a directory, 3 a symbolic link.
enum { SFF_OTHER = 0, SFF_FILE = 1, SFF_DIR = 2, SFF_LINK = 3 };

/// Names grown into one buffer, each ended by a NUL.
typedef struct {
  char *data;
  size_t len, cap;
} names_t;

static int names_add(names_t *n, const char *s, size_t len) {
  if (n->len + len + 1 > n->cap) {
    size_t cap = n->cap == 0 ? 4096 : n->cap;
    while (n->len + len + 1 > cap) cap *= 2;
    char *grown = realloc(n->data, cap);
    if (grown == NULL) return -1;
    n->data = grown;
    n->cap = cap;
  }
  memcpy(n->data + n->len, s, len);
  n->data[n->len + len] = 0;
  n->len += len + 1;
  return 0;
}

static moonbit_bytes_t names_bytes(names_t *n) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n->len, 0);
  if (n->len > 0) memcpy(out, n->data, n->len);
  free(n->data);
  return out;
}

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>

static wchar_t *wide(const char *s, const wchar_t *suffix) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  size_t extra = suffix == NULL ? 0 : wcslen(suffix);
  wchar_t *w = malloc(sizeof(wchar_t) * (n + extra));
  if (w == NULL) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  if (suffix != NULL) wcscat(w, suffix);
  return w;
}

/// libuv's uv_translate_sys_error, for what a measure meets.
static int failed(DWORD e) {
  switch (e) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
    case ERROR_INVALID_NAME:
    case ERROR_BAD_NETPATH:
    case ERROR_BAD_PATHNAME:
    case ERROR_INVALID_DRIVE:
    case ERROR_MOD_NOT_FOUND:
      return SFF_ENOENT;
    case ERROR_ACCESS_DENIED:
    case ERROR_PRIVILEGE_NOT_HELD:
      return SFF_EPERM;
    case ERROR_NOACCESS:
    case ERROR_CANT_ACCESS_FILE:
      return SFF_EACCES;
    case ERROR_DIRECTORY:
      return SFF_ENOTDIR;
    case ERROR_CANT_RESOLVE_FILENAME:
      return SFF_ELOOP;
    case ERROR_FILENAME_EXCED_RANGE:
      return SFF_ENAMETOOLONG;
    default:
      return SFF_EIO;
  }
}

/// `path`'s lstat into `out` (what it is, dev, ino, nlink, blocks), as libuv's fs__stat_handle has it: dev the volume's
/// serial number, ino its 64-bit file index, blocks its allocation size in 512-byte blocks, a symbolic link or a
/// junction (a reparse point libuv reads as a link) said a link. 0, or what failed.
int sff_lstat(moonbit_bytes_t path, int64_t *out) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return SFF_ENOENT;
  HANDLE h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return failed(GetLastError());
  BY_HANDLE_FILE_INFORMATION info;
  FILE_STANDARD_INFO standard;
  if (!GetFileInformationByHandle(h, &info) || !GetFileInformationByHandleEx(h, FileStandardInfo, &standard, sizeof standard)) {
    DWORD e = GetLastError();
    CloseHandle(h);
    return failed(e);
  }
  int kind = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? SFF_DIR : SFF_FILE;
  if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
    FILE_ATTRIBUTE_TAG_INFO tag;
    if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof tag) &&
        (tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT))
      kind = SFF_LINK;
  }
  CloseHandle(h);
  out[0] = kind;
  out[1] = (int64_t)info.dwVolumeSerialNumber;
  out[2] = (int64_t)(((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow);
  out[3] = (int64_t)info.nNumberOfLinks;
  out[4] = (int64_t)(standard.AllocationSize.QuadPart >> 9);
  return SFF_OK;
}

/// The names in the directory `path` (but `.` and `..`), each ended by a NUL, in the order the system lists them (as
/// libuv's scandir on Windows); none, with what failed in err[0].
moonbit_bytes_t sff_list(moonbit_bytes_t path, int32_t *err) {
  names_t n = {0};
  err[0] = SFF_OK;
  wchar_t *w = wide((const char *)path, L"\\*");
  if (w == NULL) {
    err[0] = SFF_ENOENT;
    return names_bytes(&n);
  }
  WIN32_FIND_DATAW found;
  HANDLE h = FindFirstFileExW(w, FindExInfoBasic, &found, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
  free(w);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    // (an empty directory has `.` at least: nothing found is a directory that is not there)
    err[0] = e == ERROR_FILE_NOT_FOUND ? SFF_ENOENT : failed(e);
    return names_bytes(&n);
  }
  do {
    const wchar_t *name = found.cFileName;
    if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;
    int len = WideCharToMultiByte(CP_UTF8, 0, name, -1, NULL, 0, NULL, NULL);
    if (len <= 1) continue;
    char *u = malloc(len);
    if (u == NULL) continue;
    WideCharToMultiByte(CP_UTF8, 0, name, -1, u, len, NULL, NULL);
    names_add(&n, u, (size_t)len - 1);
    free(u);
  } while (FindNextFileW(h, &found));
  FindClose(h);
  return names_bytes(&n);
}

/// Whether something is at `path`, its links followed (existsSync).
int sff_exists(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return 0;
  HANDLE h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return 0;
  CloseHandle(h);
  return 1;
}

/// Whether `path` is a directory, its links followed (stat's isDirectory).
int sff_dir(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return 0;
  DWORD a = GetFileAttributesW(w);
  free(w);
  return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/// The first `most` bytes of the regular file `path` into `buf` (fewer if it is shorter); -1 when it could not be read
/// or is not a file on a disk (a directory, a pipe, a device: never waited on).
static long head_read(const char *path, char *buf, size_t most) {
  wchar_t *w = wide(path, NULL);
  if (w == NULL) return -1;
  HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return -1;
  BY_HANDLE_FILE_INFORMATION info;
  if (GetFileType(h) != FILE_TYPE_DISK || !GetFileInformationByHandle(h, &info) ||
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
    if (n == 0) break;
    got += n;
  }
  CloseHandle(h);
  return (long)got;
}
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static int failed(int e) {
  switch (e) {
    case ENOENT: return SFF_ENOENT;
    case EACCES: return SFF_EACCES;
    case EPERM: return SFF_EPERM;
    case ENOTDIR: return SFF_ENOTDIR;
    case ELOOP: return SFF_ELOOP;
    case ENAMETOOLONG: return SFF_ENAMETOOLONG;
    default: return SFF_EIO;
  }
}

/// `path`'s lstat into `out` (what it is, dev, ino, nlink, blocks): 0, or what failed.
int sff_lstat(moonbit_bytes_t path, int64_t *out) {
  struct stat st;
  if (lstat((const char *)path, &st) != 0) return failed(errno);
  out[0] = S_ISLNK(st.st_mode) ? SFF_LINK : S_ISDIR(st.st_mode) ? SFF_DIR : S_ISREG(st.st_mode) ? SFF_FILE : SFF_OTHER;
  out[1] = (int64_t)st.st_dev;
  out[2] = (int64_t)st.st_ino;
  out[3] = (int64_t)st.st_nlink;
  out[4] = (int64_t)st.st_blocks;
  return SFF_OK;
}

static int by_name(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }

/// The names in the directory `path` (but `.` and `..`), each ended by a NUL, sorted by their bytes as libuv's scandir
/// sorts them (uv__fs_scandir_sort: strcmp); none, with what failed in err[0].
moonbit_bytes_t sff_list(moonbit_bytes_t path, int32_t *err) {
  names_t n = {0};
  err[0] = SFF_OK;
  DIR *d = opendir((const char *)path);
  if (d == NULL) {
    err[0] = failed(errno);
    return names_bytes(&n);
  }
  char **all = NULL;
  size_t count = 0, cap = 0;
  struct dirent *e;
  for (;;) {
    errno = 0;
    e = readdir(d);
    if (e == NULL) break;
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    if (count == cap) {
      cap = cap == 0 ? 64 : cap * 2;
      char **grown = realloc(all, sizeof(char *) * cap);
      if (grown == NULL) break;
      all = grown;
    }
    all[count] = strdup(e->d_name);
    if (all[count] != NULL) count++;
  }
  if (e == NULL && errno != 0) err[0] = failed(errno);
  closedir(d);
  if (count > 1) qsort(all, count, sizeof(char *), by_name);
  for (size_t i = 0; i < count; i++) {
    if (err[0] == SFF_OK) names_add(&n, all[i], strlen(all[i]));
    free(all[i]);
  }
  free(all);
  if (err[0] != SFF_OK) {
    free(n.data);
    n = (names_t){0};
  }
  return names_bytes(&n);
}

/// Whether something is at `path`, its links followed (existsSync).
int sff_exists(moonbit_bytes_t path) {
  struct stat st;
  return stat((const char *)path, &st) == 0;
}

/// Whether `path` is a directory, its links followed (stat's isDirectory).
int sff_dir(moonbit_bytes_t path) {
  struct stat st;
  return stat((const char *)path, &st) == 0 && S_ISDIR(st.st_mode);
}

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif

/// The first `most` bytes of the regular file `path` into `buf` (fewer if it is shorter); -1 when it could not be read
/// or is not a regular file. Opened without blocking and asked what it is by its descriptor, so a FIFO with no writer
/// (or a device) is refused at once, never waited on.
static long head_read(const char *path, char *buf, size_t most) {
  int fd;
  do fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
  while (fd < 0 && errno == EINTR);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(fd);
    return -1;
  }
  size_t got = 0;
  while (got < most) {
    ssize_t n = read(fd, buf + got, most - got);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    if (n == 0) break;
    got += (size_t)n;
  }
  close(fd);
  return (long)got;
}
#endif

/// The first `most` bytes of the file `path` (fewer if it is shorter); err[0] 1 when it could not be read or is not a
/// regular file.
moonbit_bytes_t sff_head(moonbit_bytes_t path, int32_t most, int32_t *err) {
  char buf[4096];
  if (most > (int32_t)sizeof buf) most = (int32_t)sizeof buf;
  if (most < 0) most = 0;
  long got = head_read((const char *)path, buf, (size_t)most);
  err[0] = got < 0;
  moonbit_bytes_t out = moonbit_make_bytes(got > 0 ? (int32_t)got : 0, 0);
  if (got > 0) memcpy(out, buf, (size_t)got);
  return out;
}
