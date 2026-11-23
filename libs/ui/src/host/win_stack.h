// Sampling the UI thread's call stack when Windows marks the window unresponsive (win_life.h life_logs_tick).
// Included by win_life.h and by scripts/win_stack_test.c.
//
// How it avoids deadlocking on SuspendThread: while the target thread is suspended, this code only calls
// GetThreadContext, VirtualQuery and memcpy into a static BSS snapshot buffer, then calls ResumeThread immediately.
// No heap allocation, no loader lock, no DbgHelp call and no log lock runs during the suspend window. All unwinding
// (StackWalk64 against the copied stack bytes) and symbol lookup run after the thread is resumed.
#ifndef MB_WIN_STACK_H
#define MB_WIN_STACK_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#pragma warning(push)
#pragma warning(disable : 4091)
#include <dbghelp.h>
#pragma warning(pop)
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define WIN_STACK_FRAMES 32
#define WIN_STACK_SNAP (128u * 1024u)

// Static snapshot of the suspended thread's stack, read only on the sampler thread (logs_writer, or a test).
static unsigned char ws_snap[WIN_STACK_SNAP];
static DWORD64 ws_snap_sp;
static size_t ws_snap_len;
static DWORD64 ws_snap_region_base;
static DWORD64 ws_snap_region_end;

typedef DWORD(WINAPI *ws_sym_set_options_fn)(DWORD);
typedef BOOL(WINAPI *ws_sym_init_w_fn)(HANDLE, PCWSTR, BOOL);
typedef BOOL(WINAPI *ws_sym_refresh_fn)(HANDLE);
typedef BOOL(WINAPI *ws_stack_walk64_fn)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64, PVOID, PREAD_PROCESS_MEMORY_ROUTINE64,
                                         PFUNCTION_TABLE_ACCESS_ROUTINE64, PGET_MODULE_BASE_ROUTINE64,
                                         PTRANSLATE_ADDRESS_ROUTINE64);
typedef PVOID(WINAPI *ws_ft_access64_fn)(HANDLE, DWORD64);
typedef DWORD64(WINAPI *ws_mod_base64_fn)(HANDLE, DWORD64);
typedef BOOL(WINAPI *ws_sym_from_addr_fn)(HANDLE, DWORD64, PDWORD64, PSYMBOL_INFO);

static int ws_dbg_tried;
static int ws_dbg_ok;
static ws_sym_refresh_fn ws_sym_refresh;
static ws_stack_walk64_fn ws_stack_walk64;
static ws_ft_access64_fn ws_ft_access64;
static ws_mod_base64_fn ws_mod_base64;
static ws_sym_from_addr_fn ws_sym_from_addr;

