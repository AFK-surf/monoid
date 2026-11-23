// A panel whose body and foot are nodes of the window's tree (@sf.panel_nodes): laid out where they were when the old
// frame's body and foot of the same panel stood beside them (beside what opened it, and in the middle of the window),
// drawn by the tree, closed by what it is given and by Escape.

///|
/// Where a box of `color` is drawn (its rect: x, y, width, height), the one there is.
fn painted_at(t : @ui.Tester, color : Int64) -> (Double, Double, Double, Double) raise {
  let found = t.drawn_rects().filter(fn(r) { r.4 >> 8 == color >> 8 })
  assert_eq(found.length(), 1, msg="one box of \{color}")
  // (to a thousandth of a point: what one layout sums another way, never seen)
  let near = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  (near(found[0].0), near(found[0].1), near(found[0].2), near(found[0].3))
}

///|
let body_ink : Int64 = 0x23A1DFFFL

///|
let foot_ink : Int64 = 0xB45A29FFL

///|
/// The test's boxes' corner: concentric where they stand in a dialog's corner, 24 in from its 42 (the corner rule's).
let ink_corner : Double = 18.0

///|
/// A box `w` by `h` of `ink`, as a node in `v`.
fn ink_node(v : @view.View, w : Double, h : Double, ink : Int64) -> Unit {
  v.box(fn(b) { b.width(Is(Some(w))).height(Is(Some(h))).ground(Is(ink)).radius(Is(ink_corner)) |> ignore }) |> ignore
}

///|
/// A foot capsule `w` by `button_height()` of `ink`, as a node in `v`.
fn foot_ink_node(v : @view.View, w : Double, ink : Int64) -> Unit {
  let h = @sf.button_height()
  v.box(fn(b) { b.width(Is(Some(w))).height(Is(Some(h))).ground(Is(ink)).radius(Is(h / 2.0)) |> ignore }) |> ignore
}

///|
/// Where the body's and the foot's boxes are drawn once the panel is in, and its head's words and its close button,
/// then closed by Escape and gone.
fn body_and_foot(
  t : @ui.Tester,
  close? : Bool = false,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double), Array[String], String) raise {
  t.run_for(@ui.move_most_ms)
  // (in any order: as the tree draws them)
  let words = t.words().map(fn(w) { "\{w.0} \{@ui.rect_text(tenth4((w.1, w.2, w.3, w.4)))}" })
  words.sort()
  // (its close button where it has one: asked of what is read out only where asked, `close`)
  let close = if close { t.query(Button, label=@sf.t("common.close")).map(fn(b) { tenth4(b.rect) }) } else { None }
  let at = (painted_at(t, body_ink), painted_at(t, foot_ink), words, "\{@ui.some_text(close.map(@ui.rect_text))}")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_false(@sf.presenter_visible(), msg="gone")
  at
}

