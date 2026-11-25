// Deterministic C++17 unit tests for Windows notification queue (win_notify_queue.h)
// and taskbar badge scheduler (win_badge_sched.h).
// Build & run on Linux/macOS:
//   c++ -std=c++17 -Wall -Wextra -Werror -pthread -I libs/ui/src/host libs/ui/scripts/win_notify_test.cpp -o win_notify_test && ./win_notify_test

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "win_badge_sched.h"
#include "win_notify_queue.h"

namespace {

int g_failed = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::fprintf(stderr, "%s:%d: FAILED: %s\n", __FILE__, __LINE__, #cond); \
      g_failed = 1;                                                            \
    }                                                                          \
  } while (0)

// ---- Notice Queue Tests ----

struct FakeNoticeOps {
  using ToastHandle = int;
  using Token = int;

  bool ready_result = true;
  int32_t setting_result = 1;
  int next_toast_id = 1;
  int next_token_id = 100;
  int wake_count = 0;
  int ensure_ready_calls = 0;
  int query_setting_calls = 0;
  bool subscribe_on_show = true;
  std::vector<std::string> events;
  std::function<void()> on_query_setting;

  bool ensure_ready() {
    ensure_ready_calls++;
    return ready_result;
  }

  int32_t query_setting() {
    query_setting_calls++;
    if (on_query_setting) {
      auto fn = std::move(on_query_setting);
      on_query_setting = nullptr;
      fn();
    }
    return setting_result;
  }

  bool show_toast(const std::wstring &tag, const std::wstring &title, const std::wstring &body,
                  const std::wstring &opens, ToastHandle &out_toast, Token &out_token, bool &out_subscribed) {
    (void)body;
    (void)opens;
    out_toast = next_toast_id++;
    out_token = subscribe_on_show ? next_token_id++ : 0;
    out_subscribed = subscribe_on_show;
    events.push_back("show:" + narrow(tag) + ":" + narrow(title) + "#" + std::to_string(out_toast));
    return true;
  }

  void revoke_activated(ToastHandle &toast, Token token) {
    events.push_back("revoke:#" + std::to_string(toast) + ":tok=" + std::to_string(token));
    toast = 0;
  }

  void remove_history(const std::wstring &tag) { events.push_back("cancel:" + narrow(tag)); }

  void wake() { wake_count++; }

  static std::string narrow(const std::wstring &w) {
    std::string out;
    out.reserve(w.size());
    for (wchar_t c : w) out.push_back(static_cast<char>(c));
    return out;
  }
};

void test_notice_fifo_and_revoke() {
  mb::WinNoticeQueue<FakeNoticeOps> q(5);
  FakeNoticeOps ops;

  q.enqueue_show(L"chat-1", L"First", L"b1", L"o1");
  q.enqueue_cancel(L"chat-1");
  q.enqueue_show(L"chat-1", L"Second", L"b2", L"o2");
  q.enqueue_show(L"chat-1", L"Third", L"b3", L"o3");
  q.drain(ops);

  std::vector<std::string> expected = {
      "show:chat-1:First#1",
      "revoke:#1:tok=100",
      "cancel:chat-1",
      "show:chat-1:Second#2",
      "revoke:#2:tok=101",
      "show:chat-1:Third#3",
  };
  CHECK(ops.events == expected);
  CHECK(q.active_count_for_test() == 1);

  // Cancel when subscribed == false must not call revoke_activated.
  ops.events.clear();
  ops.subscribe_on_show = false;
  q.enqueue_show(L"chat-2", L"NoSub", L"b", L"o");
  q.enqueue_cancel(L"chat-2");
  q.drain(ops);
  std::vector<std::string> expected_nosub = {
      "show:chat-2:NoSub#4",
      "cancel:chat-2",
  };
  CHECK(ops.events == expected_nosub);
}

void test_notice_refresh_coalesce_and_retrigger() {
  mb::WinNoticeQueue<FakeNoticeOps> q(5);
  FakeNoticeOps ops;
  ops.setting_result = 1;

  // Multiple requests before drain coalesce into one query.
  q.request_refresh();
  q.request_refresh();
  q.request_refresh();
  q.drain(ops);
  CHECK(ops.query_setting_calls == 1);
  CHECK(q.setting() == 1);
  CHECK(ops.wake_count == 1);

  // A new refresh requested while query_setting is running triggers one follow-up refresh.
  ops.setting_result = 2;
  ops.on_query_setting = [&]() {
    q.request_refresh();
    ops.setting_result = 1;
  };
  q.request_refresh();
  q.drain(ops);
  CHECK(ops.query_setting_calls == 3);
  CHECK(q.setting() == 1);
  CHECK(ops.wake_count == 1);  // first pass saw 1 (after callback mutated it), second pass saw 1: no change
}

