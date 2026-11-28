// 50-bar-glass (e2e/traces/bar-glass.trace): the bottom bar, all glass: 文件 tapped and the chats again, the notch's
// icon swapping between 令 and 文件's ＋ (a short scale and fade); the last slot pressed, the bar's own glass grown
// into its menu, and 已归档 tapped there as its row has risen: 已归档's page, the menu folding back with its indicator
// landing on the last slot; the chats tapped on the bar again.

///|
test "50-bar-glass" {
  @sfreplay.orders(fn(seed) {
    let f = @sfreplay.Flow::start(@sfreplay.trace("bar-glass"), seed~)
    f.see("端到端测试")
    f.tap("icon:folder")
    f.see("=文件")
    // the notch's icon swapping to 文件's ＋, the page and the ball going
    f.run_for(@sfapp.icon_swap_ms)
    f.tap("icon:chats")
    f.run_for(@sfapp.icon_swap_ms)
    f.see("端到端测试")
    f.tap("icon:chevron-up")
    f.run_for(@ui.move_most_ms)
    f.tap("已归档")
    f.see("=已归档")
    f.run_for(@ui.move_most_ms)
    f.tap("icon:chats")
    f.run_for(@sfapp.switch_fade_ms)
    f.see("端到端测试")
    // the bottom bar's springs and tweens to their declared end (its menu folded back included)
    f.run_to(@sfapp.bar_rest)
    f.end()
  })
}
