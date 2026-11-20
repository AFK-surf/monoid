// way_line_node in a column 400 across a window, the same steps at each width: what it leaves out and where the rest
// stand, at a width all fit in and at narrower ones.

///|
/// The way's look in these (the narrow files' crumbs).
fn ways_look() -> WayLook {
  {
    line: @ui.css("row pt=S0_5 pb=S1 align=ACenter"),
    step: @ui.css("px=S1 py=S1 radius=Lg"),
    words: @ui.text_style(size=Meta, color=Muted, wrap=false),
    here: @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false),
    chevron: 12.0,
    chevron_ink: theme().p.subtle,
  }
}

///|
/// The steps of these.
fn ways_steps() -> Array[String] {
  ["所有位置", "Willow · 文档", "项目", "设计稿", "二〇二六年终"]
}

///|
/// A window holding way_line_node 400 across, in a column `w` wide; the steps gone to. `menus`: 1000 by 600, it 100
/// further across (a menu beside it kept in the window by neither of its edges), what is presented (a …'s menu) drawn over it as the app's window draws it (presented, in an
/// old view over all of it; the tree's, presented_nodes).
fn ways_tester(w : Double, went : Array[Int], menus? : Bool = false) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=if menus { 1000.0 } else { 800.0 }, h=if menus { 600.0 } else { 200.0 }, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).padding(Is((if menus { 100.0 } else { 0.0 }, 0.0, 0.0, 0.0))) |> ignore
    root.box(fn(g) { g.width(Is(Some(400.0))) |> ignore }) |> ignore
    root.box(fn(h) {
      h.width(Is(Some(w))).height(Is(Some(100.0))) |> ignore
      way_line_node(h, ways_steps, ways_look, fn(i) { went.push(i) }) |> ignore
    })
    |> ignore
    if menus {
      @ui.old(root, fn(c) { presented(c) }).over(Is(true)) |> @ui.old_takes_own |> ignore
      presented_nodes(root)
    }
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Which of the steps (and the …, `way_more`) the column from `x0` draws, in the steps' order, the … where it stands.
fn ways_shown(t : @ui.Tester, x0 : Double) -> Array[String] {
  let drawn = t.words().filter(fn(w) { w.1 >= x0 - 0.5 && w.1 < x0 + 399.5 && w.5 > 0.0 })
  drawn.sort_by(fn(a, b) { a.1.compare(b.1) })
  drawn.map(fn(w) { if w.0 == way_more { way_more } else { w.0 } })
}

///|
test "way_line_node: room for all, every step and no …; narrower, those between leave for a … from the one after the first, the last staying" {
  let steps = ways_steps()
  let mut was = steps.length() + 1
  for w in [360.0, 240.0, 170.0, 110.0] {
    let t = ways_tester(w, [])
    let shown = ways_shown(t, 400.0)
    if w == 360.0 {
      assert_eq(shown, steps, msg="room for all")
    } else {
      assert_true(shown.contains(way_more), msg="\{w} wide: \{Repr(shown)}")
    }
    assert_true(shown.contains(steps[steps.length() - 1]), msg="\{w} wide: the last \{Repr(shown)}")
    assert_true(!shown.contains(steps[1]) || w == 360.0, msg="\{w} wide: the one after the first leaves first \{Repr(shown)}")
    // (in their order)
    let kept = shown.filter(fn(x) { x != way_more }).map(fn(x) { steps.search(x).unwrap() })
    for k in 1..<kept.length() {
      assert_true(kept[k - 1] < kept[k], msg="\{w} wide: \{Repr(shown)}")
    }
    // (narrower, no more drawn)
    assert_true(shown.length() <= was, msg="\{w} wide: \{Repr(shown)}")
    was = shown.length()
  }
}

///|
test "way_line_node: a step pressed goes to it" {
  let went : Array[Int] = []
  let t = ways_tester(360.0, went)
  let w = t.words().filter(fn(w) { w.0 == "项目" && w.1 >= 399.5 })[0]
  t.tap(w.1 + w.3 / 2.0, w.2 + w.4 / 2.0)
  assert_eq(went, [2])
}

///|
/// What is drawn in the column from `x0` (its glyphs, its chevrons, any ground), each its kind, where it stands in the
/// column's terms and its size, to a hundredth, in one order.
fn ways_drawn(t : @ui.Tester, x0 : Double) -> Array[String] {
  let r = fn(x : Double) { ((x * 100.0).round() / 100.0).to_string() }
  let out = t.drawn_instances()
    // (not a shape's pieces, kind 12: not in the window's terms, drawn_instances_keyed's)
    .filter(fn(a) { a[5] != 12.0 && a[0] >= x0 - 0.5 && a[0] < x0 + 399.5 && a[2] > 0.0 && a[3] > 0.0 })
    .map(fn(a) { "\{a[5]}@\{r(a[0] - x0)},\{r(a[1])} \{r(a[2])}x\{r(a[3])}" })
  out.sort()
  out
}

///|
test "way_line_node: at each width, its chevrons and all else drawn within its column" {
  for w in [360.0, 240.0, 170.0, 110.0] {
    let t = ways_tester(w, [])
    let drawn = ways_drawn(t, 400.0)
    assert_true(drawn.length() > 0, msg="\{w} wide")
    let out = t
      .drawn_instances()
      .filter(fn(a) { a[5] != 12.0 && a[0] >= 399.5 && a[2] > 0.0 && a[3] > 0.0 && a[0] + a[2] > 400.0 + w + 0.5 })
    assert_eq(out.length(), 0, msg="\{w} wide: past its column \{Repr(out)}")
  }
}

