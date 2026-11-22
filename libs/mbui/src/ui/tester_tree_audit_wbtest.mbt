// Tests for Tester::unnamed_press_faults, Tester::light_audit, Tester::assert_clean, and Tester::tree default guards
// (fanout_limit and unseen_press_held).

///|
test "unnamed_press_faults flags unnamed on_press and allows says label, child text, and as_ground" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(unnamed) {
        unnamed
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .ground(Is(0x3366CCFFL))
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
      root.box(fn(with_says) {
        with_says
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .ground(Is(0x44AA44FFL))
        .says(Is(Some(@view.said(Button, label="Save"))))
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
      root.box(fn(with_child_text) {
        with_child_text
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .ground(Is(0x555555FFL))
        .on_press(fn() { () })
        |> ignore
        with_child_text.box(fn(lbl) {
          lbl.words(Is("Cancel")).ink(Is(0xFFFFFFFFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(ground_backdrop) {
        ground_backdrop
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .ground(Is(0x00000022L))
        .as_ground()
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=300.0,
    unnamed_press_held=false,
  )
  t.draw()
  let faults = t.unnamed_press_faults()
  assert_eq(faults.length(), 1, msg=faults.join("\n"))
  assert_true(faults[0].has_prefix("[UNNAMED_PRESS]"), msg=faults[0])
  assert_true(faults[0].contains("tester_tree_audit_wbtest.mbt:"), msg=faults[0])
}

///|
test "unnamed_press_faults flags interactive role without label or visible text" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(icon_btn) {
        icon_btn
        .width(Is(Some(40.0)))
        .height(Is(Some(40.0)))
        .ground(Is(0x3366CCFFL))
        .says(Is(Some(@view.said(Button))))
        |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=200.0,
    unnamed_press_held=false,
  )
  t.draw()
  let faults = t.unnamed_press_faults()
  assert_eq(faults.length(), 1, msg=faults.join("\n"))
  assert_true(faults[0].has_prefix("[UNNAMED_PRESS]"), msg=faults[0])
}

///|
test "Tester::tree enables fanout_limit=64 by default and fanout_limit=0 disables it" {
  let sig = @signals.signal(0)
  // Default Tester::tree enables fanout_limit=64 and holds on frame end; disable hold to inspect via hold_fanout_said.
  let t = Tester::tree(
    fn(root) {
      for _ in 0..<64 {
        root.box(fn(item) {
          item
          .width(Is(Some(4.0)))
          .height(Is(Some(4.0)))
          .ground(By(fn() { if sig.get() == 0 { 0x111111FFL } else { 0x222222FFL } }))
          |> ignore
        })
        |> ignore
      }
    },
    w=300.0,
    h=300.0,
  )
  assert_eq(@signals.fanout_limit.val, 64)
  assert_true(fanout_hold.val)
  sig.set(1)
  assert_false(t.fanout_faults().is_empty(), msg=">=64 subscribers write should trigger [FAN_OUT]")
  assert_true(t.fanout_faults()[0].has_prefix("[FAN_OUT]"), msg=t.fanout_faults()[0])
  match t.hold_fanout_said() {
    Some(msg) => assert_true(msg.contains("[FAN_OUT]"), msg=msg)
    None => @halt.saying("expected hold_fanout_said to report fan-out fault")
  }
  // fanout_limit=0 disables the guard completely.
  let sig2 = @signals.signal(0)
  let t2 = Tester::tree(
    fn(root) {
      for _ in 0..<64 {
        root.box(fn(item) {
          item
          .width(Is(Some(4.0)))
          .height(Is(Some(4.0)))
          .ground(By(fn() { if sig2.get() == 0 { 0x111111FFL } else { 0x222222FFL } }))
          |> ignore
        })
        |> ignore
      }
    },
    w=300.0,
    h=300.0,
    fanout_limit=0,
  )
  assert_eq(@signals.fanout_limit.val, 0)
  assert_false(fanout_hold.val)
  sig2.set(1)
  t2.frame()
  assert_eq(t2.fanout_faults(), [])
  assert_eq(t2.hold_fanout_said(), None)
}

///|
test "Tester::tree enables unseen_press_held by default and unseen_press_held=false disables it" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(btn) {
        btn
        .width(Is(Some(60.0)))
        .height(Is(Some(32.0)))
        .ground(Is(0xCC3333FFL))
        .alpha(Is(0.0))
        .takes_unseen(Is(true))
        .says(Is(Some(@view.said(Button, label="Hidden"))))
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=200.0,
    unseen_press_held=false,
  )
  t.draw()
  assert_false(unseen_press_hold.val)
  assert_eq(t.hold_unseen_press_said(), None)
  assert_eq(t.unseen_press_faults().length(), 1)
  // Simulate the default Tester::tree guard enabled (without panicking in a test):
  unseen_press_hold.val = true
  match t.hold_unseen_press_said() {
    Some(msg) => assert_true(msg.contains("unseen press:"), msg=msg)
    None => @halt.saying("expected hold_unseen_press_said to catch unseen pressable node")
  }
  unseen_press_hold.val = false
  // Verify a clean Tester::tree defaults unseen_press_hold to true.
  let t2 = Tester::tree(
    fn(root) {
      root.box(fn(ok) {
        ok.width(Is(Some(80.0))).height(Is(Some(36.0))).words(Is("OK")).on_press(fn() { () }) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=200.0,
  )
  t2.draw()
  assert_true(unseen_press_hold.val)
  assert_eq(t2.hold_unseen_press_said(), None)
}

///|
test "light_audit draws zero extra frames, detects faults, and assert_clean passes on a clean screen" {
  let clean = Tester::tree(
    fn(root) {
      root.box(fn(btn) {
        btn
        .width(Is(Some(100.0)))
        .height(Is(Some(40.0)))
        .ground(Is(0x3366CCFFL))
        .says(Is(Some(@view.said(Button, label="Submit"))))
        .on_press(fn() { () })
        |> ignore
        btn.box(fn(lbl) { lbl.words(Is("Submit")).ink(Is(0xFFFFFFFFL)) |> ignore }) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  clean.draw()
  let frames_before = clean.frames
  assert_eq(clean.light_audit(), [])
  assert_eq(clean.frames, frames_before, msg="light_audit must not draw extra frames")
  clean.assert_clean()
  assert_eq(clean.frames, frames_before, msg="assert_clean must not draw extra frames")

  // Dirty screen: unnamed press + fanout.
  let sig = @signals.signal(0)
  let dirty = Tester::tree(
    fn(root) {
      root.box(fn(unnamed) {
        unnamed
        .width(Is(Some(60.0)))
        .height(Is(Some(32.0)))
        .ground(Is(0xCC3333FFL))
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
      for _ in 0..<8 {
        root.box(fn(item) {
          item
          .width(Is(Some(10.0)))
          .height(Is(Some(10.0)))
          .ground(By(fn() { if sig.get() == 0 { 0x111111FFL } else { 0x222222FFL } }))
          |> ignore
        })
        |> ignore
      }
    },
    w=300.0,
    h=200.0,
    fanout_limit=0,
    unnamed_press_held=false,
  )
  dirty.set_fanout_limit(8)
  sig.set(1)
  let dirty_frames = dirty.frames
  let faults = dirty.light_audit()
  assert_eq(dirty.frames, dirty_frames, msg="light_audit must not draw extra frames when faults exist")
  assert_true(faults.iter().any(fn(f) { f.has_prefix("[UNNAMED_PRESS]") }), msg=faults.join("\n"))
  assert_true(faults.iter().any(fn(f) { f.has_prefix("[FAN_OUT]") }), msg=faults.join("\n"))
  assert_true(dirty.assert_clean_said() is Some(_))
}

///|
test "pure-tree default theme automatically follows system_dark and repaints default words ink" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(lbl) { lbl.words(Is("Hello dark mode")) |> ignore }) |> ignore
    },
    w=240.0,
    h=120.0,
    dark=true,
  )
  assert_eq(tree_theme().fg, Theme::dark().fg)
  assert_eq(tree_theme().bg, Theme::dark().bg)
  t.set_dark(false)
  t.draw()
  assert_eq(tree_theme().fg, Theme::light().fg)
  assert_eq(tree_theme().bg, Theme::light().bg)
  t.set_dark(true)
  t.draw()
  assert_eq(tree_theme().fg, Theme::dark().fg)
  assert_eq(tree_theme().bg, Theme::dark().bg)
}

///|
test "Tester::tree enables untracked_read, unnamed_press, scroll_each, and effect_in_view guards by default" {
  // 1. untracked_read_held
  let sig = @signals.signal(42)
  let t1 = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        let v = sig.get()
        b.words(Is(v.to_string())) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=100.0,
    untracked_read_held=false,
  )
  assert_false(untracked_read_hold.val)
  assert_eq(t1.hold_untracked_read_said(), None)
  assert_eq(t1.untracked_read_faults().length(), 1)
  untracked_read_hold.val = true
  match t1.hold_untracked_read_said() {
    Some(msg) => assert_true(msg.contains("[STRICT_READ_UNTRACKED]"), msg=msg)
    None => @halt.saying("expected hold_untracked_read_said to catch untracked read")
  }
  untracked_read_hold.val = false

  // 2. unnamed_press_held
  let t2 = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        b.width(Is(Some(60.0))).height(Is(Some(32.0))).ground(Is(0x3366CCFFL)).on_press(fn() { () }) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=100.0,
    unnamed_press_held=false,
  )
  t2.draw()
  assert_false(unnamed_press_hold.val)
  assert_eq(t2.hold_unnamed_press_said(), None)
  unnamed_press_hold.val = true
  match t2.hold_unnamed_press_said() {
    Some(msg) => assert_true(msg.contains("[UNNAMED_PRESS]"), msg=msg)
    None => @halt.saying("expected hold_unnamed_press_said to catch unnamed press")
  }
  unnamed_press_hold.val = false

  // 3. scroll_each_limit
  let items : Array[Int] = []
  for i in 0..<52 {
    items.push(i)
  }
  let sc = @view.Scroll::new()
  let t3 = Tester::tree(
    fn(root) {
      root.box(fn(box) {
        box.width(Is(Some(200.0))).height(Is(Some(100.0))).scrolls(sc, fn(inner) {
          inner.each(fn() { items }, fn(i) { i }, fn(row, _it) {
            row.height(Is(Some(16.0))) |> ignore
          }, at_once=true)
        })
        |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=120.0,
    scroll_each_limit=0,
  )
  assert_eq(scroll_each_hold_limit.val, 0)
  assert_eq(t3.hold_scroll_each_said(), None)
  assert_eq(t3.scroll_each_faults().length(), 1)
  scroll_each_hold_limit.val = 50
  match t3.hold_scroll_each_said() {
    Some(msg) => assert_true(msg.contains("[UNVIRTUALIZED_SCROLL_EACH]"), msg=msg)
    None => @halt.saying("expected hold_scroll_each_said to catch >50 scroll-each rows")
  }
  scroll_each_hold_limit.val = 0

  // 4. effect_in_view_held
  let s_eff = @signals.signal(0)
  let t4 = Tester::tree(
    fn(root) {
      root.box(fn(_b) {
        @signals.effect(fn() { s_eff.get() |> ignore }) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=100.0,
    effect_in_view_held=false,
  )
  assert_false(effect_in_view_hold.val)
  assert_eq(t4.hold_effect_in_view_said(), None)
  assert_eq(t4.effect_in_view_faults().length(), 1)
  assert_true(t4.light_audit().iter().any(fn(f) { f.has_prefix("[EFFECT_IN_VIEW]") }))
  effect_in_view_hold.val = true
  match t4.hold_effect_in_view_said() {
    Some(msg) => assert_true(msg.contains("[EFFECT_IN_VIEW]"), msg=msg)
    None => @halt.saying("expected hold_effect_in_view_said to catch bare effect in view")
  }
  effect_in_view_hold.val = false

  // 5. Verify clean Tester::tree has all guards enabled by default
  let clean = Tester::tree(
    fn(root) {
      root.box(fn(ok) {
        ok.width(Is(Some(80.0))).height(Is(Some(36.0))).words(Is("OK")).on_press(fn() { () }) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=100.0,
  )
  clean.draw()
  assert_true(untracked_read_hold.val)
  assert_true(unnamed_press_hold.val)
  assert_eq(scroll_each_hold_limit.val, 50)
  assert_true(effect_in_view_hold.val)
  assert_eq(clean.light_audit(), [])
}
