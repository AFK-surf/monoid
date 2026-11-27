// A press's ripple and sink on a node of the window's tree (@motion.ripple's, Android's `clickable`'s, as nodes): a
// soft disc from where the finger or the button went down, drifting to the node's middle as it grows, its way in over
// ripple_enter_ms from that moment, on to gone over ripple_exit_ms once it is let go and its way in is over (a short
// press shown whole); while it is down, a node standing on a ground of its own sunk a little, springing back as it is
// let go. Pressed by a pointer, no disc: the whole node pressed at once, its ink over it evenly and, on a ground of its
// own, a little smaller, in and out as @motion.ripple's pointer's press goes. Each a motion's way from its cause's
// moment (there at once with motion reduced), drawn as each frame is while it goes, let go with the node.

///|
/// One press's ripple: where in the node it went down, its way, when it went down, when it was let go (none yet).
priv struct PressRipple {
  x : Double
  y : Double
  /// how big the node was said to be as it went down (what its disc's size and drift are worked out by)
  w : Double
  h : Double
  /// its way in, 0 to .5 from when it went down
  enter_way : @motion.Way
  /// its way out, 0 to .5 more, said as it is let go to set out once its way in is over (nothing woken for it then)
  exit_way : @motion.Way
  at : Double
  mut lifted : Double?
  /// what is due for it (its end told, View::drawn_while's), let go with it
  due : Array[() -> Unit]
}

///|
/// What a press's look is told by its gesture: its press as it goes down (View::gesture's `press`), and a tap
/// (`tap`'s), which shows a press a finger let go before it showed.
priv struct PressLook {
  down : (@view.Drag) -> Unit
  tapped : (@view.Drag) -> Unit
}

///|
/// Make node `v` pressable with ripple look around `corner`, focus ring, and accessibility `role`/`label`/`selected`.
#callsite(autofill(loc))
pub fn pressed_box_node(
  v : @view.View,
  press : () -> Unit,
  corner : @view.Live[Double],
  role : @view.Role,
  label : () -> String,
  selected? : () -> Bool? = fn() { None },
  loc~ : SourceLoc,
) -> Unit {
  v
  .presses(Is(true))
  .focusable(Is(true))
  .focus_ring_theme()
  .says(By(fn() { Some(@view.said(role, label=label(), selected?=selected())) }))
  .on_press(press)
  |> ignore
  rippled_look(loc~, v, corner, press)
}

