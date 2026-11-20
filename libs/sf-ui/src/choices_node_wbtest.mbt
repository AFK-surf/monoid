// The library's exclusive choices (choices_node.mbt): each card's radio at its end on its title's first line, clear of
// the card's round corner (as far in as the corner is round), on a page and in a panel's body; nothing the audit finds.

///|
/// A window `w` wide holding choices 自动选择 (chosen, a sentence under it) and 指定机器 (none), in a panel's body
/// where `in_panel` (its column 24 in from the panel's sides).
fn choices2(w : Double, in_panel : Bool) -> @ui.Tester {
  w2_case(w~, fn(root) {
    root.box(fn(col) {
      if in_panel {
        panel_in_lend(col, Wide, 24.0, sides=24.0)
      }
      choices_node(
        col,
        fn() { "auto" },
        fn() { [("auto", "自动选择", "按工作区的默认设置挑选最合适的一台"), ("pick", "指定机器", "")] },
        fn(_) {  },
        label=fn() { "在哪里运行" },
      )
    })
    |> ignore
  })
}

///|
test "choices: each card's radio on its title's first line, standing as far in from the card's end as its corner is round, on a page and in a panel, at 390 and 1280: nothing the audit finds" {
  for in_panel in [false, true] {
    for w in [390.0, 1280.0] {
      let t = choices2(w, in_panel)
      assert_eq(t.audit(), [], msg="in a panel \{in_panel}, \{w}")
    }
  }
}
