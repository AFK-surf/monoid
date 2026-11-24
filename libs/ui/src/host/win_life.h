// The app's life on Windows, and what the system says of it (mac_app.m's "The app's life on the Mac", the Windows
// way, as still.fail's desktop app had it there: apps/desktop/src/main.ts). Included by win_app.c after its keys (its
// hwnd, want_frame, mb_now_ms above).
//
// A program that is an app has an identity: MBUI_APP_ID (and MBUI_APP_NAME, MBUI_SCHEMES), from its environment or,
// as an app's are, its own (its resource RCDATA "MBUI_ENV": still.fail's scripts/win.sh writes it, as a Mac app's
// Info.plist has LSEnvironment). Such an app:
// - runs once for its person: started again, the one that runs is brought to the front and handed the link this one
//   was started with (WM_COPYDATA), and this one ends, as the program starts, before any of it runs (its core on the
//   same files: life_begin, among the C runtime's initializers). Its windows' taskbar button, its notifications and
//   its pinned shortcut go by the identity (the process's AppUserModelID);
// - goes on with its window closed, put away to its icon in the notification area (its core, its notifications on):
//   the icon clicked, or the app started again, brings it back; the icon's menu (the app's words: menu_setup's
//   `"role": "tray"` menu) brings it back or quits;
// - is opened with a link of its schemes (MBUI_SCHEMES, "stillfail,stillfail-beta"): as it starts, or the one running is;
//   built in still.fail's desktop app's place (MBUI_OWN), its schemes are claimed for it (links_claimed).
// A program without one (a demo, a test app's scripted run) ends as its window closes, as before. So does a window of
// the app's own (@hostapi.window_open: the program run again with MBUI_WINDOW): it runs beside the app's one run, not
// handed to it, with no icon in the notification area and no schemes claimed, its window's class its own.
// Said to the app on the system's channel (src/hostapi/system.mbt): `shown` with how long it was away as its window
// comes back after it was put away and as the PC wakes from sleep, `link`, `network` as its default route goes
// another way (another interface, another address). Told by @hostapi.set_app_state: shown (visible, not minimized),
// in front (the foreground window), and that it goes on while not shown (its frames for what comes from outside). The system's light or dark (its apps' setting, Settings > Personalization >
// Colors) read as it changes, the title bar drawn dark or light as the app is (set_dark).
#include <shellapi.h>
#include <shobjidl.h>
#include <dwmapi.h>
#include <winsock2.h>
#include <ws2ipdef.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include "mini_json.h"  // the menu the app gives (menu_setup)
#include "hotkey_parse.h"
#include "win_stack.h"

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "iphlpapi.lib")

// what the host posts that the window takes on its own thread
enum { WM_MB_TRAY = WM_APP + 1, WM_MB_NETWORK = WM_APP + 2, WM_MB_STATE = WM_APP + 3, WM_MB_QUIT = WM_APP + 5 };
// WM_COPYDATA's mark of one of this app's own, started again: what it was started with
#define MB_HANDED 0x4D42484E

// ---- the program's own environment ----

// RCDATA "MBUI_ENV"'s NAME=VALUE lines as UTF-16, each line's '=' and end made a NUL: names and values in turn
static WCHAR *own_env;
static int own_env_n;  // how many WCHARs
static void own_env_read(void) {
  static int read;
  if (read) return;
  read = 1;
  HRSRC r = FindResourceW(NULL, L"MBUI_ENV", MAKEINTRESOURCEW(10));  // RT_RCDATA
  HGLOBAL g = r ? LoadResource(NULL, r) : NULL;
  const char *p = g ? (const char *)LockResource(g) : NULL;
  int n = r ? (int)SizeofResource(NULL, r) : 0;
  if (!p || n <= 0) return;
  int w = MultiByteToWideChar(CP_UTF8, 0, p, n, NULL, 0);
  own_env = (WCHAR *)calloc((size_t)w + 1, sizeof(WCHAR));
  if (!own_env) return;
  MultiByteToWideChar(CP_UTF8, 0, p, n, own_env, w);
  for (int i = 0; i < w; i++)
    if (own_env[i] == L'\n' || own_env[i] == L'\r') own_env[i] = 0;
  // each line's first '=': the end of its name
  for (int i = 0; i < w;) {
    int j = i;
    while (j < w && own_env[j] && own_env[j] != L'=') j++;
    if (j < w && own_env[j] == L'=') own_env[j] = 0;
    while (j < w && own_env[j]) j++;
    i = j + 1;
  }
  own_env_n = w;
}

// NAME as the process's environment has it, else as the program's own does; NULL where neither says it
static const WCHAR *app_env(const WCHAR *name) {
  const WCHAR *v = _wgetenv(name);
  if (v) return v;
  own_env_read();
  for (int i = 0; i < own_env_n;) {
    const WCHAR *k = own_env + i;
    int kn = (int)wcslen(k);
    if (kn == 0) {
      i++;
      continue;
    }
    const WCHAR *val = k + kn + 1;
    if (i + kn + 1 > own_env_n) break;
    if (!wcscmp(k, name)) return val;
    i += kn + 1 + (int)wcslen(val) + 1;
  }
  return NULL;
}

moonbit_string_t mb_host_env(moonbit_string_t name) {
  int n = Moonbit_array_length(name);
  WCHAR *k = (WCHAR *)calloc((size_t)n + 1, sizeof(WCHAR));
  memcpy(k, name, (size_t)n * sizeof(WCHAR));
  const WCHAR *v = app_env(k);
  free(k);
  int len = v ? (int)wcslen(v) : 0;
  moonbit_string_t out = moonbit_make_string_raw(len);
  if (len) memcpy(out, v, (size_t)len * sizeof(WCHAR));
  return out;
}

// the app's identity ("": the program is none), its name (else the window's title)
static const WCHAR *app_id(void) {
  const WCHAR *v = app_env(L"MBUI_APP_ID");
  return v ? v : L"";
}
static const WCHAR *app_name(const WCHAR *title) {
  const WCHAR *v = app_env(L"MBUI_APP_NAME");
  return v && *v ? v : title;
}
const wchar_t *mb_win_app_id(void) { return app_id(); }
const wchar_t *mb_win_app_name(void) { return app_name(L""); }
const wchar_t *mb_win_env(const wchar_t *name) { return app_env(name); }

// a window of the app's own (@hostapi.window_open): MBUI_WINDOW said by whoever started it, never the program's own
static int window_run(void) {
  const WCHAR *w = _wgetenv(L"MBUI_WINDOW");
  return w && *w;
}