///|
test "大屏: a panel beside what opened it whose body and foot are nodes: each where it was beside the old frame's body and foot of the same panel" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", from=At(600.0, 300.0, 0.0, 0.0), foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
  })
  debug_inspect(body_and_foot(t), content=(
    #|(
    #|  (606, 342, 40, 36),
    #|  (828, 386, 60, 32),
    #|  [
    #|    "A (532, 18, 4, 8)",
    #|    "A (241, 435, 4, 8)",
    #|    "A (268, 175, 4, 8)",
    #|    "周 (266, 435, 8, 8)",
    #|    "林 (252, 175, 8, 8)",
    #|    "林 (253, 435, 8, 8)",
    #|    "今天 (66, 65, 212, 18)",
    #|    "+2 (264, 633, 12, 18)",
    #|    "个 (20.5, 719, 13, 20)",
    #|    "你 (516.5, 16, 11, 12)",
    #|    "待处理 (66, 173, 36, 18)",
    #|    "星 (20.5, 683, 13, 20)",
    #|    "昨天 (66, 381, 212, 18)",
    #|    "新建对话 (90, 17, 152, 20)",
    #|    "星期三 (66, 585, 212, 18)",
    #|    "面板 (622, 318, 252, 20)",
    #|    "发消息 (402, 710, 772, 22)",
    #|    "忽略 (408, 241.6, 24, 18)",
    #|    "周报的模板 (82, 671, 174, 20)",
    #|    "搜索全部内容 (90, 19, 188, 20)",
    #|    "整理发布清单 (408, 12, 96, 20)",
    #|    "整理发布清单 (82, 95, 174, 20)",
    #|    "Willow (420, 664, 36, 18)",
    #|    "一起换 (454, 181.6, 396, 20)",
    #|    "先不换 (454, 127.6, 396, 20)",
    #|    "5 分钟前 (450, 529.7, 44, 18)",
    #|    "Claude (408, 35.5, 36, 18)",
    #|    "等 林 决定 (408, 87.6, 60, 18)",
    #|    "Claude (408, 358.6, 36, 18)",
    #|    "Claude (408, 529.7, 36, 18)",
    #|    "Claude (494.5, 664, 36, 18)",
    #|    "迁移数据库的演练 (66, 615, 168, 20)",
    #|    "30 分钟前 (450, 35.5, 49.5, 18)",
    #|    "夜里的构建又失败了 (82, 207, 174, 20)",
    #|    "15 分钟前 (450, 358.6, 49.5, 18)",
    #|    "把旧的截图都换成新的 (66, 523, 190, 20)",
    #|    "开关和三处颜色都改好了 (82, 285, 132, 18)",
    #|    "盯着 CI，绿了告诉我 (66, 319, 190, 20)",
    #|    "首页的列表改成按天分组 (82, 151, 174, 20)",
    #|    "等你在浏览器里登录 (426, 456.7, 108, 18)",
    #|    "Slack 里问的报销流程 (66, 467, 168, 20)",
    #|    "模板放在共享文件夹的第一层 (66, 693, 188, 18)",
    #|    "给设置页加一个深色模式开关 (82, 263, 174, 20)",
    #|    "已经把三个步骤整理成一页文档 (66, 489, 188, 18)",
    #|    "正在核对第三项：安装包的签名 (66, 117, 168, 18)",
    #|    "和 Ana 一起看新版的引导页 (66, 411, 190, 20)",
    #|    "Ana：第二屏的插画可以再小一点 (66, 433, 137, 18)",
    #|    "把首页和聊天页的截图都更新 (454, 201.6, 396, 18)",
    #|    "这次只改列表，截图下次再说 (454, 147.6, 396, 18)",
    #|    "演练到第二步时 Maple 断开了 (66, 637, 132, 18)",
    #|    "在 Willow 上登录 gh (426, 436.7, 324, 18)",
    #|    "推送截图前要先登录 gh。 (408, 383.6, 760, 23.1)",
    #|    "监控中：每 5 分钟看一次主干的构建 (82, 341, 172, 18)",
    #|    "测试机的磁盘满了，要不要清理旧的缓存？ (82, 229, 172, 18)",
    #|    " · 分组的标题用相对日期还是具体日期？ (102, 173, 114, 18)",
    #|    "Willow 上 codex 的登录已失效：请在设置里重新登录 (644, 293.6, 288, 22)",
    #|    "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。 (408, 554.7, 760, 23.1)",
    #|    "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？ (408, 60.5, 760, 23.1)",
    #|  ],
    #|  "None",
    #|)




  ))
}