///|
/// A press's ripple and sink over node `v`, as big as the press says it is laid out as it goes down (Drag's `w`, `h`:
/// nothing read back of its layout), its corners
/// `corner`, the disc in `ink` as it is now (black at .1 by default, @motion.ripple_ink; a theme's, followed as it changes); sunk while pressed where `grounded` (a
/// ground of its own). Told the press's where, when and how big it is then; its letting go is the node's
/// (View::pressed). A finger's press in what scrolls shows once it has stayed tap_indication_ms (Ctx::pressed's, Compose's
/// clickable in a scrollable container): one that goes on to scroll shows nothing; a tap quicker than that shows
/// as it is let go. A pointer's press lays the ink over it evenly (no disc: @motion.ripple's), or, where `pointer` is
/// false (a row whose ground a pointer's press lights itself: the old view's press_ripple), shows nothing of its own.
#callsite(autofill(loc))
fn press_look(
  v : @view.View,
  corner : @view.Live[Double],
  grounded : () -> Bool,
  ink? : () -> Int64 = fn() { @motion.ripple_ink },
  pointer? : Bool = true,
  loc~ : SourceLoc,
) -> PressLook {
  // (the ripples' places, by their numbers, in the order they were made: each holds the ripple it shows now and
  // says when another took it over; one whose ripple has gone is shown again by the next press, no node made or
  // let go, nothing laid out again, as a sheet it is in still moves)
  let ripples : @signals.Signal[Array[Int]] = @signals.signal([], same=fn(a, b) { a == b })
  let made : Map[Int, (Ref[PressRipple], @signals.Signal[Int])] = Map([])
  let next = Ref(0)
  // (a finger's press in what scrolls not shown yet, and its showing, due)
  let late : Ref[@view.Drag?] = Ref(None)
  let late_due : Ref[() -> Unit] = Ref(fn() {  })
  // (sunk while down, back as it is let go, from where it is then; how far, by how big it is as it goes down)
  let sink = @motion.Way::new(0.0)
  let sink_most = Ref(0.0)
  v.scale(
    By(fn() {
      let s = sink.shown_on(v)
      1.0 - sink_most.val * s
    }),
    moves_besides=false,
  )
  |> ignore
  // (a pointer's press, @motion.ripple's: no disc, the ink over the whole of it, evenly, while `veil` has it; when the
  // button went down while it is, and its way out due)
  let veil = @motion.Way::new(0.0)
  let pointer_at : Ref[Double?] = Ref(None)
  let pointer_due : Ref[() -> Unit] = Ref(fn() {  })
  let pointer_once : @signals.Signal[Bool] = @signals.signal(false)
  // (let go at `at`: each ripple not yet let go on its way out once its way in is over; the sink back; a pointer's
  // press out from then, or from its way in's end where that is later, as @motion.ripple's)
  let lift = fn(at : Double) {
    match pointer_at.val {
      Some(down_at) => {
        pointer_at.val = None
        let out_at = dmax(at, down_at + @motion.pointer_enter_ms)
        pointer_due.val = v.at_moment(out_at, fn() {
          pointer_due.val = fn() {  }
          let out = @motion.tween(@motion.pointer_exit_ms, ease=Out)
          veil.go(0.0, out, at=out_at)
          sink.go(0.0, out, at=out_at)
        })
      }
      None => sink.go(0.0, @motion.tactile_bounce, at~)
    }
    for n in ripples.untracked() {
      guard made.get(n) is Some((slot, ver)) else { continue }
      let r = slot.val
      if r.lifted is None {
        r.lifted = Some(at)
        let out_at = dmax(at, r.at + @motion.ripple_enter_ms)
        r.exit_way.go(0.5, @motion.tween(@motion.ripple_exit_ms, ease=Leave), at=out_at)
        // (its disc told at the ripple's end, its binding drawn once more and the clock followed no more: nothing laid
        // out, no node made or let go, no hand worked out again)
        if r.exit_way.goes_at(at) {
          r.due.push(v.at_moment(r.exit_way.end(), fn() { ver.set(ver.untracked() + 1) }))
        }
      }
    }
  }
  v.reacts(fn() { v.pressed() }, fn(down) {
    // (sunk as the press goes down, by how big it is then: the press's own)
    if down {
      return
    }
    // (not shown yet: shown now only by a tap, told as it is let go)
    (late_due.val)()
    late_due.val = fn() {  }
    lift(v.cause_at())
  })
  // (the discs, over what it holds, cut to its corners: made as its first press shows, nothing of them before; a row or
  // a key that is never pressed holds none; over what it holds, no room of the column's to come into: at once)
  let pressed_once : @signals.Signal[Bool] = @signals.signal(false)
  v.show(fn() { pressed_once.get() }, at_once=true, fn(over) {
    over.made_for(loc).over(Is(true)).radius(corner).clips(Is(true)) |> ignore
    // (a pointer's veil over all of it, evenly: made as its first pointer's press shows)
    over.show(fn() { pointer_once.get() }, at_once=true, fn(ink_over) {
      ink_over
      .over(Is(true))
      .ground(By(fn() { @motion.pointer_veil(ink()) }))
      .alpha(By(fn() { veil.shown_on(ink_over) }))
      |> ignore
    })
    over.each(fn() { ripples.get() }, fn(n) { n }, fn(d, n) {
      match made.get(n.untracked()) {
        Some((slot, ver)) => ripple_disc(d, slot, ver, ink)
        None => ()
      }
    })
  })
  v.owns(fn() {
    (late_due.val)()
    (pointer_due.val)()
    for _, place in made {
      for f in place.0.val.due {
        f()
      }
    }
  })
  |> ignore
  // (press `d` shown from `at`)
  let show = fn(d : @view.Drag, at : Double) {
    // a pointer's: the whole of it pressed at once (on a ground of its own a little smaller too), no disc
    if @ui.pointing() is Mouse && !pointer {
      return
    }
    if @ui.pointing() is Mouse {
      (pointer_due.val)()
      pointer_due.val = fn() {  }
      pointer_at.val = Some(at)
      let in_ = @motion.tween(@motion.pointer_enter_ms, ease=Out)
      if @signals.untracked(grounded) {
        sink_most.val = @motion.pointer_sink(d.w, d.h)
        sink.go(1.0, in_, at~)
      }
      veil.go(1.0, in_, at~)
      pointer_once.set(true)
      pressed_once.set(true)
      return
    }
    if @signals.untracked(grounded) {
      sink_most.val = dmin(press_sink_most, @motion.press_sink / dmax(dmax(d.w, d.h), 1.0))
      sink.go(1.0, @motion.tactile_bounce, at~)
    }
    let enter_way = @motion.Way::new(0.0)
    enter_way.go(0.5, @motion.tween(@motion.ripple_enter_ms, ease=Out), at~)
    let exit_way = @motion.Way::new(0.0)
    let ripple = { x: d.x, y: d.y, w: d.w, h: d.h, enter_way, exit_way, at, lifted: None, due: [] }
    pressed_once.set(true)
    // (a place whose ripple has gone, out and over by now: shown again with this one)
    for n in ripples.untracked() {
      guard made.get(n) is Some((slot, ver)) else { continue }
      let was = slot.val
      if was.lifted is Some(_) && was.exit_way.target() >= 0.5 && at >= was.exit_way.end() {
        for f in was.due {
          f()
        }
        slot.val = ripple
        ver.set(ver.untracked() + 1)
        return
      }
    }
    // (every place's ripple still going: one more place)
    let n = next.val
    next.val = n + 1
    made[n] = (Ref(ripple), @signals.signal(0))
    let now = ripples.untracked().copy()
    now.push(n)
    ripples.set(now)
  }
  {
    down: fn(d) {
      (late_due.val)()
      late_due.val = fn() {  }
      late.val = None
      if @ui.pointing() is Finger && v.scroll_holding() is Some(_) {
        late.val = Some(d)
        let due = d.at + @ui.tap_indication_ms
        late_due.val = v.at_moment(due, fn() {
          late.val = None
          late_due.val = fn() {  }
          show(d, due)
        })
      } else {
        show(d, d.at)
      }
    },
    tapped: fn(t) {
      guard late.val is Some(d) else { return }
      late.val = None
      (late_due.val)()
      late_due.val = fn() {  }
      show(d, t.at)
      // (let go already: on its way out as its way in ends)
      if !@signals.untracked(fn() { v.pressed() }) {
        lift(t.at)
      }
    },
  }
}

