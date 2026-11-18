// mbc's few needs from the system: files read and written whole as bytes (paths as UTF-8 bytes), a directory's
// names, a file removed or renamed, an environment variable, and the process ended with a status.
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // (memmem)
#endif
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#if defined(_WIN32)
#include <direct.h>
#include <io.h>
#include <windows.h>
#else
#include <dirent.h>
#include <unistd.h>
#include <time.h>
#endif
#include "moonbit.h"

// Bound the cache publication wait without consuming a compiler core.
void mbc_wait_short(void) {
#if defined(_WIN32)
  Sleep(100);
#else
  struct timespec delay = {0, 100000000};
  nanosleep(&delay, NULL);
#endif
}

// a path given as bytes (UTF-8), NUL-terminated; the caller frees it
static char *cpath(moonbit_bytes_t p) {
  int32_t n = Moonbit_array_length(p);
  char *s = malloc((size_t)n + 1);
  memcpy(s, p, (size_t)n);
  s[n] = 0;
  return s;
}

static moonbit_bytes_t bytes_of(const char *s, size_t n) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, s, n);
  return out;
}

// the file's bytes; its length -1 (an empty Bytes, `ok` 0) when it cannot be read
int32_t mbc_file_ok;

moonbit_bytes_t mbc_read_file(moonbit_bytes_t path) {
  char *p = cpath(path);
  FILE *f = fopen(p, "rb");
  free(p);
  mbc_file_ok = 0;
  if (!f) return moonbit_make_bytes(0, 0);
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  size_t got = fread(out, 1, (size_t)n, f);
  fclose(f);
  if ((long)got != n) return moonbit_make_bytes(0, 0);
  mbc_file_ok = 1;
  return out;
}

int32_t mbc_read_ok(void) { return mbc_file_ok; }

// why the last write or rename that failed did (errno, taken before free() or fclose() can change it): what
// `cannot write` says, so a disk full (ENOSPC) or a directory taken away is told by the failure itself
static int mbc_errno;

int32_t mbc_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  char *p = cpath(path);
  FILE *f = fopen(p, "wb");
  int e = errno;
  free(p);
  if (!f) {
    mbc_errno = e;
    return 0;
  }
  int32_t n = Moonbit_array_length(data);
  size_t put = fwrite(data, 1, (size_t)n, f);
  e = (int32_t)put == n ? 0 : errno;
  if (fclose(f) != 0 && e == 0) e = errno;
  if ((int32_t)put != n || e != 0) {
    mbc_errno = e != 0 ? e : EIO;
    return 0;
  }
  return 1;
}

// the reason the last failed write or rename gave, as the system words it
moonbit_bytes_t mbc_last_error(void) {
  const char *s = mbc_errno != 0 ? strerror(mbc_errno) : "unknown error";
  return bytes_of(s, strlen(s));
}

int32_t mbc_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  char *a = cpath(from), *b = cpath(to);
#if defined(_WIN32)
  int r = MoveFileExA(a, b, MOVEFILE_REPLACE_EXISTING) ? 0 : -1;
#else
  int r = rename(a, b);
#endif
  int e = errno;
  free(a);
  free(b);
  if (r != 0) mbc_errno = e;
  return r == 0;
}

int32_t mbc_remove(moonbit_bytes_t path) {
  char *p = cpath(path);
  int r = remove(p);
  free(p);
  return r == 0;
}

int32_t mbc_mkdir(moonbit_bytes_t path) {
  // (and the directories it is in, as os.makedirs)
  char *p = cpath(path);
  for (char *q = p + 1; *q; q++) {
    if (*q == '/' || *q == '\\') {
      char c = *q;
      *q = 0;
#if defined(_WIN32)
      _mkdir(p);
#else
      mkdir(p, 0777);
#endif
      *q = c;
    }
  }
#if defined(_WIN32)
  int r = _mkdir(p);
#else
  int r = mkdir(p, 0777);
#endif
  free(p);
  return r == 0;
}