///|
test "大屏: an untitled panel beside what opened it whose body is nodes, ruled over its foot: each where it was beside the old frame's" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("", from=At(600.0, 300.0, 0.0, 0.0), ruled=true, foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
  })
  debug_inspect(body_and_foot(t), content=(
    #|(
    #|  (606, 312, 40, 36),
    #|  (828, 362.5, 60, 32),
    #|  [
    #|    "A (532, 18, 4, 8)",
    #|    "A (241, 435, 4, 8)",
    #|    "A (268, 175, 4, 8)",
    #|    "周 (266, 435, 8, 8)",
    #|    "林 (252, 175, 8, 8)",
    #|    "林 (253, 435, 8, 8)",
    #|    "今天 (66, 65, 212, 18)",
    #|    "+2 (264, 633, 12, 18)",
    #|    "个 (20.5, 719, 13, 20)",
    #|    "你 (516.5, 16, 11, 12)",
    #|    "待处理 (66, 173, 36, 18)",
    #|    "星 (20.5, 683, 13, 20)",
    #|    "昨天 (66, 381, 212, 18)",
    #|    "新建对话 (90, 17, 152, 20)",
    #|    "星期三 (66, 585, 212, 18)",
    #|    "发消息 (402, 710, 772, 22)",
    #|    "忽略 (408, 241.6, 24, 18)",
    #|    "周报的模板 (82, 671, 174, 20)",
    #|    "搜索全部内容 (90, 19, 188, 20)",
    #|    "整理发布清单 (408, 12, 96, 20)",
    #|    "整理发布清单 (82, 95, 174, 20)",
    #|    "Willow (420, 664, 36, 18)",
    #|    "一起换 (454, 181.6, 396, 20)",
    #|    "先不换 (454, 127.6, 396, 20)",
    #|    "5 分钟前 (450, 529.7, 44, 18)",
    #|    "Claude (408, 35.5, 36, 18)",
    #|    "等 林 决定 (408, 87.6, 60, 18)",
    #|    "Claude (408, 358.6, 36, 18)",
    #|    "Claude (408, 529.7, 36, 18)",
    #|    "Claude (494.5, 664, 36, 18)",
    #|    "迁移数据库的演练 (66, 615, 168, 20)",
    #|    "30 分钟前 (450, 35.5, 49.5, 18)",
    #|    "夜里的构建又失败了 (82, 207, 174, 20)",
    #|    "15 分钟前 (450, 358.6, 49.5, 18)",
    #|    "把旧的截图都换成新的 (66, 523, 190, 20)",
    #|    "开关和三处颜色都改好了 (82, 285, 132, 18)",
    #|    "盯着 CI，绿了告诉我 (66, 319, 190, 20)",
    #|    "首页的列表改成按天分组 (82, 151, 174, 20)",
    #|    "等你在浏览器里登录 (426, 456.7, 108, 18)",
    #|    "Slack 里问的报销流程 (66, 467, 168, 20)",
    #|    "模板放在共享文件夹的第一层 (66, 693, 188, 18)",
    #|    "给设置页加一个深色模式开关 (82, 263, 174, 20)",
    #|    "已经把三个步骤整理成一页文档 (66, 489, 188, 18)",
    #|    "正在核对第三项：安装包的签名 (66, 117, 168, 18)",
    #|    "和 Ana 一起看新版的引导页 (66, 411, 190, 20)",
    #|    "Ana：第二屏的插画可以再小一点 (66, 433, 137, 18)",
    #|    "把首页和聊天页的截图都更新 (454, 201.6, 396, 18)",
    #|    "这次只改列表，截图下次再说 (454, 147.6, 396, 18)",
    #|    "演练到第二步时 Maple 断开了 (66, 637, 132, 18)",
    #|    "在 Willow 上登录 gh (426, 436.7, 324, 18)",
    #|    "推送截图前要先登录 gh。 (408, 383.6, 760, 23.1)",
    #|    "监控中：每 5 分钟看一次主干的构建 (82, 341, 172, 18)",
    #|    "测试机的磁盘满了，要不要清理旧的缓存？ (82, 229, 172, 18)",
    #|    " · 分组的标题用相对日期还是具体日期？ (102, 173, 114, 18)",
    #|    "Willow 上 codex 的登录已失效：请在设置里重新登录 (644, 293.6, 288, 22)",
    #|    "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。 (408, 554.7, 760, 23.1)",
    #|    "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？ (408, 60.5, 760, 23.1)",
    #|  ],
    #|  "None",
    #|)




  ))
}