void test_notice_init_and_query_failure() {
  // Init failure drops 5 -> 0 and wakes once.
  {
    mb::WinNoticeQueue<FakeNoticeOps> q(5);
    FakeNoticeOps ops;
    q.on_init_failed(ops);
    CHECK(q.setting() == 0);
    CHECK(ops.wake_count == 1);
    // Repeated init failure does not double-wake.
    q.on_init_failed(ops);
    CHECK(ops.wake_count == 1);
  }
  // toasts_ready failure during refresh drops 5 -> 0 and wakes.
  {
    mb::WinNoticeQueue<FakeNoticeOps> q(5);
    FakeNoticeOps ops;
    ops.ready_result = false;
    q.request_refresh();
    q.drain(ops);
    CHECK(q.setting() == 0);
    CHECK(ops.wake_count == 1);
  }
  // get_Setting failure (returns 0) drops 5 -> 0 (never 2 denied).
  {
    mb::WinNoticeQueue<FakeNoticeOps> q(5);
    FakeNoticeOps ops;
    ops.ready_result = true;
    ops.setting_result = 0;
    q.request_refresh();
    q.drain(ops);
    CHECK(q.setting() == 0);
    CHECK(ops.wake_count == 1);
  }
}

// ---- Badge Scheduler Tests ----

struct FakeBadgeOps {
  using IconHandle = int;  // 0 == NULL, >0 == live icon handle

  struct OverlayCall {
    uintptr_t hwnd;
    int icon;
    std::wstring desc;
  };

  std::set<uintptr_t> valid_hwnds;
  std::set<int> live_icons;
  int next_icon_id = 1;
  int created_icons = 0;
  int destroyed_icons = 0;
  int double_destroys = 0;
  int reset_taskbar_calls = 0;
  bool fail_next_render = false;
  bool fail_next_overlay = false;
  std::vector<OverlayCall> overlay_calls;
  std::function<void(int, int)> on_render;
  std::function<void(uintptr_t, int)> on_set_overlay;

  bool is_window(uintptr_t hwnd) { return valid_hwnds.count(hwnd) > 0; }

  IconHandle render_icon(int n, int px) {
    if (on_render) {
      auto fn = std::move(on_render);
      on_render = nullptr;
      fn(n, px);
    }
    if (fail_next_render) {
      fail_next_render = false;
      return 0;
    }
    int id = next_icon_id++;
    live_icons.insert(id);
    created_icons++;
    return id;
  }

  void destroy_icon(IconHandle icon) {
    if (icon == 0) return;
    auto it = live_icons.find(icon);
    if (it == live_icons.end()) {
      double_destroys++;
      return;
    }
    live_icons.erase(it);
    destroyed_icons++;
  }

  bool set_overlay(uintptr_t hwnd, IconHandle icon, const wchar_t *desc) {
    if (on_set_overlay) {
      auto fn = std::move(on_set_overlay);
      on_set_overlay = nullptr;
      fn(hwnd, icon);
    }
    overlay_calls.push_back(OverlayCall{hwnd, icon, desc ? std::wstring(desc) : std::wstring()});
    if (fail_next_overlay) {
      fail_next_overlay = false;
      return false;
    }
    return true;
  }

  void reset_taskbar() { reset_taskbar_calls++; }

  void assert_icons_balanced() const {
    CHECK(created_icons == destroyed_icons);
    CHECK(live_icons.empty());
    CHECK(double_destroys == 0);
  }
};