///|
/// How far a node under a press sinks at most, a share of it (@motion.ripple's).
let press_sink_most : Double = 0.04

///|
/// One ripple place's disc in `d`, showing the ripple `slot` holds (another as `ver` says it was put there; as big as
/// that ripple says it was as it went down; nothing drawn once it has gone): its progress as the
/// ripple's way has it as each frame is drawn while it goes; its alpha the ink's from .13 of the way and fading from .4;
/// its radius 2.3 times that half diagonal and 10 more, times the progress; from where it went down to the middle by .5; blurred by .27
/// of its radius (@motion.ripple's).
fn ripple_disc(
  d : @view.View,
  slot : Ref[PressRipple],
  ver : @signals.Signal[Int],
  ink_now : () -> Int64,
) -> Unit {
  let geom = fn() {
    ver.get() |> ignore
    let r = slot.val
    let (w, h) = (r.w, r.h)
    let most = ((w * w + h * h).sqrt() / 2.0 + 10.0) * 2.3
    // (read as Way::shown_on reads a way, but asking no moment of its end of the hand (Tree::hand_at_end): a disc is
    // drawn alone, under no hand; told at its end by its place's `ver`, set then (lift), as View::drawn_while asks)
    r.enter_way.said()
    r.exit_way.said()
    let at = d.drawn_while(fn(t) { r.enter_way.goes_at(t) || r.exit_way.goes_at(t) })
    let k = if at == @double.infinity {
      r.enter_way.target() + r.exit_way.target()
    } else {
      r.enter_way.value_at(at) + r.exit_way.value_at(at)
    }
    let radius = most * k
    let t = dmin(1.0, k * 2.0)
    let cx = r.x + (w / 2.0 - r.x) * t
    let cy = r.y + (h / 2.0 - r.y) * t
    (cx, cy, radius, k)
  }
  d
  .over(Is(true))
  .offset(By(fn() {
    let (cx, cy, radius, _) = geom()
    (cx - radius, cy - radius)
  }))
  // (laid out once, as nothing: as big as it goes drawn so, its ground's, not laid out again each frame it grows)
  .width(Is(Some(0.0)))
  .height(Is(Some(0.0)))
  .ground_drawn(By(fn() {
    let radius = geom().2
    { dx: 0.0, dy: 0.0, dw: radius * 2.0, dh: radius * 2.0, corners: Some((radius, radius, radius, radius)) }
  }))
  .radius(By(fn() { geom().2 }))
  .shadow(By(fn() {
    let (_, _, radius, k) = geom()
    let sub = fn(a : Double, b : Double) { (dmin(dmax(k, a), b) - a) / (b - a) }
    let fade = dmin(sub(0.0, 0.13), 1.0 - sub(0.4, 1.0))
    let ink = ink_now()
    let alpha = ((ink & 0xFFL).to_double() * dmax(fade, 0.0)).round().to_int64()
    // (gone, or not seen: nothing drawn, as with no disc)
    if k >= 1.0 || fade <= 0.0 || alpha <= 0L {
      (0.0, 0.0, 0L)
    } else {
      (radius * 0.27, 0.0, (ink & 0xFFFFFF00L) | alpha)
    }
  }))
  |> ignore
}

