// Generic one-click per-user Windows installer for mbui apps: puts the app in %LOCALAPPDATA%\Programs\<DIR> with no
// administrator prompt. Also invoked by the app's own updater (win_update.h: `/S --updated --force-run`).
//
// What it carries: the app's files and configuration (`setup.env`: APP_NAME, APP_ID, EXE, DIR, VERSION, and optional
// PUBLISHER, SCHEMES), packed after the executable (`--pack`, LZMS via Windows' Compression API). Its raw form
// (`--raw`) is the same executable with the same files stored uncompressed (MAGIC_RAW), used as the deterministic base
// for binary delta updates (win_update.h, update_delta.h).
//
//   setup.exe [/S] [--updated] [--force-run] [/D=<dir>]   installs (/S: no window; --force-run: launch app after,
//                                                          which also happens without /S)
//   setup.exe --uninstall [/S]                             removes the installed files, shortcuts, registry entries,
//                                                          and URL schemes (user data is kept); runs from a copy in
//                                                          %TEMP% (`--uninstall-from <dir> [--after <pid>]`)
//   setup.exe --pack OUT ENV FILE...                       packs ENV (as setup.env) and FILEs after this executable
//   setup.exe --raw OUT                                    rewrites this installer with its payload stored raw
//
// Log output goes to stdout (when attached to a console) and %TEMP%\<DIR>-setup.log.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <commctrl.h>
#include <compressapi.h>
#include <objbase.h>
#include <propsys.h>
#include <restartmanager.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <tlhelp32.h>
#include <userenv.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "cabinet.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "propsys.lib")
#pragma comment(lib, "rstrtmgr.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(linker, "/SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup")
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

static const char MAGIC[8] = {'M', 'B', 'S', 'E', 'T', 'U', 'P', '1'};      // packed payload (LZMS)
static const char MAGIC_RAW[8] = {'M', 'B', 'S', 'E', 'T', 'U', 'P', '0'};  // stored payload (--raw)

// whether 8 bytes are a payload's mark: 1 packed, 2 stored, 0 neither
static int payload_mark(const unsigned char *b) {
  return !memcmp(b, MAGIC, 8) ? 1 : !memcmp(b, MAGIC_RAW, 8) ? 2 : 0;
}