void test_badge_before_ready_and_force_replay() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t w1 = 0x1001;
  ops.valid_hwnds.insert(w1);

  // 1. Before TaskbarButtonCreated, nonzero badge does not call Shell.
  CHECK(!sched.on_set_badge(w1, 3, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.empty());
  ops.assert_icons_balanced();

  // TaskbarButtonCreated forces replay.
  CHECK(sched.on_taskbar_ready(w1, 3, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);
  CHECK(ops.overlay_calls[0].hwnd == w1 && ops.overlay_calls[0].icon > 0 && ops.overlay_calls[0].desc == L"3");
  ops.assert_icons_balanced();

  // 2. While force=true is queued, a normal same-value set_badge or DPI event must NOT clear force.
  CHECK(sched.on_taskbar_ready(w1, 3, 16));
  CHECK(sched.on_set_badge(w1, 3, 16));
  CHECK(sched.on_dpi_changed(w1, 3, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 2);
  CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].desc == L"3");
  ops.assert_icons_balanced();
}

void test_badge_multi_window_independent() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t w1 = 0x2001;
  const uintptr_t w2 = 0x2002;
  ops.valid_hwnds.insert(w1);
  ops.valid_hwnds.insert(w2);

  CHECK(!sched.on_taskbar_ready(w1, 0, 16));
  CHECK(!sched.on_taskbar_ready(w2, 0, 24));
  CHECK(sched.on_set_badge(w1, 5, 16));
  CHECK(sched.on_set_badge(w2, 5, 24));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 2);
  std::set<uintptr_t> seen;
  for (const auto &c : ops.overlay_calls) {
    seen.insert(c.hwnd);
    CHECK(c.desc == L"5");
  }
  CHECK(seen.count(w1) == 1 && seen.count(w2) == 1);
  ops.assert_icons_balanced();
}

