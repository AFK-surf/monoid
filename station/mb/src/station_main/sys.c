// What the station in MoonBit asks of the system that the shell (client/shell) does not do: stderr and a descriptor's
// writes, the environment, the machine (its CPUs, memory, load, disks, addresses), the three calls the
// mesh addon made for Node (native/mesh: `file_lock`, `peer_process`, `process_usage`), child processes followed to
// their end, signals, and the launcher's control lines. Each path and string is UTF-8, ended by a NUL. What comes later
// (a child's output and end, a lock taken, a control line, a signal) is told on the program's queue as an event of its
// own (host.c `sfh_push_sys`), from a thread here: nothing here calls into MoonBit, and the program's thread never waits
// on any of it. On Windows the same through Win32's wide calls.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include "moonbit.h"

void sfh_push_sys(uint64_t id, const uint8_t *a, size_t al);
void sfh_push_sys_bounded(uint64_t id, const uint8_t *a, size_t al);

typedef struct {
  char *data;
  size_t len, cap;
} sbuf_t;

static void sb_add(sbuf_t *b, const char *s, size_t len) {
  if (b->len + len + 1 > b->cap) {
    size_t cap = b->cap == 0 ? 1024 : b->cap;
    while (b->len + len + 1 > cap) cap *= 2;
    char *grown = realloc(b->data, cap);
    if (grown == NULL) return;
    b->data = grown;
    b->cap = cap;
  }
  if (len) memcpy(b->data + b->len, s, len);
  b->len += len;
  b->data[b->len] = 0;
}

static void sb_str(sbuf_t *b, const char *s) { sb_add(b, s, strlen(s)); }

static void sb_fmt(sbuf_t *b, const char *fmt, double v) {
  char tmp[64];
  int n = snprintf(tmp, sizeof tmp, fmt, v);
  if (n > 0) sb_add(b, tmp, (size_t)n);
}

/// `s` as a JSON string, quoted.
static void sb_json(sbuf_t *b, const char *s) {
  sb_add(b, "\"", 1);
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    char esc[8];
    if (*p == '"' || *p == '\\') {
      esc[0] = '\\';
      esc[1] = (char)*p;
      sb_add(b, esc, 2);
    } else if (*p < 0x20) {
      snprintf(esc, sizeof esc, "\\u%04x", *p);
      sb_add(b, esc, 6);
    } else {
      sb_add(b, (const char *)p, 1);
    }
  }
  sb_add(b, "\"", 1);
}

static moonbit_bytes_t bytes_of(const char *s, size_t len) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len) memcpy(out, s, len);
  return out;
}

static moonbit_bytes_t sb_bytes(sbuf_t *b) {
  moonbit_bytes_t out = bytes_of(b->data ? b->data : "", b->len);
  free(b->data);
  b->data = NULL;
  b->len = b->cap = 0;
  return out;
}

static void sys_told(int64_t id, char tag, const void *data, size_t len) {
  uint8_t *msg = malloc(len + 1);
  if (msg == NULL) return;
  msg[0] = (uint8_t)tag;
  if (len) memcpy(msg + 1, data, len);
  sfh_push_sys((uint64_t)id, msg, len + 1);
  free(msg);
}

static void sys_told_text(int64_t id, char tag, const char *text) { sys_told(id, tag, text, strlen(text)); }

#define STDIN_DEFAULT_MOST (64u * 1024u * 1024u)
#define STDIN_MIN_MOST (64u * 1024u)
#define STDIN_BUCKETS 256

typedef struct stdin_chunk {
  struct stdin_chunk *next;
  size_t len;
  uint8_t data[];
} stdin_chunk_t;

static void stdin_free_chunks(stdin_chunk_t *head) {
  while (head != NULL) {
    stdin_chunk_t *next = head->next;
    free(head);
    head = next;
  }
}

static size_t stdin_parse_limit(const char *s) {
  if (s == NULL || *s == '\0' || *s == '-' || *s == '+') return STDIN_DEFAULT_MOST;
  errno = 0;
  char *end = NULL;
  unsigned long long v = strtoull(s, &end, 10);
  if (errno != 0 || end == s || *end != '\0' || v == 0) return STDIN_DEFAULT_MOST;
  if (v < (unsigned long long)STDIN_MIN_MOST) return STDIN_MIN_MOST;
  if (v > (unsigned long long)SIZE_MAX) return SIZE_MAX;
  return (size_t)v;
}

/// The system this was built for: 0 macOS, 1 Linux, 2 Windows, 3 another.
int32_t sfs_os(void) {
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

/// Its processor: 0 arm64, 1 x64, 2 another.
int32_t sfs_arch(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
  return 0;
#elif defined(__x86_64__) || defined(_M_X64)
  return 1;
#else
  return 2;
#endif
}

#ifdef _WIN32
// ───────────────────────────────────────────── Windows ─────────────────────────────────────────────
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <io.h>

static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t *w = malloc(sizeof(wchar_t) * (size_t)n);
  if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static char *narrow(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 0) return NULL;
  char *s = malloc((size_t)n);
  if (s) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
  return s;
}

static const char *win_error(DWORD code, char *buf, size_t size) {
  wchar_t wbuf[512];
  DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, wbuf, 512, NULL);
  while (n > 0 && (wbuf[n - 1] == L'\r' || wbuf[n - 1] == L'\n' || wbuf[n - 1] == L' ')) wbuf[--n] = 0;
  if (n == 0) {
    snprintf(buf, size, "error %lu", (unsigned long)code);
  } else {
    char *s = narrow(wbuf);
    snprintf(buf, size, "%s", s ? s : "error");
    free(s);
  }
  return buf;
}

typedef DWORD(WINAPI *thread_fn)(LPVOID);
static int start_thread(thread_fn f, void *arg) {
  HANDLE t = CreateThread(NULL, 0, f, arg, 0, NULL);
  if (!t) return 0;
  CloseHandle(t);
  return 1;
}

int32_t sfs_err(moonbit_bytes_t b) {
  size_t len = (size_t)Moonbit_array_length(b), done = 0;
  HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
  while (done < len) {
    DWORD n;
    if (!WriteFile(h, b + done, (DWORD)(len - done), &n, NULL) || n == 0) return 0;
    done += n;
  }
  return 1;
}

int32_t sfs_fd_write(int32_t fd, moonbit_bytes_t b) {
  size_t len = (size_t)Moonbit_array_length(b), done = 0;
  while (done < len) {
    int n = _write(fd, b + done, (unsigned)(len - done));
    if (n <= 0) return 0;
    done += (size_t)n;
  }
  return 1;
}

int32_t sfs_fd_close(int32_t fd) { return _close(fd) == 0; }

moonbit_bytes_t sfs_env_all(void) {
  wchar_t *block = GetEnvironmentStringsW();
  sbuf_t b = {0};
  for (wchar_t *p = block; p && *p; p += wcslen(p) + 1) {
    if (*p == L'=') continue; // (a drive's working directory, =C:=C:\…, as Node leaves out)
    char *s = narrow(p);
    if (s) {
      sb_add(&b, s, strlen(s) + 1);
      free(s);
    }
  }
  if (block) FreeEnvironmentStringsW(block);
  return sb_bytes(&b);
}

int32_t sfs_env_set(moonbit_bytes_t name, moonbit_bytes_t value) {
  wchar_t *n = wide((const char *)name), *v = wide((const char *)value);
  int ok = n && v && SetEnvironmentVariableW(n, v) && _wputenv_s(n, v) == 0;
  free(n);
  free(v);
  return ok;
}

int32_t sfs_env_unset(moonbit_bytes_t name) {
  wchar_t *n = wide((const char *)name);
  int ok = n && SetEnvironmentVariableW(n, NULL) && _wputenv_s(n, L"") == 0;
  free(n);
  return ok;
}

moonbit_bytes_t sfs_hostname(void) {
  wchar_t w[256];
  DWORD n = 256;
  if (!GetComputerNameExW(ComputerNameDnsHostname, w, &n)) return bytes_of("", 0);
  char *s = narrow(w);
  moonbit_bytes_t out = bytes_of(s ? s : "", s ? strlen(s) : 0);
  free(s);
  return out;
}

static moonbit_bytes_t env_or(const wchar_t *name, const char *fallback) {
  wchar_t w[32768];
  DWORD n = GetEnvironmentVariableW(name, w, 32768);
  if (n == 0 || n >= 32768) return bytes_of(fallback, strlen(fallback));
  char *s = narrow(w);
  moonbit_bytes_t out = bytes_of(s ? s : fallback, strlen(s ? s : fallback));
  free(s);
  return out;
}

moonbit_bytes_t sfs_homedir(void) { return env_or(L"USERPROFILE", "C:\\"); }

moonbit_bytes_t sfs_tmpdir(void) {
  wchar_t w[MAX_PATH + 2];
  DWORD n = GetTempPathW(MAX_PATH + 1, w);
  if (n == 0) return bytes_of("C:\\Windows\\Temp", 15);
  // (as Node's os.tmpdir: without its last separator, but a drive's root's)
  if (n > 3 && (w[n - 1] == L'\\' || w[n - 1] == L'/')) w[n - 1] = 0;
  char *s = narrow(w);
  moonbit_bytes_t out = bytes_of(s ? s : "", s ? strlen(s) : 0);
  free(s);
  return out;
}

