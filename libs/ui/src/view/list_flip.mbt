// FLIP quiet-change classification, active-way remapping, and HoldRoomFade helpers for `View::scrolls_window`.
// Pure `Int`-keyed helpers extracted from `list_window.mbt` to avoid generic monomorphization bloat.

///|
/// How a quiet key change (outside any `transition`) interacts with an active FLIP way:
/// `QuietReset` drops any active way (idle, answering, or disjoint replacement), while
/// `QuietDelta` preserves the active way by remapping surviving keys to their new layout.
priv enum FlipQuietKind {
  QuietReset
  QuietDelta
}

///|
/// Classifies a quiet key update at `at` given the active FLIP way's end time (`active_ends <= at`
/// when idle or finished), whether an initial answer is being settled, and the previous/next keys.
fn classify_flip_quiet(
  active_ends : Double,
  at : Double,
  answering : Bool,
  was : Array[Int],
  ks : Array[Int],
) -> FlipQuietKind {
  if active_ends <= at || answering {
    return QuietReset
  }
  for k in was {
    if ks.contains(k) {
      return QuietDelta
    }
  }
  QuietReset
}

///|
/// Remaps surviving keys of an active `FlipWay` (`prev`) at moment `at` from their visually drawn
/// rects `before` to their newly laid-out resting rects `after`, keeping position and size
/// continuous without enrolling newly arrived quiet keys.
fn flip_remap_active_items(
  prev : @flex.FlipWay,
  at : Double,
  before : Map[Int, (Double, Double, Double, Double)],
  after : Map[Int, (Double, Double, Double, Double)],
  speed : Map[Int, (Double, Double, Double, Double)],
) -> (Map[Int, @flex.FlipItem], @flex.FlipWay) {
  let items : Map[Int, @flex.FlipItem] = Map([])
  let list : Array[@flex.FlipItem] = []
  match prev.said {
    Some(w) => {
      let k_rem = prev.left(at).0
      for k, a in after {
        match before.get(k) {
          Some(b) => {
            let oa = (b.0 - a.0) / k_rem
            let ob = (b.1 - a.1) / k_rem
            let oc = -(b.2 - a.2) / k_rem
            let od = -(b.3 - a.3) / k_rem
            let it : @flex.FlipItem = { off: (oa, ob, oc, od), v: (0.0, 0.0, 0.0, 0.0) }
            items[k] = it
            list.push(it)
          }
          None => ()
        }
      }
      (items, @flex.FlipWay::new(prev.at, list, said=w))
    }
    None => {
      for k, a in after {
        match before.get(k) {
          Some(b) => {
            let v = speed.get(k).unwrap_or((0.0, 0.0, 0.0, 0.0))
            let it : @flex.FlipItem = {
              off: (b.0 - a.0, b.1 - a.1, -(b.2 - a.2), -(b.3 - a.3)),
              v,
            }
            items[k] = it
            list.push(it)
          }
          None => ()
        }
      }
      (items, @flex.FlipWay::new(at, list))
    }
  }
}

///|
/// Keys removed from the tail of `was` after the last key still present in `ks`.
fn flip_tail_removed(was : Array[Int], ks : Array[Int]) -> Array[Int] {
  let mut kept_step = ks.length()
  while kept_step > 0 && !was.contains(ks[kept_step - 1]) {
    kept_step = kept_step - 1
  }
  let at_end = if kept_step > 0 {
    let l = ks[kept_step - 1]
    let i = was.search(l).unwrap_or(was.length() - 1)
    was[i + 1:].to_owned()
  } else {
    was
  }
  at_end.filter(fn(k) { !ks.contains(k) })
}

///|
/// Retains only surviving keys (present in `after`) in `flip_new`, `flip_whole`, `flip_in_of`, and
/// `flip_in_amts`, scaling remaining inner offsets by `in_scale` when switching to a fresh `FlipWay`.
fn flip_prune_active_state(
  after : Map[Int, (Double, Double, Double, Double)],
  flip_new : Map[Int, Bool],
  flip_whole : Map[Int, Bool],
  flip_in_of : Map[Int, Array[Int]],
  flip_in_amts : Map[Int, FlipInAmt],
  in_scale : Double,
) -> Unit {
  let drop_new : Array[Int] = []
  for k, _ in flip_new {
    if !after.contains(k) {
      drop_new.push(k)
    }
  }
  for k in drop_new {
    flip_new.remove(k)
  }
  let drop_whole : Array[Int] = []
  for k, _ in flip_whole {
    if !after.contains(k) {
      drop_whole.push(k)
    }
  }
  for k in drop_whole {
    flip_whole.remove(k)
  }
  let drop_in : Array[Int] = []
  for k, ats in flip_in_of {
    if !after.contains(k) {
      drop_in.push(k)
      for a in ats {
        flip_in_amts.remove(a)
      }
    } else if in_scale != 1.0 {
      for a in ats {
        match flip_in_amts.get(a) {
          Some(amt) =>
            flip_in_amts[a] = {
              ..amt,
              dy: amt.dy * in_scale,
              g: amt.g * in_scale,
              sh: amt.sh * in_scale,
              dx: amt.dx * in_scale,
              lw: amt.lw * in_scale,
            }
          None => ()
        }
      }
    }
  }
  for k in drop_in {
    flip_in_of.remove(k)
  }
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
