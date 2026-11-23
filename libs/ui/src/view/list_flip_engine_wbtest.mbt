// Regression tests for FLIP engine quiet classification (QuietReset vs QuietDelta)
// and native HoldRoomFade (leaves_room exit fade) on flips=true lists.

///|
fn flip_drawn_info(tree : Tree, label : String) -> (Double, Double, Double)? {
  for d in tree.drawn() {
    if d.words == label {
      return Some((d.y, d.h, d.alpha))
    }
  }
  None
}

///|
fn flip_step_to(tree : Tree, clock : Ref[Double], target : Double, period : Double) -> Unit {
  if period <= 0.0 {
    if target > clock.val {
      clock.val = target
      tree.frame(390.0, 200.0, now=clock.val) |> ignore
    }
    return
  }
  while clock.val + period < target - 0.001 {
    clock.val += period
    tree.frame(390.0, 200.0, now=clock.val) |> ignore
  }
  if target > clock.val {
    clock.val = target
    tree.frame(390.0, 200.0, now=clock.val) |> ignore
  }
}

///|
test "list_flip_engine: QuietDelta prepending offscreen row does not interrupt active FlipWay" {
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let keys = @signals.signal([10, 11, 12, 13, 14, 15], same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          comes=fn(_) { true },
          fn(slot, k) {
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("item-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)
    let y15_rest_before = flip_drawn_info(tree, "item-15").unwrap().0
    let y15_rest_after = y15_rest_before - 40.0

    // Start FlipWay via explicit transition appending tail row 16.
    clock.val = 60.0
    tree.event(60.0, fn() { transition(fn() { keys.set([10, 11, 12, 13, 14, 15, 16]) }) })
    flip_step_to(tree, clock, 110.0, period)
    let y15_at_110 = flip_drawn_info(tree, "item-15").unwrap().0
    assert_true(
      y15_at_110 > y15_rest_after + 5.0 && y15_at_110 < y15_rest_before - 1.0,
      msg="at \{fps}fps: expected item-15 mid-flight at t=110, got \{y15_at_110} (rest \{y15_rest_before} -> \{y15_rest_after})",
    )

    // Quietly prepend offscreen row 9 outside any transition (QuietDelta).
    clock.val = 110.0
    tree.event(110.0, fn() { keys.set([9, 10, 11, 12, 13, 14, 15, 16]) })
    flip_step_to(tree, clock, 126.0, period)
    let y15_at_126 = flip_drawn_info(tree, "item-15").unwrap().0

    // Must still be smoothly animating (not snapped to final resting position).
    assert_true(
      y15_at_126 > y15_rest_after + 2.0,
      msg="at \{fps}fps: QuietDelta snapped active FlipWay to rest at t=126: y15=\{y15_at_126}, rest=\{y15_rest_after}",
    )
    // Displacement between 110ms and 126ms must be continuous (moving up, no backward or instant jump).
    assert_true(
      y15_at_126 <= y15_at_110 + 0.5 && y15_at_110 - y15_at_126 < 20.0,
      msg="at \{fps}fps: discontinuous jump from t=110 (\{y15_at_110}) to t=126 (\{y15_at_126})",
    )

    // Advance past animation end: must settle accurately at final resting position.
    flip_step_to(tree, clock, 800.0, period)
    let y15_end = flip_drawn_info(tree, "item-15").unwrap().0
    let y16_end = flip_drawn_info(tree, "item-16").unwrap().0
    assert_true(
      (y15_end - y15_rest_after).abs() < 0.5,
      msg="at \{fps}fps: item-15 did not settle at \{y15_rest_after}, got \{y15_end}",
    )
    assert_true(
      (y16_end - (y15_rest_after + 40.0)).abs() < 0.5,
      msg="at \{fps}fps: item-16 did not settle at \{y15_rest_after + 40.0}, got \{y16_end}",
    )
    assert_true(!answer_marks_left(), msg="at \{fps}fps: marks left set")
    assert_true(!transition_now(), msg="at \{fps}fps: transition left active")
    tree.dispose()
  }
}

///|
test "list_flip_engine: QuietReset preserves zero sync layout at rest and clears FlipWay on disjoint replace" {
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let keys = @signals.signal([1, 2, 3, 4, 5, 6], same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          comes=fn(_) { true },
          fn(slot, k) {
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("row-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)

    // 1. Idle state quiet update: zero synchronous layout passes inside Tree::event.
    let passes_before = tree.passes_run()
    clock.val = 60.0
    tree.event(60.0, fn() { keys.set([0, 1, 2, 3, 4, 5, 6]) })
    let passes_in_event = tree.passes_run() - passes_before
    assert_eq(passes_in_event, 0, msg="at \{fps}fps: idle quiet update ran \{passes_in_event} sync passes")
    flip_step_to(tree, clock, 100.0, period)

    // 2. Start FlipWay via transition, then do a full disjoint replacement outside transition (QuietReset).
    clock.val = 100.0
    tree.event(100.0, fn() { transition(fn() { keys.set([0, 1, 2, 3, 4, 5, 6, 7]) }) })
    flip_step_to(tree, clock, 140.0, period)
    let passes_before_replace = tree.passes_run()
    clock.val = 140.0
    tree.event(140.0, fn() { keys.set([101, 102, 103, 104, 105, 106]) })
    let passes_in_replace = tree.passes_run() - passes_before_replace
    assert_eq(passes_in_replace, 0, msg="at \{fps}fps: disjoint QuietReset ran \{passes_in_replace} sync passes")
    flip_step_to(tree, clock, 140.0 + period, period)
    let y106_after = flip_drawn_info(tree, "row-106").unwrap().0
    assert_true(
      (y106_after - 160.0).abs() < 0.5,
      msg="at \{fps}fps: disjoint QuietReset did not settle immediately: y106=\{y106_after}",
    )
    assert_true(!answer_marks_left(), msg="at \{fps}fps: marks left set")
    assert_true(!transition_now(), msg="at \{fps}fps: transition left active")
    tree.dispose()
  }
}

///|
fn hold_room_height(k : Int) -> Double {
  match k {
    50 => 44.0
    51 => 70.0
    52 => 44.0
    53 => 20.0
    _ => 40.0
  }
}

///|
test "list_flip_engine: flips HoldRoomFade fades leaving tail row in place and keeps foot_room" {
  for delay in [100.0, 300.0, 1000.0] {
    for fps in [0.0, 7.0, 24.0, 60.0, 120.0] {
      let period = if fps <= 0.0 { 0.0 } else { 1000.0 / fps }
      let clock = Ref(0.0)
      let keys = @signals.signal([1, 2, 3, 4, 5, 6], same=fn(a, b) { a == b })
      let scroll = Scroll::list()
      let tree = Tree::new(time=fn() { clock.val }, fn(root) {
        root.transitions_only() |> ignore
        root.box(fn(p) {
          p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
          p.scrolls_window(
            scroll,
            fn() { keys.get() },
            est=40.0,
            flips=true,
            follows=fn() { true },
            comes=fn(_) { true },
            leaves_room=fn(k) { k == 50 },
            fn(slot, k) {
              slot.box(fn(b) {
                b.height(Is(Some(hold_room_height(k)))).words(Is("row-\{k}")) |> ignore
              })
              |> ignore
            },
          )
          |> ignore
        })
        |> ignore
      })
      tree.frame(390.0, 200.0, now=0.0) |> ignore
      flip_step_to(tree, clock, 60.0, period)

      // Add leaving tail row 50 inside transition.
      let line_at = 60.0
      clock.val = line_at
      tree.event(line_at, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6, 50]) }) })
      let gone_at = line_at + delay
      flip_step_to(tree, clock, gone_at, period)
      let mut prev_y6 = flip_drawn_info(tree, "row-6").unwrap().0

      // Remove row 50 inside transition with no replacement.
      clock.val = gone_at
      tree.event(gone_at, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6]) }) })

      // Check fade midpoint: row 50 must still be drawn with 0 < alpha < 1, and row 6 must never drop down.
      let mid_at = gone_at + list_leaves_ms / 2.0
      flip_step_to(tree, clock, mid_at, period)
      let ctx = "delay=\{delay}ms fps=\{fps}"
      let y6_mid = flip_drawn_info(tree, "row-6").unwrap().0
      assert_true(
        y6_mid <= prev_y6 + 0.5,
        msg="\{ctx}: row-6 dropped down at midpoint from \{prev_y6} to \{y6_mid}",
      )
      prev_y6 = y6_mid
      match flip_drawn_info(tree, "row-50") {
        Some((_, _, a)) =>
          assert_true(
            a > 0.0 && a < 1.0,
            msg="\{ctx}: expected row-50 alpha in (0, 1) at fade midpoint, got \{a}",
          )
        None => fail("\{ctx}: row-50 vanished immediately instead of fading out at midpoint")
      }

      // Advance past fade completion: row 50 gone (alpha 0 / not drawn), foot_room == 44, row 6 never dropped.
      let mut t = mid_at
      let end_at = gone_at + list_leaves_ms + 400.0
      while t < end_at {
        let next_t = if period <= 0.0 { end_at } else { dmin(end_at, t + dmax(period, 20.0)) }
        flip_step_to(tree, clock, next_t, period)
        let y6_now = flip_drawn_info(tree, "row-6").unwrap().0
        assert_true(
          y6_now <= prev_y6 + 0.5,
          msg="\{ctx} at t=\{next_t}: row-6 dropped down from \{prev_y6} to \{y6_now}",
        )
        prev_y6 = y6_now
        t = next_t
      }
      assert_true(
        flip_drawn_info(tree, "row-50") is None || flip_drawn_info(tree, "row-50").unwrap().2 == 0.0,
        msg="\{ctx}: row-50 still visible after fade ended",
      )
      let y6_end = flip_drawn_info(tree, "row-6").unwrap().0
      let room_left = 200.0 - (y6_end + 40.0)
      assert_true(
        (room_left - 44.0).abs() < 0.5,
        msg="\{ctx}: expected foot_room 44.0 at rest, got \{room_left} (y6=\{y6_end})",
      )
      assert_true(!answer_marks_left(), msg="\{ctx}: marks left set")
      assert_true(!transition_now(), msg="\{ctx}: transition left active")
      tree.dispose()
    }
  }
}