// the window's class, by which the app started again finds the one running (a window of its own's another)
static void window_class(WCHAR *out, size_t cap) {
  if (*app_id() && window_run()) _snwprintf(out, cap, L"mbui %ls window", app_id());
  else if (*app_id()) _snwprintf(out, cap, L"mbui %ls", app_id());
  else lstrcpynW(out, L"mbui", (int)cap);
  out[cap - 1] = 0;
}

// a console's to write to, where the program was started from one and nothing was given it (a GUI program's output
// goes nowhere else): a person's run in a terminal sees its lines; a script's, CI's (its own pipes) as it gave them
static void life_console(void) {
  HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  if (out && out != INVALID_HANDLE_VALUE) return;
  if (!AttachConsole(ATTACH_PARENT_PROCESS)) return;
  FILE *f;
  freopen_s(&f, "CONOUT$", "w", stdout);
  freopen_s(&f, "CONOUT$", "w", stderr);
}

// ---- said on the system's channel ----

// UTF-16 to UTF-8, escaped for a JSON string: appended to `out` (cap bytes in all), its new length
static size_t json_put(char *out, size_t o, size_t cap, const WCHAR *s, int n) {
  int u = WideCharToMultiByte(CP_UTF8, 0, s, n, NULL, 0, NULL, NULL);
  char *b = (char *)malloc((size_t)u + 1);
  if (!b) return o;
  WideCharToMultiByte(CP_UTF8, 0, s, n, b, u, NULL, NULL);
  for (int i = 0; i < u && o + 8 < cap; i++) {
    unsigned char c = (unsigned char)b[i];
    if (c == '"' || c == '\\') out[o++] = '\\', out[o++] = (char)c;
    else if (c < 0x20) o += (size_t)snprintf(out + o, cap - o, "\\u%04x", c);
    else out[o++] = (char)c;
  }
  free(b);
  return o;
}

static void say_system(const char *json, size_t n) { mb_post("system", json, n, NULL, 0); }

// away since `at` (GetTickCount64's: it counts a sleep's time, as CLOCK_MONOTONIC does on Apple's systems)
static void say_shown(ULONGLONG at) {
  char b[64];
  int n = snprintf(b, sizeof b, "{\"shown\":{\"away\":%llu}}", (unsigned long long)(GetTickCount64() - at));
  say_system(b, (size_t)n);
}

// a link of the app's schemes (MBUI_SCHEMES: "stillfail,stillfail-beta"), else 0
static int app_link(const WCHAR *s) {
  const WCHAR *schemes = app_env(L"MBUI_SCHEMES");
  if (!schemes || !s) return 0;
  const WCHAR *colon = wcschr(s, L':');
  if (!colon || colon == s) return 0;
  size_t n = (size_t)(colon - s);
  for (const WCHAR *p = schemes; *p;) {
    const WCHAR *e = wcschr(p, L',');
    size_t k = e ? (size_t)(e - p) : wcslen(p);
    if (k == n && !_wcsnicmp(p, s, n)) return 1;
    p += k + (e ? 1 : 0);
  }
  return 0;
}

static void say_link(const WCHAR *url, int n) {
  size_t cap = (size_t)n * 12 + 32, o = 0;
  char *b = (char *)malloc(cap);
  if (!b) return;
  o += (size_t)snprintf(b, cap, "{\"link\":\"");
  o = json_put(b, o, cap, url, n);
  o += (size_t)snprintf(b + o, cap - o, "\"}");
  fprintf(stdout, "win: opened with a link (%.*ls)\n", (int)(wcschr(url, L':') ? wcschr(url, L':') - url + 3 : 0), url);
  fflush(stdout);
  say_system(b, o);
  free(b);
}

// the link the program was started with: the first of its arguments that is one of the app's
static const WCHAR *started_with(void) {
  static WCHAR *link;
  static int read;
  if (read) return link;
  read = 1;
  int argc = 0;
  WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  for (int i = 1; argv && i < argc && !link; i++)
    if (app_link(argv[i])) link = _wcsdup(argv[i]);
  if (argv) LocalFree(argv);
  return link;
}

// The app's links its own (MBUI_OWN: built in still.fail's desktop app's place, its schemes that app's): each of its
// schemes opens this program, as that app's setAsDefaultProtocolClient had them (HKCU\Software\Classes\<scheme>,
// shell\open\command "<this program>" "%1"), said again as it starts (it may have moved, or another taken them)
static void links_claimed(void) {
  if (window_run()) return;
  const WCHAR *own = app_env(L"MBUI_OWN"), *schemes = app_env(L"MBUI_SCHEMES");
  if (!own || wcscmp(own, L"1") != 0 || !schemes || !*schemes) return;
  WCHAR exe[MAX_PATH * 2], command[MAX_PATH * 2 + 16], key[256], label[300];
  DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  if (!n || n >= MAX_PATH * 2) return;
  _snwprintf(command, MAX_PATH * 2 + 16, L"\"%ls\" \"%%1\"", exe);
  command[MAX_PATH * 2 + 15] = 0;
  for (const WCHAR *p = schemes; *p;) {
    const WCHAR *e = wcschr(p, L',');
    size_t k = e ? (size_t)(e - p) : wcslen(p);
    if (k > 0 && k < 64) {
      WCHAR scheme[64];
      wcsncpy_s(scheme, 64, p, k);
      HKEY h = NULL;
      _snwprintf(key, 256, L"Software\\Classes\\%ls", scheme);
      if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &h, NULL) == ERROR_SUCCESS) {
        _snwprintf(label, 300, L"URL:%ls", app_name(L""));
        RegSetValueExW(h, NULL, 0, REG_SZ, (const BYTE *)label, (DWORD)((wcslen(label) + 1) * sizeof(WCHAR)));
        RegSetValueExW(h, L"URL Protocol", 0, REG_SZ, (const BYTE *)L"", sizeof(WCHAR));
        RegCloseKey(h);
      }
      _snwprintf(key, 256, L"Software\\Classes\\%ls\\shell\\open\\command", scheme);
      if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &h, NULL) == ERROR_SUCCESS) {
        RegSetValueExW(h, NULL, 0, REG_SZ, (const BYTE *)command, (DWORD)((wcslen(command) + 1) * sizeof(WCHAR)));
        RegCloseKey(h);
      }
    }
    p += k + (e ? 1 : 0);
  }
}