static uint64_t ft64(FILETIME t) { return ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime; }

/// The machine as Node's os module says it, JSON: its CPUs (model, MHz, the ticks of each kind, ms), memory, load,
/// uptime, and this process's resident memory (`rss`) and footprint.
moonbit_bytes_t sfs_machine(void) {
  sbuf_t b = {0};
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  char model[256] = "";
  DWORD mhz = 0;
  HKEY key;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", 0, KEY_READ, &key) == ERROR_SUCCESS) {
    wchar_t w[256];
    DWORD size = sizeof w;
    if (RegQueryValueExW(key, L"ProcessorNameString", NULL, NULL, (LPBYTE)w, &size) == ERROR_SUCCESS) {
      char *s = narrow(w);
      if (s) snprintf(model, sizeof model, "%s", s);
      free(s);
    }
    size = sizeof mhz;
    RegQueryValueExW(key, L"~MHz", NULL, NULL, (LPBYTE)&mhz, &size);
    RegCloseKey(key);
  }
  FILETIME idle, kernel, user;
  uint64_t idle_ms = 0, sys_ms = 0, user_ms = 0;
  if (GetSystemTimes(&idle, &kernel, &user)) {
    idle_ms = ft64(idle) / 10000ULL;
    sys_ms = (ft64(kernel) - ft64(idle)) / 10000ULL;
    user_ms = ft64(user) / 10000ULL;
  }
  unsigned n = si.dwNumberOfProcessors ? si.dwNumberOfProcessors : 1;
  sb_str(&b, "{\"cpus\":[");
  for (unsigned i = 0; i < n; i++) {
    if (i) sb_str(&b, ",");
    sb_str(&b, "{\"model\":");
    sb_json(&b, model);
    sb_fmt(&b, ",\"speed\":%.0f", (double)mhz);
    sb_fmt(&b, ",\"times\":{\"user\":%.0f", (double)(user_ms / n));
    sb_fmt(&b, ",\"nice\":%.0f", 0);
    sb_fmt(&b, ",\"sys\":%.0f", (double)(sys_ms / n));
    sb_fmt(&b, ",\"idle\":%.0f", (double)(idle_ms / n));
    sb_fmt(&b, ",\"irq\":%.0f}}", 0);
  }
  MEMORYSTATUSEX mem;
  mem.dwLength = sizeof mem;
  GlobalMemoryStatusEx(&mem);
  sb_fmt(&b, "],\"totalmem\":%.0f", (double)mem.ullTotalPhys);
  sb_fmt(&b, ",\"freemem\":%.0f", (double)mem.ullAvailPhys);
  sb_str(&b, ",\"loadavg\":[0,0,0]");
  sb_fmt(&b, ",\"uptime\":%.0f", (double)(GetTickCount64() / 1000ULL));
  PROCESS_MEMORY_COUNTERS pmc;
  double rss = 0, footprint = 0;
  if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) {
    rss = (double)pmc.WorkingSetSize;
    footprint = (double)pmc.PagefileUsage;
  }
  sb_fmt(&b, ",\"rss\":%.0f", rss);
  sb_fmt(&b, ",\"footprint\":%.0f}", footprint);
  return sb_bytes(&b);
}

/// This process's open handles (health.json's `openFds`), or -1 where not read: one call, no child.
int32_t sfs_open_fds(void) {
  DWORD count = 0;
  return GetProcessHandleCount(GetCurrentProcess(), &count) ? (int32_t)count : -1;
}

/// This process's resident memory in bytes (health.json's `rssBytes`), or -1 where not read: only its own counters,
/// never the whole machine as `sfs_machine` reads it.
double sfs_self_rss(void) {
  PROCESS_MEMORY_COUNTERS pmc;
  return K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc) ? (double)pmc.WorkingSetSize : -1.0;
}

/// A disk's free and whole size where `path` is, JSON `{free, total}`; empty where it is not read.
/// Whether `path` is a file that can be run (platform `findCommandSoon`'s check): on Windows, a file at all.
int32_t sfs_executable(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path);
  DWORD attrs = w ? GetFileAttributesW(w) : INVALID_FILE_ATTRIBUTES;
  free(w);
  return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

moonbit_bytes_t sfs_disk_of(moonbit_bytes_t path) {
  wchar_t *w = wide((const char *)path);
  ULARGE_INTEGER avail, total, free_;
  int ok = w && GetDiskFreeSpaceExW(w, &avail, &total, &free_);
  free(w);
  if (!ok) return bytes_of("", 0);
  sbuf_t b = {0};
  sb_fmt(&b, "{\"free\":%.0f", (double)avail.QuadPart);
  sb_fmt(&b, ",\"total\":%.0f}", (double)total.QuadPart);
  return sb_bytes(&b);
}

/// This machine's addresses on its networks (none of its loopback), JSON `[{name, address, family}]`.
moonbit_bytes_t sfs_lan_addrs(void) {
  ULONG size = 16 * 1024;
  IP_ADAPTER_ADDRESSES *list = NULL;
  ULONG rc = ERROR_BUFFER_OVERFLOW;
  for (int tries = 0; tries < 3 && rc == ERROR_BUFFER_OVERFLOW; tries++) {
    free(list);
    list = malloc(size);
    if (list == NULL) return bytes_of("[]", 2);
    rc = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, NULL, list, &size);
  }
  sbuf_t b = {0};
  sb_str(&b, "[");
  int first = 1;
  if (rc == NO_ERROR) {
    for (IP_ADAPTER_ADDRESSES *a = list; a; a = a->Next) {
      if (a->OperStatus != IfOperStatusUp || a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
      char *name = narrow(a->FriendlyName);
      for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
        char text[INET6_ADDRSTRLEN] = "";
        int family = u->Address.lpSockaddr->sa_family;
        if (family == AF_INET) {
          inet_ntop(AF_INET, &((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr, text, sizeof text);
        } else if (family == AF_INET6) {
          inet_ntop(AF_INET6, &((struct sockaddr_in6 *)u->Address.lpSockaddr)->sin6_addr, text, sizeof text);
        } else {
          continue;
        }
        if (!first) sb_str(&b, ",");
        first = 0;
        sb_str(&b, "{\"name\":");
        sb_json(&b, name ? name : "");
        sb_str(&b, ",\"address\":");
        sb_json(&b, text);
        sb_str(&b, family == AF_INET ? ",\"family\":\"IPv4\"}" : ",\"family\":\"IPv6\"}");
      }
      free(name);
    }
  }
  free(list);
  sb_str(&b, "]");
  return sb_bytes(&b);
}

int32_t sfs_parent_pid(void) {
  DWORD me = GetCurrentProcessId(), parent = 0;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W e;
  e.dwSize = sizeof e;
  for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
    if (e.th32ProcessID == me) {
      parent = e.th32ParentProcessID;
      break;
    }
  }
  CloseHandle(snap);
  return (int32_t)parent;
}

int32_t sfs_pid_alive(int32_t pid) {
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
  if (h == NULL) return GetLastError() == ERROR_ACCESS_DENIED;
  DWORD code = 0;
  int alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
  CloseHandle(h);
  return alive;
}

/// Runs `line` hidden and waits for it (taskkill).
static int run_hidden(wchar_t *line) {
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return -1;
  WaitForSingleObject(pi.hProcess, 30000);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return (int)code;
}

/// A signal sent (1 SIGHUP, 2 SIGINT, 9 SIGKILL, 15 SIGTERM, 101 SIGUSR1, 102 SIGUSR2; 0 asks whether it is there), to
/// its group with `group`: on Windows the process ended (its tree with `group`, taskkill /T /F).
int32_t sfs_kill(int32_t pid, int32_t sig, int32_t group) {
  if (sig == 0) return sfs_pid_alive(pid) ? 0 : -1;
  if (group) {
    wchar_t line[96];
    swprintf(line, 96, L"taskkill /T /F /PID %d", pid);
    return run_hidden(line) == 0 ? 0 : -1;
  }
  HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
  if (h == NULL) return -1;
  int ok = TerminateProcess(h, 1);
  CloseHandle(h);
  return ok ? 0 : -1;
}

// ── locks ──

typedef struct {
  int64_t id;
  char *path;
} lock_job_t;

static DWORD WINAPI lock_thread(LPVOID arg) {
  lock_job_t *job = arg;
  wchar_t *w = wide(job->path);
  HANDLE h = w ? CreateFileW(w, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL) : INVALID_HANDLE_VALUE;
  free(w);
  char msg[600];
  if (h == INVALID_HANDLE_VALUE) {
    win_error(GetLastError(), msg, sizeof msg);
    sys_told_text(job->id, '0', msg);
  } else {
    OVERLAPPED o;
    memset(&o, 0, sizeof o);
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, MAXDWORD, MAXDWORD, &o)) {
      win_error(GetLastError(), msg, sizeof msg);
      CloseHandle(h);
      sys_told_text(job->id, '0', msg);
    } else {
      snprintf(msg, sizeof msg, "%lld", (long long)(intptr_t)h);
      sys_told_text(job->id, '1', msg);
    }
  }
  free(job->path);
  free(job);
  return 0;
}

