// A room opening on what it holds and closing on it as a node of the window's tree (reveal's `middle`, made once): as tall as its share of what it holds is laid out, from the moment what opens or closes it changes, its way
// as long as a move as far as what it holds is tall then (a Move per point of it); what it holds kept in its middle, as
// big as it is open and faded in from half open, about the middle of what it draws, cut at both ends softly; all of
// it, as tall as it is, once it is open; none of it pressed or read out once it is closing or shut.

///|
/// What `make` makes in a room in `parent` that opens as `open` says it is and closes as it says it is not (each from
/// where it is at that moment, its way as long as a Move as far as what it holds is laid out tall then), still as it is
/// made: as tall as its share of what it holds comes to (View::opens: the same layout's, whatever its words or width
/// come to meanwhile), what it holds in its middle (row_held_look: as big as it is open about the middle of what it
/// draws, coming in from half open), cut at its top and foot softly (View::cuts_softly); as tall as what it holds once
/// it is open; nothing tall once it is shut. Taking no press and read out as nothing from the moment it closes. The
/// room's node. `deferred`: what `make` makes is made only as it first opens (what it holds asks for what it shows as it
/// is made: none of it asked while it is shut), kept from then.
pub fn reveal_node(
  parent : @view.View,
  open : () -> Bool,
  make : (@view.View) -> Unit,
  deferred? : Bool = false,
) -> @view.View {
  let way = NodeWay::new(if @signals.untracked(open) { 1.0 } else { 0.0 })
  let made = @signals.signal(!deferred || @signals.untracked(open), same=fn(a, b) { a == b })
  parent.box(fn(room) {
    // (as tall as it is laid out, whatever room it has: what is past its room cut)
    let held = room.box(fn(h) {
      h.shrink(Is(0.0)) |> ignore
      // (open as it is made: made with it, laid out in the same pass as what is round it)
      if made.untracked() {
        make(h)
      } else {
        // (its way this room's: at once)
        h.show(fn() { made.get() }, make, at_once=true)
      }
    })
    let shown = fn() { way.shown(room) }
    room.reacts(open, fn(o) {
      // (how far it goes: what it holds is laid out tall at this moment, the way's length said once, not followed)
      let go = fn() { way.go(room, if o { 1.0 } else { 0.0 }, moved().per_unit(held.laid_size().1)) }
      if o && !made.untracked() {
        // (made as it first opens: its way set off at this moment once what this change makes is made, laid out tall
        // as it is then)
        made.set(true)
        @signals.after_flush(go)
      } else {
        go()
      }
    })
    room
    .opens(By(fn() {
      let k = shown()
      if k >= 1.0 {
        None
      } else {
        Some(if k > 0.0 { k } else { 0.0 })
      }
    }))
    // (shut: no room of its own, nor the gap what holds it leaves before it, as an old view's room shut is not built)
    .laid_nowhere(By(fn() { !open() && shown() <= 0.0 }))
    .clips(By(fn() { shown() < 1.0 }))
    .cuts_softly(By(fn() { shown() < 1.0 }))
    .presses(By(fn() { open() }))
    .hides(By(fn() { !open() }))
    |> ignore
    held
    .scale(By(fn() {
      let k = shown()
      if k < 0.0 {
        0.0
      } else if k > 1.0 {
        1.0
      } else {
        k
      }
    }), about=Drawn)
    .alpha(By(fn() {
      let k = shown()
      if k >= 1.0 {
        1.0
      } else {
        let a = (k - @ui.row_gone_at) / (1.0 - @ui.row_gone_at)
        if a > 0.0 {
          a
        } else {
          0.0
        }
      }
    }))
    |> ignore
  })
}

///|
/// Soft-edged curtain reveal overlay in `parent`: while `active()` triggers a reveal, sweeps a multi-strip gradient
/// curtain downward across `parent` over `duration_ms` (default 1100 ms) using a `NodeWay` and pixel-snapped
/// `View::moved_by` (zero Flex relayout), fading out after `wait_after_ms` (default 800 ms) over `wait_out_ms`
/// (default 300 ms). Unmounts its strips automatically once complete so zero animation overhead remains at rest.
pub fn curtain_reveal(
  parent : @view.View,
  active : () -> Bool,
  color : () -> Int64,
  duration_ms? : Double = 1100.0,
  wait_after_ms? : Double = 800.0,
  wait_out_ms? : Double = 300.0,
  steps? : Int = 16,
) -> Unit {
  let n_steps = if steps > 0 { steps } else { 1 }
  let steps_d = n_steps.to_double()
  let way = NodeWay::new(0.0)
  parent.box(fn(v) {
    v
    .over(Is(true))
    .fills_across(Is(true))
    .height_share(Is(1.0))
    .presses(Is(false))
    .points(Is(false))
    |> ignore
    v.reacts(active, fn(on) {
      if on {
        way.go_from(v, 0.0, 1.0, tween(duration_ms, ease=Linear))
      } else {
        way.put(0.0)
      }
    })
    let ends = fn(_w : Double, _h : Double) {
      way.target() |> ignore
      way.end()
    }
    let gone = fn(n : @view.View) {
      let p = way.shown(n)
      if wait_out_ms <= 0.0 {
        if p * duration_ms >= wait_after_ms { 0.0 } else { 1.0 }
      } else {
        1.0 - dmin(1.0, dmax(0.0, (p * duration_ms - wait_after_ms) / wait_out_ms))
      }
    }
    v.show(at_once=true, fn() { active() && way.goes(v) }, fn(overlay) {
      overlay
      .over(Is(true))
      .fills_across(Is(true))
      .height_share(Is(1.0))
      .clips(Is(true))
      .presses(Is(false))
      .points(Is(false))
      |> ignore
      let strip = fn(k : Int, share : Double, alpha : Double) {
        overlay.box(fn(s) {
          s.over(Is(true)).fills_across(Is(true)).height_share(Is(share)) |> ignore
          s
          .ground(By(color))
          .alpha(By(fn() { alpha * gone(s) }))
          .moved_by(
            fn(_w, h, t) {
              let e = @ui.Out.at(dmin(1.0, dmax(0.0, way.value_at(t))))
              let frame = h / share
              let y = frame * (-0.5 + 1.5 * e) + k.to_double() * frame * 0.5 / steps_d
              let ps = s.pixel_scale()
              (0.0, if ps > 0.0 { (y * ps).round() / ps } else { y })
            },
            ends,
          )
          |> ignore
        })
        |> ignore
      }
      for k in 0..<n_steps {
        strip(k, 0.5 / steps_d, (k.to_double() + 0.5) / steps_d)
      }
      strip(n_steps, 1.0, 1.0)
    })
  })
  |> ignore
}
