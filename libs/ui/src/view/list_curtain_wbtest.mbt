// Unified curtain motion in `View::scrolls_window` (`curtain?`):
// - Contiguous curtain segments move under one scalar `CurtainRun` with zero inner `scale`, `bounds_input`, `hides`, and frontier alpha
// - Viewport truncation for 200-row groups: offscreen rows neither materialize zero-height slots nor cause 95% dead-time
// - Split segments by an active survivor key (`(prev_survivor, next_survivor)`) share one `ComeGroup`
// - Mid-flight reversal (`come_back`) rebinds surviving slots seamlessly without height jump and cleans up in `seen_whole`

///|
fn curtain_test_tree(
  initial : Array[String],
  curtain_pred : (String) -> Bool,
  h? : Double = 320.0,
  grid? : Double = 2.0,
) -> (Tree, View, @signals.Signal[Array[String]], Ref[Double], Ref[Int], Map[String, View]) {
  let clock = Ref(0.0)
  let keys = @signals.signal(initial, same=fn(a, b) { a == b })
  let made = Ref(0)
  let list_v : Ref[View?] = Ref(None)
  let row_views : Map[String, View] = Map([])
  let tree = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(h))) |> ignore
        let place : ListPlace[String] = ListPlace::new()
        place.set_curtain(curtain_pred)
        let lv = o.scrolls_window(
          Scroll::list(),
          fn() { keys.get() },
          est=40.0,
          comes=fn(k) { k.has_prefix("r/") },
          goes=fn(k) { k.has_prefix("r/") },
          place~,
          fn(b, k) {
            made.val += 1
            b.box(fn(l) {
              row_views[k] = l
              l.height(Is(Some(if k.has_prefix("h/") { 32.0 } else { 40.0 }))).words(Is(k)) |> ignore
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
  tree.frame(300.0, h, now=clock.val) |> ignore
  tree.frame(300.0, h, now=clock.val) |> ignore
  (tree, list_v.val.unwrap(), keys, clock, made, row_views)
}

///|
fn find_word_top(tree : Tree, row_views : Map[String, View], word : String) -> Double? {
  match row_views.get(word) {
    Some(v) if v.live() is Some(n) => {
      let mut y = n.ly
      let mut p = n.parent
      while p >= 0 {
        let pn = tree.nodes[p]
        if !pn.slot {
          y = y + pn.ly
        }
        p = pn.parent
      }
      Some(y)
    }
    _ => None
  }
}

///|
test "scrolls_window curtain collapse/expand has single frontier, no inner scale, and clean seen_whole reset" {
  let initial = ["h/A", "r/0", "r/1", "r/2", "r/3", "h/B", "r/b0"]
  let (tree, lv, keys, clock, _, row_views) = curtain_test_tree(initial, fn(k) { k.has_prefix("r/") && !k.has_prefix("r/b") })
  let hb_open = find_word_top(tree, row_views, "h/B").unwrap()
  // h/A (32) + 4 * 40 = 192
  assert_true((hb_open - 192.0).abs() <= 0.5, msg="expected h/B at 192, got \{hb_open}")

  // Collapse group A at t = 100
  clock.val = 100.0
  tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(["h/A", "h/B", "r/b0"]) }) })
  tree.frame(300.0, 320.0, now=clock.val) |> ignore

  // Mid-motion at t = 160: h/B is strictly between 32 and 192, no inner block has scale != 1.0,
  // and active curtain slots have bounds_input == true.
  clock.val = 160.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let hb_mid = find_word_top(tree, row_views, "h/B").unwrap()
  assert_true(hb_mid > 32.5 && hb_mid < 191.5, msg="h/B should move smoothly mid-collapse: \{hb_mid}")
  let mut curtain_slots = 0
  let mut partial_slots = 0
  for n in tree.nodes {
    if n.live && n.flex.style.come_curtain() is Some((run, idx)) {
      curtain_slots += 1
      assert_true(n.bounds_input, msg="curtain slot must clip pointer hit-testing via bounds_input")
      let sh = run.slot_height_at(idx, 160.0)
      if sh > 0.5 && sh < run.wholes[idx] - 0.5 {
        partial_slots += 1
      }
      for kid in n.kids {
        assert_eq(tree.nodes[kid].look.scale, 1.0, msg="curtain inner block must never scale")
      }
    }
  }
  assert_true(curtain_slots == 4, msg="expected 4 curtain slots, got \{curtain_slots}")
  assert_true(partial_slots <= 1, msg="expected at most 1 frontier row, got \{partial_slots}")

  // After move_most_ms: settled at 32.0
  clock.val = 100.0 + @flex.move_most_ms + 20.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let hb_closed = find_word_top(tree, row_views, "h/B").unwrap()
  assert_true((hb_closed - 32.0).abs() <= 0.5, msg="expected h/B at 32 after collapse, got \{hb_closed}")

  // Re-expand group A at t = 800
  clock.val = 800.0
  tree.event(800.0, fn() { transition(within=lv, fn() { keys.set(initial) }) })
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  clock.val = 860.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let hb_reopen_mid = find_word_top(tree, row_views, "h/B").unwrap()
  assert_true(hb_reopen_mid > 32.5 && hb_reopen_mid < 191.5, msg="h/B should move smoothly mid-expand: \{hb_reopen_mid}")

  // Settle and verify full seen_whole cleanup
  clock.val = 800.0 + @flex.move_most_ms + 20.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let hb_reopen_end = find_word_top(tree, row_views, "h/B").unwrap()
  assert_true((hb_reopen_end - 192.0).abs() <= 0.5)
  for _, rv in row_views {
    if rv.live() is Some(rn) && rn.parent >= 0 {
      let slot = tree.nodes[rn.parent]
      assert_true(slot.flex.style.come_curtain() is None, msg="come_curtain must be cleared after settle")
      assert_false(slot.bounds_input, msg="slot bounds_input must be reset after settle")
      assert_false(slot.said_hidden, msg="slot hides must be reset after settle")
      assert_eq(slot.look.alpha, 1.0, msg="slot alpha must be reset to 1.0 after settle")
    }
  }
}