/// archive.rs `file_lock`: the lock file made (never truncated) and an exclusive lock taken on it, waited for on a
/// thread of its own; told `1<handle>` once taken, `0<why>` where it failed.
void sfs_file_lock(int64_t id, moonbit_bytes_t path) {
  lock_job_t *job = malloc(sizeof *job);
  job->id = id;
  job->path = _strdup((const char *)path);
  start_thread(lock_thread, job);
}

int32_t sfs_file_unlock(int64_t handle) {
  HANDLE h = (HANDLE)(intptr_t)handle;
  OVERLAPPED o;
  memset(&o, 0, sizeof o);
  UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &o);
  return CloseHandle(h) ? 1 : 0;
}

/// No Unix socket's peer on Windows.
moonbit_bytes_t sfs_peer_process(int32_t fd) {
  (void)fd;
  return bytes_of("", 0);
}

/// Read on macOS alone.
moonbit_bytes_t sfs_process_usage(int32_t pid) {
  (void)pid;
  return bytes_of("", 0);
}

// ── processes ──

typedef struct {
  int64_t id;
  HANDLE h;
  char tag;
} pipe_job_t;


static DWORD WINAPI pipe_thread(LPVOID arg) {
  pipe_job_t *job = arg;
  uint8_t buf[1 + 65536];
  buf[0] = (uint8_t)job->tag;
  DWORD n;
  while (ReadFile(job->h, buf + 1, 65536, &n, NULL) && n > 0) {
    sfh_push_sys_bounded((uint64_t)job->id, buf, (size_t)n + 1);
  }
  CloseHandle(job->h);
  sys_told(job->id, job->tag == 'o' ? 'O' : 'E', "", 0);
  free(job);
  return 0;
}

typedef struct stdin_writer {
  int64_t id;
  struct stdin_writer *hash_next;
  int refs; // protected by stdin_table_lock
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE cond;
  stdin_chunk_t *head;
  stdin_chunk_t *tail;
  size_t queued;
  size_t limit;
  int eof_requested;
  int aborted;
  HANDLE h;
  HANDLE proc;
} stdin_writer_t;

static CRITICAL_SECTION stdin_table_lock;
static INIT_ONCE stdin_table_once = INIT_ONCE_STATIC_INIT;
static stdin_writer_t *stdin_buckets[STDIN_BUCKETS];
static int64_t stdin_next_id = 1;

static BOOL CALLBACK stdin_table_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  InitializeCriticalSection(&stdin_table_lock);
  return TRUE;
}

static void stdin_table_ensure(void) {
  InitOnceExecuteOnce(&stdin_table_once, stdin_table_init, NULL, NULL);
}

static size_t stdin_limit_bytes(void) {
  char buf[64];
  DWORD n = GetEnvironmentVariableA("STILLFAIL_STDIN_MOST", buf, (DWORD)sizeof buf);
  if (n == 0 || n >= sizeof buf) return STDIN_DEFAULT_MOST;
  return stdin_parse_limit(buf);
}

static void stdin_writer_unref(stdin_writer_t *w) {
  EnterCriticalSection(&stdin_table_lock);
  int last = (--w->refs == 0);
  LeaveCriticalSection(&stdin_table_lock);
  if (!last) return;
  stdin_free_chunks(w->head);
  if (w->h != NULL) CloseHandle(w->h);
  if (w->proc != NULL) CloseHandle(w->proc);
  DeleteCriticalSection(&w->lock);
  free(w);
}

static stdin_writer_t *stdin_table_get(int64_t id) {
  if (id <= 0) return NULL;
  stdin_table_ensure();
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  EnterCriticalSection(&stdin_table_lock);
  stdin_writer_t *w = stdin_buckets[b];
  while (w != NULL && w->id != id) w = w->hash_next;
  if (w != NULL) w->refs++;
  LeaveCriticalSection(&stdin_table_lock);
  return w;
}

static stdin_writer_t *stdin_table_take(int64_t id) {
  if (id <= 0) return NULL;
  stdin_table_ensure();
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  EnterCriticalSection(&stdin_table_lock);
  stdin_writer_t **pp = &stdin_buckets[b];
  stdin_writer_t *found = NULL;
  while (*pp != NULL) {
    if ((*pp)->id == id) {
      found = *pp;
      *pp = found->hash_next;
      found->hash_next = NULL;
      break;
    }
    pp = &(*pp)->hash_next;
  }
  LeaveCriticalSection(&stdin_table_lock);
  return found;
}

static void stdin_abort_id(int64_t id) {
  stdin_writer_t *w = stdin_table_take(id);
  if (w == NULL) return;
  EnterCriticalSection(&w->lock);
  w->aborted = 1;
  stdin_chunk_t *drop = w->head;
  w->head = w->tail = NULL;
  w->queued = 0;
  WakeConditionVariable(&w->cond);
  LeaveCriticalSection(&w->lock);
  stdin_free_chunks(drop);
  stdin_writer_unref(w);
}

static DWORD WINAPI stdin_write_thread(LPVOID arg) {
  stdin_writer_t *w = arg;
  for (;;) {
    EnterCriticalSection(&w->lock);
    while (!w->aborted && w->head == NULL && !w->eof_requested) {
      SleepConditionVariableCS(&w->cond, &w->lock, INFINITE);
    }
    if (w->aborted) {
      stdin_chunk_t *drop = w->head;
      w->head = w->tail = NULL;
      w->queued = 0;
      LeaveCriticalSection(&w->lock);
      stdin_free_chunks(drop);
      break;
    }
    if (w->head != NULL) {
      stdin_chunk_t *ch = w->head;
      w->head = ch->next;
      if (w->head == NULL) w->tail = NULL;
      w->queued -= ch->len;
      HANDLE h = w->h;
      LeaveCriticalSection(&w->lock);

      size_t done = 0;
      int ok = 1;
      while (done < ch->len) {
        size_t rem = ch->len - done;
        DWORD want = rem > 0x7fffffffu ? 0x7fffffffu : (DWORD)rem;
        DWORD n = 0;
        if (!WriteFile(h, ch->data + done, want, &n, NULL) || n == 0) {
          ok = 0;
          break;
        }
        done += (size_t)n;
      }
      free(ch);
      if (!ok) {
        EnterCriticalSection(&w->lock);
        w->aborted = 1;
        stdin_chunk_t *drop = w->head;
        w->head = w->tail = NULL;
        w->queued = 0;
        LeaveCriticalSection(&w->lock);
        stdin_free_chunks(drop);
        stdin_writer_t *taken = stdin_table_take(w->id);
        if (taken != NULL) stdin_writer_unref(taken);
        break;
      }
      continue;
    }
    if (w->eof_requested) {
      LeaveCriticalSection(&w->lock);
      break;
    }
    LeaveCriticalSection(&w->lock);
  }
  if (w->h != NULL) {
    CloseHandle(w->h);
    w->h = NULL;
  }
  stdin_writer_unref(w);
  return 0;
}

static int64_t stdin_writer_start(HANDLE h, HANDLE proc) {
  stdin_table_ensure();
  stdin_writer_t *w = calloc(1, sizeof *w);
  if (w == NULL) {
    CloseHandle(h);
    if (proc != NULL) CloseHandle(proc);
    return -1;
  }
  w->refs = 2; // 1 for table, 1 for writer thread
  w->limit = stdin_limit_bytes();
  w->h = h;
  w->proc = proc;
  InitializeCriticalSection(&w->lock);
  InitializeConditionVariable(&w->cond);

  EnterCriticalSection(&stdin_table_lock);
  int64_t id = stdin_next_id++;
  if (stdin_next_id <= 0) stdin_next_id = 1;
  w->id = id;
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  w->hash_next = stdin_buckets[b];
  stdin_buckets[b] = w;
  LeaveCriticalSection(&stdin_table_lock);

  if (!start_thread(stdin_write_thread, w)) {
    stdin_writer_t *taken = stdin_table_take(id);
    if (taken != NULL) stdin_writer_unref(taken);
    stdin_writer_unref(w);
    return -1;
  }
  return id;
}

typedef struct {
  int64_t id;
  HANDLE process;
  int64_t stdin_id;
} wait_job_t;