///|
test "大屏: a panel in the middle of the window whose body and foot are nodes, titled and saying what it is: each where it was beside the old frame's" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("对话框", description="它说的话", from=Unanchored, foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
  })
  debug_inspect(body_and_foot(t, close=true), content=(
    #|(
    #|  (404, 391.5, 40, 36),
    #|  (814, 451.5, 60, 32),
    #|  [
    #|    "A (532, 18, 4, 8)",
    #|    "A (241, 435, 4, 8)",
    #|    "A (268, 175, 4, 8)",
    #|    "周 (266, 435, 8, 8)",
    #|    "林 (252, 175, 8, 8)",
    #|    "林 (253, 435, 8, 8)",
    #|    "今天 (66, 65, 212, 18)",
    #|    "+2 (264, 633, 12, 18)",
    #|    "个 (20.5, 719, 13, 20)",
    #|    "你 (516.5, 16, 11, 12)",
    #|    "待处理 (66, 173, 36, 18)",
    #|    "星 (20.5, 683, 13, 20)",
    #|    "昨天 (66, 381, 212, 18)",
    #|    "新建对话 (90, 17, 152, 20)",
    #|    "星期三 (66, 585, 212, 18)",
    #|    "发消息 (402, 710, 772, 22)",
    #|    "忽略 (408, 241.6, 24, 18)",
    #|    "周报的模板 (82, 671, 174, 20)",
    #|    "对话框 (404, 316.5, 66, 30)",
    #|    "搜索全部内容 (90, 19, 188, 20)",
    #|    "整理发布清单 (408, 12, 96, 20)",
    #|    "整理发布清单 (82, 95, 174, 20)",
    #|    "Willow (420, 664, 36, 18)",
    #|    "一起换 (454, 181.6, 396, 20)",
    #|    "先不换 (454, 127.6, 396, 20)",
    #|    "5 分钟前 (450, 529.7, 44, 18)",
    #|    "Claude (408, 35.5, 36, 18)",
    #|    "它说的话 (404, 353.5, 472, 20)",
    #|    "等 林 决定 (408, 87.6, 60, 18)",
    #|    "Claude (408, 358.6, 36, 18)",
    #|    "Claude (408, 529.7, 36, 18)",
    #|    "Claude (494.5, 664, 36, 18)",
    #|    "迁移数据库的演练 (66, 615, 168, 20)",
    #|    "30 分钟前 (450, 35.5, 49.5, 18)",
    #|    "夜里的构建又失败了 (82, 207, 174, 20)",
    #|    "15 分钟前 (450, 358.6, 49.5, 18)",
    #|    "把旧的截图都换成新的 (66, 523, 190, 20)",
    #|    "开关和三处颜色都改好了 (82, 285, 132, 18)",
    #|    "盯着 CI，绿了告诉我 (66, 319, 190, 20)",
    #|    "首页的列表改成按天分组 (82, 151, 174, 20)",
    #|    "等你在浏览器里登录 (426, 456.7, 108, 18)",
    #|    "Slack 里问的报销流程 (66, 467, 168, 20)",
    #|    "模板放在共享文件夹的第一层 (66, 693, 188, 18)",
    #|    "给设置页加一个深色模式开关 (82, 263, 174, 20)",
    #|    "已经把三个步骤整理成一页文档 (66, 489, 188, 18)",
    #|    "正在核对第三项：安装包的签名 (66, 117, 168, 18)",
    #|    "和 Ana 一起看新版的引导页 (66, 411, 190, 20)",
    #|    "Ana：第二屏的插画可以再小一点 (66, 433, 137, 18)",
    #|    "把首页和聊天页的截图都更新 (454, 201.6, 396, 18)",
    #|    "这次只改列表，截图下次再说 (454, 147.6, 396, 18)",
    #|    "演练到第二步时 Maple 断开了 (66, 637, 132, 18)",
    #|    "在 Willow 上登录 gh (426, 436.7, 324, 18)",
    #|    "推送截图前要先登录 gh。 (408, 383.6, 760, 23.1)",
    #|    "监控中：每 5 分钟看一次主干的构建 (82, 341, 172, 18)",
    #|    "测试机的磁盘满了，要不要清理旧的缓存？ (82, 229, 172, 18)",
    #|    " · 分组的标题用相对日期还是具体日期？ (102, 173, 114, 18)",
    #|    "Willow 上 codex 的登录已失效：请在设置里重新登录 (644, 293.6, 288, 22)",
    #|    "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。 (408, 554.7, 760, 23.1)",
    #|    "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？ (408, 60.5, 760, 23.1)",
    #|  ],
    #|  "Some((842, 316.5, 32, 32))",
    #|)




  ))
}

