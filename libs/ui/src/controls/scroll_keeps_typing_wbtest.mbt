// A finger scrolling what floats beside a field with the keyboard (Android's fields, a finger's) keeps that field its
// keyboard where what scrolls is for it: what a field offers (offers_node, View::scrolls' `for_in` its `around`), a long
// pick's list under its search (pick_node, `for_in` its search), a menu opened over a field by a finger (menu_node's
// `keep_field`) and a panel that leaves the focus where it is (panel_nodes' `focus` false), each a layer leaving what is
// typed to the field outside it (View::leaves_typing). A field outside what the list is for lets its keyboard go as ever.

///|
/// The label of what has the focus, None nothing.
fn skt_focused(t : @ui.Tester) -> String? {
  t.focused().map(fn(s) { s.label })
}

///|
/// The field `label` tapped by a finger in its middle.
fn skt_tap_field(t : @ui.Tester, label : String) -> Unit {
  let (x, y, w, h) = t.get(TextField, label~).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.draw()
}

///|
/// Where the words `words` stand down the window now (-1 not drawn).
fn skt_y(t : @ui.Tester, words : String) -> Double {
  match t.find(words) {
    Some((_, y)) => y
    None => -1.0
  }
}

///|
/// A finger dragging the words `words` 75 up (past the touch slop: a scroll), then a frame.
fn skt_drag_up(t : @ui.Tester, words : String) -> Unit raise {
  guard t.find(words) is Some((x, y)) else { fail("\{words} not drawn") }
  t.drag(x + 5.0, y + 5.0, x + 5.0, y - 75.0)
  t.draw()
}

///|
/// A wide window (not 小屏: panels beside what opened them) of a finger's (Android's) holding what `app` makes.
fn skt_tester(app : (@view.View) -> Unit) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=1000.0, h=700.0, platform=2, pointing=Finger)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.padding(Is((40.0, 40.0, 40.0, 40.0))).gap(Is(16.0)) |> ignore
    app(root)
  })
  t.draw()
  t
}

///|
/// A field `label` 300 wide in `parent`, written into `f`; its frame.
fn skt_field(parent : @view.View, f : @ui.Field, label : String) -> @view.View {
  let v = input_node(parent, f, placeholder=label, label~)
  v.parent().unwrap_or(v)
}

///|
/// A window with a field 查找 in `around` offering 20 (候选 0 ..), opened by `open`, and a field 其他 outside it.
fn skt_offers(open : @signals.Signal[Bool]) -> @ui.Tester {
  let keys = Array::makei(20, fn(i) { "k\{i}" })
  let named : Map[String, String] = Map([])
  for i, k in keys {
    named[k] = "候选 \{i}"
  }
  let name_of = fn(k : String) { named.get(k).unwrap_or(k) }
  let current = @signals.signal(0, same=fn(a, b) { a == b })
  skt_tester(fn(root) {
    root.box(fn(around) {
      around.width(Is(Some(300.0))) |> ignore
      let frame = skt_field(around, @ui.Field::new(), "查找")
      offers_node(
        around,
        frame,
        fn() { open.get() },
        fn() { keys },
        current,
        fn(r, k, _) { words_node(r, fn() { name_of(k) }, fn() { offers_head_words }) |> ignore },
        name_of,
        fn(_) { open.set(false) },
        fn() { open.set(false) },
        "候选",
      )
    })
    |> ignore
    root.box(fn(o) {
      o.width(Is(Some(300.0))).margin(Is((0.0, 400.0, 0.0, 0.0))) |> ignore
      skt_field(o, @ui.Field::new(), "其他") |> ignore
    })
    |> ignore
  })
}

///|
test "offers, a finger's: scrolling what a field offers keeps that field the focus and its keyboard, open still" {
  let open = @signals.signal(false)
  let t = skt_offers(open)
  skt_tap_field(t, "查找")
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq((skt_focused(t), t.ime().0), (Some("查找"), true), msg="the field with the keyboard as it opens")
  let before = skt_y(t, "候选 4")
  skt_drag_up(t, "候选 4")
  let after = skt_y(t, "候选 4")
  assert_true(after < before, msg="scrolled: \{before} -> \{after}")
  assert_eq((skt_focused(t), t.ime().0, open.get()), (Some("查找"), true, true))
}