// System.AppUserModel.ID
static const PROPERTYKEY app_id_key = {{0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 5};

// ---- logging ----

static FILE *log_file;
static void say(const wchar_t *fmt, ...) {
  wchar_t b[2048];
  va_list a;
  va_start(a, fmt);
  _vsnwprintf(b, 2048, fmt, a);
  va_end(a);
  b[2047] = 0;
  char u[6144];
  WideCharToMultiByte(CP_UTF8, 0, b, -1, u, sizeof u, NULL, NULL);
  fprintf(stdout, "setup: %s\n", u);
  fflush(stdout);
  if (log_file) fprintf(log_file, "%s\n", u), fflush(log_file);
}

// ---- payload ----

typedef struct {
  wchar_t name[MAX_PATH];
  unsigned char *data;
  size_t size;
} entry;

static entry *entries;
static int nentries;
static wchar_t env_text[4096];  // setup.env's lines

// NAME's value in setup.env, "" if absent
static void env_get(const wchar_t *name, wchar_t *out, size_t cap) {
  out[0] = 0;
  size_t k = wcslen(name);
  for (const wchar_t *l = env_text; *l;) {
    const wchar_t *end = wcschr(l, L'\n');
    size_t n = end ? (size_t)(end - l) : wcslen(l);
    if (n > k && !wcsncmp(l, name, k) && l[k] == L'=') {
      size_t v = n - k - 1;
      if (v >= cap) v = cap - 1;
      wcsncpy_s(out, cap, l + k + 1, v);
      while (v > 0 && (out[v - 1] == L'\r' || out[v - 1] == L' ')) out[--v] = 0;
      return;
    }
    l += n + (end ? 1 : 0);
  }
}

static unsigned char *read_all(const wchar_t *path, size_t *n) {
  HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if (f == INVALID_HANDLE_VALUE) return NULL;
  LARGE_INTEGER size;
  GetFileSizeEx(f, &size);
  unsigned char *b = (unsigned char *)malloc((size_t)size.QuadPart + 1);
  size_t got = 0;
  while (b && got < (size_t)size.QuadPart) {
    DWORD k = 0;
    if (!ReadFile(f, b + got, (DWORD)((size_t)size.QuadPart - got > (1u << 30) ? (1u << 30) : (size_t)size.QuadPart - got), &k, NULL) || !k)
      break;
    got += k;
  }
  CloseHandle(f);
  if (!b || got != (size_t)size.QuadPart) {
    free(b);
    return NULL;
  }
  *n = got;
  return b;
}

static int write_all(const wchar_t *path, const void *b, size_t n) {
  HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  size_t put = 0;
  while (put < n) {
    DWORD k = 0;
    if (!WriteFile(f, (const char *)b + put, (DWORD)(n - put > (1u << 30) ? (1u << 30) : n - put), &k, NULL) || !k) break;
    put += k;
  }
  CloseHandle(f);
  return put == n;
}

// Payload format appended after the executable stub:
//   MAGIC (8B) | count (u32) | [name_len (u16) | name (UTF-16LE) | raw_size (u64) | stored_size (u64) | bytes]...
//   | payload_offset (u64) | MAGIC (8B)
// Raw form uses MAGIC_RAW at both ends with stored_size == raw_size and uncompressed bytes.
// *stub receives the offset where the executable stub ends. Returns 1 on success.
static int payload_read(size_t *stub) {
  wchar_t self[MAX_PATH * 2];
  GetModuleFileNameW(NULL, self, MAX_PATH * 2);
  size_t n = 0;
  unsigned char *b = read_all(self, &n);
  int kind = b && n >= 16 ? payload_mark(b + n - 8) : 0;
  if (!kind) {
    free(b);
    return 0;
  }
  uint64_t at;
  memcpy(&at, b + n - 16, 8);
  *stub = (size_t)at;
  if (at > n - 16 || n - 16 - at < 12 || payload_mark(b + at) != kind) {
    free(b);
    return 0;
  }
  size_t p = (size_t)at + 8, end = n - 16;
  uint32_t count;
  memcpy(&count, b + p, 4);
  p += 4;
  DECOMPRESSOR_HANDLE d = NULL;
  if (kind == 1 && !CreateDecompressor(COMPRESS_ALGORITHM_LZMS, NULL, &d)) {
    free(b);
    return 0;
  }
  entries = (entry *)calloc(count ? count : 1, sizeof(entry));
  int ok = entries != NULL;
  for (uint32_t i = 0; ok && i < count; i++) {
    uint16_t nl;
    uint64_t size, packed;
    if (end - p < 2) {
      ok = 0;
      break;
    }
    memcpy(&nl, b + p, 2);
    p += 2;
    if (nl >= MAX_PATH || end - p < (size_t)nl * 2 + 16) {
      ok = 0;
      break;
    }
    memcpy(entries[i].name, b + p, (size_t)nl * 2);
    entries[i].name[nl] = 0;
    p += (size_t)nl * 2;
    memcpy(&size, b + p, 8);
    memcpy(&packed, b + p + 8, 8);
    p += 16;
    if (packed > end - p || (kind == 2 && packed != size)) {
      ok = 0;
      break;
    }
    entries[i].data = (unsigned char *)malloc(size ? (size_t)size : 1);
    SIZE_T got = 0;
    if (kind == 2) {
      if (entries[i].data && size) memcpy(entries[i].data, b + p, (size_t)size);
      ok = entries[i].data != NULL;
    } else {
      ok = entries[i].data && (size == 0 || (Decompress(d, b + p, (SIZE_T)packed, entries[i].data, (SIZE_T)size, &got) && got == size));
    }
    entries[i].size = (size_t)size;
    p += (size_t)packed;
    nentries++;
  }
  if (d) CloseDecompressor(d);
  free(b);
  for (int i = 0; i < nentries; i++)
    if (!wcscmp(entries[i].name, L"setup.env")) {
      int w = MultiByteToWideChar(CP_UTF8, 0, (const char *)entries[i].data, (int)entries[i].size, env_text, 4095);
      env_text[w > 0 ? w : 0] = 0;
    }
  return ok;
}

static int put_all(HANDLE out, const void *p, size_t n) {
  const unsigned char *at = (const unsigned char *)p;
  while (n > 0) {
    DWORD k = 0;
    if (!WriteFile(out, at, (DWORD)(n > (1u << 30) ? (1u << 30) : n), &k, NULL) || !k) return 0;
    at += k, n -= k;
  }
  return 1;
}

static int write_payload(const wchar_t *to, const unsigned char *stub, size_t sn, const char *magic_, uint32_t count,
                         const wchar_t *const *names, const size_t *sizes, const size_t *stored,
                         const unsigned char *const *bytes) {
  HANDLE out = CreateFileW(to, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (out == INVALID_HANDLE_VALUE) return 0;
  uint64_t at = sn;
  int ok = put_all(out, stub, sn) && put_all(out, magic_, 8) && put_all(out, &count, 4);
  for (uint32_t i = 0; ok && i < count; i++) {
    uint16_t nl = (uint16_t)wcslen(names[i]);
    uint64_t size = sizes[i], pk = stored[i];
    ok = put_all(out, &nl, 2) && put_all(out, names[i], (size_t)nl * 2) && put_all(out, &size, 8) && put_all(out, &pk, 8) &&
         put_all(out, bytes[i], stored[i]);
  }
  ok = ok && put_all(out, &at, 8) && put_all(out, magic_, 8);
  CloseHandle(out);
  if (!ok) DeleteFileW(to);
  return ok;
}

// Parallel per-file LZMS compression (largest files first, up to 8 threads).
typedef struct {
  const wchar_t *name;
  unsigned char *b, *z;
  size_t n;
  SIZE_T packed;
  DWORD err;
} pack_item;

typedef struct {
  pack_item *items;
  int *order;
  LONG next;
  int count;
} pack_work;

static DWORD WINAPI pack_thread(void *arg) {
  pack_work *w = (pack_work *)arg;
  COMPRESSOR_HANDLE c = NULL;
  DWORD no_c = CreateCompressor(COMPRESS_ALGORITHM_LZMS, NULL, &c) ? 0 : GetLastError();
  if (no_c) c = NULL;
  for (;;) {
    LONG i = InterlockedIncrement(&w->next) - 1;
    if (i >= w->count) break;
    pack_item *it = &w->items[w->order[i]];
    SIZE_T cap = it->n + it->n / 2 + 65536;
    it->z = (unsigned char *)malloc(cap);
    if (!c) it->err = no_c ? no_c : ERROR_INVALID_HANDLE;
    else if (!it->z) it->err = ERROR_NOT_ENOUGH_MEMORY;
    else if (it->n && !Compress(c, it->b, it->n, it->z, cap, &it->packed)) it->err = GetLastError() ? GetLastError() : ERROR_GEN_FAILURE;
  }
  if (c) CloseCompressor(c);
  return 0;
}

// --pack OUT ENV FILE...: packs ENV (as setup.env) and FILEs after this executable.
// If MBUI_SETUP_RAW is set to a path, also writes the uncompressed raw form there.
static int pack(int argc, wchar_t **argv) {
  if (argc < 4) return 2;
  wchar_t self[MAX_PATH * 2];
  GetModuleFileNameW(NULL, self, MAX_PATH * 2);
  size_t sn = 0;
  unsigned char *me = read_all(self, &sn);
  if (!me) return 1;
  if (sn >= 16 && payload_mark(me + sn - 8)) memcpy(&sn, me + sn - 16, 8);
  int count = argc - 3, rc = 1;
  pack_item *items = (pack_item *)calloc((size_t)count, sizeof(pack_item));
  int *order = (int *)calloc((size_t)count, sizeof(int));
  const wchar_t **names = (const wchar_t **)calloc((size_t)count, sizeof(wchar_t *));
  size_t *sizes = (size_t *)calloc((size_t)count, sizeof(size_t)), *stored = (size_t *)calloc((size_t)count, sizeof(size_t));
  const unsigned char **bytes = (const unsigned char **)calloc((size_t)count, sizeof(unsigned char *));
  HANDLE threads[8];
  int nthreads = 0;
  if (!items || !order || !names || !sizes || !stored || !bytes) goto done;
  for (int i = 0; i < count; i++) {
    const wchar_t *path = argv[i + 3];
    items[i].b = read_all(path, &items[i].n);
    if (!items[i].b) {
      say(L"no %ls", path);
      goto done;
    }
    const wchar_t *name = i == 0 ? L"setup.env" : wcsrchr(path, L'\\') ? wcsrchr(path, L'\\') + 1 : path;
    if (wcsrchr(name, L'/')) name = wcsrchr(name, L'/') + 1;
    items[i].name = name;
    int j = i;
    while (j > 0 && items[order[j - 1]].n < items[i].n) order[j] = order[j - 1], j--;
    order[j] = i;
  }
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  int want = (int)si.dwNumberOfProcessors;
  if (want > 8) want = 8;
  if (want > count) want = count;
  if (want < 1) want = 1;
  pack_work work = {items, order, 0, count};
  for (; nthreads < want; nthreads++) {
    threads[nthreads] = CreateThread(NULL, 0, pack_thread, &work, 0, NULL);
    if (!threads[nthreads]) break;
  }
  if (nthreads == 0) pack_thread(&work);
  else WaitForMultipleObjects((DWORD)nthreads, threads, TRUE, INFINITE);
  for (int t = 0; t < nthreads; t++) CloseHandle(threads[t]);
  for (int i = 0; i < count; i++)
    if (items[i].err) {
      say(L"%ls not packed (%lu)", items[i].name, items[i].err);
      goto done;
    }
  for (int i = 0; i < count; i++) {
    names[i] = items[i].name, sizes[i] = items[i].n, stored[i] = items[i].packed, bytes[i] = items[i].z;
    say(L"packed %ls: %zu bytes as %zu", items[i].name, items[i].n, (size_t)items[i].packed);
  }
  if (!write_payload(argv[2], me, sn, MAGIC, (uint32_t)count, names, sizes, stored, bytes)) {
    say(L"%ls not written (%lu)", argv[2], GetLastError());
    goto done;
  }
  wchar_t raw_to[MAX_PATH * 2];
  DWORD rl = GetEnvironmentVariableW(L"MBUI_SETUP_RAW", raw_to, MAX_PATH * 2);
  if (rl > 0 && rl < MAX_PATH * 2) {
    for (int i = 0; i < count; i++) stored[i] = items[i].n, bytes[i] = items[i].b;
    if (!write_payload(raw_to, me, sn, MAGIC_RAW, (uint32_t)count, names, sizes, stored, bytes)) {
      say(L"%ls not written (%lu)", raw_to, GetLastError());
      goto done;
    }
    say(L"%ls: %d files stored", raw_to, count);
  } else if (rl >= MAX_PATH * 2) {
    say(L"MBUI_SETUP_RAW is too long");
    goto done;
  }
  rc = 0;
done:
  if (items)
    for (int i = 0; i < count; i++) free(items[i].b), free(items[i].z);
  free(items), free(order), free((void *)names), free(sizes), free(stored), free((void *)bytes), free(me);
  return rc;
}

// --raw OUT: rewrites this installer with its payload stored uncompressed (MAGIC_RAW).
static int raw(const wchar_t *to) {
  size_t stub = 0, sn = 0;
  if (!payload_read(&stub)) {
    say(L"this installer is damaged");
    return 1;
  }
  wchar_t self[MAX_PATH * 2];
  GetModuleFileNameW(NULL, self, MAX_PATH * 2);
  unsigned char *me = read_all(self, &sn);
  if (!me || stub > sn) {
    free(me);
    return 1;
  }
  int n = nentries ? nentries : 1;
  const wchar_t **names = (const wchar_t **)calloc((size_t)n, sizeof(wchar_t *));
  size_t *sizes = (size_t *)calloc((size_t)n, sizeof(size_t));
  const unsigned char **bytes = (const unsigned char **)calloc((size_t)n, sizeof(unsigned char *));
  int ok = names && sizes && bytes;
  for (int i = 0; ok && i < nentries; i++) names[i] = entries[i].name, sizes[i] = entries[i].size, bytes[i] = entries[i].data;
  ok = ok && write_payload(to, me, stub, MAGIC_RAW, (uint32_t)nentries, names, sizes, sizes, bytes);
  free(me), free((void *)names), free(sizes), free((void *)bytes);
  if (!ok) {
    say(L"%ls not written (%lu)", to, GetLastError());
    return 1;
  }
  say(L"%ls: %d files stored", to, nentries);
  return 0;
}

// ---- installation state ----

static wchar_t app_name[128], app_id[128], exe_name[128], dir_name[128], version[64], publisher[128], schemes_env[256];
static wchar_t install_dir[MAX_PATH];

// Finds an existing Uninstall registry key pointing at `dir`, or "" if none.
static void uninstall_key_of(const wchar_t *dir, wchar_t *out, size_t cap) {
  out[0] = 0;
  HKEY root;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", 0, KEY_READ, &root) != ERROR_SUCCESS)
    return;
  wchar_t name[256];
  for (DWORD i = 0;; i++) {
    DWORD n = 256;
    if (RegEnumKeyExW(root, i, name, &n, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
    wchar_t where[MAX_PATH * 2] = L"", uninstall[MAX_PATH * 2] = L"";
    DWORD wn = sizeof where, un = sizeof uninstall;
    RegGetValueW(root, name, L"InstallLocation", RRF_RT_REG_SZ, NULL, where, &wn);
    RegGetValueW(root, name, L"UninstallString", RRF_RT_REG_SZ, NULL, uninstall, &un);
    size_t dn = wcslen(dir);
    if ((where[0] && !_wcsicmp(where, dir)) || (uninstall[0] && _wcsnicmp(uninstall + (uninstall[0] == L'"'), dir, dn) == 0)) {
      lstrcpynW(out, name, (int)cap);
      break;
    }
  }
  RegCloseKey(root);
}

// Stops any running processes whose executable lives inside `dir`.
static void end_running(const wchar_t *dir) {
  size_t dn = wcslen(dir);
  for (int round = 0; round < 2; round++) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe = {sizeof pe};
    HANDLE waiting[64];
    int nw = 0;
    for (BOOL more = Process32FirstW(snap, &pe); more; more = Process32NextW(snap, &pe)) {
      if (pe.th32ProcessID == GetCurrentProcessId()) continue;
      HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
      if (!h) continue;
      wchar_t path[MAX_PATH * 2];
      DWORD n = MAX_PATH * 2;
      if (QueryFullProcessImageNameW(h, 0, path, &n) && !_wcsnicmp(path, dir, dn) && path[dn] == L'\\' && nw < 64) {
        if (round == 0) {
          say(L"%ls runs: asked to end", path);
          waiting[nw++] = h;
          continue;
        }
        say(L"%ls still runs: ended", path);
        TerminateProcess(h, 1);
        WaitForSingleObject(h, 5000);
      }
      CloseHandle(h);
    }
    CloseHandle(snap);
    if (round == 0) {
      for (int i = 0; i < nw; i++) {
        if (WaitForSingleObject(waiting[i], 15000) != WAIT_OBJECT_0) TerminateProcess(waiting[i], 1), WaitForSingleObject(waiting[i], 5000);
        CloseHandle(waiting[i]);
      }
      if (nw == 0) return;
    }
  }
}

// Finds the first file under `dir` held open by another process; returns 0 when none is held.
static int held_file(const wchar_t *dir, wchar_t *held, size_t cap) {
  wchar_t glob[MAX_PATH * 2];
  _snwprintf(glob, MAX_PATH * 2, L"%ls\\*", dir);
  WIN32_FIND_DATAW e;
  HANDLE h = FindFirstFileW(glob, &e);
  if (h == INVALID_HANDLE_VALUE) return 0;
  int found = 0;
  do {
    if (!wcscmp(e.cFileName, L".") || !wcscmp(e.cFileName, L"..")) continue;
    wchar_t p[MAX_PATH * 2];
    _snwprintf(p, MAX_PATH * 2, L"%ls\\%ls", dir, e.cFileName);
    if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      if (!(e.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) found = held_file(p, held, cap);
      continue;
    }
    HANDLE f = CreateFileW(p, DELETE, 0, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (f != INVALID_HANDLE_VALUE) {
      CloseHandle(f);
    } else if (GetLastError() == ERROR_SHARING_VIOLATION || GetLastError() == ERROR_ACCESS_DENIED) {
      lstrcpynW(held, p, (int)cap);
      found = 1;
    }
  } while (!found && FindNextFileW(h, &e));
  FindClose(h);
  return found;
}

// Uses Windows Restart Manager to find processes holding `path`.
static int holders(const wchar_t *path, HANDLE *out, int cap) {
  DWORD session = 0;
  WCHAR key[CCH_RM_SESSION_KEY + 1] = {0};
  if (RmStartSession(&session, 0, key) != ERROR_SUCCESS) return 0;
  int n = 0;
  LPCWSTR files[1] = {path};
  UINT need = 0, have = 16;
  RM_PROCESS_INFO info[16];
  DWORD why = 0;
  if (RmRegisterResources(session, 1, files, 0, NULL, 0, NULL) == ERROR_SUCCESS &&
      (RmGetList(session, &need, &have, info, &why) == ERROR_SUCCESS || have > 0)) {
    for (UINT i = 0; i < have && n < cap; i++) {
      HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE, FALSE,
                             info[i].Process.dwProcessId);
      if (!h) h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, info[i].Process.dwProcessId);
      if (h) out[n++] = h;
    }
  }
  RmEndSession(session);
  return n;
}

// Ends running processes from `dir` and waits up to 30 s for any locked files to be released.
static void let_go(const wchar_t *dir) {
  end_running(dir);
  size_t dn = wcslen(dir);
  wchar_t held[MAX_PATH * 2], last[MAX_PATH * 2] = L"";
  for (ULONGLONG t0 = GetTickCount64(); held_file(dir, held, MAX_PATH * 2);) {
    ULONGLONG spent = GetTickCount64() - t0;
    if (spent >= 30000) {
      say(L"%ls still held after %llu ms", held, spent);
      return;
    }
    HANDLE hs[16];
    int n = holders(held, hs, 16);
    if (wcscmp(held, last) != 0) say(L"%ls held by %d (%llu ms)", held, n, spent);
    lstrcpynW(last, held, MAX_PATH * 2);
    for (int i = 0; i < n; i++) {
      wchar_t path[MAX_PATH * 2];
      DWORD pn = MAX_PATH * 2;
      if (QueryFullProcessImageNameW(hs[i], 0, path, &pn) && !_wcsnicmp(path, dir, dn) && path[dn] == L'\\') {
        say(L"%ls holds it: ended", path);
        TerminateProcess(hs[i], 1);
      }
    }
    if (n > 0) WaitForMultipleObjects((DWORD)n, hs, FALSE, 500);
    else Sleep(100);
    for (int i = 0; i < n; i++) CloseHandle(hs[i]);
  }
}

// Removes `dir` and its contents recursively. Returns 1 when removed.
static int remove_tree(const wchar_t *dir) {
  wchar_t glob[MAX_PATH * 2];
  _snwprintf(glob, MAX_PATH * 2, L"%ls\\*", dir);
  WIN32_FIND_DATAW e;
  HANDLE h = FindFirstFileW(glob, &e);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      if (!wcscmp(e.cFileName, L".") || !wcscmp(e.cFileName, L"..")) continue;
      wchar_t p[MAX_PATH * 2];
      _snwprintf(p, MAX_PATH * 2, L"%ls\\%ls", dir, e.cFileName);
      if (e.dwFileAttributes & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(p, e.dwFileAttributes & ~FILE_ATTRIBUTE_READONLY);
      if ((e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(e.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) remove_tree(p);
      else if (e.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) RemoveDirectoryW(p);
      else DeleteFileW(p);
    } while (FindNextFileW(h, &e));
    FindClose(h);
  }
  return RemoveDirectoryW(dir) || GetFileAttributesW(dir) == INVALID_FILE_ATTRIBUTES;
}

// Creates a .lnk shortcut at `lnk` targeting `target`, attaching AppUserModelID when `app_id` is set.
static int shortcut(const wchar_t *lnk, const wchar_t *target) {
  IShellLinkW *sl = NULL;
  if (FAILED(CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&sl))) return 0;
  IShellLinkW_SetPath(sl, target);
  IShellLinkW_SetWorkingDirectory(sl, install_dir);
  IShellLinkW_SetIconLocation(sl, target, 0);
  if (app_id[0]) {
    IPropertyStore *ps = NULL;
    if (SUCCEEDED(IShellLinkW_QueryInterface(sl, &IID_IPropertyStore, (void **)&ps))) {
      PROPVARIANT v;
      PropVariantInit(&v);
      size_t n = (wcslen(app_id) + 1) * sizeof(wchar_t);
      v.vt = VT_LPWSTR;
      v.pwszVal = (LPWSTR)CoTaskMemAlloc(n);
      if (v.pwszVal) {
        memcpy(v.pwszVal, app_id, n);
        IPropertyStore_SetValue(ps, &app_id_key, &v);
        IPropertyStore_Commit(ps);
      }
      PropVariantClear(&v);
      IPropertyStore_Release(ps);
    }
  }
  IPersistFile *pf = NULL;
  int ok = SUCCEEDED(IShellLinkW_QueryInterface(sl, &IID_IPersistFile, (void **)&pf)) && SUCCEEDED(IPersistFile_Save(pf, lnk, TRUE));
  if (pf) IPersistFile_Release(pf);
  IShellLinkW_Release(sl);
  return ok;
}

static void known(REFKNOWNFOLDERID id, wchar_t *out) {
  PWSTR p = NULL;
  out[0] = 0;
  if (SUCCEEDED(SHGetKnownFolderPath(id, 0, NULL, &p))) lstrcpynW(out, p, MAX_PATH);
  CoTaskMemFree(p);
}

static void reg_str(HKEY k, const wchar_t *name, const wchar_t *v) {
  RegSetValueExW(k, name, 0, REG_SZ, (const BYTE *)v, (DWORD)((wcslen(v) + 1) * sizeof(wchar_t)));
}

static wchar_t *trim_ws(wchar_t *s) {
  while (*s == L' ' || *s == L'\t') s++;
  size_t n = wcslen(s);
  while (n > 0 && (s[n - 1] == L' ' || s[n - 1] == L'\t')) s[--n] = 0;
  return s;
}

// Registers comma-separated URL schemes under HKCU\Software\Classes\<scheme>.
static void register_schemes(const wchar_t *schemes_raw, const wchar_t *exe) {
  if (!schemes_raw[0]) return;
  wchar_t buf[256];
  lstrcpynW(buf, schemes_raw, 256);
  for (wchar_t *p = buf, *next = NULL, *t = wcstok_s(p, L",", &next); t; t = wcstok_s(NULL, L",", &next)) {
    t = trim_ws(t);
    if (!t[0]) continue;
    wchar_t sub[400], val[MAX_PATH * 3];
    HKEY k;
    _snwprintf(sub, 400, L"Software\\Classes\\%ls", t);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) == ERROR_SUCCESS) {
      _snwprintf(val, MAX_PATH * 3, L"URL:%ls Protocol", app_name);
      reg_str(k, NULL, val);
      reg_str(k, L"URL Protocol", L"");
      RegCloseKey(k);
    }
    _snwprintf(sub, 400, L"Software\\Classes\\%ls\\DefaultIcon", t);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) == ERROR_SUCCESS) {
      _snwprintf(val, MAX_PATH * 3, L"\"%ls\",0", exe);
      reg_str(k, NULL, val);
      RegCloseKey(k);
    }
    _snwprintf(sub, 400, L"Software\\Classes\\%ls\\shell\\open\\command", t);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) == ERROR_SUCCESS) {
      _snwprintf(val, MAX_PATH * 3, L"\"%ls\" \"%%1\"", exe);
      reg_str(k, NULL, val);
      RegCloseKey(k);
    }
  }
}

