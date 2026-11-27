// What a control feels like under the hand, as data on its node's timeline: how far the hand is on it (a pointer over
// it, the keyboard's focus shown on it) and how far it is pressed, two ways apart (Eased: each its end a moment of the
// node's, called off as another is said), each set off by its cause at its moment (View::reacts on what the tree tells:
// View::pointed, View::focus_shown, View::pressed) and read where it is drawn. Pressed by a hand in the window (a
// finger, a button: View::window_held; not every control at once as a Tester lights them all to measure their looks),
// it sinks a little at once and springs back as it is let go (lift_spring: a little past where it rests, then still); a
// finger's press in what scrolls only once it has stayed tap_indication_ms (Compose's clickable in a scrollable
// container, press_look's), one let go or taken by the list it is in (scrolled) before that not at all. Its node drawn that much smaller about its middle (View::scale, a place's:
// nothing laid out again), by points rather than a share, so a wide one sinks as far as a small one; at rest, and under
// the hand alone, exactly 1; with motion reduced, sunk and back at once (its ways', Way::go). Its scale moves nothing under a still pointer (at most a
// point and a half, 1 again at rest: seg_node's thumb's way), so its end is no moment the hand is found again at.
//
// And a hold that confirms (HoldWay): what is done only once the hand has stayed on it its whole length, its progress a
// line in time from its press, the moment it is full declared on the node's timeline. Its length is a safety, not a
// decoration: motion reduced, it still takes all of it (its progress read by the clock, not a Way, which reduced
// motion puts at its end at once); let go short of it, back to none from where it was.

///|
/// How a press sinks (in fast, eased out: the hand's press answered at once).
// kept across runs: a constant: its fields are not mut, nothing changes it
let press_in : Spec = Tween(70.0, Out, 0.0)

///|
/// A control's feel under the hand (press_feel): how far the hand is on it and how far it is pressed, each its own way.
pub struct PressFeel {
  priv hover : Eased
  priv press : Eased
  /// how far it sinks at most, a share of it: worked out of how big it is as each press goes down
  priv mut depth : Double
  /// a press told by a gesture (PressFeel::down) with its size, at its moment: what that press sinks by
  priv mut told : (Double, Double, Double)?
  /// a finger's press in what scrolls not shown yet: its showing due
  priv mut late : Bool
  priv mut late_due : () -> Unit
  priv sink_px : Double
  priv sink_most : Double
  /// how big it is, where its look knows it (a box of a side said)
  priv size : (Double, Double)?
  /// whether its node is drawn smaller as it sinks, and whether that is bound yet: bound as it is first pressed, so a
  /// control never pressed binds nothing for it (a page of them opened binds none)
  priv scale_node : Bool
  priv mut scaled : Bool
  priv loc : SourceLoc
}

///|
/// The feel of the control `v` (press_feel): `live` while it takes the hand (not disabled, not at work); `sink_px` how
/// far it sinks at its widest side as it is pressed (points), never more than `sink_most` of it; `hover_ms` how long the
/// hand's coming and going take (eased out); `hovers`: whether the hand's way is kept at all (a look that lights itself
/// under the hand its own way says false: nothing of it then watches the pointer). `scale_node`: its node drawn that
/// much smaller about its middle while it sinks (View::scale, bound as it is first pressed); else the look reads
/// `pressed_on` itself. `size`: how big it is where its look knows (a box of a side said); else its gesture tells it
/// (PressFeel::down). Made with `v`, let go with it: what it has due let go then.
#callsite(autofill(loc))
pub fn press_feel(
  v : @view.View,
  live? : () -> Bool = fn() { true },
  sink_px? : Double = 1.5,
  sink_most? : Double = 0.038,
  hover_ms? : Double = 140.0,
  hovers? : Bool = true,
  scale_node? : Bool = true,
  size? : (Double, Double),
  loc~ : SourceLoc,
) -> PressFeel {
  // (a pointer over it (never a finger, which points at nothing: View::pointed) or the keyboard's focus shown on it)
  let on = fn() { live() && (v.focus_shown() || v.pointed()) }
  let f : PressFeel = {
    hover: Eased::new(if hovers && @signals.untracked(on) { 1.0 } else { 0.0 }),
    press: Eased::new(0.0),
    depth: 0.0,
    told: None,
    late: false,
    late_due: fn() {  },
    sink_px,
    sink_most,
    size,
    scale_node,
    scaled: false,
    loc,
  }
  if hovers {
    v.reacts(on, at_start=false, fn(now) { f.hover.go(v, if now { 1.0 } else { 0.0 }, hover_ms) })
  }
  // its node drawn smaller as it sinks: bound as it is first sunk (owned by the node, as what a reaction makes is), so a
  // control never pressed binds nothing for it
  let scaled = fn() {
    if f.scale_node && !f.scaled {
      f.scaled = true
      v.scale(By(fn() { f.scale_on(v) }), moves_besides=false, loc=f.loc) |> ignore
    }
  }
  // (whether the press now down is a hand's in the window: one every control is told at once (Tree::lit_all, a
  // Tester's measure of the looks) is none)
  let by_hand = Ref(false)
  v.reacts(fn() { live() && v.pressed() }, at_start=false, fn(down) {
    let at = v.cause_at()
    if down {
      (f.late_due)()
      f.late_due = fn() {  }
      f.late = false
      if !@signals.untracked(fn() { v.window_held() }) {
        by_hand.val = false
        f.told = None
        return
      }
      by_hand.val = true
      if @ui.pointing() is Finger && v.scroll_holding() is Some(_) {
        // (a finger in what scrolls: shown once it has stayed, as one that goes on to scroll presses nothing; what its
        // gesture told of its size kept for then)
        let told = f.told
        f.told = None
        f.late = true
        f.late_due = v.at_moment(at + @ui.tap_indication_ms, fn() {
          f.late = false
          f.late_due = fn() {  }
          f.told = told
          scaled()
          f.sink(v)
        })
      } else {
        scaled()
        f.sink(v)
      }
      return
    }
    guard by_hand.val else { return }
    by_hand.val = false
    if f.late {
      // (let go, or taken by the list it is in, before it showed: nothing shown of it)
      (f.late_due)()
      f.late_due = fn() {  }
      f.late = false
      f.told = None
    } else {
      f.told = None
      f.press.go_by(v, 0.0, tactile_bounce)
    }
  })
  v.owns(fn() {
    (f.hover.due)()
    (f.press.due)()
    (f.late_due)()
  })
  |> ignore
  f
}

