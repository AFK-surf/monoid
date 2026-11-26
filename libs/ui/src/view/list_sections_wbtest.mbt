// Virtualized list bidirectional section stacking (`ListPlace::set_sections`, `View::sticky_section`,
// `ListPlace::bring_section`, `ListPlace::section_state`):
// - All 3 Astra counterexamples (unit + full Tree)
// - Dual-group deep scroll clickability & foreground hit layering (covered body rows cannot steal presses)
// - Small-screen `top_edge = top_covered - 8` (+8pt) `bring_section` landing & trailing `load_more` + `foot` reachability
// - 0.5px continuous scroll sweep across `slots_cover` mount/unmount boundaries (0px jump, 0 overlap, 0 gap, stable NodeId)
// - Deep collapse, mid-push-out collapse, last-section collapse, and mid-curtain re-expand
// - `has_sticky_in` fast-path when `dy == 0`, list-owned `chrome` slot, and full vs incremental `said_pass` parity

///|
fn make_section_tree(
  initial : Array[String],
  h? : Double = 360.0,
  w? : Double = 300.0,
  rows_cap? : () -> (Int, Int) = fn() { (2, 1) },
  top_edge? : () -> Double = fn() { 0.0 },
  bottom_edge? : () -> Double = fn() { 0.0 },
  top_covered? : () -> Double = fn() { 0.0 },
  tail? : (String) -> Bool = fn(k) { k == "load_more" || k == "foot_row" },
  with_foot? : Bool = false,
  grid? : Double = 2.0,
  chrome_ref? : Ref[SectionChrome[String]?],
) -> (
  Tree,
  View,
  Scroll,
  ListPlace[String],
  @signals.Signal[Array[String]],
  Ref[Double],
  Map[String, View],
  Array[String],
) {
  let clock = Ref(0.0)
  let keys = @signals.signal(initial, same=fn(a, b) { a == b })
  let scroll = Scroll::list()
  let place : ListPlace[String] = ListPlace::new()
  let pressed : Array[String] = []
  let row_views : Map[String, View] = Map([])
  let list_v : Ref[View?] = Ref(None)
  place.set_curtain(fn(k) { k.has_prefix("r/") })
  let chrome_fn : ((View, () -> SectionChrome[String]) -> Unit)? = match chrome_ref {
    Some(cr) =>
      Some(fn(v, read) {
        v.reacts(read, fn(c) { cr.val = Some(c) })
      })
    None => None
  }
  place.set_sections(
    fn(k) { k.has_prefix("h/") },
    tail~,
    top_edge~,
    bottom_edge~,
    rows=rows_cap,
    chrome?=chrome_fn,
  )
  let tree = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(w))).height(Is(Some(h))) |> ignore
        let lv = o.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          top_covered~,
          comes=fn(k) { k.has_prefix("r/") },
          goes=fn(k) { k.has_prefix("r/") },
          place~,
          foot?=if with_foot {
            Some(fn(f) {
              f
              .height(Is(Some(48.0)))
              .words(Is("pinned-foot"))
              .on_press(fn() { pressed.push("pinned-foot") })
              .says(Is(Some(said(Button, label="pinned-foot"))))
              |> ignore
            })
          } else {
            None
          },
          fn(b, k) {
            b.box(fn(l) {
              row_views[k] = l
              let row_h = if k.has_prefix("h/") { 44.0 } else { 40.0 }
              l.width(Is(Some(w))).height(Is(Some(row_h))).words(Is(k)) |> ignore
              if k.has_prefix("h/") {
                l
                .sticky_section()
                .says(Is(Some(said(Button, label=k, expanded=true))))
                .on_press(fn() { pressed.push(k) })
                |> ignore
              } else {
                l
                .says(Is(Some(said(Button, label=k))))
                .on_press(fn() { pressed.push(k) })
                |> ignore
              }
            })
            |> ignore
          },
        )
        list_v.val = Some(lv)
      })
      |> ignore
    },
    time=fn() { clock.val },
  )
  if grid > 0.0 {
    tree.set_rows_grid(grid)
  }
  tree.frame(w, h, now=clock.val) |> ignore
  tree.frame(w, h, now=clock.val) |> ignore
  (tree, list_v.val.unwrap(), scroll, place, keys, clock, row_views, pressed)
}

///|
fn section_drawn_y(tree : Tree, row_views : Map[String, View], key : String) -> Double? {
  match row_views.get(key) {
    Some(v) if v.alive() =>
      match tree.drawn_one(v.id()) {
        Some((_, _, y, _, _, _, _, _)) => Some(y)
        None => None
      }
    _ => None
  }
}

///|
test "Astra counterexamples 1, 2, 3 and empty/budget invariants on solve_sections" {
  // Empty section list returns empty immediately
  let empty = solve_sections([], 0.0, 0.0, 600.0, 0.0, 0.0, 2, 2, 0.0)
  assert_eq(empty.drawn.length(), 0)
  assert_eq(empty.active_idx, -1)

  // Counterexample 1: small screen top_cap=1, bot_cap=0, L=0, B=600, p=900 -> bottom pass skipped, drawn=900 (Flow)
  let ce1 = solve_sections([{ key: 0, p: 900.0, r: 44.0 }], 1200.0, 0.0, 600.0, 0.0, 0.0, 1, 0, 0.0)
  assert_eq(ce1.drawn[0], 900.0)
  assert_eq(ce1.dys[0], 0.0)
  assert_eq(ce1.states[0], SectionState::Flow)

  // Counterexample 2: mid-push-out top_cap=1, L=100, p=[0, 120], r=[44, 44] -> u_0 = min(100, 120 - 44) = 76
  let ce2 = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 120.0, r: 44.0 }],
    500.0,
    100.0,
    600.0,
    0.0,
    0.0,
    1,
    0,
    0.0,
  )
  assert_eq(ce2.drawn[0], 76.0)
  assert_eq(ce2.states[0], SectionState::Active)
  assert_eq(ce2.drawn[1], 120.0)
  assert_eq(ce2.states[1], SectionState::Flow)

  // Counterexample 3: monotonic ordered coordinates -> mutual exclusivity & Lipschitz-1 continuity (0.02pt step)
  let geoms : Array[SectionGeom] = [
    { key: 0, p: 0.0, r: 44.0 },
    { key: 1, p: 244.0, r: 44.0 },
    { key: 2, p: 488.0, r: 44.0 },
    { key: 3, p: 732.0, r: 44.0 },
  ]
  let mut prev = solve_sections(geoms, 1000.0, 0.0, 400.0, 20.0, 20.0, 2, 2, 0.0)
  let mut x = 0.02
  while x <= 600.0 {
    let cur = solve_sections(geoms, 1000.0, x, 400.0, 20.0, 20.0, 2, 2, 0.0)
    for j in 0..<geoms.length() {
      let delta = (cur.drawn[j] - prev.drawn[j]).abs()
      assert_true(delta <= 0.02 + 1.0e-9, msg="Lipschitz violated at x=\{x}, j=\{j}: delta=\{delta}")
      if j + 1 < geoms.length() {
        assert_true(
          cur.drawn[j] + geoms[j].r <= cur.drawn[j + 1] + 1.0e-9,
          msg="sections overlapped at x=\{x}: j=\{j} (\{cur.drawn[j]}+\{geoms[j].r}) > \{cur.drawn[j + 1]}",
        )
      }
    }
    prev = cur
    x = x + 0.02
  }

  // Budget downgrade: band = 100 with r=44, raw (2, 2) -> bot_cap downgrades to 0 (88 <= 100)
  let tight = solve_sections(geoms, 1000.0, 200.0, 100.0, 0.0, 0.0, 2, 2, 0.0)
  assert_eq(tight.eff_top_cap, 2)
  assert_eq(tight.eff_bot_cap, 0)
  // Very tight band = 30 -> both downgrade to 0
  let tiny = solve_sections(geoms, 1000.0, 200.0, 30.0, 0.0, 0.0, 2, 2, 0.0)
  assert_eq(tiny.eff_top_cap, 0)
  assert_eq(tiny.eff_bot_cap, 0)

  // Astra Minor 1: huge cap clamped to g before loop (no million-iteration hang / overflow)
  let huge = solve_sections([{ key: 0, p: 0.0, r: 44.0 }], 500.0, 100.0, 20.0, 0.0, 0.0, 1_000_000, 1_000_000, 0.0)
  assert_eq(huge.eff_top_cap, 0)
  assert_eq(huge.eff_bot_cap, 0)

  // Astra M3: 1x pixel grid with fractional natural tops -> shared edge has 0 overlap and 0 gap
  let f1 = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 100.4, r: 44.0 }],
    1000.0,
    200.0,
    400.0,
    0.55,
    0.0,
    2,
    0,
    1.0,
  )
  assert_true((f1.drawn[0] + 44.0 - f1.drawn[1]).abs() <= 1.0e-6, msg="1x grid 0.55 seam: \{f1.drawn[0] + 44.0} vs \{f1.drawn[1]}")
  let f2 = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 100.6, r: 44.0 }],
    1000.0,
    200.0,
    400.0,
    0.45,
    0.0,
    2,
    0,
    1.0,
  )
  assert_true((f2.drawn[0] + 44.0 - f2.drawn[1]).abs() <= 1.0e-6, msg="1x grid 0.45 seam: \{f2.drawn[0] + 44.0} vs \{f2.drawn[1]}")

  // Astra M3: post-quantization Flow consistency (p=0, L=0.2, grid=1 -> drawn=0, dy=0, Flow)
  let q_flow = solve_sections([{ key: 0, p: 0.0, r: 44.0 }], 500.0, 0.0, 300.0, 0.2, 0.0, 1, 0, 1.0)
  assert_eq(q_flow.dys[0], 0.0)
  assert_eq(q_flow.states[0], SectionState::Flow)

  // Astra M3: tail out-of-bounds (p=0, r=44, tail_end=120, x=200) -> pushed above l_edge, NOT Active!
  let tail_oob = solve_sections([{ key: 0, p: 0.0, r: 44.0 }], 120.0, 200.0, 300.0, 0.0, 0.0, 1, 0, 0.0)
  assert_eq(tail_oob.active_idx, -1)
  assert_eq(tail_oob.states[0], SectionState::Above)
  assert_eq(tail_oob.above_overflow, 1)
}