///|
test "scrolls_window curtain viewport truncation handles 200-row group without offscreen slots or dead-time" {
  let collapsed = ["h/Big", "h/Next"]
  let expanded : Array[String] = ["h/Big"]
  for i in 0..<200 {
    expanded.push("r/" + i.to_string())
  }
  expanded.push("h/Next")
  let (tree, lv, keys, clock, made, _) = curtain_test_tree(collapsed, fn(k) { k.has_prefix("r/") }, h=240.0)
  let made_before = made.val

  // Expand 200 rows at t = 100
  clock.val = 100.0
  tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(expanded) }) })
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  let made_after_expand = made.val - made_before
  // Must materialize only viewport + margin rows, never 200 zero-height slots!
  assert_true(made_after_expand < 30, msg="200-row expand materialized too many slots: \{made_after_expand}")

  // Check active curtain run has <= 10 visible members (240 / 40 = 6 + margin)
  let mut run_len = 0
  for n in tree.nodes {
    if n.live && n.flex.style.come_curtain() is Some((run, _)) {
      run_len = run.wholes.length()
      break
    }
  }
  assert_true(run_len > 0 && run_len <= 12, msg="viewport-truncated curtain run length should be <= 12, got \{run_len}")

  // Settle expand
  clock.val = 700.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore

  // Collapse 200 rows at t = 800: must move visibly at t = 860 (no 95% offscreen dead-time!)
  clock.val = 800.0
  tree.event(800.0, fn() { transition(within=lv, fn() { keys.set(collapsed) }) })
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  clock.val = 860.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  let mut close_run_total = 0.0
  let mut close_run_now = 0.0
  for n in tree.nodes {
    if n.live && n.flex.style.come_curtain() is Some((run, _)) {
      close_run_total = run.total
      close_run_now = run.total_at(860.0)
      break
    }
  }
  assert_true(close_run_total > 0.0 && close_run_total <= 480.0, msg="closing run total should be viewport-truncated, got \{close_run_total}")
  assert_true(close_run_now < close_run_total - 10.0, msg="closing curtain must move visibly at +60ms, not freeze in offscreen dead-time")
}

