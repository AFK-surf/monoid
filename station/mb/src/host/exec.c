// Cross-platform process replacement (execv on Unix, CreateProcessW + Job Object on Windows)
// and tiny OS lookups used by the reader's station_shim and reader_harness's reader fallback.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
#define PROC_THREAD_ATTRIBUTE_JOB_LIST ((SIZE_T)0x0002000D)
#endif
#else
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif

#ifndef _WIN32
static moonbit_bytes_t bytes_from_cstr(const char *s) {
  if (s == NULL || s[0] == '\0') return moonbit_make_bytes(0, 0);
  size_t n = strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, s, n);
  return out;
}
#endif

/// Compile-time host OS check (never guessed from environment variables or path separators).
int32_t sfh_is_windows(void) {
#ifdef _WIN32
  return 1;
#else
  return 0;
#endif
}

#ifdef _WIN32
static wchar_t *utf8_to_wide(const char *s) {
  int need = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (need <= 0) return NULL;
  wchar_t *w = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
  if (w == NULL) return NULL;
  if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, need) <= 0) {
    free(w);
    return NULL;
  }
  return w;
}

static moonbit_bytes_t wide_to_bytes(const wchar_t *w) {
  if (w == NULL || w[0] == L'\0') return moonbit_make_bytes(0, 0);
  size_t wlen_sz = wcslen(w);
  if (wlen_sz == 0 || wlen_sz > (size_t)INT32_MAX) return moonbit_make_bytes(0, 0);
  int wlen = (int)wlen_sz;
  int need = WideCharToMultiByte(CP_UTF8, 0, w, wlen, NULL, 0, NULL, NULL);
  if (need <= 0) {
    fprintf(stderr, "stillfail-reader: WideCharToMultiByte sizing failed (error %lu)\n", (unsigned long)GetLastError());
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)need, 0);
  int wrote = WideCharToMultiByte(CP_UTF8, 0, w, wlen, (char *)out, need, NULL, NULL);
  if (wrote != need) {
    fprintf(stderr, "stillfail-reader: WideCharToMultiByte conversion failed (error %lu)\n", (unsigned long)GetLastError());
    return moonbit_make_bytes(0, 0);
  }
  return out;
}