///|
test "dual-group deep scroll stacks top headers and foreground hit-testing beats covered body rows" {
  let ks : Array[String] = ["h/A"]
  for i in 0..<10 {
    ks.push("r/a" + i.to_string())
  }
  ks.push("h/B")
  for i in 0..<10 {
    ks.push("r/b" + i.to_string())
  }
  ks.push("h/C")
  for i in 0..<10 {
    ks.push("r/c" + i.to_string())
  }
  let chrome_ref : Ref[SectionChrome[String]?] = Ref(None)
  let (tree, _, scroll, place, _, clock, row_views, pressed) = make_section_tree(
    ks,
    h=360.0,
    rows_cap=fn() { (2, 1) },
    chrome_ref~,
  )
  // At top: h/A is at 0 (Flow, dy=0), h/C is bottom-docked (Below)
  assert_eq(place.section_state("h/A"), SectionState::Flow)
  assert_eq(place.section_state("h/C"), SectionState::Below)

  // Deep scroll into section B (h/A=0..44, r/a0..9=44..444, h/B=444..488, r/b0..9=488..888, h/C=888..932).
  // At x=500, L=500 and B=860 < 888, so h/A is Above (0..44), h/B is Active (44..88), and h/C is Below (316..360).
  scroll.put(500.0)
  clock.val = 20.0
  tree.frame(300.0, 360.0, now=clock.val) |> ignore

  // h/A is Above at y=0..44, h/B is Active at y=44..88, h/C is Below at y=316..360
  assert_eq(place.section_state("h/A"), SectionState::Above)
  assert_eq(place.section_state("h/B"), SectionState::Active)
  assert_eq(place.section_state("h/C"), SectionState::Below)
  let ya = section_drawn_y(tree, row_views, "h/A").unwrap()
  let yb = section_drawn_y(tree, row_views, "h/B").unwrap()
  let yc = section_drawn_y(tree, row_views, "h/C").unwrap()
  assert_true((ya - 0.0).abs() <= 0.5, msg="h/A expected at 0, got \{ya}")
  assert_true((yb - 44.0).abs() <= 0.5, msg="h/B expected at 44, got \{yb}")
  assert_true((yc - 316.0).abs() <= 0.5, msg="h/C expected at 316, got \{yc}")

  // Click each stacked header directly over covered body rows: section headers MUST win!
  pressed.clear()
  assert_true(tree.press(50.0, 22.0))
  assert_true(tree.press(50.0, 66.0))
  assert_true(tree.press(50.0, 338.0))
  assert_eq(pressed, ["h/A", "h/B", "h/C"])

  // List-owned chrome reports active="h/B", above_count=1, below_count=1
  let ch = chrome_ref.val.unwrap()
  assert_eq(ch.active, Some("h/B"))
  assert_eq(ch.above_count, 1)
  assert_eq(ch.below_count, 1)

  // Opus M1: bring_section("h/B") lands h/B at its stacked slot (y=44), chrome.active == Some("h/B"), h/A == Above
  clock.val = 40.0
  tree.event(40.0, fn() { place.bring_section("h/B", glide=false) })
  tree.frame(300.0, 360.0, now=clock.val) |> ignore
  assert_eq(place.section_state("h/A"), SectionState::Above)
  assert_eq(chrome_ref.val.unwrap().active, Some("h/B"))
}

///|
test "small-screen top_edge (+8pt) bring_section landing and trailing load_more + foot reachability" {
  let ks : Array[String] = ["h/A"]
  for i in 0..<8 {
    ks.push("r/a" + i.to_string())
  }
  ks.push("h/B")
  for i in 0..<8 {
    ks.push("r/b" + i.to_string())
  }
  ks.push("load_more")
  ks.push("foot_row")
  // Small screen: top_covered = 64, section top_edge = 56 (frame.under = frame.top - 8 => +8pt delta!), top_cap=1, bot_cap=0
  let (tree, _, scroll, place, _, clock, row_views, pressed) = make_section_tree(
    ks,
    h=360.0,
    rows_cap=fn() { (1, 0) },
    top_covered=fn() { 64.0 },
    top_edge=fn() { 56.0 },
    with_foot=true,
  )
  // bring_section("h/B", glide=false) must land h/B at screen y = 56.0 (NOT 64.0!)
  clock.val = 50.0
  tree.event(50.0, fn() { place.bring_section("h/B", glide=false) })
  tree.frame(300.0, 360.0, now=clock.val) |> ignore
  let yb = section_drawn_y(tree, row_views, "h/B").unwrap()
  assert_true((yb - 56.0).abs() <= 0.5, msg="small-screen bring_section expected h/B at 56.0 (+8pt above 64), got \{yb}")

  // Scroll all the way to end: load_more and foot_row are past tail_end, so h/B is pushed off and load_more + pinned foot are reachable
  clock.val = 100.0
  tree.event(100.0, fn() { place.to_end(glide=false) })
  tree.frame(300.0, 360.0, now=clock.val) |> ignore
  let y_lm = section_drawn_y(tree, row_views, "load_more").unwrap()
  let y_fr = section_drawn_y(tree, row_views, "foot_row").unwrap()
  assert_true(y_lm >= 56.0 && y_lm < 312.0, msg="load_more should be visible above pinned foot: \{y_lm}")
  assert_true(y_fr >= 56.0 && y_fr < 312.0, msg="foot_row should be visible above pinned foot: \{y_fr}")
  pressed.clear()
  assert_true(tree.press(50.0, y_lm + 20.0))
  assert_true(tree.press(50.0, 336.0))
  assert_eq(pressed, ["load_more", "pinned-foot"])
  ignore(scroll)
}

///|
test "0.5px continuous scroll sweep across slots_cover mount/unmount boundaries has 0px jump, 0 overlap, and stable NodeId" {
  let ks : Array[String] = ["h/A"]
  for i in 0..<40 {
    ks.push("r/a" + i.to_string())
  }
  ks.push("h/B")
  for i in 0..<40 {
    ks.push("r/b" + i.to_string())
  }
  ks.push("h/C")
  for i in 0..<20 {
    ks.push("r/c" + i.to_string())
  }
  let (tree, _, scroll, _, _, clock, row_views, _) = make_section_tree(
    ks,
    h=240.0,
    rows_cap=fn() { (2, 1) },
    grid=2.0,
  )
  // Record initial NodeId of h/A; sweep 0 -> 800 -> 0 in 0.5px steps across slots_cover boundaries
  let ha_id0 = row_views.get("h/A").unwrap().id()
  let mut prev_ya = section_drawn_y(tree, row_views, "h/A").unwrap()
  fn check_step(x : Double) raise {
    scroll.put(x)
    clock.val = clock.val + 1.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    let ha_v = row_views.get("h/A").unwrap()
    assert_eq(ha_v.id(), ha_id0, msg="h/A NodeId changed at x=\{x} across slots_cover boundary")
    let ya = section_drawn_y(tree, row_views, "h/A").unwrap()
    let step_jump = (ya - prev_ya).abs()
    assert_true(step_jump <= 0.5 + 1.0e-6, msg="h/A jumped by \{step_jump} at x=\{x}: \{prev_ya} -> \{ya}")
    prev_ya = ya
    // Verify any adjacent mounted pair has zero overlap
    match section_drawn_y(tree, row_views, "h/B") {
      Some(yb) => {
        assert_true(ya + 44.0 <= yb + 1.0e-6, msg="h/A overlapped h/B at x=\{x}: \{ya}+44 > \{yb}")
        match section_drawn_y(tree, row_views, "h/C") {
          Some(yc) => assert_true(yb + 44.0 <= yc + 1.0e-6, msg="h/B overlapped h/C at x=\{x}: \{yb}+44 > \{yc}")
          None => ()
        }
      }
      None => ()
    }
  }
  let mut x = 0.5
  while x <= 800.0 {
    check_step(x)
    x = x + 0.5
  }
  x = 799.5
  while x >= 0.0 {
    check_step(x)
    x = x - 0.5
  }
}