void test_badge_render_failure_preserves_icon_and_retries() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t w1 = 0x3001;
  ops.valid_hwnds.insert(w1);

  CHECK(sched.on_taskbar_ready(w1, 4, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);

  // Render failure returns NULL: must NOT call SetOverlayIcon(NULL) and must NOT mark applied.
  ops.fail_next_render = true;
  CHECK(sched.on_set_badge(w1, 7, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);
  ops.assert_icons_balanced();

  // Retry with the same value 7 succeeds because applied still holds 4.
  CHECK(sched.on_set_badge(w1, 7, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 2);
  CHECK(ops.overlay_calls[1].desc == L"7");
  ops.assert_icons_balanced();

  // SetOverlayIcon failure resets taskbar and does not mark applied.
  ops.fail_next_overlay = true;
  CHECK(sched.on_set_badge(w1, 8, 16));
  sched.drain(ops);
  CHECK(ops.reset_taskbar_calls == 1);
  CHECK(ops.overlay_calls.size() == 3);
  ops.assert_icons_balanced();

  CHECK(sched.on_set_badge(w1, 8, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 4);
  CHECK(ops.overlay_calls[3].desc == L"8");
  ops.assert_icons_balanced();
}

void test_badge_hwnd_reuse_while_rendering() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t reused_hwnd = 0x4001;
  ops.valid_hwnds.insert(reused_hwnd);

  CHECK(sched.on_taskbar_ready(reused_hwnd, 9, 16));

  // Pause inside render_icon while another thread closes the old window and opens a brand-new window
  // that happens to reuse the exact same numeric HWND.
  std::mutex gate_mu;
  std::condition_variable gate_cv;
  bool in_render = false;
  bool allow_finish = false;

  ops.on_render = [&](int, int) {
    std::unique_lock<std::mutex> lk(gate_mu);
    in_render = true;
    gate_cv.notify_one();
    gate_cv.wait(lk, [&]() { return allow_finish; });
  };

  std::thread worker([&]() { sched.drain(ops); });

  {
    std::unique_lock<std::mutex> lk(gate_mu);
    gate_cv.wait(lk, [&]() { return in_render; });
  }

  // Close old window and open a new window with the same HWND (not yet ready, or ready with a new count).
  CHECK(sched.on_window_closed(reused_hwnd));
  CHECK(!sched.on_set_badge(reused_hwnd, 2, 16));  // new instance_id, ready == false

  {
    std::lock_guard<std::mutex> lk(gate_mu);
    allow_finish = true;
  }
  gate_cv.notify_one();
  worker.join();

  // Old render was discarded without calling SetOverlayIcon and its HICON was destroyed exactly once.
  CHECK(ops.overlay_calls.empty());
  ops.assert_icons_balanced();
  CHECK(ops.created_icons == 1 && ops.destroyed_icons == 1);

  // Now the new window becomes ready: its badge 2 applies cleanly.
  CHECK(sched.on_taskbar_ready(reused_hwnd, 2, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);
  CHECK(ops.overlay_calls[0].hwnd == reused_hwnd && ops.overlay_calls[0].desc == L"2");
  ops.assert_icons_balanced();
}

void test_badge_zero_skip_and_clear() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t w1 = 0x5001;
  ops.valid_hwnds.insert(w1);

  // n == 0 never shown before: skipped completely.
  CHECK(!sched.on_taskbar_ready(w1, 0, 16));
  CHECK(sched.on_set_badge(w1, 0, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.empty());
  ops.assert_icons_balanced();

  // Show 1, then clear to 0.
  CHECK(sched.on_set_badge(w1, 1, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);
  CHECK(ops.overlay_calls[0].desc == L"1");

  CHECK(sched.on_set_badge(w1, 0, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 2);
  CHECK(ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());

  // Repeated 0 after already cleared: skipped.
  CHECK(sched.on_set_badge(w1, 0, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 2);
  ops.assert_icons_balanced();
}

void test_badge_superseded_while_rendering() {
  mb::WinBadgeScheduler<FakeBadgeOps> sched;
  FakeBadgeOps ops;
  const uintptr_t w1 = 0x6001;
  ops.valid_hwnds.insert(w1);

  // First show 3 so applied_ holds 3.
  CHECK(sched.on_taskbar_ready(w1, 3, 16));
  sched.drain(ops);
  CHECK(ops.overlay_calls.size() == 1);
  CHECK(ops.overlay_calls[0].desc == L"3");

  // Request 5, pause inside render_icon, and while paused UI thread clears badge to 0.
  std::mutex gate_mu;
  std::condition_variable gate_cv;
  bool in_render = false;
  bool allow_finish = false;

  ops.on_render = [&](int, int) {
    std::unique_lock<std::mutex> lk(gate_mu);
    in_render = true;
    gate_cv.notify_one();
    gate_cv.wait(lk, [&]() { return allow_finish; });
  };

  CHECK(sched.on_set_badge(w1, 5, 16));
  std::thread worker([&]() { sched.drain(ops); });

  {
    std::unique_lock<std::mutex> lk(gate_mu);
    gate_cv.wait(lk, [&]() { return in_render; });
  }

  CHECK(sched.on_set_badge(w1, 0, 16));

  {
    std::lock_guard<std::mutex> lk(gate_mu);
    allow_finish = true;
  }
  gate_cv.notify_one();
  worker.join();

  // The superseded render for 5 must NOT have called SetOverlayIcon(w1, old_icon); only the clear (0) ran.
  CHECK(ops.overlay_calls.size() == 2);
  CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());
  ops.assert_icons_balanced();
  CHECK(ops.created_icons == 2 && ops.destroyed_icons == 2);
}

void test_badge_rebuild_interleavings() {
  // 1. Opus A / Astra 1: shown 3 -> TaskbarButtonCreated(3) -> same-px DPI or set(5) during render -> new button gets final badge.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7001;
    ops.valid_hwnds.insert(w1);

    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 1 && ops.overlay_calls[0].desc == L"3");

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_render = false;
    bool allow_finish = false;
    ops.on_render = [&](int, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_render = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_render; });
    }
    // Same-px DPI change arrives mid-render (superseding the in-flight render): new button must still get 3.
    CHECK(sched.on_dpi_changed(w1, 3, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();
    CHECK(ops.overlay_calls.size() == 2 && ops.overlay_calls[1].desc == L"3");
    ops.assert_icons_balanced();
  }

  // 2. Opus B & C / Astra 2: shown 4 -> clear(0) unconsumed -> TaskbarButtonCreated(0) -> set(4) -> new button gets 4.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7002;
    ops.valid_hwnds.insert(w1);

    CHECK(sched.on_taskbar_ready(w1, 4, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 1 && ops.overlay_calls[0].desc == L"4");

    CHECK(sched.on_set_badge(w1, 0, 16));
    CHECK(!sched.on_taskbar_ready(w1, 0, 16));  // new button starts empty: no COM call needed
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 1);

    CHECK(sched.on_set_badge(w1, 4, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 2 && ops.overlay_calls[1].desc == L"4");
    ops.assert_icons_balanced();
  }

  // 3. Opus D: shown 3 -> TaskbarButtonCreated(3) -> render fails -> set(3) again -> new button gets 3.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7003;
    ops.valid_hwnds.insert(w1);

    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 1);

    ops.fail_next_render = true;
    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 1);

    CHECK(sched.on_set_badge(w1, 3, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 2 && ops.overlay_calls[1].desc == L"3");
    ops.assert_icons_balanced();
  }

  // 4. Astra 3: render(7) paused -> clear(0) -> TaskbarButtonCreated(0) -> render resumes -> 0 nonzero writes to new button.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7004;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_render = false;
    bool allow_finish = false;
    ops.on_render = [&](int, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_render = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_set_badge(w1, 7, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_render; });
    }
    CHECK(sched.on_set_badge(w1, 0, 16));
    CHECK(!sched.on_taskbar_ready(w1, 0, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(ops.overlay_calls.empty());
    CHECK(ops.created_icons == 1 && ops.destroyed_icons == 1);
    ops.assert_icons_balanced();
  }

  // 5. Astra cross-rebuild Shell call: set_overlay(7) paused -> TaskbarButtonCreated(0) -> set_overlay(7) returns ->
  //    scheduler reconciles the new button by clearing it back to 0.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7005;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_finish = false;
    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_set_badge(w1, 7, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    CHECK(!sched.on_taskbar_ready(w1, 0, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[0].desc == L"7");
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());
    ops.assert_icons_balanced();
  }

  // 5b. set_overlay(3, 16) straddles TaskbarButtonCreated(3, 16) with identical desired_n/desired_px:
  //     must NOT treat live_gen as already applied; must issue a second set_overlay(3, 16) for the new button.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7006;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_finish = false;
    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_set_badge(w1, 3, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[0].desc == L"3");
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon > 0 && ops.overlay_calls[1].desc == L"3");
    ops.assert_icons_balanced();
  }

  // 5c. set_overlay(3, 16) straddles TaskbarButtonCreated(3, 16), then UI clears to 0 before the follow-up drain:
  //     sentinel n == -1 forces an explicit SetOverlayIcon(nullptr) clear so the new button cannot retain stale 3.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7007;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_finish = false;
    bool clear_sent = false;
    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };
    // Pause on the follow-up render for 3 (or intercept before follow-up) by clearing right after on_taskbar_ready(3)
    // while set_overlay is still in flight; when set_overlay returns, desired_n is already 0 and sentinel n==-1 forces clear.
    CHECK(sched.on_set_badge(w1, 3, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    CHECK(sched.on_set_badge(w1, 0, 16));
    clear_sent = true;
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(clear_sent);
    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[0].desc == L"3");
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());
    ops.assert_icons_balanced();
  }

  // 5d. Astra cross-instance HWND reuse while SetOverlayIcon(7) is in flight:
  //     old window closes and a brand-new window reuses the exact same HWND with desired_n == 0 -> must clear.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7008;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_finish = false;
    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_set_badge(w1, 7, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    CHECK(sched.on_window_closed(w1));
    CHECK(!sched.on_taskbar_ready(w1, 0, 16));  // new instance_id with n == 0
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[0].desc == L"7");
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());
    ops.assert_icons_balanced();
  }

  // 5e. Cross-instance HWND reuse where the new window's TaskbarButtonCreated(0) arrives AFTER set_overlay(7) returns:
  //     stale_hwnds_ wakes the worker on on_taskbar_ready(w1, 0, 16) and clears the reused HWND, while an unrelated
  //     fresh zero-badge window w2 stays zero-wake / zero-Shell.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x7009;
    const uintptr_t w2 = 0x700A;
    ops.valid_hwnds.insert(w1);
    ops.valid_hwnds.insert(w2);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_finish = false;
    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_finish; });
    };

    CHECK(sched.on_set_badge(w1, 7, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    // Old window closes while valid_hwnds still contains w1 (OS already reused handle before new window registers).
    CHECK(sched.on_window_closed(w1));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_finish = true;
    }
    gate_cv.notify_one();
    worker.join();
    CHECK(ops.overlay_calls.size() == 1 && ops.overlay_calls[0].desc == L"7");

    // New window on reused w1 becomes ready with 0: stale_hwnds_ triggers reconcile and returns true to wake worker.
    CHECK(sched.on_taskbar_ready(w1, 0, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());

    // Unrelated fresh zero-badge window w2 does NOT wake worker and makes zero Shell calls.
    CHECK(!sched.on_taskbar_ready(w2, 0, 16));
    sched.drain(ops);
    CHECK(ops.overlay_calls.size() == 2);
    ops.assert_icons_balanced();
  }

  // 5f. reconcile survives superseding during follow-up render:
  //     old set_overlay(3) straddles TaskbarButtonCreated(3); during the reconcile render for 3, UI clears to 0 ->
  //     reconcile stays armed and issues an explicit SetOverlayIcon(nullptr) clear.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    FakeBadgeOps ops;
    const uintptr_t w1 = 0x700B;
    ops.valid_hwnds.insert(w1);

    CHECK(!sched.on_taskbar_ready(w1, 0, 16));

    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool in_overlay = false;
    bool allow_overlay = false;
    bool in_reconcile_render = false;
    bool allow_render = false;
    int render_count = 0;

    ops.on_set_overlay = [&](uintptr_t, int) {
      std::unique_lock<std::mutex> lk(gate_mu);
      in_overlay = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_overlay; });
    };

    CHECK(sched.on_set_badge(w1, 3, 16));
    std::thread worker([&]() { sched.drain(ops); });
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_overlay; });
    }
    // Arm on_render hook for the reconcile pass before releasing set_overlay(3).
    ops.on_render = [&](int, int) {
      render_count++;
      std::unique_lock<std::mutex> lk(gate_mu);
      in_reconcile_render = true;
      gate_cv.notify_one();
      gate_cv.wait(lk, [&]() { return allow_render; });
    };
    CHECK(sched.on_taskbar_ready(w1, 3, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_overlay = true;
    }
    gate_cv.notify_one();
    {
      std::unique_lock<std::mutex> lk(gate_mu);
      gate_cv.wait(lk, [&]() { return in_reconcile_render; });
    }
    // Supersede the reconcile render with clear(0): reconcile must stay armed and clear the button.
    CHECK(sched.on_set_badge(w1, 0, 16));
    {
      std::lock_guard<std::mutex> lk(gate_mu);
      allow_render = true;
    }
    gate_cv.notify_one();
    worker.join();

    CHECK(render_count == 1);
    CHECK(ops.overlay_calls.size() == 2);
    CHECK(ops.overlay_calls[0].desc == L"3");
    CHECK(ops.overlay_calls[1].hwnd == w1 && ops.overlay_calls[1].icon == 0 && ops.overlay_calls[1].desc.empty());
    ops.assert_icons_balanced();
  }

  // 6. Astra zero-badge window churn: opening/closing 100 windows with n==0 leaves closed_pending_count == 0.
  {
    mb::WinBadgeScheduler<FakeBadgeOps> sched;
    for (uintptr_t i = 1; i <= 100; i++) {
      uintptr_t h = 0x8000 + i;
      CHECK(!sched.on_taskbar_ready(h, 0, 16));
      CHECK(!sched.on_window_closed(h));
    }
    CHECK(sched.closed_pending_count_for_test() == 0);
  }
}