///|
test "way_line_node: its … offers the steps left out, in their order, under it; one pressed goes to it" {
  for w in [170.0, 110.0] {
    let went : Array[Int] = []
    let t = ways_tester(w, went, menus=true)
    // (the menu the … in the column from `x0` opens: what is drawn that was not, each where it stands from the …; then
    // its last pressed)
    let offered = fn(x0 : Double) raise {
      let in_col = fn(x : Double) { x >= x0 - 0.5 && x < x0 + 399.5 }
      let more = t.words().filter(fn(w) { w.0 == way_more && in_col(w.1) && w.5 > 0.0 })
      guard more.length() == 1 else { @halt.saying("\{w} wide, from \{x0}: no … (\{more.length()})") }
      let (mx, my) = (more[0].1, more[0].2)
      let before = t.words().filter(fn(w) { w.5 > 0.0 }).map(fn(w) { "\{w.0}@\{w.1},\{w.2}" })
      t.tap(mx + more[0].3 / 2.0, my + more[0].4 / 2.0)
      t.run_for(@ui.move_most_ms)
      let items = t.words().filter(fn(w) { w.5 > 0.0 && !before.contains("\{w.0}@\{w.1},\{w.2}") })
      // (under the …, in the order they stand)
      let under = items.copy()
      under.sort_by(fn(a, b) { a.2.compare(b.2) })
      assert_true(under.iter().all(fn(w) { w.2 > my }), msg="\{w} wide: under the …: \{Repr(under)}")
      let said = under.map(fn(w) { w.0 })
      guard items.length() > 0 else { @halt.saying("\{w} wide, from \{x0}: nothing offered") }
      let last = items.iter().fold(init=items[0], fn(a, b) { if b.2 > a.2 { b } else { a } })
      t.tap(last.1 + last.3 / 2.0, last.2 + last.4 / 2.0)
      t.run_for(@ui.move_most_ms)
      said
    }
    let new = offered(500.0)
    // (steps before the last, in their order)
    let steps = ways_steps()
    let at = new.map(fn(x) { steps.search(x).unwrap_or(-1) })
    for k in 0..<at.length() {
      assert_true(at[k] >= 0 && at[k] < steps.length() - 1 && (k == 0 || at[k - 1] < at[k]), msg="\{w} wide: \{Repr(new)}")
    }
    assert_eq(went.length(), 1, msg="\{w} wide: \{Repr(went)}")
    // (the last offered is the last left out: the step before the last but one's, left out at either width)
    assert_true(went[0] >= 1 && went[0] <= 3, msg="\{w} wide: \{Repr(went)}")
  }
}

///|
/// A window 1000 by 600 holding way_line_node alone, in a column 170 wide against its right side 100 in (the … where
/// the window's width puts it: further left in a narrower one), what is presented drawn over it as the app's window
/// draws it; the steps gone to.
fn way_menu_tester(went : Array[Int]) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=1000.0, h=600.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).padding(Is((0.0, 100.0, 0.0, 0.0))) |> ignore
    root.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    root.box(fn(h) {
      h.width(Is(Some(170.0))).height(Is(Some(100.0))) |> ignore
      way_line_node(h, ways_steps, ways_look, fn(i) { went.push(i) }) |> ignore
    })
    |> ignore
    @ui.old(root, fn(c) { presented(c) }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "way_line_node: its …'s menu opened by the keyboard and shut by Escape gives the focus back to the …" {
  let more = t("common.more")
  let t = way_menu_tester([])
  t.act(Button, Focus, label=more)
  let before = t.focused().map(fn(s) { s.label })
  t.enter()
  t.run_for(@ui.move_most_ms)
  let opened = presenting()
  let inside = t.focused().map(fn(s) { s.label })
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(
    (before, opened, inside != Some(more), presenting(), t.focused().map(fn(s) { s.label })),
    (Some(more), true, true, false, Some(more)),
  )
}

///|
test "way_line_node: its …'s menu, open while the window narrows, stays beside the … where it is now" {
  let t = way_menu_tester([])
  let more_at = fn() {
    let m = t.words().filter(fn(w) { w.0 == way_more && w.5 > 0.0 })
    guard m.length() == 1 else { @halt.saying("no … (\{m.length()})") }
    (m[0].1, m[0].2, m[0].3, m[0].4)
  }
  let (mx, my, mw, mh) = more_at()
  let before = t.words().filter(fn(w) { w.5 > 0.0 }).map(fn(w) { w.0 })
  t.tap(mx + mw / 2.0, my + mh / 2.0)
  t.run_for(@ui.move_most_ms)
  let items = t.words().filter(fn(w) { w.5 > 0.0 && !before.contains(w.0) }).map(fn(w) { w.0 })
  guard items.length() > 0 else { @halt.saying("nothing offered") }
  // (each item where it stands from the …)
  let from_more = fn() {
    let (x, y, _, _) = more_at()
    t.words().filter(fn(w) { w.5 > 0.0 && items.contains(w.0) }).map(fn(w) { "\{w.0}@\{w.1 - x},\{w.2 - y}" })
  }
  let wide = from_more()
  t.resize(900.0, 600.0)
  t.run_for(@ui.move_most_ms)
  let (nx, _, _, _) = more_at()
  let narrow = from_more()
  let open = presenting()
  // (shut, so nothing of it is left open for what runs after in this process)
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(open && !presenting(), msg="open while it narrowed, shut after")
  assert_eq(nx, mx - 100.0, msg="the … 100 further left")
  assert_eq(narrow, wide)
}