// ---- progress window (omitted with /S) ----

static HWND shown;
static DWORD WINAPI window_thread(void *arg) {
  (void)arg;
  INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_PROGRESS_CLASS};
  InitCommonControlsEx(&icc);
  int zh = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
  wchar_t words[256];
  _snwprintf(words, 256, zh ? L"正在安装 %ls…" : L"Installing %ls…", app_name);
  int dpi = (int)GetDpiForSystem();
  int w = MulDiv(360, dpi, 96), h = MulDiv(120, dpi, 96);
  shown = CreateWindowExW(WS_EX_TOPMOST, L"STATIC", app_name, WS_POPUPWINDOW | WS_CAPTION | WS_VISIBLE,
                          (GetSystemMetrics(SM_CXSCREEN) - w) / 2, (GetSystemMetrics(SM_CYSCREEN) - h) / 2, w, h, NULL, NULL,
                          GetModuleHandleW(NULL), NULL);
  RECT rc;
  GetClientRect(shown, &rc);
  int pad = MulDiv(16, dpi, 96);
  CreateWindowExW(0, L"STATIC", words, WS_CHILD | WS_VISIBLE, pad, pad, rc.right - 2 * pad, MulDiv(20, dpi, 96), shown, NULL,
                  NULL, NULL);
  HWND bar = CreateWindowExW(0, PROGRESS_CLASSW, NULL, WS_CHILD | WS_VISIBLE | PBS_MARQUEE, pad, pad + MulDiv(30, dpi, 96),
                             rc.right - 2 * pad, MulDiv(14, dpi, 96), shown, NULL, NULL, NULL);
  SendMessageW(bar, PBM_SETMARQUEE, TRUE, 30);
  MSG m;
  while (GetMessageW(&m, NULL, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  return 0;
}

// ---- installing ----

static int install(int silent, int run_after, const wchar_t *dir_given) {
  wchar_t local[MAX_PATH], key[256], path[MAX_PATH * 2];
  if (dir_given) {
    lstrcpynW(install_dir, dir_given, MAX_PATH);
  } else {
    known(&FOLDERID_LocalAppData, local);
    _snwprintf(install_dir, MAX_PATH, L"%ls\\Programs\\%ls", local, dir_name);
  }
  int fresh = GetFileAttributesW(install_dir) == INVALID_FILE_ATTRIBUTES;
  say(L"%ls %ls into %ls (%ls)", app_name, version, install_dir, fresh ? L"first" : L"over what is there");
  if (!silent) CloseHandle(CreateThread(NULL, 0, window_thread, NULL, 0, NULL));
  if (!fresh) let_go(install_dir);
  wchar_t next[MAX_PATH], old[MAX_PATH];
  _snwprintf(next, MAX_PATH, L"%ls.new", install_dir);
  _snwprintf(old, MAX_PATH, L"%ls.old", install_dir);
  remove_tree(next);
  remove_tree(old);
  SHCreateDirectoryExW(NULL, next, NULL);
  for (int i = 0; i < nentries; i++) {
    _snwprintf(path, MAX_PATH * 2, L"%ls\\%ls", next, entries[i].name);
    if (!write_all(path, entries[i].data, entries[i].size)) {
      say(L"%ls not written (%lu)", path, GetLastError());
      return 1;
    }
  }
  // Uninstaller: this executable stub without the attached payload.
  wchar_t uninstaller[MAX_PATH * 2], self[MAX_PATH * 2];
  GetModuleFileNameW(NULL, self, MAX_PATH * 2);
  _snwprintf(uninstaller, MAX_PATH * 2, L"%ls\\Uninstall %ls.exe", next, app_name);
  size_t sn = 0, stub = 0;
  unsigned char *me = read_all(self, &sn);
  if (me && sn >= 16 && payload_mark(me + sn - 8)) memcpy(&stub, me + sn - 16, 8);
  if (me) write_all(uninstaller, me, stub ? stub : sn);
  free(me);
  int swapped = 0;
  if (fresh) {
    swapped = MoveFileExW(next, install_dir, 0);
  } else if (MoveFileExW(install_dir, old, 0)) {
    swapped = MoveFileExW(next, install_dir, 0);
    if (!swapped) MoveFileExW(old, install_dir, 0);
  }
  if (!swapped) {
    say(L"the old one not put aside (%lu): written over", GetLastError());
    SHCreateDirectoryExW(NULL, install_dir, NULL);
    for (int i = 0; i < nentries; i++) {
      _snwprintf(path, MAX_PATH * 2, L"%ls\\%ls", install_dir, entries[i].name);
      if (!write_all(path, entries[i].data, entries[i].size)) {
        say(L"%ls not written (%lu)", path, GetLastError());
        return 1;
      }
    }
    _snwprintf(path, MAX_PATH * 2, L"%ls\\Uninstall %ls.exe", install_dir, app_name);
    CopyFileW(uninstaller, path, FALSE);
    remove_tree(next);
  }
  remove_tree(old);
  say(L"its files in place");
  wchar_t exe[MAX_PATH * 2];
  _snwprintf(exe, MAX_PATH * 2, L"%ls\\%ls.exe", install_dir, exe_name);
  _snwprintf(uninstaller, MAX_PATH * 2, L"%ls\\Uninstall %ls.exe", install_dir, app_name);
  uninstall_key_of(install_dir, key, 256);
  if (!key[0]) lstrcpynW(key, app_id[0] ? app_id : dir_name, 256);
  wchar_t sub[400];
  _snwprintf(sub, 400, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\%ls", key);
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) == ERROR_SUCCESS) {
    wchar_t v[MAX_PATH * 3];
    if (version[0]) _snwprintf(v, MAX_PATH * 3, L"%ls %ls", app_name, version);
    else lstrcpynW(v, app_name, MAX_PATH * 3);
    reg_str(k, L"DisplayName", v);
    if (version[0]) reg_str(k, L"DisplayVersion", version);
    reg_str(k, L"Publisher", publisher[0] ? publisher : app_name);
    reg_str(k, L"InstallLocation", install_dir);
    _snwprintf(v, MAX_PATH * 3, L"%ls,0", exe);
    reg_str(k, L"DisplayIcon", v);
    _snwprintf(v, MAX_PATH * 3, L"\"%ls\" --uninstall", uninstaller);
    reg_str(k, L"UninstallString", v);
    _snwprintf(v, MAX_PATH * 3, L"\"%ls\" --uninstall /S", uninstaller);
    reg_str(k, L"QuietUninstallString", v);
    DWORD one = 1;
    RegSetValueExW(k, L"NoModify", 0, REG_DWORD, (const BYTE *)&one, sizeof one);
    RegSetValueExW(k, L"NoRepair", 0, REG_DWORD, (const BYTE *)&one, sizeof one);
    RegCloseKey(k);
  }
  register_schemes(schemes_env, exe);
  // Start menu shortcut if absent; desktop shortcut on first install.
  CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  wchar_t lnk[MAX_PATH * 2], folder[MAX_PATH];
  known(&FOLDERID_Programs, folder);
  _snwprintf(lnk, MAX_PATH * 2, L"%ls\\%ls.lnk", folder, app_name);
  if (GetFileAttributesW(lnk) == INVALID_FILE_ATTRIBUTES) say(L"the start menu's shortcut %ls", shortcut(lnk, exe) ? L"made" : L"not made");
  known(&FOLDERID_Desktop, folder);
  if (fresh) {
    _snwprintf(lnk, MAX_PATH * 2, L"%ls\\%ls.lnk", folder, app_name);
    if (GetFileAttributesW(lnk) == INVALID_FILE_ATTRIBUTES) shortcut(lnk, exe);
  }
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL);
  if (shown) PostMessageW(shown, WM_CLOSE, 0, 0);
  if (run_after || !silent) {
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    wchar_t command[MAX_PATH * 2 + 4];
    _snwprintf(command, MAX_PATH * 2 + 4, L"\"%ls\"", exe);
    // Launch with a clean user environment block rather than the updater's or script's environment.
    void *env = NULL;
    HANDLE token = NULL;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &token)) {
      if (!CreateEnvironmentBlock(&env, token, FALSE)) env = NULL;
      CloseHandle(token);
    }
    BOOL opened = CreateProcessW(exe, command, NULL, NULL, FALSE, env ? CREATE_UNICODE_ENVIRONMENT : 0, env, install_dir, &si, &pi);
    if (env) DestroyEnvironmentBlock(env);
    if (opened) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      say(L"%ls opened", exe);
    } else {
      say(L"%ls not opened (%lu)", exe, GetLastError());
    }
  }
  return 0;
}

