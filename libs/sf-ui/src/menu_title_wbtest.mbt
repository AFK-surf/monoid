// A menu's title over its rows, drawn only where a heading of its own is not first (two headings one over the other
// read as one more of them), still its name to a screen reader either way.

///|
/// A window with a menu titled 远程 holding `items`, open.
fn titled_menu_tester(items : Array[MenuItem?]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.padding(Is((100.0, 100.0, 0.0, 0.0))) |> ignore
    let opener = root.box(fn(o) {
      o.width(Is(Some(120.0))).height(Is(Some(36.0))).says(Is(Some(@view.said(Button, label="开")))) |> ignore
    })
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node(l, fn() { true }, fn(_) { opener }, fn() { items }, "远程", Start, 8.0, false, false, fn(_) {  }, fn() {  })
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a menu's title: over a heading of its own first, not drawn; over a row, drawn; its name either way" {
  let row = Some(menu_item_of("Willow 的桌面", fn() {  }, icon="monitor"))
  let headed = titled_menu_tester([Some(menu_item_of("屏幕", fn() {  }, heading=true)), row])
  assert_eq((headed.find("远程") is None, headed.find("屏幕") is Some(_)), (true, true))
  assert_true(headed.query(Menu, label="远程") is Some(_))
  let plain = titled_menu_tester([row])
  assert_true(plain.find("远程") is Some(_))
}