///|
test "大屏: an untitled form whose body and foot are nodes: each where it was beside the old frame's" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("", from=At(600.0, 300.0, 0.0, 0.0), form=true, foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
  })
  debug_inspect(body_and_foot(t), content=(
    #|(
    #|  (404, 370, 40, 36),
    #|  (814, 430, 60, 32),
    #|  [
    #|    "A (532, 18, 4, 8)",
    #|    "A (241, 435, 4, 8)",
    #|    "A (268, 175, 4, 8)",
    #|    "周 (266, 435, 8, 8)",
    #|    "林 (252, 175, 8, 8)",
    #|    "林 (253, 435, 8, 8)",
    #|    "今天 (66, 65, 212, 18)",
    #|    "+2 (264, 633, 12, 18)",
    #|    "个 (20.5, 719, 13, 20)",
    #|    "你 (516.5, 16, 11, 12)",
    #|    "待处理 (66, 173, 36, 18)",
    #|    "星 (20.5, 683, 13, 20)",
    #|    "昨天 (66, 381, 212, 18)",
    #|    "新建对话 (90, 17, 152, 20)",
    #|    "星期三 (66, 585, 212, 18)",
    #|    "发消息 (402, 710, 772, 22)",
    #|    "忽略 (408, 241.6, 24, 18)",
    #|    "周报的模板 (82, 671, 174, 20)",
    #|    "搜索全部内容 (90, 19, 188, 20)",
    #|    "整理发布清单 (408, 12, 96, 20)",
    #|    "整理发布清单 (82, 95, 174, 20)",
    #|    "Willow (420, 664, 36, 18)",
    #|    "一起换 (454, 181.6, 396, 20)",
    #|    "先不换 (454, 127.6, 396, 20)",
    #|    "5 分钟前 (450, 529.7, 44, 18)",
    #|    "Claude (408, 35.5, 36, 18)",
    #|    "等 林 决定 (408, 87.6, 60, 18)",
    #|    "Claude (408, 358.6, 36, 18)",
    #|    "Claude (408, 529.7, 36, 18)",
    #|    "Claude (494.5, 664, 36, 18)",
    #|    "迁移数据库的演练 (66, 615, 168, 20)",
    #|    "30 分钟前 (450, 35.5, 49.5, 18)",
    #|    "夜里的构建又失败了 (82, 207, 174, 20)",
    #|    "15 分钟前 (450, 358.6, 49.5, 18)",
    #|    "把旧的截图都换成新的 (66, 523, 190, 20)",
    #|    "开关和三处颜色都改好了 (82, 285, 132, 18)",
    #|    "盯着 CI，绿了告诉我 (66, 319, 190, 20)",
    #|    "首页的列表改成按天分组 (82, 151, 174, 20)",
    #|    "等你在浏览器里登录 (426, 456.7, 108, 18)",
    #|    "Slack 里问的报销流程 (66, 467, 168, 20)",
    #|    "模板放在共享文件夹的第一层 (66, 693, 188, 18)",
    #|    "给设置页加一个深色模式开关 (82, 263, 174, 20)",
    #|    "已经把三个步骤整理成一页文档 (66, 489, 188, 18)",
    #|    "正在核对第三项：安装包的签名 (66, 117, 168, 18)",
    #|    "和 Ana 一起看新版的引导页 (66, 411, 190, 20)",
    #|    "Ana：第二屏的插画可以再小一点 (66, 433, 137, 18)",
    #|    "把首页和聊天页的截图都更新 (454, 201.6, 396, 18)",
    #|    "这次只改列表，截图下次再说 (454, 147.6, 396, 18)",
    #|    "演练到第二步时 Maple 断开了 (66, 637, 132, 18)",
    #|    "在 Willow 上登录 gh (426, 436.7, 324, 18)",
    #|    "推送截图前要先登录 gh。 (408, 383.6, 760, 23.1)",
    #|    "监控中：每 5 分钟看一次主干的构建 (82, 341, 172, 18)",
    #|    "测试机的磁盘满了，要不要清理旧的缓存？ (82, 229, 172, 18)",
    #|    " · 分组的标题用相对日期还是具体日期？ (102, 173, 114, 18)",
    #|    "Willow 上 codex 的登录已失效：请在设置里重新登录 (644, 293.6, 288, 22)",
    #|    "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。 (408, 554.7, 760, 23.1)",
    #|    "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？ (408, 60.5, 760, 23.1)",
    #|  ],
    #|  "None",
    #|)




  ))
}