// the names in a directory (not . and ..), each ended by a NUL, in one Bytes
moonbit_bytes_t mbc_list_dir(moonbit_bytes_t path) {
  char *p = cpath(path);
  size_t cap = 4096, len = 0;
  char *buf = malloc(cap);
#if defined(_WIN32)
  char *pat = malloc(strlen(p) + 3);
  sprintf(pat, "%s\\*", p);
  WIN32_FIND_DATAA fd;
  HANDLE h = FindFirstFileA(pat, &fd);
  free(pat);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      const char *n = fd.cFileName;
#else
  DIR *d = opendir(p);
  struct dirent *e;
  if (d) {
    while ((e = readdir(d))) {
      const char *n = e->d_name;
#endif
      if (strcmp(n, ".") == 0 || strcmp(n, "..") == 0) continue;
      size_t k = strlen(n) + 1;
      while (len + k > cap) buf = realloc(buf, cap *= 2);
      memcpy(buf + len, n, k);
      len += k;
#if defined(_WIN32)
    } while (FindNextFileA(h, &fd));
    FindClose(h);
  }
#else
    }
    closedir(d);
  }
#endif
  free(p);
  moonbit_bytes_t out = bytes_of(buf, len);
  free(buf);
  return out;
}

// an environment variable's value; `set` says whether it was
int32_t mbc_env_set;

moonbit_bytes_t mbc_getenv(moonbit_bytes_t name) {
  char *n = cpath(name);
  const char *v = getenv(n);
  free(n);
  mbc_env_set = v != NULL;
  return v ? bytes_of(v, strlen(v)) : moonbit_make_bytes(0, 0);
}

int32_t mbc_env_was_set(void) { return mbc_env_set; }

int32_t mbc_cpu_count(void) {
#if defined(_WIN32)
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return (int32_t)si.dwNumberOfProcessors;
#else
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int32_t)n : 1;
#endif
}

void mbc_write_err(moonbit_bytes_t s) {
  fwrite(s, 1, (size_t)Moonbit_array_length(s), stderr);
  fflush(stderr);
}

void mbc_exit(int32_t code) { exit(code); }

#if !defined(_WIN32)
#include <sys/wait.h>
#endif

int32_t mbc_fork(void) {
#if defined(_WIN32)
  return -1;
#else
  fflush(stdout);
  fflush(stderr);
  return (int32_t)fork();
#endif
}

int32_t mbc_wait_all(void) {
#if defined(_WIN32)
  return 0;
#else
  int st, bad = 0;
  while (wait(&st) > 0) {
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) bad = 1;
  }
  return bad;
#endif
}

void mbc_child_exit(int32_t code) {
#if defined(_WIN32)
  exit(code);
#else
  _exit(code);
#endif
}

// ---------------------------------------------------------------- mbc's: processes, files' metadata, locks

#if defined(_WIN32)
#include <sys/utime.h>
#else
#include <fcntl.h>
#include <spawn.h>
#include <sys/file.h>
#include <utime.h>
#include <limits.h>
extern char **environ;
#endif

int32_t mbc_is_windows(void) {
#if defined(_WIN32)
  return 1;
#else
  return 0;
#endif
}

int32_t mbc_is_linux(void) {
#if defined(__linux__)
  return 1;
#else
  return 0;
#endif
}

void mbc_write_out(moonbit_bytes_t s) {
  fwrite(s, 1, (size_t)Moonbit_array_length(s), stdout);
  fflush(stdout);
}

int32_t mbc_setenv(moonbit_bytes_t name, moonbit_bytes_t value) {
  char *n = cpath(name), *v = cpath(value);
#if defined(_WIN32)
  int r = _putenv_s(n, v);
#else
  int r = setenv(n, v, 1);
#endif
  free(n);
  free(v);
  return r == 0;
}

// a file's kind (0 none, 1 file, 2 directory, 3 other), size and mtime in ns, by mbc_stat
static int64_t st_size, st_mtime_ns;

