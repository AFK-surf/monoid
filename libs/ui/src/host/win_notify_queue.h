// Platform-independent Windows toast notification queue and permission state machine.
// Included by win_notify.cpp on Windows and compiled standalone on Linux/macOS for unit tests.
#pragma once

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

namespace mb {

enum class WinNoticeOpKind {
  Show,
  Cancel,
};

struct WinNoticeOp {
  WinNoticeOpKind kind;
  std::wstring tag;
  std::wstring title;
  std::wstring body;
  std::wstring opens;
};

template <typename Ops>
class WinNoticeQueue {
 public:
  using ToastHandle = typename Ops::ToastHandle;
  using Token = typename Ops::Token;

  explicit WinNoticeQueue(int32_t initial_setting = 5) : setting_(initial_setting) {}

  int32_t setting() const { return setting_.load(std::memory_order_acquire); }

  void set_initial_setting(int32_t value) { setting_.store(value, std::memory_order_release); }

  void enqueue_show(std::wstring tag, std::wstring title, std::wstring body, std::wstring opens) {
    std::lock_guard<std::mutex> lock(mu_);
    if (dead_) return;
    ops_.push_back(WinNoticeOp{
        WinNoticeOpKind::Show,
        std::move(tag),
        std::move(title),
        std::move(body),
        std::move(opens),
    });
  }

  void enqueue_cancel(std::wstring tag) {
    std::lock_guard<std::mutex> lock(mu_);
    if (dead_) return;
    ops_.push_back(WinNoticeOp{
        WinNoticeOpKind::Cancel,
        std::move(tag),
        {},
        {},
        {},
    });
  }

  void request_refresh() {
    std::lock_guard<std::mutex> lock(mu_);
    if (dead_) return;
    refresh_pending_ = true;
  }

  // Called when worker startup/initialization fails (CreateThread, RoInitialize, etc.):
  // marks the queue dead, drops pending ops, transitions setting from pending (5) to unknown (0), and wakes UI.
  void on_init_failed(Ops &ops) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      dead_ = true;
      ops_.clear();
      refresh_pending_ = false;
    }
    int32_t prev = setting_.exchange(0, std::memory_order_acq_rel);
    if (prev != 0) {
      ops.wake();
    }
  }

  // Drains all queued operations and coalesced refresh requests on the worker thread.
  // Must only be called from the single worker thread.
  void drain(Ops &ops) {
    for (;;) {
      bool do_refresh = false;
      bool has_op = false;
      WinNoticeOp op{};
      {
        std::lock_guard<std::mutex> lock(mu_);
        if (refresh_pending_) {
          // Clear before executing so a foreground event arriving mid-refresh schedules one follow-up refresh.
          refresh_pending_ = false;
          do_refresh = true;
        } else if (!ops_.empty()) {
          op = std::move(ops_.front());
          ops_.pop_front();
          has_op = true;
        } else {
          break;
        }
      }

      if (do_refresh) {
        int32_t next = 0;
        if (ops.ensure_ready()) {
          next = ops.query_setting();
        }
        int32_t prev = setting_.exchange(next, std::memory_order_acq_rel);
        if (prev != next) {
          ops.wake();
        }
        continue;
      }

      if (!has_op) {
        break;
      }

      if (op.kind == WinNoticeOpKind::Show) {
        revoke_active(ops, op.tag);
        if (ops.ensure_ready()) {
          ActiveToast entry{};
          if (ops.show_toast(op.tag, op.title, op.body, op.opens, entry.toast, entry.token, entry.subscribed)) {
            active_[op.tag] = std::move(entry);
          }
        }
      } else {
        revoke_active(ops, op.tag);
        // Also ensure_ready() on cancel so cross-process residual toasts can be removed.
        if (ops.ensure_ready()) {
          ops.remove_history(op.tag);
        }
      }
    }
  }

  size_t active_count_for_test() const { return active_.size(); }

  size_t queued_count_for_test() const {
    std::lock_guard<std::mutex> lock(mu_);
    return ops_.size();
  }

 private:
  struct ActiveToast {
    ToastHandle toast{};
    Token token{};
    bool subscribed = false;
  };

  void revoke_active(Ops &ops, const std::wstring &tag) {
    auto it = active_.find(tag);
    if (it == active_.end()) {
      return;
    }
    if (it->second.subscribed) {
      ops.revoke_activated(it->second.toast, it->second.token);
    }
    active_.erase(it);
  }

  mutable std::mutex mu_;
  bool dead_ = false;
  std::deque<WinNoticeOp> ops_;
  bool refresh_pending_ = false;
  std::atomic<int32_t> setting_;
  // Worker-thread-only state.
  std::unordered_map<std::wstring, ActiveToast> active_;
};

}  // namespace mb
