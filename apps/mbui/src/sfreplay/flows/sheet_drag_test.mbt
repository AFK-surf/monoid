// 32-sheet-drag (e2e/traces/sheet-drag.trace): a sheet dragged by its top: the workspaces' sheet opened from the
// name (as tall as what it holds), drawn up (it does not grow: it comes back), dragged down past 30%: closed. Then a new chat's station sheet
// (as tall as its stations, not draggable): dragged down a little it comes back, flicked down 100 (to the window's
// foot: a Mac's drag ends there) it closes; opened again, its station tapped (newChat.pick).

///|
test "32-sheet-drag" {
  @sfreplay.orders(fn(seed) {
    let f = @sfreplay.Flow::start(@sfreplay.trace("sheet-drag"), seed~)
    f.see("端到端测试")
    f.tap("=Dev")
    f.run_to(@sf.presented_rest)
    f.see("切换 workspace")
    // top-bar workspace switcher opens as a popover on Small; tap outside below it to dismiss
    f.tap_at(195.0, 700.0)
    f.run_to(@sf.presented_rest)
    f.gone("切换 workspace")
    f.tap("icon:plus")
    f.run_for(@ui.move_most_ms)
    f.see("想让 agent 做什么？")
    f.tap("=willow")
    f.run_to(@sf.presented_rest)
    f.see("选择运行的 station")
    f.drag("选择运行的 station", 0.0, 40.0, steps=sheet_flick_steps)
    f.run_to(@sf.presented_rest)
    f.see("选择运行的 station")
    f.drag("选择运行的 station", 0.0, 100.0, steps=sheet_flick_steps)
    f.run_to(@sf.presented_rest)
    f.gone("选择运行的 station")
    f.tap("=willow")
    f.run_to(@sf.presented_rest)
    f.tap("=willow", top=true)
    f.run_to(@sf.presented_rest)
    f.gone("选择运行的 station")
    f.tap("=取消")
    f.run_for(@ui.move_most_ms)
    f.see("端到端测试")
    // the bottom bar's springs and tweens to their declared end
    f.run_to(@sfapp.bar_rest)
    f.end()
  })
}

///|
/// The run's flicks on a sheet's top: `dragon … 300` (a move a frame, 300 ms of them).
let sheet_flick_steps : Int = 19