///|
test "deep collapse, mid-push-out collapse, last-section collapse, and mid-curtain reversal preserve exact header anchor" {
  // 1. Mid-push-out collapse (Astra counterexample 2 in full Tree!)
  let ks_push : Array[String] = ["h/A", "r/0", "r/1", "h/B", "r/b0", "r/b1", "r/b2", "r/b3", "r/b4", "r/b5"]
  let (tree1, lv1, scroll1, place1, keys1, clock1, rows1, _) = make_section_tree(
    ks_push,
    h=240.0,
    rows_cap=fn() { (1, 0) },
  )
  // h/A=0..44, r/0=44..84, r/1=84..124, h/B=124..168. At x=100, u_0 = min(100, 124 - 44) = 80 => screen y = -20!
  scroll1.put(100.0)
  clock1.val = 20.0
  tree1.frame(300.0, 240.0, now=clock1.val) |> ignore
  assert_eq(place1.section_state("h/A"), SectionState::Active)
  let ha_before = section_drawn_y(tree1, rows1, "h/A").unwrap()
  let hb_before = section_drawn_y(tree1, rows1, "h/B").unwrap()
  assert_true((ha_before - -20.0).abs() <= 0.5, msg="expected mid-push-out h/A at -20, got \{ha_before}")
  // Press h/A (bottom half is visible at y=10) and collapse its rows in the same event!
  clock1.val = 100.0
  tree1.event(100.0, fn() {
    let _ = tree1.press(50.0, 10.0)
    transition(within=lv1, fn() { keys1.set(["h/A", "h/B", "r/b0", "r/b1", "r/b2", "r/b3", "r/b4", "r/b5"]) })
  })
  tree1.frame(300.0, 240.0, now=clock1.val) |> ignore
  let ha_after = section_drawn_y(tree1, rows1, "h/A").unwrap()
  let hb_after = section_drawn_y(tree1, rows1, "h/B").unwrap()
  assert_true((ha_after - ha_before).abs() <= 0.5, msg="mid-push-out collapse jumped h/A: \{ha_before} -> \{ha_after}")
  assert_true((hb_after - hb_before).abs() <= 0.5, msg="mid-push-out collapse jumped h/B: \{hb_before} -> \{hb_after}")
  clock1.val = 160.0
  tree1.frame(300.0, 240.0, now=clock1.val) |> ignore
  assert_true((section_drawn_y(tree1, rows1, "h/A").unwrap() - ha_before).abs() <= 0.5, msg="mid-push-out h/A drifted at +60ms")
  assert_true((section_drawn_y(tree1, rows1, "h/B").unwrap() - hb_before).abs() <= 0.5, msg="mid-push-out h/B drifted at +60ms")
  clock1.val = 100.0 + @flex.move_most_ms + 20.0
  tree1.frame(300.0, 240.0, now=clock1.val) |> ignore
  assert_true((section_drawn_y(tree1, rows1, "h/A").unwrap() - ha_before).abs() <= 0.5, msg="mid-push-out h/A jumped at end")
  assert_true((section_drawn_y(tree1, rows1, "h/B").unwrap() - hb_before).abs() <= 0.5, msg="mid-push-out h/B jumped at end")

  // 2. Deep collapse + mid-curtain reversal (t=0, +60ms, reversal t=0, reversal end)
  let ks_deep : Array[String] = ["h/A"]
  for i in 0..<20 {
    ks_deep.push("r/a" + i.to_string())
  }
  ks_deep.push("h/B")
  for i in 0..<10 {
    ks_deep.push("r/b" + i.to_string())
  }
  let ks_deep_collapsed : Array[String] = ["h/A", "h/B"]
  for i in 0..<10 {
    ks_deep_collapsed.push("r/b" + i.to_string())
  }
  let (tree2, lv2, scroll2, place2, keys2, clock2, rows2, _) = make_section_tree(
    ks_deep,
    h=240.0,
    rows_cap=fn() { (1, 0) },
  )
  scroll2.put(524.0)
  clock2.val = 20.0
  tree2.frame(300.0, 240.0, now=clock2.val) |> ignore
  assert_eq(place2.section_state("h/A"), SectionState::Active)
  let ha2_0 = section_drawn_y(tree2, rows2, "h/A").unwrap()
  assert_true((ha2_0 - 0.0).abs() <= 0.5)
  clock2.val = 100.0
  tree2.event(100.0, fn() {
    let _ = tree2.press(50.0, 20.0)
    transition(within=lv2, fn() { keys2.set(ks_deep_collapsed) })
  })
  tree2.frame(300.0, 240.0, now=clock2.val) |> ignore
  assert_true((section_drawn_y(tree2, rows2, "h/A").unwrap() - 0.0).abs() <= 0.5, msg="deep collapse jumped h/A at t=0")
  // Mid-curtain at +60ms: reverse back to expanded and verify end state
  clock2.val = 160.0
  tree2.frame(300.0, 240.0, now=clock2.val) |> ignore
  assert_true((section_drawn_y(tree2, rows2, "h/A").unwrap() - 0.0).abs() <= 0.5, msg="deep collapse drifted mid-curtain")
  tree2.event(160.0, fn() { transition(within=lv2, fn() { keys2.set(ks_deep) }) })
  tree2.frame(300.0, 240.0, now=clock2.val) |> ignore
  assert_true((section_drawn_y(tree2, rows2, "h/A").unwrap() - 0.0).abs() <= 0.5, msg="mid-curtain reversal jumped h/A")
  clock2.val = 160.0 + @flex.move_most_ms + 20.0
  tree2.frame(300.0, 240.0, now=clock2.val) |> ignore
  assert_true((section_drawn_y(tree2, rows2, "h/A").unwrap() - 0.0).abs() <= 0.5, msg="mid-curtain reversal jumped h/A at end")

  // 3. Opus B2: Last-section collapse (x=400, y=0) stays locked at y=0 through t=0, +60ms, and end (final x=124)
  let ks_last : Array[String] = ["h/A", "r/a0", "r/a1", "h/Last"]
  for i in 0..<15 {
    ks_last.push("r/l" + i.to_string())
  }
  let (tree3, lv3, scroll3, place3, keys3, clock3, rows3, _) = make_section_tree(
    ks_last,
    h=240.0,
    rows_cap=fn() { (1, 0) },
  )
  scroll3.put(400.0)
  clock3.val = 20.0
  tree3.frame(300.0, 240.0, now=clock3.val) |> ignore
  assert_eq(place3.section_state("h/Last"), SectionState::Active)
  clock3.val = 100.0
  tree3.event(100.0, fn() {
    let _ = tree3.press(50.0, 20.0)
    transition(within=lv3, fn() { keys3.set(["h/A", "r/a0", "r/a1", "h/Last"]) })
  })
  tree3.frame(300.0, 240.0, now=clock3.val) |> ignore
  assert_true((section_drawn_y(tree3, rows3, "h/Last").unwrap() - 0.0).abs() <= 0.5, msg="last-section collapse jumped at t=0")
  clock3.val = 160.0
  tree3.frame(300.0, 240.0, now=clock3.val) |> ignore
  assert_true((section_drawn_y(tree3, rows3, "h/Last").unwrap() - 0.0).abs() <= 0.5, msg="last-section collapse jumped at +60ms")
  clock3.val = 100.0 + @flex.move_most_ms + 20.0
  tree3.frame(300.0, 240.0, now=clock3.val) |> ignore
  let hl_end = section_drawn_y(tree3, rows3, "h/Last").unwrap()
  assert_true((hl_end - 0.0).abs() <= 0.5, msg="last-section collapse jumped at end: \{hl_end}")
  assert_true((scroll3.drawn(tree3) - 124.0).abs() <= 1.0, msg="last-section final x expected 124, got \{scroll3.drawn(tree3)}")

  // 4. Astra M1: Top 2nd row B (x=500, y=44, rows_cap=(2,1)) stays locked at y=44 through t=0, +60ms, and end (final x=400)
  let ks_row2 : Array[String] = ["h/A"]
  for i in 0..<10 {
    ks_row2.push("r/a" + i.to_string())
  }
  ks_row2.push("h/B")
  for i in 0..<10 {
    ks_row2.push("r/b" + i.to_string())
  }
  ks_row2.push("h/C")
  for i in 0..<10 {
    ks_row2.push("r/c" + i.to_string())
  }
  let ks_row2_collapsed : Array[String] = ["h/A"]
  for i in 0..<10 {
    ks_row2_collapsed.push("r/a" + i.to_string())
  }
  ks_row2_collapsed.push("h/B")
  ks_row2_collapsed.push("h/C")
  for i in 0..<10 {
    ks_row2_collapsed.push("r/c" + i.to_string())
  }
  let (tree4, lv4, scroll4, place4, keys4, clock4, rows4, _) = make_section_tree(
    ks_row2,
    h=360.0,
    rows_cap=fn() { (2, 1) },
  )
  scroll4.put(500.0)
  clock4.val = 20.0
  tree4.frame(300.0, 360.0, now=clock4.val) |> ignore
  assert_eq(place4.section_state("h/B"), SectionState::Active)
  assert_true((section_drawn_y(tree4, rows4, "h/B").unwrap() - 44.0).abs() <= 0.5)
  clock4.val = 100.0
  tree4.event(100.0, fn() {
    let _ = tree4.press(50.0, 66.0)
    transition(within=lv4, fn() { keys4.set(ks_row2_collapsed) })
  })
  tree4.frame(300.0, 360.0, now=clock4.val) |> ignore
  assert_true((section_drawn_y(tree4, rows4, "h/B").unwrap() - 44.0).abs() <= 0.5, msg="row2 B jumped at t=0")
  clock4.val = 160.0
  tree4.frame(300.0, 360.0, now=clock4.val) |> ignore
  assert_true((section_drawn_y(tree4, rows4, "h/B").unwrap() - 44.0).abs() <= 0.5, msg="row2 B jumped at +60ms")
  clock4.val = 100.0 + @flex.move_most_ms + 20.0
  tree4.frame(300.0, 360.0, now=clock4.val) |> ignore
  let yb_end = section_drawn_y(tree4, rows4, "h/B").unwrap()
  assert_true((yb_end - 44.0).abs() <= 0.5, msg="row2 B jumped at end: \{yb_end}")
  assert_true((scroll4.drawn(tree4) - 400.0).abs() <= 1.0, msg="row2 B final x expected 400, got \{scroll4.drawn(tree4)}")
}