// Load dbghelp.dll once and initialize symbols against the executable's own directory only (never hitting network
// symbol servers even if _NT_SYMBOL_PATH is set).
static int ws_dbg_init(void) {
  if (ws_dbg_tried) return ws_dbg_ok;
  ws_dbg_tried = 1;
  HMODULE mod = LoadLibraryW(L"dbghelp.dll");
  if (!mod) return 0;
  ws_sym_set_options_fn set_opts = (ws_sym_set_options_fn)(void *)GetProcAddress(mod, "SymSetOptions");
  ws_sym_init_w_fn init_w = (ws_sym_init_w_fn)(void *)GetProcAddress(mod, "SymInitializeW");
  ws_sym_refresh = (ws_sym_refresh_fn)(void *)GetProcAddress(mod, "SymRefreshModuleList");
  ws_stack_walk64 = (ws_stack_walk64_fn)(void *)GetProcAddress(mod, "StackWalk64");
  ws_ft_access64 = (ws_ft_access64_fn)(void *)GetProcAddress(mod, "SymFunctionTableAccess64");
  ws_mod_base64 = (ws_mod_base64_fn)(void *)GetProcAddress(mod, "SymGetModuleBase64");
  ws_sym_from_addr = (ws_sym_from_addr_fn)(void *)GetProcAddress(mod, "SymFromAddr");
  if (!init_w || !ws_stack_walk64 || !ws_ft_access64 || !ws_mod_base64) return 0;
  if (set_opts) set_opts(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_NO_PROMPTS);
  WCHAR dir[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(NULL, dir, MAX_PATH * 2);
  PCWSTR path = L"";
  if (n > 0 && n < MAX_PATH * 2) {
    WCHAR *slash = wcsrchr(dir, L'\\');
    if (slash) {
      *slash = 0;
      path = dir;
    }
  }
  if (!init_w(GetCurrentProcess(), path, TRUE)) return 0;
  ws_dbg_ok = 1;
  return 1;
}

static void win_stack_refresh(void) {
  if (ws_dbg_init() && ws_sym_refresh) ws_sym_refresh(GetCurrentProcess());
}

// Read routine for StackWalk64: serves stack bytes from the snapshot captured while the thread was suspended,
// refuses un-snapshotted bytes inside the live stack region, and uses ReadProcessMemory for read-only PE/code bytes.
static BOOL CALLBACK ws_read_mem(HANDLE proc, DWORD64 addr, PVOID buf, DWORD size, LPDWORD got) {
  if (got) *got = 0;
  if (size == 0) return TRUE;
  if (ws_snap_len > 0 && addr >= ws_snap_sp && addr <= ws_snap_sp + ws_snap_len &&
      (DWORD64)size <= (ws_snap_sp + ws_snap_len) - addr) {
    memcpy(buf, ws_snap + (size_t)(addr - ws_snap_sp), size);
    if (got) *got = size;
    return TRUE;
  }
  if (ws_snap_region_end > ws_snap_region_base && addr >= ws_snap_region_base && addr < ws_snap_region_end) {
    return FALSE;
  }
  SIZE_T read = 0;
  if (!ReadProcessMemory(proc, (LPCVOID)(uintptr_t)addr, buf, size, &read)) return FALSE;
  if (got) *got = (DWORD)read;
  return read == size;
}

// ASCII basename of a loaded module (for log lines).
static void ws_module_name(HMODULE mod, char *out, size_t cap) {
  WCHAR path[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(mod, path, MAX_PATH * 2);
  if (!n || n >= MAX_PATH * 2) {
    snprintf(out, cap, "?");
    return;
  }
  const WCHAR *base = path;
  for (const WCHAR *p = path; *p; p++) {
    if (*p == L'\\' || *p == L'/') base = p + 1;
  }
  int u = WideCharToMultiByte(CP_UTF8, 0, base, -1, out, (int)cap, NULL, NULL);
  if (u <= 0) snprintf(out, cap, "?");
}

// Header line identifying the main executable's PE metadata (and CodeView PDB GUID/age when present) so RVAs (+0x...)
// in subsequent stack lines map to exact build symbols even when no PDB is on the user's machine.
// Colons split the GUID so log_clean's opaque-token redactor leaves every field intact.
static int win_stack_header(DWORD tid, char *out, size_t cap) {
  HMODULE exe = GetModuleHandleW(NULL);
  char name[128];
  ws_module_name(exe, name, sizeof name);
  DWORD ts = 0, img_size = 0, age = 0;
  int has_pdb = 0;
  unsigned char guid[16] = {0};
  const unsigned char *base = (const unsigned char *)exe;
  if (base) {
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    if (dos->e_magic == IMAGE_DOS_SIGNATURE && dos->e_lfanew > 0 && dos->e_lfanew < 4096) {
      const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
      if (nt->Signature == IMAGE_NT_SIGNATURE) {
        ts = nt->FileHeader.TimeDateStamp;
        img_size = nt->OptionalHeader.SizeOfImage;
        if (nt->OptionalHeader.NumberOfRvaAndSizes > IMAGE_DIRECTORY_ENTRY_DEBUG) {
          const IMAGE_DATA_DIRECTORY *dd = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
          if (dd->VirtualAddress && dd->Size >= sizeof(IMAGE_DEBUG_DIRECTORY) && dd->VirtualAddress < img_size &&
              img_size - dd->VirtualAddress >= dd->Size) {
            DWORD count = dd->Size / (DWORD)sizeof(IMAGE_DEBUG_DIRECTORY);
            const IMAGE_DEBUG_DIRECTORY *dir = (const IMAGE_DEBUG_DIRECTORY *)(base + dd->VirtualAddress);
            for (DWORD i = 0; i < count; i++) {
              if (dir[i].Type == IMAGE_DEBUG_TYPE_CODEVIEW && dir[i].AddressOfRawData && dir[i].SizeOfData >= 24 &&
                  dir[i].AddressOfRawData < img_size && img_size - dir[i].AddressOfRawData >= 24) {
                const unsigned char *cv = base + dir[i].AddressOfRawData;
                if (cv[0] == 'R' && cv[1] == 'S' && cv[2] == 'D' && cv[3] == 'S') {
                  memcpy(guid, cv + 4, 16);
                  memcpy(&age, cv + 20, 4);
                  has_pdb = 1;
                  break;
                }
              }
            }
          }
        }
      }
    }
  }
  if (has_pdb) {
    uint32_t d1 = 0;
    uint16_t d2 = 0, d3 = 0;
    memcpy(&d1, guid, 4);
    memcpy(&d2, guid + 4, 2);
    memcpy(&d3, guid + 6, 2);
    return snprintf(out, cap,
                    "win: hang stacks: exe=%s ts=0x%08lx size=0x%lx pdb=%08lx:%04x:%04x:%02x%02x:%02x%02x%02x%02x%02x%02x age=%lu tid=%lu",
                    name, (unsigned long)ts, (unsigned long)img_size, (unsigned long)d1, (unsigned)d2, (unsigned)d3,
                    (unsigned)guid[8], (unsigned)guid[9], (unsigned)guid[10], (unsigned)guid[11], (unsigned)guid[12],
                    (unsigned)guid[13], (unsigned)guid[14], (unsigned)guid[15], (unsigned long)age, (unsigned long)tid);
  }
  return snprintf(out, cap, "win: hang stacks: exe=%s ts=0x%08lx size=0x%lx tid=%lu", name, (unsigned long)ts,
                  (unsigned long)img_size, (unsigned long)tid);
}

// Capture up to cap_frames instruction pointers of thread `tid`, innermost first. Returns frame count (0 on failure).
static int win_stack_capture(DWORD tid, DWORD64 *out_pcs, int cap_frames) {
#if defined(_M_X64) || defined(__x86_64__) || defined(_M_ARM64) || defined(__aarch64__)
  if (!tid || tid == GetCurrentThreadId() || cap_frames <= 0) return 0;
  HANDLE th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid);
  if (!th) return 0;

  CONTEXT ctx;
  memset(&ctx, 0, sizeof ctx);
  ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
  ws_snap_sp = 0;
  ws_snap_len = 0;
  ws_snap_region_base = 0;
  ws_snap_region_end = 0;

  DWORD prev = SuspendThread(th);
  if (prev == (DWORD)-1) {
    CloseHandle(th);
    return 0;
  }
  BOOL got_ctx = GetThreadContext(th, &ctx);
  if (got_ctx) {
#if defined(_M_X64) || defined(__x86_64__)
    uintptr_t sp = (uintptr_t)ctx.Rsp;
#else
    uintptr_t sp = (uintptr_t)ctx.Sp;
#endif
    MEMORY_BASIC_INFORMATION mbi;
    if (sp && VirtualQuery((LPCVOID)sp, &mbi, sizeof mbi) == sizeof mbi && mbi.State == MEM_COMMIT &&
        !(mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD))) {
      uintptr_t region_base = (uintptr_t)mbi.BaseAddress;
      uintptr_t region_end = region_base + mbi.RegionSize;
      size_t avail = region_end > sp ? region_end - sp : 0;
      size_t take = avail < sizeof ws_snap ? avail : sizeof ws_snap;
      if (take > 0) {
        memcpy(ws_snap, (const void *)sp, take);
        ws_snap_sp = (DWORD64)sp;
        ws_snap_len = take;
        ws_snap_region_base = (DWORD64)region_base;
        ws_snap_region_end = (DWORD64)region_end;
      }
    }
  }
  ResumeThread(th);
  CloseHandle(th);
  if (!got_ctx) return 0;

#if defined(_M_X64) || defined(__x86_64__)
  DWORD machine = IMAGE_FILE_MACHINE_AMD64;
  DWORD64 pc0 = ctx.Rip, sp0 = ctx.Rsp, fp0 = ctx.Rbp;
#else
  DWORD machine = IMAGE_FILE_MACHINE_ARM64;
  DWORD64 pc0 = ctx.Pc, sp0 = ctx.Sp, fp0 = ctx.Fp;
#endif
  if (!ws_dbg_init()) {
    out_pcs[0] = pc0;
    return pc0 ? 1 : 0;
  }

  STACKFRAME64 sf;
  memset(&sf, 0, sizeof sf);
  sf.AddrPC.Offset = pc0;
  sf.AddrPC.Mode = AddrModeFlat;
  sf.AddrStack.Offset = sp0;
  sf.AddrStack.Mode = AddrModeFlat;
  sf.AddrFrame.Offset = fp0;
  sf.AddrFrame.Mode = AddrModeFlat;

  HANDLE proc = GetCurrentProcess();
  int depth = 0;
  DWORD64 prev_pc = 0, prev_sp = 0;
  while (depth < cap_frames) {
    if (!ws_stack_walk64(machine, proc, NULL, &sf, &ctx, ws_read_mem, ws_ft_access64, ws_mod_base64, NULL)) break;
    if (!sf.AddrPC.Offset) break;
    if (depth > 0 && sf.AddrPC.Offset == prev_pc && sf.AddrStack.Offset == prev_sp) break;
    out_pcs[depth++] = sf.AddrPC.Offset;
    prev_pc = sf.AddrPC.Offset;
    prev_sp = sf.AddrStack.Offset;
  }
  if (depth == 0 && pc0) {
    out_pcs[0] = pc0;
    depth = 1;
  }
  return depth;
#else
  (void)tid;
  (void)out_pcs;
  (void)cap_frames;
  return 0;
#endif
}

