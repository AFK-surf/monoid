// One sheet over another on a phone's window (Small, a finger), each the window's tree's (panel_nodes).

///|
/// A phone's window with a sheet opened by 打开 and come to rest, then another over it, come to rest; what each let go of as it closed unsaid, and what was pressed, in `said`.
/// The sheet under it holds `under_lines` lines; the one over it three and 按我 at its foot.
fn sheets_over(said : Array[String], under_lines? : Int = 8) -> @ui.Tester {
  let t = presenting_tester(phone, fn(_) {
    panel_nodes("下面", from=Unanchored, gone=fn() { said.push("under gone") }, fn(v, _) {
      for i in 0..<under_lines {
        words_node(v, fn() { "下面第\{i + 1}行" }, fn() { paragraph }) |> ignore
      }
    })
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  panel_nodes("上面", from=Unanchored, gone=fn() { said.push("over gone") }, fn(v, _) {
    for i in 0..<3 {
      words_node(v, fn() { "上面第\{i + 1}行" }, fn() { paragraph }) |> ignore
    }
    button_node(v, fn() { "按我" }, fn() { said.push("pressed") }) |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "one sheet over another, each the window's tree's: one scrim dims what is under them" {
  let said : Array[String] = []
  let t = sheets_over(said)
  assert_eq(scrims_drawn(t, phone), 1)
}