static int win_is_file_w(const wchar_t *w) {
  DWORD attr = GetFileAttributesW(w);
  return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

static int win_has_exe_suffix(const wchar_t *w, size_t len) {
  if (len < 4) return 0;
  const wchar_t *tail = w + len - 4;
  return tail[0] == L'.' &&
         (tail[1] == L'e' || tail[1] == L'E') &&
         (tail[2] == L'x' || tail[2] == L'X') &&
         (tail[3] == L'e' || tail[3] == L'E');
}
#endif

/// Returns the value of environment variable `name` (NUL-terminated UTF-8), or empty bytes if unset/empty.
moonbit_bytes_t sfh_env_get(moonbit_bytes_t name) {
  const char *key = (const char *)name;
#ifdef _WIN32
  wchar_t *wkey = utf8_to_wide(key);
  if (wkey == NULL) return moonbit_make_bytes(0, 0);
  DWORD need = GetEnvironmentVariableW(wkey, NULL, 0);
  if (need == 0) {
    free(wkey);
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wval = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
  if (wval == NULL) {
    free(wkey);
    return moonbit_make_bytes(0, 0);
  }
  DWORD got = GetEnvironmentVariableW(wkey, wval, need);
  free(wkey);
  moonbit_bytes_t out = (got > 0 && got < need) ? wide_to_bytes(wval) : moonbit_make_bytes(0, 0);
  free(wval);
  return out;
#else
  return bytes_from_cstr(getenv(key));
#endif
}

/// Sets environment variable `name` to `val` (both NUL-terminated UTF-8). Returns 1 on success, 0 on failure.
int32_t sfh_env_set(moonbit_bytes_t name, moonbit_bytes_t val) {
  const char *k = (const char *)name;
  const char *v = (const char *)val;
#ifdef _WIN32
  wchar_t *wk = utf8_to_wide(k);
  wchar_t *wv = utf8_to_wide(v);
  int ok = wk != NULL && wv != NULL && SetEnvironmentVariableW(wk, wv) != 0;
  free(wk);
  free(wv);
  return ok ? 1 : 0;
#else
  return setenv(k, v, 1) == 0 ? 1 : 0;
#endif
}

/// Unsets environment variable `name` (NUL-terminated UTF-8). Returns 1 on success, 0 on failure.
int32_t sfh_env_unset(moonbit_bytes_t name) {
  const char *k = (const char *)name;
#ifdef _WIN32
  wchar_t *wk = utf8_to_wide(k);
  int ok = wk != NULL && SetEnvironmentVariableW(wk, NULL) != 0;
  free(wk);
  return ok ? 1 : 0;
#else
  return unsetenv(k) == 0 ? 1 : 0;
#endif
}

/// Returns the current working directory (UTF-8), or empty bytes on failure.
moonbit_bytes_t sfh_getcwd(void) {
#ifdef _WIN32
  DWORD need = GetCurrentDirectoryW(0, NULL);
  if (need == 0) return moonbit_make_bytes(0, 0);
  wchar_t *buf = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
  if (buf == NULL) return moonbit_make_bytes(0, 0);
  DWORD got = GetCurrentDirectoryW(need, buf);
  moonbit_bytes_t out = (got > 0 && got < need) ? wide_to_bytes(buf) : moonbit_make_bytes(0, 0);
  free(buf);
  return out;
#else
  char buf[PATH_MAX];
  if (getcwd(buf, sizeof(buf)) == NULL) return moonbit_make_bytes(0, 0);
  return bytes_from_cstr(buf);
#endif
}

/// Returns the canonical path of the current executable, or empty bytes on failure.
moonbit_bytes_t sfh_exe_path(void) {
#ifdef _WIN32
  DWORD cap = 512;
  wchar_t *buf = (wchar_t *)malloc((size_t)cap * sizeof(wchar_t));
  if (buf == NULL) return moonbit_make_bytes(0, 0);
  for (;;) {
    DWORD n = GetModuleFileNameW(NULL, buf, cap);
    if (n == 0) {
      free(buf);
      return moonbit_make_bytes(0, 0);
    }
    if (n < cap - 1) {
      moonbit_bytes_t out = wide_to_bytes(buf);
      free(buf);
      return out;
    }
    cap *= 2;
    wchar_t *next = (wchar_t *)realloc(buf, (size_t)cap * sizeof(wchar_t));
    if (next == NULL) {
      free(buf);
      return moonbit_make_bytes(0, 0);
    }
    buf = next;
  }
#elif defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(NULL, &size);
  if (size == 0) return moonbit_make_bytes(0, 0);
  char *raw = (char *)malloc((size_t)size + 1);
  if (raw == NULL) return moonbit_make_bytes(0, 0);
  if (_NSGetExecutablePath(raw, &size) != 0) {
    free(raw);
    return moonbit_make_bytes(0, 0);
  }
  char resolved[PATH_MAX];
  moonbit_bytes_t out = realpath(raw, resolved) != NULL ? bytes_from_cstr(resolved) : bytes_from_cstr(raw);
  free(raw);
  return out;
#else
  char buf[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return moonbit_make_bytes(0, 0);
  buf[n] = '\0';
  return bytes_from_cstr(buf);
#endif
}

/// Returns 1 if `path` (NUL-terminated UTF-8) exists and is a regular file (following symlinks).
int32_t sfh_is_file(moonbit_bytes_t path) {
  const char *p = (const char *)path;
  if (p[0] == '\0') return 0;
#ifdef _WIN32
  wchar_t *wp = utf8_to_wide(p);
  if (wp == NULL) return 0;
  int ok = win_is_file_w(wp);
  free(wp);
  return ok ? 1 : 0;
#else
  struct stat st;
  return stat(p, &st) == 0 && S_ISREG(st.st_mode) ? 1 : 0;
#endif
}

/// Returns 1 if `path` (NUL-terminated UTF-8) exists, is a regular file, and is executable.
int32_t sfh_is_executable_file(moonbit_bytes_t path) {
  const char *p = (const char *)path;
  if (p[0] == '\0') return 0;
#ifdef _WIN32
  return sfh_is_file(path);
#else
  struct stat st;
  return stat(p, &st) == 0 && S_ISREG(st.st_mode) && access(p, X_OK) == 0 ? 1 : 0;
#endif
}

/// Returns 1 if `a` and `b` refer to the same underlying file (by dev/ino on Unix, or volume+file index on Windows).
int32_t sfh_same_file(moonbit_bytes_t a, moonbit_bytes_t b) {
  const char *pa = (const char *)a;
  const char *pb = (const char *)b;
  if (pa[0] == '\0' || pb[0] == '\0') return 0;
#ifdef _WIN32
  wchar_t *wa = utf8_to_wide(pa);
  wchar_t *wb = utf8_to_wide(pb);
  if (wa == NULL || wb == NULL) {
    free(wa);
    free(wb);
    return 0;
  }
  HANDLE ha = CreateFileW(wa, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  HANDLE hb = CreateFileW(wb, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(wa);
  free(wb);
  int same = 0;
  if (ha != INVALID_HANDLE_VALUE && hb != INVALID_HANDLE_VALUE) {
    BY_HANDLE_FILE_INFORMATION ia, ib;
    if (GetFileInformationByHandle(ha, &ia) && GetFileInformationByHandle(hb, &ib)) {
      same = ia.dwVolumeSerialNumber == ib.dwVolumeSerialNumber &&
             ia.nFileIndexHigh == ib.nFileIndexHigh &&
             ia.nFileIndexLow == ib.nFileIndexLow;
    }
  }
  if (ha != INVALID_HANDLE_VALUE) CloseHandle(ha);
  if (hb != INVALID_HANDLE_VALUE) CloseHandle(hb);
  return same ? 1 : 0;
#else
  struct stat sa, sb;
  if (stat(pa, &sa) != 0 || stat(pb, &sb) != 0) return 0;
  return (sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino) ? 1 : 0;
#endif
}

/// Searches PATH directories for an executable named `name`.
/// Platform convention: Windows strictly excludes CWD from PATH lookup; Unix follows POSIX where an empty segment in a non-empty PATH denotes ".".
moonbit_bytes_t sfh_find_in_path(moonbit_bytes_t name) {
  const char *cmd = (const char *)name;
  if (cmd[0] == '\0') return moonbit_make_bytes(0, 0);
#ifdef _WIN32
  wchar_t *wcmd = utf8_to_wide(cmd);
  if (wcmd == NULL) return moonbit_make_bytes(0, 0);
  size_t cmd_len = wcslen(wcmd);
  DWORD need = GetEnvironmentVariableW(L"PATH", NULL, 0);
  if (need == 0) {
    free(wcmd);
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wpath = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
  if (wpath == NULL) {
    free(wcmd);
    return moonbit_make_bytes(0, 0);
  }
  DWORD got = GetEnvironmentVariableW(L"PATH", wpath, need);
  if (got == 0 || got >= need) {
    free(wpath);
    free(wcmd);
    return moonbit_make_bytes(0, 0);
  }
  int has_ext = win_has_exe_suffix(wcmd, cmd_len);
  const wchar_t *cur = wpath;
  for (;;) {
    const wchar_t *sep = wcschr(cur, L';');
    size_t dlen = sep != NULL ? (size_t)(sep - cur) : wcslen(cur);
    const wchar_t *dstart = cur;
    if (dlen >= 2 && dstart[0] == L'"' && dstart[dlen - 1] == L'"') {
      dstart++;
      dlen -= 2;
    }
    if (dlen > 0) {
      size_t need_slash = (dstart[dlen - 1] == L'\\' || dstart[dlen - 1] == L'/') ? 0 : 1;
      // Try with .exe first when bare name lacks .exe, else as given.
      for (int pass = 0; pass < (has_ext ? 1 : 2); pass++) {
        int add_exe = (!has_ext && pass == 0);
        size_t total = dlen + need_slash + cmd_len + (add_exe ? 4 : 0) + 1;
        wchar_t *cand = (wchar_t *)malloc(total * sizeof(wchar_t));
        if (cand == NULL) break;
        wmemcpy(cand, dstart, dlen);
        size_t pos = dlen;
        if (need_slash) cand[pos++] = L'\\';
        wmemcpy(cand + pos, wcmd, cmd_len);
        pos += cmd_len;
        if (add_exe) {
          wmemcpy(cand + pos, L".exe", 4);
          pos += 4;
        }
        cand[pos] = L'\0';
        if (win_is_file_w(cand)) {
          moonbit_bytes_t out = wide_to_bytes(cand);
          free(cand);
          free(wpath);
          free(wcmd);
          return out;
        }
        free(cand);
      }
    }
    if (sep == NULL) break;
    cur = sep + 1;
  }
  free(wpath);
  free(wcmd);
  return moonbit_make_bytes(0, 0);
#else
  const char *path_env = getenv("PATH");
  if (path_env == NULL || path_env[0] == '\0') return moonbit_make_bytes(0, 0);
  size_t cmd_len = strlen(cmd);
  const char *cur = path_env;
  for (;;) {
    const char *sep = strchr(cur, ':');
    size_t dir_len = sep != NULL ? (size_t)(sep - cur) : strlen(cur);
    // POSIX: an empty segment in a non-empty PATH (e.g. "/a:", ":/b", "/a::/b") means ".".
    const char *dir = dir_len > 0 ? cur : ".";
    size_t dlen = dir_len > 0 ? dir_len : 1;
    size_t need = dlen + 1 + cmd_len + 1;
    char *cand = (char *)malloc(need);
    if (cand == NULL) return moonbit_make_bytes(0, 0);
    memcpy(cand, dir, dlen);
    if (cand[dlen - 1] == '/') {
      memcpy(cand + dlen, cmd, cmd_len + 1);
    } else {
      cand[dlen] = '/';
      memcpy(cand + dlen + 1, cmd, cmd_len + 1);
    }
    struct stat st;
    int ok = stat(cand, &st) == 0 && S_ISREG(st.st_mode) && access(cand, X_OK) == 0;
    if (ok) {
      moonbit_bytes_t out = bytes_from_cstr(cand);
      free(cand);
      return out;
    }
    free(cand);
    if (sep == NULL) break;
    cur = sep + 1;
  }
  return moonbit_make_bytes(0, 0);
#endif
}

#ifdef _WIN32
typedef struct {
  wchar_t *data;
  size_t len;
  size_t cap;
} wbuf_t;

static int wbuf_push(wbuf_t *b, wchar_t c) {
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

/// Appends one argument formatted for Windows CommandLineToArgvW parsing rules.
static int wbuf_append_arg(wbuf_t *b, const wchar_t *arg) {
  int need_quotes = arg[0] == L'\0';
  for (const wchar_t *p = arg; !need_quotes && *p != L'\0'; p++) {
    if (*p == L' ' || *p == L'\t' || *p == L'\n' || *p == L'\v' || *p == L'"') {
      need_quotes = 1;
    }
  }
  if (!need_quotes) {
    for (const wchar_t *p = arg; *p != L'\0'; p++) {
      if (!wbuf_push(b, *p)) return 0;
    }
    return 1;
  }
  if (!wbuf_push(b, L'"')) return 0;
  size_t slashes = 0;
  for (const wchar_t *p = arg; *p != L'\0'; p++) {
    if (*p == L'\\') {
      slashes++;
    } else if (*p == L'"') {
      for (size_t i = 0; i < slashes * 2 + 1; i++) {
        if (!wbuf_push(b, L'\\')) return 0;
      }
      slashes = 0;
      if (!wbuf_push(b, L'"')) return 0;
    } else {
      for (size_t i = 0; i < slashes; i++) {
        if (!wbuf_push(b, L'\\')) return 0;
      }
      slashes = 0;
      if (!wbuf_push(b, *p)) return 0;
    }
  }
  for (size_t i = 0; i < slashes * 2; i++) {
    if (!wbuf_push(b, L'\\')) return 0;
  }
  return wbuf_push(b, L'"');
}
#endif

/// Replaces the current process on Unix via execv(program, argv), preserving PID, PGID, signal mask,
/// and inherited file descriptors (such as launcher fds 3, 4, 5). On Windows, spawns `program` via
/// CreateProcessW with handle inheritance enabled (without CREATE_NO_WINDOW) inside a Job Object
/// configured with KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK so direct Node child exits if the shim
/// is force-killed while detached grandchildren (stillfail-runner / background jobs) survive.
int32_t sfh_exec_replace(moonbit_bytes_t program, moonbit_bytes_t argv_nul) {
  const char *prog = (const char *)program;
  const char *raw = (const char *)argv_nul;
  size_t total = (size_t)Moonbit_array_length(argv_nul);
  size_t argc = 0;
  for (size_t i = 0; i < total; i++) {
    if (raw[i] == '\0') argc++;
  }
  char **argv = (char **)malloc((argc + 1) * sizeof(char *));
  if (argv == NULL) {
    fprintf(stderr, "stillfail-reader: out of memory preparing exec\n");
    return 127;
  }
  size_t idx = 0;
  size_t pos = 0;
  while (pos < total && idx < argc) {
    argv[idx++] = (char *)(raw + pos);
    pos += strlen(raw + pos) + 1;
  }
  argv[idx] = NULL;

#ifdef _WIN32
  wchar_t *wprog = utf8_to_wide(prog);
  if (wprog == NULL) {
    free(argv);
    fprintf(stderr, "stillfail-reader: invalid UTF-8 program path\n");
    return 127;
  }
  wbuf_t cmd = { NULL, 0, 0 };
  for (size_t i = 0; i < idx; i++) {
    if (i > 0 && !wbuf_push(&cmd, L' ')) {
      free(cmd.data);
      free(wprog);
      free(argv);
      fprintf(stderr, "stillfail-reader: out of memory building command line\n");
      return 127;
    }
    wchar_t *warg = utf8_to_wide(argv[i]);
    int ok = warg != NULL && wbuf_append_arg(&cmd, warg);
    free(warg);
    if (!ok) {
      free(cmd.data);
      free(wprog);
      free(argv);
      fprintf(stderr, "stillfail-reader: failed formatting Windows arguments\n");
      return 127;
    }
  }
  free(argv);

  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (job == NULL) {
    fprintf(stderr, "stillfail-reader: CreateJobObjectW failed (error %lu)\n", (unsigned long)GetLastError());
    free(cmd.data);
    free(wprog);
    return 127;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli;
  ZeroMemory(&jeli, sizeof(jeli));
  jeli.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) {
    fprintf(stderr, "stillfail-reader: SetInformationJobObject failed (error %lu)\n", (unsigned long)GetLastError());
    CloseHandle(job);
    free(cmd.data);
    free(wprog);
    return 127;
  }

  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  if (attr_size == 0) {
    fprintf(stderr, "stillfail-reader: InitializeProcThreadAttributeList sizing failed (error %lu)\n", (unsigned long)GetLastError());
    CloseHandle(job);
    free(cmd.data);
    free(wprog);
    return 127;
  }
  LPPROC_THREAD_ATTRIBUTE_LIST attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
  if (attr_list == NULL || !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size)) {
    fprintf(stderr, "stillfail-reader: InitializeProcThreadAttributeList failed (error %lu)\n", (unsigned long)GetLastError());
    free(attr_list);
    CloseHandle(job);
    free(cmd.data);
    free(wprog);
    return 127;
  }
  if (!UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(HANDLE), NULL, NULL)) {
    fprintf(stderr, "stillfail-reader: UpdateProcThreadAttribute(JOB_LIST) failed (error %lu)\n", (unsigned long)GetLastError());
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
    fprintf(stderr, "stillfail-reader: CreateProcessW(%s) failed (error %lu)\n", prog, (unsigned long)create_err);
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
  execv(prog, argv);
  int err = errno;
  fprintf(stderr, "stillfail-reader: execv(%s) failed: %s\n", prog, strerror(err));
  free(argv);
  return 127;
#endif
}
