// The library's finding in a page (page_find_node): where it has its field, Enter the next one and Escape lets the
// find go; what it says of where the reader is shown only while it says something; the one before and after pressed
// only while there is one, each an icon button named for it; the find let go by its close key.

///|
/// A find in a page 360 wide at the window's top, with a field where `field` is given; what it was asked told in `did`.
fn page_find_case(did : Array[String], field? : @ui.Field, said? : () -> String = fn() { "2/5" }) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=200.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(360.0))) |> ignore
      page_find_node(
        b,
        said,
        fn(d) { did.push("step \{d}") },
        fn(d) { d > 0 },
        fn() { did.push("close") },
        field?,
        placeholder_by=fn() { "查找" },
        prev_label=fn() { "上一个" },
        next_label=fn() { "下一个" },
        close_label=fn() { "关闭查找" },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "page_find_node: its keys, the one before not pressed where there is none; pressed, the next and the find let go" {
  let did = []
  let t = page_find_case(did)
  let prev_off = t.get(Button, label="上一个").disabled
  let (nx, ny, nw, nh) = t.get(Button, label="下一个").rect
  t.tap(nx + nw / 2.0, ny + nh / 2.0)
  let (cx, cy, cw, ch) = t.get(Button, label="关闭查找").rect
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  assert_eq((prev_off, t.find("2/5") is Some(_), did), (true, true, ["step 1", "close"]))
}

///|
test "page_find_node with its field: Enter the next one, Escape lets the find go; nothing said, nothing shown" {
  let did = []
  let f = @ui.Field::new()
  let t = page_find_case(did, field=f, said=fn() { "" })
  let (x, y, w, h) = t.get(TextField, label="查找").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.type_text("abc")
  t.key_named("enter") |> ignore
  t.key_named("escape") |> ignore
  assert_eq((f.text(), did), ("abc", ["step 1", "close"]))
}