///|
test "scrolls_window curtain splits around surviving active row and reverses smoothly mid-flight (come_back)" {
  let expanded = ["h/A", "r/0", "r/1", "r/active", "r/2", "r/3", "h/B"]
  let collapsed = ["h/A", "r/active", "h/B"]
  let (tree, lv, keys, clock, _, row_views) = curtain_test_tree(expanded, fn(k) { k.has_prefix("r/") && k != "r/active" })

  // Collapse around r/active at t = 100
  clock.val = 100.0
  tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(collapsed) }) })
  tree.frame(300.0, 320.0, now=clock.val) |> ignore

  // Verify two distinct CurtainRuns (above and below r/active) sharing one ComeGroup end
  let runs : Array[@flex.CurtainRun] = []
  for n in tree.nodes {
    if n.live && n.flex.style.come_curtain() is Some((run, _)) {
      if !runs.iter().any(fn(o) { physical_equal(o, run) }) {
        runs.push(run)
      }
    }
  }
  assert_eq(runs.length(), 2, msg="active survivor must split group into 2 independent CurtainRuns")
  assert_eq(runs[0].ends, runs[1].ends, msg="both segments must share one ComeGroup end")

  // Mid-flight at t = 170: rapidly reverse back to expanded (come_back path!)
  clock.val = 170.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let active_before_rev = find_word_top(tree, row_views, "r/active").unwrap()
  let hb_before_rev = find_word_top(tree, row_views, "h/B").unwrap()
  tree.event(170.0, fn() { transition(within=lv, fn() { keys.set(expanded) }) })
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let active_at_rev = find_word_top(tree, row_views, "r/active").unwrap()
  let hb_at_rev = find_word_top(tree, row_views, "h/B").unwrap()
  // No jump at reversal moment!
  assert_true((active_at_rev - active_before_rev).abs() <= 1.0, msg="r/active jumped on reversal: \{active_before_rev} -> \{active_at_rev}")
  assert_true((hb_at_rev - hb_before_rev).abs() <= 1.0, msg="h/B jumped on reversal: \{hb_before_rev} -> \{hb_at_rev}")

  // Settle after reversal: everything back to full expanded positions and cleaned up
  clock.val = 170.0 + @flex.move_most_ms + 100.0
  tree.frame(300.0, 320.0, now=clock.val) |> ignore
  let active_end = find_word_top(tree, row_views, "r/active").unwrap()
  let hb_end = find_word_top(tree, row_views, "h/B").unwrap()
  assert_true((active_end - 112.0).abs() <= 0.5, msg="expected r/active at 112, got \{active_end}")
  assert_true((hb_end - 232.0).abs() <= 0.5, msg="expected h/B at 232, got \{hb_end}")
  for _, rv in row_views {
    if rv.live() is Some(rn) && rn.parent >= 0 {
      let slot = tree.nodes[rn.parent]
      assert_true(slot.flex.style.come_curtain() is None)
      assert_false(slot.bounds_input)
      assert_false(slot.said_hidden)
      assert_eq(slot.look.alpha, 1.0)
    }
  }
}