///|
/// Its press told by the gesture that brought it (Drag's size as it went down, nothing read of its layout): what it
/// sinks by, for a press at that moment. A look whose gesture says it hands it its `press` (@headless.Hold's `down`).
pub fn PressFeel::down(self : PressFeel, d : @view.Drag) -> Unit {
  self.told = Some((d.at, d.w, d.h))
}

///|
/// Sunk from `v`'s cause's moment, as far as how big it is says: as its gesture told it as it went down, else as its
/// look said it is, else (nothing told: a press no gesture handed on) a share of its most. Nothing read of its layout:
/// a press of each of many at one moment lays nothing out for any of them.
fn PressFeel::sink(self : PressFeel, v : @view.View) -> Unit {
  let (w, h) = match (self.told, self.size) {
    (Some((_, w, h)), _) => (w, h)
    (None, Some(s)) => s
    (None, None) => (0.0, 0.0)
  }
  self.told = None
  let side = dmax(w, h)
  self.depth = if side <= 0.0 {
    self.sink_most * 0.6
  } else {
    dmin(self.sink_most, self.sink_px / dmax(side, 1.0))
  }
  self.press.go_by(v, 1.0, press_in)
}

///|
/// How far the hand is on it as `n` is drawn (0 … 1): a pointer over it or the keyboard's focus shown on it.
pub fn PressFeel::hovered_on(self : PressFeel, n : @view.View) -> Double {
  self.hover.shown(n)
}

///|
/// How far it is pressed as `n` is drawn (0 … 1, a little under 0 as it springs back past its rest).
pub fn PressFeel::pressed_on(self : PressFeel, n : @view.View) -> Double {
  self.press.shown(n)
}

///|
/// How big its node is drawn as `n` is drawn: 1 less how far it sinks, exactly 1 at rest. Read at the moment drawn
/// while it goes, its end no moment the hand is found again at (the file's head: it moves nothing under a pointer).
pub fn PressFeel::scale_on(self : PressFeel, n : @view.View) -> Double {
  self.press.ended.get() |> ignore
  self.press.way.said()
  let t = n.drawn_while(fn(at) { self.press.way.goes_at(at) })
  let p = if t == @double.infinity {
    self.press.way.target()
  } else {
    self.press.way.value_at(t)
  }
  if p == 0.0 {
    1.0
  } else {
    1.0 - self.depth * p
  }
}

///|
/// A hold that confirms (hold_way): its progress a line in time from its press, full at `hold_ms`.
pub struct HoldWay {
  /// told as it is pressed, let go, called off or full: what reads its progress follows it
  priv said : @signals.Signal[Int]
  priv mut on : Bool
  /// where its progress was and when, as it was last pressed, and when it is full
  priv mut from : Double
  priv mut start : Double
  priv mut full_at : Double
  priv hold_ms : Double
  /// back to none as it is let go short of full
  priv back : Eased
  priv mut due : () -> Unit
  /// full and done as it was held: let go, it is none at once (what it did is done, nothing short of it to take back)
  priv mut done : Bool
}

