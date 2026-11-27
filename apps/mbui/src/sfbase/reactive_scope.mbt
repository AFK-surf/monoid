// Structural reactive invalidation guard for auth/vault scope boundaries in `sfbase`.
//
// Invariant:
// External invalidation paths (`invalidate_auth_scope`, `SourceKept::forget_*`, `SourceKept::sweep`,
// `let_go_unread`, `on_unwatched`) NEVER call `Computed::dispose()` on a live watched computed
// (`c.watched() == true`). Disposing a watched computed severs its upstream dependency links
// without notifying downstream readers (`app_tree` / `app_is` / `root.pick`), permanently freezing
// the UI. Instead, all external disposal/invalidation flows funnel through these single-point
// helpers: unwatched computeds are detached before disposal (preventing re-entrant `on_unwatched`
// double-release), while watched computeds stay linked and have their `epoch` / `lifetime` signal
// bumped in a single batch so downstream readers immediately re-evaluate and remain live.

///|
/// Disposes `c` ONLY when no live downstream reader watches it (`!c.watched()`).
/// Returns `true` if disposed, `false` if still watched (never severs a live reactive chain).
fn[T] dispose_if_unwatched(c : @signals.Computed[T]) -> Bool {
  if c.watched() {
    false
  } else {
    c.dispose()
    true
  }
}

///|
/// Retires `c` ONLY when no live downstream reader watches it (`!c.watched()`), preserving exact
/// caller-specified ordering around `Computed::dispose()`:
/// - `before_dispose()` runs first (removing the entry from registry arrays before `c.dispose()` so
///   any synchronous re-entrant `on_unwatched` callback triggered by `c.dispose()` cannot see it again).
/// - `c.dispose()` runs next.
/// - `after_dispose()` runs last.
/// Returns `true` if retired, `false` if still watched.
fn[T] retire_if_unwatched(
  c : @signals.Computed[T],
  before_dispose : () -> Unit,
  after_dispose? : () -> Unit = fn() {  },
) -> Bool {
  if c.watched() {
    false
  } else {
    before_dispose()
    c.dispose()
    after_dispose()
    true
  }
}

///|
/// Structural invalidation primitive for auth/vault scope boundaries:
/// - If `c.watched()` is `false`: disposes `c` and returns `true` (caller removes from cache bucket).
/// - If `c.watched()` is `true`: NEVER disposes `c`; queues `epoch` into `pending_bumps` for batched
///   re-evaluation and returns `false` (live subscription chain stays intact).
fn[T] invalidate_live_or_dispose(
  c : @signals.Computed[T],
  epoch : @signals.Signal[Int],
  pending_bumps : Array[@signals.Signal[Int]],
) -> Bool {
  if c.watched() {
    pending_bumps.push(epoch)
    false
  } else {
    c.dispose()
    true
  }
}

///|
/// Flushes all queued `epoch` / `lifetime` signal bumps in a single reactive batch so live
/// watched followers and derived caches re-evaluate synchronously without intermediate glitches.
fn flush_epoch_bumps(bumps : Array[@signals.Signal[Int]]) -> Unit {
  if !bumps.is_empty() {
    @signals.start_batch()
    for sig in bumps {
      sig.set(sig.untracked() + 1)
    }
    @signals.end_batch()
  }
}
