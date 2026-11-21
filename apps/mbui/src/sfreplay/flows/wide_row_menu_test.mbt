// 62-wide-row-menu (e2e/traces/wide-row-menu.trace: 1280 × 800): a chat's row right clicked in the wide frame's list:
// its menu; 固定 pins it (chat.pin), the row goes up under 已固定; right clicked again,
// 取消固定 lets it go. (The run's pins at the station, alice's one then none: the app's chat.pin asks, made again as
// they were.)

///|
test "62-wide-row-menu" {
  @sfreplay.orders(fn(seed) {
    let f = @sfreplay.Flow::start(@sfreplay.trace("wide-row-menu"), seed~, w=1280.0, h=800.0)
    f.see("新建对话")
    // (the new chat's pane come in beside it, what it asks asked, before the row is pointed at)
    f.see("做任何事")
    // (the new chat answered: its model said beside it, what it asks asked)
    f.see("Sonnet")
    f.run_for(@ui.move_most_ms)
    f.hover("端到端测试")
    f.right_click("端到端测试")
    f.see("=固定")
    f.tap("=固定")
    // (its row pinned as the core answers, before the menu is asked for again)
    f.answered("chat.pin", 1)
    f.gone("=重命名")
    f.see("已固定")
    // (pointed at again where it is now, under 已固定, before the menu is asked for there)
    f.hover("端到端测试")
    f.right_click("端到端测试")
    f.see("=取消固定")
    f.tap("=取消固定")
    f.gone("已固定")
    f.end()
  })
}