// ---- in front or not ----

static void (*state_cb)(int32_t);
static int state_told = -1;
void mb_host_set_app_state(void (*f)(int32_t)) { state_cb = f; }
static void tell_state(void) {
  if (!state_cb || !hwnd) return;
  // (shown: any window of the run's, the first put away and another open among them)
  int shown = 0;
  for (int k = 0; k < MB_WINS && !shown; k++)
    if (win_slots[k].h && IsWindowVisible(win_slots[k].h) && !IsIconic(win_slots[k].h)) shown = 1;
  // (in front: any window of the run's, a window beside the first among them)
  int front = shown && win_of(GetForegroundWindow()) >= 0;
  // (| 4: the app goes on with its window not shown, as what comes from outside asks: win_app.c draw_frame)
  int s = (shown ? 1 : 0) | (front ? 2 : 0) | 4;
  if (s == state_told) return;
  state_told = s;
  state_cb(s);
}

// ---- light or dark ----

static int sys_dark = -1, drawn_dark = -1;
static void read_dark(void) {
  DWORD v = 1, n = sizeof v;
  sys_dark = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                          L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &v, &n) == ERROR_SUCCESS && v == 0;
}

// Whether the system is set to dark (@hostapi.system_dark): its apps' mode, read again as it changes
// (WM_SETTINGCHANGE's ImmersiveColorSet)
int32_t mb_host_system_dark(void) {
  if (sys_dark < 0) read_dark();
  return sys_dark;
}

// the title bar as the app is drawn (DWMWA_USE_IMMERSIVE_DARK_MODE: 20, 19 before Windows 10 20H1), each window's of the
// run
static void title_dark_of(HWND h) {
  if (!h || drawn_dark < 0) return;
  BOOL d = drawn_dark;
  if (FAILED(DwmSetWindowAttribute(h, 20, &d, sizeof d))) DwmSetWindowAttribute(h, 19, &d, sizeof d);
}
static void title_dark(void) {
  for (int k = 0; k < MB_WINS; k++) title_dark_of(win_slots[k].h);
}

// The app drawn dark or light (@hostapi.set_dark): the window's title bar the same.
void mb_host_set_dark(int32_t dark) {
  if ((dark != 0) == drawn_dark) return;
  drawn_dark = dark != 0;
  title_dark();
}

// ---- where its window was left ----

// An app's window opens where it was last left, its size and place and whether it was maximized (the Mac's frame
// autosave, the Windows way): its placement kept in HKCU\Software\<the app's id> as the person leaves it (a move or
// a resize let go, the window put away, the app quitting) and put back before it is first shown, unless no screen
// shows it now. A run that stands for no one looking at it (scripted, driven, recorded, a bench's, one taking pictures
// or told its size) and a window of its own (MBUI_WINDOW) keep the size they are given.
static int place_kept(void) {
  return *app_id() && !window_run() && !script && !shot_dir && !getenv("MBUI_WIN") && !getenv("MBUI_DRIVE") &&
         !getenv("MBUI_DRIVE_B64") && !getenv("MBUI_BENCH") && !getenv("MBUI_RECORD");
}

static void place_key(WCHAR *out, size_t cap) {
  _snwprintf(out, cap, L"Software\\%ls", app_id());
  out[cap - 1] = 0;
}

static void place_keep(void) {
  if (!hwnd || !place_kept()) return;
  WINDOWPLACEMENT p = {sizeof p};
  if (!GetWindowPlacement(hwnd, &p)) return;
  WCHAR key[256];
  place_key(key, 256);
  RegSetKeyValueW(HKEY_CURRENT_USER, key, L"WindowPlacement", REG_BINARY, &p, sizeof p);
}

// The kept placement put on the window, still hidden: how to show it (SW_SHOW where none was kept).
static int place_put_back(void) {
  if (!hwnd || !place_kept()) return SW_SHOW;
  WINDOWPLACEMENT p;
  DWORD n = sizeof p;
  WCHAR key[256];
  place_key(key, 256);
  if (RegGetValueW(HKEY_CURRENT_USER, key, L"WindowPlacement", RRF_RT_REG_BINARY, NULL, &p, &n) != ERROR_SUCCESS ||
      n != sizeof p || p.length != sizeof p)
    return SW_SHOW;
  RECT *r = &p.rcNormalPosition;
  if (r->right - r->left < 100 || r->bottom - r->top < 100 || !MonitorFromRect(r, MONITOR_DEFAULTTONULL))
    return SW_SHOW;
  // (left minimized: opened as it was before, maximized where it was)
  int max = p.showCmd == SW_SHOWMAXIMIZED || (p.showCmd == SW_SHOWMINIMIZED && (p.flags & WPF_RESTORETOMAXIMIZED));
  p.showCmd = SW_HIDE;
  p.flags = 0;
  SetWindowPlacement(hwnd, &p);
  // (again: the first may have moved it onto a screen of another scale, whose WM_DPICHANGED sized it by that scale)
  SetWindowPlacement(hwnd, &p);
  return max ? SW_SHOWMAXIMIZED : SW_SHOW;
}

// ---- put away, brought back ----

static ULONGLONG put_away_at;  // GetTickCount64's as the window was closed (0: it is out)
static ULONGLONG asleep_at;    // as the PC went to sleep (0: awake)

static int first_hidden_bare;  // a bare run's first hidden as it closed while another was open (put_away)
static void bring_back(void) {
  if (!hwnd) return;
  if (put_away_at || IsIconic(hwnd)) {
    fprintf(stdout, "win: brought back\n");
    fflush(stdout);
  }
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
  if (put_away_at) {
    say_shown(put_away_at);
    put_away_at = 0;
  }
  first_hidden_bare = 0;
  // (the first's frame, whichever window is in place as it is brought back: a window beside it may ask it)
  win_slots[0].want_frame = 1;
  tell_state();
}

static int tray_on;

