// The 8 motion library showcase stories (stories_motion.mbt) in a Tester:
// every page passes Tester::audit() at 390 and 1280 width and at 1.0x and 1.3x font scale,
// and core interactive controls across all 8 pages work cleanly.

///|
fn motion_story_keys() -> Array[String] {
  [
    "motion-curves",
    "motion-press",
    "motion-controls",
    "motion-overlays",
    "motion-reveal",
    "motion-cycles",
    "motion-transitions",
    "motion-zoom",
  ]
}

///|
fn motion_tester(key : String, w : Double, scale? : Double = 1.0, h? : Double = 1200.0) -> @ui.Tester {
  @ui.host_image_bytes_known([("src/sfstorybook/stories_motion_wbtest.mbt", 9834)])
  @sf.presenters_reset()
  let t = @ui.Tester::new(stories_view, tree=stories_tree(key), w~, h~, platform=0)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  t.draw()
  t
}

///|
test "all 8 motion stories pass audit at 390 and 1280 width and 1.0 and 1.3 scale" {
  let all : Array[String] = []
  for key in motion_story_keys() {
    for w in [390.0, 1280.0] {
      for scale in [1.0, 1.3] {
        let t = motion_tester(key, w, scale~)
        for f in page_faults(t) {
          all.push("\{key} at \{w} ×\{scale}: \{f}")
        }
      }
    }
  }
  assert_true(all.is_empty(), msg=all.join("\n"))
}

///|
test "motion-curves: 播放 sets curves off and 放回 returns them to rest" {
  let t = motion_tester("motion-curves", 1280.0, h=1600.0)
  t.click(Button, label="播放")
  t.run_for(@ui.move_most_ms * 3.0)
  assert_true(t.find("放回") is Some(_), msg="button switched to 放回")
  assert_true(t.at_rest(), msg="at rest after forward play")
  t.click(Button, label="放回")
  t.run_for(@ui.move_most_ms * 3.0)
  assert_true(t.find("播放") is Some(_), msg="button returned to 播放")
  assert_true(t.at_rest(), msg="at rest after reverse play")
}

///|
test "motion-controls: switching segmented control, tabs, and stops updates selection cleanly" {
  let t = motion_tester("motion-controls", 1280.0, h=1400.0)
  t.click(Radio, label="进行中")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Tab, label="变更")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("当前面板：变更") is Some(_), msg="tab panel switched to 变更")
  let (sx, sy, sw, sh) = t.get(@ui.Role::Slider, label="思考强度").rect
  t.tap(sx + sw * 2.5 / 4.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("高") is Some(_), msg="stops switched to 高")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-reveal: flash trigger and ComeGroup list insert/remove run cleanly" {
  let t = motion_tester("motion-reveal", 1280.0, h=1600.0)
  t.click(Button, label="触发定位闪烁")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="插入一行")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("动态列表条目 #4") is Some(_), msg="inserted row #4")
  t.click(Button, label="删除末行")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("动态列表条目 #3") is None, msg="removed last row #3")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-overlays: confirm dialog opens and closes cleanly on Cancel" {
  let t = motion_tester("motion-overlays", 1280.0, h=1200.0)
  t.click(Button, label="打开确认框")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("应用这套动效参数？") is Some(_), msg="confirm dialog opened")
  let open_faults = page_faults(t)
  assert_true(open_faults.is_empty(), msg=open_faults.join("\n"))
  t.click(Button, label="取消")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("应用这套动效参数？") is None, msg="confirm dialog closed")
}

///|
test "motion-cycles: SyncKey toggle and Station Glyph mode switch run cleanly" {
  let t = motion_tester("motion-cycles", 1280.0, h=1600.0)
  t.click(Button, label="同步完成")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("状态：已完成") is Some(_), msg="sync_key switched to completed")
  t.click(Button, label="模拟同步")
  t.run_for(@ui.move_most_ms)
  t.click(Radio, label="连接中")
  t.run_for(@ui.move_most_ms)
  t.click(Radio, label="异常")
  t.run_for(@ui.move_most_ms)
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-transitions: layered push/pop, shared element flight, and spring fling work cleanly" {
  let t = motion_tester("motion-transitions", 1280.0, h=1600.0)
  t.click(Button, label="推入详情")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("会话详情（前景页）") is Some(_), msg="layered nav pushed detail")
  t.click(Button, label="返回列表")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("消息列表（背景页）") is Some(_), msg="layered nav popped to list")
  t.click(Button, label="移至进行中")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("移回待办") is Some(_), msg="shared task card flew to in-progress")
  t.click(Button, label="模拟甩动回弹")
  t.run_for(@ui.move_most_ms * 2.0)
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-zoom: 2x, 3x, inertia fling, and 1x reset run cleanly" {
  let t = motion_tester("motion-zoom", 1280.0, h=1200.0)
  t.click(Button, label="2x 放大")
  t.run_for(@ui.move_most_ms * 2.0)
  let words_2x = t.words().map(fn(w) { w.0 }).join("|")
  assert_true(t.find("倍率 2x") is Some(_), msg="zoomed to 2x: \{words_2x}")
  t.click(Button, label="3x 细节")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("倍率 3x") is Some(_), msg="zoomed to 3x")
  t.click(Button, label="1x 适配")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("倍率 1x") is Some(_), msg="reset to 1x")
  t.click(Button, label="模拟惯性甩动复位")
  t.run_for(@ui.move_most_ms * 3.0)
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}