static DWORD WINAPI wait_thread(LPVOID arg) {
  wait_job_t *job = arg;
  WaitForSingleObject(job->process, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(job->process, &code);
  CloseHandle(job->process);
  if (job->stdin_id > 0) stdin_abort_id(job->stdin_id);
  char msg[64];
  snprintf(msg, sizeof msg, "%lu ", (unsigned long)code);
  sys_told_text(job->id, 'x', msg);
  free(job);
  return 0;
}

/// An argument quoted as the C runtime reads a command line back (CommandLineToArgvW's rules).
static void quote_arg(sbuf_t *b, const char *a) {
  if (*a && !strpbrk(a, " \t\n\v\"")) {
    sb_str(b, a);
    return;
  }
  sb_str(b, "\"");
  for (const char *p = a;; p++) {
    size_t slashes = 0;
    while (*p == '\\') {
      p++;
      slashes++;
    }
    if (*p == 0) {
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

static HANDLE inheritable_file(const char *path, int append) {
  SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
  wchar_t *w = wide(path);
  HANDLE h = w ? CreateFileW(w, append ? FILE_APPEND_DATA : GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &sa, append ? OPEN_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL) : INVALID_HANDLE_VALUE;
  free(w);
  return h;
}

/// A child started: `program` with `args` and `env` (each ended by a NUL; no env: this one's), in `cwd` ("" this one's);
/// stdin 0 nothing, 1 a pipe (its handle in `out[1]`); stdout and stderr 0 nothing, 1 a pipe (told 'o' and 'e', their
/// ends 'O' and 'E'), 2 appended to `out_file` / `err_file`; in a group of its own with `group`. Its end told 'x' with
/// its code and the signal that ended it. Its pid, or -1 (`out[0]` the error's words' length in the reason buffer).
int32_t sfs_spawn(int64_t id, moonbit_bytes_t program, moonbit_bytes_t args, moonbit_bytes_t env, moonbit_bytes_t cwd,
                  int32_t in_mode, int32_t out_mode, int32_t err_mode, moonbit_bytes_t out_file, moonbit_bytes_t err_file,
                  int32_t group, int64_t *out, moonbit_bytes_t why) {
  sbuf_t line = {0};
  quote_arg(&line, (const char *)program);
  int32_t args_len = Moonbit_array_length(args);
  for (int32_t i = 0; i < args_len;) {
    const char *a = (const char *)args + i;
    size_t n = strlen(a);
    sb_str(&line, " ");
    quote_arg(&line, a);
    i += (int32_t)n + 1;
  }
  wchar_t *wline = wide(line.data ? line.data : "");
  free(line.data);
  wchar_t *wenv = NULL;
  int32_t env_len = Moonbit_array_length(env);
  if (env_len > 0) {
    int wn = MultiByteToWideChar(CP_UTF8, 0, (const char *)env, env_len, NULL, 0);
    wenv = calloc((size_t)wn + 2, sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, (const char *)env, env_len, wenv, wn);
  }
  wchar_t *wcwd = Moonbit_array_length(cwd) > 1 ? wide((const char *)cwd) : NULL;
  SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
  HANDLE child[3] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE };
  HANDLE mine[3] = { NULL, NULL, NULL };
  int modes[3] = { in_mode, out_mode, err_mode };
  const char *files[3] = { NULL, (const char *)out_file, (const char *)err_file };
  for (int i = 0; i < 3; i++) {
    if (modes[i] == 1) {
      HANDLE r, w;
      CreatePipe(&r, &w, &sa, 0);
      if (i == 0) {
        child[i] = r;
        mine[i] = w;
      } else {
        child[i] = w;
        mine[i] = r;
      }
      SetHandleInformation(mine[i], HANDLE_FLAG_INHERIT, 0);
    } else if (modes[i] == 2) {
      child[i] = inheritable_file(files[i], 1);
    } else {
      child[i] = inheritable_file("NUL", 0);
    }
  }
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = child[0];
  si.hStdOutput = child[1];
  si.hStdError = child[2];
  DWORD flags = CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | (group ? CREATE_NEW_PROCESS_GROUP : 0);
  BOOL ok = wline && CreateProcessW(NULL, wline, NULL, NULL, TRUE, flags, wenv, wcwd, &si, &pi);
  DWORD code = ok ? 0 : GetLastError();
  for (int i = 0; i < 3; i++) if (child[i] != INVALID_HANDLE_VALUE) CloseHandle(child[i]);
  free(wline);
  free(wenv);
  free(wcwd);
  if (!ok) {
    for (int i = 0; i < 3; i++) if (mine[i]) CloseHandle(mine[i]);
    char msg[512];
    win_error(code, msg, sizeof msg);
    size_t n = strlen(msg);
    int32_t room = Moonbit_array_length(why);
    if ((int32_t)n > room) n = (size_t)room;
    memcpy(why, msg, n);
    out[0] = (int64_t)n;
    return -1;
  }
  CloseHandle(pi.hThread);
  int64_t stdin_id = -1;
  if (mine[0]) {
    HANDLE proc_dup = NULL;
    DuplicateHandle(GetCurrentProcess(), pi.hProcess, GetCurrentProcess(), &proc_dup, PROCESS_TERMINATE, FALSE, 0);
    stdin_id = stdin_writer_start(mine[0], proc_dup);
  }
  out[1] = stdin_id;
  for (int i = 1; i < 3; i++) {
    if (mine[i]) {
      pipe_job_t *job = malloc(sizeof *job);
      job->id = id;
      job->h = mine[i];
      job->tag = i == 1 ? 'o' : 'e';
      start_thread(pipe_thread, job);
    }
  }
  wait_job_t *wj = malloc(sizeof *wj);
  wj->id = id;
  wj->process = pi.hProcess;
  wj->stdin_id = stdin_id > 0 ? stdin_id : 0;
  start_thread(wait_thread, wj);
  return (int32_t)pi.dwProcessId;
}

int32_t sfs_handle_write(int64_t handle, moonbit_bytes_t b) {
  stdin_writer_t *w = stdin_table_get(handle);
  if (w == NULL) return 0;
  size_t len = (size_t)Moonbit_array_length(b);
  EnterCriticalSection(&w->lock);
  if (w->eof_requested || w->aborted) {
    LeaveCriticalSection(&w->lock);
    stdin_writer_unref(w);
    return 0;
  }
  if (len == 0) {
    LeaveCriticalSection(&w->lock);
    stdin_writer_unref(w);
    return 1;
  }
  if (len > w->limit || w->queued > w->limit - len) {
    w->aborted = 1;
    stdin_chunk_t *drop = w->head;
    w->head = w->tail = NULL;
    w->queued = 0;
    WakeConditionVariable(&w->cond);
    LeaveCriticalSection(&w->lock);
    stdin_free_chunks(drop);
    stdin_writer_t *taken = stdin_table_take(handle);
    if (taken != NULL) stdin_writer_unref(taken);
    if (w->proc != NULL) TerminateProcess(w->proc, 1);
    stdin_writer_unref(w);
    return 0;
  }
  stdin_chunk_t *ch = malloc(sizeof *ch + len);
  if (ch == NULL) {
    LeaveCriticalSection(&w->lock);
    stdin_writer_unref(w);
    return 0;
  }
  ch->next = NULL;
  ch->len = len;
  memcpy(ch->data, b, len);
  if (w->tail != NULL) w->tail->next = ch;
  else w->head = ch;
  w->tail = ch;
  w->queued += len;
  WakeConditionVariable(&w->cond);
  LeaveCriticalSection(&w->lock);
  stdin_writer_unref(w);
  return 1;
}

int32_t sfs_handle_close(int64_t handle) {
  stdin_writer_t *w = stdin_table_take(handle);
  if (w == NULL) return 0;
  EnterCriticalSection(&w->lock);
  w->eof_requested = 1;
  WakeConditionVariable(&w->cond);
  LeaveCriticalSection(&w->lock);
  stdin_writer_unref(w);
  return 1;
}

// ── control lines and signals ──

typedef struct {
  int64_t id;
  int fd;
} lines_job_t;

static void lines_from(int64_t id, int (*read_some)(void *, char *, int), void *ctx) {
  sbuf_t line = {0};
  char buf[4096];
  int n;
  while ((n = read_some(ctx, buf, sizeof buf)) > 0) {
    for (int i = 0; i < n; i++) {
      if (buf[i] == '\n') {
        sys_told(id, 'l', line.data ? line.data : "", line.len);
        line.len = 0;
      } else {
        sb_add(&line, buf + i, 1);
      }
    }
  }
  if (line.len) sys_told(id, 'l', line.data, line.len);
  free(line.data);
  sys_told(id, 'z', "", 0);
}

static int read_fd(void *ctx, char *buf, int size) { return _read(*(int *)ctx, buf, (unsigned)size); }

static DWORD WINAPI lines_thread(LPVOID arg) {
  lines_job_t *job = arg;
  lines_from(job->id, read_fd, &job->fd);
  free(job);
  return 0;
}

/// Each line read from `fd` told 'l' (without its end), its end 'z'.
void sfs_read_lines(int64_t id, int32_t fd) {
  lines_job_t *job = malloc(sizeof *job);
  job->id = id;
  job->fd = fd;
  start_thread(lines_thread, job);
}

static int64_t signal_id = 0;

static BOOL WINAPI on_ctrl(DWORD kind) {
  if (signal_id == 0) return FALSE;
  const char *name = kind == CTRL_C_EVENT ? "SIGINT" : kind == CTRL_BREAK_EVENT ? "SIGBREAK" : "SIGTERM";
  sys_told_text(signal_id, 's', name);
  return TRUE;
}

/// The signals a station ends or is told by: ignored (`ignore`: a launcher tells it on its control line instead), or
/// each told 's' with its name.
void sfs_signals(int64_t id, int32_t ignore) {
  if (ignore) {
    SetConsoleCtrlHandler(NULL, TRUE);
    return;
  }
  signal_id = id;
  SetConsoleCtrlHandler(on_ctrl, TRUE);
}

#else
// ───────────────────────────────────────────── Unix ─────────────────────────────────────────────
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <pwd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/un.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <sys/resource.h>
extern char **environ;
#else
#include <sys/sysinfo.h>
#include <dirent.h>
extern char **environ;
#endif

static int start_thread(void *(*f)(void *), void *arg) {
  pthread_t t;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&t, &attr, f, arg);
  pthread_attr_destroy(&attr);
  return rc == 0;
}

static int write_all(int fd, const uint8_t *b, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, b + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return 0;
    done += (size_t)n;
  }
  return 1;
}

int32_t sfs_err(moonbit_bytes_t b) { return write_all(2, b, (size_t)Moonbit_array_length(b)); }

int32_t sfs_fd_write(int32_t fd, moonbit_bytes_t b) { return write_all(fd, b, (size_t)Moonbit_array_length(b)); }

int32_t sfs_fd_close(int32_t fd) { return close(fd) == 0; }

moonbit_bytes_t sfs_env_all(void) {
  sbuf_t b = {0};
  for (char **e = environ; e && *e; e++) sb_add(&b, *e, strlen(*e) + 1);
  return sb_bytes(&b);
}

int32_t sfs_env_set(moonbit_bytes_t name, moonbit_bytes_t value) { return setenv((const char *)name, (const char *)value, 1) == 0; }

int32_t sfs_env_unset(moonbit_bytes_t name) { return unsetenv((const char *)name) == 0; }

moonbit_bytes_t sfs_hostname(void) {
  char name[256];
  if (gethostname(name, sizeof name) != 0) return bytes_of("", 0);
  name[255] = 0;
  return bytes_of(name, strlen(name));
}

/// As Node's os.homedir: $HOME, else the user's entry.
moonbit_bytes_t sfs_homedir(void) {
  const char *home = getenv("HOME");
  if (home && *home) return bytes_of(home, strlen(home));
  struct passwd *pw = getpwuid(getuid());
  if (pw && pw->pw_dir) return bytes_of(pw->pw_dir, strlen(pw->pw_dir));
  return bytes_of("/", 1);
}

/// As Node's os.tmpdir: $TMPDIR (or $TMP, $TEMP) without its last slash, else /tmp.
moonbit_bytes_t sfs_tmpdir(void) {
  const char *names[3] = { "TMPDIR", "TMP", "TEMP" };
  for (int i = 0; i < 3; i++) {
    const char *t = getenv(names[i]);
    if (t && *t) {
      size_t n = strlen(t);
      if (n > 1 && t[n - 1] == '/') n--;
      return bytes_of(t, n);
    }
  }
  return bytes_of("/tmp", 4);
}

#ifdef __APPLE__
static void cpu_part(sbuf_t *b) {
  char model[256] = "";
  size_t size = sizeof model;
  sysctlbyname("machdep.cpu.brand_string", model, &size, NULL, 0);
  uint64_t freq = 0;
  size = sizeof freq;
  if (sysctlbyname("hw.cpufrequency", &freq, &size, NULL, 0) != 0) freq = 0;
  natural_t count = 0;
  processor_info_array_t info;
  mach_msg_type_number_t info_count;
  long ticks = sysconf(_SC_CLK_TCK);
  double ms = ticks > 0 ? 1000.0 / (double)ticks : 10.0;
  sb_str(b, "\"cpus\":[");
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &info_count) == KERN_SUCCESS) {
    for (natural_t i = 0; i < count; i++) {
      unsigned *t = (unsigned *)info + CPU_STATE_MAX * i;
      if (i) sb_str(b, ",");
      sb_str(b, "{\"model\":");
      sb_json(b, model);
      sb_fmt(b, ",\"speed\":%.0f", (double)(freq / 1000000ULL));
      sb_fmt(b, ",\"times\":{\"user\":%.0f", t[CPU_STATE_USER] * ms);
      sb_fmt(b, ",\"nice\":%.0f", t[CPU_STATE_NICE] * ms);
      sb_fmt(b, ",\"sys\":%.0f", t[CPU_STATE_SYSTEM] * ms);
      sb_fmt(b, ",\"idle\":%.0f", t[CPU_STATE_IDLE] * ms);
      sb_str(b, ",\"irq\":0}}");
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, info_count * sizeof(integer_t));
  }
  sb_str(b, "]");
}