// the window closed: put away where the program is an app (to its icon in the notification area; minimized where it
// has none there, as Explorer is not running), else the program ends. The windows beside it stay as they are: the
// first only hidden, its window kept (what is posted to it, the run's thread's messages, still comes), all of them
// going only as the program ends. A bare run's (not an app) hidden while a window beside it is open, the run ending as
// the last of them closes (win_app.c win_closed), as the Mac's.
static int put_away(void) {
  if (window_run()) return 0;
  if (!*app_id()) {
    int beside = 0;
    for (int k = 1; k < MB_WINS; k++)
      if (win_slots[k].h) beside = 1;
    if (!beside) return 0;
    fprintf(stdout, "win: closed, hidden while a window beside it is open\n");
    fflush(stdout);
    first_hidden_bare = 1;
    ShowWindow(hwnd, SW_HIDE);
    tell_state();
    return 1;
  }
  place_keep();
  if (!tray_on) {
    fprintf(stdout, "win: put away, minimized (no notification area)\n");
    fflush(stdout);
    ShowWindow(hwnd, SW_MINIMIZE);
    return 1;
  }
  fprintf(stdout, "win: put away, to its icon in the notification area\n");
  fflush(stdout);
  ShowWindow(hwnd, SW_HIDE);
  if (!put_away_at) put_away_at = GetTickCount64();
  tell_state();
  return 1;
}

// ---- once for its person ----

static HANDLE single, window_up;

// 1: this is the app's one run; else it handed what it was started with to the one that runs (which comes to the
// front), and ends
static int life_single(void) {
  const WCHAR *id = app_id();
  if (!*id || window_run()) return 1;
  WCHAR name[300], up[300];
  _snwprintf(name, 300, L"Local\\mbui %ls", id);
  name[299] = 0;
  _snwprintf(up, 300, L"Local\\mbui %ls window", id);
  up[299] = 0;
  // (set by the one that runs once its window is there: what this one waits on, not a time)
  window_up = CreateEventW(NULL, TRUE, FALSE, up);
  single = CreateMutexW(NULL, FALSE, name);
  if (!single || GetLastError() != ERROR_ALREADY_EXISTS) return 1;
  if (window_up) WaitForSingleObject(window_up, 30000);
  WCHAR cls[300];
  window_class(cls, 300);
  HWND other = FindWindowW(cls, NULL);
  // (one that runs but has no window after all that: still not a second one on its files)
  if (!other) {
    fprintf(stdout, "win: the app runs already, with no window to hand to\n");
    fflush(stdout);
    return 0;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(other, &pid);
  AllowSetForegroundWindow(pid);
  const WCHAR *link = started_with();
  COPYDATASTRUCT cd = {MB_HANDED, link ? (DWORD)(wcslen(link) * sizeof(WCHAR)) : 0, (void *)link};
  DWORD_PTR r = 0;
  SendMessageTimeoutW(other, WM_COPYDATA, 0, (LPARAM)&cd, SMTO_ABORTIFHUNG, 10000, &r);
  fprintf(stdout, "win: the app runs already: handed to it%s\n", link ? " with a link" : "");
  fflush(stdout);
  return 0;
}

// the app's identity the process's (its taskbar button, its notifications, the shortcut pinned for it)
static void life_identity(void) {
  if (*app_id()) SetCurrentProcessExplicitAppUserModelID(app_id());
}

// ---- its log files (win_logs.h) ----

double mb_host_cpu_ms(void);

// (on the window's thread, between its frames: what shows how much the record holds follows it)
static volatile LONG life_perf_telling;
static void life_perf_told(void *unused) {
  (void)unused;
  InterlockedExchange(&life_perf_telling, 0);
  told_between(MB_OUTSIDE_PERF, 0);
}

// The record grown, told once for all the writes before it is delivered.
static void life_perf_written(void) {
  if (hwnd && !InterlockedExchange(&life_perf_telling, 1)) mb_app_call(life_perf_told, NULL);
}

// Each few seconds, whatever the window's thread is doing (the writer's thread): a line for the record of what the
// process takes; and, record or none, the window no longer answering and answering again (the system's own test: its
// messages unread for 5 s), with the UI thread's call stacks sampled when it hangs so a freeze leaves its frames in
// the log without anyone having caught it live.
static void life_logs_tick(void) {
  static double cpu_was = -1;
  static ULONGLONG at_was, hung_at;
  static int hung_ticks;
  double cpu = mb_host_cpu_ms();
  ULONGLONG at = GetTickCount64();
  double share = cpu_was >= 0 && at > at_was ? (cpu - cpu_was) * 100.0 / (double)(at - at_was) : 0;
  cpu_was = cpu;
  at_was = at;
  HWND h = hwnd;
  int hung = h && IsHungAppWindow(h);
  char line[160];
  int n = 0;
  if (hung && !hung_at) {
    hung_at = at;
    hung_ticks = 1;
    n = snprintf(line, sizeof line, "win: the window is not answering: cpu=%.0f%% mem=%.0fMB", share, mb_host_mem_bytes() / 1048576.0);
  } else if (hung && hung_at) {
    hung_ticks++;
  } else if (!hung && hung_at) {
    n = snprintf(line, sizeof line, "win: the window answers again, %.0f s on", (double)(at - hung_at) / 1000.0);
    hung_at = 0;
    hung_ticks = 0;
  }
  if (n > 0) logs_line(LOGS_LOG, line, (size_t)n);
  if (hung && (hung_ticks == 1 || hung_ticks == 2)) {
    DWORD tid = GetWindowThreadProcessId(h, NULL);
    if (tid) {
      char stack_line[2048];
      if (hung_ticks == 1) {
        int hn = win_stack_header(tid, stack_line, sizeof stack_line);
        if (hn > 0) logs_line(LOGS_LOG, stack_line, (size_t)hn);
        win_stack_refresh();
        for (int s = 1; s <= 3; s++) {
          if (s > 1) Sleep(50);
          int sn = win_stack_sample(tid, s, stack_line, sizeof stack_line);
          if (sn > 0) logs_line(LOGS_LOG, stack_line, (size_t)sn);
        }
      } else {
        int sn = win_stack_sample(tid, 4, stack_line, sizeof stack_line);
        if (sn > 0) logs_line(LOGS_LOG, stack_line, (size_t)sn);
      }
    }
  }
  if (logs_perf_on) {
    n = snprintf(line, sizeof line, "win: cpu=%.0f%% mem=%.0fMB hung=%d", share, mb_host_mem_bytes() / 1048576.0, hung);
    logs_line(LOGS_PERF, line, (size_t)n);
  }
}

// %LOCALAPPDATA%\<the app's id>\logs, for a program that is an app (a demo has none, and keeps nothing).
static void life_logs(void) {
  if (!*app_id()) return;
  PWSTR local = NULL;
  if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &local))) return;
  WCHAR dir[MAX_PATH * 2];
  _snwprintf(dir, MAX_PATH * 2, L"%ls\\%ls\\logs", local, app_id());
  dir[MAX_PATH * 2 - 1] = 0;
  CoTaskMemFree(local);
  logs_begin(dir, life_logs_tick, life_perf_written);
}

