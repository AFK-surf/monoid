// The library's address (address_bar_node, address_field_node): where the page is while nobody writes there; pressed
// into, all of it picked; Escape gives the writing up, the page's address again; Enter goes to what is written.

///|
/// A browser's row at the top of a window with keyboard and mouse, the page at `url`, what Enter went to put in `went`.
fn address_case(url : @signals.Signal[String], field : @ui.Field, went : Array[String]) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    address_bar_node(
      root,
      field,
      fn() { url.get() },
      fn(to) {
        went.push(to)
        url.set(to)
      },
      fn() { "地址" },
      fn() {  },
      fn() {  },
      fn() {  },
    )
    |> ignore
  })
  t.draw()
  t
}

///|
test "an address: it follows the page; pressed into, all of it picked; Escape gives the writing up, the page's address in it again" {
  let url = @signals.signal("https://a.example/one")
  let field = @ui.Field::new()
  let went = []
  let t = address_case(url, field, went)
  assert_eq(field.text(), "https://a.example/one")
  url.set("https://a.example/two")
  t.draw()
  assert_eq(field.text(), "https://a.example/two")
  t.click(TextField, label="地址")
  t.draw()
  assert_true(field.focused())
  assert_eq(field.selection(), (0, "https://a.example/two".length()))
  t.type_text("b.example")
  t.draw()
  assert_eq(field.text(), "b.example")
  // (written in, the page's own change waits for the writing to end)
  url.set("https://a.example/three")
  t.draw()
  assert_eq(field.text(), "b.example")
  t.key(@ui.key_escape)
  t.draw()
  assert_eq((field.focused(), field.text(), went.length()), (false, "https://a.example/three", 0))
}

///|
test "an address: Enter goes to what is written, the field let go" {
  let url = @signals.signal("https://a.example/")
  let field = @ui.Field::new()
  let went = []
  let t = address_case(url, field, went)
  t.click(TextField, label="地址")
  t.draw()
  t.type_text("  b.example/x ")
  t.enter()
  t.draw()
  assert_eq((went, field.focused(), field.text()), (["b.example/x"], false, "b.example/x"))
}
