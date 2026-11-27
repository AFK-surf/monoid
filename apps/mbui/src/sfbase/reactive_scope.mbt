// Structural reactive invalidation guard for auth/vault scope boundaries in `sfbase`.
//
// Invariant:
// External invalidation paths (`invalidate_auth_scope`, `SourceKept::forget_*`, `SourceKept::sweep`,
// `let_go_unread`, `on_unwatched`) NEVER call `Computed::dispose()` on a live watched computed
// (`c.watched() == true`). Disposing a watched computed severs its upstream dependency links
// without notifying downstream readers (`app_tree` / `app_is` / `root.pick`), permanently freezing
// the UI. Instead, all external disposal/invalidation flows funnel through these single-point
// helpers: unwatched computeds are disposed and evicted, while watched computeds stay linked and
// have their `epoch` / `lifetime` signal bumped in a single batch so downstream readers immediately
// re-evaluate and remain live for future updates.

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
