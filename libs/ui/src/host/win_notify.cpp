// Notifications on Windows (src/hostapi/notify.mbt), as mac_app.m has them: the system's toasts (ToastNotificationManager,
// WinRT through its ABI and WRL, nothing packaged) where the program is an app (its identity, MBUI_APP_ID: win_life.h),
// one per tag (a newer one with the same tag takes its place in the system's list too), tapped it brings the app to
// the front with what it was shown with (its Activated, on a thread of the system's: what it opens kept for the app's
// next frame, the window brought back on its own thread: WM_MB_TAPPED). A program without one keeps them only. Either
// way each is kept (one per tag) and said on the log (NOTICE <tag>\t<title>\t<body>), and a scripted run taps one by
// its words (mb_notice_drive: drive 6), which gives the app what it opens as a tap would, or looks for one (7).
//
// An app outside a package shows toasts under its AppUserModelID (the process's: win_life.h life_identity) once the
// system knows that id's name and icon: HKCU\Software\Classes\AppUserModelId\<id> (DisplayName, IconUri), written on
// the dedicated WinRT worker thread, the icon the program's own (its resource 1's largest picture, a PNG: written beside
// its data). What the system allows: its settings for the app (the notifier's Setting), queried asynchronously on the
// worker thread (5 pending until the first refresh lands, then 1/2/0); nothing to ask (Windows asks no app).
//
// The number on the app's taskbar buttons (@hostapi.set_badge, what waits for the person: a Mac's Dock tile's badge):
// Windows draws none of an app's own, so it is an overlay icon over each taskbar button (ITaskbarList3::SetOverlayIcon),
// rendered and applied on a dedicated STA thread (GDI+ + Shell COM) so the UI thread never blocks on Shell IPC. Put on
// again each time the taskbar makes a button anew (TaskbarButtonCreated) and rescaled on WM_DPICHANGED.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <objidl.h>
#include <gdiplus.h>
#include <roapi.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.ui.notifications.h>
#include <windows.data.xml.dom.h>
#include <stdio.h>
#include <string>
#include <vector>
#include "win.h"
#include "win_badge_sched.h"
#include "win_notify_queue.h"

#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

using namespace Microsoft::WRL;
using namespace Microsoft::WRL::Wrappers;
using namespace ABI::Windows::Data::Xml::Dom;
using namespace ABI::Windows::Foundation;
using namespace ABI::Windows::UI::Notifications;

namespace {

// UI-thread-only in-memory notification list (no WinRT/COM objects held here).
struct Notice {
  std::wstring tag, title, body, opens;
};

std::vector<Notice> notices;
SRWLOCK opened_lock = SRWLOCK_INIT;
// Heap-allocated and intentionally never destroyed so exit(0) never races Activated callbacks on static teardown.
std::wstring *opened_str = NULL;  // what the last one tapped opens, till the app takes it
const wchar_t *const group = L"mbui";

std::wstring wide(moonbit_string_t s) { return std::wstring((const wchar_t *)s, (size_t)Moonbit_array_length(s)); }

moonbit_string_t of(const std::wstring &s) {
  moonbit_string_t out = moonbit_make_string_raw((int32_t)s.size());
  if (!s.empty()) memcpy(out, s.data(), s.size() * sizeof(wchar_t));
  return out;
}

std::string utf8(const std::wstring &w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), NULL, 0, NULL, NULL);
  std::string s((size_t)n, '\0');
  if (n) WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, NULL, NULL);
  return s;
}

// a tag as the system takes it (at most 64 characters): its FNV-1a 64's hex
std::wstring system_tag(const std::wstring &tag) {
  unsigned long long h = 1469598103934665603ull;
  for (wchar_t c : tag) {
    h ^= (unsigned long long)c;
    h *= 1099511628211ull;
  }
  wchar_t b[17];
  _snwprintf(b, 17, L"%016llx", h);
  b[16] = 0;
  return b;
}

