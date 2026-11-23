// Cross-platform process replacement (execv on Unix, CreateProcessW on Windows) and tiny OS lookups
// used by the reader's station_shim and reader_harness's reader fallback.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif

static moonbit_bytes_t bytes_from_cstr(const char *s) {
  if (s == NULL || s[0] == '\0') return moonbit_make_bytes(0, 0);
  size_t n = strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, s, n);
  return out;
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
  int need = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (need <= 1) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(need - 1), 0);
  WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)out, need - 1, NULL, NULL);
  return out;
}

static int win_is_file_w(const wchar_t *w) {
  DWORD attr = GetFileAttributesW(w);
  return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
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
  moonbit_bytes_t out = got > 0 ? wide_to_bytes(wval) : moonbit_make_bytes(0, 0);
  free(wval);
  return out;
#else
  return bytes_from_cstr(getenv(key));
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

/// Searches PATH for an executable named `name` (NUL-terminated UTF-8). Returns full path or empty bytes.
moonbit_bytes_t sfh_find_in_path(moonbit_bytes_t name) {
  const char *cmd = (const char *)name;
  if (cmd[0] == '\0') return moonbit_make_bytes(0, 0);
#ifdef _WIN32
  wchar_t *wcmd = utf8_to_wide(cmd);
  if (wcmd == NULL) return moonbit_make_bytes(0, 0);
  wchar_t buf[32768];
  DWORD n = SearchPathW(NULL, wcmd, L".exe", (DWORD)(sizeof(buf) / sizeof(buf[0])), buf, NULL);
  free(wcmd);
  if (n == 0 || n >= (DWORD)(sizeof(buf) / sizeof(buf[0]))) return moonbit_make_bytes(0, 0);
  return win_is_file_w(buf) ? wide_to_bytes(buf) : moonbit_make_bytes(0, 0);
#else
  const char *path_env = getenv("PATH");
  if (path_env == NULL || path_env[0] == '\0') return moonbit_make_bytes(0, 0);
  size_t cmd_len = strlen(cmd);
  const char *cur = path_env;
  for (;;) {
    const char *sep = strchr(cur, ':');
    size_t dir_len = sep != NULL ? (size_t)(sep - cur) : strlen(cur);
    size_t need = (dir_len == 0 ? 1 : dir_len) + 1 + cmd_len + 1;
    char *cand = (char *)malloc(need);
    if (cand == NULL) return moonbit_make_bytes(0, 0);
    if (dir_len == 0) {
      cand[0] = '.';
      cand[1] = '/';
      memcpy(cand + 2, cmd, cmd_len + 1);
    } else {
      memcpy(cand, cur, dir_len);
      if (cand[dir_len - 1] == '/') {
        memcpy(cand + dir_len, cmd, cmd_len + 1);
      } else {
        cand[dir_len] = '/';
        memcpy(cand + dir_len + 1, cmd, cmd_len + 1);
      }
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
/// CreateProcessW with handle inheritance enabled (and without CREATE_NO_WINDOW), waits for exit, and
/// returns its exit code. `argv_nul` contains NUL-terminated UTF-8 arguments back to back.
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
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));
  if (!CreateProcessW(wprog, cmd.data, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
    DWORD err = GetLastError();
    fprintf(stderr, "stillfail-reader: CreateProcessW(%s) failed (error %lu)\n", prog, (unsigned long)err);
    free(cmd.data);
    free(wprog);
    return 127;
  }
  free(cmd.data);
  free(wprog);
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
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
