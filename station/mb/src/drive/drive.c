// What the drive (drive.mbt, fs.mbt, trash.mbt, zip.mbt, transfers.mbt) asks of the system, as station/src/drive's
// node:fs calls ask it: a path's stat or lstat (what it is, its size, its time in ms as Node's mtimeMs, its device), a
// folder's entries with their kinds, realpath(3) as fs.promises.realpath, a part of a file read, a part written (made
// anew or opened as it is, at least so long, truncated, synced), a rename, a folder made, removed, a file unlinked, a
// file copied as copyFile with COPYFILE_EXCL | COPYFILE_FICLONE (libuv's uv_fs_copyfile), whether a folder opens, a
// file made only where none is (O_EXCL), a file written whole as writePrivateSoon writes one, a local time's fields and
// the user's id. Each path is UTF-8, ended by a NUL. A failure is its errno as Node names it (sfd_code_name).
// On Windows the same through Win32's wide calls, as libuv makes them (footprint.c's way).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include "moonbit.h"

/// Node's codes, by number (what each answers, 0 none).
enum {
  SFD_OK = 0, SFD_ENOENT = 1, SFD_EACCES = 2, SFD_EPERM = 3, SFD_EEXIST = 4, SFD_ENOTEMPTY = 5, SFD_EISDIR = 6,
  SFD_ENOTDIR = 7, SFD_ENOSPC = 8, SFD_EXDEV = 9, SFD_EROFS = 10, SFD_ELOOP = 11, SFD_EINVAL = 12, SFD_EBUSY = 13,
  SFD_ENAMETOOLONG = 14, SFD_EMFILE = 15, SFD_ENOSYS = 16, SFD_EIO = 17
};

typedef struct {
  char *data;
  size_t len, cap;
} buf_t;

static int buf_add(buf_t *b, const char *s, size_t len) {
  if (b->len + len > b->cap) {
    size_t cap = b->cap == 0 ? 4096 : b->cap;
    while (b->len + len > cap) cap *= 2;
    char *grown = realloc(b->data, cap);
    if (grown == NULL) return -1;
    b->data = grown;
    b->cap = cap;
  }
  if (len > 0) memcpy(b->data + b->len, s, len);
  b->len += len;
  return 0;
}

static moonbit_bytes_t buf_bytes(buf_t *b) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)b->len, 0);
  if (b->len > 0) memcpy(out, b->data, b->len);
  free(b->data);
  b->data = NULL;
  b->len = b->cap = 0;
  return out;
}

static moonbit_bytes_t empty_bytes(void) { return moonbit_make_bytes(0, 0); }

#ifdef _WIN32

#include <windows.h>
#include <bcrypt.h>
#include <wchar.h>
#include <process.h>

/// `s` (UTF-8) in UTF-16, `suffix` after it; NULL where it is not UTF-8 or memory is short.
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

/// `w` (UTF-16, `len` of it, or to its NUL with -1) in UTF-8, added to `b`.
static int narrow_add(buf_t *b, const wchar_t *w, int len) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, len, NULL, 0, NULL, NULL);
  if (n <= 0) return -1;
  char *u = malloc((size_t)n);
  if (u == NULL) return -1;
  WideCharToMultiByte(CP_UTF8, 0, w, len, u, n, NULL, NULL);
  int r = buf_add(b, u, (size_t)(len < 0 ? n - 1 : n));
  free(u);
  return r;
}

/// libuv's uv_translate_sys_error, as Node names what each becomes.
static int failed(DWORD e) {
  switch (e) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
    case ERROR_INVALID_NAME:
    case ERROR_BAD_NETPATH:
    case ERROR_BAD_PATHNAME:
    case ERROR_INVALID_DRIVE:
    case ERROR_MOD_NOT_FOUND:
    case ERROR_INVALID_REPARSE_DATA:
      return SFD_ENOENT;
    case ERROR_ACCESS_DENIED:
    case ERROR_PRIVILEGE_NOT_HELD:
      return SFD_EPERM;
    case ERROR_NOACCESS:
    case ERROR_CANT_ACCESS_FILE:
      return SFD_EACCES;
    case ERROR_FILE_EXISTS:
    case ERROR_ALREADY_EXISTS:
      return SFD_EEXIST;
    case ERROR_DIR_NOT_EMPTY:
      return SFD_ENOTEMPTY;
    case ERROR_DIRECTORY:
      return SFD_ENOTDIR;
    case ERROR_DISK_FULL:
    case ERROR_HANDLE_DISK_FULL:
      return SFD_ENOSPC;
    case ERROR_NOT_SAME_DEVICE:
      return SFD_EXDEV;
    case ERROR_WRITE_PROTECT:
      return SFD_EROFS;
    case ERROR_CANT_RESOLVE_FILENAME:
      return SFD_ELOOP;
    case ERROR_INVALID_PARAMETER:
    case ERROR_INVALID_FLAGS:
      return SFD_EINVAL;
    case ERROR_SHARING_VIOLATION:
    case ERROR_LOCK_VIOLATION:
    case ERROR_BUSY:
      return SFD_EBUSY;
    case ERROR_FILENAME_EXCED_RANGE:
      return SFD_ENAMETOOLONG;
    case ERROR_TOO_MANY_OPEN_FILES:
      return SFD_EMFILE;
    default:
      return SFD_EIO;
  }
}

static const DWORD SHARE_ALL = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

