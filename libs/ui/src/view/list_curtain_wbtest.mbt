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
        let lv = o.scrolls_window(
          Scroll::list(),
          fn() { keys.get() },
          est=40.0,
          comes=fn(k) { k.has_prefix("r/") },
          goes=fn(k) { k.has_prefix("r/") },
          curtain=curtain_pred,
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
    if n.live && n.flex.style.come_curtain is Some((run, idx)) {
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
      assert_true(slot.flex.style.come_curtain is None, msg="come_curtain must be cleared after settle")
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
    if n.live && n.flex.style.come_curtain is Some((run, _)) {
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
    if n.live && n.flex.style.come_curtain is Some((run, _)) {
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
    if n.live && n.flex.style.come_curtain is Some((run, _)) {
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
      assert_true(slot.flex.style.come_curtain is None)
      assert_false(slot.bounds_input)
      assert_false(slot.said_hidden)
      assert_eq(slot.look.alpha, 1.0)
    }
  }
}