///|
test "大屏: a panel whose body is nodes: drawn by the window's tree, read out a dialog by its title; what its body is given closes it, its gone not told; Escape closes it, its gone told once" {
  let t = menu_tester(1280.0, 800.0, 0)
  let gone = Ref(0)
  let close_it : Ref[() -> Unit] = Ref(fn() {  })
  @sf.panel_nodes("节点面板", from=At(600.0, 300.0, 0.0, 0.0), gone=fn() { gone.val += 1 }, fn(v, close) {
    close_it.val = close
    ink_node(v, 40.0, 36.0, body_ink)
  })
  t.run_for(@ui.move_most_ms)
  assert_true(tree_said(Dialog, "节点面板") is Some(_), msg="the tree's")
  assert_true(@sf.presenting())
  (close_it.val)()
  t.run_for(@motion.pop_out_ms)
  assert_eq((@sf.presenting(), @sf.presenter_visible(), gone.val), (false, false, 0))
  @sf.panel_nodes("节点面板", from=Unanchored, gone=fn() { gone.val += 1 }, fn(v, _) { ink_node(v, 40.0, 36.0, body_ink) })
  t.run_for(@ui.move_most_ms)
  assert_true(tree_said(Dialog, "节点面板") is Some(_), msg="the tree's, in the middle")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_eq((@sf.presenting(), @sf.presenter_visible(), gone.val), (false, false, 1))
}

///|
test "大屏: an untitled panel in the middle of the window whose body and foot are nodes: its close button in its corner where it was beside the old frame's" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("", from=Unanchored, foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
  })
  debug_inspect(body_and_foot(t, close=true), content=(
    #|(
    #|  (404, 370, 40, 36),
    #|  (814, 430, 60, 32),
    #|  [
    #|    "A (532, 18, 4, 8)",
    #|    "A (241, 435, 4, 8)",
    #|    "A (268, 175, 4, 8)",
    #|    "周 (266, 435, 8, 8)",
    #|    "林 (252, 175, 8, 8)",
    #|    "林 (253, 435, 8, 8)",
    #|    "今天 (66, 65, 212, 18)",
    #|    "+2 (264, 633, 12, 18)",
    #|    "个 (20.5, 719, 13, 20)",
    #|    "你 (516.5, 16, 11, 12)",
    #|    "待处理 (66, 173, 36, 18)",
    #|    "星 (20.5, 683, 13, 20)",
    #|    "昨天 (66, 381, 212, 18)",
    #|    "新建对话 (90, 17, 152, 20)",
    #|    "星期三 (66, 585, 212, 18)",
    #|    "发消息 (402, 710, 772, 22)",
    #|    "忽略 (408, 241.6, 24, 18)",
    #|    "周报的模板 (82, 671, 174, 20)",
    #|    "搜索全部内容 (90, 19, 188, 20)",
    #|    "整理发布清单 (408, 12, 96, 20)",
    #|    "整理发布清单 (82, 95, 174, 20)",
    #|    "Willow (420, 664, 36, 18)",
    #|    "一起换 (454, 181.6, 396, 20)",
    #|    "先不换 (454, 127.6, 396, 20)",
    #|    "5 分钟前 (450, 529.7, 44, 18)",
    #|    "Claude (408, 35.5, 36, 18)",
    #|    "等 林 决定 (408, 87.6, 60, 18)",
    #|    "Claude (408, 358.6, 36, 18)",
    #|    "Claude (408, 529.7, 36, 18)",
    #|    "Claude (494.5, 664, 36, 18)",
    #|    "迁移数据库的演练 (66, 615, 168, 20)",
    #|    "30 分钟前 (450, 35.5, 49.5, 18)",
    #|    "夜里的构建又失败了 (82, 207, 174, 20)",
    #|    "15 分钟前 (450, 358.6, 49.5, 18)",
    #|    "把旧的截图都换成新的 (66, 523, 190, 20)",
    #|    "开关和三处颜色都改好了 (82, 285, 132, 18)",
    #|    "盯着 CI，绿了告诉我 (66, 319, 190, 20)",
    #|    "首页的列表改成按天分组 (82, 151, 174, 20)",
    #|    "等你在浏览器里登录 (426, 456.7, 108, 18)",
    #|    "Slack 里问的报销流程 (66, 467, 168, 20)",
    #|    "模板放在共享文件夹的第一层 (66, 693, 188, 18)",
    #|    "给设置页加一个深色模式开关 (82, 263, 174, 20)",
    #|    "已经把三个步骤整理成一页文档 (66, 489, 188, 18)",
    #|    "正在核对第三项：安装包的签名 (66, 117, 168, 18)",
    #|    "和 Ana 一起看新版的引导页 (66, 411, 190, 20)",
    #|    "Ana：第二屏的插画可以再小一点 (66, 433, 137, 18)",
    #|    "把首页和聊天页的截图都更新 (454, 201.6, 396, 18)",
    #|    "这次只改列表，截图下次再说 (454, 147.6, 396, 18)",
    #|    "演练到第二步时 Maple 断开了 (66, 637, 132, 18)",
    #|    "在 Willow 上登录 gh (426, 436.7, 324, 18)",
    #|    "推送截图前要先登录 gh。 (408, 383.6, 760, 23.1)",
    #|    "监控中：每 5 分钟看一次主干的构建 (82, 341, 172, 18)",
    #|    "测试机的磁盘满了，要不要清理旧的缓存？ (82, 229, 172, 18)",
    #|    " · 分组的标题用相对日期还是具体日期？ (102, 173, 114, 18)",
    #|    "Willow 上 codex 的登录已失效：请在设置里重新登录 (644, 293.6, 288, 22)",
    #|    "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。 (408, 554.7, 760, 23.1)",
    #|    "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？ (408, 60.5, 760, 23.1)",
    #|  ],
    #|  "Some((842, 338, 32, 32))",
    #|)




  ))
}

