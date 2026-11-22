// The 11 motion library showcase stories (stories_motion.mbt) in a Tester:
// every page passes Tester::audit() at 390 and 1280 width and at 1.0x and 1.3x font scale,
// and core interactive controls across all 11 pages work cleanly.

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
    "motion-morph",
    "motion-physics",
    "motion-choreography",
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
test "all 11 motion stories pass audit at 390 and 1280 width and 1.0 and 1.3 scale" {
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

///|
test "motion-press: HoldButton with undo confirms and undoes cleanly" {
  let t = motion_tester("motion-press", 1280.0, h=1800.0)
  let b = t.get(Button, label="长按清除缓存").rect
  let (cx, cy) = (b.0 + b.2 / 2.0, b.1 + b.3 / 2.0)
  t.press_at(cx, cy)
  t.run_for(@ui.move_most_ms * 2.0)
  t.release(cx, cy)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("撤销") is Some(_), msg="hold_button entered undo window")
  t.click(Button, label="撤销")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("已撤销清除操作（确认 1 / 撤销 1）") is Some(_), msg="hold_button undo triggered")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-controls: Accordion expands and collapses sections cleanly" {
  let t = motion_tester("motion-controls", 1280.0, h=1800.0)
  t.click(Button, label="首行箭头旋转与平滑展开")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("当前展开：首行箭头旋转与平滑展开") is Some(_), msg="accordion expanded first section")
  t.click(Button, label="软边裁剪与退场释放点击")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("当前展开：软边裁剪与退场释放点击") is Some(_), msg="accordion switched to second section")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-reveal: CurtainReveal replays and unmounts cleanly at rest" {
  let t = motion_tester("motion-reveal", 1280.0, h=1800.0)
  t.click(Button, label="重播窗帘揭幕")
  t.run_for(@sfbase.viz_reveal_ms + @ui.move_most_ms)
  assert_true(t.find("已重播 1 次") is Some(_), msg="curtain_reveal replayed")
  assert_true(t.at_rest(), msg="curtain_reveal at rest after completion")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-morph: TextMorph, RollingSlots, and button reshape run cleanly" {
  let t = motion_tester("motion-morph", 1280.0, h=1400.0)
  t.click(Button, label="切换状态文案")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("并行校验 270 项多帧率单测") is Some(_), msg="TextMorph switched to second line")
  t.click(Button, label="+128")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="-45")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="保存")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("正在写入配置…") is Some(_), msg="button reshaped to busy state")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-physics: EdgePull, SpringFollow2D, and DismissDrag run cleanly" {
  let t = motion_tester("motion-physics", 1280.0, h=1600.0)
  t.click(Button, label="模拟右拉过界")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="松手回弹")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="左锚点")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="右锚点")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="轻拉回弹")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="快甩关闭")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="恢复卡片")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("已恢复卡片") is Some(_), msg="dismiss card restored")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "motion-choreography: hero_flight_box, Choreography, and SerialQueue run cleanly" {
  let t = motion_tester("motion-choreography", 1280.0, h=1600.0)
  t.click(Button, label="展开全屏")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("飞回原位") is Some(_), msg="hero expanded")
  t.click(Button, label="切换 Letterbox")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="飞回原位")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("展开全屏") is Some(_), msg="hero returned")
  t.click(Button, label="播放四段编排")
  t.run_for(@ui.move_most_ms * 3.0)
  t.click(Button, label="逆向回放")
  t.run_for(@ui.move_most_ms * 3.0)
  t.click(Button, label="触发多源错峰")
  t.run_for(@ui.move_most_ms * 3.0)
  assert_true(t.find("错峰启动：+0 / +200 / +400 ms") is Some(_), msg="serial queue staggered 3 sources")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}
