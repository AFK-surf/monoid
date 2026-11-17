// The bar as nodes (nav_bar_node): back only where it says where to. With nowhere back (a folder's page in a pane beside
// its list on 中屏: files_page_node's narrow_folder_node, its frame's back None) it has none: no chevron saying nothing,
// pressed to go nowhere, unnamed to a screen reader (Tester::hold_named stopped every frame of it, switches_still's
// 中屏 drive and the player's pages, main 2026-11-17).

///|
test "nav bar node: back where it says where to; with nowhere back, no back at all and nothing unnamed to press; the title where it was" {
  let back = @signals.signal("文件")
  let t = @ui.Tester::new(fn(_) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) { nav_bar_node(root, fn() { back.get() }, fn() { "文档" }, fn() {  }) })
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Link, label="文件") is Some(_))
  let title = t.locate("文档")
  @ui.view_tree().unwrap().event(t.time(), fn() { back.set("") })
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Link) is None)
  assert_true(t.find("文件") is None)
  assert_eq(t.locate("文档"), title)
  // (somewhere to go again: back as it was)
  @ui.view_tree().unwrap().event(t.time(), fn() { back.set("文件") })
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Link, label="文件") is Some(_))
}
