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

///|
test "choices in narrow panel with capsule input extra: concentric on both pointer (36pt) and touch (44pt)" {
  for platform in [0, 2] {
    presenters_reset()
    let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=640.0, platform~)
    t.check_looks(false)
    set_dark(Some(false))
    @ui.set_tree_theme(ui_theme_now)
    let field = @ui.Field::new()
    @ui.set_view_app(fn(root) {
      root.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      root.box(fn(col) {
        panel_in_lend(col, Narrow, 20.0, sides=20.0)
        choices_node(
          col,
          fn() { "new" },
          fn() { [("new", "新建会话", "从空白上下文开始。"), ("old", "已有会话", "")] },
          fn(_) {  },
          label=fn() { "会话" },
          extra=fn(k) {
            guard k == "new" else { None }
            Some(fn(x) { input_node(x, field, placeholder="可选标题") |> ignore })
          },
        )
      })
      |> ignore
    })
    t.frame()
    assert_eq(t.corner_faults(), [], msg="platform \{platform}")
  }
}
