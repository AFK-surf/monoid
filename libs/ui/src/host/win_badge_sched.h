// Platform-independent Windows taskbar badge scheduler state machine.
// Included by win_notify.cpp on Windows and compiled standalone on Linux/macOS for unit tests.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <deque>
#include <mutex>
#include <unordered_map>

namespace mb {

template <typename Ops>
class WinBadgeScheduler {
 public:
  using IconHandle = typename Ops::IconHandle;

  // Worker startup/COM initialization failed: stop accepting work and release pending state.
  void on_init_failed() {
    std::lock_guard<std::mutex> lock(mu_);
    dead_ = true;
    closed_hwnds_.clear();
    stale_hwnds_.clear();
    for (auto &kv : windows_) {
      kv.second.pending = false;
      kv.second.reconcile = false;
    }
  }

  // UI thread: desired badge count and icon pixel size for a window.
  // Returns true if the worker should be woken.
  bool on_set_badge(uintptr_t hwnd, int n, int px) {
    if (!hwnd) return false;
    int clamped = n > 0 ? n : 0;
    std::lock_guard<std::mutex> lock(mu_);
    WindowEntry &e = ensure_entry_locked(hwnd);
    e.desired_n = clamped;
    e.desired_px = px;
    if (!e.ready || dead_) {
      return false;
    }
    e.pending = true;
    e.worker_touched = true;
    return true;
  }

  // UI thread: TaskbarButtonCreated received for hwnd.
  // Unconditionally increments button_gen so any prior Applied or in-flight render is invalidated.
  // Consumes any pending stale-HWND marker from a prior instance's in-flight SetOverlayIcon.
  // Returns true if the worker should be woken.
  bool on_taskbar_ready(uintptr_t hwnd, int n, int px) {
    if (!hwnd) return false;
    int clamped = n > 0 ? n : 0;
    std::lock_guard<std::mutex> lock(mu_);
    WindowEntry &e = ensure_entry_locked(hwnd);
    e.button_gen++;
    e.ready = true;
    e.desired_n = clamped;
    e.desired_px = px;
    auto sit = std::find(stale_hwnds_.begin(), stale_hwnds_.end(), hwnd);
    if (sit != stale_hwnds_.end()) {
      stale_hwnds_.erase(sit);
      e.reconcile = true;
    }
    if (dead_) {
      e.pending = false;
      return false;
    }
    if (clamped > 0 || e.reconcile) {
      e.pending = true;
      e.worker_touched = true;
      return true;
    }
    e.pending = false;
    return false;
  }

  // UI thread: WM_DPICHANGED received for hwnd.
  // Only schedules an update when n > 0 and the taskbar button is ready.
  // Returns true if the worker should be woken.
  bool on_dpi_changed(uintptr_t hwnd, int n, int px) {
    if (!hwnd || n <= 0) return false;
    std::lock_guard<std::mutex> lock(mu_);
    WindowEntry &e = ensure_entry_locked(hwnd);
    e.desired_n = n;
    e.desired_px = px;
    if (!e.ready || dead_) {
      return false;
    }
    e.pending = true;
    e.worker_touched = true;
    return true;
  }

  // UI thread: window closed (WM_DESTROY / win_closed).
  // Removes the window record so any future OS reuse of the same HWND value receives a fresh instance_id.
  // Only records cleanup for the worker when this window ever touched the worker (bounds memory at zero-badge churn).
  bool on_window_closed(uintptr_t hwnd) {
    if (!hwnd) return false;
    std::lock_guard<std::mutex> lock(mu_);
    auto it = windows_.find(hwnd);
    if (it == windows_.end()) {
      return false;
    }
    uint64_t closed_inst = it->second.instance_id;
    bool need_cleanup = it->second.worker_touched;
    windows_.erase(it);
    if (need_cleanup && !dead_) {
      closed_hwnds_[hwnd] = closed_inst;
      return true;
    }
    return false;
  }