// Format one captured frame list into a single log line:
//   win: hang stack #<sample>: +0x1a2b(fn) ntdll.dll+0x9f12(NtWaitForSingleObject) ...
// Placing +0x<rva> before (<sym>) keeps every RVA short and separated by '(', so log_clean never redacts an RVA.
static int win_stack_format(int sample, const DWORD64 *pcs, int depth, char *out, size_t cap) {
  if (depth <= 0 || cap < 64) return 0;
  HMODULE exe = GetModuleHandleW(NULL);
  HANDLE proc = GetCurrentProcess();
  int at = snprintf(out, cap, "win: hang stack #%d:", sample);
  if (at < 0 || (size_t)at >= cap) return 0;

  unsigned char sym_buf[sizeof(SYMBOL_INFO) + 128];
  SYMBOL_INFO *sym = (SYMBOL_INFO *)sym_buf;

  for (int i = 0; i < depth; i++) {
    if ((size_t)at + 96 >= cap) break;
    DWORD64 pc = pcs[i];
    HMODULE mod = NULL;
    char loc[160];
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)(uintptr_t)pc, &mod) &&
        mod) {
      DWORD64 rva = pc - (DWORD64)(uintptr_t)mod;
      if (mod == exe) {
        snprintf(loc, sizeof loc, "+0x%llx", (unsigned long long)rva);
      } else {
        char mname[96];
        ws_module_name(mod, mname, sizeof mname);
        snprintf(loc, sizeof loc, "%s+0x%llx", mname, (unsigned long long)rva);
      }
    } else {
      snprintf(loc, sizeof loc, "?0x%llx", (unsigned long long)pc);
    }

    char sname[72];
    sname[0] = 0;
    if (ws_dbg_ok && ws_sym_from_addr) {
      memset(sym, 0, sizeof *sym);
      sym->SizeOfStruct = sizeof(SYMBOL_INFO);
      sym->MaxNameLen = 64;
      DWORD64 disp = 0;
      if (ws_sym_from_addr(proc, pc, &disp, sym) && sym->Name[0]) {
        size_t o = 0;
        for (const char *p = sym->Name; *p && o < 64; p++) {
          unsigned char c = (unsigned char)*p;
          if (c == '(' || c == ')' || c == ' ' || c < 0x20 || c >= 0x7f) continue;
          sname[o++] = (char)c;
        }
        sname[o] = 0;
      }
    }

    int wrote = sname[0] ? snprintf(out + at, cap - (size_t)at, " %s(%s)", loc, sname)
                         : snprintf(out + at, cap - (size_t)at, " %s", loc);
    if (wrote <= 0 || (size_t)wrote >= cap - (size_t)at) break;
    at += wrote;
  }
  return at;
}

static int win_stack_sample(DWORD tid, int sample, char *out, size_t cap) {
  DWORD64 pcs[WIN_STACK_FRAMES];
  int depth = win_stack_capture(tid, pcs, WIN_STACK_FRAMES);
  return win_stack_format(sample, pcs, depth, out, cap);
}

#endif  // MB_WIN_STACK_H