std::wstring xml_escaped(const std::wstring &s) {
  std::wstring o;
  for (wchar_t c : s) {
    switch (c) {
      case L'&': o += L"&amp;"; break;
      case L'<': o += L"&lt;"; break;
      case L'>': o += L"&gt;"; break;
      case L'"': o += L"&quot;"; break;
      case L'\'': o += L"&apos;"; break;
      default:
        // (control characters but a line's end are not XML's)
        if (c >= 0x20 || c == L'\n' || c == L'\t') o += c;
    }
  }
  return o;
}

// the program's own icon's largest picture (its group 1's entries: PNGs, still.fail's scripts/win.sh), as a file
// beside the app's data the system can read: its path, "" none
std::wstring own_icon_file(const std::wstring &id) {
  HMODULE m = GetModuleHandleW(NULL);
  HRSRC g = FindResourceW(m, MAKEINTRESOURCEW(1), MAKEINTRESOURCEW(14));  // RT_GROUP_ICON
  const BYTE *dir = g ? (const BYTE *)LockResource(LoadResource(m, g)) : NULL;
  if (!dir) return L"";
  // GRPICONDIR: reserved, type, count; then 14-byte entries (width, height, colours, reserved, planes, bits, size, id)
  int count = dir[4] | dir[5] << 8, best = -1, best_w = -1;
  for (int i = 0; i < count; i++) {
    const BYTE *e = dir + 6 + 14 * i;
    int w = e[0] ? e[0] : 256;
    if (w > best_w) best_w = w, best = e[12] | e[13] << 8;
  }
  HRSRC r = best >= 0 ? FindResourceW(m, MAKEINTRESOURCEW(best), MAKEINTRESOURCEW(3))  /* RT_ICON */ : NULL;
  const BYTE *png = r ? (const BYTE *)LockResource(LoadResource(m, r)) : NULL;
  DWORD n = r ? SizeofResource(m, r) : 0;
  if (!png || n < 8 || memcmp(png, "\x89PNG", 4) != 0) return L"";
  PWSTR local = NULL;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, NULL, &local))) return L"";
  std::wstring dirpath = std::wstring(local) + L"\\" + id;
  CoTaskMemFree(local);
  SHCreateDirectoryExW(NULL, dirpath.c_str(), NULL);
  std::wstring path = dirpath + L"\\notice-icon.png";
  HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return L"";
  DWORD put = 0;
  BOOL ok = WriteFile(f, png, n, &put, NULL) && put == n;
  CloseHandle(f);
  return ok ? path : L"";
}