  // STA worker thread: drains pending badge updates until none remain.
  // Rendering and Shell calls execute outside the lock.
  void drain(Ops &ops) {
    for (;;) {
      std::unordered_map<uintptr_t, uint64_t> closed;
      bool has_work = false;
      uintptr_t hwnd = 0;
      uint64_t instance_id = 0;
      uint64_t button_gen = 0;
      int n = 0;
      int px = 0;
      bool reconcile = false;

      {
        std::lock_guard<std::mutex> lock(mu_);
        if (!closed_hwnds_.empty()) {
          closed.swap(closed_hwnds_);
        }
        for (auto &kv : windows_) {
          if (kv.second.pending) {
            hwnd = kv.first;
            instance_id = kv.second.instance_id;
            button_gen = kv.second.button_gen;
            n = kv.second.desired_n;
            px = kv.second.desired_px;
            reconcile = kv.second.reconcile;
            // Clear pending, but retain reconcile until SetOverlayIcon succeeds on (instance_id, button_gen).
            kv.second.pending = false;
            has_work = true;
            break;
          }
        }
      }

      for (const auto &kv : closed) {
        auto ait = applied_.find(kv.first);
        if (ait != applied_.end() && ait->second.instance_id <= kv.second) {
          applied_.erase(ait);
        }
      }

      if (!has_work) {
        break;
      }

      if (!ops.is_window(hwnd)) {
        auto ait = applied_.find(hwnd);
        if (ait != applied_.end() && ait->second.instance_id == instance_id) {
          applied_.erase(ait);
        }
        continue;
      }

      if (!reconcile) {
        auto it = applied_.find(hwnd);
        bool same_btn =
            (it != applied_.end() && it->second.instance_id == instance_id && it->second.button_gen == button_gen);
        if (n == 0) {
          if (!same_btn || it->second.n == 0) {
            continue;
          }
        } else if (same_btn && it->second.n == n && it->second.px == px) {
          continue;
        }
      }

      IconHandle icon{};
      if (n > 0) {
        icon = ops.render_icon(n, px);
        if (!icon) {
          // Intentionally retain the previous overlay icon rather than calling SetOverlayIcon(hwnd, NULL, ...),
          // and leave applied_ / reconcile unchanged so a subsequent update can retry.
          continue;
        }
      }

      bool still_valid = false;
      bool superseded = false;
      {
        std::lock_guard<std::mutex> lock(mu_);
        auto wit = windows_.find(hwnd);
        if (wit != windows_.end() && wit->second.instance_id == instance_id && wit->second.ready &&
            wit->second.button_gen == button_gen) {
          still_valid = true;
          superseded = wit->second.pending;
        }
      }

      if (!still_valid) {
        if (icon) {
          ops.destroy_icon(icon);
        }
        auto ait = applied_.find(hwnd);
        if (ait != applied_.end() && ait->second.instance_id == instance_id) {
          applied_.erase(ait);
        }
        continue;
      }

      if (superseded) {
        if (icon) {
          ops.destroy_icon(icon);
        }
        continue;
      }

      wchar_t desc_buf[16];
      const wchar_t *desc = nullptr;
      if (n > 0) {
        std::swprintf(desc_buf, 16, L"%d", n);
        desc = desc_buf;
      }

      bool ok = ops.set_overlay(hwnd, icon, desc);
      if (icon) {
        ops.destroy_icon(icon);
      }

      if (!ok) {
        ops.reset_taskbar();
        continue;
      }

      bool alive_after = (n > 0) ? ops.is_window(hwnd) : false;
      bool record_applied = false;
      {
        std::lock_guard<std::mutex> lock(mu_);
        auto wit = windows_.find(hwnd);
        if (wit != windows_.end() && wit->second.instance_id == instance_id) {
          if (wit->second.button_gen == button_gen) {
            wit->second.reconcile = false;
            record_applied = true;
          } else if (n > 0) {
            // SetOverlayIcon(n > 0) straddled a TaskbarButtonCreated rebuild on the same window instance.
            wit->second.reconcile = true;
            if (!dead_ && wit->second.ready) {
              wit->second.pending = true;
            }
          }
        } else if (wit != windows_.end()) {
          // A new window instance already reused this HWND while SetOverlayIcon(n > 0) was in flight.
          if (n > 0) {
            wit->second.reconcile = true;
            if (!dead_ && wit->second.ready) {
              wit->second.pending = true;
              wit->second.worker_touched = true;
            }
          }
        } else if (n > 0 && !dead_ && alive_after) {
          // Old window closed and HWND is still live (possibly reused before the new window registers).
          if (std::find(stale_hwnds_.begin(), stale_hwnds_.end(), hwnd) == stale_hwnds_.end()) {
            if (stale_hwnds_.size() >= kMaxStaleHwnds) {
              stale_hwnds_.pop_front();
            }
            stale_hwnds_.push_back(hwnd);
          }
        }
      }

      if (record_applied) {
        applied_[hwnd] = Applied{instance_id, button_gen, n, px};
      } else {
        auto ait = applied_.find(hwnd);
        if (ait != applied_.end() && ait->second.instance_id == instance_id) {
          applied_.erase(ait);
        }
      }
    }
  }

  size_t closed_pending_count_for_test() const {
    std::lock_guard<std::mutex> lock(mu_);
    return closed_hwnds_.size();
  }

 private:
  static constexpr size_t kMaxStaleHwnds = 64;

  struct WindowEntry {
    uint64_t instance_id = 0;
    uint64_t button_gen = 0;
    bool ready = false;
    int desired_n = 0;
    int desired_px = 0;
    bool pending = false;
    bool worker_touched = false;
    bool reconcile = false;
  };

  struct Applied {
    uint64_t instance_id = 0;
    uint64_t button_gen = 0;
    int n = 0;
    int px = 0;
  };

  WindowEntry &ensure_entry_locked(uintptr_t hwnd) {
    auto it = windows_.find(hwnd);
    if (it != windows_.end()) {
      return it->second;
    }
    WindowEntry &e = windows_[hwnd];
    e.instance_id = next_instance_id_++;
    return e;
  }

  mutable std::mutex mu_;
  bool dead_ = false;
  uint64_t next_instance_id_ = 1;
  std::unordered_map<uintptr_t, WindowEntry> windows_;
  std::unordered_map<uintptr_t, uint64_t> closed_hwnds_;
  std::deque<uintptr_t> stale_hwnds_;
  // Worker-thread-only state.
  std::unordered_map<uintptr_t, Applied> applied_;
};

}  // namespace mb