///|
test "scrolls_window curtain mid-viewport expand never flashes offscreen tail rows below header (Opus B1)" {
  let collapsed = ["h/Top", "t/top0", "t/top1", "h/Mid", "h/After"]
  let expanded : Array[String] = ["h/Top", "t/top0", "t/top1", "h/Mid"]
  for i in 0..<20 {
    expanded.push("r/" + i.to_string())
  }
  expanded.push("h/After")
  let (tree, lv, keys, clock, _, row_views) = curtain_test_tree(collapsed, fn(k) { k.has_prefix("r/") }, h=240.0)
  let mid_y0 = find_word_top(tree, row_views, "h/Mid").unwrap()
  let after_y0 = find_word_top(tree, row_views, "h/After").unwrap()
  assert_true(mid_y0 >= 100.0 && mid_y0 < 150.0, msg="h/Mid should start in middle of 240pt viewport, got \{mid_y0}")
  assert_true((after_y0 - (mid_y0 + 32.0)).abs() <= 0.5)

  // Expand 20 rows under h/Mid at t = 100
  clock.val = 100.0
  tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(expanded) }) })
  tree.frame(300.0, 240.0, now=clock.val) |> ignore

  // At +16ms and +60ms (and while pressing/holding the list mid-expand at +60ms..+76ms):
  // tail rows outside the curtain run (e.g. r/10) must NOT flash into the viewport!
  for dt in [16.0, 60.0] {
    clock.val = 100.0 + dt
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    let mid_y = find_word_top(tree, row_views, "h/Mid").unwrap()
    assert_true((mid_y - mid_y0).abs() <= 0.5, msg="h/Mid drifted at +\{dt}ms: \{mid_y0} -> \{mid_y}")
    // First non-run tail row r/10 must either be absent or below viewport bottom (240)
    match find_word_top(tree, row_views, "r/10") {
      Some(y) => assert_true(y >= 240.0, msg="tail row r/10 flashed into viewport at +\{dt}ms: y=\{y}")
      None => ()
    }
    match find_word_top(tree, row_views, "r/15") {
      Some(y) => assert_true(y >= 240.0, msg="tail row r/15 flashed into viewport at +\{dt}ms: y=\{y}")
      None => ()
    }
  }
  // Settle: r/0..r/2 visible under h/Mid, r/10 still offscreen below viewport
  clock.val = 700.0
  tree.frame(300.0, 240.0, now=clock.val) |> ignore
  let m0_end = find_word_top(tree, row_views, "r/0").unwrap()
  assert_true((m0_end - (mid_y0 + 32.0)).abs() <= 0.5, msg="r/0 should settle right under h/Mid: \{m0_end}")
}

