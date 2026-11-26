// High-frequency node-level motion tools: causal, closed-form, zero-relayout during motion,
// and reduced-motion aware.

///|
/// Hover/active fade progress in `0..1` bound to node `v`:
/// fades in over `duration_ms` on `Out` when `active()` becomes true, fades out over `duration_ms` on `Out`
/// when `active()` becomes false (or snaps to `0.0` immediately when `instant_off()` is true).
/// Settled immediately at initial state on mount (epistemic silence).
#callsite(autofill(loc))
pub fn hover_fade(
  v : @view.View,
  active : () -> Bool,
  duration_ms? : Double = 140.0,
  instant_off? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> () -> Double {
  let init = if @signals.untracked(active) { 1.0 } else { 0.0 }
  let way = NodeWay::new(init)
  v.reacts(active, at_start=false, fn(on) {
    if on {
      way.go(v, 1.0, tween(duration_ms, ease=Out), loc~)
    } else if @signals.untracked(instant_off) {
      way.put(0.0, loc~)
    } else {
      way.go(v, 0.0, tween(duration_ms, ease=Out), loc~)
    }
  })
  fn() { way.shown(v) }
}

///|
/// Quote/target highlight flash bound to node `v`:
/// whenever `trigger()` increments, starts at `v.cause_at()` and runs
/// `in_ms` (`Out`, 0 -> 1) -> `hold_ms` (at 1) -> `out_ms` (`Leave`, 1 -> 0).
/// Under `reduced_motion`, illuminates immediately to `1.0`, holds for `in_ms + hold_ms + out_ms`,
/// then turns off at the declared end moment without requesting intermediate frames.
#callsite(autofill(loc))
pub fn flash_way(
  v : @view.View,
  trigger : () -> Int,
  in_ms? : Double = 160.0,
  hold_ms? : Double = 740.0,
  out_ms? : Double = 800.0,
  loc~ : SourceLoc,
) -> () -> Double {
  let started_at : @signals.Signal[Double?] = @signals.signal(None)
  let ended : @signals.Signal[Int] = @signals.signal(0)
  let last = Ref(@signals.untracked(trigger))
  let due : Ref[(() -> Unit)?] = Ref(None)
  let total = dmax(0.0, in_ms) + dmax(0.0, hold_ms) + dmax(0.0, out_ms)
  let stop_due = fn() {
    match due.val {
      Some(f) => {
        due.val = None
        f()
      }
      None => ()
    }
  }
  v.reacts(trigger, at_start=false, fn(n) {
    let prev = last.val
    last.val = n
    if n > prev {
      stop_due()
      let start = v.cause_at()
      started_at.set(Some(start), loc~)
      if total > 0.0 && v.alive() {
        let unkeep : Ref[(() -> Unit)?] = Ref(None)
        let drop_unkeep = fn() {
          match unkeep.val {
            Some(f) => {
              unkeep.val = None
              f()
            }
            None => ()
          }
        }
        let stop_moment = v.at_moment(start + total, fn() {
          drop_unkeep()
          due.val = None
          ended.set(ended.untracked() + 1, loc~)
        })
        unkeep.val = Some(
          v.owns_while(fn() {
            unkeep.val = None
            stop_moment()
            due.val = None
          }),
        )
        due.val = Some(fn() {
          drop_unkeep()
          stop_moment()
          due.val = None
        })
      }
    }
  })
  fn() {
    ended.get() |> ignore
    guard started_at.get() is Some(start) else { return 0.0 }
    if total <= 0.0 {
      return 0.0
    }
    let goes = fn(now : Double) { now >= start && now < start + total }
    if @ui.reduced_motion() {
      if v.goes_now(goes) {
        1.0
      } else {
        0.0
      }
    } else {
      let at = v.drawn_while(goes)
      if at == @double.infinity || at < start || at >= start + total {
        return 0.0
      }
      let dt = at - start
      if dt < in_ms {
        if in_ms <= 0.0 {
          1.0
        } else {
          @ui.Out.at(dclamp(dt / in_ms, 0.0, 1.0))
        }
      } else if dt < in_ms + hold_ms {
        1.0
      } else if out_ms <= 0.0 {
        0.0
      } else {
        1.0 - @ui.Leave.at(dclamp((dt - in_ms - hold_ms) / out_ms, 0.0, 1.0))
      }
    }
  }
}

///|
/// Breathing alpha in `[low, 1.0]` for skeletons and waiting states:
/// returns `1.0` when `still()` or `reduced_motion()` holds;
/// uses `v.cycle_resident(period_ms)` (10 Hz power-saving steps) when `resident=true`,
/// otherwise `v.cycle(period_ms)`, oscillating smoothly between `1.0` and `low` on `InOut`.
pub fn breathe_alpha(
  v : @view.View,
  period_ms? : Double = 1400.0,
  low? : Double = 0.5,
  resident? : Bool = false,
  still? : () -> Bool = fn() { false },
) -> () -> Double {
  fn() {
    if still() || @ui.reduced_motion() {
      return 1.0
    }
    let p = if resident { v.cycle_resident(period_ms) } else { v.cycle(period_ms) }
    let half = if p < 0.5 { p * 2.0 } else { (1.0 - p) * 2.0 }
    let e = @ui.InOut.at(dclamp(half, 0.0, 1.0))
    1.0 - (1.0 - low) * e
  }
}

///|
/// Resident 10 Hz cycle progress in `[0, 1)` (`v.cycle_resident(period_ms)`).
pub fn resident_cycle(v : @view.View, period_ms : Double) -> Double {
  v.cycle_resident(period_ms)
}

///|
/// Resident 10 Hz discrete step index in `0..<steps` for spokes, working dots, and status indicators.
/// Returns `0` when `steps <= 1` or `reduced_motion()` is active.
pub fn resident_step(v : @view.View, period_ms : Double, steps : Int) -> Int {
  if steps <= 1 || @ui.reduced_motion() {
    return 0
  }
  let raw = (v.cycle_resident(period_ms) * steps.to_double()).floor().to_int()
  if raw < 0 {
    0
  } else if raw >= steps {
    steps - 1
  } else {
    raw
  }
}

///|
/// Pure paint-layer sliding indicator rectangle `(x, y, w, h)` bound to node `v`:
/// tracks four `NodeWay`s (`x`, `y`, `w`, `h`), settles immediately on the first non-None target
/// (epistemic silence), and transitions subsequent targets by `spec` (default `snappy_damped`)
/// with zero relayout during animation.
#callsite(autofill(loc))
pub fn indicator_rect(
  v : @view.View,
  target : () -> (Double, Double, Double, Double)?,
  spec? : Spec = snappy_damped,
  loc~ : SourceLoc,
) -> () -> (Double, Double, Double, Double)? {
  let wx = NodeWay::new(0.0)
  let wy = NodeWay::new(0.0)
  let ww = NodeWay::new(0.0)
  let wh = NodeWay::new(0.0)
  let placed = Ref(false)
  let visible = @signals.signal(false)
  match @signals.untracked(target) {
    Some((x, y, w, h)) => {
      wx.put(x, loc~)
      wy.put(y, loc~)
      ww.put(w, loc~)
      wh.put(h, loc~)
      placed.val = true
      visible.set(true, loc~)
    }
    None => ()
  }
  v.reacts(target, at_start=false, fn(next) {
    match next {
      Some((x, y, w, h)) => {
        if !placed.val {
          wx.put(x, loc~)
          wy.put(y, loc~)
          ww.put(w, loc~)
          wh.put(h, loc~)
          placed.val = true
        } else {
          wx.go(v, x, spec, loc~)
          wy.go(v, y, spec, loc~)
          ww.go(v, w, spec, loc~)
          wh.go(v, h, spec, loc~)
        }
        visible.set(true, loc~)
      }
      None => {
        placed.val = false
        visible.set(false, loc~)
      }
    }
  })
  fn() {
    if visible.get() {
      Some((wx.shown(v), wy.shown(v), ww.shown(v), wh.shown(v)))
    } else {
      None
    }
  }
}

///|
/// Symmetric overlay presence helper:
/// returns `(look, modal_live)` where `look` drives `enter` on entry and `exit` while `v.leaving()`,
/// and `modal_live` becomes `false` on the very first frame of exit so leaving overlays never swallow clicks.
pub fn overlay_presence(
  v : @view.View,
  enter~ : Trans,
  exit~ : Trans,
) -> (() -> @ui.Look, () -> Bool) {
  let look = presence_look(v, enter, exit~)
  let modal_live = fn() { !v.leaving() }
  (look, modal_live)
}

///|
/// Keyed hover/active fade progress in `0..1` for reused list rows bound to node `v`:
/// behaves like `hover_fade`, except whenever `key()` changes (row recycled for another item),
/// snaps immediately to `active()` (`way.put`) with no frame-dependent motion.
#callsite(autofill(loc))
pub fn hover_fade_keyed(
  v : @view.View,
  key : () -> String,
  active : () -> Bool,
  duration_ms? : Double = 140.0,
  instant_off? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> () -> Double {
  let init = if @signals.untracked(active) { 1.0 } else { 0.0 }
  let way = NodeWay::new(init)
  let key_was = Ref(@signals.untracked(key))
  v.reacts(fn() { (key(), active()) }, at_start=false, fn(now) {
    let (k, on) = now
    if k != key_was.val {
      key_was.val = k
      way.put(if on { 1.0 } else { 0.0 }, loc~)
    } else if on {
      way.go(v, 1.0, tween(duration_ms, ease=Out), loc~)
    } else if @signals.untracked(instant_off) {
      way.put(0.0, loc~)
    } else {
      way.go(v, 0.0, tween(duration_ms, ease=Out), loc~)
    }
  })
  fn() { way.shown(v) }
}

///|
/// Index-driven cover sliding indicator rectangle `(x, y, w, h)` bound to node `v`:
/// wraps `@ui.cover_set_out` + `@ui.cover_rect` + `NodeWay` so the indicator blends from its
/// previous item(s) to `chosen()` on `spec` (default `move_damped`), while recomputing rects
/// via `rect_of` live during paint (zero lag on resize/font-scale change, zero relayout during motion).
#callsite(autofill(loc))
pub fn cover_indicator(
  v : @view.View,
  chosen : () -> Int,
  rect_of : (Int) -> (Double, Double, Double, Double)?,
  spec? : Spec = move_damped,
  loc~ : SourceLoc,
) -> () -> (Double, Double, Double, Double)? {
  let first = @signals.untracked(chosen)
  let cover : @signals.Signal[(Array[(Int, Double)], Int)] = @signals.signal(([(first, 1.0)], first))
  let way = NodeWay::new(1.0)
  v.reacts(chosen, fn(k) {
    let (from, to) = cover.untracked()
    if k != to {
      let p = way.value_at(v.cause_at())
      cover.set((@ui.cover_set_out(from, to, p), k), loc~)
      way.go_from(v, 0.0, 1.0, spec, loc~)
    }
  })
  fn() {
    let (from, to) = cover.get()
    @ui.cover_rect(from, to, way.shown(v), rect_of)
  }
}

///|
/// Keyed quote/target highlight flash for reused list items bound to node `v`:
/// when `key()` changes, immediately clears (`put(0.0)`) and cancels any pending fade timer;
/// when `target()` matches `(key, at)` with `at >= 0.0` and `v.cause_at() < at + total_ms`,
/// runs `in_ms` (`Out`, 0 -> 1) -> `held_ms` -> `(total_ms - held_ms)` (`Leave`, 1 -> 0),
/// each way at once under `reduced_motion` (Way::go), its hold as long. Automatically cancels timers on unmount.
#callsite(autofill(loc))
pub fn flash_way_keyed(
  v : @view.View,
  key : () -> String,
  target : () -> (String, Double),
  in_ms? : Double = 160.0,
  held_ms? : Double = 900.0,
  total_ms? : Double = 1700.0,
  hold? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Way {
  let way = Way::new(0.0)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  let key_was = Ref(@signals.untracked(key))
  v.reacts(fn() { (target(), key()) }, fn(g) {
    let ((k, at), now) = g
    if now != key_was.val {
      key_was.val = now
      (due.val)()
      due.val = fn() {  }
      way.put(0.0, loc~)
    }
    let held = hold()
    guard k == now && at >= 0.0 && (held || v.cause_at() < at + total_ms) else { return }
    (due.val)()
    due.val = fn() {  }
    if held {
      way.put(1.0, loc~)
      return
    }
    way.go(1.0, tween(in_ms, ease=Out), at~, loc~)
    let out = at + held_ms
    due.val = v.at_moment(out, fn() {
      due.val = fn() {  }
      way.go(0.0, tween(total_ms - held_ms, ease=Leave), at=out, loc~)
    })
  })
  v.owns(fn() { (due.val)() }) |> ignore
  way
}
