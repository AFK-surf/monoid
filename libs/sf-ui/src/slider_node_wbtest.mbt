// A slider as nodes (value_slider_node): read out a slider with its value; a press along it goes there, the keys step
// it; held, its value over it in a bubble, gone as it is let go; at rest nothing of the bubble, nothing reading the clock.

///|
/// Moments the tests here look at: held long enough for its drop and bubble to be whole, past every way.
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
  // (pressed three quarters along: its knob's middle runs from half a knob in to as far from its end)
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
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
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let bubble = t.words().map(fn(w) { w.0 })
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((said, bubble), (["40%"], ["7", "5", "%"]))
}

///|
test "a slider given the tips' layer: its bubble there, over the knob above the slider, whatever clips what holds it; gone as it is let go" {
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
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
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
    let x0 = 20.0 + 10.0 + 0.4 * (300.0 - 20.0)
    let x1 = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
    let y = 60.0 + 14.0
    t.press_at(x0, y)
    t.run_for(part_whole_ms)
    let shape_span_h = fn() {
      let sh = t.drawn_shapes()
      if sh.is_empty() {
        0.0
      } else {
        let mut lo = sh[0].1
        let mut hi = sh[0].1 + sh[0].3
        for s in sh {
          if s.1 < lo {
            lo = s.1
          }
          if s.1 + s.3 > hi {
            hi = s.1 + s.3
          }
        }
        hi - lo
      }
    }
    if solid || reduced {
      assert_eq(t.drawn_glass().length(), 0, msg="mode=\{mode}: solid/reduced must draw 0 glass while held")
      assert_true(
        shape_span_h() >= 20.0,
        msg="mode=\{mode}: solid/reduced fallback keeps meniscus drop (height \{shape_span_h()})",
      )
    } else {
      let glass = t.drawn_glass()
      assert_eq(glass.length(), 1, msg="mode=\{mode}: held must draw 1 clear liquid glass lens")
      assert_eq(glass[0].4, 6, msg="mode=\{mode}: lens must be kind == 6")
      assert_true(
        shape_span_h() <= 12.0,
        msg="mode=\{mode}: GPU glass mode must omit opaque meniscus drop (span=\{shape_span_h()} <= 12pt)",
      )
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
test "value_slider_node: elastic track thickening 4pt -> 8pt and horizontal liquid-pill lens proportion with laid == 0" {
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
  let track_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == track_col && r.2 > 200.0 })
    assert_eq(rs.length(), 1, msg="expected 1 value_slider background track rect")
    rs[0]
  }
  let rest_tr = track_rect()
  assert_true((rest_tr.3 - 4.0).abs() < 0.05, msg="rest track height must be 4pt, got \{rest_tr.3}")
  let rest_cy = rest_tr.1 + rest_tr.3 / 2.0

  // Press and hold: track thickens from 4pt to ~8pt centered at rest_cy, lens is a horizontal pill (lw > lh).
  let x0 = 20.0 + 10.0 + 0.4 * (300.0 - 20.0)
  let x1 = 20.0 + 10.0 + 0.72 * (300.0 - 20.0)
  let y = 60.0 + 14.0
  t.press_at(x0, y)
  t.run_for(slider_held_ms)
  let held_tr = track_rect()
  assert_true(held_tr.3 >= 7.5 && held_tr.3 <= 8.6, msg="held track height must thicken to ~8pt, got \{held_tr.3}")
  let held_cy = held_tr.1 + held_tr.3 / 2.0
  assert_true((held_cy - rest_cy).abs() < 0.1, msg="thickened track must stay centered (\{held_cy} vs \{rest_cy})")

  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1, msg="held must draw 1 clear liquid glass lens")
  let lw = lenses[0][2]
  let lh = lenses[0][3]
  assert_true(
    lw >= 34.5 && lw <= 38.0 && lh >= 23.0 && lh <= 26.0 && lw / lh >= 1.40,
    msg="held lens must be iOS 26 horizontal liquid pill (~36x24.4pt, ~1.48:1), got \{lw}x\{lh}",
  )
  let sh = t.drawn_shapes()
  assert_true(!sh.is_empty(), msg="held slider must draw thickened active track capsule")
  let mut sh_lo = sh[0].1
  let mut sh_hi = sh[0].1 + sh[0].3
  for s in sh {
    if s.1 < sh_lo {
      sh_lo = s.1
    }
    if s.1 + s.3 > sh_hi {
      sh_hi = s.1 + s.3
    }
  }
  assert_true(
    sh_hi - sh_lo <= 12.0,
    msg="GPU glass mode must draw only clean ~8pt thickened track capsule (no opaque meniscus blob), got span \{sh_hi - sh_lo}",
  )

  // Dragging must not trigger relayout.
  t.tree_frames_from_now()
  t.move_to(x1, y)
  t.run_for(part_whole_ms / 2.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="value_slider_node drag must not relayout: \{Repr(f)}")
  }

  // Release and settle: track returns to 4pt.
  t.release(x1, y)
  t.run_for(slider_past_ms)
  let done_tr = track_rect()
  assert_true((done_tr.3 - 4.0).abs() < 0.05, msg="settled track height must return to 4pt, got \{done_tr.3}")
}