///|
/// A panel a share of the window caps (`tall`) holding a list of one row (a box 40 by 36 of body_ink), with a foot, as
/// tall as what it holds up to that share (`hugs`: panel_list_node). Where its body's and its foot's boxes are drawn
/// once it is in; closed by Escape and gone after.
fn hugging(t : @ui.Tester) -> ((Double, Double, Double, Double), (Double, Double, Double, Double)) raise {
  let at = fn() raise {
    t.run_for(@ui.move_most_ms)
    let boxes = (painted_at(t, body_ink), painted_at(t, foot_ink))
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible(), msg="gone")
    boxes
  }
  @sf.panel_nodes("列表", from=Unanchored, tall=0.78, hugs=true, foot=fn(v, _) { foot_ink_node(v, 60.0, foot_ink) }, fn(v, _) {
    @sf.panel_list_node(v, fn() { [0] }, fn(b, _) { ink_node(b, 40.0, 36.0, body_ink) }, est=40.0) |> ignore
  })
  at()
}

///|
test "a panel a share of the window caps whose body is nodes, as tall as what it holds (hugs): its list's row and its foot where they were beside the old frame's, as a sheet and in the middle of the window" {
  let sheet = hugging(menu_tester(390.0, 844.0, 2))
  let dialog = hugging(menu_tester(1280.0, 800.0, 0))
  debug_inspect((sheet, dialog), content=(
    #|(
    #|  ((6, 696, 40, 36), (298, 780, 60, 32)),
    #|  ((396, 378.5, 40, 36), (814, 438.5, 60, 32)),
    #|)

  ))
}

///|
/// The ways a panel is shown that a field it opens to be typed in has the keys in (@sf.panel_opens_in_node): `at`,
/// the window (width, height, platform) and where it is opened from: a sheet on a phone by touch and with keyboard and
/// mouse, in the middle of a fold laid open by touch, beside what opened it and in the middle of a wide window.
let field_panel_ways : Array[(String, Double, Double, Int, @sf.Anchor)] = [
  ("小屏 touch sheet", 390.0, 844.0, 2, Unanchored),
  ("中屏 touch middle", 674.0, 842.0, 2, Unanchored),
  ("小屏 keyboard sheet", 390.0, 844.0, 0, Unanchored),
  ("大屏 beside", 1280.0, 800.0, 0, At(600.0, 300.0, 0.0, 0.0)),
  ("大屏 middle", 1280.0, 800.0, 0, Unanchored),
]