///|
test "list_flip_engine: flips HoldRoomFade mid-fade arrival removes fading row immediately and deducts foot_room" {
  for next_k in [51, 52, 53] {
    for fps in [0.0, 7.0, 24.0, 60.0, 120.0] {
      let period = if fps <= 0.0 { 0.0 } else { 1000.0 / fps }
      let clock = Ref(0.0)
      let keys = @signals.signal([1, 2, 3, 4, 5, 6], same=fn(a, b) { a == b })
      let scroll = Scroll::list()
      let tree = Tree::new(time=fn() { clock.val }, fn(root) {
        root.transitions_only() |> ignore
        root.box(fn(p) {
          p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
          p.scrolls_window(
            scroll,
            fn() { keys.get() },
            est=40.0,
            flips=true,
            follows=fn() { true },
            comes=fn(_) { true },
            leaves_room=fn(k) { k == 50 },
            fn(slot, k) {
              slot.box(fn(b) {
                b.height(Is(Some(hold_room_height(k)))).words(Is("row-\{k}")) |> ignore
              })
              |> ignore
            },
          )
          |> ignore
        })
        |> ignore
      })
      tree.frame(390.0, 200.0, now=0.0) |> ignore
      flip_step_to(tree, clock, 60.0, period)
      clock.val = 60.0
      tree.event(60.0, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6, 50]) }) })
      let gone_at = 500.0
      flip_step_to(tree, clock, gone_at, period)
      let mut prev_y6 = flip_drawn_info(tree, "row-6").unwrap().0

      // Start fade of row 50.
      clock.val = gone_at
      tree.event(gone_at, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6]) }) })

      // Mid-fade arrival of replacement row (taller 70, equal 44, or shorter 20).
      let arrive_at = gone_at + list_leaves_ms / 3.0
      flip_step_to(tree, clock, arrive_at, period)
      let ctx = "next_k=\{next_k} (h=\{hold_room_height(next_k)}) fps=\{fps}"
      let y6_pre = flip_drawn_info(tree, "row-6").unwrap().0
      assert_true(y6_pre <= prev_y6 + 0.5, msg="\{ctx}: row-6 dropped before arrival")
      prev_y6 = y6_pre

      clock.val = arrive_at
      tree.event(arrive_at, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6, next_k]) }) })
      let check_at = arrive_at + (if period <= 0.0 { 16.0 } else { period })
      flip_step_to(tree, clock, check_at, period)

      // Leaving row 50 must disappear immediately (never drawn alongside new row).
      assert_true(
        flip_drawn_info(tree, "row-50") is None || flip_drawn_info(tree, "row-50").unwrap().2 == 0.0,
        msg="\{ctx}: row-50 still visible alongside newly arrived row-\{next_k}",
      )

      // Walk to rest: row 6 must never drop down, and remaining foot_room must equal max(0, 44 - new_h).
      let mut t = check_at
      let end_at = arrive_at + 800.0
      while t < end_at {
        let next_t = if period <= 0.0 { end_at } else { dmin(end_at, t + dmax(period, 20.0)) }
        flip_step_to(tree, clock, next_t, period)
        let y6_now = flip_drawn_info(tree, "row-6").unwrap().0
        assert_true(
          y6_now <= prev_y6 + 0.5,
          msg="\{ctx} at t=\{next_t}: row-6 dropped down from \{prev_y6} to \{y6_now}",
        )
        prev_y6 = y6_now
        t = next_t
      }
      let y_new = flip_drawn_info(tree, "row-\{next_k}").unwrap().0
      let room_left = 200.0 - (y_new + hold_room_height(next_k))
      let want_room = dmax(0.0, 44.0 - hold_room_height(next_k))
      assert_true(
        (room_left - want_room).abs() < 0.5,
        msg="\{ctx}: expected remaining foot_room \{want_room}, got \{room_left}",
      )
      assert_true(!answer_marks_left(), msg="\{ctx}: marks left set")
      assert_true(!transition_now(), msg="\{ctx}: transition left active")
      tree.dispose()
    }
  }
}

