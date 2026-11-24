// One of a few levels in order as nodes of the window's tree (stops' made-once form, seg.mbt: how hard a model thinks
// on a sheet): single-row standard pill `@glass.liquid_slider_node` (6pt track, 38x24 pure white capsule thumb, solid
// accent fill, lazy-mounted 1.5x clear refraction loupe) paired with a fixed-width right-side current/preview stop
// label, sf-ui's optimistic `Stops` state machine (`Stops::reset`), and semantic label readout.

///|
let stops_label_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)

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
  let shown : @signals.Signal[Int] = @signals.signal(-1)
  let told = fn(c : Int) {
    if state.expect >= 0 {
      if c == state.expect {
        state.expect = -1
        state.stale.clear()
        state.said = c
      } else if !state.stale.contains(c) {
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
  let count = @signals.untracked(fn() { labels().length() })
  let last = dmax(1.0, (count - 1).to_double())
  let pad = @ui.Space::px(S1)
  let thumb_h = @glass.slider_thumb_h
  let init_v = dmax(0.0, @signals.untracked(fn() { shown.get() }).to_double())
  let dd = @glass.DampedDrag::new(init_v, lo=0.0, hi=last, held_scale=@glass.slider_thumb_held_scale)
  parent.box(made_for=loc, fn(wrap) {
    // (room in its own box over and under the thumb for it held at its tallest, past its own padding: what holds it, a
    // sheet that scrolls, cuts what is drawn past its box; in its box, not a margin, so its gaps to what is over and
    // under it stay the spacing scale's)
    let reach = dmax(0.0, @glass.slider_held_reach(thumb_h) - pad)
    let high_held = fn() { button_height() + 2.0 * reach }
    style_node(wrap, fn() { stops_track }, in_row=true)
    wrap
    .ground(Is(0L))
    .min_height(By(fn() { Some(high_held()) }))
    .lines_up(Is(Some(Middle)))
    .padding(Is((pad, pad + reach, pad, pad + reach)))
    |> ignore
    wrap.reacts(at_start=false, fn() { (chosen(), state.resets.get()) }, fn(k) { told(k.0) })
    wrap
    .by_room(fn(inner, room) {
      let gap = @ui.Space::px(S2)
      inner
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(gap))
      |> ignore
      let label_w = fn() -> Double {
        inner.words_redone() |> ignore
        let size = node_sp(inner, theme().t.meta)
        let ls = labels()
        let mut widest = 0.0
        for s in ls {
          if s != "" {
            widest = dmax(widest, node_words_w(s, size, weight=500))
          }
        }
        let room_w = room.width()
        if widest <= 0.0 || room_w <= 0.0 {
          0.0
        } else {
          let want = widest.ceil() + 2.0
          let min_track = dmin(room_w * 0.65, dmax(96.0, count.to_double() * 24.0))
          dmin(want, dmax(0.0, room_w - gap - min_track))
        }
      }
      let sl = @glass.liquid_slider_node(
        inner,
        fn() { dmax(0.0, shown.get().to_double()) },
        fn(v) { pick_it(v.round().to_int()) },
        fn() { said },
        least=0.0,
        most=last,
        track_h=@glass.slider_track_h,
        thumb_w_px=@glass.slider_thumb_w,
        thumb_h_px=thumb_h,
        track_color=fn() { theme().p.line_strong },
        fill_color=fn() { theme().p.accent },
        stops=count,
        flush=true,
        value_bubble=None,
        drag=dd,
        loc~,
      )
      sl
      .grow(Is(1.0))
      .min_width(Is(Some(0.0)))
      .says(By(fn() {
        let ls = labels()
        let a = shown.get()
        let value = if a >= 0 && a < ls.length() { ls[a] } else { "" }
        Some(@view.said(Slider, label=said, value~, range=(0.0, dmax(0.0, a.to_double()), last), actions=[Increment, Decrement]))
      }))
      |> ignore
      inner.box(fn(lbl_box) {
        lbl_box
        .row(Is(true))
        .shrink(Is(0.0))
        .width(By(fn() { Some(label_w()) }))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(End))
        |> ignore
        let preview_text = fn() -> String {
          let ls = labels()
          let a = if dd.pressing() { dd.target().round().to_int() } else { shown.get() }
          if a >= 0 && a < ls.length() { ls[a] } else { "" }
        }
        words_node(lbl_box, preview_text, fn() { stops_label_words })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .cuts(Is(true))
        .allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
    })
    .grow(Is(1.0))
    .min_width(Is(Some(0.0)))
    |> ignore
  })
}