/// A path opened as libuv opens one to stat it: links followed (or not), a folder too.
static HANDLE open_path(const char *path, DWORD access, DWORD disposition, int follow, int *err) {
  wchar_t *w = wide(path, NULL);
  if (w == NULL) {
    *err = SFD_ENOENT;
    return INVALID_HANDLE_VALUE;
  }
  HANDLE h = CreateFileW(w, access, SHARE_ALL, NULL, disposition, FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT), NULL);
  free(w);
  *err = h == INVALID_HANDLE_VALUE ? failed(GetLastError()) : SFD_OK;
  return h;
}

/// A file time as Node's mtimeMs: its 100 ns since 1601 less those to 1970, in ms.
static double ms_of(FILETIME t) {
  uint64_t v = ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
  return ((double)(int64_t)(v - 116444736000000000ULL)) / 1e4;
}

int sfd_stat(moonbit_bytes_t path, int32_t follow, double *out) {
  int err;
  HANDLE h = open_path((const char *)path, FILE_READ_ATTRIBUTES, OPEN_EXISTING, follow, &err);
  if (h == INVALID_HANDLE_VALUE) return err;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(h, &info)) {
    DWORD e = GetLastError();
    CloseHandle(h);
    return failed(e);
  }
  int kind = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 2 : 1;
  if (!follow && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    FILE_ATTRIBUTE_TAG_INFO tag;
    if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof tag) &&
        (tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT))
      kind = 3;
  }
  CloseHandle(h);
  out[0] = kind;
  out[1] = (double)(((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow);
  out[2] = ms_of(info.ftLastWriteTime);
  out[3] = (double)info.dwVolumeSerialNumber;
  return SFD_OK;
}

/// The entries of the folder `path` as sfd_readdir's POSIX one gives them, in the order the system lists them (as
/// libuv's scandir on Windows, which does not sort them), a reparse point a link as libuv's dirent says it.
moonbit_bytes_t sfd_readdir(moonbit_bytes_t path, int32_t *err) {
  buf_t out = {0};
  err[0] = SFD_OK;
  wchar_t *w = wide((const char *)path, L"\\*");
  if (w == NULL) {
    err[0] = SFD_ENOENT;
    return buf_bytes(&out);
  }
  WIN32_FIND_DATAW found;
  HANDLE h = FindFirstFileExW(w, FindExInfoBasic, &found, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
  free(w);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    // (an empty folder has `.` at least: nothing found is a folder that is not there)
    err[0] = e == ERROR_FILE_NOT_FOUND ? SFD_ENOENT : failed(e);
    return buf_bytes(&out);
  }
  do {
    const wchar_t *name = found.cFileName;
    if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;
    char kind = (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? 'l' : (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'd' : 'f';
    buf_add(&out, &kind, 1);
    narrow_add(&out, name, -1);
    buf_add(&out, "", 1);
  } while (FindNextFileW(h, &found));
  DWORD e = GetLastError();
  FindClose(h);
  if (e != ERROR_NO_MORE_FILES) {
    err[0] = failed(e);
    free(out.data);
    out = (buf_t){0};
  }
  return buf_bytes(&out);
}

/// uv_fs_realpath: the handle's final path, `\\?\` taken off (`\\?\UNC\` made `\\`).
moonbit_bytes_t sfd_realpath(moonbit_bytes_t path, int32_t *err) {
  buf_t out = {0};
  int e;
  HANDLE h = open_path((const char *)path, 0, OPEN_EXISTING, 1, &e);
  err[0] = e;
  if (h == INVALID_HANDLE_VALUE) return buf_bytes(&out);
  DWORD n = GetFinalPathNameByHandleW(h, NULL, 0, VOLUME_NAME_DOS);
  wchar_t *w = n == 0 ? NULL : malloc(sizeof(wchar_t) * (n + 1));
  if (w == NULL || GetFinalPathNameByHandleW(h, w, n + 1, VOLUME_NAME_DOS) == 0) {
    err[0] = failed(GetLastError());
    free(w);
    CloseHandle(h);
    return buf_bytes(&out);
  }
  CloseHandle(h);
  const wchar_t *p = w;
  if (wcsncmp(p, L"\\\\?\\UNC\\", 8) == 0) {
    buf_add(&out, "\\\\", 2);
    p += 8;
  } else if (wcsncmp(p, L"\\\\?\\", 4) == 0) {
    p += 4;
  }
  narrow_add(&out, p, -1);
  free(w);
  return buf_bytes(&out);
}

moonbit_bytes_t sfd_read(moonbit_bytes_t path, double offset, double length, double *out, int32_t *err) {
  int e;
  HANDLE h = open_path((const char *)path, GENERIC_READ, OPEN_EXISTING, 1, &e);
  err[0] = e;
  if (h == INVALID_HANDLE_VALUE) return empty_bytes();
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(h, &info)) {
    err[0] = failed(GetLastError());
    CloseHandle(h);
    return empty_bytes();
  }
  if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
    err[0] = SFD_EISDIR;
    CloseHandle(h);
    return empty_bytes();
  }
  double size = (double)(((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow);
  out[0] = size;
  out[1] = ms_of(info.ftLastWriteTime);
  double want = size - offset;
  if (want > length) want = length;
  if (want < 0) want = 0;
  size_t n = (size_t)want, got = 0;
  char *data = n > 0 ? malloc(n) : NULL;
  while (got < n) {
    OVERLAPPED at = {0};
    uint64_t pos = (uint64_t)offset + got;
    at.Offset = (DWORD)pos;
    at.OffsetHigh = (DWORD)(pos >> 32);
    DWORD chunk = n - got > 0x40000000 ? 0x40000000 : (DWORD)(n - got), r = 0;
    if (!ReadFile(h, data + got, chunk, &r, &at)) {
      DWORD le = GetLastError();
      if (le == ERROR_HANDLE_EOF) break;
      err[0] = failed(le);
      break;
    }
    if (r == 0) break;
    got += r;
  }
  CloseHandle(h);
  if (err[0] != SFD_OK) {
    free(data);
    return empty_bytes();
  }
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)got, 0);
  if (got > 0) memcpy(bytes, data, got);
  free(data);
  return bytes;
}

static int write_all(HANDLE h, const char *data, size_t n, uint64_t offset) {
  size_t put = 0;
  while (put < n) {
    OVERLAPPED at = {0};
    uint64_t pos = offset + put;
    at.Offset = (DWORD)pos;
    at.OffsetHigh = (DWORD)(pos >> 32);
    DWORD chunk = n - put > 0x40000000 ? 0x40000000 : (DWORD)(n - put), w = 0;
    if (!WriteFile(h, data + put, chunk, &w, &at)) return failed(GetLastError());
    put += w;
  }
  return SFD_OK;
}

int sfd_write(moonbit_bytes_t path, int32_t create, double offset, moonbit_bytes_t data, double at_least, double truncate_to, int32_t sync, double *out) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return SFD_ENOENT;
  HANDLE h = CreateFileW(w, GENERIC_READ | GENERIC_WRITE, SHARE_ALL, NULL, create ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return failed(GetLastError());
  int code = SFD_OK;
  LARGE_INTEGER size;
  out[1] = 0;
  if (!GetFileSizeEx(h, &size)) {
    code = failed(GetLastError());
    goto done;
  }
  if (at_least >= 0 && (double)size.QuadPart < at_least) {
    out[0] = (double)size.QuadPart;
    out[1] = 1;
    goto done;
  }
  code = write_all(h, (const char *)data, (size_t)Moonbit_array_length(data), (uint64_t)offset);
  if (code != SFD_OK) goto done;
  if (truncate_to >= 0) {
    FILE_END_OF_FILE_INFO end;
    end.EndOfFile.QuadPart = (LONGLONG)truncate_to;
    if (!SetFileInformationByHandle(h, FileEndOfFileInfo, &end, sizeof end)) {
      code = failed(GetLastError());
      goto done;
    }
  }
  if (sync && !FlushFileBuffers(h)) {
    code = failed(GetLastError());
    goto done;
  }
  if (!GetFileSizeEx(h, &size)) {
    code = failed(GetLastError());
    goto done;
  }
  out[0] = (double)size.QuadPart;
done:
  CloseHandle(h);
  return code;
}

int sfd_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  wchar_t *a = wide((const char *)from, NULL), *b = wide((const char *)to, NULL);
  int code = a == NULL || b == NULL ? SFD_ENOENT : MoveFileExW(a, b, MOVEFILE_REPLACE_EXISTING) ? SFD_OK : failed(GetLastError());
  free(a);
  free(b);
  return code;
}

