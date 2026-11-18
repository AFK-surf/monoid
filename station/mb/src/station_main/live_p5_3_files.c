// What of a file the shell's `fs.*` does not set (station/mb src/station_main/live_p5_3_sandbox.mbt: a file copied back
// from a sandbox keeps the other side's time, as sandbox-bridge.mjs `place` keeps it with utimesSync): its access and
// modification times, `ms` since 1970, links followed. 0 where set, -1 where not. `path` is NUL-terminated UTF-8.
#include <stdint.h>

#if defined(_WIN32)
#include <windows.h>

int sfp53_utimes(const char *path, double ms) {
  int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  if (n <= 0) return -1;
  WCHAR *wide = (WCHAR *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)n * sizeof(WCHAR));
  if (wide == NULL) return -1;
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, n);
  HANDLE h = CreateFileW(wide, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  HeapFree(GetProcessHeap(), 0, wide);
  if (h == INVALID_HANDLE_VALUE) return -1;
  // (100 ns since 1601)
  uint64_t t = (uint64_t)(ms * 10000.0) + 116444736000000000ULL;
  FILETIME ft;
  ft.dwLowDateTime = (DWORD)(t & 0xffffffffULL);
  ft.dwHighDateTime = (DWORD)(t >> 32);
  BOOL ok = SetFileTime(h, NULL, &ft, &ft);
  CloseHandle(h);
  return ok ? 0 : -1;
}
#else
#include <sys/time.h>

int sfp53_utimes(const char *path, double ms) {
  struct timeval tv[2];
  int64_t us = (int64_t)(ms * 1000.0);
  tv[0].tv_sec = (time_t)(us / 1000000);
  tv[0].tv_usec = (suseconds_t)(us % 1000000);
  if (tv[0].tv_usec < 0) {
    tv[0].tv_sec -= 1;
    tv[0].tv_usec += 1000000;
  }
  tv[1] = tv[0];
  return utimes(path, tv) == 0 ? 0 : -1;
}
#endif