///|
/// A hold that confirms on `v`: pressed and held (a finger or the pointer on it, View::pressed) while `live`, its
/// progress goes from where it was to full in a line, the whole of `hold_ms` from none (motion reduced too: a hold's
/// length is no motion); full, `on_complete` done at that moment (View::at_moment), it stays full while held. Let go,
/// called off or no longer live short of it, back to none from where it was over `recoil_ms`, eased out (with motion
/// reduced, at once); once full, none at once. Its node's: what is due let go with it.
#callsite(autofill(loc))
pub fn hold_way(
  v : @view.View,
  hold_ms : Double,
  on_complete : () -> Unit,
  live? : () -> Bool = fn() { true },
  recoil_ms? : Double = 160.0,
  loc~ : SourceLoc,
) -> HoldWay {
  ignore(loc)
  let hw : HoldWay = {
    said: @signals.signal(0),
    on: false,
    from: 0.0,
    start: 0.0,
    full_at: 0.0,
    hold_ms: dmax(hold_ms, 1.0),
    back: Eased::new(0.0),
    due: fn() {  },
    done: false,
  }
  v.reacts(fn() { live() && v.pressed() }, at_start=false, fn(down) {
    if down {
      hw.press_at(v, v.cause_at(), on_complete)
    } else {
      hw.release_at(v, v.cause_at(), recoil_ms)
    }
  })
  v.owns(fn() {
    (hw.due)()
    (hw.back.due)()
  })
  |> ignore
  hw
}

///|
/// Held from `at`, from where it is then.
fn HoldWay::press_at(self : HoldWay, v : @view.View, at : Double, on_complete : () -> Unit) -> Unit {
  if self.on {
    return
  }
  let p = dclamp(self.back.way.value_at(at), 0.0, 1.0)
  (self.due)()
  self.back.put(p)
  self.on = true
  self.done = false
  self.from = p
  self.start = at
  self.full_at = at + (1.0 - p) * self.hold_ms
  self.due = v.at_moment(self.full_at, fn() {
    self.due = fn() {  }
    self.done = true
    self.said.set(self.said.untracked() + 1)
    on_complete()
  })
  self.said.set(self.said.untracked() + 1)
}

///|
/// Let go at `at`: back to none from where it was then; full and done, none at once.
fn HoldWay::release_at(self : HoldWay, v : @view.View, at : Double, recoil_ms : Double) -> Unit {
  if !self.on {
    return
  }
  let p = self.progress_at(at)
  (self.due)()
  self.due = fn() {  }
  self.on = false
  if self.done {
    self.done = false
    self.back.put(0.0)
  } else {
    self.back.put(p)
    self.back.go(v, 0.0, recoil_ms)
  }
  self.said.set(self.said.untracked() + 1)
}

///|
/// Its progress at moment `t` while held.
fn HoldWay::progress_at(self : HoldWay, t : Double) -> Double {
  if t >= self.full_at {
    1.0
  } else {
    dclamp(self.from + (t - self.start) / self.hold_ms, 0.0, 1.0)
  }
}

///|
/// How far it has come as `n` is drawn (0 … 1): while held, at the moment drawn till it is full (the clock followed no
/// more after); let go, its way back.
pub fn HoldWay::progress_on(self : HoldWay, n : @view.View) -> Double {
  self.said.get() |> ignore
  if self.on {
    let t = n.drawn_while(fn(at) { at < self.full_at })
    if t == @double.infinity {
      1.0
    } else {
      self.progress_at(t)
    }
  } else {
    self.back.shown(n)
  }
}

///|
/// How far it has come at moment `t` (what a place drawn by it reads at the moment it is drawn: View::moved_by), as it
/// is said now: held, its line in time; let go, its way back.
pub fn HoldWay::at(self : HoldWay, t : Double) -> Double {
  if self.on {
    self.progress_at(t)
  } else {
    self.back.way.value_at(t)
  }
}

///|
/// When what it says now comes to rest (full while held, back at none once let go), followed as it is said anew: what
/// a place drawn by it (View::moved_by's `ends`) is drawn again till.
pub fn HoldWay::end(self : HoldWay) -> Double {
  self.said.get() |> ignore
  self.back.way.said()
  if self.on {
    self.full_at
  } else {
    self.back.way.end()
  }
}

///|
/// Whether it is held now (pressed and live, full or not).
pub fn HoldWay::holding(self : HoldWay) -> Bool {
  self.said.get() |> ignore
  self.on
}
