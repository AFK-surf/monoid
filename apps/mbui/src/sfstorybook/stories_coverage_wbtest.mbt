// The stories of the overlays, the controls and what shows data (stories_overlays.mbt, stories_controls.mbt,
// stories_display.mbt) in a Tester: each part's page held to every rule (Tester::audit) at 小屏's width and a wide
// window's, and what its first state opens opened and held to them too.

///|
/// The keys of the parts these stories add, in their order.
fn coverage_keys() -> Array[String] {
  let tips = @sf.TipLayer::new(fn() { None })
  (stories_wave1(tips) + stories_wave2(tips) + stories_wave3(tips)).map(fn(s) { s.key })
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
    ("panel-parts", "面板设置"),
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

///|
test "wave2 chip-tabs, steps and segmented interactions stay clean at 390 and 1280" {
  for w in [390.0, 1280.0] {
    let t = coverage_tester("chip-tabs", w)
    t.click(Tab, label="待处理")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("当前分组：待处理") is Some(_), msg="chip-tabs switched at \{w}")
    let chip_faults = page_faults(t)
    assert_true(chip_faults.is_empty(), msg="chip-tabs at \{w}: " + chip_faults.join("\n"))

    let ts = coverage_tester("steps", w)
    ts.click(Button, label="下一步")
    ts.run_for(@ui.move_most_ms)
    assert_true(ts.find("当前第 3 / 3 步") is Some(_), msg="steps advanced at \{w}")
    let step_faults = page_faults(ts)
    assert_true(step_faults.is_empty(), msg="steps at \{w}: " + step_faults.join("\n"))

    let tg = coverage_tester("segmented", w)
    tg.click(Radio, label="未读")
    tg.run_for(@ui.move_most_ms)
    assert_true(tg.find("当前筛选：未读") is Some(_), msg="segmented switched at \{w}")
    let seg_faults = page_faults(tg)
    assert_true(seg_faults.is_empty(), msg="segmented at \{w}: " + seg_faults.join("\n"))
  }
}

///|
test "wave3 overlays (hover-panel, beside-panel, confirm-dialog, ask-dialog) open, act, close and stay clean at 390 and 1280" {
  for w in [390.0, 1280.0] {
    // 1. hover-panel: open -> audit -> close -> audit
    let th = coverage_tester("hover-panel", w)
    th.click(Button, label="查看工作站队列")
    th.run_for(@ui.move_most_ms)
    assert_true(th.find("队列状态") is Some(_), msg="hover-panel opened at \{w}")
    let th_open = page_faults(th)
    assert_true(th_open.is_empty(), msg="hover-panel open at \{w}: " + th_open.join("\n"))
    th.click(Button, label="关闭面板")
    th.run_for(@ui.move_most_ms)
    assert_true(th.find("队列状态") is None, msg="hover-panel closed at \{w}")
    assert_true(th.find("已关闭悬停面板") is Some(_), msg="hover-panel status updated at \{w}")
    let th_closed = page_faults(th)
    assert_true(th_closed.is_empty(), msg="hover-panel closed at \{w}: " + th_closed.join("\n"))

    // 2. beside-panel: open -> audit -> close -> audit
    let tb = coverage_tester("beside-panel", w)
    tb.click(Button, label="自定义侧边栏")
    tb.run_for(@ui.move_most_ms)
    assert_true(tb.find("紧凑列表密度") is Some(_), msg="beside-panel opened at \{w}")
    let tb_open = page_faults(tb)
    assert_true(tb_open.is_empty(), msg="beside-panel open at \{w}: " + tb_open.join("\n"))
    tb.click(Button, label="完成设置")
    tb.run_for(@ui.move_most_ms)
    assert_true(tb.find("紧凑列表密度") is None, msg="beside-panel closed at \{w}")
    assert_true(tb.find("已保存侧边栏设置") is Some(_), msg="beside-panel status updated at \{w}")
    let tb_closed = page_faults(tb)
    assert_true(tb_closed.is_empty(), msg="beside-panel closed at \{w}: " + tb_closed.join("\n"))

    // 3. confirm-dialog: standard confirm & danger confirm with warning
    let tc = coverage_tester("confirm-dialog", w)
    tc.click(Button, label="打开普通确认")
    tc.run_for(@ui.move_most_ms)
    assert_true(tc.find("归档选中对话？") is Some(_), msg="confirm-dialog standard opened at \{w}")
    let tc_std = page_faults(tc)
    assert_true(tc_std.is_empty(), msg="confirm-dialog standard at \{w}: " + tc_std.join("\n"))
    tc.click(Button, label="确认归档")
    tc.run_for(@ui.move_most_ms)
    assert_true(tc.find("归档选中对话？") is None, msg="confirm-dialog standard closed at \{w}")
    assert_true(tc.find("状态：已归档对话") is Some(_), msg="confirm-dialog standard confirmed at \{w}")
    tc.click(Button, label="打开危险确认")
    tc.run_for(@ui.move_most_ms)
    assert_true(tc.find("清除本地构建缓存？") is Some(_), msg="confirm-dialog danger opened at \{w}")
    assert_true(tc.find("此操作不可撤销，请确认没有进行中的任务。") is Some(_), msg="confirm-dialog warning shown at \{w}")
    let tc_danger = page_faults(tc)
    assert_true(tc_danger.is_empty(), msg="confirm-dialog danger at \{w}: " + tc_danger.join("\n"))
    tc.click(Button, label="取消")
    tc.run_for(@ui.move_most_ms)
    assert_true(tc.find("清除本地构建缓存？") is None, msg="confirm-dialog danger closed at \{w}")
    assert_true(tc.find("状态：已取消清除") is Some(_), msg="confirm-dialog danger cancelled at \{w}")
    let tc_after = page_faults(tc)
    assert_true(tc_after.is_empty(), msg="confirm-dialog after close at \{w}: " + tc_after.join("\n"))

    // 4. ask-dialog: open -> audit -> type -> submit -> audit
    let ta = coverage_tester("ask-dialog", w)
    ta.click(Button, label="修改工作区名")
    ta.run_for(@ui.move_most_ms)
    assert_true(ta.find("修改工作区名称") is Some(_), msg="ask-dialog opened at \{w}")
    let ta_open = page_faults(ta)
    assert_true(ta_open.is_empty(), msg="ask-dialog open at \{w}: " + ta_open.join("\n"))
    ta.type_text("-v3")
    ta.run_for(@ui.move_most_ms)
    ta.click(Button, label="保存名称")
    ta.run_for(@ui.move_most_ms)
    assert_true(ta.find("修改工作区名称") is None, msg="ask-dialog closed at \{w}")
    assert_true(ta.find("当前名称：sfstorybook-v3 · 令牌：未配置") is Some(_), msg="ask-dialog submitted at \{w}")
    let ta_after = page_faults(ta)
    assert_true(ta_after.is_empty(), msg="ask-dialog after submit at \{w}: " + ta_after.join("\n"))
  }
}

