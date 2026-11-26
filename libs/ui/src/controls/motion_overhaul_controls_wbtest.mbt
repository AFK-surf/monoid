// Adversarial tests for Wave 1 controls (seg_fill_node, seg_node, tabs_node(Pill), switch_node):
// 1. Slow click (300ms hold on unselected option, release in place -> commits with 0 lens).
// 2. Press unselected and drag away -> thumb never moves, 0 lens, 0 commit.
// 3. Option list mutation during hold (same-length reorder & add/remove) -> silent cancel, 0 commit.
// 4. Axis lock & Up-only on selected option (vertical lock ignores later horizontal Up; vertical Up-only 0 commit;
//    horizontal Up-only commits by Up.x; Off always 0 commit).
// 5. Sync unmount, shown=false hide-without-destroy, default & shared SegThumb sync rejection.
// 6. Mid-lens toggle of reduced_motion / glass_solid -> Up/Off -> restore -> 0 glass & assert_idle.
// 7. Bare async Segmented tap (200ms delayed chosen.set) -> thumb stays still until confirmed, then slides monotonically.
// 8. Mouse & touch short-tap #8553 sync reject & redirect across seg_fill_node and tabs_node(Pill).
// 9. tabs_node(Pill) manual keyboard mode and Underline-only cover_indicator.

///|
let ctrl_frame_ms : Double = 16.0

///|
let ctrl_two_frames_ms : Double = 32.0

///|
let ctrl_short_hold_ms : Double = 40.0

///|
let ctrl_drag_hold_ms : Double = 60.0

///|
let ctrl_over_hold_ms : Double = 220.0

///|
let ctrl_slow_click_ms : Double = 300.0

