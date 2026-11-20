// This device's password manager for the Windows host (host_native.mbt `pw_*`, hostapi/passwords.mbt): 1Password's
// command-line tool `op.exe`, resolved and started on a background thread without a window so the UI thread never
// blocks on path lookup or process creation, its output kept until the app takes it: apple_passwords.m's way, the app
// told as it ends (MB_OUTSIDE_OP, between frames: win_app.c's mb_app_told). `op` signed in through 1Password's desktop
// app asks the person itself (Windows Hello, in its own window). Found where winget and 1Password's installer put it,
// else on PATH.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "win.h"

#pragma comment(lib, "user32.lib")

typedef struct run {
  int id;
  HANDLE process;
  // How it ended, once it has: "<code>\x1f<out>\x1f<err>\x1f" (UTF-8).
  char *done;
  struct run *next;
} run;

static SRWLOCK lock = SRWLOCK_INIT;
static run *runs;
static int run_next;

static run *find(int id) {
  for (run *r = runs; r; r = r->next)
    if (r->id == id) return r;
  return NULL;
}

/// Where op.exe is: winget's links, 1Password's installer's, else the first on PATH; FALSE when it is nowhere.
static BOOL op_path(WCHAR *out, DWORD cap) {
  WCHAR place[MAX_PATH];
  const WCHAR *vars[] = {L"%LOCALAPPDATA%\\Microsoft\\WinGet\\Links\\op.exe", L"%ProgramFiles%\\1Password CLI\\op.exe", L"%LOCALAPPDATA%\\1Password\\cli\\op.exe"};
  for (int i = 0; i < 3; i++) {
    if (ExpandEnvironmentStringsW(vars[i], place, MAX_PATH) && GetFileAttributesW(place) != INVALID_FILE_ATTRIBUTES) {
      wcsncpy(out, place, cap - 1);
      out[cap - 1] = 0;
      return TRUE;
    }
  }
  return SearchPathW(NULL, L"op.exe", NULL, cap, out, NULL) > 0;
}

/// `arg` put on a command line as one argument, as the C runtime reads it back (quotes, and the backslashes before them).
static void quote(WCHAR *line, size_t cap, size_t *at, const WCHAR *arg) {
#define PUT(c) do { if (*at + 1 < cap) line[(*at)++] = (c); } while (0)
  PUT(L' ');
  PUT(L'"');
  for (const WCHAR *p = arg;; p++) {
    size_t slashes = 0;
    while (*p == L'\\') {
      slashes++;
      p++;
    }
    if (*p == 0) {
      for (size_t i = 0; i < slashes * 2; i++) PUT(L'\\');
      break;
    }
    if (*p == L'"') {
      for (size_t i = 0; i < slashes * 2 + 1; i++) PUT(L'\\');
    } else {
      for (size_t i = 0; i < slashes; i++) PUT(L'\\');
    }
    PUT(*p);
  }
  PUT(L'"');
  line[*at] = 0;
#undef PUT
}

/// All a pipe gives until it ends, NUL-ended.
static char *drain(HANDLE h) {
  size_t n = 0, cap = 4096;
  char *buf = malloc(cap);
  for (;;) {
    DWORD got = 0;
    if (n + 4096 > cap) buf = realloc(buf, cap *= 2);
    if (!ReadFile(h, buf + n, 4096, &got, NULL) || got == 0) break;
    n += got;
  }
  buf[n] = 0;
  return buf;
}

typedef struct err_read {
  HANDLE err;
  char *errs;
} err_read;

static DWORD WINAPI err_reader(LPVOID p) {
  err_read *e = p;
  e->errs = drain(e->err);
  return 0;
}

typedef struct launch {
  int id;
  WCHAR *args;
  int len;
} launch;

static int ended(int id, const char *why) {
  size_t len = strlen(why) + 16;
  char *done = malloc(len);
  snprintf(done, len, "-1\x1f\x1f%s\x1f", why);
  AcquireSRWLockExclusive(&lock);
  run *r = find(id);
  if (r) r->done = done;
  else free(done);
  ReleaseSRWLockExclusive(&lock);
  mb_app_told(MB_OUTSIDE_OP, id);
  return id;
}