static int is_sep_w(char c) { return c == '/' || c == '\\'; }

/// Where `p`'s root ends (`C:\`, `C:`, `\\server\share\`, a leading separator): what a recursive mkdir never makes.
static size_t root_end(const char *p) {
  size_t n = strlen(p);
  if (n >= 2 && p[1] == ':') return n > 2 && is_sep_w(p[2]) ? 3 : 2;
  if (n >= 2 && is_sep_w(p[0]) && is_sep_w(p[1])) {
    size_t i = 2;
    for (int names = 0; names < 2 && i < n; names++) {
      while (i < n && !is_sep_w(p[i])) i++;
      if (i < n) i++;
    }
    return i;
  }
  return n > 0 && is_sep_w(p[0]) ? 1 : 0;
}

int sfd_mkdir(moonbit_bytes_t path, int32_t recursive, int32_t mode) {
  (void)mode;
  const char *p = (const char *)path;
  wchar_t *w = wide(p, NULL);
  if (w == NULL) return SFD_ENOENT;
  BOOL made = CreateDirectoryW(w, NULL);
  DWORD e = made ? 0 : GetLastError();
  if (made) {
    free(w);
    return SFD_OK;
  }
  if (!recursive) {
    free(w);
    return failed(e);
  }
  if (e == ERROR_ALREADY_EXISTS || e == ERROR_FILE_EXISTS) {
    DWORD a = GetFileAttributesW(w);
    free(w);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) ? SFD_OK : SFD_EEXIST;
  }
  if (e != ERROR_PATH_NOT_FOUND) {
    free(w);
    return failed(e);
  }
  char *copy = strdup(p);
  size_t len = strlen(copy), root = root_end(copy);
  while (len > root && is_sep_w(copy[len - 1])) copy[--len] = 0;
  while (len > root && !is_sep_w(copy[len - 1])) len--;
  if (len <= root) {
    free(copy);
    free(w);
    return failed(e);
  }
  while (len > root && is_sep_w(copy[len - 1])) len--;
  copy[len] = 0;
  int up = len > root ? sfd_mkdir((moonbit_bytes_t)copy, 1, mode) : SFD_OK;
  free(copy);
  if (up != SFD_OK) {
    free(w);
    return up;
  }
  made = CreateDirectoryW(w, NULL);
  e = made ? 0 : GetLastError();
  if (!made && (e == ERROR_ALREADY_EXISTS || e == ERROR_FILE_EXISTS)) {
    DWORD a = GetFileAttributesW(w);
    if (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY)) made = TRUE;
  }
  free(w);
  return made ? SFD_OK : failed(e);
}