///|
/// A row of a list that is pressed, held and asked for its menu as a file browser's is (a folder's entry: chosen by a
/// press, opened by the second of two, its menu by a right click or a finger's hold), `v` itself: pressed with the
/// keyboard's focus on it (Enter, Space) or by a screen reader `key_press`; let go where it was pressed (a tap, a
/// mouse's click, moved or not) `pressed` told the press (View::twice says whether it is the second of two); held by a
/// finger `held_ms` without leaving it, `held` (its menu, felt: menu_held_node; a mouse's held is a press as long as
/// any); a mouse's secondary button, `menu` where
/// it was pressed in the window. Its press rippling round `corner` (press_look's: a pointer's press shows nothing of its
/// own, the row's ground lighting itself). What it is to a screen reader is the row's own to say.
#callsite(autofill(loc))
pub fn row_presses_node(
  v : @view.View,
  corner : @view.Live[Double],
  key_press : () -> Unit,
  pressed : (@view.Drag) -> Unit,
  held : (@view.Drag) -> Unit,
  menu : (Double, Double) -> Unit,
  held_ms? : Double = @ui.long_press_ms,
  loc~ : SourceLoc,
) -> Unit {
  v.presses(Is(true)).focusable(Is(true)).focus_ring_theme().on_press(key_press).on_menu(fn(m) { menu(m.wx, m.wy) }) |> ignore
  let rippled = press_look(loc~, v, corner, fn() { false }, pointer=false)
  let on_it = fn(d : @view.Drag) { v.finger_target(d.wx, d.wy) }
  v.gesture(
    @ui.touch_slop(),
    press=rippled.down,
    tap=fn(d) {
      (rippled.tapped)(d)
      if on_it(d) {
        pressed(d)
      }
    },
    // (a finger's hold: a mouse's held is a press as long as any)
    hold=(held_ms, fn(d) {
      if @ui.pointing() is Finger {
        menu_held_node()
        held(d)
      }
    }),
    drag=fn(d) {
      // (a mouse's moved on it past the slop and let go on it: still a press, as a click is)
      if d.kind == Up && @ui.pointing() is Mouse && on_it(d) {
        pressed(d)
      }
    },
  )
  |> ignore
}

///|
/// A press's look on a button over mbui's headless button, handed it by that button's Hold (its press going down, a tap
/// a finger let go before it showed), never by a gesture of the look's own (headless.mbt: a look takes no press):
/// `kept` the look's, made as it draws; told only while `live`. A press held however long is still its press.
fn ripple_hold(kept : Ref[PressLook?], live : () -> Bool) -> @headless.Hold {
  @headless.Hold::new(
    @ui.touch_slop(),
    @ui.long_press_ms,
    fn() { false },
    down=fn(d) { if live() && kept.val is Some(r) { (r.down)(d) } },
    tapped=fn(d) { if live() && kept.val is Some(r) { (r.tapped)(d) } },
  )
}