int32_t mbc_stat(moonbit_bytes_t path) {
  char *p = cpath(path);
#if defined(_WIN32)
  struct _stat64 st;
  int r = _stat64(p, &st);
#else
  struct stat st;
  int r = stat(p, &st);
#endif
  free(p);
  if (r != 0) return 0;
  st_size = (int64_t)st.st_size;
#if defined(__APPLE__)
  st_mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#elif defined(_WIN32)
  st_mtime_ns = (int64_t)st.st_mtime * 1000000000;
#else
  st_mtime_ns = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
  if ((st.st_mode & S_IFMT) == S_IFREG) return 1;
  if ((st.st_mode & S_IFMT) == S_IFDIR) return 2;
  return 3;
}

int64_t mbc_stat_size(void) { return st_size; }
int64_t mbc_stat_mtime(void) { return st_mtime_ns; }

// (a file's or a directory's: Windows' _utime opens what it touches as a file, and a directory then is not touched,
// so MBC_STORE's units taken from it were pruned as unused)
int32_t mbc_touch(moonbit_bytes_t path) {
  char *p = cpath(path);
#if defined(_WIN32)
  int r = -1;
  HANDLE h = CreateFileA(p, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (h != INVALID_HANDLE_VALUE) {
    FILETIME t;
    GetSystemTimeAsFileTime(&t);
    if (SetFileTime(h, NULL, &t, &t)) r = 0;
    CloseHandle(h);
  }
#else
  int r = utime(p, NULL);
#endif
  free(p);
  return r == 0;
}

int32_t mbc_rmdir(moonbit_bytes_t path) {
  char *p = cpath(path);
#if defined(_WIN32)
  int r = _rmdir(p);
#else
  int r = rmdir(p);
#endif
  free(p);
  return r == 0;
}

int32_t mbc_symlink(moonbit_bytes_t target, moonbit_bytes_t link) {
#if defined(_WIN32)
  return 0;
#else
  char *t = cpath(target), *l = cpath(link);
  int r = symlink(t, l);
  free(t);
  free(l);
  return r == 0;
#endif
}

int32_t mbc_chmod(moonbit_bytes_t path, int32_t mode) {
#if defined(_WIN32)
  return 1;
#else
  char *p = cpath(path);
  int r = chmod(p, (mode_t)mode);
  free(p);
  return r == 0;
#endif
}

int32_t mbc_executable(moonbit_bytes_t path) {
#if defined(_WIN32)
  return 1;
#else
  char *p = cpath(path);
  int r = access(p, X_OK);
  free(p);
  return r == 0;
#endif
}

moonbit_bytes_t mbc_getcwd(void) {
  char buf[4096];
#if defined(_WIN32)
  if (!_getcwd(buf, sizeof buf)) buf[0] = 0;
#else
  if (!getcwd(buf, sizeof buf)) buf[0] = 0;
#endif
  return bytes_of(buf, strlen(buf));
}

moonbit_bytes_t mbc_realpath(moonbit_bytes_t path) {
  char *p = cpath(path);
#if defined(_WIN32)
  char *r = _fullpath(NULL, p, 0);
#else
  char *r = realpath(p, NULL);
#endif
  free(p);
  if (!r) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = bytes_of(r, strlen(r));
  free(r);
  return out;
}

int32_t mbc_getpid(void) {
#if defined(_WIN32)
  return (int32_t)GetCurrentProcessId();
#else
  return (int32_t)getpid();
#endif
}

// an exclusive lock on a file (made if it is not there), the system's to let go when its holder ends however it
// ends (flock): its handle, -1 when another holds it (wait 0) or it cannot be had; Windows: no lock, 0
int32_t mbc_lock(moonbit_bytes_t path, int32_t wait) {
#if defined(_WIN32)
  return 0;
#else
  char *p = cpath(path);
  int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0666);
  free(p);
  if (fd < 0) return -1;
  if (flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
#endif
}

void mbc_unlock(int32_t fd) {
#if !defined(_WIN32)
  if (fd > 0) {
    flock(fd, LOCK_UN);
    close(fd);
  }
#endif
}

// processes: started with mbc_spawn (argv as NUL-ended words; on Windows the command line), their output into a
// file (or this one's when out is empty); mbc_wait_any answers the slot of one that ended, mbc_status its exit code.
// A slot is free again only when mbc_release says its end was taken: one that ended while another was waited for is
// not given to the next process (its end was a job's still)
#define MBC_SLOTS 256
#if defined(_WIN32)
static HANDLE slots[MBC_SLOTS];
#else
static pid_t slots[MBC_SLOTS];
#endif
static int32_t slot_used[MBC_SLOTS]; // 0 free, 1 running, 2 ended (its end not yet taken)
static int32_t last_status;

int32_t mbc_spawn(moonbit_bytes_t words, moonbit_bytes_t cmdline, moonbit_bytes_t out) {
  int32_t s = -1;
  for (int32_t i = 0; i < MBC_SLOTS; i++)
    if (!slot_used[i]) {
      s = i;
      break;
    }
  if (s < 0) return -1;
#if defined(_WIN32)
  (void)words;
  char *cl = cpath(cmdline);
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  HANDLE f = INVALID_HANDLE_VALUE;
  if (Moonbit_array_length(out) > 0) {
    char *o = cpath(out);
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    f = CreateFileA(o, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(o);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = f;
    si.hStdError = f;
  }
  BOOL ok = CreateProcessA(NULL, cl, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
  DWORD error = ok ? 0 : GetLastError();
  free(cl);
  if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
  if (!ok) {
    fprintf(stderr, "mbc: CreateProcess failed (%lu), command length %d\n", (unsigned long)error,
            (int)Moonbit_array_length(cmdline));
    return -1;
  }
  CloseHandle(pi.hThread);
  slots[s] = pi.hProcess;
#else
  (void)cmdline;
  int32_t n = Moonbit_array_length(words);
  int argc = 0;
  for (int32_t i = 0; i < n; i++)
    if (words[i] == 0) argc++;
  char **argv = calloc((size_t)argc + 1, sizeof(char *));
  char *buf = malloc((size_t)n + 1);
  memcpy(buf, words, (size_t)n);
  buf[n] = 0;
  int k = 0;
  for (int32_t i = 0; i < n; i++) {
    if (i == 0 || words[i - 1] == 0) argv[k++] = buf + i;
  }
  argv[argc] = NULL;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  char *o = NULL;
  if (Moonbit_array_length(out) > 0) {
    o = cpath(out);
    posix_spawn_file_actions_addopen(&fa, 1, o, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
  }
  pid_t pid;
  int r = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  free(o);
  free(argv);
  free(buf);
  if (r != 0) return -1;
  slots[s] = pid;
#endif
  slot_used[s] = 1;
  return s;
}

int32_t mbc_wait_any(void) {
#if defined(_WIN32)
  HANDLE hs[MAXIMUM_WAIT_OBJECTS];
  int32_t ids[MAXIMUM_WAIT_OBJECTS];
  int n = 0;
  for (int32_t i = 0; i < MBC_SLOTS && n < MAXIMUM_WAIT_OBJECTS; i++)
    if (slot_used[i] == 1) {
      hs[n] = slots[i];
      ids[n++] = i;
    }
  if (n == 0) return -1;
  DWORD w = WaitForMultipleObjects((DWORD)n, hs, FALSE, INFINITE);
  if (w >= WAIT_OBJECT_0 + (DWORD)n) return -1;
  int32_t s = ids[w - WAIT_OBJECT_0];
  DWORD code = 1;
  GetExitCodeProcess(slots[s], &code);
  CloseHandle(slots[s]);
  last_status = (int32_t)code;
  slot_used[s] = 2;
  return s;
#else
  for (;;) {
    int st;
    pid_t p = wait(&st);
    if (p < 0) return -1;
    for (int32_t i = 0; i < MBC_SLOTS; i++)
      if (slot_used[i] == 1 && slots[i] == p) {
        slot_used[i] = 2;
        last_status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
        return i;
      }
  }
#endif
}

int32_t mbc_status(void) { return last_status; }

void mbc_release(int32_t s) {
  if (s >= 0 && s < MBC_SLOTS) slot_used[s] = 0;
}

int32_t mbc_append(moonbit_bytes_t path, moonbit_bytes_t data) {
  char *p = cpath(path);
  FILE *f = fopen(p, "ab");
  free(p);
  if (!f) return 0;
  size_t n = (size_t)Moonbit_array_length(data);
  int ok = fwrite(data, 1, n, f) == n;
  return fclose(f) == 0 && ok;
}

int32_t mbc_chdir(moonbit_bytes_t path) {
  char *p = cpath(path);
#if defined(_WIN32)
  int r = _chdir(p);
#else
  int r = chdir(p);
#endif
  free(p);
  return r == 0;
}
// Bytes searched as libc searches them (find and find_byte in util.mbt: a C text of half a gigabyte, searched many
// times over)
int32_t mbc_find_byte(moonbit_bytes_t t, int32_t from, int32_t end, int32_t c) {
  if (from >= end) return -1;
  const uint8_t *p = memchr(t + from, c, (size_t)(end - from));
  return p == NULL ? -1 : (int32_t)(p - t);
}

int32_t mbc_find(moonbit_bytes_t t, int32_t from, int32_t end, moonbit_bytes_t s) {
  size_t m = (size_t)Moonbit_array_length(s);
  if (m == 0) return from <= end ? from : -1;
  if (from < 0 || end - from < (int32_t)m) return -1;
#if defined(__GLIBC__) || defined(__APPLE__) || defined(__FreeBSD__) || defined(__ANDROID__)
  const uint8_t *p = memmem(t + from, (size_t)(end - from), s, m);
  return p == NULL ? -1 : (int32_t)(p - t);
#else
  const uint8_t *q = t + from, *last = t + end - m;
  while (q <= last) {
    q = memchr(q, s[0], (size_t)(last - q) + 1);
    if (q == NULL) return -1;
    if (memcmp(q, s, m) == 0) return (int32_t)(q - t);
    q++;
  }
  return -1;
#endif
}

// What csplit's scans do to every byte of the C (scan.mbt says what each is; these do it as they do): a byte at a
// time in MoonBit, its view's bounds checked at each, was most of their time.

// FNV-1a of t[s:e] as util.mbt's hash_range has it (Int's wrapping multiply, an arithmetic shift)
int32_t mbc_hash(moonbit_bytes_t t, int32_t s, int32_t e) {
  uint32_t u = 0x811c9dc5u;
  for (int32_t i = s; i < e; i++) u = (u ^ t[i]) * 0x01000193u;
  int32_t h = (int32_t)u;
  return h ^ (h >> 15);
}

static uint8_t ident_tab[256];

static void ident_tab_init(void) {
  if (ident_tab['_']) return;
  for (int c = 'a'; c <= 'z'; c++) ident_tab[c] = 1;
  for (int c = 'A'; c <= 'Z'; c++) ident_tab[c] = 1;
  for (int c = '0'; c <= '9'; c++) ident_tab[c] = 1;
  ident_tab['$'] = 1;
  ident_tab['_'] = 1;
}

// the end of the run of identifier characters ([A-Za-z0-9_$]) in t[i:end]
int32_t mbc_ident_end(moonbit_bytes_t t, int32_t i, int32_t end) {
  ident_tab_init();
  while (i < end && ident_tab[t[i]]) i++;
  return i;
}

// k[ks:ks + n] is t[s:s + n]
int32_t mbc_same(uint8_t *k, int32_t ks, moonbit_bytes_t t, int32_t s, int32_t n) {
  if (n <= 0) return 1;
  return memcmp(k + ks, t + s, (size_t)n) == 0;
}

// len() of the text Python decoded t[s:e] to (util.mbt's clen: the bytes that do not continue a character)
int32_t mbc_clen(moonbit_bytes_t t, int32_t s, int32_t e) {
  int32_t n = 0;
  for (int32_t i = s; i < e; i++) n += (t[i] & 0xC0) != 0x80;
  return n;
}

// scan.mbt's line_starts of t, into `all` (empty: only counted): where each line starts (str.splitlines(keepends=True)'s
// line breaks), and the text's end last; how many
int32_t mbc_line_starts(moonbit_bytes_t t, int32_t *all) {
  int32_t *out = Moonbit_array_length(all) > 0 ? all : NULL;
  int32_t n = Moonbit_array_length(t), k = 0, last = 0;
  if (out) out[k] = 0;
  k++;
  int32_t i = 0;
  while (i < n) {
    uint8_t c = t[i];
    int32_t e = -1;
    if (c > 0x1e && c != 0xc2 && c != 0xe2) {
      i++;
      continue;
    }
    if (c == '\n' || c == 0x0b || c == 0x0c || c == 0x1c || c == 0x1d || c == 0x1e) e = i + 1;
    else if (c == '\r') e = i + 1 < n && t[i + 1] == '\n' ? i + 2 : i + 1;
    else if (c == 0xc2 && i + 1 < n && t[i + 1] == 0x85) e = i + 2;
    else if (c == 0xe2 && i + 2 < n && t[i + 1] == 0x80 && (t[i + 2] == 0xa8 || t[i + 2] == 0xa9)) e = i + 3;
    if (e >= 0) {
      if (out) out[k] = e;
      k++;
      last = e;
      i = e;
    } else {
      i++;
    }
  }
  if (last != n) {
    if (out) out[k] = n;
    k++;
  }
  return k;
}

// scan.mbt's lit_end and blank_end on t[0:n]
static int32_t lit_end(const uint8_t *t, int32_t p, int32_t n) {
  uint8_t q = t[p];
  int32_t k = p + 1;
  while (k < n) {
    uint8_t c = t[k];
    if (c == '\\') {
      if (k + 1 < n) {
        k += 2;
        continue;
      }
      return -1;
    }
    if (c == q) return k + 1;
    if (c == '\n') return -1;
    k++;
  }
  return -1;
}

static int32_t eol_of(const uint8_t *t, int32_t p, int32_t n) {
  const uint8_t *e = p < n ? memchr(t + p, '\n', (size_t)(n - p)) : NULL;
  return e == NULL ? n : (int32_t)(e - t);
}

static int32_t blank_end(const uint8_t *t, int32_t p, int32_t n) {
  uint8_t c = t[p];
  if (c == '/' && p + 1 < n && t[p + 1] == '*') {
    int32_t from = p + 2;
    const uint8_t *e = NULL;
    for (const uint8_t *q = t + from; n - (q - t) >= 2;) {
      q = memchr(q, '*', (size_t)(n - (q - t)) - 1);
      if (q == NULL) break;
      if (q[1] == '/') {
        e = q;
        break;
      }
      q++;
    }
    if (e != NULL) return (int32_t)(e - t) + 2;
  }
  if (c == '/' && p + 1 < n && t[p + 1] == '/') return eol_of(t, p, n);
  if (c == '"' || c == '\'') {
    int32_t q = lit_end(t, p, n);
    if (q >= 0) return q;
  }
  if (p == 0 || t[p - 1] == '\n') {
    int32_t q = p;
    while (q < n && (t[q] == ' ' || t[q] == '\t')) q++;
    if (q < n && t[q] == '#') return eol_of(t, q, n);
  }
  return -1;
}

// scan.mbt's blank of tv[start:start + n] into out (n bytes)
void mbc_blank(moonbit_bytes_t tv, int32_t start, int32_t n, uint8_t *out) {
  if (n <= 0) return;
  const uint8_t *t = tv + start;
  int32_t last = 0, p = 0;
  while (p < n) {
    uint8_t c = t[p];
    if (!(c == '/' || c == '"' || c == '\'' || p == 0 || t[p - 1] == '\n')) {
      p++;
      continue;
    }
    int32_t me = blank_end(t, p, n);
    if (me < 0) {
      p++;
      continue;
    }
    memcpy(out + last, t + last, (size_t)(p - last));
    int32_t a = p, z = me;
    if (c == '"' || c == '\'') {
      // (a literal: its quotes kept)
      out[p] = c;
      out[me - 1] = t[me - 1];
      a = p + 1;
      z = me - 1;
    }
    for (int32_t k = a; k < z; k++) out[k] = t[k] == '\n' ? '\n' : ' ';
    last = me;
    p = me;
  }
  memcpy(out + last, t + last, (size_t)(n - last));
}