///|
fn assert_no_row_overlap(tree : Tree, ctx : String) -> Unit raise {
  let rects : Array[(String, Double, Double)] = []
  for d in tree.drawn() {
    if d.words.has_prefix("item-") || d.words.has_prefix("row-") {
      rects.push((d.words, d.y, d.y + d.h))
    }
  }
  for i in 0..<rects.length() {
    for j in (i + 1)..<rects.length() {
      let (w1, top1, bot1) = rects[i]
      let (w2, top2, bot2) = rects[j]
      if top1 < bot2 - 1.0 && top2 < bot1 - 1.0 {
        fail("\{ctx}: overlapping rows \{w1} [\{top1}, \{bot1}] and \{w2} [\{top2}, \{bot2}]")
      }
    }
  }
}

///|
test "list_flip_engine: wheel scroll mid-FlipWay plus offscreen QuietDelta never overlaps rows" {
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let init_keys = Array::makei(20, fn(i) { i + 10 })
    let keys = @signals.signal(init_keys, same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          comes=fn(_) { true },
          fn(slot, k) {
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("item-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)

    // Start FlipWay via explicit transition appending tail row 30.
    let with_30 = init_keys.copy()
    with_30.push(30)
    clock.val = 60.0
    tree.event(60.0, fn() { transition(fn() { keys.set(with_30) }) })
    flip_step_to(tree, clock, 90.0, period)

    // Scroll up off foot mid-FlipWay.
    clock.val = 90.0
    tree.wheel_at(150.0, 100.0, 0.0, -240.0, 0, 90.0) |> ignore
    flip_step_to(tree, clock, 120.0, period)
    assert_no_row_overlap(tree, "at \{fps}fps after wheel")

    // Quietly prepend offscreen key 1 outside visible span while FlipWay is still active.
    let with_prepend = [1]
    with_prepend.append(with_30)
    clock.val = 120.0
    tree.event(120.0, fn() { keys.set(with_prepend) })

    // Step through remaining motion: zero row overlap at every frame.
    let mut t = 120.0
    while t < 700.0 {
      let next_t = dmin(700.0, t + dmax(period, 16.0))
      flip_step_to(tree, clock, next_t, period)
      assert_no_row_overlap(tree, "at \{fps}fps t=\{next_t}")
      t = next_t
    }
    assert_true(!answer_marks_left(), msg="at \{fps}fps: marks left set")
    assert_true(!transition_now(), msg="at \{fps}fps: transition left active")
    tree.dispose()
  }
}

///|
test "list_flip_engine: quiet insert inside visible span triggers QuietReset with no overlap" {
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let keys = @signals.signal([10, 11, 12, 13, 14, 15], same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          comes=fn(_) { true },
          fn(slot, k) {
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("item-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)

    // Start FlipWay via explicit transition appending tail row 16.
    clock.val = 60.0
    tree.event(60.0, fn() { transition(fn() { keys.set([10, 11, 12, 13, 14, 15, 16]) }) })
    flip_step_to(tree, clock, 110.0, period)

    // Quietly insert key 99 inside the visible span [11..16]: must QuietReset (zero sync pass, settled next frame, no overlap).
    let passes_before = tree.passes_run()
    clock.val = 110.0
    tree.event(110.0, fn() { keys.set([10, 11, 12, 13, 99, 14, 15, 16]) })
    let passes_in_event = tree.passes_run() - passes_before
    assert_eq(passes_in_event, 0, msg="at \{fps}fps: visible-span QuietReset ran \{passes_in_event} sync passes")
    flip_step_to(tree, clock, 110.0 + period, period)
    assert_no_row_overlap(tree, "at \{fps}fps after visible-span QuietReset")
    let y16 = flip_drawn_info(tree, "item-16").unwrap().0
    assert_true(
      (y16 - 160.0).abs() < 0.5,
      msg="at \{fps}fps: visible-span QuietReset did not settle item-16 at 160, got \{y16}",
    )
    assert_true(!answer_marks_left(), msg="at \{fps}fps: marks left set")
    assert_true(!transition_now(), msg="at \{fps}fps: transition left active")
    tree.dispose()
  }
}

///|
test "list_flip_engine: off-foot scroll before repaint plus tail insert has zero backward pullback" {
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let init_keys : Array[Int] = []
    for i in 10..<30 {
      init_keys.push(i)
    }
    let keys = @signals.signal(init_keys, same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          comes=fn(_) { true },
          fn(slot, k) {
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("item-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)

    // Scroll well above the foot and let it settle.
    clock.val = 60.0
    tree.wheel_at(150.0, 100.0, 0.0, -240.0, 0, 60.0) |> ignore
    flip_step_to(tree, clock, 120.0, period)
    // Pick a currently visible row near the middle of the viewport.
    let mut track_label = ""
    let mut y_before = 0.0
    for d in tree.drawn() {
      if d.words.has_prefix("item-") && d.y >= 40.0 && d.y <= 120.0 {
        track_label = d.words
        y_before = d.y
        break
      }
    }
    assert_true(track_label != "", msg="at \{fps}fps: no visible row found off-foot")

    // In the same event tick before the next repaint:
    // 1. Scroll further up (changing scroll_off_now ahead of scroll_shown),
    // 2. Append a new tail row via transition.
    let next_t = clock.val + period
    clock.val = next_t
    tree.wheel_at(150.0, 100.0, 0.0, -24.0, 0, next_t) |> ignore
    let with_30 = init_keys.copy()
    with_30.push(30)
    tree.event(next_t, fn() { transition(fn() { keys.set(with_30) }) })

    // Paint the frame at next_t and subsequent frames through 700ms:
    // the tracked row must immediately reflect the +24pt user scroll with zero backward pullback or jump.
    tree.frame(390.0, 200.0, now=next_t) |> ignore
    let y_first = flip_drawn_info(tree, track_label).unwrap().0
    let expected = y_before + 24.0
    assert_true(
      (y_first - expected).abs() < 1.0,
      msg="at \{fps}fps: \{track_label} pulled back on first frame after off-foot scroll+insert: got \{y_first}, expected \{expected} (before=\{y_before})",
    )
    let mut prev_y = y_first
    let mut t = next_t
    while t < 700.0 {
      let step_t = dmin(700.0, t + dmax(period, 16.0))
      flip_step_to(tree, clock, step_t, period)
      let cur_y = flip_drawn_info(tree, track_label).unwrap().0
      assert_true(
        (cur_y - expected).abs() < 1.0,
        msg="at \{fps}fps t=\{step_t}: \{track_label} drifted to \{cur_y}, expected \{expected}",
      )
      assert_true(
        (cur_y - prev_y).abs() < 1.0,
        msg="at \{fps}fps t=\{step_t}: \{track_label} jumped from \{prev_y} to \{cur_y}",
      )
      prev_y = cur_y
      t = step_t
    }
    assert_true(!answer_marks_left(), msg="at \{fps}fps: marks left set")
    assert_true(!transition_now(), msg="at \{fps}fps: transition left active")
    tree.dispose()
  }
}