// the system told the app's name and icon for its id (what an app outside a package shows toasts with)
void register_id(const std::wstring &id, const std::wstring &name) {
  std::wstring key = L"Software\\Classes\\AppUserModelId\\" + id;
  HKEY k = NULL;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS) return;
  std::wstring shown = name.empty() ? id : name;
  RegSetValueExW(k, L"DisplayName", 0, REG_SZ, (const BYTE *)shown.c_str(), (DWORD)((shown.size() + 1) * sizeof(wchar_t)));
  std::wstring icon = own_icon_file(id);
  if (!icon.empty())
    RegSetValueExW(k, L"IconUri", 0, REG_SZ, (const BYTE *)icon.c_str(), (DWORD)((icon.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(k);
}

// a tap: what it opens kept for the app, the window brought back on its own thread
void tapped(const std::wstring &tag, const std::wstring &opens) {
  AcquireSRWLockExclusive(&opened_lock);
  if (!opened_str) opened_str = new std::wstring();
  *opened_str = opens;
  ReleaseSRWLockExclusive(&opened_lock);
  fprintf(stdout, "NOTICE TAP %s\n", utf8(tag).c_str());
  fflush(stdout);
  PostMessageW((HWND)mb_app_hwnd(), WM_MB_TAPPED, 0, 0);
  mb_app_wake();
}

void forget(const std::wstring &tag) {
  for (size_t i = 0; i < notices.size(); i++)
    if (notices[i].tag == tag) {
      notices.erase(notices.begin() + (long)i);
      return;
    }
}

struct WinNoticeOps {
  using ToastHandle = ComPtr<IToastNotification>;
  using Token = EventRegistrationToken;

  int toasts = -1;  // -1 not tried yet, 0 unavailable, 1 ready
  ComPtr<IToastNotifier> notifier;
  ComPtr<IToastNotificationHistory> history;
  // Populated on the UI thread in mb_win_notify_start() before spawning the worker thread.
  std::wstring aumid;
  std::wstring app_name;

  bool ensure_ready() {
    if (toasts >= 0) return toasts == 1;
    toasts = 0;
    if (aumid.empty()) return false;
    register_id(aumid, app_name);
    ComPtr<IToastNotificationManagerStatics> mgr;
    if (FAILED(::Windows::Foundation::GetActivationFactory(
            HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(), &mgr)))
      return false;
    if (FAILED(mgr->CreateToastNotifierWithId(HStringReference(aumid.c_str()).Get(), &notifier))) return false;
    ComPtr<IToastNotificationManagerStatics2> mgr2;
    if (SUCCEEDED(mgr.As(&mgr2))) mgr2->get_History(&history);
    toasts = 1;
    return true;
  }

  int32_t query_setting() {
    if (!notifier) return 0;
    NotificationSetting s = NotificationSetting_Enabled;
    if (FAILED(notifier->get_Setting(&s))) return 0;
    return s == NotificationSetting_Enabled ? 1 : 2;
  }

  ComPtr<IToastNotification> toast_of(const std::wstring &tag, const std::wstring &title, const std::wstring &body) {
    std::wstring xml = L"<toast><visual><binding template=\"ToastGeneric\"><text>" + xml_escaped(title) +
                       L"</text><text>" + xml_escaped(body) + L"</text></binding></visual></toast>";
    ComPtr<IInspectable> made;
    ComPtr<IXmlDocument> doc;
    ComPtr<IXmlDocumentIO> io;
    if (FAILED(RoActivateInstance(HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(), &made)) ||
        FAILED(made.As(&doc)) || FAILED(made.As(&io)) || FAILED(io->LoadXml(HStringReference(xml.c_str()).Get())))
      return nullptr;
    ComPtr<IToastNotificationFactory> factory;
    ComPtr<IToastNotification> toast;
    if (FAILED(::Windows::Foundation::GetActivationFactory(
            HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(), &factory)) ||
        FAILED(factory->CreateToastNotification(doc.Get(), &toast)))
      return nullptr;
    ComPtr<IToastNotification2> tagged;
    if (SUCCEEDED(toast.As(&tagged))) {
      tagged->put_Tag(HStringReference(system_tag(tag).c_str()).Get());
      tagged->put_Group(HStringReference(group).Get());
    }
    return toast;
  }

  bool show_toast(const std::wstring &tag, const std::wstring &title, const std::wstring &body,
                  const std::wstring &opens, ToastHandle &out_toast, Token &out_token, bool &out_subscribed) {
    ComPtr<IToastNotification> toast = toast_of(tag, title, body);
    if (!toast) return false;
    std::wstring t = tag, o = opens;
    HRESULT sub = toast->add_Activated(Callback<ITypedEventHandler<ToastNotification *, IInspectable *>>(
                                           [t, o](IToastNotification *, IInspectable *) -> HRESULT {
                                             tapped(t, o);
                                             return S_OK;
                                           })
                                           .Get(),
                                       &out_token);
    out_subscribed = SUCCEEDED(sub);
    HRESULT shown = notifier->Show(toast.Get());
    fprintf(stdout, SUCCEEDED(shown) ? "NOTICE shown by the system\n" : "NOTICE not shown by the system (%08lx)\n",
            (unsigned long)shown);
    fflush(stdout);
    if (FAILED(shown)) {
      if (out_subscribed) toast->remove_Activated(out_token);
      return false;
    }
    out_toast = toast;
    return true;
  }

  void revoke_activated(ToastHandle &toast, Token token) {
    if (toast) toast->remove_Activated(token);
  }

  void remove_history(const std::wstring &tag) {
    if (toasts == 1 && history) {
      history->RemoveGroupedTagWithId(HStringReference(system_tag(tag).c_str()).Get(), HStringReference(group).Get(),
                                      HStringReference(aumid.c_str()).Get());
    }
  }

  void wake() { mb_app_wake(); }
};

// Heap-allocated and intentionally never destroyed so exit(0) never tears down worker state mid-flight.
struct NoticeWorker {
  mb::WinNoticeQueue<WinNoticeOps> queue{5};
  WinNoticeOps ops;
  HANDLE wake_ev = NULL;
  HANDLE thread = NULL;
  bool started = false;
};

NoticeWorker *notice_worker = NULL;

DWORD WINAPI notice_worker_proc(LPVOID arg) {
  NoticeWorker *w = static_cast<NoticeWorker *>(arg);
  HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
  if (FAILED(hr)) {
    fprintf(stderr, "NOTICE worker RoInitialize failed (%08lx)\n", (unsigned long)hr);
    fflush(stderr);
    w->queue.on_init_failed(w->ops);
    return 0;
  }
  for (;;) {
    w->queue.drain(w->ops);
    WaitForSingleObject(w->wake_ev, INFINITE);
  }
}

NoticeWorker *get_notice_worker() {
  if (!notice_worker) notice_worker = new NoticeWorker();
  return notice_worker;
}

bool has_app_id() {
  const wchar_t *id = mb_win_app_id();
  return id && *id;
}

}  // namespace

extern "C" {

void mb_win_notify_start(void) {
  NoticeWorker *w = get_notice_worker();
  if (w->started) return;
  w->started = true;
  const wchar_t *id = mb_win_app_id();
  if (!id || !*id) {
    w->queue.set_initial_setting(0);
    return;
  }
  const wchar_t *name = mb_win_app_name();
  w->ops.aumid = id;
  w->ops.app_name = name ? name : L"";
  w->queue.set_initial_setting(5);
  w->queue.request_refresh();
  w->wake_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  if (!w->wake_ev) {
    fprintf(stderr, "NOTICE worker CreateEventW failed (%lu)\n", (unsigned long)GetLastError());
    fflush(stderr);
    w->queue.on_init_failed(w->ops);
    return;
  }
  w->thread = CreateThread(NULL, 0, notice_worker_proc, w, 0, NULL);
  if (!w->thread) {
    fprintf(stderr, "NOTICE worker CreateThread failed (%lu)\n", (unsigned long)GetLastError());
    fflush(stderr);
    CloseHandle(w->wake_ev);
    w->wake_ev = NULL;
    w->queue.on_init_failed(w->ops);
    return;
  }
  SetEvent(w->wake_ev);
}

void mb_win_notify_refresh(void) {
  if (!has_app_id()) return;
  NoticeWorker *w = get_notice_worker();
  if (!w->started) {
    mb_win_notify_start();
    return;
  }
  w->queue.request_refresh();
  if (w->wake_ev) SetEvent(w->wake_ev);
}

void mb_host_notice_show(moonbit_string_t channel, moonbit_string_t tag, moonbit_string_t title, moonbit_string_t body,
                         moonbit_string_t opens) {
  (void)channel;  // (one list per app: Windows has no channels of an app's)
  Notice n{wide(tag), wide(title), wide(body), wide(opens)};
  forget(n.tag);
  fprintf(stdout, "NOTICE %s\t%s\t%s\n", utf8(n.tag).c_str(), utf8(n.title).c_str(), utf8(n.body).c_str());
  fflush(stdout);
  if (has_app_id()) {
    mb_win_notify_start();
    NoticeWorker *w = get_notice_worker();
    w->queue.enqueue_show(n.tag, n.title, n.body, n.opens);
    if (w->wake_ev) SetEvent(w->wake_ev);
  }
  notices.push_back(std::move(n));
}

// The system's own bars (@hostapi.nav_bar): none here, the app draws its own.
int32_t mb_host_nav_bar(moonbit_string_t spec) {
  (void)spec;
  return 0;
}

int32_t mb_host_nav_able(void) { return 0; }

void mb_host_notice_cancel(moonbit_string_t tag_s) {
  std::wstring tag = wide(tag_s);
  forget(tag);
  if (has_app_id()) {
    mb_win_notify_start();
    NoticeWorker *w = get_notice_worker();
    w->queue.enqueue_cancel(tag);
    if (w->wake_ev) SetEvent(w->wake_ev);
  }
}

int32_t mb_host_notice_state(int32_t what) {
  switch (what) {
    // what the system allows: 5 pending until the first async refresh completes, then 1 granted / 2 denied / 0 unknown
    case 0: {
      if (!notice_worker || !notice_worker->started) return has_app_id() ? 5 : 0;
      return notice_worker->queue.setting();
    }
    // (nothing to ask on Windows: no answer)
    case 1: return 0;
    case 2: return -1;
    // the system's settings of notifications opened
    case 3: return (INT_PTR)ShellExecuteW(NULL, L"open", L"ms-settings:notifications", NULL, NULL, SW_SHOWNORMAL) > 32 ? 1 : 0;
    // the number on the app's icon: not shown here (the taskbar's overlay is not drawn)
    default: return 0;
  }
}

moonbit_string_t mb_host_notice_text(int32_t what) {
  if (what != 0) return moonbit_make_string_raw(0);  // (no push service here)
  AcquireSRWLockExclusive(&opened_lock);
  std::wstring o;
  if (opened_str) {
    o = *opened_str;
    opened_str->clear();
  }
  ReleaseSRWLockExclusive(&opened_lock);
  return of(o);
}

// A scripted run's: the one whose title or words hold `text` tapped (1 when there is one), or only looked for.
int32_t mb_notice_drive(int32_t tap, const wchar_t *text) {
  for (size_t i = 0; i < notices.size(); i++) {
    const Notice &n = notices[i];
    if (n.title.find(text) == std::wstring::npos && n.body.find(text) == std::wstring::npos) continue;
    if (tap) {
      std::wstring tag = n.tag, opens = n.opens;
      if (has_app_id()) {
        mb_win_notify_start();
        NoticeWorker *w = get_notice_worker();
        w->queue.enqueue_cancel(tag);
        if (w->wake_ev) SetEvent(w->wake_ev);
      }
      forget(tag);
      tapped(tag, opens);
    }
    return 1;
  }
  return 0;
}

}  // extern "C"

// ---- the number on the taskbar button ----

namespace {

struct WinBadgeOps {
  using IconHandle = HICON;

  ComPtr<ITaskbarList3> taskbar;
  ULONG_PTR gdiplus_token = 0;

  bool is_window(uintptr_t hwnd) { return hwnd != 0 && IsWindow((HWND)hwnd) != FALSE; }

  // the number drawn `px` square: round, red, its figures white and bold, as large as they fit
  HICON render_icon(int n, int px) {
    if (!gdiplus_token) {
      Gdiplus::GdiplusStartupInput in;
      if (Gdiplus::GdiplusStartup(&gdiplus_token, &in, NULL) != Gdiplus::Ok) return NULL;
    }
    HICON icon = NULL;
    {
      Gdiplus::Bitmap bmp(px, px, PixelFormat32bppARGB);
      Gdiplus::Graphics g(&bmp);
      g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
      g.Clear(Gdiplus::Color(0, 0, 0, 0));
      Gdiplus::SolidBrush red(Gdiplus::Color(255, 0xE5, 0x48, 0x4D));
      g.FillEllipse(&red, 0.0f, 0.0f, (Gdiplus::REAL)px, (Gdiplus::REAL)px);
      std::wstring figures = n > 99 ? L"99+" : std::to_wstring(n);
      Gdiplus::REAL size = px * (figures.size() == 1 ? 0.66f : figures.size() == 2 ? 0.52f : 0.4f);
      Gdiplus::FontFamily face(L"Segoe UI");
      Gdiplus::Font font(&face, size, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      Gdiplus::StringFormat at;
      at.SetAlignment(Gdiplus::StringAlignmentCenter);
      at.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
      g.DrawString(figures.c_str(), -1, &font, Gdiplus::RectF(0.0f, 0.0f, (Gdiplus::REAL)px, (Gdiplus::REAL)px), &at,
                   &white);
      bmp.GetHICON(&icon);
    }
    return icon;
  }

  void destroy_icon(HICON icon) {
    if (icon) DestroyIcon(icon);
  }

  bool set_overlay(uintptr_t hwnd, HICON icon, const wchar_t *desc) {
    if (!taskbar) {
      if (FAILED(CoCreateInstance(CLSID_TaskbarList, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar))) ||
          FAILED(taskbar->HrInit())) {
        taskbar.Reset();
        return false;
      }
    }
    return SUCCEEDED(taskbar->SetOverlayIcon((HWND)hwnd, icon, desc));
  }

  void reset_taskbar() { taskbar.Reset(); }
};

// Heap-allocated and intentionally never destroyed so exit(0) never tears down STA COM state mid-flight.
struct BadgeWorker {
  mb::WinBadgeScheduler<WinBadgeOps> sched;
  WinBadgeOps ops;
  HANDLE wake_ev = NULL;
  HANDLE thread = NULL;
  bool thread_started = false;
};

BadgeWorker *badge_worker = NULL;

DWORD WINAPI badge_worker_proc(LPVOID arg) {
  BadgeWorker *w = static_cast<BadgeWorker *>(arg);
  HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) {
    fprintf(stderr, "BADGE worker CoInitializeEx failed (%08lx)\n", (unsigned long)hr);
    fflush(stderr);
    w->sched.on_init_failed();
    return 0;
  }
  for (;;) {
    w->sched.drain(w->ops);
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    DWORD r = MsgWaitForMultipleObjectsEx(1, &w->wake_ev, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    if (r == WAIT_OBJECT_0 + 1) {
      while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
      }
    }
  }
}

BadgeWorker *get_badge_worker() {
  if (!badge_worker) badge_worker = new BadgeWorker();
  return badge_worker;
}

void wake_badge_worker(BadgeWorker *w) {
  if (!w->thread_started) {
    w->thread_started = true;
    w->wake_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!w->wake_ev) {
      fprintf(stderr, "BADGE worker CreateEventW failed (%lu)\n", (unsigned long)GetLastError());
      fflush(stderr);
      w->sched.on_init_failed();
      return;
    }
    w->thread = CreateThread(NULL, 0, badge_worker_proc, w, 0, NULL);
    if (!w->thread) {
      fprintf(stderr, "BADGE worker CreateThread failed (%lu)\n", (unsigned long)GetLastError());
      fflush(stderr);
      CloseHandle(w->wake_ev);
      w->wake_ev = NULL;
      w->sched.on_init_failed();
      return;
    }
  }
  if (w->wake_ev) SetEvent(w->wake_ev);
}