/// What is at `w` let go: a folder with all it holds (a link to one, a junction, removed as itself), a file read-only
/// or not.
static int rm_w(const wchar_t *w) {
  DWORD a = GetFileAttributesW(w);
  if (a == INVALID_FILE_ATTRIBUTES) return failed(GetLastError());
  if (a & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(w, a & ~FILE_ATTRIBUTE_READONLY);
  if (!(a & FILE_ATTRIBUTE_DIRECTORY)) return DeleteFileW(w) ? SFD_OK : failed(GetLastError());
  if (!(a & FILE_ATTRIBUTE_REPARSE_POINT)) {
    size_t n = wcslen(w);
    wchar_t *pattern = malloc(sizeof(wchar_t) * (n + 3));
    if (pattern == NULL) return SFD_EIO;
    wcscpy(pattern, w);
    wcscat(pattern, L"\\*");
    WIN32_FIND_DATAW found;
    HANDLE h = FindFirstFileExW(pattern, FindExInfoBasic, &found, FindExSearchNameMatch, NULL, 0);
    free(pattern);
    int code = SFD_OK;
    if (h != INVALID_HANDLE_VALUE) {
      do {
        if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
        wchar_t *child = malloc(sizeof(wchar_t) * (n + wcslen(found.cFileName) + 2));
        if (child == NULL) {
          code = SFD_EIO;
          break;
        }
        wcscpy(child, w);
        wcscat(child, L"\\");
        wcscat(child, found.cFileName);
        int c = rm_w(child);
        free(child);
        if (c != SFD_OK && code == SFD_OK) code = c;
      } while (FindNextFileW(h, &found));
      FindClose(h);
    }
    if (code != SFD_OK) return code;
  }
  return RemoveDirectoryW(w) ? SFD_OK : failed(GetLastError());
}

int sfd_rm(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return SFD_ENOENT;
  int code = rm_w(w);
  free(w);
  return code;
}

/// libuv's fs__unlink: a file (read-only too), a link to a folder or a junction; a folder itself refused (EPERM).
int sfd_unlink(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path, NULL);
  if (w == NULL) return SFD_ENOENT;
  DWORD a = GetFileAttributesW(w);
  int code;
  if (a == INVALID_FILE_ATTRIBUTES) code = failed(GetLastError());
  else if ((a & FILE_ATTRIBUTE_DIRECTORY) && !(a & FILE_ATTRIBUTE_REPARSE_POINT)) code = SFD_EPERM;
  else {
    if (a & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(w, a & ~FILE_ATTRIBUTE_READONLY);
    BOOL ok = (a & FILE_ATTRIBUTE_DIRECTORY) ? RemoveDirectoryW(w) : DeleteFileW(w);
    code = ok ? SFD_OK : failed(GetLastError());
  }
  free(w);
  return code;
}

/// uv_fs_copyfile with COPYFILE_EXCL (FICLONE is no matter on Windows).
int sfd_copy(moonbit_bytes_t from, moonbit_bytes_t to) {
  wchar_t *a = wide((const char *)from, NULL), *b = wide((const char *)to, NULL);
  int code = a == NULL || b == NULL ? SFD_ENOENT : CopyFileExW(a, b, NULL, NULL, NULL, COPY_FILE_FAIL_IF_EXISTS) ? SFD_OK : failed(GetLastError());
  free(a);
  free(b);
  return code;
}

int sfd_opendir(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path, L"\\*");
  if (w == NULL) return SFD_ENOENT;
  WIN32_FIND_DATAW found;
  HANDLE h = FindFirstFileExW(w, FindExInfoBasic, &found, FindExSearchNameMatch, NULL, 0);
  free(w);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    return e == ERROR_FILE_NOT_FOUND ? SFD_ENOENT : failed(e);
  }
  FindClose(h);
  return SFD_OK;
}