// As the program starts, before main (the C runtime's initializers, .CRT$XCU): its console, whether it is the app's
// one run (else it has handed over, and ends here), its identity, its log files.
static void __cdecl life_begin(void) {
  life_console();
  if (!life_single()) {
    fflush(stdout);
    ExitProcess(0);
  }
  life_identity();
  life_logs();
}
// (named outside the file and asked for by the link: nothing refers to it, and an optimizer would drop it)
#pragma section(".CRT$XCU", read)
__declspec(allocate(".CRT$XCU")) void(__cdecl *mb_win_life_begins)(void) = life_begin;
#pragma comment(linker, "/include:mb_win_life_begins")

// ---- windows of its own ----

static VOID CALLBACK window_opener_ended(PVOID data, BOOLEAN timed) {
  (void)data;
  (void)timed;
  ExitProcess(0);
}

// A window of the app's own ends with the run that opened it, however that ends (a window run by hand, with no
// MBUI_WINDOW_OF, is its own). Its opener gone before this looked: at once.
static void window_ends_with_opener(void) {
  const WCHAR *of = _wgetenv(L"MBUI_WINDOW_OF");
  DWORD pid = of ? wcstoul(of, NULL, 10) : 0;
  if (!pid) return;
  HANDLE opener = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!opener) {
    if (GetLastError() == ERROR_INVALID_PARAMETER) ExitProcess(0);
    return;
  }
  HANDLE wait;
  if (!RegisterWaitForSingleObject(&wait, opener, window_opener_ended, NULL, INFINITE, WT_EXECUTEONLYONCE)) CloseHandle(opener);
}

// Another window of the app's (@hostapi.window_open): the program run again, its environment this one's with
// MBUI_WINDOW=<what>; a run of its own beside this one (window_run), ending as its window closes or as this run ends
// (MBUI_WINDOW_OF, this run's pid: window_ends_with_opener).
typedef struct WindowOpened {
  WCHAR *what;
  HANDLE process;
  DWORD pid;
  struct WindowOpened *next;
} WindowOpened;
static WindowOpened *windows_opened;  // what each was started for, the last for each

static WindowOpened **window_opened_at(const WCHAR *what, int n) {
  WindowOpened **at = &windows_opened;
  for (; *at; at = &(*at)->next) {
    if ((int)wcslen((*at)->what) == n && !wmemcmp((*at)->what, what, n)) return at;
  }
  return at;
}

static void window_opened_drop(WindowOpened **at) {
  WindowOpened *w = *at;
  *at = w->next;
  CloseHandle(w->process);
  free(w->what);
  free(w);
}

// (the windows of this run, beside its first: win_app.c mb_host_windows; a window of the app's own is another run of it
// where the app says so, or where it is one itself: MBUI_WINDOW)
int32_t mb_host_window_opens(void) { return 1; }
int32_t mb_host_window_open(moonbit_string_t what) {
  int wn = Moonbit_array_length(what);
  if (wn <= 0) return 0;
  WCHAR exe[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  if (!n || n >= MAX_PATH * 2) return 0;
  // this one's environment, its own MBUI_WINDOW left out, then the new one's (each NAME=VALUE ended by a NUL, all by
  // another)
  WCHAR *env = GetEnvironmentStringsW();
  if (!env) return 0;
  size_t have = 0;
  for (const WCHAR *e = env; *e; e += wcslen(e) + 1) have += wcslen(e) + 1;
  WCHAR *block = (WCHAR *)calloc(have + (size_t)wn + 64, sizeof(WCHAR));
  if (!block) {
    FreeEnvironmentStringsW(env);
    return 0;
  }
  WCHAR *at = block;
  for (const WCHAR *e = env; *e; e += wcslen(e) + 1) {
    if (!_wcsnicmp(e, L"MBUI_WINDOW=", 12)) continue;
    size_t len = wcslen(e);
    memcpy(at, e, (len + 1) * sizeof(WCHAR));
    at += len + 1;
  }
  FreeEnvironmentStringsW(env);
  memcpy(at, L"MBUI_WINDOW=", 12 * sizeof(WCHAR));
  at += 12;
  memcpy(at, what, (size_t)wn * sizeof(WCHAR));
  at += wn;
  *at++ = 0;
  at += _snwprintf(at, 40, L"MBUI_WINDOW_OF=%lu", GetCurrentProcessId()) + 1;
  *at = 0;
  WCHAR command[MAX_PATH * 2 + 4];
  _snwprintf(command, MAX_PATH * 2 + 4, L"\"%ls\"", exe);
  command[MAX_PATH * 2 + 3] = 0;
  STARTUPINFOW si = {sizeof si};
  PROCESS_INFORMATION pi = {0};
  BOOL ok = CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_UNICODE_ENVIRONMENT, block, NULL, &si, &pi);
  free(block);
  if (!ok) {
    fprintf(stdout, "win: no window of its own (CreateProcess: %lu)\n", GetLastError());
    fflush(stdout);
    return 0;
  }
  // (its window to the front once it is there: it may take the foreground from this one)
  AllowSetForegroundWindow(pi.dwProcessId);
  CloseHandle(pi.hThread);
  WindowOpened **before = window_opened_at((const WCHAR *)what, wn);
  if (*before) window_opened_drop(before);
  WindowOpened *w = (WindowOpened *)calloc(1, sizeof *w);
  WCHAR *words = (WCHAR *)calloc((size_t)wn + 1, sizeof(WCHAR));
  if (!w || !words) {
    free(w);
    free(words);
    CloseHandle(pi.hProcess);
    return 1;
  }
  memcpy(words, what, (size_t)wn * sizeof(WCHAR));
  *w = (WindowOpened){words, pi.hProcess, pi.dwProcessId, windows_opened};
  windows_opened = w;
  return 1;
}