///|
test "has_sticky_in keeps kept-drawn fast path when dy == 0 and incremental said_pass matches full said_pass" {
  let ks : Array[String] = ["h/A"]
  for i in 0..<10 {
    ks.push("r/a" + i.to_string())
  }
  ks.push("h/B")
  for i in 0..<10 {
    ks.push("r/b" + i.to_string())
  }
  // top_cap=1, bot_cap=0: at top (x=0), dy == 0 for ALL headers -> has_sticky_in MUST be false!
  let (tree, lv, scroll, _, _, clock, _, _) = make_section_tree(
    ks,
    h=240.0,
    rows_cap=fn() { (1, 0) },
  )
  assert_false(tree.has_sticky_in(lv.id()), msg="has_sticky_in must be false when all section headings have dy == 0")

  // Prime incremental a11y mirror with a full pass
  let known : Map[NodeId, (Double, Double, Double, Double)] = Map([])
  let p0 = tree.said_pass(fn(_) { false }, fn(_) { "" }, whole=true)
  for e in p0.entries {
    known[e.id] = e.rect
  }

  // Scroll down so h/A becomes displaced (dy > 0): has_sticky_in becomes true, and incremental said_pass updates h/A!
  scroll.put(120.0)
  clock.val = 20.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  assert_true(tree.has_sticky_in(lv.id()), msg="has_sticky_in must be true once a section heading is displaced")

  let p_inc = tree.said_pass(fn(id) { known.contains(id) }, fn(_) { "" }, whole=false)
  for e in p_inc.entries {
    known[e.id] = e.rect
  }
  let p_full = tree.said_pass(fn(_) { false }, fn(_) { "" }, whole=true)
  for e in p_full.entries {
    match e.said {
      Some(s) if s.label == "h/A" || s.label == "h/B" => {
        let inc_r = known.get(e.id)
        assert_eq(inc_r, Some(e.rect), msg="incremental said_pass rect diverged from full for \{s.label}")
      }
      _ => ()
    }
  }
}

///|
test "O(G) head predicate call count is zero on pure scroll, reactive grouped flip works, and pin mutual exclusion holds" {
  // 1. O(G) head call count == 0 during pure scroll & reactive grouped flip (Opus M3, Astra M7/M9)
  let ks : Array[String] = ["h/A"]
  for i in 0..<100 {
    ks.push("r/a" + i.to_string())
  }
  ks.push("h/B")
  for i in 0..<100 {
    ks.push("r/b" + i.to_string())
  }
  let head_calls = Ref(0)
  let grouped = @signals.signal(true)
  let clock = Ref(0.0)
  let scroll = Scroll::list()
  let place : ListPlace[String] = ListPlace::new()
  let rows : Map[String, View] = Map([])
  place.set_sections(
    fn(k) {
      head_calls.val = head_calls.val + 1
      grouped.get() && k.has_prefix("h/")
    },
    rows=fn() { (2, 1) },
  )
  let tree = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        o.scrolls_window(scroll, fn() { ks }, est=40.0, place~, fn(b, k) {
          b.box(fn(l) {
            rows[k] = l
            l.width(Is(Some(300.0))).height(Is(Some(if k.has_prefix("h/") { 44.0 } else { 40.0 }))) |> ignore
            if k.has_prefix("h/") {
              l.sticky_section() |> ignore
            }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { clock.val },
  )
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  // Reset counter and scroll across 20 scroll offsets: head predicate must NOT be called during pure scroll!
  head_calls.val = 0
  let mut sx = 15.0
  while sx <= 300.0 {
    scroll.put(sx)
    clock.val = clock.val + 16.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    let _ = place.section_state("h/A")
    sx = sx + 15.0
  }
  assert_eq(head_calls.val, 0, msg="head predicate was called \{head_calls.val} times during pure scroll")
  assert_eq(place.section_state("h/A"), SectionState::Active)

  // Flip `grouped` in place without changing keys/sizes/scroll: h/A must immediately return to Flow (Astra M7)
  grouped.set(false)
  clock.val = clock.val + 16.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  assert_eq(place.section_state("h/A"), SectionState::Flow)

  // 2. Astra M2 / Opus Minor 1: clicking an ordinary disclosure row mid-collapse cancels old section_pin
  let ks_mix : Array[String] = ["h/A"]
  for i in 0..<12 {
    ks_mix.push("r/a" + i.to_string())
  }
  ks_mix.push("h/B")
  for i in 0..<8 {
    ks_mix.push("r/b" + i.to_string())
  }
  let ks_mix_collapsed : Array[String] = ["h/A", "h/B"]
  for i in 0..<8 {
    ks_mix_collapsed.push("r/b" + i.to_string())
  }
  let keys_m = @signals.signal(ks_mix, same=fn(a, b) { a == b })
  let disc_open = @signals.signal(false)
  let scroll_m = Scroll::list()
  let place_m : ListPlace[String] = ListPlace::new()
  let clock_m = Ref(0.0)
  let rows_m : Map[String, View] = Map([])
  let lv_m : Ref[View?] = Ref(None)
  place_m.set_curtain(fn(k) { k.has_prefix("r/") })
  place_m.set_sections(fn(k) { k.has_prefix("h/") }, rows=fn() { (1, 0) })
  let tree_m = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(360.0))) |> ignore
        let lv = o.scrolls_window(
          scroll_m,
          fn() { keys_m.get() },
          est=40.0,
          comes=fn(k) { k.has_prefix("r/") },
          goes=fn(k) { k.has_prefix("r/") },
          place=place_m,
          fn(b, k) {
            b.box(fn(l) {
              rows_m[k] = l
              let h_row = if k.has_prefix("h/") {
                44.0
              } else if k == "r/b0" {
                if disc_open.get() { 100.0 } else { 40.0 }
              } else {
                40.0
              }
              l.width(Is(Some(300.0))).height(By(fn() { Some(if k == "r/b0" && disc_open.get() { 100.0 } else { h_row }) })) |> ignore
              if k.has_prefix("h/") {
                l.sticky_section().says(Is(Some(said(Button, label=k, expanded=true)))).on_press(fn() {  }) |> ignore
              } else if k == "r/b0" {
                l
                .says(By(fn() { Some(said(Button, label=k, expanded=disc_open.get())) }))
                .on_press(fn() { disc_open.set(!disc_open.untracked()) })
                |> ignore
              }
            })
            |> ignore
          },
        )
        lv_m.val = Some(lv)
      })
      |> ignore
    },
    time=fn() { clock_m.val },
  )
  tree_m.frame(300.0, 360.0, now=clock_m.val) |> ignore
  scroll_m.put(364.0)
  clock_m.val = 20.0
  tree_m.frame(300.0, 360.0, now=clock_m.val) |> ignore
  // Collapse h/A (starts section_pin), then at +30ms click ordinary disclosure row r/b0
  clock_m.val = 100.0
  tree_m.event(100.0, fn() {
    let _ = tree_m.press(50.0, 20.0)
    transition(within=lv_m.val.unwrap(), fn() { keys_m.set(ks_mix_collapsed) })
  })
  tree_m.frame(300.0, 360.0, now=clock_m.val) |> ignore
  clock_m.val = 130.0
  tree_m.frame(300.0, 360.0, now=clock_m.val) |> ignore
  let rb0_y_before = section_drawn_y(tree_m, rows_m, "r/b0").unwrap()
  assert_true(rb0_y_before >= 44.0 && rb0_y_before < 320.0, msg="r/b0 should be visible on screen: \{rb0_y_before}")
  tree_m.event(130.0, fn() {
    let _ = tree_m.press(50.0, rb0_y_before + 10.0)
  })
  tree_m.frame(300.0, 360.0, now=clock_m.val) |> ignore
  assert_true(disc_open.untracked(), msg="ordinary disclosure row r/b0 should have toggled open")
  let rb0_y_after = section_drawn_y(tree_m, rows_m, "r/b0").unwrap()
  assert_true((rb0_y_after - rb0_y_before).abs() <= 1.0, msg="old section_pin hijacked ordinary disclosure pin: \{rb0_y_before} -> \{rb0_y_after}")
}