static int write_new(const char *path, DWORD disposition, moonbit_bytes_t data, int sync) {
  wchar_t *w = wide(path, NULL);
  if (w == NULL) return SFD_ENOENT;
  HANDLE h = CreateFileW(w, GENERIC_WRITE, SHARE_ALL, NULL, disposition, FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return failed(GetLastError());
  int code = write_all(h, (const char *)data, (size_t)Moonbit_array_length(data), 0);
  if (code == SFD_OK && sync && !FlushFileBuffers(h)) code = failed(GetLastError());
  CloseHandle(h);
  return code;
}

int sfd_create_excl(moonbit_bytes_t path, moonbit_bytes_t data) { return write_new((const char *)path, CREATE_NEW, data, 0); }

int sfd_write_private(moonbit_bytes_t path, moonbit_bytes_t tmp, moonbit_bytes_t data) {
  char *dir = strdup((const char *)path);
  if (dir != NULL) {
    size_t len = strlen(dir), root = root_end(dir);
    while (len > root && !is_sep_w(dir[len - 1])) len--;
    while (len > root && is_sep_w(dir[len - 1])) len--;
    if (len > root) {
      dir[len] = 0;
      int c = sfd_mkdir((moonbit_bytes_t)dir, 1, 0777);
      if (c != SFD_OK) {
        free(dir);
        return c;
      }
    }
    free(dir);
  }
  int code = write_new((const char *)tmp, CREATE_ALWAYS, data, 1);
  if (code != SFD_OK) return code;
  return sfd_rename(tmp, path);
}

void sfd_local(double ms, int32_t *out) {
  double secs = ms / 1000.0;
  time_t t = (time_t)secs;
  if ((double)t > secs) t -= 1;
  struct tm tm;
  if (localtime_s(&tm, &t) != 0) {
    memset(out, 0, sizeof(int32_t) * 6);
    return;
  }
  out[0] = tm.tm_year + 1900;
  out[1] = tm.tm_mon;
  out[2] = tm.tm_mday;
  out[3] = tm.tm_hour;
  out[4] = tm.tm_min;
  out[5] = tm.tm_sec;
}

double sfd_local_ms(int32_t year, int32_t month, int32_t day) {
  struct tm tm;
  memset(&tm, 0, sizeof tm);
  tm.tm_year = year - 1900;
  tm.tm_mon = month;
  tm.tm_mday = day;
  tm.tm_isdst = -1;
  return (double)mktime(&tm) * 1000.0;
}

int32_t sfd_uid(void) { return -1; }

/// process.env[name], read in UTF-16 (a path of any letters).
moonbit_bytes_t sfd_getenv(moonbit_bytes_t name, int32_t *found) {
  wchar_t *w = wide((const char *)name, NULL);
  const wchar_t *v = w == NULL ? NULL : _wgetenv(w);
  free(w);
  found[0] = v != NULL;
  buf_t out = {0};
  if (v != NULL) narrow_add(&out, v, -1);
  return buf_bytes(&out);
}

moonbit_bytes_t sfd_random(int32_t n) {
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  if (n > 0 && BCryptGenRandom(NULL, out, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) abort();
  return out;
}

int32_t sfd_pid(void) { return (int32_t)_getpid(); }

double sfd_now_ms(void) {
  FILETIME t;
  GetSystemTimeAsFileTime(&t);
  return (double)(int64_t)(ms_of(t));
}

/// process.cwd().
moonbit_bytes_t sfd_cwd(void) {
  buf_t out = {0};
  DWORD n = GetCurrentDirectoryW(0, NULL);
  wchar_t *w = n == 0 ? NULL : malloc(sizeof(wchar_t) * n);
  if (w != NULL && GetCurrentDirectoryW(n, w) != 0) narrow_add(&out, w, -1);
  free(w);
  return buf_bytes(&out);
}

#else

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __APPLE__
#include <copyfile.h>
#endif
#ifdef __linux__
#include <sys/ioctl.h>
#include <linux/fs.h>
#endif

static int failed(int e) {
  switch (e) {
    case ENOENT: return SFD_ENOENT;
    case EACCES: return SFD_EACCES;
    case EPERM: return SFD_EPERM;
    case EEXIST: return SFD_EEXIST;
    case ENOTEMPTY: return SFD_ENOTEMPTY;
    case EISDIR: return SFD_EISDIR;
    case ENOTDIR: return SFD_ENOTDIR;
    case ENOSPC: return SFD_ENOSPC;
    case EXDEV: return SFD_EXDEV;
    case EROFS: return SFD_EROFS;
    case ELOOP: return SFD_ELOOP;
    case EINVAL: return SFD_EINVAL;
    case EBUSY: return SFD_EBUSY;
    case ENAMETOOLONG: return SFD_ENAMETOOLONG;
    case EMFILE: return SFD_EMFILE;
    default: return SFD_EIO;
  }
}

/// Node's mtimeMs: seconds × 1000 + nanoseconds / 1e6, as a double.
static double mtime_ms(const struct stat *st) {
#ifdef __APPLE__
  return (double)st->st_mtimespec.tv_sec * 1e3 + (double)st->st_mtimespec.tv_nsec / 1e6;
#else
  return (double)st->st_mtim.tv_sec * 1e3 + (double)st->st_mtim.tv_nsec / 1e6;
#endif
}

static void stat_out(const struct stat *st, double *out) {
  out[0] = S_ISLNK(st->st_mode) ? 3 : S_ISDIR(st->st_mode) ? 2 : S_ISREG(st->st_mode) ? 1 : 0;
  out[1] = (double)st->st_size;
  out[2] = mtime_ms(st);
  out[3] = (double)st->st_dev;
}

/// `path`'s stat (links followed with `follow`, else lstat) into `out`: kind (0 other, 1 file, 2 folder, 3 link), size,
/// mtimeMs, device. 0, or what failed.
int sfd_stat(moonbit_bytes_t path, int32_t follow, double *out) {
  struct stat st;
  int r = follow ? stat((const char *)path, &st) : lstat((const char *)path, &st);
  if (r != 0) return failed(errno);
  stat_out(&st, out);
  return SFD_OK;
}

typedef struct {
  char *name;
  char kind;
} dent_t;

static int by_name(const void *a, const void *b) { return strcmp(((const dent_t *)a)->name, ((const dent_t *)b)->name); }

/// The entries of the folder `path` (but `.` and `..`), each its kind ('f' file, 'd' folder, 'l' link, 'o' other, as
/// the folder says it, links not followed) then its name and a NUL, sorted by their bytes as libuv's scandir sorts them;
/// none, with what failed in err[0].
moonbit_bytes_t sfd_readdir(moonbit_bytes_t path, int32_t *err) {
  buf_t out = {0};
  err[0] = SFD_OK;
  DIR *d = opendir((const char *)path);
  if (d == NULL) {
    err[0] = failed(errno);
    return buf_bytes(&out);
  }
  dent_t *all = NULL;
  size_t count = 0, cap = 0;
  struct dirent *e;
  for (;;) {
    errno = 0;
    e = readdir(d);
    if (e == NULL) break;
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    if (count == cap) {
      cap = cap == 0 ? 64 : cap * 2;
      dent_t *grown = realloc(all, sizeof(dent_t) * cap);
      if (grown == NULL) break;
      all = grown;
    }
    char kind = 'o';
#ifdef DT_DIR
    if (e->d_type == DT_DIR) kind = 'd';
    else if (e->d_type == DT_REG) kind = 'f';
    else if (e->d_type == DT_LNK) kind = 'l';
    else if (e->d_type == DT_UNKNOWN) {
#endif
      struct stat st;
      char *full = malloc(strlen((const char *)path) + strlen(e->d_name) + 2);
      if (full != NULL) {
        sprintf(full, "%s/%s", (const char *)path, e->d_name);
        if (lstat(full, &st) == 0) kind = S_ISLNK(st.st_mode) ? 'l' : S_ISDIR(st.st_mode) ? 'd' : S_ISREG(st.st_mode) ? 'f' : 'o';
        free(full);
      }
#ifdef DT_DIR
    }
#endif
    all[count].name = strdup(e->d_name);
    all[count].kind = kind;
    if (all[count].name != NULL) count++;
  }
  if (e == NULL && errno != 0) err[0] = failed(errno);
  closedir(d);
  if (count > 1) qsort(all, count, sizeof(dent_t), by_name);
  for (size_t i = 0; i < count; i++) {
    if (err[0] == SFD_OK) {
      buf_add(&out, &all[i].kind, 1);
      buf_add(&out, all[i].name, strlen(all[i].name) + 1);
    }
    free(all[i].name);
  }
  free(all);
  if (err[0] != SFD_OK) {
    free(out.data);
    out = (buf_t){0};
  }
  return buf_bytes(&out);
}

/// realpath(3) of `path`, as libuv's uv_fs_realpath gives it; none, with what failed in err[0].
moonbit_bytes_t sfd_realpath(moonbit_bytes_t path, int32_t *err) {
  err[0] = SFD_OK;
  char *got = realpath((const char *)path, NULL);
  if (got == NULL) {
    err[0] = failed(errno);
    return empty_bytes();
  }
  buf_t out = {0};
  buf_add(&out, got, strlen(got));
  free(got);
  return buf_bytes(&out);
}

/// Up to `length` bytes of the file `path` from `offset` (fewer at its end, none past it), as fs.ts `direct.read` reads
/// them: out[0] its size, out[1] its mtimeMs; EISDIR for a folder.
moonbit_bytes_t sfd_read(moonbit_bytes_t path, double offset, double length, double *out, int32_t *err) {
  err[0] = SFD_OK;
  int fd = open((const char *)path, O_RDONLY);
  if (fd < 0) {
    err[0] = failed(errno);
    return empty_bytes();
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    err[0] = failed(errno);
    close(fd);
    return empty_bytes();
  }
  if (S_ISDIR(st.st_mode)) {
    err[0] = SFD_EISDIR;
    close(fd);
    return empty_bytes();
  }
  out[0] = (double)st.st_size;
  out[1] = mtime_ms(&st);
  double want = (double)st.st_size - offset;
  if (want > length) want = length;
  if (want < 0) want = 0;
  size_t n = (size_t)want;
  char *data = n > 0 ? malloc(n) : NULL;
  size_t got = 0;
  while (got < n) {
    ssize_t r = pread(fd, data + got, n - got, (off_t)offset + (off_t)got);
    if (r < 0) {
      if (errno == EINTR) continue;
      err[0] = failed(errno);
      break;
    }
    if (r == 0) break;
    got += (size_t)r;
  }
  close(fd);
  if (err[0] != SFD_OK) {
    free(data);
    return empty_bytes();
  }
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)got, 0);
  if (got > 0) memcpy(bytes, data, got);
  free(data);
  return bytes;
}