///|
test "a panel whose body says its field is typed in as it opens: that field has the keys as it opens on a sheet, beside what opened it and in the window's middle (the input method up for it by touch); back where they were as it goes" {
  for way in field_panel_ways {
    let (at, w, h, platform, from) = way
    let t = menu_tester(w, h, platform)
    let was = t.focus_said()
    let name = @ui.Field::new()
    @sf.panel_nodes("面板", from~, fn(v, _) {
      v.box(fn(b) { @sf.panel_opens_in_node(@sf.input_node(b, name, placeholder="名字")) }) |> ignore
    })
    t.run_for(@ui.move_most_ms)
    assert_true(t.focus_said().has_prefix("TextField \"名字\""), msg="\{at}: \{t.focus_said()}")
    if platform == 2 {
      assert_true(t.ime().0, msg="\{at}: the input method")
    }
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible(), msg="\{at}: gone")
    assert_eq(t.focus_said(), was, msg="\{at}: given back")
  }
}

///|
test "a panel whose body says its search is at hand: that search has the keys as it opens beside what opened it and in the window's middle with keyboard and mouse, given back as it goes; on a sheet (by touch or with keyboard and mouse) and in the window's middle by touch not, no input method up" {
  for way in field_panel_ways {
    @sf.presenters_reset()
    let (at, w, h, platform, from) = way
    let t = menu_tester(w, h, platform)
    let was = t.focus_said()
    let query = @ui.Field::new()
    @sf.panel_nodes("面板", from~, fn(v, _) {
      v.box(fn(b) { @sf.panel_search_at_hand_node(@sf.input_node(b, query, placeholder="搜索")) }) |> ignore
    })
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenter_visible(), msg="\{at}: up")
    if w < 600.0 || platform == 2 {
      assert_false(t.focus_said().has_prefix("TextField \"搜索\""), msg="\{at}: \{t.focus_said()}")
      assert_false(t.ime().0, msg="\{at}: the input method")
    } else {
      assert_true(t.focus_said().has_prefix("TextField \"搜索\""), msg="\{at}: \{t.focus_said()}")
    }
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible(), msg="\{at}: gone")
    assert_eq(t.focus_said(), was, msg="\{at}: given back")
  }
}

///|
/// A panel of nodes that goes in steps (panel_nodes' `steps`) opened by nothing in `t`: its first step a box of body_ink
/// and 下一步, which goes a step in (panel_go_nodes) to a box of foot_ink titled 节点的第二步; how many times that step was
/// let go of in `left`.
fn steps_of_nodes(left : Ref[Int]) -> Unit {
  @sf.panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
    ink_node(v, 40.0, 36.0, body_ink)
    @sf.button_node(v, fn() { "下一步" }, fn() {
      @sf.panel_go_nodes("节点的第二步", left=fn() { left.val += 1 }, fn(w, _) { ink_node(w, 60.0, 36.0, foot_ink) })
    })
    |> ignore
  })
}

///|
test "大屏: a panel of nodes in steps: a step in slides in within the same dialog, its back key and Escape back a step, the first as it was left; Escape from the first closes it" {
  let t = menu_tester(1280.0, 800.0, 0)
  let left = Ref(0)
  steps_of_nodes(left)
  t.run_for(@ui.move_most_ms)
  let dialog = t.get(Dialog).id
  assert_true(t.query(Button, label="返回") is None, msg="no back key on the first step")
  t.tap_text("下一步")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(t.semantics().filter(fn(n) { n.role == Dialog }).length(), 1, msg="one dialog, half way")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Dialog).id, dialog)
  assert_true(t.find("节点的第二步") is Some(_) && t.find("下一步") is None)
  t.click(Button, label="返回")
  t.run_for(@ui.move_most_ms)
  assert_eq((t.get(Dialog).id, t.find("下一步") is Some(_), t.find("节点的第二步") is None, left.val), (dialog, true, true, 1))
  t.tap_text("下一步")
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq((t.find("下一步") is Some(_), left.val, @sf.presenting()), (true, 2, true))
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_false(@sf.presenting())
}

///|
test "小屏: a panel of nodes in steps: a step in is a page of the same sheet, back a page back" {
  let t = phone_tester()
  let left = Ref(0)
  steps_of_nodes(left)
  t.run_for(sheet_way_ms(t))
  t.tap_text("下一步")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("节点的第二步") is Some(_) && t.query(Button, label="返回") is Some(_), msg=t.semantics_dump())
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_eq((t.find("下一步") is Some(_), left.val, @sf.presenting()), (true, 1, true))
}