/// Resolves op.exe, starts it without leaking unrelated handles, reads its output, waits for exit, and notifies the app.
static DWORD WINAPI run_op(LPVOID p) {
  launch *l = p;
  int id = l->id;
  AcquireSRWLockShared(&lock);
  BOOL still_wanted = find(id) != NULL;
  ReleaseSRWLockShared(&lock);
  if (!still_wanted) {
    free(l->args);
    free(l);
    return 0;
  }
  WCHAR op[MAX_PATH];
  if (!op_path(op, MAX_PATH)) {
    free(l->args);
    free(l);
    ended(id, "op not found");
    return 0;
  }
  // The command line: the program, then each argument (each ended by a unit separator, U+001F, as the app gives them).
  int n = l->len;
  size_t cap = (size_t)n * 2 + MAX_PATH + 64;
  WCHAR *line = malloc(cap * sizeof(WCHAR));
  size_t at = 0;
  line[0] = 0;
  quote(line, cap, &at, op);
  WCHAR *arg = malloc(((size_t)n + 1) * sizeof(WCHAR));
  int k = 0;
  for (int i = 0; i < n; i++) {
    WCHAR c = l->args[i];
    if (c == 0x1f) {
      arg[k] = 0;
      quote(line, cap, &at, arg);
      k = 0;
    } else {
      arg[k++] = c;
    }
  }
  free(arg);
  free(l->args);
  free(l);
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  HANDLE out_r = NULL, out_w = NULL, err_r = NULL, err_w = NULL;
  if (!CreatePipe(&out_r, &out_w, &sa, 0) || !CreatePipe(&err_r, &err_w, &sa, 0)) {
    if (out_r) CloseHandle(out_r);
    if (out_w) CloseHandle(out_w);
    if (err_r) CloseHandle(err_r);
    if (err_w) CloseHandle(err_w);
    free(line);
    ended(id, "no pipe");
    return 0;
  }
  SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
  HANDLE nul_in = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
  STARTUPINFOEXW siex;
  memset(&siex, 0, sizeof siex);
  siex.StartupInfo.cb = sizeof siex.StartupInfo;
  siex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  siex.StartupInfo.hStdInput = nul_in != INVALID_HANDLE_VALUE ? nul_in : NULL;
  siex.StartupInfo.hStdOutput = out_w;
  siex.StartupInfo.hStdError = err_w;
  // Restrict inherited handles to the child's stdio pipes/NUL so unrelated handles in the process are never leaked.
  HANDLE inherit_list[3];
  DWORD inherit_count = 0;
  inherit_list[inherit_count++] = out_w;
  inherit_list[inherit_count++] = err_w;
  if (nul_in != INVALID_HANDLE_VALUE) inherit_list[inherit_count++] = nul_in;
  SIZE_T attr_size = 0;
  LPPROC_THREAD_ATTRIBUTE_LIST attr_list = NULL;
  DWORD flags = CREATE_NO_WINDOW;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  if (attr_size > 0) {
    attr_list = malloc(attr_size);
    if (attr_list && InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size)) {
      if (UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit_list,
                                    (SIZE_T)inherit_count * sizeof(HANDLE), NULL, NULL)) {
        siex.StartupInfo.cb = sizeof siex;
        siex.lpAttributeList = attr_list;
        flags |= EXTENDED_STARTUPINFO_PRESENT;
      } else {
        DeleteProcThreadAttributeList(attr_list);
        free(attr_list);
        attr_list = NULL;
      }
    } else {
      free(attr_list);
      attr_list = NULL;
    }
  }
  AcquireSRWLockShared(&lock);
  still_wanted = find(id) != NULL;
  ReleaseSRWLockShared(&lock);
  PROCESS_INFORMATION pi;
  memset(&pi, 0, sizeof pi);
  BOOL started = FALSE;
  if (still_wanted) {
    // (the line without the space `quote` puts first)
    started = CreateProcessW(op, line + 1, NULL, NULL, TRUE, flags, NULL, NULL, &siex.StartupInfo, &pi);
  }
  if (attr_list) {
    DeleteProcThreadAttributeList(attr_list);
    free(attr_list);
  }
  free(line);
  CloseHandle(out_w);
  CloseHandle(err_w);
  if (nul_in != INVALID_HANDLE_VALUE) CloseHandle(nul_in);
  if (!still_wanted) {
    CloseHandle(out_r);
    CloseHandle(err_r);
    return 0;
  }
  if (!started) {
    CloseHandle(out_r);
    CloseHandle(err_r);
    ended(id, "op did not start");
    return 0;
  }
  CloseHandle(pi.hThread);
  HANDLE mine = NULL;
  AcquireSRWLockExclusive(&lock);
  run *still = find(id);
  if (still) {
    if (DuplicateHandle(GetCurrentProcess(), pi.hProcess, GetCurrentProcess(), &mine, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
      still->process = pi.hProcess;
    } else {
      mine = pi.hProcess;
    }
  }
  ReleaseSRWLockExclusive(&lock);
  if (!still) {
    TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hProcess);
    CloseHandle(out_r);
    CloseHandle(err_r);
    return 0;
  }
  // Its error output read beside its output: a pipe that fills up holds the process.
  err_read er = {err_r, NULL};
  HANDLE t = CreateThread(NULL, 0, err_reader, &er, 0, NULL);
  char *said = drain(out_r);
  if (t) {
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
  } else {
    er.errs = drain(err_r);
  }
  WaitForSingleObject(mine, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(mine, &code);
  size_t len = strlen(said) + strlen(er.errs) + 32;
  char *done = malloc(len);
  snprintf(done, len, "%ld\x1f%s\x1f%s\x1f", (long)code, said, er.errs);
  free(said);
  free(er.errs);
  CloseHandle(out_r);
  CloseHandle(err_r);
  CloseHandle(mine);
  AcquireSRWLockExclusive(&lock);
  run *r = find(id);
  if (r) {
    r->done = done;
    if (r->process) CloseHandle(r->process);
    r->process = NULL;
  } else {
    free(done);
  }
  ReleaseSRWLockExclusive(&lock);
  mb_app_told(MB_OUTSIDE_OP, id);
  return 0;
}

