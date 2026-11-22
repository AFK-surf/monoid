// What comes and goes under a post in a chat's list (its options, how a card went, 忽略; ListMotion.kt, Chat.kt
// ArchiveEase; Decisions.css.ts): its room opening and closing as what is in it comes and goes, each on its own curve,
// from the moment it changed, with whatever else changes the list's height (list_turns.mbt).

///|
/// The room under a post going to its new height: a Move as long as its way is far, as every row's height in a chat's
/// list goes (mbui's view/list_motion.mbt: what changes together moves as one, on one curve from one moment).
// kept across runs: a curve, never written
pub let close_gap : @motion.Spec = @motion.moved()

///|
/// How long the archive buttons take to come and go, 忽略 too.
pub let archive_ms : Double = 280.0

///|
/// ArchiveEase: a quick start, a soft landing.
// kept across runs: a curve, never written
pub let archive_ease : @ui.Ease = Out

///|
/// How small the archive buttons (and 忽略) are as they have come or gone: 85%.
pub let archive_scale : Double = 0.85

///|
/// The archive buttons' curve and time (`archive_ms`): a quick start, a soft landing.
// kept across runs: a curve, never written
pub let archive_tween : @motion.Spec = @motion.tween(archive_ms, ease=archive_ease)

///|
/// Legacy rest timestamp for rooms under posts (always -1.0 since node-based views own their own motion).
pub fn under_rest() -> Double {
  -1.0
}

// ── the cards in a chat ─────────────────────────────────────────────────

///|
/// Options answered fade out in this long; how it went fades in after them as long.
pub let options_out_ms : Double = 200.0

///|
/// The answered options' curve (CSS's ease-out) and how small they are as they have gone: 90%.
// kept across runs: a curve, never written
pub let options_ease : @ui.Ease = Leave

///|
pub let options_scale : Double = 0.9