// its top-level window, of the run asked for (a tool window of its own has an owner)
typedef struct {
  DWORD pid;
  HWND found;
} WindowOfRun;
static BOOL CALLBACK window_of_run(HWND h, LPARAM find) {
  WindowOfRun *of = (WindowOfRun *)find;
  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  if (pid != of->pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
  of->found = h;
  return FALSE;
}

// The window opened for `what` to the front, while it runs (@hostapi.window_front). (Not there yet, as it starts: it
// takes the foreground itself, AllowSetForegroundWindow above.)
int32_t mb_host_window_front(moonbit_string_t what) {
  int wn = Moonbit_array_length(what);
  WindowOpened **at = window_opened_at((const WCHAR *)what, wn);
  if (!*at) return 0;
  if (WaitForSingleObject((*at)->process, 0) != WAIT_TIMEOUT) {
    window_opened_drop(at);
    return 0;
  }
  WindowOfRun of = {(*at)->pid, NULL};
  EnumWindows(window_of_run, (LPARAM)&of);
  if (of.found) {
    if (IsIconic(of.found)) ShowWindow(of.found, SW_RESTORE);
    AllowSetForegroundWindow(of.pid);
    SetForegroundWindow(of.found);
  }
  return 1;
}

// what the app started again handed over: the window to the front, its link to the app
static LRESULT life_handed(const COPYDATASTRUCT *cd) {
  if (!cd || cd->dwData != MB_HANDED) return FALSE;
  bring_back();
  int n = (int)(cd->cbData / sizeof(WCHAR));
  if (n > 0) {
    WCHAR *s = (WCHAR *)calloc((size_t)n + 1, sizeof(WCHAR));
    if (s) {
      memcpy(s, cd->lpData, (size_t)n * sizeof(WCHAR));
      if (app_link(s)) say_link(s, n);
      free(s);
    }
  }
  return TRUE;
}

// ---- the notification area's icon, and its menu ----

static NOTIFYICONDATAW tray;
static UINT taskbar_created;  // Explorer started again: the icon is put there again
static const WCHAR *window_title = L"";

// the menu's items, as the app gave them (its "tray" menu): their words ({app} the app's name), their role ("show",
// "quit"), or the action said back to the app (`menu`)
#define TRAY_MOST 16
static struct {
  WCHAR *title;
  char role[16];
  char *action;
  int separator;
} tray_items[TRAY_MOST];
static int tray_n;

// the program's own icon (its resource 1) at the size asked for, the system's default where it has none
static HICON own_icon(int size) {
  HICON i = (HICON)LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1), IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
  return i ? i : LoadIcon(NULL, IDI_APPLICATION);
}

static void tray_put(void) {
  if (!*app_id() || window_run() || !hwnd) return;
  memset(&tray, 0, sizeof tray);
  tray.cbSize = sizeof tray;
  tray.hWnd = hwnd;
  tray.uID = 1;
  tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray.uCallbackMessage = WM_MB_TRAY;
  UINT dpi = GetDpiForWindow(hwnd);
  tray.hIcon = own_icon(GetSystemMetricsForDpi(SM_CXSMICON, dpi ? dpi : 96));
  lstrcpynW(tray.szTip, app_name(window_title), (int)(sizeof tray.szTip / sizeof tray.szTip[0]));
  tray_on = Shell_NotifyIconW(NIM_ADD, &tray);
  if (tray_on) {
    tray.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray);
  }
}

static void tray_gone(void) {
  if (tray_on) Shell_NotifyIconW(NIM_DELETE, &tray);
  tray_on = 0;
}

// the app quits: its icon taken from the notification area first (else it lingers there until pointed at)
static void quit(void) {
  place_keep();
  tray_gone();
  exit(0);
}

// `in`'s words with {app} the app's name, as UTF-16
static WCHAR *tray_words(const char *in) {
  int n = MultiByteToWideChar(CP_UTF8, 0, in, -1, NULL, 0);
  WCHAR *w = (WCHAR *)calloc((size_t)n + 1, sizeof(WCHAR));
  if (!w) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, in, -1, w, n);
  WCHAR *at = wcsstr(w, L"{app}");
  if (!at) return w;
  const WCHAR *name = app_name(window_title);
  size_t len = wcslen(w) - 5 + wcslen(name) + 1;
  WCHAR *out = (WCHAR *)calloc(len, sizeof(WCHAR));
  if (!out) return w;
  wcsncpy_s(out, len, w, (size_t)(at - w));
  wcscat_s(out, len, name);
  wcscat_s(out, len, at + 5);
  free(w);
  return out;
}

// The app's menus (@hostapi.menu_setup): Windows has no menu bar of the app's; its "tray" menu is the icon's.
void mb_host_menu_setup(moonbit_string_t json_s) {
  int n = Moonbit_array_length(json_s);
  int u = WideCharToMultiByte(CP_UTF8, 0, (LPCWCH)json_s, n, NULL, 0, NULL, NULL);
  char *text = (char *)malloc((size_t)u + 1);
  if (!text) return;
  WideCharToMultiByte(CP_UTF8, 0, (LPCWCH)json_s, n, text, u, NULL, NULL);
  text[u] = 0;
  const char *p = text;
  jv menus;
  int ok = jparse(&p, &menus, 0) && menus.kind == 'a';
  for (int i = 0; ok && i < menus.n; i++) {
    const jv *m = &menus.at[i];
    if (strcmp(jtext(m, "role"), "tray") != 0) continue;
    const jv *items = jget(m, "items");
    if (!items || items->kind != 'a') break;
    for (int k = 0; k < tray_n; k++) free(tray_items[k].title), free(tray_items[k].action);
    tray_n = 0;
    for (int k = 0; k < items->n && tray_n < TRAY_MOST; k++) {
      const jv *it = &items->at[k];
      if (it->kind != 'o') continue;
      memset(&tray_items[tray_n], 0, sizeof tray_items[0]);
      const jv *sep = jget(it, "separator");
      tray_items[tray_n].separator = sep && sep->kind == 't';
      tray_items[tray_n].title = tray_words(jtext(it, "title"));
      lstrcpynA(tray_items[tray_n].role, jtext(it, "role"), sizeof tray_items[0].role);
      tray_items[tray_n].action = _strdup(jtext(it, "action"));
      tray_n++;
    }
    break;
  }
  jv_free(&menus);
  free(text);
}

// one of the menu's items chosen
static void tray_chose(int i) {
  if (i < 0 || i >= tray_n) return;
  if (!strcmp(tray_items[i].role, "quit")) quit();
  if (!strcmp(tray_items[i].role, "show")) {
    bring_back();
    return;
  }
  const char *a = tray_items[i].action;
  if (!a || !*a) return;
  WCHAR w[128];
  int n = MultiByteToWideChar(CP_UTF8, 0, a, -1, w, 128);
  if (n <= 1) return;
  char b[400];
  size_t o = (size_t)snprintf(b, sizeof b, "{\"menu\":\"");
  o = json_put(b, o, sizeof b - 3, w, n - 1);
  o += (size_t)snprintf(b + o, sizeof b - o, "\"}");
  bring_back();
  say_system(b, o);
}