int32_t mb_host_passwords_able(void) { return 1; }

int32_t mb_host_passwords_run(moonbit_string_t args) {
  run *r = calloc(1, sizeof *r);
  AcquireSRWLockExclusive(&lock);
  r->id = ++run_next;
  r->next = runs;
  runs = r;
  int id = r->id;
  ReleaseSRWLockExclusive(&lock);
  // Allow 1Password's desktop unlock/CLI approval dialog to come to the foreground over this window.
  AllowSetForegroundWindow(ASFW_ANY);
  int n = Moonbit_array_length(args);
  launch *l = malloc(sizeof *l);
  l->id = id;
  l->len = n;
  l->args = malloc(((size_t)n + 1) * sizeof(WCHAR));
  if (n > 0) memcpy(l->args, args, (size_t)n * sizeof(WCHAR));
  l->args[n] = 0;
  HANDLE t = CreateThread(NULL, 0, run_op, l, 0, NULL);
  if (t) {
    CloseHandle(t);
  } else {
    free(l->args);
    free(l);
    return ended(id, "no thread");
  }
  return id;
}

moonbit_string_t mb_host_passwords_out(int32_t id) {
  AcquireSRWLockShared(&lock);
  run *r = find(id);
  WCHAR *w = NULL;
  int n = 0;
  if (r && r->done) {
    n = MultiByteToWideChar(CP_UTF8, 0, r->done, -1, NULL, 0) - 1;
    w = malloc(((size_t)n + 1) * sizeof(WCHAR));
    MultiByteToWideChar(CP_UTF8, 0, r->done, -1, w, n + 1);
  }
  ReleaseSRWLockShared(&lock);
  moonbit_string_t out = moonbit_make_string_raw(n > 0 ? n : 0);
  if (n > 0) memcpy(out, w, (size_t)n * sizeof(WCHAR));
  free(w);
  return out;
}

void mb_host_passwords_end(int32_t id) {
  AcquireSRWLockExclusive(&lock);
  for (run **p = &runs; *p; p = &(*p)->next) {
    if ((*p)->id != id) continue;
    run *r = *p;
    *p = r->next;
    if (r->process) {
      TerminateProcess(r->process, 1);
      CloseHandle(r->process);
    }
    free(r->done);
    free(r);
    break;
  }
  ReleaseSRWLockExclusive(&lock);
}

// The system's autofill (host_native.mbt `af_*`): none on Windows (android_host.c).
int32_t mb_host_autofill_able(void) { return 0; }
int32_t mb_host_autofill_ask(moonbit_string_t host) { (void)host; return 0; }
moonbit_string_t mb_host_autofill_take(void) { return moonbit_make_string_raw(0); }
void mb_host_autofill_end(void) {}