static void memory_part(sbuf_t *b) {
  uint64_t total = 0;
  size_t size = sizeof total;
  sysctlbyname("hw.memsize", &total, &size, NULL, 0);
  vm_statistics64_data_t vm;
  mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
  double free_ = 0;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) == KERN_SUCCESS) {
    free_ = (double)(vm.free_count + vm.inactive_count) * (double)vm_page_size; // (libuv's uv_get_free_memory)
  }
  sb_fmt(b, ",\"totalmem\":%.0f", (double)total);
  sb_fmt(b, ",\"freemem\":%.0f", free_);
  struct timeval boot;
  size = sizeof boot;
  int mib[2] = { CTL_KERN, KERN_BOOTTIME };
  double up = 0;
  if (sysctl(mib, 2, &boot, &size, NULL, 0) == 0) up = (double)(time(NULL) - boot.tv_sec);
  sb_fmt(b, ",\"uptime\":%.0f", up);
  mach_task_basic_info_data_t basic;
  mach_msg_type_number_t bn = MACH_TASK_BASIC_INFO_COUNT;
  double rss = 0, footprint = 0;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &bn) == KERN_SUCCESS) rss = (double)basic.resident_size;
  task_vm_info_data_t vmi;
  mach_msg_type_number_t vn = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &vn) == KERN_SUCCESS) footprint = (double)vmi.phys_footprint;
  sb_fmt(b, ",\"rss\":%.0f", rss);
  sb_fmt(b, ",\"footprint\":%.0f", footprint);
}
#else
static void cpu_part(sbuf_t *b) {
  char model[256] = "";
  double speed = 0;
  FILE *f = fopen("/proc/cpuinfo", "r");
  char line[512];
  if (f) {
    while (fgets(line, sizeof line, f)) {
      char *colon = strchr(line, ':');
      if (!colon) continue;
      if (!model[0] && (strncmp(line, "model name", 10) == 0 || strncmp(line, "Model", 5) == 0)) {
        char *v = colon + 1;
        while (*v == ' ' || *v == '\t') v++;
        size_t n = strcspn(v, "\n");
        if (n >= sizeof model) n = sizeof model - 1;
        memcpy(model, v, n);
        model[n] = 0;
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
  if (f) {
    while (fgets(line, sizeof line, f)) {
      if (strncmp(line, "cpu", 3) != 0 || line[3] < '0' || line[3] > '9') continue;
      unsigned long long user = 0, nice = 0, sys = 0, idle = 0, iowait = 0, irq = 0;
      char *p = line + 3;
      while (*p && *p != ' ') p++;
      sscanf(p, "%llu %llu %llu %llu %llu %llu", &user, &nice, &sys, &idle, &iowait, &irq);
      if (!first) sb_str(b, ",");
      first = 0;
      sb_str(b, "{\"model\":");
      sb_json(b, model[0] ? model : "unknown");
      sb_fmt(b, ",\"speed\":%.0f", speed);
      sb_fmt(b, ",\"times\":{\"user\":%.0f", (double)user * ms);
      sb_fmt(b, ",\"nice\":%.0f", (double)nice * ms);
      sb_fmt(b, ",\"sys\":%.0f", (double)sys * ms);
      sb_fmt(b, ",\"idle\":%.0f", (double)idle * ms);
      sb_fmt(b, ",\"irq\":%.0f}}", (double)irq * ms);
    }
    fclose(f);
  }
  sb_str(b, "]");
}

static double meminfo(const char *key) {
  FILE *f = fopen("/proc/meminfo", "r");
  if (!f) return -1;
  char line[256];
  double v = -1;
  size_t kl = strlen(key);
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, key, kl) == 0 && line[kl] == ':') {
      v = atof(line + kl + 1) * 1024.0;
      break;
    }
  }
  fclose(f);
  return v;
}

static void memory_part(sbuf_t *b) {
  double total = meminfo("MemTotal"), avail = meminfo("MemAvailable");
  if (avail < 0) avail = meminfo("MemFree");
  sb_fmt(b, ",\"totalmem\":%.0f", total < 0 ? 0 : total);
  sb_fmt(b, ",\"freemem\":%.0f", avail < 0 ? 0 : avail);
  double up = 0;
  FILE *f = fopen("/proc/uptime", "r");
  if (f) {
    if (fscanf(f, "%lf", &up) != 1) up = 0;
    fclose(f);
  }
  sb_fmt(b, ",\"uptime\":%.0f", up);
  double rss = 0;
  f = fopen("/proc/self/statm", "r");
  if (f) {
    unsigned long size = 0, resident = 0;
    if (fscanf(f, "%lu %lu", &size, &resident) == 2) rss = (double)resident * (double)sysconf(_SC_PAGESIZE);
    fclose(f);
  }
  sb_fmt(b, ",\"rss\":%.0f", rss);
  sb_fmt(b, ",\"footprint\":%.0f", rss);
}
#endif

