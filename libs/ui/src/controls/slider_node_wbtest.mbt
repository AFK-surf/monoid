// Unified iOS 26 value slider (`value_slider_node` delegating to `@glass.liquid_slider_node`):
// semantic readout & keyboard stepping, flush 40x24 capsule geometry, 6->10pt elastic track thickening,
// lazy 1.5x (~60x36pt) clear liquid glass lens with zero relayout (`laid == 0`), and unclipped value bubble in `tips`.

///|
/// Moments the tests here look at: held long enough for the lens and bubble to reach peak, and past every spring.
let slider_held_ms : Double = 400.0

///|
let slider_past_ms : Double = 1000.0

///|
/// A slider 300 wide at the top left of a window 390 by 300, `v` as it is, moved as it is told.
fn slider_case(v : @signals.Signal[Double], format? : (Int) -> String = fn(n) { n.to_string() }) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      b.box(fn(s) {
        s.width(Is(Some(300.0))) |> ignore
        value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, format~) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a slider as nodes: read out a slider named by its label with its value; the keys step it, End to its most" {
  let v = @signals.signal(40.0)
  let t = slider_case(v)
  let said = t.semantics().filter(fn(n) { n.role == Slider }).map(fn(n) { "\{n.label} \{n.value}" })
  t.key(@ui.key_tab)
  t.frame()
  t.key(@ui.key_code_right)
  t.frame()
  let stepped = v.get()
  t.key(@ui.key_code_end)
  t.frame()
  assert_eq((said, stepped, v.get()), (["音量 40"], 41.0, 100.0))
}