///|
test "ancestor scale, ancestor drawn_off clip, nested scroll clip, legacy sticky a11y, and non-zero short-list off" {
  // 1. Astra M4 (0.8x intermediate wrapper scale) + Astra M5 (ancestor drawn_off +100 clip + nested scroll inside header)
  // Leading body row `r/pre` (40pt) places `h/A` at p=40 > top_edge=20 so at x=0 `h/A` is truly in Flow (dy == 0)!
  let ks : Array[String] = ["r/pre", "h/A"]
  for i in 0..<15 {
    ks.push("r/a" + i.to_string())
  }
  let scroll = Scroll::list()
  let inner_scroll = Scroll::plain()
  let place : ListPlace[String] = ListPlace::new()
  let clock = Ref(0.0)
  let heading_v : Ref[View?] = Ref(None)
  let nested_child_v : Ref[View?] = Ref(None)
  place.set_sections(fn(k) { k == "h/A" }, top_edge=fn() { 20.0 }, bottom_edge=fn() { 20.0 }, rows=fn() { (1, 0) })
  let tree = Tree::new(
    fn(root) {
      root.box(fn(outer) {
        outer.width(Is(Some(300.0))).height(Is(Some(240.0))).drawn_off(Is((0.0, 100.0))) |> ignore
        outer.scrolls_window(scroll, fn() { ks }, est=40.0, place~, fn(b, k) {
          if k == "h/A" {
            // 0.8x intermediate wrapper at top-origin (Astra M4)
            b.box(fn(wrap) {
              wrap.width(Is(Some(300.0))).height(Is(Some(44.0))).scale(Is(0.8), about=DrawnSide(0.0)) |> ignore
              wrap.box(fn(h) {
                heading_v.val = Some(h)
                h.width(Is(Some(300.0))).height(Is(Some(44.0))).sticky_section() |> ignore
                h.scrolls(inner_scroll, fn(ih) {
                  ih.box(fn(ic) {
                    nested_child_v.val = Some(ic)
                    ic.width(Is(Some(100.0))).height(Is(Some(20.0))) |> ignore
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          } else {
            b.box(fn(l) { l.width(Is(Some(300.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { clock.val },
  )
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  // At x=0 (Flow, dy=0): Astra boundary 2 — section_clip_of STILL clips all section_slots to [top_edge, vh - bottom_edge]
  let clip0 = tree.section_clip_of(nested_child_v.val.unwrap().id()).unwrap()
  assert_true((clip0.1 - 120.0).abs() <= 1.0 && (clip0.3 - 320.0).abs() <= 1.0, msg="expected Flow clip [120, 320], got [\{clip0.1}, \{clip0.3}]")
  // Scroll to x=300: h/A is pinned at top_edge=20 -> screen y = 100 (outer drawn_off) + 20 = 120!
  scroll.put(300.0)
  clock.val = 20.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  let (_, _, hy, _, _, _, _, _) = tree.drawn_one(heading_v.val.unwrap().id()).unwrap()
  assert_true((hy - 120.0).abs() <= 1.0, msg="0.8x wrapper mis-scaled sticky_section: expected 120, got \{hy}")
  // Astra M5: clip reflects outer drawn_off (+100 -> [120, 320]) even through nested scrollable child!
  let clip = tree.section_clip_of(nested_child_v.val.unwrap().id()).unwrap()
  assert_true((clip.1 - 120.0).abs() <= 1.0 && (clip.3 - 320.0).abs() <= 1.0, msg="expected clip [120, 320], got [\{clip.1}, \{clip.3}]")

  // 2. Astra M6: legacy View::sticky with named child button stays synced in incremental said_pass on pure scroll
  let s_leg = Scroll::plain()
  let c_leg = Ref(0.0)
  let t_leg = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(200.0))).height(Is(Some(200.0))) |> ignore
        o.scrolls(s_leg, fn(h) {
          h.box(fn(sec) {
            sec.width(Is(Some(200.0))).height(Is(Some(600.0))) |> ignore
            sec.box(fn(st) {
              st.width(Is(Some(200.0))).height(Is(Some(40.0))).sticky(Is(Some(0.0))) |> ignore
              st.box(fn(btn) {
                btn
                .width(Is(Some(80.0)))
                .height(Is(Some(30.0)))
                .says(Is(Some(said(Button, label="sticky-btn"))))
                .on_press(fn() {  })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { c_leg.val },
  )
  t_leg.frame(200.0, 200.0, now=c_leg.val) |> ignore
  s_leg.put(100.0)
  c_leg.val = 16.0
  t_leg.frame(200.0, 200.0, now=c_leg.val) |> ignore
  let known_leg : Map[NodeId, (Double, Double, Double, Double)] = Map([])
  for e in t_leg.said_pass(fn(_) { false }, fn(_) { "" }, whole=true).entries {
    known_leg[e.id] = e.rect
  }
  // Pure scroll 100 -> 120: screen py of sticky-btn stays 0, but scroll_holder moved -20; incremental pass MUST update it
  s_leg.put(120.0)
  c_leg.val = 32.0
  t_leg.frame(200.0, 200.0, now=c_leg.val) |> ignore
  let inc_leg = t_leg.said_pass(fn(id) { known_leg.contains(id) }, fn(_) { "" }, whole=false)
  for e in inc_leg.entries {
    known_leg[e.id] = e.rect
  }
  let full_leg = t_leg.said_pass(fn(_) { false }, fn(_) { "" }, whole=true)
  let mut saw_btn = false
  for e in full_leg.entries {
    if e.said is Some(sd) && sd.label == "sticky-btn" {
      saw_btn = true
      assert_eq(known_leg.get(e.id), Some(e.rect), msg="legacy View::sticky child button drifted in incremental said_pass")
    }
  }
  assert_true(saw_btn)

  // 3. Real non-zero `off`: short `from_end=true, head=None` list (84pt total in 240pt viewport -> off = 156pt)
  let s_short = Scroll::list()
  let p_short : ListPlace[String] = ListPlace::new()
  let c_short = Ref(0.0)
  let rows_short : Map[String, View] = Map([])
  p_short.set_sections(fn(k) { k == "h/A" }, rows=fn() { (1, 0) })
  let t_short = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        o.scrolls_window(s_short, fn() { ["h/A", "r/a0"] }, est=40.0, from_end=true, place=p_short, fn(b, k) {
          b.box(fn(l) {
            rows_short[k] = l
            l.width(Is(Some(300.0))).height(Is(Some(if k == "h/A" { 44.0 } else { 40.0 }))) |> ignore
            if k == "h/A" {
              l.sticky_section() |> ignore
            }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { c_short.val },
  )
  t_short.frame(300.0, 240.0, now=c_short.val) |> ignore
  t_short.frame(300.0, 240.0, now=c_short.val) |> ignore
  let y_short = section_drawn_y(t_short, rows_short, "h/A").unwrap()
  assert_true((y_short - 156.0).abs() <= 1.0, msg="short from_end list h/A expected at 156, got \{y_short}")
  assert_eq(p_short.section_state("h/A"), SectionState::Flow)
  c_short.val = 20.0
  t_short.event(20.0, fn() { p_short.bring_section("h/A", glide=false) })
  t_short.frame(300.0, 240.0, now=c_short.val) |> ignore
  let y_short2 = section_drawn_y(t_short, rows_short, "h/A").unwrap()
  assert_true((y_short2 - 156.0).abs() <= 1.0, msg="short from_end bring_section moved h/A: \{y_short2}")
}

///|
test "v4 regressions: OOB bottom-dock stability, end_room short-list off, Astra #1/#2/#4/#5/#6/#7 and Flow clip" {
  // 1. Opus M-a: OOB bottom-docked h/C stays pinned at y=316 throughout h/A's 3-row collapse curtain (0 drift!)
  let ks_ma : Array[String] = ["h/A", "r/a0", "r/a1", "r/a2", "h/B"]
  for i in 0..<30 {
    ks_ma.push("r/b" + i.to_string())
  }
  ks_ma.push("h/C")
  for i in 0..<5 {
    ks_ma.push("r/c" + i.to_string())
  }
  let ks_ma_col : Array[String] = ["h/A", "h/B"]
  for i in 0..<30 {
    ks_ma_col.push("r/b" + i.to_string())
  }
  ks_ma_col.push("h/C")
  for i in 0..<5 {
    ks_ma_col.push("r/c" + i.to_string())
  }
  let (t_ma, lv_ma, _, _, keys_ma, clk_ma, rows_ma, _) = make_section_tree(ks_ma, h=360.0, rows_cap=fn() { (2, 1) })
  assert_true((section_drawn_y(t_ma, rows_ma, "h/C").unwrap() - 316.0).abs() <= 0.5)
  clk_ma.val = 50.0
  t_ma.event(50.0, fn() {
    let _ = t_ma.press(50.0, 20.0)
    transition(within=lv_ma, fn() { keys_ma.set(ks_ma_col) })
  })
  t_ma.frame(300.0, 360.0, now=clk_ma.val) |> ignore
  assert_true((section_drawn_y(t_ma, rows_ma, "h/C").unwrap() - 316.0).abs() <= 0.5, msg="OOB h/C drifted at t=0")
  for dt in [40.0, 80.0, 120.0, @flex.move_most_ms + 20.0] {
    clk_ma.val = 50.0 + dt
    t_ma.frame(300.0, 360.0, now=clk_ma.val) |> ignore
    let yc = section_drawn_y(t_ma, rows_ma, "h/C").unwrap()
    assert_true((yc - 316.0).abs() <= 0.5, msg="OOB h/C drifted at +\{dt}ms: \{yc}")
  }

  // 2. Opus M-b + Astra #3: from_end=true + end_room=48 short list (vh=240, content=84 -> start=108, top_edge=130 -> h/A sticks at 130)
  let s_er = Scroll::list()
  let p_er : ListPlace[String] = ListPlace::new()
  let c_er = Ref(0.0)
  let rows_er : Map[String, View] = Map([])
  p_er.set_sections(fn(k) { k == "h/A" }, top_edge=fn() { 130.0 }, rows=fn() { (1, 0) })
  let t_er = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        o.scrolls_window(
          s_er,
          fn() { ["h/A", "r/a0"] },
          est=40.0,
          from_end=true,
          end_room=fn() { 48.0 },
          place=p_er,
          fn(b, k) {
            b.box(fn(l) {
              rows_er[k] = l
              l.width(Is(Some(300.0))).height(Is(Some(if k == "h/A" { 44.0 } else { 40.0 }))) |> ignore
              if k == "h/A" {
                l.sticky_section() |> ignore
              }
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    },
    time=fn() { c_er.val },
  )
  t_er.frame(300.0, 240.0, now=c_er.val) |> ignore
  t_er.frame(300.0, 240.0, now=c_er.val) |> ignore
  let y_er = section_drawn_y(t_er, rows_er, "h/A").unwrap()
  assert_true((y_er - 130.0).abs() <= 1.0, msg="short from_end + end_room=48 expected h/A at 130, got \{y_er}")
  assert_eq(p_er.section_state("h/A"), SectionState::Active)

  // 3. Astra #1 exact counterexample: 1x grid, top_edge=0.2, x=100, collapse 1 offscreen-below 40pt row -> x stays 100, body row stays fixed!
  let ks_a1 : Array[String] = ["h/A"]
  for i in 0..<24 {
    ks_a1.push("r/a" + i.to_string())
  }
  ks_a1.push("h/B")
  for i in 0..<10 {
    ks_a1.push("r/b" + i.to_string())
  }
  let ks_a1_col : Array[String] = ["h/A"]
  for i in 0..<23 {
    ks_a1_col.push("r/a" + i.to_string())
  }
  ks_a1_col.push("h/B")
  for i in 0..<10 {
    ks_a1_col.push("r/b" + i.to_string())
  }
  let (t_a1, lv_a1, sc_a1, _, keys_a1, clk_a1, rows_a1, _) = make_section_tree(
    ks_a1,
    h=240.0,
    top_edge=fn() { 0.2 },
    rows_cap=fn() { (1, 0) },
    grid=1.0,
  )
  sc_a1.put(100.0)
  clk_a1.val = 20.0
  t_a1.frame(300.0, 240.0, now=clk_a1.val) |> ignore
  let body_before = section_drawn_y(t_a1, rows_a1, "r/a3").unwrap()
  clk_a1.val = 100.0
  t_a1.event(100.0, fn() {
    let _ = t_a1.press(50.0, 20.0)
    transition(within=lv_a1, fn() { keys_a1.set(ks_a1_col) })
  })
  t_a1.frame(300.0, 240.0, now=clk_a1.val) |> ignore
  assert_true((section_drawn_y(t_a1, rows_a1, "h/A").unwrap() - 0.0).abs() <= 0.5, msg="Astra #1 h/A moved")
  assert_true((sc_a1.drawn(t_a1) - 100.0).abs() <= 0.5, msg="Astra #1 scroll jumped from 100 to \{sc_a1.drawn(t_a1)}")
  let body_after = section_drawn_y(t_a1, rows_a1, "r/a3").unwrap()
  assert_true((body_after - body_before).abs() <= 0.5, msg="Astra #1 body row r/a3 jumped: \{body_before} -> \{body_after}")

  // 4. Astra #2 exact counterexamples + small-screen bot_cap==0 below_overflow
  let no_flip = solve_sections([{ key: 0, p: 0.4, r: 44.0 }], 500.0, 0.0, 300.0, 0.45, 0.0, 1, 0, 1.0)
  assert_true(no_flip.states[0] != SectionState::Below, msg="top sticky quantized into Below!")
  assert_eq(no_flip.below_count, 0)
  let frac_r = solve_sections(
    [{ key: 0, p: 0.0, r: 44.4 }, { key: 1, p: 100.0, r: 44.0 }],
    500.0,
    200.0,
    300.0,
    0.2,
    0.0,
    2,
    0,
    1.0,
  )
  assert_true(
    (frac_r.drawn[0] + 44.4 - frac_r.drawn[1]).abs() <= 1.0e-6,
    msg="fractional r_j contact seam gap: \{frac_r.drawn[0] + 44.4} vs \{frac_r.drawn[1]}",
  )
  let small_bot = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 900.0, r: 44.0 }],
    1000.0,
    100.0,
    240.0,
    0.0,
    0.0,
    1,
    0,
    0.0,
  )
  assert_eq(small_bot.below_overflow, 1)
  assert_eq(small_bot.below_count, 0)
  assert_eq(small_bot.states[1], SectionState::Flow)

  // 5. Astra #4 (end_room=160 chrome active) + Astra #5 (flat->grouped foreground order & grouped->flat chrome clear) + Astra #7 (replace chrome)
  let ks_a4 : Array[String] = ["h/A"]
  for i in 0..<18 {
    ks_a4.push("r/a" + i.to_string())
  }
  ks_a4.push("h/B")
  ks_a4.push("r/b0")
  ks_a4.push("r/b1")
  let grouped_a5 = @signals.signal(false)
  let ch_a : Ref[SectionChrome[String]?] = Ref(None)
  let ch_b : Ref[SectionChrome[String]?] = Ref(None)
  let pressed_a5 : Array[String] = []
  let sc_a4 = Scroll::list()
  let pl_a4 : ListPlace[String] = ListPlace::new()
  let clk_a4 = Ref(0.0)
  pl_a4.set_sections(
    fn(k) { grouped_a5.get() && k.has_prefix("h/") },
    rows=fn() { (1, 0) },
    chrome=fn(v, read) { v.reacts(read, fn(c) { ch_a.val = Some(c) }) },
  )
  let t_a4 = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        o.scrolls_window(
          sc_a4,
          fn() { ks_a4 },
          est=40.0,
          end_room=fn() { 160.0 },
          place=pl_a4,
          fn(b, k) {
            b.box(fn(l) {
              l.width(Is(Some(300.0))).height(Is(Some(if k.has_prefix("h/") { 44.0 } else { 40.0 }))) |> ignore
              if k.has_prefix("h/") {
                l.sticky_section().on_press(fn() { pressed_a5.push(k) }) |> ignore
              } else {
                l.on_press(fn() { pressed_a5.push(k) }) |> ignore
              }
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    },
    time=fn() { clk_a4.val },
  )
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  // Scroll down while flat, then flip grouped=true in place (Astra #5): h/A must move to foreground and win clicks!
  sc_a4.put(120.0)
  clk_a4.val = 16.0
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  grouped_a5.set(true)
  clk_a4.val = 32.0
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  pressed_a5.clear()
  assert_true(t_a4.press(50.0, 20.0))
  assert_eq(pressed_a5, ["h/A"], msg="flat->grouped did not move h/A to foreground!")
  assert_eq(ch_a.val.unwrap().active, Some("h/A"))
  // Flip grouped=false without scrolling: chrome.active MUST clear to None!
  grouped_a5.set(false)
  clk_a4.val = 48.0
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  assert_eq(ch_a.val.unwrap().active, None, msg="grouped->flat did not clear chrome.active without scrolling")
  // Astra #7: replace presenter A with presenter B, then re-enable grouped and scroll to bottom (end_room=160, x=820 -> Astra #4)
  pl_a4.set_sections(
    fn(k) { grouped_a5.get() && k.has_prefix("h/") },
    rows=fn() { (1, 0) },
    chrome=fn(v, read) { v.reacts(read, fn(c) { ch_b.val = Some(c) }) },
  )
  clk_a4.val = 64.0
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  grouped_a5.set(true)
  sc_a4.put(820.0)
  clk_a4.val = 80.0
  t_a4.frame(300.0, 240.0, now=clk_a4.val) |> ignore
  assert_eq(ch_b.val.unwrap().active, Some("h/B"), msg="Astra #4/#7 chrome B expected active=h/B at x=820 with end_room=160")
  assert_eq(ch_a.val.unwrap().active, None, msg="Astra #7 old chrome A should have unmounted and stopped updating")

  // 6. Real section slot FLIP drawn_off.y=+30 transitions continuously across dy == 0 (no 30pt jump)
  let ks_flip : Array[String] = ["r/pre0", "r/pre1", "h/A"]
  for i in 0..<15 {
    ks_flip.push("r/a" + i.to_string())
  }
  let (t_fl, _, sc_fl, _, _, clk_fl, rows_fl, _) = make_section_tree(ks_flip, h=240.0, rows_cap=fn() { (1, 0) }, grid=1.0)
  // Natural top of h/A is 80; inject FLIP drawn_off.y = +30 on h/A's real section slot
  let (ha_slot, _, _) = t_fl.section_slot_of(rows_fl.get("h/A").unwrap().at).unwrap()
  t_fl.nodes[ha_slot].look.drawn_off = (0.0, 30.0)
  sc_fl.put(80.0)
  clk_fl.val = 16.0
  t_fl.frame(300.0, 240.0, now=clk_fl.val) |> ignore
  let mut prev_fl_y = section_drawn_y(t_fl, rows_fl, "h/A").unwrap()
  let mut fx = 81.0
  while fx <= 120.0 {
    sc_fl.put(fx)
    clk_fl.val = clk_fl.val + 16.0
    t_fl.frame(300.0, 240.0, now=clk_fl.val) |> ignore
    let cur_y = section_drawn_y(t_fl, rows_fl, "h/A").unwrap()
    assert_true((cur_y - prev_fl_y).abs() <= 1.0 + 1.0e-6, msg="FLIP +30 jumped at x=\{fx}: \{prev_fl_y} -> \{cur_y}")
    prev_fl_y = cur_y
    fx = fx + 1.0
  }
  assert_true(prev_fl_y.abs() <= 1.0e-6, msg="FLIP +30 should end pinned at y=0, got \{prev_fl_y}")

  // 7. Flow heading extending into top_edge=20 is clipped for hit-testing (y=10 misses, y=22 hits)
  let ks_b2 : Array[String] = ["h/Last", "load_more"]
  for i in 0..<10 {
    ks_b2.push("r/t" + i.to_string())
  }
  let (t_b2, _, sc_b2, _, _, clk_b2, _, pressed_b2) = make_section_tree(
    ks_b2,
    h=240.0,
    top_edge=fn() { 20.0 },
    rows_cap=fn() { (1, 0) },
  )
  sc_b2.put(20.0)
  clk_b2.val = 16.0
  t_b2.frame(300.0, 240.0, now=clk_b2.val) |> ignore
  pressed_b2.clear()
  let _ = t_b2.press(50.0, 10.0)
  assert_false(pressed_b2.contains("h/Last"), msg="Flow heading inside top_edge inset (y=10) must be clipped from hits")
  assert_true(t_b2.press(50.0, 22.0))
  assert_eq(pressed_b2, ["h/Last"], msg="Visible part of Flow heading [20, 24) must remain clickable")
}

///|
test "section FLIP crosses top and bottom edges continuously for negative and positive slot residuals" {
  let ks : Array[String] = ["r/pre0", "r/pre1", "h/A"]
  for i in 0..<20 {
    ks.push("r/a" + i.to_string())
  }
  let (t, _, sc, _, _, clk, rows, _) = make_section_tree(
    ks,
    h=240.0,
    rows_cap=fn() { (1, 0) },
    grid=1.0,
  )
  let hd = rows.get("h/A").unwrap()
  let (slot, _, _) = t.section_slot_of(hd.at).unwrap()
  t.nodes[slot].look.drawn_off = (0.0, -30.0)
  let ys : Array[Double] = []
  for x in [80.0, 81.0] {
    sc.put(x)
    clk.val += 16.0
    t.frame(300.0, 240.0, now=clk.val) |> ignore
    ys.push(section_drawn_y(t, rows, "h/A").unwrap())
  }
  assert_true(
    (ys[1] - ys[0]).abs() <= 1.0 && ys[1].abs() <= 1.0e-6,
    msg="1pt scroll with -30 FLIP residual; actual y=\{ys[0]} -> \{ys[1]}",
  )

  // Bottom sticky with +30 residual crossing bottom edge continuously
  let ks_b : Array[String] = ["r/b0", "r/b1", "r/b2", "r/b3", "r/b4", "h/Bot"]
  for i in 0..<10 {
    ks_b.push("r/z" + i.to_string())
  }
  let (tb, _, scb, _, _, clkb, rowsb, _) = make_section_tree(
    ks_b,
    h=240.0,
    rows_cap=fn() { (0, 1) },
    grid=1.0,
  )
  let hdb = rowsb.get("h/Bot").unwrap()
  let (slotb, _, _) = tb.section_slot_of(hdb.at).unwrap()
  tb.nodes[slotb].look.drawn_off = (0.0, 30.0)
  let ysb : Array[Double] = []
  for x in [4.0, 3.0, 2.0] {
    scb.put(x)
    clkb.val += 16.0
    tb.frame(300.0, 240.0, now=clkb.val) |> ignore
    ysb.push(section_drawn_y(tb, rowsb, "h/Bot").unwrap())
  }
  assert_true(
    (ysb[1] - ysb[0]).abs() <= 1.0 && (ysb[2] - ysb[1]).abs() <= 1.0,
    msg="bottom FLIP +30 residual jumped: \{ysb[0]} -> \{ysb[1]} -> \{ysb[2]}",
  )
}

///|
test "late and replaced section chrome receives viewport box and yields hits to foot" {
  let ks : Array[String] = ["r/pre0", "r/pre1", "h/A"]
  for i in 0..<20 {
    ks.push("r/a" + i.to_string())
  }
  let keys = @signals.signal(ks)
  let p : ListPlace[String] = ListPlace::new()
  let sc = Scroll::list()
  let clk = Ref(0.0)
  let lv_ref : Ref[View?] = Ref(None)
  let foot_hits = Ref(0)
  let chrome_hits = Ref(0)
  let t = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        lv_ref.val = Some(
          o.scrolls_window(
            sc,
            fn() { keys.get() },
            place=p,
            est=40.0,
            foot=fn(fv) {
              fv
              .box(fn(fb) {
                fb
                .width(Is(Some(300.0)))
                .height(Is(Some(40.0)))
                .on_press(fn() { foot_hits.val = foot_hits.val + 1 })
                |> ignore
              })
              |> ignore
            },
            fn(b, k) {
              b.box(fn(l) {
                let h = if k.has_prefix("h/") { 44.0 } else { 40.0 }
                l.height(Is(Some(h))).shrink(Is(0.0)).width(Is(Some(300.0))) |> ignore
                if k.has_prefix("h/") {
                  l.sticky_section() |> ignore
                }
              })
              |> ignore
            },
          ),
        )
      })
      |> ignore
    },
    time=fn() { clk.val },
  )
  t.set_rows_grid(1.0)
  t.frame(300.0, 240.0, now=0.0) |> ignore
  t.frame(300.0, 240.0, now=0.0) |> ignore
  let lv = lv_ref.val.unwrap()
  let cv : Ref[View?] = Ref(None)
  p.set_sections(fn(k) { k.has_prefix("h/") }, chrome=fn(ch, _) {
    cv.val = Some(ch)
    ch.box(fn(pill) {
      let ps = t.nodes[pill.at].flex.style
      ps.position = @flex.PositionType::Absolute
      ps.set_inset_left(Pt(0.0))
      ps.set_inset_right(Pt(0.0))
      ps.set_inset_bottom(Pt(0.0))
      pill.height(Is(Some(40.0))).points(Is(true)).on_press(fn() { chrome_hits.val = chrome_hits.val + 1 }) |> ignore
    })
    |> ignore
  })
  clk.val += 16.0
  t.frame(300.0, 240.0, now=clk.val) |> ignore
  let ch = cv.val.unwrap()
  let cy = t.projected(ch.at, drawn=true).1
  let ly = t.projected(lv.at, drawn=true).1
  let h = t.nodes[ch.at].lh
  assert_true(
    (cy - ly).abs() <= 0.01 && (h - 240.0).abs() <= 0.01,
    msg="list y=\{ly}; chrome y=\{cy}, h=\{h}",
  )
  // Foot overlaps bottom 40pt of viewport and must take hit priority over late-registered chrome
  assert_true(t.press(50.0, 220.0))
  assert_eq((foot_hits.val, chrome_hits.val), (1, 0), msg="foot must win hit over overlapping section chrome")
}

///|
test "chrome reports heading at snapped scroll boundary" {
  let ks = [
    "h/A", "r/pre", "h/B", "r/1", "r/2", "r/3", "r/4", "r/5", "r/6", "r/7", "r/8",
  ]
  let cr : Ref[SectionChrome[String]?] = Ref(None)
  let (t, _, sc, _, _, clk, rows, _) = make_section_tree(
    ks,
    h=240.0,
    rows_cap=fn() { (1, 0) },
    grid=1.0,
    chrome_ref=cr,
  )
  sc.put(83.6)
  clk.val = 16.0
  t.frame(300.0, 240.0, now=clk.val) |> ignore
  let (_, held, _) = t.section_slot_of(rows.get("h/B").unwrap().at).unwrap()
  let x = -t.scroll_off_now(t.nodes[held]).1
  let oracle = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 84.0, r: 44.0 }],
    500.0,
    x,
    240.0,
    0.0,
    0.0,
    1,
    0,
    1.0,
  )
  assert_eq(oracle.active_idx, 1)
  assert_eq(
    cr.val.unwrap().active,
    Some("h/B"),
    msg="logical scroll=\{sc.drawn(t)}; drawn scroll=\{x}",
  )
}

///|
test "pushed section pin survives disclosure heading remeasurement" {
  let ks = ["h/A", "r/twenty", "r/fiftysix", "load_more"]
  let keys = @signals.signal(ks)
  let tall = @signals.signal(44.0)
  let p : ListPlace[String] = ListPlace::new()
  let sc = Scroll::list()
  let clock = Ref(0.0)
  let rows : Map[String, View] = Map([])
  let list : Ref[View?] = Ref(None)
  p.set_sections(fn(k) { k == "h/A" }, tail=fn(k) { k == "load_more" }, rows=fn() {
    (1, 0)
  })
  let t = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
        list.val = Some(
          o.scrolls_window(sc, fn() { keys.get() }, place=p, est=40.0, fn(b, k) {
            b.box(fn(l) {
              rows[k] = l
              l
              .height(
                By(fn() {
                  Some(
                    if k == "h/A" {
                      tall.get()
                    } else if k == "r/twenty" {
                      20.0
                    } else if k == "r/fiftysix" {
                      56.0
                    } else {
                      600.0
                    },
                  )
                }),
              )
              .shrink(Is(0.0))
              .width(Is(Some(300.0)))
              |> ignore
              if k == "h/A" {
                l
                .sticky_section()
                .says(Is(Some(said(Button, label=k, expanded=true))))
                .on_press(fn() {  })
                |> ignore
              }
            })
            |> ignore
          }),
        )
      })
      |> ignore
    },
    time=fn() { clock.val },
  )
  t.set_rows_grid(1.0)
  t.frame(300.0, 240.0, now=0.0) |> ignore
  t.frame(300.0, 240.0, now=0.0) |> ignore
  sc.put(100.0)
  clock.val = 16.0
  t.frame(300.0, 240.0, now=16.0) |> ignore
  let old_y = section_drawn_y(t, rows, "h/A").unwrap()
  assert_eq(old_y, -24.0)
  assert_eq(p.section_state("h/A"), Active)
  clock.val = 50.0
  t.event(50.0, fn() {
    let hit = t.press(50.0, 10.0)
    ignore(hit)
    transition(within=list.val.unwrap(), fn() {
      keys.set(["h/A", "r/fiftysix", "load_more"])
      tall.set(64.0)
    })
  })
  for tm in [50.0, 80.0, 120.0, 200.0] {
    clock.val = tm
    t.frame(300.0, 240.0, now=tm) |> ignore
    let y = section_drawn_y(t, rows, "h/A").unwrap()
    assert_true(
      (y - old_y).abs() <= 0.01,
      msg="t=\{tm}, x=\{sc.drawn(t)}, before=\{old_y}, after=\{y}",
    )
  }
}

///|
test "fractional Flow contacts, visible slot counts, and large-cap downgrade" {
  // 1. Top contact with Flow neighbor preserves 0.0pt shared edge
  let a = solve_sections(
    [{ key: 0, p: 0.0, r: 44.6 }, { key: 1, p: 100.0, r: 44.0 }],
    500.0,
    60.0,
    240.0,
    0.0,
    0.0,
    1,
    0,
    1.0,
  )
  let gap = a.drawn[1] - a.drawn[0] - a.rs[0]
  assert_true(gap.abs() < 1.0e-6, msg="gap=\{gap}")
  assert_eq(a.states[1], Flow)
  assert_eq(a.dys[1], 0.0)

  // 2. Bottom contact with Flow neighbor keeps Flow fixed with dy=0.0 and 0.0pt gap
  let b = solve_sections(
    [{ key: 0, p: 0.0, r: 44.4 }, { key: 1, p: 300.0, r: 40.0 }],
    500.0,
    0.0,
    75.0,
    0.0,
    0.0,
    0,
    1,
    1.0,
  )
  assert_eq(b.states[0], Flow)
  assert_eq(b.dys[0], 0.0)
  assert_true((b.drawn[1] - b.drawn[0] - b.rs[0]).abs() < 1.0e-6)

  // 3. Fractional bottom_edge=0.6 with bot_cap=1 counts 1 visible + 1 overflow and mounts 1
  let c = solve_sections(
    [{ key: 0, p: 3000.0, r: 44.0 }, { key: 1, p: 5000.0, r: 44.0 }],
    5740.0,
    0.0,
    240.0,
    0.0,
    0.6,
    0,
    1,
    1.0,
  )
  assert_eq((c.below_count, c.below_overflow), (1, 1))
  assert_eq(c.mounted_keys, [0])

  // 4. Mirror fractional top_edge=0.6 with top_cap=1 counts 0 visible above + 1 overflow and mounts 1
  let d = solve_sections(
    [{ key: 0, p: 0.0, r: 44.0 }, { key: 1, p: 100.0, r: 44.0 }],
    500.0,
    200.0,
    240.0,
    0.6,
    0.0,
    1,
    0,
    1.0,
  )
  assert_eq((d.above_count, d.above_overflow, d.active_idx), (0, 1, 1))
  assert_eq(d.mounted_keys, [1])

  // 5. Large-cap binary search downgrade finishes fast and downgrades exact cap
  let many : Array[SectionGeom] = []
  for i in 0..<2000 {
    many.push({ key: i, p: i.to_double() * 80.0, r: 44.0 })
  }
  let big = solve_sections(many, 160000.0, 0.0, 240.0, 0.0, 0.0, 2000, 2000, 1.0)
  assert_eq((big.eff_top_cap, big.eff_bot_cap), (5, 0))
}
