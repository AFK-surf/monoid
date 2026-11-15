// One of a few levels in order as nodes of the window's tree (stops' made-once form, seg.mbt: how hard a model thinks
// on a sheet): a capsule track on the words' tint, a stop for each level across it, a dot each, the one under its thumb
// gone; its thumb over the stop it is at, a lifted capsule saying that level's name, as wide as the name needs. A
// finger takes the thumb along the track, to the stop under it and leaning a quarter of the way on toward the finger,
// on the ball's spring (@kit.follow_spring), each stop come to under it felt; let go, the level under it is picked (a
// tap is a press let go there). Held, the thumb a little larger and the bar's lens of liquid glass grown over it as it
// fades under the lens (glass_knob), gone as it is let go; where glass is solid, the capsule alone. Read out a slider
// of its levels, stepped by a screen reader and by the arrows with the keyboard's focus.

///|
/// The levels `labels` in `parent`, at `chosen()` (-1: none), `said` what a screen reader calls it, `state` what it
/// keeps (its caller's, one for each of them: Stops). The level it shows is its own once picked in it: shown from
/// then on whatever its caller says meanwhile that is no news (the level it had, an earlier pick's) until its caller
/// says that level back; a level its caller says that is news is shown as it is said (stops'). `on_pick`: what
/// choosing another level does, given its index, as it is chosen; where that does not take, its caller says so
/// (Stops::reset), and it shows what its caller says again. The node.
#callsite(autofill(loc))
pub fn stops_node(
  parent : @view.View,
  labels : () -> Array[String],
  chosen : () -> Int,
  state : Stops,
  said? : String = "",
  on_pick? : (Int) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> @view.View {
  // (the level it shows: as stops' works it out of what its caller says, told again as that changes and as it is reset)
  let shown : @signals.Signal[Int] = @signals.signal(-1)
  let told = fn(c : Int) {
    if state.expect >= 0 {
      if c == state.expect {
        // (what was picked here said back)
        state.expect = -1
        state.stale.clear()
        state.said = c
      } else if !state.stale.contains(c) {
        // (news from elsewhere while a pick was on its way)
        state.expect = -1
        state.stale.clear()
        state.said = c
        state.shown = c
      }
    } else if c != state.said {
      state.said = c
      state.shown = c
    }
    shown.set(state.shown)
  }
  @signals.untracked(fn() { told(chosen()) })
  let n = fn() { labels().length() }
  let last = fn() { dmax(0.0, (n() - 1).to_double()) }
  let pad = @ui.Space::px(S1)
  let high = fn() { button_height() }
  // (a finger on it: where along it, counted in stops; None while none is)
  let finger : @signals.Signal[Double?] = @signals.signal(None)
  let along = fn(px : Double, w : Double) -> Double? {
    let k = n()
    if k > 0 && w > 2.0 * pad {
      Some(dclamp((px - pad) / (w - 2.0 * pad) * k.to_double() - 0.5, -0.5, last() + 0.5))
    } else {
      None
    }
  }
  let stop_of = fn(p : Double) -> Int {
    let i = p.round().to_int()
    let k = n()
    if i < 0 {
      0
    } else if i > k - 1 {
      k - 1
    } else {
      i
    }
  }
  let at = fn() {
    match finger.get() {
      Some(fp) => stop_of(fp)
      None => shown.get()
    }
  }
  // (where its thumb goes, counted in stops: the stop it is at, leaning toward a finger)
  let goal = fn() {
    match finger.get() {
      Some(fp) => {
        let a = at().to_double()
        dclamp(a + (fp - a) * stops_lean, 0.0, last())
      }
      None => dmax(0.0, at().to_double())
    }
  }
  // (another level picked in it, as stops' does as it is let go: what its caller may say meanwhile that is no news)
  let pick_it = fn(i : Int) {
    if i < 0 || i == state.shown {
      return
    }
    for old in [(state.said, -1), (state.shown, -1), (state.expect, 0)] {
      if old.0 >= old.1 && old.0 != i && !state.stale.contains(old.0) {
        state.stale.push(old.0)
      }
    }
    state.stale.retain(fn(x) { x != i })
    state.expect = i
    state.shown = i
    shown.set(i)
    on_pick(i)
  }
  parent.box(made_for=loc, fn(track) {
    // (across the rest of the row it is in, as an old drag area filling its row: stops' `w=Fill(1.0)`)
    style_node(track, fn() { stops_track.then(@ui.style(h=Fixed(high()))) }, in_row=true)
    // (what its caller says, and again as it says a pick did not take: Stops::reset)
    track.reacts(at_start=false, fn() { (chosen(), state.resets.get()) }, fn(k) { told(k.0) })
    let felt = Ref(-1)
    track
    .presses(Is(true))
    .focusable(Is(true))
    .says(By(fn() {
      let k = n()
      let a = at()
      let value = if a >= 0 && a < k { labels()[a] } else { "" }
      Some(@view.said(Slider, label=said, value~, range=(0.0, dmax(0.0, a.to_double()), last()), actions=[Increment, Decrement]))
    }))
    .on_step(fn(by) {
      let k = n()
      if k > 0 {
        pick_it(dclamp((state.shown + by).to_double(), 0.0, (k - 1).to_double()).to_int())
      }
    })
    .on_key(fn(k) {
      if !track.focused() || k.mods != 0 {
        return false
      }
      // 3 Left, 4 Right, 5 Up, 6 Down (ui/desktop.mbt key_code_*)
      let by = if k.code == 3 || k.code == 6 {
        -1
      } else if k.code == 4 || k.code == 5 {
        1
      } else {
        0
      }
      if by == 0 || n() == 0 {
        return false
      }
      pick_it(dclamp((state.shown + by).to_double(), 0.0, (n() - 1).to_double()).to_int())
      true
    })
    .on_drag(fn(d) {
      match d.kind {
        Down | Moved =>
          match along(d.x, d.w) {
            Some(p) => {
              let i = stop_of(p)
              if d.kind is Moved && i != felt.val {
                @ui.haptic(TextHandleMove)
              }
              felt.val = i
              finger.set(Some(p))
            }
            None => ()
          }
        Up => {
          let i = match along(d.x, d.w) {
            Some(p) => stop_of(p)
            None => -1
          }
          felt.val = -1
          finger.set(None)
          pick_it(i)
        }
        Off => {
          felt.val = -1
          finger.set(None)
        }
      }
    })
    |> ignore
    // (what it holds by the room the track gives it: its stops' share of that, its thumb as wide as its name there)
    track
    .by_room(fn(inner, room) {
      let cell = fn() {
        let k = n()
        if k > 0 {
          room.width() / k.to_double()
        } else {
          0.0
        }
      }
      let thumb_h = fn() { high() - 2.0 * pad }
      // its stops, a dot each, the one under its thumb gone (each faded over dur_ms, eased out, from the moment it
      // comes under it or leaves it)
      inner.box(fn(row) {
        row.row(Is(true)).height(By(fn() { Some(thumb_h()) })) |> ignore
        for i in 0..<@signals.untracked(n) {
          row.box(fn(c) {
            style_node(c, fn() { stops_cell })
            let a = EdgeWay::new(if @signals.untracked(at) == i { 0.0 } else { 1.0 })
            c.reacts(at_start=false, fn() { at() == i }, fn(under) { a.go(c, if under { 0.0 } else { 1.0 }, dur_ms) })
            c.box(fn(d) {
              style_node(d, fn() { stops_dot })
              d.alpha(By(fn() { a.shown(d) })) |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      // its thumb over them: laid out at the stop it goes to, drawn where its spring has it on the way; held, a little
      // larger and the lens grown over it
      let p = EdgeWay::new(@signals.untracked(goal))
      inner.reacts(at_start=false, goal, fn(g) { p.go_by(inner, g, @kit.follow_spring) })
      let held = EdgeWay::new(0.0)
      inner.reacts(at_start=false, fn() { finger.get() is Some(_) }, fn(h) {
        held.go_by(inner, if h { 1.0 } else { 0.0 }, @motion.lift_spring)
      })
      let name = fn() {
        let a = at()
        labels().get(a).unwrap_or("")
      }
      let tw = fn() {
        inner.words_redone() |> ignore
        let words = node_words_w(name(), node_sp(inner, theme().t.ui), weight=500) + 2.0 * @ui.Space::px(S3)
        dmin(room.width(), dmax(cell(), words))
      }
      let left_at = fn(q : Double) -> Double { dclamp((q + 0.5) * cell() - tw() / 2.0, 0.0, dmax(0.0, room.width() - tw())) }
      let x_now = fn(v : @view.View) { left_at(dclamp(p.shown(v), 0.0, last())) }
      let lensed = fn(v : @view.View) { if v.glass_solid() { 0.0 } else { dmin(1.0, dmax(0.0, held.shown(v))) } }
      inner.show(fn() { at() >= 0 && n() > 0 }, fn(o) {
        // (over the stops, all of their room: what it holds placed in it from their start)
        o.over(Is(true)) |> ignore
        o.box(fn(ball) {
          style_node(ball, fn() { stops_ball })
          ball
          .over(Is(true))
          .width(By(fn() { Some(tw()) }))
          .height(By(fn() { Some(thumb_h()) }))
          .offset(By(fn() { (x_now(ball), 0.0) }))
          .alpha(By(fn() { 1.0 - lensed(ball) }))
          .scale(By(fn() { 1.0 + stops_held_grow * dmax(0.0, held.shown(ball)) }))
          |> ignore
        })
        |> ignore
        o.box(fn(w) {
          style_node(w, fn() { stops_name })
          w
          .over(Is(true))
          .width(By(fn() { Some(tw()) }))
          .height(By(fn() { Some(thumb_h()) }))
          .offset(By(fn() { (x_now(w), 0.0) }))
          |> ignore
          words_node(w, name, fn() { stops_words }) |> ignore
        })
        |> ignore
        // (the bar's lens as the library has it for a knob this small (glass_knob), drawn only while it is held)
        o.show(fn() { !o.glass_solid() }, fn(l) {
          l.over(Is(true)) |> ignore
          l.box(fn(lens) {
            style_node(lens, fn() { stops_ball_room })
            lens
            .over(Is(true))
            .width(By(fn() { Some(tw()) }))
            .height(By(fn() { Some(thumb_h()) }))
            .offset(By(fn() { (x_now(lens), 0.0) }))
            .glass(Is(Some(glass_knob())))
            .alpha(By(fn() { lensed(lens) }))
            .scale(By(fn() {
              (1.0 + stops_held_grow * dmax(0.0, held.shown(lens))) * (1.0 + stops_lens_grow * lensed(lens))
            }))
            |> ignore
          })
          |> ignore
        })
      })
    })
    .grow(Is(1.0))
    |> ignore
  })
}