void test_notice_dead_queue_rejects_after_init_failed() {
  mb::WinNoticeQueue<FakeNoticeOps> q(5);
  FakeNoticeOps ops;
  q.enqueue_show(L"a", L"t", L"b", L"o");
  CHECK(q.queued_count_for_test() == 1);
  q.on_init_failed(ops);
  CHECK(q.setting() == 0);
  CHECK(q.queued_count_for_test() == 0);
  q.enqueue_show(L"b", L"t", L"b", L"o");
  q.enqueue_cancel(L"a");
  q.request_refresh();
  CHECK(q.queued_count_for_test() == 0);
}

}  // namespace

int main() {
  test_notice_fifo_and_revoke();
  test_notice_refresh_coalesce_and_retrigger();
  test_notice_init_and_query_failure();
  test_notice_dead_queue_rejects_after_init_failed();
  test_badge_before_ready_and_force_replay();
  test_badge_multi_window_independent();
  test_badge_render_failure_preserves_icon_and_retries();
  test_badge_hwnd_reuse_while_rendering();
  test_badge_zero_skip_and_clear();
  test_badge_superseded_while_rendering();
  test_badge_rebuild_interleavings();

  if (!g_failed) {
    std::printf("win_notify_test: ok\n");
  }
  return g_failed;
}
