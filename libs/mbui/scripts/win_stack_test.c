// src/host/win_stack.h's tests on Windows:
//   cl.exe -nologo -W4 -WX -Isrc/host scripts/win_stack_test.c -Foout/stack/ -Feout/stack/win_stack_test.exe
//   out/stack/win_stack_test.exe
// Samples a real spinning worker thread, verifies multi-frame unwind, clean thread resumption, and that log_clean
// preserves the binary header and every frame's RVA without redacting them.
#define _CRT_SECURE_NO_WARNINGS
#include "win_stack.h"
#include "log_files.h"

static int failed;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static HANDLE spin_ready;
static volatile LONG spin_stop;
static volatile LONG spin_iters;

__declspec(noinline) static void spin_leaf(void) {
  SetEvent(spin_ready);
  while (!InterlockedCompareExchange(&spin_stop, 0, 0)) {
    InterlockedIncrement(&spin_iters);
    YieldProcessor();
  }
}

__declspec(noinline) static void spin_middle(int depth) {
  volatile int guard = depth + 1;
  if (depth > 0) spin_middle(depth - 1);
  else spin_leaf();
  (void)guard;
}

static DWORD WINAPI spin_worker(LPVOID unused) {
  (void)unused;
  spin_middle(3);
  return 0;
}

int main(void) {
  // Never suspend the calling thread itself.
  DWORD64 self_pcs[4];
  CHECK(win_stack_capture(GetCurrentThreadId(), self_pcs, 4) == 0);

  spin_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  CHECK(spin_ready != NULL);
  DWORD tid = 0;
  HANDLE th = CreateThread(NULL, 0, spin_worker, NULL, 0, &tid);
  CHECK(th != NULL && tid != 0);
  CHECK(WaitForSingleObject(spin_ready, 5000) == WAIT_OBJECT_0);

  char header[512];
  int hn = win_stack_header(tid, header, sizeof header);
  CHECK(hn > 0);
  CHECK(strstr(header, "win: hang stacks: exe=") != NULL);
  CHECK(strstr(header, " ts=0x") != NULL);
  CHECK(strstr(header, " size=0x") != NULL);
  CHECK(strstr(header, " tid=") != NULL);

  char clean[LF_LINE_MOST + 64];
  size_t cn = log_clean(header, (size_t)hn, clean, LF_LINE_MOST);
  clean[cn] = 0;
  CHECK(cn == (size_t)hn);
  CHECK(strstr(clean, "<cut>") == NULL);
  printf("header: %s\n", clean);

  win_stack_refresh();
  for (int s = 1; s <= 3; s++) {
    if (s > 1) Sleep(10);
    DWORD64 pcs[WIN_STACK_FRAMES];
    int depth = win_stack_capture(tid, pcs, WIN_STACK_FRAMES);
    CHECK(depth >= 3);
    char line[2048];
    int ln = win_stack_format(s, pcs, depth, line, sizeof line);
    CHECK(ln > 0);
    CHECK(strstr(line, "win: hang stack #") != NULL);
    CHECK(strstr(line, " +0x") != NULL);
    size_t lcn = log_clean(line, (size_t)ln, clean, LF_LINE_MOST);
    clean[lcn] = 0;
    CHECK(lcn > 0);
    CHECK(strstr(clean, "<cut>") == NULL);
    if (s == 1) printf("sample: %s\n", clean);
  }

  // Verify the worker thread resumed cleanly and kept running after sampling.
  LONG before = InterlockedCompareExchange(&spin_iters, 0, 0);
  Sleep(5);
  LONG after = InterlockedCompareExchange(&spin_iters, 0, 0);
  CHECK(after > before);

  InterlockedExchange(&spin_stop, 1);
  CHECK(WaitForSingleObject(th, 5000) == WAIT_OBJECT_0);
  CloseHandle(th);
  CloseHandle(spin_ready);

  // Verify long Windows API symbol names paired with RVAs survive log_clean intact.
  const char *long_sym =
      "win: hang stack #1: +0x1a2b3c uiautomationcore.dll+0x42100(UiaRaiseAutomationPropertyChangedEvent) ntdll.dll+0x9f120(NtWaitForSingleObject)";
  size_t lsn = log_clean(long_sym, strlen(long_sym), clean, LF_LINE_MOST);
  clean[lsn] = 0;
  CHECK(lsn == strlen(long_sym));
  CHECK(strstr(clean, "<cut>") == NULL);

  if (failed) return 1;
  printf("win_stack: ok\n");
  return 0;
}