/// fs.ts `direct.write`: `data` written at `offset` of `path` (made anew with `create`, as open's "w", else opened "r+"),
/// nothing written where it is shorter than `at_least` (≥ 0) (out[1] 1), truncated to `truncate_to` (≥ 0) and synced
/// as asked; out[0] its size after.
int sfd_write(moonbit_bytes_t path, int32_t create, double offset, moonbit_bytes_t data, double at_least, double truncate_to, int32_t sync, double *out) {
  int fd = create ? open((const char *)path, O_WRONLY | O_CREAT | O_TRUNC, 0666) : open((const char *)path, O_RDWR);
  if (fd < 0) return failed(errno);
  struct stat st;
  int code = SFD_OK;
  out[1] = 0;
  if (fstat(fd, &st) != 0) {
    code = failed(errno);
    goto done;
  }
  if (at_least >= 0 && (double)st.st_size < at_least) {
    out[0] = (double)st.st_size;
    out[1] = 1;
    goto done;
  }
  size_t n = (size_t)Moonbit_array_length(data);
  size_t put = 0;
  while (put < n) {
    ssize_t w = pwrite(fd, (const char *)data + put, n - put, (off_t)offset + (off_t)put);
    if (w < 0) {
      if (errno == EINTR) continue;
      code = failed(errno);
      goto done;
    }
    put += (size_t)w;
  }
  if (truncate_to >= 0 && ftruncate(fd, (off_t)truncate_to) != 0) {
    code = failed(errno);
    goto done;
  }
  if (sync && fsync(fd) != 0) {
    code = failed(errno);
    goto done;
  }
  if (fstat(fd, &st) != 0) {
    code = failed(errno);
    goto done;
  }
  out[0] = (double)st.st_size;
done:
  close(fd);
  return code;
}