moonbit_bytes_t sfs_machine(void) {
  sbuf_t b = {0};
  sb_str(&b, "{");
  cpu_part(&b);
  memory_part(&b);
  double load[3] = { 0, 0, 0 };
  if (getloadavg(load, 3) != 3) load[0] = load[1] = load[2] = 0;
  sb_fmt(&b, ",\"loadavg\":[%.6f", load[0]);
  sb_fmt(&b, ",%.6f", load[1]);
  sb_fmt(&b, ",%.6f]}", load[2]);
  return sb_bytes(&b);
}

/// Whether `path` is a regular file (links followed) with an execute bit (unix.ts `findCommandSoon`: `mode & 0o111`).
int32_t sfs_executable(moonbit_bytes_t path) {
  struct stat st;
  return stat((const char *)path, &st) == 0 && S_ISREG(st.st_mode) && (st.st_mode & 0111) != 0;
}

moonbit_bytes_t sfs_disk_of(moonbit_bytes_t path) {
  struct statvfs s;
  if (statvfs((const char *)path, &s) != 0) return bytes_of("", 0);
  sbuf_t b = {0};
  sb_fmt(&b, "{\"free\":%.0f", (double)s.f_bavail * (double)s.f_frsize);
  sb_fmt(&b, ",\"total\":%.0f}", (double)s.f_blocks * (double)s.f_frsize);
  return sb_bytes(&b);
}

moonbit_bytes_t sfs_lan_addrs(void) {
  struct ifaddrs *list = NULL;
  sbuf_t b = {0};
  sb_str(&b, "[");
  if (getifaddrs(&list) == 0) {
    int first = 1;
    for (struct ifaddrs *a = list; a; a = a->ifa_next) {
      // (up and running, as libuv's uv_interface_addresses takes them: a bridge with nothing on it is up, not running)
      if (!a->ifa_addr || !(a->ifa_flags & IFF_UP) || !(a->ifa_flags & IFF_RUNNING) || (a->ifa_flags & IFF_LOOPBACK)) continue;
      int family = a->ifa_addr->sa_family;
      char text[INET6_ADDRSTRLEN] = "";
      if (family == AF_INET) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, text, sizeof text);
      } else if (family == AF_INET6) {
        inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ifa_addr)->sin6_addr, text, sizeof text);
      } else {
        continue;
      }
      if (!first) sb_str(&b, ",");
      first = 0;
      sb_str(&b, "{\"name\":");
      sb_json(&b, a->ifa_name ? a->ifa_name : "");
      sb_str(&b, ",\"address\":");
      sb_json(&b, text);
      sb_str(&b, family == AF_INET ? ",\"family\":\"IPv4\"}" : ",\"family\":\"IPv6\"}");
    }
    freeifaddrs(list);
  }
  sb_str(&b, "]");
  return sb_bytes(&b);
}

int32_t sfs_parent_pid(void) { return (int32_t)getppid(); }

int32_t sfs_pid_alive(int32_t pid) { return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM); }

static int signal_of(int32_t sig) {
  switch (sig) {
    case 1: return SIGHUP;
    case 2: return SIGINT;
    case 9: return SIGKILL;
    case 15: return SIGTERM;
    case 101: return SIGUSR1;
    case 102: return SIGUSR2;
    default: return sig;
  }
}

int32_t sfs_kill(int32_t pid, int32_t sig, int32_t group) {
  if (pid <= 0) return -1;
  int rc = kill(group ? -pid : pid, signal_of(sig));
  return rc == 0 ? 0 : -errno;
}

// ── locks ──

typedef struct {
  int64_t id;
  char *path;
} lock_job_t;

static void *lock_thread(void *arg) {
  lock_job_t *job = arg;
  int fd = open(job->path, O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC, 0600);
  char msg[600];
  if (fd < 0) {
    snprintf(msg, sizeof msg, "%s", strerror(errno));
    sys_told_text(job->id, '0', msg);
  } else {
    int rc;
    do {
      rc = flock(fd, LOCK_EX);
    } while (rc != 0 && errno == EINTR);
    if (rc != 0) {
      snprintf(msg, sizeof msg, "%s", strerror(errno));
      close(fd);
      sys_told_text(job->id, '0', msg);
    } else {
      snprintf(msg, sizeof msg, "%d", fd);
      sys_told_text(job->id, '1', msg);
    }
  }
  free(job->path);
  free(job);
  return NULL;
}

void sfs_file_lock(int64_t id, moonbit_bytes_t path) {
  lock_job_t *job = malloc(sizeof *job);
  job->id = id;
  job->path = strdup((const char *)path);
  start_thread(lock_thread, job);
}

int32_t sfs_file_unlock(int64_t handle) {
  flock((int)handle, LOCK_UN);
  return close((int)handle) == 0;
}

/// The process at the other end of a connected Unix socket, JSON `{pid, auditToken}` (local.rs `peer_process`); empty
/// where it is not known.
moonbit_bytes_t sfs_peer_process(int32_t fd) {
#if defined(__APPLE__)
  pid_t pid = 0;
  socklen_t len = sizeof pid;
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 || pid <= 0) return bytes_of("", 0);
  uint8_t token[32];
  len = sizeof token;
  int ok = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &len) == 0 && len == sizeof token;
  sbuf_t b = {0};
  sb_fmt(&b, "{\"pid\":%.0f,\"auditToken\":", (double)pid);
  if (ok) {
    char hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + 2 * i, 3, "%02x", token[i]);
    sb_json(&b, hex);
  } else {
    sb_str(&b, "null");
  }
  sb_str(&b, "}");
  return sb_bytes(&b);
#elif defined(__linux__)
  struct ucred cred;
  socklen_t len = sizeof cred;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0 || cred.pid <= 0) return bytes_of("", 0);
  sbuf_t b = {0};
  sb_fmt(&b, "{\"pid\":%.0f,\"auditToken\":null}", (double)cred.pid);
  return sb_bytes(&b);
#else
  (void)fd;
  return bytes_of("", 0);
#endif
}

/// What a process has used so far (usage.rs `process_usage`), JSON `{cpuNs, footprint, wakeups, energyNj, diskRead,
/// diskWritten}`; empty where it is not read (gone, another user's, not macOS).
moonbit_bytes_t sfs_process_usage(int32_t pid) {
#if defined(__APPLE__)
  struct rusage_info_v6 info;
  memset(&info, 0, sizeof info);
  if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&info) != 0) return bytes_of("", 0);
  mach_timebase_info_data_t base = { 1, 1 };
  mach_timebase_info(&base);
  double ticks = (double)(info.ri_user_time + info.ri_system_time);
  sbuf_t b = {0};
  sb_fmt(&b, "{\"cpuNs\":%.0f", ticks * (double)base.numer / (double)(base.denom ? base.denom : 1));
  sb_fmt(&b, ",\"footprint\":%.0f", (double)info.ri_phys_footprint);
  sb_fmt(&b, ",\"wakeups\":%.0f", (double)info.ri_interrupt_wkups);
  sb_fmt(&b, ",\"energyNj\":%.0f", (double)info.ri_energy_nj);
  sb_fmt(&b, ",\"diskRead\":%.0f", (double)info.ri_diskio_bytesread);
  sb_fmt(&b, ",\"diskWritten\":%.0f}", (double)info.ri_diskio_byteswritten);
  return sb_bytes(&b);
#else
  (void)pid;
  return bytes_of("", 0);
#endif
}

/// This process's open descriptors (health.json's `openFds`), or -1 where not read: the kernel's count, no child.
int32_t sfs_open_fds(void) {
#if defined(__APPLE__)
  int n = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
  return n >= 0 ? (int32_t)(n / (int)sizeof(struct proc_fdinfo)) : -1;
#elif defined(__linux__)
  DIR *d = opendir("/proc/self/fd");
  if (!d) return -1;
  int32_t n = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) n++;
  }
  closedir(d);
  return n > 0 ? n - 1 : -1; // (the directory's own descriptor, counted while it was open)
#else
  return -1;
#endif
}

/// This process's resident memory in bytes (health.json's `rssBytes`), or -1 where not read: only its own counters,
/// never the whole machine as `sfs_machine` reads it.
double sfs_self_rss(void) {
#if defined(__APPLE__)
  mach_task_basic_info_data_t basic;
  mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
  return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &n) == KERN_SUCCESS ? (double)basic.resident_size : -1.0;
#elif defined(__linux__)
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return -1.0;
  unsigned long size = 0, resident = 0;
  double rss = fscanf(f, "%lu %lu", &size, &resident) == 2 ? (double)resident * (double)sysconf(_SC_PAGESIZE) : -1.0;
  fclose(f);
  return rss;
#else
  return -1.0;
#endif
}

// ── processes ──

typedef struct {
  int64_t id;
  int fds[2];
} pipes_job_t;

