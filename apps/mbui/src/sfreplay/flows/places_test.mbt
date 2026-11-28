// 31-places (e2e/traces/places.trace): the bottom bar's places: 文件 tapped (its page in place of the chats', the ball
// going to it); the bar's last slot pressed, its glass grown into the menu of the places past the first three, 用量
// picked there (用量's page, the last slot standing for it); the menu again and 已归档 picked; the chats tapped on the
// bar.

///|
test "31-places" {
  @sfreplay.orders(fn(seed) {
    let f = @sfreplay.Flow::start(@sfreplay.trace("places"), seed~)
    f.see("端到端测试")
    f.tap("icon:folder")
    // 文件's page in from the side the ball goes to; the ball there
    f.run_for(@ui.move_most_ms)
    f.see("=文件")
    f.gone("端到端测试")
    f.tap("icon:chats")
    f.run_for(@ui.move_most_ms)
    f.see("端到端测试")
    // the last slot: the menu, 用量 picked in it
    f.tap("icon:chevron-up")
    f.run_for(@ui.move_most_ms)
    f.tap("用量")
    f.run_for(@sfapp.switch_fade_ms)
    f.see("=用量")
    // the menu again, 已归档 picked
    f.run_for(@ui.move_most_ms)
    f.tap("icon:chevron-up")
    f.run_for(@ui.move_most_ms)
    f.tap("已归档")
    f.run_for(@ui.move_most_ms)
    f.see("=已归档")
    f.tap("icon:chats")
    f.run_for(@sfapp.switch_fade_ms)
    f.see("端到端测试")
    // the bottom bar's springs and tweens to their declared end (its menu folded back included)
    f.run_to(@sfapp.bar_rest)
    f.end()
  })
}