int sfd_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  return rename((const char *)from, (const char *)to) == 0 ? SFD_OK : failed(errno);
}

/// mkdir, or with `recursive` as Node's `mkdir(path, { recursive: true })`: those it is in made, one there already a
/// folder no failure (a file there EEXIST, a file on the way ENOTDIR).
int sfd_mkdir(moonbit_bytes_t path, int32_t recursive, int32_t mode) {
  const char *p = (const char *)path;
  if (mkdir(p, (mode_t)mode) == 0) return SFD_OK;
  int e = errno;
  if (!recursive) return failed(e);
  if (e == EEXIST) {
    struct stat st;
    if (stat(p, &st) == 0 && S_ISDIR(st.st_mode)) return SFD_OK;
    return SFD_EEXIST;
  }
  if (e != ENOENT) return failed(e);
  size_t len = strlen(p);
  char *copy = strdup(p);
  if (copy == NULL) return SFD_EIO;
  while (len > 1 && copy[len - 1] == '/') copy[--len] = 0;
  char *slash = strrchr(copy, '/');
  if (slash == NULL || slash == copy) {
    free(copy);
    return failed(e);
  }
  *slash = 0;
  int up = sfd_mkdir((moonbit_bytes_t)copy, 1, mode);
  free(copy);
  if (up != SFD_OK) return up;
  if (mkdir(p, (mode_t)mode) == 0) return SFD_OK;
  e = errno;
  if (e == EEXIST) {
    struct stat st;
    if (stat(p, &st) == 0 && S_ISDIR(st.st_mode)) return SFD_OK;
  }
  return failed(e);
}

static int rm_tree(const char *p) {
  struct stat st;
  if (lstat(p, &st) != 0) return failed(errno);
  if (!S_ISDIR(st.st_mode)) return unlink(p) == 0 ? SFD_OK : failed(errno);
  DIR *d = opendir(p);
  if (d == NULL) return failed(errno);
  struct dirent *e;
  int code = SFD_OK;
  size_t plen = strlen(p);
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    char *full = malloc(plen + strlen(e->d_name) + 2);
    if (full == NULL) {
      code = SFD_EIO;
      break;
    }
    sprintf(full, "%s/%s", p, e->d_name);
    int c = rm_tree(full);
    free(full);
    if (c != SFD_OK && code == SFD_OK) code = c;
  }
  closedir(d);
  if (code != SFD_OK) return code;
  return rmdir(p) == 0 ? SFD_OK : failed(errno);
}

/// Node's `rm(path, { recursive: true })`: a folder with all it holds, anything else itself (a link too).
int sfd_rm(moonbit_bytes_t path) { return rm_tree((const char *)path); }

int sfd_unlink(moonbit_bytes_t path) { return unlink((const char *)path) == 0 ? SFD_OK : failed(errno); }

/// copyFile(from, to, COPYFILE_EXCL | COPYFILE_FICLONE) as libuv's uv_fs_copyfile makes it: macOS's copyfile(3) with
/// COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL; elsewhere `to` made anew with `from`'s mode, cloned where the file
/// system can (FICLONE), else its bytes copied.
int sfd_copy(moonbit_bytes_t from, moonbit_bytes_t to) {
#ifdef __APPLE__
  if (copyfile((const char *)from, (const char *)to, NULL, COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL) != 0) return failed(errno);
  return SFD_OK;
#else
  int in = open((const char *)from, O_RDONLY);
  if (in < 0) return failed(errno);
  struct stat st;
  if (fstat(in, &st) != 0) {
    int e = failed(errno);
    close(in);
    return e;
  }
  int out = open((const char *)to, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 07777);
  if (out < 0) {
    int e = failed(errno);
    close(in);
    return e;
  }
  int code = SFD_OK;
  if (fchmod(out, st.st_mode & 07777) != 0) {
    code = failed(errno);
    goto done;
  }
#ifdef FICLONE
  if (ioctl(out, FICLONE, in) == 0) goto done;
#endif
  {
    char buf[1 << 16];
    for (;;) {
      ssize_t r = read(in, buf, sizeof buf);
      if (r < 0) {
        if (errno == EINTR) continue;
        code = failed(errno);
        break;
      }
      if (r == 0) break;
      ssize_t put = 0;
      while (put < r) {
        ssize_t w = write(out, buf + put, (size_t)(r - put));
        if (w < 0) {
          if (errno == EINTR) continue;
          code = failed(errno);
          goto done;
        }
        put += w;
      }
    }
  }
done:
  close(in);
  close(out);
  if (code != SFD_OK) unlink((const char *)to);
  return code;
#endif
}