///|
test "offers, a finger's: scrolling them while a field outside what holds their field has the focus lets that field's keyboard go" {
  let open = @signals.signal(false)
  let t = skt_offers(open)
  skt_tap_field(t, "其他")
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq((skt_focused(t), t.ime().0), (Some("其他"), true), msg="the other field with the keyboard")
  let before = skt_y(t, "候选 4")
  skt_drag_up(t, "候选 4")
  let after = skt_y(t, "候选 4")
  assert_true(after < before, msg="scrolled: \{before} -> \{after}")
  assert_eq((skt_focused(t) == Some("其他"), t.ime().0), (false, false))
}

///|
test "a long pick, a finger's: scrolling what is found keeps its search the focus and its keyboard" {
  let open = @signals.signal(false)
  let opener : Ref[@view.View?] = Ref(None)
  let choices = Array::makei(30, fn(i) {
    { key: "c\{i}", label: "选择 \{i}", note: "", value: "", icon: "", mark: None, disabled: false }
  })
  let t = skt_tester(fn(root) {
    opener.val = Some(
      root.box(fn(o) {
        o.width(Is(Some(120.0))).height(Is(Some(36.0))) |> ignore
      }),
    )
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      pick_node(
        l,
        fn() { open.get() },
        fn(_) { opener.val.unwrap() },
        "挑一个",
        choices,
        "",
        @ui.Field::new(),
        Start,
        6.0,
        fn(_) { open.set(false) },
        fn() { open.set(false) },
      )
    })
    |> ignore
  })
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  // (on touch, opening a long pick keeps the soft keyboard down until the user taps the search field)
  assert_eq(t.ime().0, false, msg="touch long pick does not auto-open keyboard")
  let tf = t.semantics().iter().find_first(fn(s) { s.role == TextField }).unwrap()
  t.tap(tf.rect.0 + tf.rect.2 / 2.0, tf.rect.1 + tf.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  let search = skt_focused(t)
  assert_true(search is Some(_) && t.ime().0, msg="its search with the keyboard once tapped: \{search.unwrap_or("none")}")
  let before = skt_y(t, "选择 4")
  skt_drag_up(t, "选择 4")
  let after = skt_y(t, "选择 4")
  assert_true(after < before, msg="scrolled: \{before} -> \{after}")
  assert_eq((skt_focused(t), t.ime().0, open.get()), (search, true, true))
}

///|
test "a menu opened by a finger over a field with the keyboard (keep_field), a finger's: scrolling it keeps the field its keyboard" {
  let open = @signals.signal(false)
  let frame : Ref[@view.View?] = Ref(None)
  let items = Array::makei(30, fn(i) { Some(menu_item_of("菜单项 \{i}", fn() {  })) })
  let t = skt_tester(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      frame.val = Some(skt_field(b, @ui.Field::new(), "写字"))
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node(
        l,
        fn() { open.get() },
        fn(_) { frame.val.unwrap() },
        fn() { items },
        "",
        Start,
        6.0,
        false,
        true,
        fn(_) { open.set(false) },
        fn() { open.set(false) },
      )
    })
    |> ignore
  })
  skt_tap_field(t, "写字")
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq((skt_focused(t), t.ime().0), (Some("写字"), true), msg="the field with the keyboard as it opens")
  let before = skt_y(t, "菜单项 6")
  skt_drag_up(t, "菜单项 6")
  let after = skt_y(t, "菜单项 6")
  assert_true(after < before, msg="scrolled: \{before} -> \{after}")
  assert_eq((skt_focused(t), t.ime().0, open.get()), (Some("写字"), true, true))
}

///|
test "a panel that leaves the focus where it is (focus false), a finger's: scrolling what it holds keeps the field under it its keyboard" {
  let frame : Ref[@view.View?] = Ref(None)
  let t = skt_tester(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      frame.val = Some(skt_field(b, @ui.Field::new(), "写字"))
    })
    |> ignore
    presented_nodes(root)
  })
  skt_tap_field(t, "写字")
  panel_nodes(
    "面板",
    fn(v, _) {
      for i in 0..<20 {
        words_node(v, fn() { "内容 \{i}" }, fn() { desk_muted }) |> ignore
      }
    },
    from=Node(frame.val.unwrap()),
    focus=false,
    most=fn() { 200.0 },
  )
  t.draw()
  come_to_rest(t)
  assert_eq((skt_focused(t), t.ime().0), (Some("写字"), true), msg="the field with the keyboard as it opens")
  let before = skt_y(t, "内容 3")
  skt_drag_up(t, "内容 3")
  let after = skt_y(t, "内容 3")
  assert_true(after < before, msg="scrolled: \{before} -> \{after}")
  assert_eq((skt_focused(t), t.ime().0, t.find("内容 3") is Some(_)), (Some("写字"), true, true))
}