///|
test "a slider held: there where it is pressed, its value over it while held, none of it once let go and at rest" {
  let v = @signals.signal(40.0)
  let t = slider_case(v)
  let words_rest = t.words().length()
  // (pressed three quarters along: flush 40pt capsule thumb middle runs from 20pt in to 20pt from its end)
  let x = 20.0 + 20.0 + 0.75 * (300.0 - 40.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let held_v = v.get()
  let bubble = t.words().filter(fn(w) { w.0 == "7" || w.0 == "5" }).length()
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((words_rest, held_v, bubble, t.words().length()), (0, 75.0, 2, 0))
}

///|
test "a slider written as it says: read out so, and so in its bubble while held" {
  let v = @signals.signal(40.0)
  let t = slider_case(v, format=fn(n) { "\{n}%" })
  let said = t.semantics().filter(fn(n) { n.role == Slider }).map(fn(n) { n.value })
  let x = 20.0 + 20.0 + 0.75 * (300.0 - 40.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let bubble = t.words().map(fn(w) { w.0 })
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((said, bubble), (["40%"], ["7", "5", "%"]))
}

///|
test "a slider given the tips' layer: its bubble there, over the thumb above the slider, whatever clips what holds it; gone as it is let go" {
  let v = @signals.signal(40.0)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(b) {
      b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      b.box(fn(s) {
        // (what holds it cut to itself, its top right at the slider's: a bubble in it would be cut away)
        s.width(Is(Some(300.0))).clips(Is(true)) |> ignore
        value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, format=fn(n) { "\{n}%" }, tips~) |> ignore
      })
      |> ignore
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  let x = 20.0 + 20.0 + 0.75 * (300.0 - 40.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let bubble = t.words().filter(fn(w) { w.0 == "7" || w.0 == "5" || w.0 == "%" })
  let over_it = bubble.length() == 3 && bubble.all(fn(w) { w.2 + w.4 <= 60.0 && (w.1 - x).abs() < 30.0 })
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((v.get(), over_it, t.words().length()), (75.0, true, 0))
}

///|
test "value_slider_node: lazy clear liquid glass lens on press, zero relayout during drag, and solid/reduced_motion guards" {
  for mode in [0, 1, 2] {
    let solid = mode == 1
    let reduced = mode == 2
    let v = @signals.signal(40.0)
    let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=0)
    t.check_looks(false)
    @ui.set_glass_solid(if solid { Some(true) } else { None })
    if reduced {
      t.set_reduce_motion(true)
    }
    @ui.set_view_app(
      fn(root) {
        root.box(fn(b) {
          b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
          b.box(fn(s) {
            s.width(Is(Some(300.0))) |> ignore
            value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, bubble=false) |> ignore
          })
          |> ignore
        })
        |> ignore
      },
      theme=ui_theme_now,
    )
    t.draw()
    assert_eq(t.drawn_glass().length(), 0, msg="mode=\{mode}: rest must draw 0 glass")
    let x0 = 20.0 + 20.0 + 0.4 * (300.0 - 40.0)
    let x1 = 20.0 + 20.0 + 0.75 * (300.0 - 40.0)
    let y = 60.0 + 14.0
    t.press_at(x0, y)
    t.run_for(part_whole_ms)
    if solid || reduced {
      assert_eq(t.drawn_glass().length(), 0, msg="mode=\{mode}: solid/reduced must draw 0 glass while held")
    } else {
      let glass = t.drawn_glass()
      assert_eq(glass.length(), 1, msg="mode=\{mode}: held must draw 1 clear liquid glass lens")
      assert_eq(glass[0].4, 6, msg="mode=\{mode}: lens must be kind == 6")
    }
    t.tree_frames_from_now()
    t.move_to(x1, y)
    t.run_for(part_whole_ms / 2.0)
    for f in t.tree_frames() {
      assert_eq(f.laid, 0, msg="mode=\{mode}: slider drag must not trigger relayout: \{Repr(f)}")
    }
    t.release(x1, y)
    t.run_for(slider_past_ms)
    assert_eq(t.drawn_glass().length(), 0, msg="mode=\{mode}: settled must return to 0 glass")
    @ui.set_glass_solid(None)
  }
}

///|
test "value_slider_node: unified iOS 27 crisp 6pt track and ~60x36pt clear pill lens with laid == 0" {
  let v = @signals.signal(40.0)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(b) {
        b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
        b.box(fn(s) {
          s.width(Is(Some(300.0))) |> ignore
          value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, bubble=false) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let track_col = theme().p.line_strong
  let accent_col = theme().p.accent
  let track_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == track_col && r.2 > 200.0 })
    assert_eq(rs.length(), 1, msg="expected 1 value_slider background track rect")
    rs[0]
  }
  let fill_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == accent_col && r.2 > 20.0 })
    assert_eq(rs.length(), 1, msg="expected 1 value_slider active fill rect")
    rs[0]
  }
  let rest_tr = track_rect()
  let rest_fl = fill_rect()
  assert_true((rest_tr.3 - 6.0).abs() < 0.05, msg="rest track height must be 6pt, got \{rest_tr.3}")
  assert_true((rest_fl.3 - 6.0).abs() < 0.05, msg="rest fill height must be 6pt, got \{rest_fl.3}")
  let rest_cy = rest_tr.1 + rest_tr.3 / 2.0

  // Press and hold: track & fill stay crisp 6pt centered at rest_cy, lens is ~60x36pt horizontal liquid pill.
  let x0 = 20.0 + 20.0 + 0.4 * (300.0 - 40.0)
  let x1 = 20.0 + 20.0 + 0.72 * (300.0 - 40.0)
  let y = 60.0 + 14.0
  t.press_at(x0, y)
  t.run_for(slider_held_ms)
  let held_tr = track_rect()
  let held_fl = fill_rect()
  assert_true((held_tr.3 - 6.0).abs() < 0.05, msg="held track height must stay crisp 6pt, got \{held_tr.3}")
  assert_true((held_fl.3 - 6.0).abs() < 0.05, msg="held fill height must stay crisp 6pt, got \{held_fl.3}")
  let held_cy = held_tr.1 + held_tr.3 / 2.0
  assert_true((held_cy - rest_cy).abs() < 0.1, msg="track must stay centered (\{held_cy} vs \{rest_cy})")

  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1, msg="held must draw 1 clear liquid glass lens")
  let lw = lenses[0][2]
  let lh = lenses[0][3]
  assert_true(
    lw >= 57.0 && lw <= 63.0 && lh >= 34.0 && lh <= 38.0,
    msg="held lens must be unified iOS 27 liquid pill (~60x36pt), got \{lw}x\{lh}",
  )

  // Dragging must not trigger relayout.
  t.tree_frames_from_now()
  t.move_to(x1, y)
  t.run_for(part_whole_ms / 2.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="value_slider_node drag must not relayout: \{Repr(f)}")
  }

  // Release and settle: track & fill return to 6pt.
  t.release(x1, y)
  t.run_for(slider_past_ms)
  let done_tr = track_rect()
  let done_fl = fill_rect()
  assert_true((done_tr.3 - 6.0).abs() < 0.05, msg="settled track height must return to 6pt, got \{done_tr.3}")
  assert_true((done_fl.3 - 6.0).abs() < 0.05, msg="settled fill height must return to 6pt, got \{done_fl.3}")
}