/// Whether the folder `path` opens (opendir, closed at once): 0, or what failed.
int sfd_opendir(moonbit_bytes_t path) {
  DIR *d = opendir((const char *)path);
  if (d == NULL) return failed(errno);
  closedir(d);
  return SFD_OK;
}

/// A file made at `path` only where none is (O_CREAT | O_EXCL, mode 0600), `data` written in it.
int sfd_create_excl(moonbit_bytes_t path, moonbit_bytes_t data) {
  int fd = open((const char *)path, O_CREAT | O_EXCL | O_WRONLY, 0600);
  if (fd < 0) return failed(errno);
  size_t n = (size_t)Moonbit_array_length(data), put = 0;
  int code = SFD_OK;
  while (put < n) {
    ssize_t w = write(fd, (const char *)data + put, n - put);
    if (w < 0) {
      if (errno == EINTR) continue;
      code = failed(errno);
      break;
    }
    put += (size_t)w;
  }
  close(fd);
  return code;
}

/// ops/files.ts `writePrivateSoon`: `data` written to `tmp` (made anew, 0600), synced, renamed to `path`; the folder
/// made first.
int sfd_write_private(moonbit_bytes_t path, moonbit_bytes_t tmp, moonbit_bytes_t data) {
  char *dir = strdup((const char *)path);
  if (dir != NULL) {
    char *slash = strrchr(dir, '/');
    if (slash != NULL && slash != dir) {
      *slash = 0;
      int c = sfd_mkdir((moonbit_bytes_t)dir, 1, 0777);
      if (c != SFD_OK) {
        free(dir);
        return c;
      }
    }
    free(dir);
  }
  int fd = open((const char *)tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return failed(errno);
  size_t n = (size_t)Moonbit_array_length(data), put = 0;
  int code = SFD_OK;
  while (put < n) {
    ssize_t w = write(fd, (const char *)data + put, n - put);
    if (w < 0) {
      if (errno == EINTR) continue;
      code = failed(errno);
      break;
    }
    put += (size_t)w;
  }
  if (code == SFD_OK && fsync(fd) != 0) code = failed(errno);
  close(fd);
  if (code != SFD_OK) return code;
  return rename((const char *)tmp, (const char *)path) == 0 ? SFD_OK : failed(errno);
}

/// A time (ms) in the machine's local time: year, month (0-11), day, hours, minutes, seconds (as Date's getters).
void sfd_local(double ms, int32_t *out) {
  double secs = ms / 1000.0;
  time_t t = (time_t)secs;
  if ((double)t > secs) t -= 1;
  struct tm tm;
  if (localtime_r(&t, &tm) == NULL) {
    memset(out, 0, sizeof(int32_t) * 6);
    return;
  }
  out[0] = tm.tm_year + 1900;
  out[1] = tm.tm_mon;
  out[2] = tm.tm_mday;
  out[3] = tm.tm_hour;
  out[4] = tm.tm_min;
  out[5] = tm.tm_sec;
}

/// `new Date(year, month, day).getTime()`: local midnight of that day, in ms.
double sfd_local_ms(int32_t year, int32_t month, int32_t day) {
  struct tm tm;
  memset(&tm, 0, sizeof tm);
  tm.tm_year = year - 1900;
  tm.tm_mon = month;
  tm.tm_mday = day;
  tm.tm_isdst = -1;
  return (double)mktime(&tm) * 1000.0;
}

int32_t sfd_uid(void) { return (int32_t)getuid(); }

/// getenv(`name`): its value, found[0] 1 where it is set.
moonbit_bytes_t sfd_getenv(moonbit_bytes_t name, int32_t *found) {
  const char *v = getenv((const char *)name);
  found[0] = v != NULL;
  if (v == NULL) return empty_bytes();
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)strlen(v), 0);
  if (strlen(v) > 0) memcpy(out, v, strlen(v));
  return out;
}

/// `n` random bytes from the system's source (crypto.randomUUID's, crypto.randomBytes').
#ifdef __APPLE__
moonbit_bytes_t sfd_random(int32_t n) {
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  arc4random_buf(out, (size_t)n);
  return out;
}
#else
#include <sys/random.h>
moonbit_bytes_t sfd_random(int32_t n) {
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  size_t got = 0;
  while (got < (size_t)n) {
    ssize_t r = getrandom(out + got, (size_t)n - got, 0);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) abort();
    got += (size_t)r;
  }
  return out;
}
#endif

int32_t sfd_pid(void) { return (int32_t)getpid(); }

/// The machine's time in ms (Date.now's clock).
#include <sys/time.h>
double sfd_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (double)tv.tv_sec * 1000.0 + (double)(tv.tv_usec / 1000);
}

/// process.cwd().
moonbit_bytes_t sfd_cwd(void) {
  char buf[4096];
  if (getcwd(buf, sizeof buf) == NULL) return empty_bytes();
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)strlen(buf), 0);
  memcpy(out, buf, strlen(buf));
  return out;
}

#endif

/// Which system the program runs on: 1 macOS, 2 Windows, 0 another (Linux).
int32_t sfd_platform(void) {
#if defined(__APPLE__)
  return 1;
#elif defined(_WIN32)
  return 2;
#else
  return 0;
#endif
}