///|
test "scrolls_window curtain pressing list mid-expand (in_hand) keeps h/After and first hidden tail row r/4 identical to unheld (Opus/Astra)" {
  let collapsed = ["h/Top", "t/top0", "t/top1", "h/Mid", "h/After"]
  let expanded : Array[String] = ["h/Top", "t/top0", "t/top1", "h/Mid"]
  for i in 0..<20 {
    expanded.push("r/" + i.to_string())
  }
  expanded.push("h/After")
  let mk = fn() {
    let clock = Ref(0.0)
    let keys = @signals.signal(collapsed, same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let list_v : Ref[View?] = Ref(None)
    let rows : Map[String, View] = Map([])
    let tree = Tree::new(
      fn(root) {
        root.box(fn(o) {
          o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
          let place : ListPlace[String] = ListPlace::new()
          place.set_curtain(fn(k) { k.has_prefix("r/") })
          let lv = o.scrolls_window(
            scroll,
            fn() { keys.get() },
            est=40.0,
            comes=fn(k) { k.has_prefix("r/") },
            goes=fn(k) { k.has_prefix("r/") },
            place~,
            fn(b, k) {
              b.box(fn(l) {
                rows[k] = l
                l.height(Is(Some(if k.has_prefix("h/") { 32.0 } else { 40.0 }))).words(Is(k)) |> ignore
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
    tree.set_rows_grid(2.0)
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    (tree, list_v.val.unwrap(), keys, clock, scroll, rows)
  }
  let (t_unheld, lv_u, keys_u, clk_u, _, rows_u) = mk()
  let (t_held, lv_h, keys_h, clk_h, scroll_h, rows_h) = mk()

  // Expand 20 rows on both trees at t = 100 and advance to t = 108ms (h/After still in viewport, r/4..r/19 hidden tail)
  clk_u.val = 100.0
  clk_h.val = 100.0
  t_unheld.event(100.0, fn() { transition(within=lv_u, fn() { keys_u.set(expanded) }) })
  t_held.event(100.0, fn() { transition(within=lv_h, fn() { keys_h.set(expanded) }) })
  t_unheld.frame(300.0, 240.0, now=100.0) |> ignore
  t_held.frame(300.0, 240.0, now=100.0) |> ignore
  clk_u.val = 108.0
  clk_h.val = 108.0
  t_unheld.frame(300.0, 240.0, now=108.0) |> ignore
  t_held.frame(300.0, 240.0, now=108.0) |> ignore

  // Press the held list at t = 108ms and verify `scroll_h.in_hand()` is genuinely true
  let cid = match t_held.claimers_at(150.0, 120.0) {
    [(id, _), ..] => id
    _ => fail("expected a scroll claimer at (150, 120)")
  }
  t_held.drag_at(cid, Down, 150.0, 120.0, 108.0, finger=0) |> ignore
  assert_true(scroll_h.in_hand(), msg="expected scroll_h.in_hand() == true after Down")

  // Next animation frame at t = 116ms: held tree MUST match unheld tree on h/After and first hidden tail row r/4
  clk_u.val = 116.0
  clk_h.val = 116.0
  t_unheld.frame(300.0, 240.0, now=116.0) |> ignore
  t_held.frame(300.0, 240.0, now=116.0) |> ignore
  let after_u = match find_word_top(t_unheld, rows_u, "h/After") {
    Some(y) => y
    None => fail("unheld h/After must be visible at t=116ms")
  }
  let after_h = match find_word_top(t_held, rows_h, "h/After") {
    Some(y) => y
    None => fail("held h/After vanished on in_hand at t=116ms (old tail-clear regression)")
  }
  assert_eq(after_h, after_u, msg="held h/After drifted from unheld at t=116ms: \{after_h} vs \{after_u}")
  match find_word_top(t_held, rows_h, "r/4") {
    Some(y) => assert_true(y >= 240.0, msg="first hidden tail row r/4 flashed into viewport on in_hand at y=\{y}")
    None => ()
  }
  assert_eq(
    find_word_top(t_held, rows_h, "r/4"),
    find_word_top(t_unheld, rows_u, "r/4"),
    msg="held r/4 placement diverged from unheld at t=116ms",
  )

  // Release and settle cleanly
  t_held.drag_at(cid, Up, 150.0, 120.0, 116.0, finger=0) |> ignore
  assert_false(scroll_h.in_hand())
  clk_h.val = 700.0
  t_held.frame(300.0, 240.0, now=700.0) |> ignore
  assert_true(find_word_top(t_held, rows_h, "r/0") is Some(_))
}

///|
test "scrolls_window curtain reversal after scroll-down and scroll-up remaps R across overlapping keys continuously (Astra M1/M3)" {
  // Surround h/Big with surviving rows above (p/0..p/9 = 400pt) and below (q/0..q/9 = 400pt) so scroll never clamps to 0.
  let collapsed : Array[String] = []
  let expanded : Array[String] = []
  for i in 0..<10 {
    collapsed.push("p/" + i.to_string())
    expanded.push("p/" + i.to_string())
  }
  collapsed.push("h/Big")
  expanded.push("h/Big")
  for i in 0..<200 {
    expanded.push("r/" + i.to_string())
  }
  collapsed.push("h/Next")
  expanded.push("h/Next")
  for i in 0..<10 {
    collapsed.push("q/" + i.to_string())
    expanded.push("q/" + i.to_string())
  }
  let find_curtain_slot = fn(tree : Tree, rv : View) -> Int? {
    match rv.live() {
      Some(rn) => {
        let mut p = rn.parent
        while p >= 0 {
          if tree.nodes[p].flex.style.come_curtain() is Some(_) {
            return Some(p)
          }
          p = tree.nodes[p].parent
        }
        None
      }
      None => None
    }
  }
  // Verify BOTH scroll directions:
  //   Case 1 (scroll down): start at y=472 (r/0..r/6), scroll down to y=552 (drops r/0,r/1, adds lower rows)
  //   Case 2 (scroll up):   start at y=592 (r/3..r/9), scroll up to y=472 (prepends r/0,r/1,r/2 before frontier)
  for case in [(472.0, 552.0, "down"), (592.0, 472.0, "up")] {
    let (y_start, y_mid, dir) = case
    let clock = Ref(0.0)
    let keys = @signals.signal(expanded, same=fn(a, b) { a == b })
    let s = Scroll::list()
    let row_views : Map[String, View] = Map([])
    let list_v : Ref[View?] = Ref(None)
    let tree = Tree::new(
      fn(root) {
        root.box(fn(o) {
          o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
          let place : ListPlace[String] = ListPlace::new()
          place.set_curtain(fn(k) { k.has_prefix("r/") })
          let lv = o.scrolls_window(
            s,
            fn() { keys.get() },
            est=40.0,
            comes=fn(k) { k.has_prefix("r/") },
            goes=fn(k) { k.has_prefix("r/") },
            place~,
            fn(b, k) {
              b.box(fn(l) {
                row_views[k] = l
                l.height(Is(Some(if k.has_prefix("h/") { 32.0 } else { 40.0 }))).words(Is(k)) |> ignore
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
    tree.set_rows_grid(2.0)
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    s.put(y_start)
    clock.val = 20.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    let lv = list_v.val.unwrap()

    // Start collapsing at t = 100
    clock.val = 100.0
    tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(collapsed) }) })
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    clock.val = 160.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore

    // Record active curtain keys & heights BEFORE shifting scroll and reversing
    let before_keys : Array[String] = []
    let mut partial_key = ""
    let mut partial_h = -1.0
    for i in 0..<200 {
      let k = "r/" + i.to_string()
      match row_views.get(k) {
        Some(rv) =>
          match find_curtain_slot(tree, rv) {
            Some(sp) => {
              let slot = tree.nodes[sp]
              before_keys.push(k)
              if partial_key == "" && slot.flex.height > 2.0 && slot.flex.height < 38.0 {
                partial_key = k
                partial_h = slot.flex.height
              }
            }
            None => ()
          }
        None => ()
      }
    }
    let before_s = before_keys.join(",")
    assert_true(
      partial_key != "",
      msg="dir=\{dir}: expected a strictly partial frontier row at t=160ms, before_keys=\{before_s}",
    )

    // Mid-flight at t = 165, shift scroll to `y_mid` so the viewport-truncated slice changes, then reverse back to expanded
    s.put(y_mid)
    clock.val = 165.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    // Re-read the frontier row's exact curtain index, height, and screen y right before reversal at t=165
    let pre_rv = row_views.get(partial_key).unwrap()
    let pre_slot = tree.nodes[find_curtain_slot(tree, pre_rv).unwrap()]
    let old_idx = match pre_slot.flex.style.come_curtain() {
      Some((_, i)) => i
      None => -1
    }
    partial_h = pre_slot.flex.height
    let partial_sy = find_word_top(tree, row_views, partial_key).unwrap() - s.drawn(tree)
    assert_true(
      partial_h > 0.0 && partial_h < 40.0 && old_idx >= 0,
      msg="dir=\{dir}: frontier row \{partial_key} not partial before reversal: h=\{partial_h}, idx=\{old_idx}",
    )

    tree.event(165.0, fn() { transition(within=lv, fn() { keys.set(expanded) }) })
    tree.frame(300.0, 240.0, now=clock.val) |> ignore

    // Hard assertions (no silent skip!):
    // 1. Frontier row MUST survive in the rebound CurtainRun with a shifted index (`new_idx < old_idx` on down,
    //    `new_idx > old_idx` on up — proving earlier rows were dropped/prepended in `vis_seg`!).
    // 2. Frontier row height & screen-y MUST remain continuous (`<= 2.0pt`).
    // 3. Every visible curtain row before frontier MUST stay full 40pt (no shrinkage jump on scroll-up prepend!).
    // 4. Every visible curtain row after frontier MUST stay 0pt (no premature reveal!).
    let post_rv = row_views.get(partial_key).unwrap()
    let post_slot = tree.nodes[find_curtain_slot(tree, post_rv).unwrap()]
    let (post_run, new_idx) = match post_slot.flex.style.come_curtain() {
      Some((r, i)) => (r, i)
      None => fail("dir=\{dir}: frontier row \{partial_key} lost come_curtain after reversal")
    }
    if dir == "down" {
      assert_true(
        new_idx < old_idx,
        msg="dir=down: expected curtain index of \{partial_key} to decrease after scrolling down: old=\{old_idx}, new=\{new_idx}",
      )
    } else {
      assert_true(
        new_idx > old_idx,
        msg="dir=up: expected curtain index of \{partial_key} to increase (prepended prefix) after scrolling up: old=\{old_idx}, new=\{new_idx}",
      )
    }
    assert_true(
      (post_slot.flex.height - partial_h).abs() <= 2.0,
      msg="dir=\{dir}: frontier row \{partial_key} height jumped across reversal: \{partial_h} -> \{post_slot.flex.height} (old_idx=\{old_idx}, new_idx=\{new_idx})",
    )
    let post_sy = find_word_top(tree, row_views, partial_key).unwrap() - s.drawn(tree)
    assert_true(
      (post_sy - partial_sy).abs() <= 2.0,
      msg="dir=\{dir}: frontier row \{partial_key} screen-y jumped across reversal: \{partial_sy} -> \{post_sy}",
    )
    // Verify EVERY slot in the new CurtainRun matches the invariant (full 40pt before frontier, 0pt after frontier)
    for j in 0..<post_run.wholes.length() {
      let sh = post_run.slot_height_at(j, clock.val)
      if j < new_idx {
        assert_true(
          (sh - 40.0).abs() <= 1.0,
          msg="dir=\{dir}: new CurtainRun slot \{j} before frontier \{new_idx} shrank to \{sh}",
        )
      } else if j == new_idx {
        assert_true(
          (sh - partial_h).abs() <= 2.0,
          msg="dir=\{dir}: new CurtainRun frontier slot \{j} jumped: \{partial_h} -> \{sh}",
        )
      } else {
        assert_true(
          sh <= 1.0,
          msg="dir=\{dir}: new CurtainRun slot \{j} after frontier \{new_idx} prematurely opened to \{sh}",
        )
      }
    }
    // Settle cleanly
    clock.val = 800.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
  }
}

///|
test "scrolls_window entering curtain offscreen tail spans stay O(1) across 30, 200, and 15000 rows (Astra M2)" {
  let counts : Array[Int] = []
  for total_rows in [30, 200, 15000] {
    let collapsed = ["h/Top", "h/Mid", "h/Next"]
    let expanded : Array[String] = ["h/Top", "h/Mid"]
    for i in 0..<total_rows {
      expanded.push("r/" + i.to_string())
    }
    expanded.push("h/Next")
    let clock = Ref(0.0)
    let keys = @signals.signal(collapsed, same=fn(a, b) { a == b })
    let s = Scroll::list()
    let row_views : Map[String, View] = Map([])
    let list_v : Ref[View?] = Ref(None)
    let made_count = Ref(0)
    let tree = Tree::new(
      fn(root) {
        root.box(fn(o) {
          o.width(Is(Some(300.0))).height(Is(Some(240.0))) |> ignore
          let place : ListPlace[String] = ListPlace::new()
          place.set_curtain(fn(k) { k.has_prefix("r/") })
          let lv = o.scrolls_window(
            s,
            fn() { keys.get() },
            est=40.0,
            comes=fn(k) { k.has_prefix("r/") },
            goes=fn(k) { k.has_prefix("r/") },
            place~,
            fn(b, k) {
              made_count.val += 1
              b.box(fn(l) {
                row_views[k] = l
                l.height(Is(Some(if k.has_prefix("h/") { 32.0 } else { 40.0 }))).words(Is(k)) |> ignore
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
    tree.set_rows_grid(2.0)
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    tree.frame(300.0, 240.0, now=0.0) |> ignore
    let lv = list_v.val.unwrap()
    let mid_y0 = find_word_top(tree, row_views, "h/Mid").unwrap()
    made_count.val = 0

    // Expand `total_rows` rows at t=100
    clock.val = 100.0
    tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(expanded) }) })
    tree.frame(300.0, 240.0, now=clock.val) |> ignore

    // Step through opening frames: tail rows must never materialize or flash, and h/Mid stays pinned
    for dt in [16.0, 60.0, 120.0] {
      clock.val = 100.0 + dt
      tree.frame(300.0, 240.0, now=clock.val) |> ignore
      let mid_y = find_word_top(tree, row_views, "h/Mid").unwrap()
      assert_true((mid_y - mid_y0).abs() <= 0.5, msg="N=\{total_rows} h/Mid drifted at +\{dt}ms")
      let last_tail = "r/" + (total_rows - 1).to_string()
      assert_true(
        find_word_top(tree, row_views, last_tail) is None,
        msg="N=\{total_rows} tail row \{last_tail} materialized mid-expand at +\{dt}ms",
      )
    }
    counts.push(made_count.val)
    // Settle cleanly
    clock.val = 700.0
    tree.frame(300.0, 240.0, now=clock.val) |> ignore
    assert_true(find_word_top(tree, row_views, "r/0") is Some(_), msg="N=\{total_rows} r/0 missing after settle")
  }
  // O(1) materialized work across 30, 200, and 15,000 rows in the same viewport!
  let cstr = counts.map(fn(x) { x.to_string() }).join(",")
  assert_eq(counts[0], counts[1], msg="materialized count grew from 30 to 200 rows: \{cstr}")
  assert_eq(counts[1], counts[2], msg="materialized count grew from 200 to 15000 rows: \{cstr}")
  assert_true(counts[2] <= 24, msg="materialized count exceeded O(V) budget for 15000 rows: \{counts[2]}")
}

///|
test "scrolls_window curtain tail spans stay continuous when live updates remove interior, remove endpoint, or move endpoint past next header (Astra R3)" {
  let check_mutation = fn(name : String, mutate : (Array[String]) -> Array[String]) raise {
    let base = ["h/Top", "t/0", "t/1", "h/Mid"]
    let full = base.copy()
    for i in 0..<20 {
      full.push("r/" + i.to_string())
    }
    full.push("h/After")
    base.push("h/After")
    let (tree, lv, keys, clock, _, rows) = curtain_test_tree(base, fn(k) { k.has_prefix("r/") }, h=240.0)
    clock.val = 100.0
    tree.event(100.0, fn() { transition(within=lv, fn() { keys.set(full) }) })
    tree.frame(300.0, 240.0, now=100.0) |> ignore
    clock.val = 108.0
    tree.frame(300.0, 240.0, now=108.0) |> ignore
    let before = match find_word_top(tree, rows, "h/After") {
      Some(y) => y
      None => fail("\{name}: h/After must be visible at t=108ms before mutation")
    }
    let visible_r_before : Array[String] = []
    for i in 0..<20 {
      let k = "r/" + i.to_string()
      if find_word_top(tree, rows, k) is Some(y) && y >= 0.0 && y < 240.0 {
        visible_r_before.push(k)
      }
    }
    let next_keys = mutate(full)
    tree.event(108.0, fn() { keys.set(next_keys) })
    tree.frame(300.0, 240.0, now=108.0) |> ignore
    let after = match find_word_top(tree, rows, "h/After") {
      Some(y) => y
      None => fail("\{name}: h/After disappeared after same-timestamp mutation (was y=\{before})")
    }
    assert_eq(after, before, msg="\{name}: h/After jumped after same-timestamp mutation: \{before} -> \{after}")
    // No offscreen tail row that was hidden before the mutation may flash into [0, 240)
    for i in 0..<20 {
      let k = "r/" + i.to_string()
      if !visible_r_before.contains(k) {
        match find_word_top(tree, rows, k) {
          Some(y) =>
            assert_true(
              y >= 240.0 || y < 0.0,
              msg="\{name}: hidden tail row \{k} flashed into viewport at y=\{y}",
            )
          None => ()
        }
      }
    }
    // Settle cleanly after curtain ends
    clock.val = 700.0
    tree.frame(300.0, 240.0, now=700.0) |> ignore
    assert_true(find_word_top(tree, rows, "r/0") is Some(_), msg="\{name}: r/0 missing after settle")
  }
  // 1. Control: remove interior tail row r/18
  check_mutation("remove-interior-r18", fn(full) { full.filter(fn(k) { k != "r/18" }) })
  // 2. Remove trailing tail endpoint r/19
  check_mutation("remove-end-r19", fn(full) { full.filter(fn(k) { k != "r/19" }) })
  // 3. Remove leading tail endpoint r/4
  check_mutation("remove-start-r4", fn(full) { full.filter(fn(k) { k != "r/4" }) })
  // 4. Move trailing tail endpoint r/19 past h/After
  check_mutation("move-end-r19-past-header", fn(full) {
    let out = full.filter(fn(k) { k != "r/19" })
    out.push("r/19")
    out
  })
}
