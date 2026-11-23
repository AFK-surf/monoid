// Wave 5 regression tests: verify app-level fullscreen overlays (viz_page, tab_full_node, publish, viewer_tree)
// register on the unified `@headless.overlays_open(tree)` stack and preserve Escape / Back dismiss semantics.

///|
fn w5_overlays_open() -> Int {
  match @ui.view_tree() {
    Some(tree) => @headless.overlays_open(tree)
    None => 0
  }
}

///|
test "W5-M: viz_full_shown registers on @headless.overlays_open and dismisses on Escape and Back" {
  new_run()
  let src = fixture("chat-viz")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=1)
  t.run_for(@ui.move_most_ms)
  let base = w5_overlays_open()
  // Escape dismiss
  viz_open_full("release.html", "ws1/st1", "s-c1", "work/s-c1/release.html", "s-c1")
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viz_full.get() is Some(_))
  assert_eq(w5_overlays_open(), base + 1)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viz_full.get() is None)
  assert_eq(w5_overlays_open(), base)
  // Back dismiss
  viz_open_full("release.html", "ws1/st1", "s-c1", "work/s-c1/release.html", "s-c1")
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_eq(w5_overlays_open(), base + 1)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viz_full.get() is None)
  assert_eq(w5_overlays_open(), base)
}

///|
test "W5-M: tab_full_node registers on @headless.overlays_open and dismisses on Escape and Back" {
  new_run()
  let src = fixture("chat-viz")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let base = w5_overlays_open()
  // Escape dismiss
  viz_open_full("release.html", "ws1/st1", "s-c1", "work/s-c1/release.html", "s-c1")
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is Some(_))
  assert_eq(w5_overlays_open(), base + 1)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_eq(w5_overlays_open(), base)
  // Back dismiss
  viz_open_full("release.html", "ws1/st1", "s-c1", "work/s-c1/release.html", "s-c1")
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_eq(w5_overlays_open(), base + 1)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_eq(w5_overlays_open(), base)
}

///|
test "W5-M: publish_layer_node registers on @headless.overlays_open and dismisses on Escape and Back" {
  new_run()
  let src = fixture("chat-viz")
  let r : @sfbase.ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let base = w5_overlays_open()
  let preview : Json = { "title": "整理发布清单", "list": [] }
  // Escape dismiss
  @sfpages.publish_set(r, 7.0, preview)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.publish_open())
  assert_eq(w5_overlays_open(), base + 1)
  t.key(@ui.key_escape)
  t.run_for(@motion.dialog_out_ms + 50.0)
  assert_false(@sfpages.publish_open())
  assert_eq(w5_overlays_open(), base)
  // Back dismiss
  @sfpages.publish_set(r, 7.0, preview)
  t.run_for(@ui.move_most_ms)
  assert_eq(w5_overlays_open(), base + 1)
  t.back()
  t.run_for(@motion.dialog_out_ms + 50.0)
  assert_false(@sfpages.publish_open())
  assert_eq(w5_overlays_open(), base)
}
