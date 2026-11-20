// The stories of the overlays, the controls and what shows data (stories_overlays.mbt, stories_controls.mbt,
// stories_display.mbt) in a Tester: each part's page held to every rule (Tester::audit) at 小屏's width and a wide
// window's, and what its first state opens opened and held to them too.

///|
/// The keys of the parts these stories add, in their order.
fn coverage_keys() -> Array[String] {
  let tips = @sf.TipLayer::new(fn() { None })
  stories_wave1(tips).map(fn(s) { s.key })
}

///|
/// The page opened on `key`, `w` wide and 844 high, pointed at with a mouse (foundations_wbtest's story_tester, made
/// here: what its host holds of pictures handed over is this file's, under its own bar).
fn coverage_tester(key : String, w : Double) -> @ui.Tester {
  // (the pictures these parts draw: a notice's app icon and the like, at most this much at once)
  @ui.host_image_bytes_known([("src/sfstorybook/stories_coverage_wbtest.mbt", 9834)])
  @sf.presenters_reset()
  let t = @ui.Tester::new(stories_view, tree=stories_tree(key), w~, h=844.0, platform=0)
  t.draw()
  t
}

///|
test "each part of the overlays, the controls and the data shows keeps every rule at 390 and 1280" {
  let all : Array[String] = []
  for key in coverage_keys() {
    for w in [390.0, 1280.0] {
      let t = coverage_tester(key, w)
      for f in page_faults(t) {
        all.push("\{key} at \{w}: \{f}")
      }
    }
  }
  assert_true(all.is_empty(), msg=all.join("\n"))
}

///|
test "each part's key is its own" {
  let keys = coverage_keys()
  let tips = @sf.TipLayer::new(fn() { None })
  let all = foundations() + stories(tips)
  for key in keys {
    assert_eq(all.filter(fn(s) { s.key == key }).length(), 1, msg=key)
  }
}

///|
test "what the overlays' stories open keeps every rule, at 390 and 1280" {
  let opens = [
    ("menu", "更多操作"),
    ("menu", "排序"),
    ("confirm", "删除工作站"),
    ("sheet", "选择工作站"),
    ("ask", "重命名"),
    ("panel", "工作站概况"),
    ("panel", "添加账号"),
    ("controls-pick", "选择模型"),
  ]
  let all : Array[String] = []
  for o in opens {
    let (key, button) = o
    for w in [390.0, 1280.0] {
      let t = coverage_tester(key, w)
      t.click(Button, label=button)
      t.run_for(@ui.move_most_ms)
      for f in page_faults(t) {
        all.push("\{key} › \{button} at \{w}: \{f}")
      }
    }
  }
  assert_true(all.is_empty(), msg=all.join("\n"))
}

///|
test "a toast pressed into the story's toaster shows, and its 撤销 says so and takes it away" {
  let t = coverage_tester("toast", 1280.0)
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("已归档 1 个对话") is Some(_), msg="the toast shows")
  t.click(Button, label="撤销")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("已撤销（story-1）") is Some(_), msg="its action said")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}
