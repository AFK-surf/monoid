// The library's field to look through a list by (search_input_node): what is typed is its Field's and told as it
// changes; Enter gives it up once; while it holds words the clear key shows at its end, and pressed empties it, tells
// both that it was cleared and its words now none, and gives the focus back to the field; Escape is its caller's.

///|
/// A node "别处" taking the focus at the window's top, then in a box 300 wide what `make` makes there.
fn search_input_case(make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(50.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The clear key's name, as the field says it.
fn search_clear_label() -> String {
  t("android-misc.drive.pick.filterClear")
}

///|
test "search_input_node: typed, its words told as they change; the clear key only while it holds words" {
  let f = @ui.Field::new()
  let told = []
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索设置" }, edited=fn(w) { told.push(w) }) |> ignore
  })
  let empty_has = t.query(Button, label=search_clear_label()) is Some(_)
  let (x, y, w, h) = t.get(TextField, label="搜索设置").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.type_text("主题")
  t.draw()
  let typed_has = t.query(Button, label=search_clear_label()) is Some(_)
  assert_eq((empty_has, typed_has, f.text(), told.last()), (false, true, "主题", Some("主题")))
}

///|
test "search_input_node: the clear key empties it, tells it cleared and its words none, and gives the focus back to the field" {
  let f = @ui.Field::new(text="账号")
  let told = []
  let cleared = Ref(0)
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索设置" }, edited=fn(w) { told.push(w) }, cleared=fn() { cleared.val += 1 })
    |> ignore
  })
  let (x, y, w, h) = t.get(Button, label=search_clear_label()).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.draw()
  let focused = t.focused().map(fn(s) { s.label })
  let gone = t.query(Button, label=search_clear_label()) is None
  assert_eq((f.text(), told, cleared.val, focused, gone), ("", [""], 1, Some("搜索设置"), true))
}

///|
test "search_input_node: Enter gives its words up once; Escape its caller's where it takes it" {
  let f = @ui.Field::new()
  let sent = []
  let escaped = Ref(0)
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索" }, submitted=fn(w) { sent.push(w) }, escape=fn() {
      escaped.val += 1
      true
    })
    |> ignore
  })
  let (x, y, w, h) = t.get(TextField, label="搜索").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.type_text("归档")
  t.key_named("enter") |> ignore
  t.key_named("escape") |> ignore
  assert_eq((sent, escaped.val), (["归档"], 1))
}
