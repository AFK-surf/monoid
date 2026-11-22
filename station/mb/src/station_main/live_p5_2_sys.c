// What the agents' side of the station (live_p5_2_*.mbt) asks of the files and processes that neither the shell nor
// station/mb's drive does: a file appended to, a symbolic and a hard link, a tree removed, a file written with its mode,
// a process's start time and whether a process group is there. Each path is UTF-8, ended by a NUL; each answers 0 for
// done, else the system's error number (a process's start, milliseconds since the epoch, or -1 where it is not known).
// On Windows the same through Win32's wide calls.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>

static wchar_t *sfl_wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)(n > 0 ? n : 1));
  if (w == NULL) return NULL;
  if (n <= 0) {
    w[0] = 0;
    return w;
  }
  MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static int32_t sfl_err(void) {
  DWORD e = GetLastError();
  return e == 0 ? 1 : (int32_t)e;
}

int32_t sflive_append(moonbit_bytes_t path, moonbit_bytes_t data) {
  wchar_t *w = sfl_wide((const char *)path);
  HANDLE h = CreateFileW(w, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return sfl_err();
  size_t len = (size_t)Moonbit_array_length(data), at = 0;
  while (at < len) {
    DWORD n = 0;
    if (!WriteFile(h, data + at, (DWORD)(len - at), &n, NULL)) {
      int32_t e = sfl_err();
      CloseHandle(h);
      return e;
    }
    at += n;
  }
  CloseHandle(h);
  return 0;
}

int32_t sflive_write(moonbit_bytes_t path, moonbit_bytes_t data, int32_t mode) {
  (void)mode;
  wchar_t *w = sfl_wide((const char *)path);
  HANDLE h = CreateFileW(w, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return sfl_err();
  size_t len = (size_t)Moonbit_array_length(data), at = 0;
  while (at < len) {
    DWORD n = 0;
    if (!WriteFile(h, data + at, (DWORD)(len - at), &n, NULL)) {
      int32_t e = sfl_err();
      CloseHandle(h);
      return e;
    }
    at += n;
  }
  CloseHandle(h);
  return 0;
}

int32_t sflive_symlink(moonbit_bytes_t target, moonbit_bytes_t path) {
  wchar_t *t = sfl_wide((const char *)target), *p = sfl_wide((const char *)path);
  DWORD attrs = GetFileAttributesW(t);
  DWORD flags = 0x2; // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
  if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
  BOOL ok = CreateSymbolicLinkW(p, t, flags);
  int32_t e = ok ? 0 : sfl_err();
  free(t);
  free(p);
  return e;
}

int32_t sflive_link(moonbit_bytes_t from, moonbit_bytes_t to) {
  wchar_t *f = sfl_wide((const char *)from), *t = sfl_wide((const char *)to);
  BOOL ok = CreateHardLinkW(t, f, NULL);
  int32_t e = ok ? 0 : sfl_err();
  free(f);
  free(t);
  return e;
}

double sflive_start_time(int32_t pid) {
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
  if (h == NULL) return -1.0;
  FILETIME created, exited, kernel, user;
  double ms = -1.0;
  if (GetProcessTimes(h, &created, &exited, &kernel, &user)) {
    ULARGE_INTEGER t;
    t.LowPart = created.dwLowDateTime;
    t.HighPart = created.dwHighDateTime;
    // (100 ns since 1601 to ms since 1970)
    ms = (double)(t.QuadPart / 10000ULL) - 11644473600000.0;
  }
  CloseHandle(h);
  return ms;
}

int32_t sflive_cloexec_all(void) { return 0; }

int32_t sflive_group_alive(int32_t pgid) {
  // (Windows has no process groups as Unix's: the group's leader alive stands for it)
  HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pgid);
  if (h == NULL) return 0;
  DWORD r = WaitForSingleObject(h, 0);
  CloseHandle(h);
  return r == WAIT_TIMEOUT ? 1 : 0;
}

#else
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#endif

static int32_t sfl_write_all(int fd, const uint8_t *p, size_t len) {
  size_t at = 0;
  while (at < len) {
    ssize_t n = write(fd, p + at, len - at);
    if (n < 0) {
      if (errno == EINTR) continue;
      return errno;
    }
    at += (size_t)n;
  }
  return 0;
}

int32_t sflive_append(moonbit_bytes_t path, moonbit_bytes_t data) {
  int fd = open((const char *)path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  if (fd < 0) return errno;
  int32_t e = sfl_write_all(fd, data, (size_t)Moonbit_array_length(data));
  close(fd);
  return e;
}

int32_t sflive_write(moonbit_bytes_t path, moonbit_bytes_t data, int32_t mode) {
  int fd = open((const char *)path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode > 0 ? (mode_t)mode : 0644);
  if (fd < 0) return errno;
  if (mode > 0) fchmod(fd, (mode_t)mode);
  int32_t e = sfl_write_all(fd, data, (size_t)Moonbit_array_length(data));
  close(fd);
  return e;
}

int32_t sflive_symlink(moonbit_bytes_t target, moonbit_bytes_t path) {
  return symlink((const char *)target, (const char *)path) == 0 ? 0 : errno;
}

int32_t sflive_link(moonbit_bytes_t from, moonbit_bytes_t to) {
  return link((const char *)from, (const char *)to) == 0 ? 0 : errno;
}

double sflive_start_time(int32_t pid) {
#ifdef __APPLE__
  struct proc_bsdinfo info;
  int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info);
  if (n != (int)sizeof info) return -1.0;
  return (double)info.pbi_start_tvsec * 1000.0 + (double)info.pbi_start_tvusec / 1000.0;
#elif defined(__linux__)
  char file[64];
  snprintf(file, sizeof file, "/proc/%d/stat", (int)pid);
  FILE *f = fopen(file, "r");
  if (f == NULL) return -1.0;
  char buf[2048];
  size_t got = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[got] = 0;
  char *close_paren = strrchr(buf, ')');
  if (close_paren == NULL) return -1.0;
  // (the 22nd field, the start in clock ticks after boot; fields from the 3rd on follow the name)
  char *p = close_paren + 2;
  int field = 3;
  while (*p && field < 22) {
    if (*p == ' ') field++;
    p++;
  }
  unsigned long long ticks = strtoull(p, NULL, 10);
  long hz = sysconf(_SC_CLK_TCK);
  FILE *u = fopen("/proc/uptime", "r");
  if (u == NULL || hz <= 0) {
    if (u) fclose(u);
    return -1.0;
  }
  double up = 0;
  if (fscanf(u, "%lf", &up) != 1) up = 0;
  fclose(u);
  struct timeval now;
  gettimeofday(&now, NULL);
  double now_ms = (double)now.tv_sec * 1000.0 + (double)now.tv_usec / 1000.0;
  return now_ms - up * 1000.0 + (double)ticks * 1000.0 / (double)hz;
#else
  (void)pid;
  return -1.0;
#endif
}

/// Every descriptor this process holds past stdio kept from what it starts (FD_CLOEXEC): the launcher's sockets and
/// channel (`--launcher-fds`) are given it without, and a runner that kept them would keep the station's door and its
/// channel open after the station is gone. How many were marked.
int32_t sflive_cloexec_all(void) {
  int32_t n = 0;
  long most = sysconf(_SC_OPEN_MAX);
  if (most <= 0 || most > 65536) most = 65536;
  for (int fd = 3; fd < most; fd++) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) continue;
    if (!(flags & FD_CLOEXEC) && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0) n++;
  }
  return n;
}

int32_t sflive_group_alive(int32_t pgid) {
  if (pgid <= 0) return 0;
  return kill(-pgid, 0) == 0 || errno == EPERM ? 1 : 0;
}
#endif