// what the icon says: clicked (or chosen by the keyboard), the window back; its menu asked for, the app's
static void tray_said(WPARAM wp, LPARAM lp) {
  switch (LOWORD(lp)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
      bring_back();
      break;
    case WM_CONTEXTMENU: {
      if (tray_n == 0) return;
      HMENU m = CreatePopupMenu();
      for (int i = 0; i < tray_n; i++) {
        if (tray_items[i].separator) AppendMenuW(m, MF_SEPARATOR, 0, NULL);
        else AppendMenuW(m, MF_STRING, (UINT_PTR)(i + 1), tray_items[i].title ? tray_items[i].title : L"");
      }
      // (the window in front first, or the menu stays when clicked away from: TrackPopupMenu's own remarks)
      SetForegroundWindow(hwnd);
      int chose = (int)TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                                        GET_X_LPARAM(wp), GET_Y_LPARAM(wp), hwnd, NULL);
      PostMessageW(hwnd, WM_NULL, 0, 0);
      DestroyMenu(m);
      if (chose > 0) tray_chose(chose - 1);
      break;
    }
  }
}

// ---- the network ----

// the way out now: the interface and the address the default route goes from ("": none)
static void network_way(WCHAR *out, size_t cap) {
  SOCKADDR_INET to, from;
  MIB_IPFORWARD_ROW2 route;
  memset(&to, 0, sizeof to);
  to.Ipv4.sin_family = AF_INET;
  to.Ipv4.sin_addr.S_un.S_addr = 0x01010101;  // 1.1.1.1: any address out there (nothing is sent)
  out[0] = 0;
  if (GetBestRoute2(NULL, 0, NULL, &to, 0, &route, &from) != NO_ERROR) return;
  const unsigned char *a = (const unsigned char *)&from.Ipv4.sin_addr;
  _snwprintf(out, cap, L"%lu/%u.%u.%u.%u", (unsigned long)route.InterfaceIndex, a[0], a[1], a[2], a[3]);
  out[cap - 1] = 0;
}

static WCHAR network_was[64];
static int network_seen;

// a route changed (NotifyRouteChange2's, on a thread of its own): looked at on the window's
static void CALLBACK network_changed(PVOID ctx, PMIB_IPFORWARD_ROW2 row, MIB_NOTIFICATION_TYPE type) {
  (void)ctx, (void)row, (void)type;
  if (hwnd) PostMessageW(hwnd, WM_MB_NETWORK, 0, 0);
}

// another way out than the one before (not the first seen, nor none): said
static void network_look(void) {
  WCHAR now[64];
  network_way(now, 64);
  int changed = network_seen && now[0] && wcscmp(now, network_was) != 0;
  if (now[0] || !network_seen) {
    lstrcpynW(network_was, now, 64);
    network_seen = 1;
  }
  if (changed) {
    fprintf(stdout, "win: network now %ls\n", now);
    fflush(stdout);
    say_system("{\"network\":true}", 16);
  }
}

// ---- login auto-launch (@hostapi.auto_launch / set_auto_launch) ----
static void auto_launch_value_name(WCHAR *out, size_t cap) {
  const WCHAR *id = app_id();
  if (id && *id) {
    lstrcpynW(out, id, (int)cap);
    return;
  }
  WCHAR exe[MAX_PATH];
  DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    lstrcpynW(out, L"mbui", (int)cap);
    return;
  }
  const WCHAR *base = wcsrchr(exe, L'\\');
  base = base ? base + 1 : exe;
  lstrcpynW(out, base, (int)cap);
}

int32_t mb_host_auto_launch(void) {
  WCHAR name[256];
  auto_launch_value_name(name, 256);
  HKEY key = NULL;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return 0;
  }
  WCHAR val[MAX_PATH + 32];
  DWORD type = 0, sz = sizeof val;
  LSTATUS st = RegQueryValueExW(key, name, NULL, &type, (LPBYTE)val, &sz);
  RegCloseKey(key);
  return (st == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ) && sz >= sizeof(WCHAR) && val[0] != 0) ? 1
                                                                                                                  : 0;
}

int32_t mb_host_set_auto_launch(int32_t enabled) {
  WCHAR name[256];
  auto_launch_value_name(name, 256);
  HKEY key = NULL;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, NULL, 0,
                      KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) {
    return 0;
  }
  LSTATUS st;
  if (enabled) {
    WCHAR exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
      RegCloseKey(key);
      return 0;
    }
    WCHAR cmd[MAX_PATH + 8];
    _snwprintf(cmd, MAX_PATH + 8, L"\"%ls\"", exe);
    cmd[MAX_PATH + 7] = 0;
    st = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)cmd, (DWORD)((wcslen(cmd) + 1) * sizeof(WCHAR)));
  } else {
    st = RegDeleteValueW(key, name);
    if (st == ERROR_FILE_NOT_FOUND) st = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return st == ERROR_SUCCESS ? 1 : 0;
}

// ---- global hotkeys (@hostapi.hotkey_set / hotkey_clear) ----
#define MB_WIN_HOTKEY_MAX 64
typedef struct {
  int used;
  int num_id;
  char *id;
} mb_win_hotkey;

static mb_win_hotkey win_hotkeys[MB_WIN_HOTKEY_MAX];
static int win_hotkey_next_id = 0x4D00;

static void hotkeys_clear_all(void) {
  for (int i = 0; i < MB_WIN_HOTKEY_MAX; i++) {
    if (win_hotkeys[i].used) {
      if (hwnd) UnregisterHotKey(hwnd, win_hotkeys[i].num_id);
      free(win_hotkeys[i].id);
      memset(&win_hotkeys[i], 0, sizeof win_hotkeys[i]);
    }
  }
}

static void hotkey_fired(int num_id) {
  for (int i = 0; i < MB_WIN_HOTKEY_MAX; i++) {
    if (win_hotkeys[i].used && win_hotkeys[i].num_id == num_id && win_hotkeys[i].id) {
      WCHAR w[256];
      int n = MultiByteToWideChar(CP_UTF8, 0, win_hotkeys[i].id, -1, w, 256);
      if (n <= 1) return;
      char b[600];
      size_t o = (size_t)snprintf(b, sizeof b, "{\"id\":\"");
      o = json_put(b, o, sizeof b - 3, w, n - 1);
      o += (size_t)snprintf(b + o, sizeof b - o, "\"}");
      mb_post("mbui.hotkey", b, o, NULL, 0);
      return;
    }
  }
}