// ---- uninstalling ----

static int uninstall(int silent, int from_copy) {
  wchar_t self[MAX_PATH * 2], dir[MAX_PATH * 2];
  GetModuleFileNameW(NULL, self, MAX_PATH * 2);
  lstrcpynW(dir, self, MAX_PATH * 2);
  if (wcsrchr(dir, L'\\')) *wcsrchr(dir, L'\\') = 0;
  if (!from_copy) {
    wchar_t tmp[MAX_PATH], copy[MAX_PATH * 2], command[MAX_PATH * 6];
    GetTempPathW(MAX_PATH, tmp);
    _snwprintf(copy, MAX_PATH * 2, L"%lsmbui-uninstall-%lu.exe", tmp, GetCurrentProcessId());
    if (!CopyFileW(self, copy, FALSE)) return 1;
    _snwprintf(command, MAX_PATH * 6, L"\"%ls\" --uninstall-from \"%ls\" --after %lu%ls", copy, dir, GetCurrentProcessId(),
               silent ? L" /S" : L"");
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(copy, command, NULL, NULL, FALSE, 0, NULL, tmp, &si, &pi)) return 1;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
  }
  return 0;
}

static int uninstall_from(const wchar_t *dir, int silent, DWORD after) {
  lstrcpynW(install_dir, dir, MAX_PATH);
  if (after) {
    HANDLE p = OpenProcess(SYNCHRONIZE, FALSE, after);
    if (p) WaitForSingleObject(p, 30000), CloseHandle(p);
  }
  wchar_t exe[MAX_PATH * 2], envp[MAX_PATH * 2], schemes[256];
  _snwprintf(envp, MAX_PATH * 2, L"%ls\\setup.env", dir);
  size_t en = 0;
  unsigned char *eb = read_all(envp, &en);
  if (eb) {
    int w = MultiByteToWideChar(CP_UTF8, 0, (const char *)eb, (int)en, env_text, 4095);
    env_text[w > 0 ? w : 0] = 0;
    free(eb);
  }
  env_get(L"APP_NAME", app_name, 128);
  env_get(L"APP_ID", app_id, 128);
  env_get(L"EXE", exe_name, 128);
  env_get(L"SCHEMES", schemes, 256);
  if (!app_name[0]) return 1;
  if (!silent) {
    int zh = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
    wchar_t q[256];
    _snwprintf(q, 256, zh ? L"要从这台电脑上移除 %ls 吗？你的数据与设置会保留。" : L"Remove %ls from this PC? Your data and settings are kept.", app_name);
    if (MessageBoxW(NULL, q, app_name, MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return 0;
  }
  end_running(dir);
  wchar_t key[256], sub[400];
  uninstall_key_of(dir, key, 256);
  if (key[0]) {
    _snwprintf(sub, 400, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\%ls", key);
    RegDeleteTreeW(HKEY_CURRENT_USER, sub);
  }
  _snwprintf(exe, MAX_PATH * 2, L"%ls\\%ls.exe", dir, exe_name);
  for (wchar_t *p = schemes, *next = NULL, *t = wcstok_s(p, L",", &next); t; t = wcstok_s(NULL, L",", &next)) {
    t = trim_ws(t);
    if (!t[0]) continue;
    wchar_t cmd[MAX_PATH * 3] = L"";
    DWORD cn = sizeof cmd;
    _snwprintf(sub, 400, L"Software\\Classes\\%ls\\shell\\open\\command", t);
    if (RegGetValueW(HKEY_CURRENT_USER, sub, NULL, RRF_RT_REG_SZ, NULL, cmd, &cn) == ERROR_SUCCESS && wcsstr(cmd, dir)) {
      _snwprintf(sub, 400, L"Software\\Classes\\%ls", t);
      RegDeleteTreeW(HKEY_CURRENT_USER, sub);
    }
  }
  if (app_id[0]) {
    _snwprintf(sub, 400, L"Software\\Classes\\AppUserModelId\\%ls", app_id);
    RegDeleteTreeW(HKEY_CURRENT_USER, sub);
  }
  wchar_t folder[MAX_PATH], lnk[MAX_PATH * 2];
  REFKNOWNFOLDERID places[] = {&FOLDERID_Programs, &FOLDERID_Desktop};
  for (int i = 0; i < 2; i++) {
    known(places[i], folder);
    _snwprintf(lnk, MAX_PATH * 2, L"%ls\\%ls.lnk", folder, app_name);
    DeleteFileW(lnk);
  }
  remove_tree(dir);
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL);
  say(L"%ls removed", dir);
  return 0;
}

int wmain(int argc, wchar_t **argv) {
  HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  if ((!out || out == INVALID_HANDLE_VALUE) && AttachConsole(ATTACH_PARENT_PROCESS)) {
    FILE *f;
    freopen_s(&f, "CONOUT$", "w", stdout);
  }
  if (argc >= 2 && !wcscmp(argv[1], L"--pack")) return pack(argc, argv);
  if (argc >= 3 && !wcscmp(argv[1], L"--raw")) return raw(argv[2]);
  int silent = 0, run_after = 0, remove = 0;
  const wchar_t *dir_given = NULL, *from = NULL;
  DWORD after = 0;
  for (int i = 1; i < argc; i++) {
    if (!_wcsicmp(argv[i], L"/S")) silent = 1;
    else if (!wcscmp(argv[i], L"--force-run")) run_after = 1;
    else if (!wcscmp(argv[i], L"--uninstall")) remove = 1;
    else if (!wcscmp(argv[i], L"--uninstall-from") && i + 1 < argc) from = argv[++i];
    else if (!wcscmp(argv[i], L"--after") && i + 1 < argc) after = (DWORD)wcstoul(argv[++i], NULL, 10);
    else if (!_wcsnicmp(argv[i], L"/D=", 3)) dir_given = argv[i] + 3;
  }
  if (from) return uninstall_from(from, silent, after);
  if (remove) return uninstall(silent, 0);
  size_t stub = 0;
  if (!payload_read(&stub)) {
    MessageBoxW(NULL, L"This installer is damaged: download it again.", L"Installer", MB_OK | MB_ICONERROR);
    return 1;
  }
  env_get(L"APP_NAME", app_name, 128);
  env_get(L"APP_ID", app_id, 128);
  env_get(L"EXE", exe_name, 128);
  env_get(L"DIR", dir_name, 128);
  env_get(L"VERSION", version, 64);
  env_get(L"PUBLISHER", publisher, 128);
  env_get(L"SCHEMES", schemes_env, 256);
  if (!app_name[0] || !exe_name[0] || !dir_name[0]) return 1;
  wchar_t tmp[MAX_PATH], logp[MAX_PATH * 2];
  GetTempPathW(MAX_PATH, tmp);
  _snwprintf(logp, MAX_PATH * 2, L"%ls%ls-setup.log", tmp, dir_name);
  log_file = _wfopen(logp, L"w");
  int r = install(silent, run_after, dir_given);
  if (r != 0 && !silent) {
    int zh = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
    MessageBoxW(NULL, zh ? L"没能装好，详情见临时文件夹里的安装记录。" : L"It could not be installed: see the log in the temporary folder.", app_name,
                MB_OK | MB_ICONERROR);
  }
  if (log_file) fclose(log_file);
  return r;
}
