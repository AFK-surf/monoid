// What a finger holds lifted as a node (lift_node): its scale on lift_spring from the moment its menu is said up, all
// the way, and back down from the moment it goes, as lift_of's; lifted, drawn over the menu's scrim and kept clear of
// the sheet the menu is in.

///|
let lift_test_side : Double = 100.0

///|
/// How much larger it is all the way up (a message's picture's).
let lift_test_scale : Double = 1.04

///|
/// A moment on its way up to look at.
let lift_test_mid : Double = 120.0

///|
/// The square lifted, as it is drawn: (x, y, w, h) and where among what is drawn; None where it is not.
fn lift_square(t : @ui.Tester) -> ((Double, Double, Double, Double), Int)? {
  for i, r in t.drawn_rects() {
    if r.4 == lift_test_ink {
      return Some(((r.0, r.1, r.2, r.3), i))
    }
  }
  None
}

///|
let lift_test_ink : Int64 = 0x336699FFL

///|
test "lifted as lift_of's: on lift_spring from the moment its menu is said up, back down from the moment it goes" {
  let open = @signals.signal(false)
  let root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(
    fn(c) { @ui.old_views_here(c) },
    tree=fn(r) {
      root.val = Some(r)
      r.box(fn(b) {
        b.width(Is(Some(lift_test_side))).height(Is(Some(lift_test_side))).ground(Is(lift_test_ink)) |> ignore
        lift_node(b, fn() { false }, fn() { open.get() }, lift_test_scale) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=300.0,
    platform=2,
  )
  t.run_for(lift_test_mid)
  let want = @motion.Way::new(0.0)
  for to in [true, false] {
    let at = t.time() + lift_test_mid
    root.val.unwrap().at_moment(at, fn() { open.set(to) }) |> ignore
    want.go(if to { 1.0 } else { 0.0 }, @motion.tactile_bounce, at~)
    for dt in [lift_test_mid / 2.0, lift_test_mid, @ui.move_most_ms] {
      t.run_for(at + dt - t.time())
      let w = lift_test_side * (1.0 + (lift_test_scale - 1.0) * want.value_at(t.time()))
      let got = lift_square(t).unwrap().0.2
      assert_true((got - w).abs() < 0.001, msg="\{to} at \{dt}: \{got} wanted \{w}")
    }
  }
  assert_eq(lift_square(t).unwrap().0.2, lift_test_side)
  assert_eq(t.audit(), [])
}

///|
test "lifted with its menu up from the foot: drawn over the scrim, and up clear of the sheet the menu is in; back in its place as it goes" {
  presenters_reset()
  let square : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      presented_tree(fn(c) {
        begin(c) |> ignore
        c.with_theme(ui_theme(), fn() { presented(c) })
      })(root)
      // (at the window's foot, where the sheet comes up)
      root.box(fn(b) {
        square.val = Some(b)
        b
        .over(Is(true))
        .offset(Is((20.0, 844.0 - lift_test_side - 20.0)))
        .width(Is(Some(lift_test_side)))
        .height(Is(Some(lift_test_side)))
        .ground(Is(lift_test_ink))
        |> ignore
        lift_node(b, fn() { false }, fn() { presented_from(Node(b)) }, lift_test_scale) |> ignore
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.draw()
  let (laid, _) = lift_square(t).unwrap()
  menu([Some(menu_item_of("一项", fn() {  }))], from=Node(square.val.unwrap()))
  t.run_for(@ui.move_most_ms)
  let (up, at) = lift_square(t).unwrap()
  assert_true((up.2 - lift_test_side * lift_test_scale).abs() < 0.001, msg="\{Repr(up)}")
  assert_true(up.1 + up.3 < laid.1 + laid.3, msg="up clear of the sheet: \{Repr(up)} from \{Repr(laid)}")
  // (drawn after the scrim: a rect over the whole window drawn before it)
  let mut scrim : Int? = None
  for i, r in t.drawn_rects() {
    if scrim is None && r.2 >= 390.0 && r.3 >= 844.0 && (r.4 & 0xFFL) < 0xFFL {
      scrim = Some(i)
    }
  }
  assert_true(scrim is Some(s) && s < at, msg="scrim \{Repr(scrim)}, square \{at}")
  close_presented_of(last_presented())
  t.run_for(@ui.move_most_ms)
  assert_eq(lift_square(t).unwrap().0, laid)
  assert_true(!presented_drawn())
}

///|
let lift_float_ink : Int64 = 0xAA3366FFL

///|
fn lift_rect_index(t : @ui.Tester, ink : Int64) -> Int? {
  for i, r in t.drawn_rects() {
    if r.4 == ink {
      return Some(i)
    }
  }
  None
}

///|
test "presented_open_chain_of: true while open or replaced in place, false as soon as closing without replacement" {
  presenters_reset()
  let anchor : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      presented_tree(fn(c) {
        begin(c) |> ignore
        c.with_theme(ui_theme(), fn() { presented(c) })
      })(root)
      root.box(fn(b) {
        anchor.val = Some(b)
        b.over(Is(true)).offset(Is((20.0, 500.0))).width(Is(Some(80.0))).height(Is(Some(80.0))) |> ignore
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.draw()
  // Open menu sheet; selecting a confirm item pushes onto the same sheet (same serial).
  menu(
    [
      Some(menu_item_of("确认动作", fn() { confirm("确认", "说明", "好", fn() {  }) })),
      Some(menu_item_of("输入动作", fn() { ask("输入", "好", fn(_) {  }) })),
    ],
    from=Node(anchor.val.unwrap()),
  )
  let menu_serial = last_presented()
  t.run_for(@ui.move_most_ms)
  assert_true(presented_open_chain_of(menu_serial))
  t.tap_text("确认动作")
  t.draw()
  assert_true(presented_open_chain_of(menu_serial), msg="must remain true while inline confirm page is open on the same sheet")
  assert_eq(last_presented(), menu_serial, msg="Small Menu -> Confirm pushes a page onto the same sheet")
  // Back returns to the menu page; selecting `ask` replaces the sheet in place (`took_place`, new serial).
  t.back()
  t.run_for(@ui.move_most_ms)
  t.tap_text("输入动作")
  t.draw()
  assert_true(presented_open_chain_of(menu_serial), msg="must remain true while replacement sheet is open")
  let ask_serial = last_presented()
  assert_true(ask_serial != menu_serial)
  // Closing the replacement sheet without another replacement flips presented_open_chain_of to false immediately.
  close_presented_of(ask_serial)
  t.draw()
  assert_true(!presented_open_chain_of(menu_serial), msg="must become false immediately when closing without replacement")
  assert_true(presented_drawn_of(menu_serial), msg="still drawn while dismissing")
  t.run_for(@ui.move_most_ms)
  assert_true(!presented_drawn_of(menu_serial))
}

///|
test "leaving sheet with unpushed lifted node (dy == 0) stops raising it above floating siblings on the first exit frame" {
  presenters_reset()
  let square : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      presented_tree(fn(c) {
        begin(c) |> ignore
        c.with_theme(ui_theme(), fn() { presented(c) })
      })(root)
      // Placed at y=200 (well above the bottom sheet, so dy == 0)
      root.box(fn(b) {
        square.val = Some(b)
        b
        .over(Is(true))
        .offset(Is((20.0, 200.0)))
        .width(Is(Some(lift_test_side)))
        .height(Is(Some(lift_test_side)))
        .ground(Is(lift_test_ink))
        |> ignore
        lift_node(b, fn() { false }, fn() { presented_open_chain_of(last_presented()) && presenting() }, lift_test_scale) |> ignore
      })
      |> ignore
      // Floating sibling drawn after the lifted node
      root.box(fn(f) {
        f
        .over(Is(true))
        .offset(Is((10.0, 220.0)))
        .width(Is(Some(200.0)))
        .height(Is(Some(44.0)))
        .ground(Is(lift_float_ink))
        |> ignore
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.draw()
  menu([Some(menu_item_of("一项", fn() {  }))], from=At(20.0, 600.0, 80.0, 40.0))
  t.run_for(@ui.move_most_ms)
  let open_sq = lift_rect_index(t, lift_test_ink).unwrap()
  let open_fl = lift_rect_index(t, lift_float_ink).unwrap()
  assert_true(open_sq > open_fl, msg="while menu is open, lifted node (\{open_sq}) is drawn over floating sibling (\{open_fl})")
  // Close menu: on the very first exit frame while the lifted node is still scaling back down, it must stay below floating sibling.
  close_presented_of(last_presented())
  t.run_for(lift_test_mid / 4.0)
  assert_true(presented_drawn(), msg="sheet must still be dismissing")
  let exit_sq = lift_rect_index(t, lift_test_ink).unwrap()
  let exit_fl = lift_rect_index(t, lift_float_ink).unwrap()
  assert_true(exit_sq < exit_fl, msg="during exit with dy==0, lifted node (\{exit_sq}) must be below floating sibling (\{exit_fl})")
  t.run_for(@ui.move_most_ms)
}

///|
test "leaving sheet with pushed lifted node (dy < 0) rides down on normal dismiss, but drops immediately when IME rises or chosen action focuses a field" {
  presenters_reset()
  let square : Ref[@view.View?] = Ref(None)
  let want_focus = @signals.signal(false)
  let ext_field = @ui.Field::new()
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      presented_tree(fn(c) {
        begin(c) |> ignore
        c.with_theme(ui_theme(), fn() { presented(c) })
      })(root)
      // At the bottom of the window so the sheet pushes it up (dy < 0)
      root.box(fn(b) {
        square.val = Some(b)
        b
        .over(Is(true))
        .offset(Is((20.0, 844.0 - lift_test_side - 20.0)))
        .width(Is(Some(lift_test_side)))
        .height(Is(Some(lift_test_side)))
        .ground(Is(lift_test_ink))
        |> ignore
        lift_node(b, fn() { false }, fn() { presented_open_chain_of(last_presented()) && presenting() }, lift_test_scale) |> ignore
      })
      |> ignore
      // Floating bar + external field above it
      root.box(fn(f) {
        f
        .over(Is(true))
        .offset(Is((10.0, 480.0)))
        .width(Is(Some(260.0)))
        .height(Is(Some(44.0)))
        .ground(Is(lift_float_ink))
        |> ignore
        let inp = input_node(f, ext_field, placeholder="说明")
        f.reacts(at_start=false, fn() { want_focus.get() }, fn(on) {
          if on {
            inp.ask_focus() |> ignore
          }
        })
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.draw()
  let laid = lift_square(t).unwrap().0
  // Case A: normal dismiss -> rides down smoothly (still shifted up mid-dismissal, no snap to laid.1)
  menu([Some(menu_item_of("一项", fn() {  }))], from=Node(square.val.unwrap()))
  t.run_for(@ui.move_most_ms)
  let up_y = lift_square(t).unwrap().0.1
  assert_true(up_y < laid.1 - 10.0, msg="pushed up while open: \{up_y} vs \{laid.1}")
  close_presented_of(last_presented())
  t.run_for(lift_test_mid / 2.0)
  let mid_y = lift_square(t).unwrap().0.1
  assert_true(mid_y < laid.1 - 1.0 && mid_y > up_y, msg="normal dismiss rides down smoothly: up=\{up_y}, mid=\{mid_y}, laid=\{laid.1}")
  t.run_for(@ui.move_most_ms)
  // Case B: dismiss with IME rising -> stops raising above floating bar immediately
  menu([Some(menu_item_of("一项", fn() {  }))], from=Node(square.val.unwrap()))
  t.run_for(@ui.move_most_ms)
  close_presented_of(last_presented())
  t.set_ime_inset(260.0)
  t.run_for(lift_test_mid / 2.0)
  let ime_sq = lift_rect_index(t, lift_test_ink).unwrap()
  let ime_fl = lift_rect_index(t, lift_float_ink).unwrap()
  assert_true(ime_sq < ime_fl, msg="with IME rising on exit, lifted node (\{ime_sq}) must be below floating bar (\{ime_fl})")
  t.set_ime_inset(0.0)
  t.run_for(@ui.move_most_ms)
  // Case C: chosen menu item focuses external field (even before IME inset arrives) -> stops raising immediately
  menu(
    [Some(menu_item_of("引用", fn() { want_focus.set(true) }))],
    from=Node(square.val.unwrap()),
  )
  t.run_for(@ui.move_most_ms)
  t.tap_text("引用")
  t.run_for(lift_test_mid / 2.0)
  assert_true(@ui.field_has_focus(), msg="external field must be focused after chosen action")
  let chosen_sq = lift_rect_index(t, lift_test_ink).unwrap()
  let chosen_fl = lift_rect_index(t, lift_float_ink).unwrap()
  assert_true(chosen_sq < chosen_fl, msg="when chosen action focuses external field, lifted node (\{chosen_sq}) must be below floating bar (\{chosen_fl})")
  t.run_for(@ui.move_most_ms)
}