static void *pipes_thread(void *arg) {
  pipes_job_t *job = arg;
  uint8_t buf[1 + 65536];
  int open_ = (job->fds[0] >= 0) + (job->fds[1] >= 0);
  while (open_ > 0) {
    struct pollfd p[2];
    int n = 0, which[2];
    for (int i = 0; i < 2; i++) {
      if (job->fds[i] >= 0) {
        p[n].fd = job->fds[i];
        p[n].events = POLLIN;
        p[n].revents = 0;
        which[n++] = i;
      }
    }
    if (poll(p, (nfds_t)n, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    for (int k = 0; k < n; k++) {
      if (!p[k].revents) continue;
      int i = which[k];
      ssize_t got = read(job->fds[i], buf + 1, 65536);
      if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (got <= 0) {
        close(job->fds[i]);
        job->fds[i] = -1;
        open_--;
        sys_told(job->id, i == 0 ? 'O' : 'E', "", 0);
      } else {
        buf[0] = (uint8_t)(i == 0 ? 'o' : 'e');
        sfh_push_sys_bounded((uint64_t)job->id, buf, (size_t)got + 1);
      }
    }
  }
  for (int i = 0; i < 2; i++) {
    if (job->fds[i] >= 0) {
      close(job->fds[i]);
      sys_told(job->id, i == 0 ? 'O' : 'E', "", 0);
    }
  }
  free(job);
  return NULL;
}

typedef struct stdin_writer {
  int64_t id;
  struct stdin_writer *hash_next;
  int refs; // protected by stdin_table_lock
  pthread_mutex_t lock;
  pthread_cond_t cond;
  stdin_chunk_t *head;
  stdin_chunk_t *tail;
  size_t queued;
  size_t limit;
  int eof_requested;
  int aborted;
  int fd;
  pid_t pid;
  int group;
} stdin_writer_t;

static pthread_mutex_t stdin_table_lock = PTHREAD_MUTEX_INITIALIZER;
static stdin_writer_t *stdin_buckets[STDIN_BUCKETS];
static int64_t stdin_next_id = 1;

static size_t stdin_limit_bytes(void) {
  return stdin_parse_limit(getenv("STILLFAIL_STDIN_MOST"));
}

static void stdin_writer_unref(stdin_writer_t *w) {
  pthread_mutex_lock(&stdin_table_lock);
  int last = (--w->refs == 0);
  pthread_mutex_unlock(&stdin_table_lock);
  if (!last) return;
  stdin_free_chunks(w->head);
  if (w->fd >= 0) close(w->fd);
  pthread_cond_destroy(&w->cond);
  pthread_mutex_destroy(&w->lock);
  free(w);
}

static stdin_writer_t *stdin_table_get(int64_t id) {
  if (id <= 0) return NULL;
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  pthread_mutex_lock(&stdin_table_lock);
  stdin_writer_t *w = stdin_buckets[b];
  while (w != NULL && w->id != id) w = w->hash_next;
  if (w != NULL) w->refs++;
  pthread_mutex_unlock(&stdin_table_lock);
  return w;
}

static stdin_writer_t *stdin_table_take(int64_t id) {
  if (id <= 0) return NULL;
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  pthread_mutex_lock(&stdin_table_lock);
  stdin_writer_t **pp = &stdin_buckets[b];
  stdin_writer_t *found = NULL;
  while (*pp != NULL) {
    if ((*pp)->id == id) {
      found = *pp;
      *pp = found->hash_next;
      found->hash_next = NULL;
      break;
    }
    pp = &(*pp)->hash_next;
  }
  pthread_mutex_unlock(&stdin_table_lock);
  return found;
}

static void stdin_abort_id(int64_t id) {
  stdin_writer_t *w = stdin_table_take(id);
  if (w == NULL) return;
  pthread_mutex_lock(&w->lock);
  w->aborted = 1;
  stdin_chunk_t *drop = w->head;
  w->head = w->tail = NULL;
  w->queued = 0;
  pthread_cond_signal(&w->cond);
  pthread_mutex_unlock(&w->lock);
  stdin_free_chunks(drop);
  stdin_writer_unref(w);
}

static void *stdin_write_thread(void *arg) {
  stdin_writer_t *w = arg;
  sigset_t pipe_sig;
  sigemptyset(&pipe_sig);
  sigaddset(&pipe_sig, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &pipe_sig, NULL);
  for (;;) {
    pthread_mutex_lock(&w->lock);
    while (!w->aborted && w->head == NULL && !w->eof_requested) {
      pthread_cond_wait(&w->cond, &w->lock);
    }
    if (w->aborted) {
      stdin_chunk_t *drop = w->head;
      w->head = w->tail = NULL;
      w->queued = 0;
      pthread_mutex_unlock(&w->lock);
      stdin_free_chunks(drop);
      break;
    }
    if (w->head != NULL) {
      stdin_chunk_t *ch = w->head;
      w->head = ch->next;
      if (w->head == NULL) w->tail = NULL;
      w->queued -= ch->len;
      int fd = w->fd;
      pthread_mutex_unlock(&w->lock);

      int ok = write_all(fd, ch->data, ch->len);
      free(ch);
      if (!ok) {
        pthread_mutex_lock(&w->lock);
        w->aborted = 1;
        stdin_chunk_t *drop = w->head;
        w->head = w->tail = NULL;
        w->queued = 0;
        pthread_mutex_unlock(&w->lock);
        stdin_free_chunks(drop);
        stdin_writer_t *taken = stdin_table_take(w->id);
        if (taken != NULL) stdin_writer_unref(taken);
        break;
      }
      continue;
    }
    if (w->eof_requested) {
      pthread_mutex_unlock(&w->lock);
      break;
    }
    pthread_mutex_unlock(&w->lock);
  }
  if (w->fd >= 0) {
    close(w->fd);
    w->fd = -1;
  }
  stdin_writer_unref(w);
  return NULL;
}

static int64_t stdin_writer_start(int fd, pid_t pid, int group) {
  stdin_writer_t *w = calloc(1, sizeof *w);
  if (w == NULL) {
    close(fd);
    return -1;
  }
  w->refs = 2; // 1 for table, 1 for writer thread
  w->limit = stdin_limit_bytes();
  w->fd = fd;
  w->pid = pid;
  w->group = group;
  pthread_mutex_init(&w->lock, NULL);
  pthread_cond_init(&w->cond, NULL);

  pthread_mutex_lock(&stdin_table_lock);
  int64_t id = stdin_next_id++;
  if (stdin_next_id <= 0) stdin_next_id = 1;
  w->id = id;
  size_t b = (size_t)((uint64_t)id % STDIN_BUCKETS);
  w->hash_next = stdin_buckets[b];
  stdin_buckets[b] = w;
  pthread_mutex_unlock(&stdin_table_lock);

  if (!start_thread(stdin_write_thread, w)) {
    stdin_writer_t *taken = stdin_table_take(id);
    if (taken != NULL) stdin_writer_unref(taken);
    stdin_writer_unref(w);
    return -1;
  }
  return id;
}

typedef struct {
  int64_t id;
  pid_t pid;
  int64_t stdin_id;
} wait_job_t;

static const char *signal_name(int sig) {
  switch (sig) {
    case SIGHUP: return "SIGHUP";
    case SIGINT: return "SIGINT";
    case SIGQUIT: return "SIGQUIT";
    case SIGILL: return "SIGILL";
    case SIGABRT: return "SIGABRT";
    case SIGBUS: return "SIGBUS";
    case SIGFPE: return "SIGFPE";
    case SIGKILL: return "SIGKILL";
    case SIGSEGV: return "SIGSEGV";
    case SIGPIPE: return "SIGPIPE";
    case SIGALRM: return "SIGALRM";
    case SIGTERM: return "SIGTERM";
    case SIGUSR1: return "SIGUSR1";
    case SIGUSR2: return "SIGUSR2";
    default: return "SIGUNKNOWN";
  }
}

static void *wait_thread(void *arg) {
  wait_job_t *job = arg;
  int status = 0;
  pid_t rc;
  do {
    rc = waitpid(job->pid, &status, 0);
  } while (rc < 0 && errno == EINTR);
  if (job->stdin_id > 0) stdin_abort_id(job->stdin_id);
  char msg[64];
  if (rc < 0) {
    snprintf(msg, sizeof msg, "-1 ");
  } else if (WIFSIGNALED(status)) {
    snprintf(msg, sizeof msg, "- %s", signal_name(WTERMSIG(status)));
  } else {
    snprintf(msg, sizeof msg, "%d ", WEXITSTATUS(status));
  }
  sys_told_text(job->id, 'x', msg);
  free(job);
  return NULL;
}

static char **split_nul(moonbit_bytes_t b, const char *first) {
  int32_t len = Moonbit_array_length(b);
  size_t n = first ? 1 : 0;
  for (int32_t i = 0; i < len; i++) if (b[i] == 0) n++;
  char **out = calloc(n + 1, sizeof(char *));
  size_t k = 0;
  if (first) out[k++] = (char *)first;
  for (int32_t i = 0; i < len;) {
    out[k++] = (char *)b + i;
    i += (int32_t)strlen((const char *)b + i) + 1;
  }
  out[k] = NULL;
  return out;
}

/// `program` as execvp finds it, by the PATH of `envp` (or this process's).
static char *found(const char *program, char **envp) {
  if (strchr(program, '/')) return strdup(program);
  const char *path = NULL;
  if (envp) {
    for (char **e = envp; *e; e++) if (strncmp(*e, "PATH=", 5) == 0) path = *e + 5;
  } else {
    path = getenv("PATH");
  }
  if (!path) path = "/usr/bin:/bin";
  size_t pl = strlen(program);
  while (*path) {
    const char *end = strchr(path, ':');
    size_t dl = end ? (size_t)(end - path) : strlen(path);
    char *full = malloc(dl + pl + 2);
    if (dl == 0) {
      memcpy(full, ".", 1);
      dl = 1;
    } else {
      memcpy(full, path, dl);
    }
    full[dl] = '/';
    memcpy(full + dl + 1, program, pl + 1);
    if (access(full, X_OK) == 0) return full;
    free(full);
    if (!end) break;
    path = end + 1;
  }
  return strdup(program);
}

static int cloexec_pipe(int fds[2]) {
  if (pipe(fds) != 0) return -1;
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);
  return 0;
}

int32_t sfs_spawn(int64_t id, moonbit_bytes_t program, moonbit_bytes_t args, moonbit_bytes_t env, moonbit_bytes_t cwd,
                  int32_t in_mode, int32_t out_mode, int32_t err_mode, moonbit_bytes_t out_file, moonbit_bytes_t err_file,
                  int32_t group, int64_t *out, moonbit_bytes_t why) {
  char **argv = split_nul(args, (const char *)program);
  char **envp = Moonbit_array_length(env) > 0 ? split_nul(env, NULL) : NULL;
  char *path = found((const char *)program, envp);
  const char *dir = Moonbit_array_length(cwd) > 1 ? (const char *)cwd : NULL;
  int in[2] = { -1, -1 }, outp[2] = { -1, -1 }, errp[2] = { -1, -1 }, report[2] = { -1, -1 };
  int fail = 0;
  if (in_mode == 1 && cloexec_pipe(in) != 0) fail = errno;
  if (!fail && out_mode == 1 && cloexec_pipe(outp) != 0) fail = errno;
  if (!fail && err_mode == 1 && cloexec_pipe(errp) != 0) fail = errno;
  if (!fail && cloexec_pipe(report) != 0) fail = errno;
  pid_t pid = -1;
  if (!fail) pid = fork();
  if (pid == 0) {
    // (the child: only what is safe between fork and exec)
    if (group) setpgid(0, 0);
    int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    dup2(in_mode == 1 ? in[0] : null_fd, 0);
    if (out_mode == 1) {
      dup2(outp[1], 1);
    } else if (out_mode == 2) {
      int f = open((const char *)out_file, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
      dup2(f >= 0 ? f : null_fd, 1);
    } else {
      dup2(null_fd, 1);
    }
    if (err_mode == 1) {
      dup2(errp[1], 2);
    } else if (err_mode == 2) {
      int f = open((const char *)err_file, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
      dup2(f >= 0 ? f : null_fd, 2);
    } else {
      dup2(null_fd, 2);
    }
    // (signals ignored here are ignored in the child too: given back their defaults)
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGUSR1, SIG_DFL);
    signal(SIGUSR2, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    if (dir && chdir(dir) != 0) {
      int e = errno;
      if (write(report[1], &e, sizeof e) < 0) {}
      _exit(127);
    }
    if (envp) execve(path, argv, envp); else execv(path, argv);
    int e = errno;
    if (write(report[1], &e, sizeof e) < 0) {}
    _exit(127);
  }
  if (pid < 0 && !fail) fail = errno;
  if (report[1] >= 0) close(report[1]);
  if (!fail) {
    int e = 0;
    ssize_t n;
    do {
      n = read(report[0], &e, sizeof e);
    } while (n < 0 && errno == EINTR);
    if (n == (ssize_t)sizeof e) {
      fail = e;
      int status;
      waitpid(pid, &status, 0);
    }
  }
  if (report[0] >= 0) close(report[0]);
  if (in[0] >= 0) close(in[0]);
  if (outp[1] >= 0) close(outp[1]);
  if (errp[1] >= 0) close(errp[1]);
  free(path);
  free(argv);
  free(envp);
  if (fail) {
    if (in[1] >= 0) close(in[1]);
    if (outp[0] >= 0) close(outp[0]);
    if (errp[0] >= 0) close(errp[0]);
    char msg[256];
    snprintf(msg, sizeof msg, "%s %s", fail == ENOENT ? "ENOENT" : fail == EACCES ? "EACCES" : "EIO", strerror(fail));
    size_t n = strlen(msg);
    int32_t room = Moonbit_array_length(why);
    if ((int32_t)n > room) n = (size_t)room;
    memcpy(why, msg, n);
    out[0] = (int64_t)n;
    return -1;
  }
  int64_t stdin_id = -1;
  if (in[1] >= 0) {
    stdin_id = stdin_writer_start(in[1], pid, group != 0);
  }
  out[1] = stdin_id;
  if (outp[0] >= 0 || errp[0] >= 0) {
    pipes_job_t *job = malloc(sizeof *job);
    job->id = id;
    job->fds[0] = outp[0];
    job->fds[1] = errp[0];
    start_thread(pipes_thread, job);
  }
  wait_job_t *wj = malloc(sizeof *wj);
  wj->id = id;
  wj->pid = pid;
  wj->stdin_id = stdin_id > 0 ? stdin_id : 0;
  start_thread(wait_thread, wj);
  return (int32_t)pid;
}

int32_t sfs_handle_write(int64_t handle, moonbit_bytes_t b) {
  stdin_writer_t *w = stdin_table_get(handle);
  if (w == NULL) return 0;
  size_t len = (size_t)Moonbit_array_length(b);
  pthread_mutex_lock(&w->lock);
  if (w->eof_requested || w->aborted) {
    pthread_mutex_unlock(&w->lock);
    stdin_writer_unref(w);
    return 0;
  }
  if (len == 0) {
    pthread_mutex_unlock(&w->lock);
    stdin_writer_unref(w);
    return 1;
  }
  if (len > w->limit || w->queued > w->limit - len) {
    w->aborted = 1;
    stdin_chunk_t *drop = w->head;
    w->head = w->tail = NULL;
    w->queued = 0;
    pthread_cond_signal(&w->cond);
    pthread_mutex_unlock(&w->lock);
    stdin_free_chunks(drop);
    stdin_writer_t *taken = stdin_table_take(handle);
    if (taken != NULL) stdin_writer_unref(taken);
    kill(w->group ? -w->pid : w->pid, SIGKILL);
    stdin_writer_unref(w);
    return 0;
  }
  stdin_chunk_t *ch = malloc(sizeof *ch + len);
  if (ch == NULL) {
    pthread_mutex_unlock(&w->lock);
    stdin_writer_unref(w);
    return 0;
  }
  ch->next = NULL;
  ch->len = len;
  memcpy(ch->data, b, len);
  if (w->tail != NULL) w->tail->next = ch;
  else w->head = ch;
  w->tail = ch;
  w->queued += len;
  pthread_cond_signal(&w->cond);
  pthread_mutex_unlock(&w->lock);
  stdin_writer_unref(w);
  return 1;
}

int32_t sfs_handle_close(int64_t handle) {
  stdin_writer_t *w = stdin_table_take(handle);
  if (w == NULL) return 0;
  pthread_mutex_lock(&w->lock);
  w->eof_requested = 1;
  pthread_cond_signal(&w->cond);
  pthread_mutex_unlock(&w->lock);
  stdin_writer_unref(w);
  return 1;
}

// ── control lines and signals ──

typedef struct {
  int64_t id;
  int fd;
} lines_job_t;

static void *lines_thread(void *arg) {
  lines_job_t *job = arg;
  sbuf_t line = {0};
  char buf[4096];
  for (;;) {
    ssize_t n = read(job->fd, buf, sizeof buf);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    for (ssize_t i = 0; i < n; i++) {
      if (buf[i] == '\n') {
        sys_told(job->id, 'l', line.data ? line.data : "", line.len);
        line.len = 0;
      } else {
        sb_add(&line, buf + i, 1);
      }
    }
  }
  if (line.len) sys_told(job->id, 'l', line.data, line.len);
  free(line.data);
  sys_told(job->id, 'z', "", 0);
  free(job);
  return NULL;
}

void sfs_read_lines(int64_t id, int32_t fd) {
  lines_job_t *job = malloc(sizeof *job);
  job->id = id;
  job->fd = fd;
  start_thread(lines_thread, job);
}

static int signal_pipe[2] = { -1, -1 };

static void on_signal(int sig) {
  int e = errno;
  unsigned char s = (unsigned char)sig;
  if (write(signal_pipe[1], &s, 1) < 0) {}
  errno = e;
}

static void *signals_thread(void *arg) {
  int64_t id = *(int64_t *)arg;
  free(arg);
  for (;;) {
    unsigned char s;
    ssize_t n = read(signal_pipe[0], &s, 1);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    sys_told_text(id, 's', signal_name(s));
  }
  return NULL;
}

void sfs_signals(int64_t id, int32_t ignore) {
  int sigs[5] = { SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2 };
  if (ignore) {
    for (int i = 0; i < 5; i++) signal(sigs[i], SIG_IGN);
    return;
  }
  if (signal_pipe[0] < 0) {
    if (cloexec_pipe(signal_pipe) != 0) return;
    int64_t *arg = malloc(sizeof *arg);
    *arg = id;
    start_thread(signals_thread, arg);
  }
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  for (int i = 0; i < 5; i++) sigaction(sigs[i], &sa, NULL);
}
#endif
