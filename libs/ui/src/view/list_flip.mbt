// FLIP quiet-change classification and HoldRoomFade helpers for `View::scrolls_window`.
// Pure `Int`-keyed helpers extracted from `list_window.mbt` to avoid generic monomorphization bloat.

///|
/// How a quiet key change (outside any `transition`) interacts with an active FLIP way:
/// `QuietReset` drops any active way (idle, answering, or visible-span mutation), while
/// `QuietDelta` preserves the active way in-place when the visible span is untouched.
priv enum FlipQuietKind {
  QuietReset
  QuietDelta
}

///|
/// Classifies a quiet key update at `at` given the active FLIP way's end time (`active_ends <= at`
/// when idle or finished), whether an initial answer is being settled, the currently showing keys,
/// and the previous/next key arrays.
///
/// Returns `QuietDelta` only when an active FLIP way is running (`active_ends > at && !answering`)
/// and the entire contiguous visible span `was[first_vis ..= last_vis]` is preserved verbatim and
/// contiguously in `ks`. Any mutation inside the visible span returns `QuietReset`.
fn classify_flip_quiet(
  active_ends : Double,
  at : Double,
  answering : Bool,
  showing : Map[Int, Bool],
  was : Array[Int],
  ks : Array[Int],
) -> FlipQuietKind {
  if active_ends <= at || answering {
    return QuietReset
  }
  let mut first_vis = -1
  let mut last_vis = -1
  for i, k in was {
    if showing.contains(k) {
      if first_vis < 0 {
        first_vis = i
      }
      last_vis = i
    }
  }
  if first_vis < 0 {
    return QuietReset
  }
  let span_len = last_vis - first_vis + 1
  guard ks.length() >= span_len else { return QuietReset }
  match ks.search(was[first_vis]) {
    Some(start) if start + span_len <= ks.length() => {
      for j in 0..<span_len {
        if ks[start + j] != was[first_vis + j] {
          return QuietReset
        }
      }
      QuietDelta
    }
    _ => QuietReset
  }
}

///|
/// Builds a hash set of list keys in O(N) for FLIP diff checks.
fn flip_key_set(ks : Array[Int]) -> Map[Int, Unit] {
  let m : Map[Int, Unit] = Map([], capacity=ks.length())
  for k in ks {
    m[k] = ()
  }
  m
}

///|
/// Whether `ks` is a strict subset of `was` (at least one key removed, none added), in O(N) with an O(1) same-array
/// fast path.
fn flip_steady_left(was : Array[Int], ks : Array[Int]) -> Bool {
  if physical_equal(was, ks) {
    return false
  }
  let ks_set = flip_key_set(ks)
  if !was.iter().any(fn(k) { !ks_set.contains(k) }) {
    return false
  }
  let was_set = flip_key_set(was)
  !ks.iter().any(fn(k) { !was_set.contains(k) })
}

///|
/// Whether the relative order of keys present in both `was` and `ks` changed, in O(N) using prebuilt key sets.
fn flip_order_changed(
  was : Array[Int],
  ks : Array[Int],
  was_set : Map[Int, Unit],
  ks_set : Map[Int, Unit],
) -> Bool {
  if physical_equal(was, ks) {
    return false
  }
  was.filter(fn(k) { ks_set.contains(k) }) != ks.filter(fn(k) { was_set.contains(k) })
}

///|
/// Keys appended at the tail of `ks` after the last key that was already in `base_was`, in O(N).
fn flip_tail_added(base_was : Array[Int], ks : Array[Int]) -> Array[Int] {
  if physical_equal(base_was, ks) || ks.is_empty() {
    return []
  }
  let was_set = flip_key_set(base_was)
  let mut kept = ks.length()
  while kept > 0 && !was_set.contains(ks[kept - 1]) {
    kept = kept - 1
  }
  ks[kept:].to_owned()
}

///|
/// Keys removed from the tail of `was` after the last key still present in `ks`.
fn flip_tail_removed(was : Array[Int], ks : Array[Int]) -> Array[Int] {
  if physical_equal(was, ks) {
    return []
  }
  let was_set = flip_key_set(was)
  let mut kept_step = ks.length()
  while kept_step > 0 && !was_set.contains(ks[kept_step - 1]) {
    kept_step = kept_step - 1
  }
  let at_end = if kept_step > 0 {
    let l = ks[kept_step - 1]
    let i = was.search(l).unwrap_or(was.length() - 1)
    was[i + 1:].to_owned()
  } else {
    was
  }
  if at_end.is_empty() {
    return []
  }
  let ks_set = flip_key_set(ks)
  at_end.filter(fn(k) { !ks_set.contains(k) })
}

///|
/// Computes the HoldRoomFade end time: at least `went + list_leaves_ms`, extended to the active
/// `FlipWay`'s end time when `flips` is enabled so a fading tail row is not dropped mid-slide.
fn fade_end_with_flip(went : Double, flips : Bool, flip_way : @flex.FlipWay?) -> Double {
  let mut end = went + list_leaves_ms
  if flips {
    match flip_way {
      Some(w) if w.ends() > end => end = w.ends()
      _ => ()
    }
  }
  end
}
