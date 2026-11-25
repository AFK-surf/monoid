// Platform-independent bounded FIFO queue for Windows background Shell launches (URLs and file reveals).
// Included by win_notify.cpp on Windows and compiled standalone on Linux/macOS for unit tests.
#pragma once

#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <utility>

namespace mb {

enum class WinLaunchOpKind {
  OpenUrl,
  RevealFile,
};

struct WinLaunchOp {
  WinLaunchOpKind kind;
  std::wstring target;
};

template <typename Ops>
class WinLaunchQueue {
 public:
  static constexpr size_t kMaxPending = 64;

  explicit WinLaunchQueue(size_t max_pending = kMaxPending) : max_pending_(max_pending) {}

  bool enqueue(WinLaunchOpKind kind, std::wstring target) {
    std::lock_guard<std::mutex> lock(mu_);
    if (dead_ || ops_.size() >= max_pending_) {
      return false;
    }
    ops_.push_back(WinLaunchOp{kind, std::move(target)});
    return true;
  }

  // Drains all queued launch requests on the single STA worker thread.
  // Releases mu_ before each Shell call so callers never block behind slow Shell launches.
  void drain(Ops &ops) {
    for (;;) {
      WinLaunchOp op{};
      {
        std::lock_guard<std::mutex> lock(mu_);
        if (ops_.empty()) {
          break;
        }
        op = std::move(ops_.front());
        ops_.pop_front();
      }
      if (op.kind == WinLaunchOpKind::OpenUrl) {
        ops.open_url(op.target);
      } else {
        ops.reveal_file(op.target);
      }
      ops.pump_messages();
    }
  }

  // Marks the queue dead and settles every already-enqueued item exactly once.
  void on_init_failed(Ops &ops) {
    std::deque<WinLaunchOp> dropped;
    {
      std::lock_guard<std::mutex> lock(mu_);
      dead_ = true;
      dropped.swap(ops_);
    }
    for (const auto &op : dropped) {
      ops.on_failed(op);
    }
  }

  bool is_dead() const {
    std::lock_guard<std::mutex> lock(mu_);
    return dead_;
  }

  size_t pending_count() const {
    std::lock_guard<std::mutex> lock(mu_);
    return ops_.size();
  }

 private:
  size_t max_pending_;
  mutable std::mutex mu_;
  bool dead_ = false;
  std::deque<WinLaunchOp> ops_;
};

}  // namespace mb
