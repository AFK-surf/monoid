// A file's card waiting in the composer (file_waiting_node), pressed: its ✎ and ↻ at its end pressed whether or not
// the card itself opens anything, the card only where it does, never as its buttons are.

///|
/// Long past a tap: what it does, done.
let waiting_tapped_ms : Double = 500.0

///|
test "a file waiting in the composer: its ✎ and ↻ pressed whether it opens or not, the card itself only where it opens" {
  let opens = @signals.signal(false)
  let pressed : Array[String] = []
  let tt = @ui.Tester::new(fn(_c) {  }, w=480.0, h=200.0, platform=0)
  tt.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    root.lines_up(Is(Some(Start))) |> ignore
    let tips = @sf.TipLayer::new(fn() { None })
    file_waiting_node(
      root,
      tips,
      fn() { "粘贴的文字.txt" },
      fn() { "" },
      fn() { "12 KB" },
      fn() { 16.0 },
      fn(p) {
        pressed.push(
          match p {
            Opened => "opened"
            Again => "again"
            Back => "back"
          },
        )
      },
      retry=fn() { true },
      restore=fn() { true },
      opens=fn() { opens.get() },
    )
    |> ignore
  })
  tt.draw()
  let press_all = fn() raise {
    pressed.clear()
    let (x, y) = tt.find("12 KB").unwrap()
    tt.tap(x, y)
    tt.run_for(waiting_tapped_ms)
    tt.click(Button, label=@sf.t("web-main.composer.expandPaste"))
    tt.run_for(waiting_tapped_ms)
    tt.click(Button, label=@sf.t("web-main.composer.retryUpload"))
    tt.run_for(waiting_tapped_ms)
    pressed.join(",")
  }
  assert_eq(press_all(), "back,again")
  opens.set(true)
  tt.draw()
  assert_eq(press_all(), "opened,back,again")
  assert_eq(tt.audit(), [])
}