int badge_px_for_hwnd(HWND h, unsigned dpi_override) {
  UINT dpi = dpi_override ? (UINT)dpi_override : GetDpiForWindow(h);
  return GetSystemMetricsForDpi(SM_CXSMICON, dpi ? dpi : 96);
}

}  // namespace

extern "C" {

void mb_win_badge(void *hwnd, int n) {
  if (!hwnd) return;
  BadgeWorker *w = get_badge_worker();
  int px = n > 0 ? badge_px_for_hwnd((HWND)hwnd, 0) : 0;
  if (w->sched.on_set_badge((uintptr_t)hwnd, n, px)) wake_badge_worker(w);
}

void mb_win_badge_ready(void *hwnd, int n) {
  if (!hwnd) return;
  BadgeWorker *w = get_badge_worker();
  int px = n > 0 ? badge_px_for_hwnd((HWND)hwnd, 0) : 0;
  if (w->sched.on_taskbar_ready((uintptr_t)hwnd, n, px)) wake_badge_worker(w);
}

void mb_win_badge_dpi(void *hwnd, int n, unsigned dpi) {
  if (!hwnd || n <= 0) return;
  BadgeWorker *w = get_badge_worker();
  int px = badge_px_for_hwnd((HWND)hwnd, dpi);
  if (w->sched.on_dpi_changed((uintptr_t)hwnd, n, px)) wake_badge_worker(w);
}

void mb_win_badge_closed(void *hwnd) {
  if (!hwnd || !badge_worker) return;
  if (badge_worker->sched.on_window_closed((uintptr_t)hwnd) && badge_worker->thread_started && badge_worker->wake_ev) {
    SetEvent(badge_worker->wake_ev);
  }
}

}  // extern "C"