///|
test "wave3 detail-page, count-section, capsule-words-button and quota-chips-actions interactions stay clean at 390 and 1280" {
  for w in [390.0, 1280.0] {
    let td = coverage_tester("detail-page", w)
    td.click(Button, label="切换加载骨架")
    td.run_for(@ui.move_most_ms)
    assert_true(td.find("显示正文") is Some(_), msg="detail-page toggled loading at \{w}")
    let td_load = page_faults(td)
    assert_true(td_load.is_empty(), msg="detail-page loading at \{w}: " + td_load.join("\n"))
    td.click(Button, label="显示正文")
    td.run_for(@ui.move_most_ms)
    assert_true(td.find("pvg-office-2 · x64 Linux · 8 核") is Some(_), msg="detail-page body restored at \{w}")
    let td_body = page_faults(td)
    assert_true(td_body.is_empty(), msg="detail-page body at \{w}: " + td_body.join("\n"))

    let tcs = coverage_tester("count-section", w)
    tcs.click(Button, label="新增一项")
    tcs.run_for(@ui.move_most_ms)
    assert_true(tcs.find("当前有 4 项来自工作站的待确认操作。") is Some(_), msg="count-section incremented at \{w}")
    let tcs_faults = page_faults(tcs)
    assert_true(tcs_faults.is_empty(), msg="count-section at \{w}: " + tcs_faults.join("\n"))

    let tcw = coverage_tester("capsule-words-button", w)
    tcw.click(Button, label="切换缩放比例")
    tcw.run_for(@ui.move_most_ms)
    assert_true(tcw.find("当前：125% · 60 fps") is Some(_), msg="capsule-words-button cycled zoom at \{w}")
    let tcw_faults = page_faults(tcw)
    assert_true(tcw_faults.is_empty(), msg="capsule-words-button at \{w}: " + tcw_faults.join("\n"))

    let tq = coverage_tester("quota-chips-actions", w)
    tq.click(Button, label="更多动作")
    tq.run_for(@ui.move_most_ms)
    assert_true(tq.find("复制工作站 ID") is Some(_), msg="quota-chips-actions menu opened at \{w}")
    let tq_faults = page_faults(tq)
    assert_true(tq_faults.is_empty(), msg="quota-chips-actions menu at \{w}: " + tq_faults.join("\n"))

    let tdt = coverage_tester("data-table", w)
    tdt.click(Button, label="按 剩余额度 排序")
    tdt.run_for(@ui.move_most_ms)
    assert_true(tdt.query(ColumnHeader, label="剩余额度, 升序") is Some(_), msg="data-table sorted at \{w}")
    tdt.click(Button, label="显示空态")
    tdt.run_for(@ui.move_most_ms)
    assert_true(tdt.find("没有匹配的工作站") is Some(_), msg="data-table empty state shown at \{w}")
    let tdt_faults = page_faults(tdt)
    assert_true(tdt_faults.is_empty(), msg="data-table at \{w}: " + tdt_faults.join("\n"))
  }
}
