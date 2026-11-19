// A menu that is not modal (menu_node's `modal` false: a submenu's, beside the row that opened it): what is under it its
// own, a press outside it closing it and going on to what it lands on, a press on what opened it not; the arrow key back
// toward what opened it closing it. A modal menu takes a primary press outside, and hands a secondary press on after it
// closes.

///|
/// A window with a button 开 that opens a menu at its Right (`modal` or not), and a button 下面 under it, each counting its
/// presses (`under`), the menu's closings unchosen counted in `cancels`.
fn side_menu_tester(
  modal : Bool,
  open : @signals.Signal[Bool],
  cancels : Ref[Int],
  under : Ref[Int],
  leave_open? : Bool = false,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.padding(Is((100.0, 100.0, 0.0, 0.0))).gap(Is(40.0)) |> ignore
    let opener = root.box(fn(o) {
      o
      .width(Is(Some(120.0)))
      .height(Is(Some(36.0)))
      .presses(Is(true))
      .on_press(fn() { open.set(true) })
      .says(Is(Some(@view.said(Button, label="开"))))
      |> ignore
    })
    root.box(fn(u) {
      u
      .width(Is(Some(120.0)))
      .height(Is(Some(36.0)))
      .presses(Is(true))
      .on_press(fn() { under.val += 1 })
      .on_menu(fn(_) { under.val += 1 })
      .says(Is(Some(@view.said(Button, label="下面"))))
      |> ignore
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node(
        l,
        fn() { open.get() },
        fn(_) { opener },
        fn() { [Some(menu_item_of("一", fn() {  })), Some(menu_item_of("二", fn() {  }))] },
        "",
        Start,
        8.0,
        false,
        false,
        fn(_) { open.set(false) },
        fn() {
          cancels.val += 1
          if !leave_open {
            open.set(false)
          }
        },
        side=Right,
        modal~,
      )
    })
    |> ignore
  })
  t.draw()
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The middle of the button `label` (开 or 下面), where side_menu_tester lays it out: 100 in, 100 down, 120 by 36, 40
/// apart (by where it is, not by what is read out: a modal menu hides what is under it from that).
fn side_button(label : String) -> (Double, Double) {
  if label == "开" {
    (160.0, 118.0)
  } else {
    (160.0, 194.0)
  }
}

///|
test "a menu not modal: a press outside its panel closes it as it goes down, and what it lands on is pressed; modal, the press its own" {
  for modal in [false, true] {
    let open = @signals.signal(false)
    let (cancels, under) = (Ref(0), Ref(0))
    let t = side_menu_tester(modal, open, cancels, under)
    assert_true(t.query(Menu) is Some(_), msg="modal \{modal}: open")
    let (x, y) = side_button("下面")
    t.tap(x, y)
    t.run_for(@ui.move_most_ms)
    assert_eq((cancels.val, under.val, t.query(Menu) is None), (1, if modal { 0 } else { 1 }, true), msg="modal \{modal}")
  }
}

///|
test "a modal menu: a secondary press inside leaves it open; outside closes it and goes to what is under it" {
  let open = @signals.signal(false)
  let (cancels, under) = (Ref(0), Ref(0))
  let t = side_menu_tester(true, open, cancels, under)
  let (x, y, w, h) = t.rect_of("一").unwrap()
  t.right_click(x + w / 2.0, y + h / 2.0)
  assert_eq((cancels.val, under.val, t.query(Menu) is Some(_)), (0, 0, true))
  let (x, y) = side_button("下面")
  t.right_click(x, y)
  assert_eq((cancels.val, under.val, t.query(Menu) is None), (1, 1, true))
}

///|
test "a modal menu that stays open does not send its secondary press through" {
  let open = @signals.signal(false)
  let (cancels, under) = (Ref(0), Ref(0))
  let t = side_menu_tester(true, open, cancels, under, leave_open=true)
  let (x, y) = side_button("下面")
  t.right_click(x, y)
  assert_eq((cancels.val, under.val, t.query(Menu) is Some(_)), (1, 0, true))
}

///|
test "a menu not modal: a press on what opened it leaves it open" {
  let open = @signals.signal(false)
  let (cancels, under) = (Ref(0), Ref(0))
  let t = side_menu_tester(false, open, cancels, under)
  let (x, y) = side_button("开")
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq((cancels.val, t.query(Menu) is Some(_)), (0, true))
}

///|
test "a menu not modal at its opener's Right: Left (back toward it) closes it; modal, Left closes nothing" {
  for modal in [false, true] {
    let open = @signals.signal(false)
    let (cancels, under) = (Ref(0), Ref(0))
    let t = side_menu_tester(modal, open, cancels, under)
    t.key(@ui.key_code_left)
    t.run_for(@ui.move_most_ms)
    assert_eq((cancels.val, t.query(Menu) is None), if modal { (0, false) } else { (1, true) }, msg="modal \{modal}")
  }
}

///|
/// How opaque the words `w` are drawn now (-1: not drawn).
fn side_words_alpha(t : @ui.Tester, w : String) -> Double {
  match t.words().filter(fn(x) { x.0 == w }) {
    [x, ..] => x.5
    [] => -1.0
  }
}

///|
test "a menu closed draws back into what opened it over pop_out_ms, nothing of it in the way from the moment it closes: a press under it is what it lands on's at once" {
  let open = @signals.signal(false)
  let (cancels, under) = (Ref(0), Ref(0))
  let t = side_menu_tester(true, open, cancels, under)
  assert_eq(side_words_alpha(t, "一"), 1.0)
  t.key(@ui.key_escape)
  // (closed: not read out, not modal, nothing of it pressed, though still drawn)
  let (x, y) = side_button("下面")
  t.tap(x, y)
  assert_eq((cancels.val, under.val, t.query(Menu) is None), (1, 1, true))
  t.run_for(@motion.pop_out_ms / 2.0)
  let half = side_words_alpha(t, "一")
  assert_true(half > 0.0 && half < 1.0, msg="drawn back: \{half}")
  t.run_for(@motion.pop_out_ms / 2.0)
  assert_eq(side_words_alpha(t, "一"), -1.0)
}

///|
test "a menu closed half way in draws back from where it got to, never first whole: as faint as it was, fainter from there" {
  let open = @signals.signal(false)
  let (cancels, under) = (Ref(0), Ref(0))
  let t = side_menu_tester(true, open, cancels, under)
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_eq(side_words_alpha(t, "一"), -1.0)
  open.set(true)
  t.draw()
  t.run_for(@motion.pop_ms / 2.0)
  let mid = side_words_alpha(t, "一")
  assert_true(mid > 0.0 && mid < 1.0, msg="half way in: \{mid}")
  t.key(@ui.key_escape)
  t.draw()
  let closing = side_words_alpha(t, "一")
  assert_true(closing > 0.0 && closing <= mid, msg="as it closes: \{closing} after \{mid}")
  t.run_for(@motion.pop_out_ms / 4.0)
  let going = side_words_alpha(t, "一")
  assert_true(going < closing || going == -1.0, msg="going: \{going} after \{closing}")
  t.run_for(@motion.pop_out_ms)
  assert_eq(side_words_alpha(t, "一"), -1.0)
}