///|
test "Segmented mouse slow click (300ms) commits with 0 lens; drag-away from unselected cancels with 0 commit" {
  let chosen = @signals.signal(0)
  let commits : Array[Int] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(
          page,
          fn() { ["A", "B", "C"] },
          fn() { chosen.get() },
          fn(k) {
            commits.push(k)
            chosen.set(k)
          },
          said="SlowClick",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let rb = t.get(Radio, label="B").rect
  let rc = t.get(Radio, label="C").rect
  // 1. Slow click (300ms) on unselected "B" -> 0 lens, commits 1 on release.
  t.press_at(rb.0 + rb.2 / 2.0, rb.1 + rb.3 / 2.0)
  t.run_for(ctrl_slow_click_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="300ms hold on unselected must keep 0 glass")
  t.release(rb.0 + rb.2 / 2.0, rb.1 + rb.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1)
  assert_eq(commits, [1])
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()
  // 2. Press unselected "C" and drag away outside -> 0 lens, 0 commit.
  t.press_at(rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.run_for(ctrl_drag_hold_ms)
  t.move_to(rc.0 + rc.2 / 2.0, rc.1 + 80.0)
  t.run_for(ctrl_short_hold_ms)
  assert_eq(t.drawn_glass().length(), 0)
  t.release(rc.0 + rc.2 / 2.0, rc.1 + 80.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1, msg="drag-away from unselected must not change chosen")
  assert_eq(commits, [1], msg="drag-away from unselected must not call choose")
  t.assert_idle()
  set_dark(None)
}

///|
test "Segmented option mutation during hold (same-length reorder & resize) silently cancels with 0 commit" {
  let labels = @signals.signal(["One", "Two", "Three"])
  let chosen = @signals.signal(0)
  let commits : Array[Int] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_node(
          page,
          fn() { labels.get() },
          fn() { chosen.get() },
          fn(k) {
            commits.push(k)
            chosen.set(k)
          },
          said="Mutate",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r2 = t.get(Radio, label="Two").rect
  // Same-length reorder while holding unselected "Two" -> 0 commit
  t.press_at(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
  t.run_for(ctrl_short_hold_ms)
  labels.set(["One", "Three", "Two"])
  t.draw()
  t.release(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits, [], msg="same-length reorder during hold must cancel with 0 commit")
  // Length change while holding selected "One" -> 0 commit
  let r0 = t.get(Radio, label="One").rect
  t.press_at(r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0)
  t.run_for(ctrl_over_hold_ms)
  labels.set(["One", "Three"])
  t.draw()
  t.release(r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits, [], msg="resize during hold must cancel with 0 commit")
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()
  set_dark(None)
}

///|
test "Segmented selected-item axis lock: vertical lock ignores later horizontal Up; Off always 0 commit" {
  let chosen = @signals.signal(0)
  let commits : Array[Int] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(
          page,
          fn() { ["Alpha", "Beta", "Gamma"] },
          fn() { chosen.get() },
          fn(k) {
            commits.push(k)
            chosen.set(k)
          },
          said="AxisLock",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r0 = t.get(Radio, label="Alpha").rect
  let r2 = t.get(Radio, label="Gamma").rect
  let c0x = r0.0 + r0.2 / 2.0
  let c0y = r0.1 + r0.3 / 2.0
  let c2x = r2.0 + r2.2 / 2.0
  // 1. Vertical drag first (locks vertical), then swing horizontally to Gamma and release -> 0 commit
  t.press_at(c0x, c0y)
  t.move_to(c0x, c0y + 24.0)
  t.run_for(ctrl_frame_ms)
  t.move_to(c2x, c0y + 24.0)
  t.run_for(ctrl_frame_ms)
  t.release(c2x, c0y + 24.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits, [], msg="vertical-locked drag ending over Gamma must commit 0")
  assert_eq(chosen.get(), 0)
  assert_eq(t.drawn_glass().length(), 0)
  // 2. Horizontal touch drag from Alpha to Gamma, then touch cancel (Off) -> 0 commit and 0 glass
  t.touch(0, c0x, c0y)
  t.touch(1, c2x, c0y)
  t.run_for(ctrl_two_frames_ms)
  t.touch(3, c2x, c0y)
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(commits, [], msg="Off must always commit 0")
  assert_eq(chosen.get(), 0)
  assert_eq(t.drawn_glass().length(), 0)
  // 3. No-Moved vertical Up-only over slop inside item (Mouse on selected) -> 0 commit
  let dy_in = 10.0
  assert_true(dy_in > @ui.touch_slop() && dy_in < r0.3 / 2.0, msg="vertical Up-only offset must exceed slop while staying inside item")
  t.press_at(c0x, c0y)
  t.release(c0x, c0y + dy_in)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits, [], msg="mouse vertical Up-only on selected must commit 0")
  // 4. No-Moved horizontal Up-only over slop (Mouse on selected) -> commits 1x by Up.x
  t.press_at(c0x, c0y)
  t.release(c2x, c0y)
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(commits, [2], msg="mouse horizontal Up-only on selected must commit by Up.x")
  assert_eq(chosen.get(), 2)
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()
  // 5. Finger-mode no-Moved vertical Up-only over slop INSIDE unselected item -> 0 commit; horizontal Up-only -> commits 1x
  let f_chosen = @signals.signal(0)
  let f_commits : Array[Int] = []
  let tf = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Finger, native=Finger)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(
          page,
          fn() { ["Alpha", "Beta", "Gamma"] },
          fn() { f_chosen.get() },
          fn(k) {
            f_commits.push(k)
            f_chosen.set(k)
          },
          said="AxisSegFinger",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tf.draw()
  let fr0 = tf.get(Radio, label="Alpha").rect
  let fr1 = tf.get(Radio, label="Beta").rect
  let fr2 = tf.get(Radio, label="Gamma").rect
  let fc1x = fr1.0 + fr1.2 / 2.0
  let fc1y = fr1.1 + fr1.3 / 2.0
  assert_true(dy_in > @ui.touch_slop() && dy_in < fr1.3 / 2.0, msg="finger vertical Up-only offset must exceed slop while staying inside item")
  tf.touch(0, fc1x, fc1y)
  tf.touch(2, fc1x, fc1y + dy_in)
  tf.run_for(@ui.move_most_ms)
  assert_eq(f_commits, [], msg="finger vertical Up-only over slop inside unselected item must commit 0")
  assert_eq(f_chosen.get(), 0)
  tf.touch(0, fr0.0 + fr0.2 / 2.0, fc1y)
  tf.touch(2, fr2.0 + fr2.2 / 2.0, fc1y)
  tf.run_for(2.0 * @ui.move_most_ms)
  assert_eq(f_commits, [2], msg="finger horizontal Up-only must commit by Up.x")
  assert_eq(f_chosen.get(), 2)
  assert_eq(tf.drawn_glass().length(), 0)
  tf.assert_idle()
  set_dark(None)
}

///|
test "Segmented hide-without-destroy (shown=false), mid-lens unmount, default reject, and shared SegThumb A/B isolation" {
  // 1. Real shown=false hide-without-destroy on liquid_segmented_node while holding lens -> drops lens & idle
  let vis = @signals.signal(true)
  let chosen_vis = @signals.signal(0)
  let tv = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { ["X", "Y"] },
          fn() { chosen_vis.get() },
          fn(k) { chosen_vis.set(k) },
          width=260.0,
          height=32.0,
          shown=fn() { vis.get() },
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tv.draw()
  let rx = tv.get(Tab, label="X").rect
  tv.press_at(rx.0 + rx.2 / 2.0, rx.1 + rx.3 / 2.0)
  tv.run_for(ctrl_over_hold_ms + part_whole_ms)
  assert_eq(tv.drawn_glass().length(), 1, msg="holding selected X must lift lens")
  vis.set(false)
  tv.draw()
  tv.run_for(2.0 * @ui.move_most_ms)
  assert_eq(tv.drawn_glass().length(), 0, msg="shown=false mid-lens must clear lens")
  tv.assert_idle()

  // 2. Default (non-shared) SegThumb sync reject + mid-lens callback unmount (mode=2)
  let chosen_def = @signals.signal(0)
  let mounted = @signals.signal(true)
  let unmount_on_cb = @signals.signal(false)
  let td = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        page.show(fn() { mounted.get() }, at_once=true, fn(wrap) {
          seg_fill_node(
            wrap,
            fn() { ["D0", "D1"] },
            fn() { chosen_def.get() },
            fn(_k) {
              if unmount_on_cb.get() {
                mounted.set(false)
              }
            },
            said="DefaultSeg",
          )
          |> ignore
        })
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  td.draw()
  let rd0 = td.get(Radio, label="D0").rect
  let rd1 = td.get(Radio, label="D1").rect
  let rd0_cx = rd0.0 + rd0.2 / 2.0
  td.tap(rd1.0 + rd1.2 / 2.0, rd1.1 + rd1.3 / 2.0)
  for _ in 0..<8 {
    td.run_for(ctrl_frame_ms)
    let lifted = @ui.tree_theme().lifted
    let pills = td.drawn_rects().filter(fn(r) { r.4 == lifted && (r.1 - rd0.1).abs() < 8.0 && r.2 > 40.0 })
    assert_true(pills.length() >= 1, msg="default SegThumb sync reject must keep solid thumb visible")
    let cx = pills[0].0 + pills[0].2 / 2.0
    assert_true((cx - rd0_cx).abs() < 3.0, msg="default SegThumb sync reject must keep thumb centered at D0 (\{rd0_cx}), got \{cx}")
  }
  td.run_for(@ui.move_most_ms)
  assert_eq(chosen_def.get(), 0, msg="default SegThumb sync reject must keep 0")
  assert_eq(td.drawn_glass().length(), 0)
  // Mid-lens drag release triggers sync unmount -> must settle cleanly with 0 glass & idle
  unmount_on_cb.set(true)
  td.press_at(rd0.0 + rd0.2 / 2.0, rd0.1 + rd0.3 / 2.0)
  td.run_for(ctrl_over_hold_ms + part_whole_ms)
  assert_eq(td.drawn_glass().length(), 1)
  td.move_to(rd1.0 + rd1.2 / 2.0, rd1.1 + rd1.3 / 2.0)
  td.release(rd1.0 + rd1.2 / 2.0, rd1.1 + rd1.3 / 2.0)
  td.run_for(2.0 * @ui.move_most_ms)
  assert_eq(td.drawn_glass().length(), 0, msg="callback unmount mid-lens must leave 0 glass")
  td.assert_idle()

  // 3. Shared SegThumb A/B isolation: different option counts & selected values;
  //    while B drags to index 3 and holds, A updates selected & labels length AND unmounts -> B 100% untouched!
  let show_a = @signals.signal(true)
  let labels_a = @signals.signal(["A0", "A1", "A2"])
  let chosen_a = @signals.signal(0)
  let chosen_b = @signals.signal(2)
  let tab = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared = SegThumb::new(page, fn() { chosen_b.get() })
        page.show(fn() { show_a.get() }, at_once=true, fn(sa) {
          seg_fill_node(sa, fn() { labels_a.get() }, fn() { chosen_a.get() }, fn(k) { chosen_a.set(k) }, said="GroupA", thumb=shared)
          |> ignore
        })
        page.box(fn(sb) {
          seg_fill_node(sb, fn() { ["B0", "B1", "B2", "B3"] }, fn() { chosen_b.get() }, fn(k) { chosen_b.set(k) }, said="GroupB", thumb=shared)
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tab.draw()
  let rb2 = tab.get(Radio, label="B2").rect
  let rb3 = tab.get(Radio, label="B3").rect
  let rb3_cx = rb3.0 + rb3.2 / 2.0
  // Start dragging B from B2 to B3 and hold until settled at B3 (lens active on B)
  tab.press_at(rb2.0 + rb2.2 / 2.0, rb2.1 + rb2.3 / 2.0)
  tab.run_for(ctrl_over_hold_ms + part_whole_ms)
  tab.move_to(rb3_cx, rb3.1 + rb3.3 / 2.0)
  tab.run_for(@ui.move_most_ms)
  assert_eq(tab.drawn_glass().length(), 1, msg="B must hold active lens before A changes")
  let lens_b_before = tab.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lens_b_before.length(), 1)
  // Mutate A's selected AND shrink A's labels length while B is actively dragging at index 3
  chosen_a.set(1)
  labels_a.set(["A0", "A1"])
  for _ in 0..<4 {
    tab.run_for(ctrl_frame_ms)
    let lb = tab.drawn_instances().filter(fn(i) { i[5] == 6.0 })
    assert_eq(lb.length(), 1, msg="A selected/labels update must NOT drop B's active lens")
    let cx = lb[0][0] + lb[0][2] / 2.0
    assert_true((cx - rb3_cx).abs() < 12.0, msg="A selected/labels update must NOT pull B's lens away from B3 (\{rb3_cx}), got \{cx}")
  }
  // Unmount A while B is still actively dragging -> B's lens and position must stay completely intact!
  show_a.set(false)
  for _ in 0..<4 {
    tab.run_for(ctrl_frame_ms)
    let lb = tab.drawn_instances().filter(fn(i) { i[5] == 6.0 })
    assert_eq(lb.length(), 1, msg="unmounting unrelated GroupA must NOT drop GroupB's active lens")
    let cx = lb[0][0] + lb[0][2] / 2.0
    assert_true((cx - rb3_cx).abs() < 12.0, msg="unmounting A must NOT pull B's lens away from B3 (\{rb3_cx}), got \{cx}")
  }
  tab.release(rb3_cx, rb3.1 + rb3.3 / 2.0)
  tab.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chosen_b.get(), 3, msg="GroupB drag release after GroupA update+unmount must still commit 3")
  assert_eq(tab.drawn_glass().length(), 0)
  tab.assert_idle()

  // 4. Shared SegThumb A/B isolation under reduced_motion=true and glass_solid=true (no-lens drag path):
  //    while B drags B2->B3 with 0 glass, A updates selected 0->1, shrinks labels, unmounts, AND a new 2-item A_new mounts ->
  //    B's solid capsule stays at B3 every frame and release commits 3.
  for use_solid in [false, true] {
    let show_a2 = @signals.signal(true)
    let show_a_new = @signals.signal(false)
    let labels_a2 = @signals.signal(["A0", "A1", "A2"])
    let chosen_a2 = @signals.signal(0)
    let chosen_b2 = @signals.signal(2)
    let tab2 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=280.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
    if use_solid {
      @ui.set_glass_solid(Some(true))
    } else {
      tab2.set_reduce_motion(true)
    }
    @ui.set_view_app(
      fn(root) {
        root.box(fn(page) {
          page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
          let shared2 = SegThumb::new(page, fn() { chosen_b2.get() })
          page.show(fn() { show_a2.get() }, at_once=true, fn(sa) {
            seg_fill_node(sa, fn() { labels_a2.get() }, fn() { chosen_a2.get() }, fn(k) { chosen_a2.set(k) }, said="GroupA2", thumb=shared2)
            |> ignore
          })
          page.show(fn() { show_a_new.get() }, at_once=true, fn(san) {
            seg_fill_node(san, fn() { ["N0", "N1"] }, fn() { 0 }, fn(_k) { () }, said="GroupANew", thumb=shared2)
            |> ignore
          })
          page.box(fn(sb) {
            seg_fill_node(sb, fn() { ["B0", "B1", "B2", "B3"] }, fn() { chosen_b2.get() }, fn(k) { chosen_b2.set(k) }, said="GroupB2", thumb=shared2)
            |> ignore
          })
          |> ignore
        })
        |> ignore
      },
      theme=ui_theme_now,
    )
    tab2.draw()
    let rb2_2 = tab2.get(Radio, label="B2").rect
    let rb3_2 = tab2.get(Radio, label="B3").rect
    let rb3_2_cx = rb3_2.0 + rb3_2.2 / 2.0
    let b_thumb_cx = fn() raise {
      if use_solid {
        let cur_rb3 = tab2.get(Radio, label="B3").rect
        let lifted = @ui.tree_theme().lifted
        let pills = tab2.drawn_rects().filter(fn(r) { r.4 == lifted && (r.1 - cur_rb3.1).abs() < 8.0 && r.2 > 20.0 })
        assert_true(pills.length() >= 1, msg="solid=\{use_solid} GroupB solid capsule must stay visible")
        pills[0].0 + pills[0].2 / 2.0
      } else {
        let lenses = tab2.drawn_instances().filter(fn(i) { i[5] == 6.0 })
        assert_eq(lenses.length(), 1, msg="reduced_motion GroupB must keep 1 clear lens during drag")
        lenses[0][0] + lenses[0][2] / 2.0
      }
    }
    let expected_drag_glass = if use_solid { 0 } else { 1 }
    tab2.press_at(rb2_2.0 + rb2_2.2 / 2.0, rb2_2.1 + rb2_2.3 / 2.0)
    tab2.run_for(ctrl_over_hold_ms + part_whole_ms)
    tab2.move_to(rb3_2_cx, rb3_2.1 + rb3_2.3 / 2.0)
    tab2.run_for(@ui.move_most_ms)
    assert_eq(tab2.drawn_glass().length(), expected_drag_glass, msg="solid=\{use_solid} drag glass count")
    assert_true((b_thumb_cx() - rb3_2_cx).abs() < 12.0, msg="solid=\{use_solid} B thumb must be at B3 before A mutates")
    chosen_a2.set(1)
    labels_a2.set(["A0", "A1"])
    for _ in 0..<4 {
      tab2.run_for(ctrl_frame_ms)
      assert_eq(tab2.drawn_glass().length(), expected_drag_glass, msg="solid=\{use_solid} glass count while A mutates")
      let cx = b_thumb_cx()
      assert_true((cx - rb3_2_cx).abs() < 12.0, msg="solid=\{use_solid} A update must NOT pull B thumb away from B3 (\{rb3_2_cx}), got \{cx}")
    }
    show_a2.set(false)
    for _ in 0..<4 {
      tab2.run_for(ctrl_frame_ms)
      assert_eq(tab2.drawn_glass().length(), expected_drag_glass, msg="solid=\{use_solid} glass count while A unmounts")
      let cx = b_thumb_cx()
      assert_true((cx - rb3_2_cx).abs() < 12.0, msg="solid=\{use_solid} A unmount must NOT pull B thumb away from B3 (\{rb3_2_cx}), got \{cx}")
    }
    // Mount a brand-new 2-item GroupA_new while B is actively dragging at index 3 -> must NOT overwrite bounds or target!
    show_a_new.set(true)
    for _ in 0..<4 {
      tab2.run_for(ctrl_frame_ms)
      assert_eq(tab2.drawn_glass().length(), expected_drag_glass, msg="solid=\{use_solid} glass count when A_new mounts")
      let cx = b_thumb_cx()
      assert_true((cx - rb3_2_cx).abs() < 12.0, msg="solid=\{use_solid} mounting A_new must NOT pull B thumb away from B3 (\{rb3_2_cx}), got \{cx}")
    }
    let cur_rb3_end = tab2.get(Radio, label="B3").rect
    tab2.release(rb3_2_cx, cur_rb3_end.1 + cur_rb3_end.3 / 2.0)
    tab2.run_for(2.0 * @ui.move_most_ms)
    assert_eq(chosen_b2.get(), 3, msg="solid=\{use_solid} GroupB release after GroupA update+unmount+mount must commit 3")
    let lifted_after = @ui.tree_theme().lifted
    let pills_after = tab2.drawn_rects().filter(fn(r) { r.4 == lifted_after && (r.1 - cur_rb3_end.1).abs() < 8.0 && r.2 > 20.0 })
    assert_true(pills_after.length() >= 1, msg="solid=\{use_solid} GroupB solid capsule must be visible after release")
    let cx_after_rel = pills_after[0].0 + pills_after[0].2 / 2.0
    assert_true((cx_after_rel - rb3_2_cx).abs() < 3.0, msg="solid=\{use_solid} GroupA_new must NOT steal dd after GroupB release: got \{cx_after_rel} vs \{rb3_2_cx}")
    assert_eq(tab2.drawn_glass().length(), 0)
    tab2.assert_idle()
    @ui.set_glass_solid(None)
    tab2.set_reduce_motion(false)
  }

  // 5. Shared SegThumb: clicking unselected item in GroupA whose on_select synchronously sets shown_a=false
  //    (hiding A while keeping node alive) must release gest_owner so external chosen_b.set(3) slides B's capsule to B3.
  let shown_ah = @signals.signal(true)
  let chosen_ah = @signals.signal(0)
  let chosen_bh = @signals.signal(0)
  let tah = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared_h = @glass.DampedDrag::new(0.0, lo=0.0, hi=3.0, held_scale=@glass.ctrl_seg_held_scale)
        @glass.liquid_segmented_node(
          page,
          fn() { ["H0", "H1"] },
          fn() { chosen_ah.get() },
          fn(k) {
            chosen_ah.set(k)
            shown_ah.set(false)
          },
          width=260.0,
          height=32.0,
          drag=shared_h,
          shown=fn() { shown_ah.get() },
          glass_track=false,
        )
        |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { ["K0", "K1", "K2", "K3"] },
          fn() { chosen_bh.get() },
          fn(k) { chosen_bh.set(k) },
          width=320.0,
          height=32.0,
          drag=shared_h,
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tah.draw()
  let rh1 = tah.get(Tab, label="H1").rect
  tah.tap(rh1.0 + rh1.2 / 2.0, rh1.1 + rh1.3 / 2.0)
  tah.draw()
  // Without touching B, externally update chosen_bh -> 3: B's solid capsule must slide to K3!
  chosen_bh.set(3)
  tah.run_for(2.0 * @ui.move_most_ms)
  let rk3 = tah.get(Tab, label="K3").rect
  let rk3_cx = rk3.0 + rk3.2 / 2.0
  let lifted_h = @ui.tree_theme().lifted
  let pills_h = tah.drawn_rects().filter(fn(r) { r.4 == lifted_h && (r.1 - rk3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h.length() >= 1, msg="GroupB solid capsule must be visible after GroupA sync hide")
  let cx_h = pills_h[0].0 + pills_h[0].2 / 2.0
  assert_true((cx_h - rk3_cx).abs() < 3.0, msg="GroupB capsule must land on K3 (\{rk3_cx}) after GroupA sync hide, got \{cx_h}")
  tah.assert_idle()

  // 6. Shared SegThumb: while GroupA holds H1, external chosen_bh.set(3) arrives on GroupB;
  //    once GroupA releases H1 and synchronously hides (shown_ah=false), GroupB immediately replays deferred sync to K3.
  let shown_ah2 = @signals.signal(true)
  let chosen_ah2 = @signals.signal(0)
  let chosen_bh2 = @signals.signal(0)
  let tah2 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared_h2 = @glass.DampedDrag::new(0.0, lo=0.0, hi=3.0, held_scale=@glass.ctrl_seg_held_scale)
        @glass.liquid_segmented_node(
          page,
          fn() { ["H0", "H1"] },
          fn() { chosen_ah2.get() },
          fn(k) {
            chosen_ah2.set(k)
            shown_ah2.set(false)
          },
          width=260.0,
          height=32.0,
          drag=shared_h2,
          shown=fn() { shown_ah2.get() },
          glass_track=false,
        )
        |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { ["K0", "K1", "K2", "K3"] },
          fn() { chosen_bh2.get() },
          fn(k) { chosen_bh2.set(k) },
          width=320.0,
          height=32.0,
          drag=shared_h2,
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tah2.draw()
  let rh1_2 = tah2.get(Tab, label="H1").rect
  tah2.press_at(rh1_2.0 + rh1_2.2 / 2.0, rh1_2.1 + rh1_2.3 / 2.0)
  tah2.run_for(ctrl_frame_ms)
  // While A holds H1, B receives external selection update to 3:
  chosen_bh2.set(3)
  tah2.draw()
  // Release H1 -> A commits H1 & synchronously hides -> B must replay deferred sync and land on K3!
  tah2.release(rh1_2.0 + rh1_2.2 / 2.0, rh1_2.1 + rh1_2.3 / 2.0)
  tah2.run_for(2.0 * @ui.move_most_ms)
  let rk3_2 = tah2.get(Tab, label="K3").rect
  let rk3_2_cx = rk3_2.0 + rk3_2.2 / 2.0
  let lifted_h2 = @ui.tree_theme().lifted
  let pills_h2 = tah2.drawn_rects().filter(fn(r) { r.4 == lifted_h2 && (r.1 - rk3_2.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h2.length() >= 1, msg="GroupB solid capsule must be visible after deferred sync replay")
  let cx_h2 = pills_h2[0].0 + pills_h2[0].2 / 2.0
  assert_true((cx_h2 - rk3_2_cx).abs() < 3.0, msg="GroupB capsule must replay deferred sync to K3 (\{rk3_2_cx}) after GroupA release+hide, got \{cx_h2}")
  tah2.assert_idle()

  // 7. Shared SegThumb: GroupB starts hidden (shown_b=false, alive); while GroupA holds H1, external chosen_b.set(3)
  //    arrives -> GroupA releases H1 and hides (shown_a=false) -> draw 1 frame -> GroupB becomes shown_b=true ->
  //    GroupB replays deferred sync on shown=true and lands on K3.
  let shown_ah3 = @signals.signal(true)
  let shown_bh3 = @signals.signal(false)
  let chosen_ah3 = @signals.signal(0)
  let chosen_bh3 = @signals.signal(0)
  let tah3 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared_h3 = @glass.DampedDrag::new(0.0, lo=0.0, hi=3.0, held_scale=@glass.ctrl_seg_held_scale)
        @glass.liquid_segmented_node(
          page,
          fn() { ["H0", "H1"] },
          fn() { chosen_ah3.get() },
          fn(k) {
            chosen_ah3.set(k)
            shown_ah3.set(false)
          },
          width=260.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_ah3.get() },
          glass_track=false,
        )
        |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { ["K0", "K1", "K2", "K3"] },
          fn() { chosen_bh3.get() },
          fn(k) { chosen_bh3.set(k) },
          width=320.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_bh3.get() },
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tah3.draw()
  let rh1_3 = tah3.get(Tab, label="H1").rect
  tah3.press_at(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.run_for(ctrl_frame_ms)
  chosen_bh3.set(3)
  tah3.draw()
  tah3.release(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.draw()
  // Reveal GroupB AFTER GroupA already relinquished ownership:
  shown_bh3.set(true)
  tah3.run_for(2.0 * @ui.move_most_ms)
  let rk3_3 = tah3.get(Tab, label="K3").rect
  let rk3_3_cx = rk3_3.0 + rk3_3.2 / 2.0
  let lifted_h3 = @ui.tree_theme().lifted
  let pills_h3 = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3.length() >= 1, msg="GroupB solid capsule must be visible after becoming shown=true")
  let cx_h3 = pills_h3[0].0 + pills_h3[0].2 / 2.0
  assert_true((cx_h3 - rk3_3_cx).abs() < 3.0, msg="GroupB capsule must replay deferred sync to K3 (\{rk3_3_cx}) on shown=true, got \{cx_h3}")
  tah3.assert_idle()
  // While GroupA is hidden (shown_ah3=false) but still alive, externally changing GroupA's selected back to H0
  // must NOT hijack shared dd or pull GroupB's capsule away from K3!
  chosen_ah3.set(0)
  tah3.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chosen_bh3.get(), 3, msg="GroupB selected must remain 3 after hidden GroupA updates")
  let pills_h3_after = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3_after.length() >= 1, msg="GroupB solid capsule must stay visible after hidden GroupA updates")
  let cx_h3_after = pills_h3_after[0].0 + pills_h3_after[0].2 / 2.0
  assert_true((cx_h3_after - rk3_3_cx).abs() < 3.0, msg="hidden GroupA selected update must NOT pull GroupB capsule away from K3 (\{rk3_3_cx}), got \{cx_h3_after}")
  tah3.assert_idle()
  // Round-trip B -> A -> B with no change to B's selection while hidden: B must immediately snap back to K3!
  shown_bh3.set(false)
  tah3.draw()
  shown_ah3.set(true)
  tah3.draw()
  tah3.assert_idle()
  shown_ah3.set(false)
  tah3.draw()
  shown_bh3.set(true)
  tah3.draw()
  assert_eq(chosen_bh3.get(), 3)
  let pills_rt = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_rt.length() >= 1, msg="GroupB solid capsule must be visible immediately on round-trip restore")
  let cx_rt = pills_rt[0].0 + pills_rt[0].2 / 2.0
  assert_true((cx_rt - rk3_3_cx).abs() < 3.0, msg="B shown again (frame 0, 0-motion): capsule=\{cx_rt}, K3=\{rk3_3_cx}")
  tah3.assert_idle()
  // Same-batch round-trip where receiver (shown_bh3=true) is notified BEFORE releasing host (shown_ah3=false):
  shown_bh3.set(false)
  tah3.draw()
  shown_ah3.set(true)
  tah3.draw()
  tah3.assert_idle()
  @signals.start_batch()
  shown_bh3.set(true)
  shown_ah3.set(false)
  @signals.end_batch()
  tah3.draw()
  assert_eq(chosen_bh3.get(), 3)
  let pills_rt_batch = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_rt_batch.length() >= 1, msg="GroupB solid capsule must be visible immediately on same-batch receiver-first restore")
  let cx_rt_batch = pills_rt_batch[0].0 + pills_rt_batch[0].2 / 2.0
  assert_true((cx_rt_batch - rk3_3_cx).abs() < 3.0, msg="same-batch receiver-first restore (frame 0, 0-motion): capsule=\{cx_rt_batch}, K3=\{rk3_3_cx}")
  tah3.assert_idle()

  // 8. Real seg_fill_node narrow-menu -> select in menu -> widen back to segmented:
  //    frame 0 on restore must already sit on the new option with zero slide animation and assert_idle().
  let chosen_mw = @signals.signal(0)
  let room_w = @signals.signal(420.0)
  let tmw = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.width(By(fn() { Some(room_w.get()) })).height(Is(Some(160.0))).padding(Is((12.0, 12.0, 12.0, 12.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(page, fn() { ["Standard", "Balanced", "Maximum"] }, fn() { chosen_mw.get() }, fn(k) { chosen_mw.set(k) }, said="MenuRestore")
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tmw.draw()
  // Shrink into narrow menu mode (seg hidden, menu shown) -> update chosen to 2 -> widen back to segmented.
  room_w.set(120.0)
  tmw.draw()
  assert_true(tmw.find("Maximum") is None && tmw.find("Balanced") is None && tmw.find("Standard") is Some(_), msg="narrow room_w=120 must switch seg_fill_node into menu mode (hiding unselected Radio labels)")
  chosen_mw.set(2)
  tmw.draw()
  room_w.set(420.0)
  tmw.draw()
  let rmax = tmw.get(Radio, label="Maximum").rect
  let rmax_cx = rmax.0 + rmax.2 / 2.0
  let lifted_mw = @ui.tree_theme().lifted
  let mw_pills0 = tmw.drawn_rects().filter(fn(r) { r.4 == lifted_mw && (r.1 - rmax.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(mw_pills0.length() >= 1, msg="seg_fill_node restore frame 0 must draw solid capsule")
  let mw_cx0 = mw_pills0[0].0 + mw_pills0[0].2 / 2.0
  assert_true((mw_cx0 - rmax_cx).abs() < 3.0, msg="seg_fill_node restore frame 0 must sit on Maximum (\{rmax_cx}) with 0 animation, got \{mw_cx0}")
  tmw.assert_idle()
  for _ in 0..<4 {
    tmw.run_for(ctrl_frame_ms)
    let p = tmw.drawn_rects().filter(fn(r) { r.4 == lifted_mw && (r.1 - rmax.1).abs() < 8.0 && r.2 > 20.0 })
    assert_true(((p[0].0 + p[0].2 / 2.0) - mw_cx0).abs() < 0.01, msg="seg_fill_node restore must not animate across frames")
  }
  tmw.assert_idle()
  set_dark(None)
}

///|
test "Bare async Segmented tap (200ms delayed chosen.set): thumb holds still until confirmed then slides monotonically" {
  let chosen = @signals.signal(0)
  let pending : Ref[Int?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(
          page,
          fn() { ["10", "20", "30"] },
          fn() { chosen.get() },
          fn(k) { pending.val = Some(k) },
          said="AsyncSeg",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let thumb_cx = fn() raise {
    let lifted = @ui.tree_theme().lifted
    let rs = t.drawn_rects().filter(fn(r) { r.4 == lifted && r.2 > 10.0 && r.3 > 10.0 })
    assert_eq(rs.length(), 1)
    rs[0].0 + rs[0].2 / 2.0
  }
  let start_cx = thumb_cx()
  let r2 = t.get(Radio, label="30").rect
  t.tap(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
  assert_eq(pending.val, Some(2))
  // During 200ms before authority confirms, thumb center must remain rock steady at start_cx (0 glass).
  for _ in 0..<12 {
    t.run_for(ctrl_frame_ms)
    assert_eq(t.drawn_glass().length(), 0)
    assert_true((thumb_cx() - start_cx).abs() < 0.5, msg="bare async thumb must stay still before confirmation")
  }
  // Confirm -> slides monotonically toward 30 without any backward jump.
  chosen.set(2)
  let mut prev = thumb_cx()
  for _ in 0..<15 {
    t.run_for(ctrl_frame_ms)
    let cur = thumb_cx()
    assert_true(cur >= prev - 0.1, msg="confirmed async thumb must slide monotonically: \{cur} < \{prev}")
    prev = cur
  }
  t.run_for(@ui.move_most_ms)
  assert_true((thumb_cx() - (r2.0 + r2.2 / 2.0)).abs() < 2.0)
  t.assert_idle()
  set_dark(None)
}

///|
test "Mid-lens toggle of reduced_motion and glass_solid cleans up on frame 0 after restore across Segmented, Switch, and Slider (Up & Off)" {
  for toggle_solid in [false, true] {
    for use_off in [false, true] {
      // 1. Segmented
      let chosen = @signals.signal(0)
      let t = @ui.Tester::new(
        fn(_c) {  },
        w=420.0,
        h=160.0,
        dark=false,
        platform=0,
        pointing=if use_off { Finger } else { Mouse },
        native=if use_off { Finger } else { Mouse },
      )
      set_dark(Some(false))
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            seg_fill_node(page, fn() { ["A", "B", "C"] }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, said="MidSeg")
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      let r0 = t.get(Radio, label="A").rect
      let r2 = t.get(Radio, label="C").rect
      if use_off {
        t.touch(0, r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0)
      } else {
        t.press_at(r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0)
      }
      t.run_for(ctrl_over_hold_ms + part_whole_ms)
      assert_eq(t.drawn_glass().length(), 1)
      if toggle_solid {
        @ui.set_glass_solid(Some(true))
      } else {
        t.set_reduce_motion(true)
      }
      t.draw()
      if use_off {
        t.touch(3, r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0)
      } else {
        t.move_to(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
        t.release(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
      }
      // Restore preference immediately -> frame 0 must have 0 glass (no lens resurrection)
      @ui.set_glass_solid(None)
      t.set_reduce_motion(false)
      t.draw()
      assert_eq(t.drawn_glass().length(), 0, msg="Seg restore frame 0 (solid=\{toggle_solid} off=\{use_off}) must be 0 glass")
      t.run_for(@ui.move_most_ms)
      t.assert_idle()

      // 2. Switch
      let sw_on = @signals.signal(false)
      let ts = @ui.Tester::new(fn(_c) {  }, w=260.0, h=140.0, dark=false, platform=0, pointing=Finger, native=Finger)
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            switch_node(page, fn() { sw_on.get() }, fn(v) { sw_on.set(v) }, fn() { "MidSw" }) |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      ts.draw()
      let rsw = ts.get(Switch, label="MidSw").rect
      ts.touch(0, rsw.0 + 12.0, rsw.1 + rsw.3 / 2.0)
      ts.run_for(part_whole_ms)
      assert_eq(ts.drawn_glass().length(), 1)
      if toggle_solid {
        @ui.set_glass_solid(Some(true))
      } else {
        ts.set_reduce_motion(true)
      }
      ts.draw()
      if use_off {
        ts.touch(3, rsw.0 + 12.0, rsw.1 + rsw.3 / 2.0)
      } else {
        ts.touch(2, rsw.0 + 36.0, rsw.1 + rsw.3 / 2.0)
      }
      @ui.set_glass_solid(None)
      ts.set_reduce_motion(false)
      ts.draw()
      assert_eq(ts.drawn_glass().length(), 0, msg="Switch restore frame 0 (solid=\{toggle_solid} off=\{use_off}) must be 0 glass")
      ts.run_for(@ui.move_most_ms)
      ts.assert_idle()

      // 3. Slider (stops_node)
      let st_idx = @signals.signal(0)
      let st_state = Stops::new()
      let tl = @ui.Tester::new(
        fn(_c) {  },
        w=420.0,
        h=160.0,
        dark=false,
        platform=0,
        pointing=if use_off { Finger } else { Mouse },
        native=if use_off { Finger } else { Mouse },
      )
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            stops_node(page, fn() { ["Low", "Med", "High"] }, fn() { st_idx.get() }, st_state, said="MidStops", on_pick=fn(i) { st_idx.set(i) })
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      tl.draw()
      let rsl = tl.get(Slider, label="MidStops").rect
      if use_off {
        tl.touch(0, rsl.0 + 24.0, rsl.1 + rsl.3 / 2.0)
      } else {
        tl.press_at(rsl.0 + 24.0, rsl.1 + rsl.3 / 2.0)
      }
      tl.run_for(part_whole_ms)
      assert_eq(tl.drawn_glass().length(), 1)
      if toggle_solid {
        @ui.set_glass_solid(Some(true))
      } else {
        tl.set_reduce_motion(true)
      }
      tl.draw()
      if use_off {
        tl.touch(3, rsl.0 + 24.0, rsl.1 + rsl.3 / 2.0)
      } else {
        tl.move_to(rsl.0 + rsl.2 - 24.0, rsl.1 + rsl.3 / 2.0)
        tl.release(rsl.0 + rsl.2 - 24.0, rsl.1 + rsl.3 / 2.0)
      }
      @ui.set_glass_solid(None)
      tl.set_reduce_motion(false)
      tl.draw()
      assert_eq(tl.drawn_glass().length(), 0, msg="Slider restore frame 0 (solid=\{toggle_solid} off=\{use_off}) must be 0 glass")
      tl.run_for(@ui.move_most_ms)
      tl.assert_idle()
    }
  }
  set_dark(None)
}

///|
test "tabs_node(Pill) #8553 mouse & finger reject/redirect, axis lock, Up-only, in-place reorder, manual keyboard; stops_node 90pt fast drag cap" {
  let chosen = @signals.signal("a")
  let mode = @signals.signal(0) // 0=reject, 1=redirect to "b", 2=accept
  let tab_arr : Array[(String, () -> String)] = [("a", fn() { "Alpha" }), ("b", fn() { "Beta" }), ("c", fn() { "Gamma" })]
  let commits : Array[String] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=220.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        tabs_node(
          page,
          fn() { "PillTabs" },
          tab_arr,
          fn() { chosen.get() },
          fn(k) {
            commits.push(k)
            match mode.get() {
              0 => () // reject
              1 => chosen.set("b") // redirect
              _ => chosen.set(k)
            }
          },
          fn(p, k) { words_node(p, fn() { "panel:" + k }, fn() { paragraph }) |> ignore },
          look=Pill,
          manual=true,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let pill_cx = fn() raise {
    let raised = theme().p.raised
    let rs = t.drawn_rects().filter(fn(r) { r.4 == raised && r.2 > 20.0 && r.3 > 16.0 })
    assert_true(rs.length() >= 1)
    rs[0].0 + rs[0].2 / 2.0
  }
  let ra = t.get(Tab, label="Alpha").rect
  let rb = t.get(Tab, label="Beta").rect
  let rc = t.get(Tab, label="Gamma").rect
  // 1. Mouse & Finger short-tap #8553 sync reject & redirect
  t.tap(rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "a")
  assert_true(t.find("panel:a") is Some(_))
  assert_eq(t.get(Tab, label="Alpha").selected, Some(true))
  assert_true((pill_cx() - (ra.0 + ra.2 / 2.0)).abs() < 3.0)
  assert_eq(t.drawn_glass().length(), 0)
  // Finger short-tap reject
  t.touch(0, rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.touch(2, rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "a")
  assert_eq(t.get(Tab, label="Alpha").selected, Some(true))
  // Finger short-tap redirect to "b"
  mode.set(1)
  t.touch(0, rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.touch(2, rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "b")
  assert_true(t.find("panel:b") is Some(_))
  assert_eq(t.get(Tab, label="Beta").selected, Some(true))
  assert_true((pill_cx() - (rb.0 + rb.2 / 2.0)).abs() < 3.0)
  // 2. Manual keyboard mode: ArrowRight moves focus without changing chosen; Space activates.
  mode.set(2)
  t.key(@ui.key_tab)
  t.draw()
  t.key(@ui.key_code_right)
  t.run_for(ctrl_two_frames_ms)
  assert_eq(chosen.get(), "b", msg="manual tabs ArrowRight must not auto-select")
  t.key(@ui.key_space)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "c", msg="manual tabs Space must activate focused tab")
  assert_eq(t.drawn_glass().length(), 0)
  // 3. Mouse selected-item axis lock & Finger/Mouse Up-only
  let c0 = commits.length()
  let cy = rc.1 + rc.3 / 2.0
  t.press_at(rc.0 + rc.2 / 2.0, cy)
  t.move_to(rc.0 + rc.2 / 2.0, cy + 24.0)
  t.run_for(ctrl_frame_ms)
  t.move_to(ra.0 + ra.2 / 2.0, cy + 24.0)
  t.release(ra.0 + ra.2 / 2.0, cy + 24.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits.length(), c0, msg="tabs vertical-locked drag must commit 0")
  // Mouse vertical Up-only over slop on selected -> 0 commit
  let mdy = 10.0
  assert_true(mdy > @ui.touch_slop() && mdy < rc.3 / 2.0)
  t.press_at(rc.0 + rc.2 / 2.0, cy)
  t.release(rc.0 + rc.2 / 2.0, cy + mdy)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits.length(), c0, msg="tabs mouse vertical Up-only on selected must commit 0")
  // Horizontal Up-only on selected -> commits by Up.x
  t.press_at(rc.0 + rc.2 / 2.0, cy)
  t.release(ra.0 + ra.2 / 2.0, cy)
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chosen.get(), "a", msg="tabs mouse horizontal Up-only must commit Alpha")
  // 4. In-place array reorder [a,b,c] -> [a,c,b] during hold -> 0 commit
  let c1 = commits.length()
  t.press_at(rb.0 + rb.2 / 2.0, cy)
  t.run_for(ctrl_short_hold_ms)
  let tmp = tab_arr[1]
  tab_arr[1] = tab_arr[2]
  tab_arr[2] = tmp
  t.release(rb.0 + rb.2 / 2.0, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(commits.length(), c1, msg="in-place tabs reorder during hold must commit 0")
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()

  // 4b. Finger-mode tabs_node(Pill): vertical Up-only over slop INSIDE unselected item -> 0 commit
  let f_tab_chosen = @signals.signal("a")
  let f_tab_commits : Array[String] = []
  let ttf = @ui.Tester::new(fn(_c) {  }, w=460.0, h=160.0, dark=false, platform=0, pointing=Finger, native=Finger)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        tabs_node(
          page,
          fn() { "PillTabsFinger" },
          [("a", fn() { "Alpha" }), ("b", fn() { "Beta" }), ("c", fn() { "Gamma" })],
          fn() { f_tab_chosen.get() },
          fn(k) {
            f_tab_commits.push(k)
            f_tab_chosen.set(k)
          },
          fn(_p, _k) {  },
          look=Pill,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  ttf.draw()
  let fra = ttf.get(Tab, label="Alpha").rect
  let frb = ttf.get(Tab, label="Beta").rect
  let frc = ttf.get(Tab, label="Gamma").rect
  let fdy = 10.0
  assert_true(fdy > @ui.touch_slop() && fdy < frb.3 / 2.0, msg="tabs finger vertical Up-only offset must exceed slop while staying inside item")
  ttf.touch(0, frb.0 + frb.2 / 2.0, frb.1 + frb.3 / 2.0)
  ttf.touch(2, frb.0 + frb.2 / 2.0, frb.1 + frb.3 / 2.0 + fdy)
  ttf.run_for(@ui.move_most_ms)
  assert_eq(f_tab_commits, [], msg="tabs finger vertical Up-only over slop inside unselected item must commit 0")
  assert_eq(f_tab_chosen.get(), "a")
  // Finger horizontal Up-only over slop -> commits by Up.x
  ttf.touch(0, fra.0 + fra.2 / 2.0, fra.1 + fra.3 / 2.0)
  ttf.touch(2, frc.0 + frc.2 / 2.0, frc.1 + frc.3 / 2.0)
  ttf.run_for(2.0 * @ui.move_most_ms)
  assert_eq(f_tab_commits, ["c"], msg="tabs finger horizontal Up-only must commit Gamma by Up.x")
  assert_eq(f_tab_chosen.get(), "c")
  assert_eq(ttf.drawn_glass().length(), 0)
  ttf.assert_idle()

  // 5. Real stops_node long-label (>=90pt wide thumb) multi-frame fast drag: lens width <= cur_tw + 20pt
  let st_chosen = @signals.signal(0)
  let st_state = Stops::new()
  let ts = @ui.Tester::new(fn(_c) {  }, w=460.0, h=160.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        stops_node(
          page,
          fn() { ["Standard", "Balanced", "Maximum Effort"] },
          fn() { st_chosen.get() },
          st_state,
          said="LongStops",
          on_pick=fn(i) { st_chosen.set(i) },
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  ts.draw()
  // Measure resting thumb width first (must be >= 90pt)
  let rsl = ts.get(Slider, label="LongStops").rect
  let rest_thumbs = ts.drawn_instances().filter(fn(i) { i[5] == 0.0 && i[2] >= 90.0 && i[3] >= 20.0 && i[3] <= 40.0 })
  let rest_w = rest_thumbs.fold(init=0.0, fn(acc, inst) { if inst[2] > acc { inst[2] } else { acc } })
  assert_true(rest_w >= 90.0, msg="long-label stops_node thumb must be >= 90pt, got \{rest_w}")
  let sly = rsl.1 + rsl.3 / 2.0
  ts.press_at(rsl.0 + 40.0, sly)
  ts.run_for(part_whole_ms)
  ts.move_to(rsl.0 + 160.0, sly)
  ts.frame(ms=ctrl_frame_ms)
  ts.move_to(rsl.0 + rsl.2 - 30.0, sly)
  ts.run_for(ctrl_two_frames_ms)
  let sl_lenses = ts.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(sl_lenses.length(), 1, msg="stops_node fast drag must draw 1 glass lens")
  assert_true(sl_lenses[0][2] <= rest_w + 20.5, msg="wide stops_node lens (\{sl_lenses[0][2]}) must be capped <= rest_w+20 (\{rest_w + 20.0})")
  ts.release(rsl.0 + rsl.2 - 30.0, sly)
  ts.run_for(2.0 * @ui.move_most_ms)
  ts.assert_idle()
  set_dark(None)
}

///|
test "shared SegThumb: receiver-first reveal with same-batch labels change" {
  let shown_ah3 = @signals.signal(true)
  let shown_bh3 = @signals.signal(false)
  let chosen_ah3 = @signals.signal(0)
  let labels_b = @signals.signal(["K0", "K1", "K2", "K3"])
  let chosen_bh3 = @signals.signal(0)
  let tah3 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared_h3 = @glass.DampedDrag::new(0.0, lo=0.0, hi=3.0, held_scale=@glass.ctrl_seg_held_scale)
        @glass.liquid_segmented_node(
          page,
          fn() { ["H0", "H1"] },
          fn() { chosen_ah3.get() },
          fn(k) {
            chosen_ah3.set(k)
            shown_ah3.set(false)
          },
          width=260.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_ah3.get() },
          glass_track=false,
        )
        |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { labels_b.get() },
          fn() { chosen_bh3.get() },
          fn(k) { chosen_bh3.set(k) },
          width=320.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_bh3.get() },
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tah3.draw()
  let rh1_3 = tah3.get(Tab, label="H1").rect
  tah3.press_at(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.run_for(ctrl_frame_ms)
  chosen_bh3.set(3)
  tah3.draw()
  tah3.release(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.draw()
  // Reveal GroupB AFTER GroupA already relinquished ownership:
  shown_bh3.set(true)
  tah3.run_for(2.0 * @ui.move_most_ms)
  let rk3_3 = tah3.get(Tab, label="K3").rect
  let rk3_3_cx = rk3_3.0 + rk3_3.2 / 2.0
  let lifted_h3 = @ui.tree_theme().lifted
  let pills_h3 = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3.length() >= 1, msg="GroupB solid capsule must be visible after becoming shown=true")
  let cx_h3 = pills_h3[0].0 + pills_h3[0].2 / 2.0
  assert_true((cx_h3 - rk3_3_cx).abs() < 3.0, msg="GroupB capsule must replay deferred sync to K3 (\{rk3_3_cx}) on shown=true, got \{cx_h3}")
  tah3.assert_idle()
  // While GroupA is hidden (shown_ah3=false) but still alive, externally changing GroupA's selected back to H0
  // must NOT hijack shared dd or pull GroupB's capsule away from K3!
  chosen_ah3.set(0)
  tah3.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chosen_bh3.get(), 3, msg="GroupB selected must remain 3 after hidden GroupA updates")
  let pills_h3_after = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3_after.length() >= 1, msg="GroupB solid capsule must stay visible after hidden GroupA updates")
  let cx_h3_after = pills_h3_after[0].0 + pills_h3_after[0].2 / 2.0
  assert_true((cx_h3_after - rk3_3_cx).abs() < 3.0, msg="hidden GroupA selected update must NOT pull GroupB capsule away from K3 (\{rk3_3_cx}), got \{cx_h3_after}")
  tah3.assert_idle()
  // Round-trip B -> A -> B with no change to B's selection while hidden: B must immediately snap back to K3!
  shown_bh3.set(false)
  tah3.draw()
  shown_ah3.set(true)
  tah3.draw()
  tah3.assert_idle()
  @signals.start_batch()
  shown_bh3.set(true)
  shown_ah3.set(false)
  labels_b.set(["K0", "K1", "K2", "K3", "K4"])
  @signals.end_batch()
  tah3.draw()
  let rr = tah3.get(Tab, label="K3").rect
  let target = rr.0 + rr.2 / 2.0
  let drawn = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rr.1).abs() < 8.0 && r.2 > 20.0 })
  let cx = drawn[0].0 + drawn[0].2 / 2.0
  tah3.run_for(2.0 * @ui.move_most_ms)
  tah3.assert_idle()
  let still = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rr.1).abs() < 8.0 && r.2 > 20.0 })
  let end_x = still[0].0 + still[0].2 / 2.0
  assert_true((cx - target).abs() < 3.0 && (end_x - target).abs() < 3.0, msg="K3=\{target}, reveal frame=\{cx}, idle=\{end_x}")
}

///|
test "shared SegThumb: receiver-first reveal with same-batch selection change" {
  let shown_ah3 = @signals.signal(true)
  let shown_bh3 = @signals.signal(false)
  let chosen_ah3 = @signals.signal(0)
  let labels_b = @signals.signal(["K0", "K1", "K2", "K3"])
  let chosen_bh3 = @signals.signal(0)
  let tah3 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
        let shared_h3 = @glass.DampedDrag::new(0.0, lo=0.0, hi=3.0, held_scale=@glass.ctrl_seg_held_scale)
        @glass.liquid_segmented_node(
          page,
          fn() { ["H0", "H1"] },
          fn() { chosen_ah3.get() },
          fn(k) {
            chosen_ah3.set(k)
            shown_ah3.set(false)
          },
          width=260.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_ah3.get() },
          glass_track=false,
        )
        |> ignore
        @glass.liquid_segmented_node(
          page,
          fn() { labels_b.get() },
          fn() { chosen_bh3.get() },
          fn(k) { chosen_bh3.set(k) },
          width=320.0,
          height=32.0,
          drag=shared_h3,
          shown=fn() { shown_bh3.get() },
          glass_track=false,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  tah3.draw()
  let rh1_3 = tah3.get(Tab, label="H1").rect
  tah3.press_at(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.run_for(ctrl_frame_ms)
  chosen_bh3.set(3)
  tah3.draw()
  tah3.release(rh1_3.0 + rh1_3.2 / 2.0, rh1_3.1 + rh1_3.3 / 2.0)
  tah3.draw()
  // Reveal GroupB AFTER GroupA already relinquished ownership:
  shown_bh3.set(true)
  tah3.run_for(2.0 * @ui.move_most_ms)
  let rk3_3 = tah3.get(Tab, label="K3").rect
  let rk3_3_cx = rk3_3.0 + rk3_3.2 / 2.0
  let lifted_h3 = @ui.tree_theme().lifted
  let pills_h3 = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3.length() >= 1, msg="GroupB solid capsule must be visible after becoming shown=true")
  let cx_h3 = pills_h3[0].0 + pills_h3[0].2 / 2.0
  assert_true((cx_h3 - rk3_3_cx).abs() < 3.0, msg="GroupB capsule must replay deferred sync to K3 (\{rk3_3_cx}) on shown=true, got \{cx_h3}")
  tah3.assert_idle()
  // While GroupA is hidden (shown_ah3=false) but still alive, externally changing GroupA's selected back to H0
  // must NOT hijack shared dd or pull GroupB's capsule away from K3!
  chosen_ah3.set(0)
  tah3.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chosen_bh3.get(), 3, msg="GroupB selected must remain 3 after hidden GroupA updates")
  let pills_h3_after = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rk3_3.1).abs() < 8.0 && r.2 > 20.0 })
  assert_true(pills_h3_after.length() >= 1, msg="GroupB solid capsule must stay visible after hidden GroupA updates")
  let cx_h3_after = pills_h3_after[0].0 + pills_h3_after[0].2 / 2.0
  assert_true((cx_h3_after - rk3_3_cx).abs() < 3.0, msg="hidden GroupA selected update must NOT pull GroupB capsule away from K3 (\{rk3_3_cx}), got \{cx_h3_after}")
  tah3.assert_idle()
  // Round-trip B -> A -> B with no change to B's selection while hidden: B must immediately snap back to K3!
  shown_bh3.set(false)
  tah3.draw()
  shown_ah3.set(true)
  tah3.draw()
  tah3.assert_idle()
  @signals.start_batch()
  shown_bh3.set(true)
  shown_ah3.set(false)
  chosen_bh3.set(2)
  @signals.end_batch()
  tah3.draw()
  let rr = tah3.get(Tab, label="K2").rect
  let target = rr.0 + rr.2 / 2.0
  let drawn = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rr.1).abs() < 8.0 && r.2 > 20.0 })
  let cx = drawn[0].0 + drawn[0].2 / 2.0
  tah3.run_for(2.0 * @ui.move_most_ms)
  tah3.assert_idle()
  let still = tah3.drawn_rects().filter(fn(r) { r.4 == lifted_h3 && (r.1 - rr.1).abs() < 8.0 && r.2 > 20.0 })
  let end_x = still[0].0 + still[0].2 / 2.0
  assert_true((cx - target).abs() < 3.0 && (end_x - target).abs() < 3.0, msg="K2=\{target}, reveal frame=\{cx}, idle=\{end_x}")
}