static char *mb_win_utf8_from_mbt(moonbit_string_t s) {
  int n = Moonbit_array_length(s);
  int u = WideCharToMultiByte(CP_UTF8, 0, (LPCWCH)s, n, NULL, 0, NULL, NULL);
  char *out = (char *)malloc((size_t)u + 1);
  if (!out) return NULL;
  if (u > 0) WideCharToMultiByte(CP_UTF8, 0, (LPCWCH)s, n, out, u, NULL, NULL);
  out[u] = 0;
  return out;
}

int32_t mb_host_hotkey_set(moonbit_string_t id_s, moonbit_string_t accel_s) {
  if (!hwnd) return 0;
  char *id_c = mb_win_utf8_from_mbt(id_s);
  char *accel_c = mb_win_utf8_from_mbt(accel_s);
  if (!id_c || !accel_c || !*id_c || !*accel_c) {
    free(id_c);
    free(accel_c);
    return 0;
  }
  mb_hotkey_spec spec;
  int ok = mb_hotkey_parse(accel_c, 0, &spec);
  free(accel_c);
  if (!ok) {
    free(id_c);
    return 0;
  }
  int vk = mb_hotkey_win_vk(spec.key);
  UINT mods = (UINT)mb_hotkey_win_mods(spec.mods);
  if (vk < 0 || mods == 0) {
    free(id_c);
    return 0;
  }
  int slot = -1;
  for (int i = 0; i < MB_WIN_HOTKEY_MAX; i++) {
    if (win_hotkeys[i].used && win_hotkeys[i].id && strcmp(win_hotkeys[i].id, id_c) == 0) {
      UnregisterHotKey(hwnd, win_hotkeys[i].num_id);
      free(win_hotkeys[i].id);
      memset(&win_hotkeys[i], 0, sizeof win_hotkeys[i]);
      slot = i;
      break;
    }
    if (!win_hotkeys[i].used && slot < 0) slot = i;
  }
  if (slot < 0) {
    free(id_c);
    return 0;
  }
  int num_id = win_hotkey_next_id++;
  if (win_hotkey_next_id >= 0xBFFF) win_hotkey_next_id = 0x4D00;
  if (!RegisterHotKey(hwnd, num_id, mods, (UINT)vk)) {
    free(id_c);
    return 0;
  }
  win_hotkeys[slot].used = 1;
  win_hotkeys[slot].num_id = num_id;
  win_hotkeys[slot].id = id_c;
  return 1;
}

void mb_host_hotkey_clear(moonbit_string_t id_s) {
  char *id_c = mb_win_utf8_from_mbt(id_s);
  if (!id_c || !*id_c) {
    free(id_c);
    return;
  }
  for (int i = 0; i < MB_WIN_HOTKEY_MAX; i++) {
    if (win_hotkeys[i].used && win_hotkeys[i].id && strcmp(win_hotkeys[i].id, id_c) == 0) {
      if (hwnd) UnregisterHotKey(hwnd, win_hotkeys[i].num_id);
      free(win_hotkeys[i].id);
      memset(&win_hotkeys[i], 0, sizeof win_hotkeys[i]);
      break;
    }
  }
  free(id_c);
}

// ---- as the window is made, and what it is told ----

// once the window is there: its icon in the notification area, the one started again told it may hand over, the
// network watched, the link it was started with to the app, what it is now
static void life_start(const WCHAR *title) {
  window_ends_with_opener();
  window_title = _wcsdup(title);
  taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  tray_put();
  atexit(tray_gone);
  atexit(hotkeys_clear_all);
  if (window_up) SetEvent(window_up);
  HANDLE watch = NULL;
  network_look();
  NotifyRouteChange2(AF_UNSPEC, network_changed, NULL, FALSE, &watch);
  links_claimed();
  const WCHAR *link = started_with();
  if (link) say_link(link, (int)wcslen(link));
  title_dark();
  tell_state();
}

// the window's messages of the app's life: 1 when taken (*r its answer)
static int life_message(UINT msg, WPARAM wp, LPARAM lp, LRESULT *r) {
  if (taskbar_created && msg == taskbar_created) {
    tray_put();
    return 0;
  }
  switch (msg) {
    case WM_CLOSE:
      if (!put_away()) return 0;
      *r = 0;
      return 1;
    case WM_COPYDATA:
      *r = life_handed((const COPYDATASTRUCT *)lp);
      return 1;
    case WM_MB_TRAY:
      tray_said(wp, lp);
      *r = 0;
      return 1;
    case WM_HOTKEY:
      hotkey_fired((int)wp);
      *r = 0;
      return 1;
    case WM_MB_NETWORK:
      network_look();
      *r = 0;
      return 1;
    case WM_ACTIVATE:
    case WM_ACTIVATEAPP:
    case WM_SHOWWINDOW:
    case WM_SIZE:
      // (told after the window has it: what IsWindowVisible, IsIconic and the foreground say then)
      PostMessageW(hwnd, WM_MB_STATE, 0, 0);
      return 0;
    case WM_MB_STATE:
      tell_state();
      *r = 0;
      return 1;
    // the app quits on its own thread (win_update.h: the installer of a newer build run)
    case WM_MB_QUIT:
      quit();
      return 1;
    // a notification tapped (win_notify.cpp): the window back, what it opens the app's next frame's
    case WM_MB_TAPPED:
      bring_back();
      *r = 0;
      return 1;
    case WM_SETTINGCHANGE:
      if (lp && !wcscmp((const WCHAR *)lp, L"ImmersiveColorSet")) {
        read_dark();
        ws->want_frame = 1;
      } else if (wp == SPI_SETSCREENREADER || wp == SPI_SETHIGHCONTRAST) {
        win_sr_invalidate();
        mb_host_request_frame();
      }
      return 0;
    case WM_POWERBROADCAST:
      if (wp == PBT_APMSUSPEND) asleep_at = GetTickCount64();
      // (a sleep whose start was not seen taken as a minute's, as the Mac's)
      if (wp == PBT_APMRESUMEAUTOMATIC) {
        say_shown(asleep_at ? asleep_at : GetTickCount64() - 60000);
        asleep_at = 0;
      }
      return 0;
    case WM_ENDSESSION:
      if (wp) quit();
      return 0;
  }
  return 0;
}
