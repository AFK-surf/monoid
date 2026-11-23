// The headless desktop menubar (`@headless.menubar`, `Menubar::trigger`), under `window` (window_test.mbt) so
// zero-draw is enforced.

///|
fn mb_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "menubar: MenuBar of MenuItem triggers, single roving Tab stop, ←/→/Home/End navigation, ↓/Enter/Space open, hot-switch, and Escape close keeping focus" {
  let active : @signals.Signal[String?] = @signals.signal(None)
  let t = window(fn(root) {
    let side = fn(name : String) {
      @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(40.0))).height(Is(Some(28.0))) |> ignore
      })
      |> ignore
    }
    side("前")
    @headless.menubar(
      root,
      fn() { "主菜单" },
      fn() { active.get() },
      fn(to) { active.set(to) },
      fn(v, mb) {
        v.row(Is(true)) |> ignore
        mb.trigger(v, "file", fn() { "文件" }, fn(n, _) {
          n.width(Is(Some(60.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
        mb.trigger(v, "edit", fn() { "编辑" }, disabled=fn() { true }, fn(n, _) {
          n.width(Is(Some(60.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
        mb.trigger(v, "view", fn() { "视图" }, fn(n, _) {
          n.width(Is(Some(60.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
        mb.trigger(v, "help", fn() { "帮助" }, fn(n, _) {
          n.width(Is(Some(60.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
    side("后")
  })
  t.set_a11y(true)
  let has_bar = t.query(MenuBar, label="主菜单") is Some(_)
  // Single roving Tab stop: 前 -> 文件 -> 后
  t.act(Button, Focus, label="前")
  t.tab()
  let tab_in = mb_focus(t)
  t.tab()
  let tab_out = mb_focus(t)
  // Back into menubar: → skips disabled "编辑" to "视图", closed so active stays None
  t.tab(back=true)
  t.key(@ui.key_code_right)
  let moved_closed = (mb_focus(t), active.untracked())
  // ↓ opens "视图"
  t.key(@ui.key_code_down)
  let opened_down = (active.untracked(), t.get(MenuItem, label="视图").expanded)
  // While open, → hot-switches active to "帮助", → wraps to "文件"
  t.key(@ui.key_code_right)
  let hot_help = (mb_focus(t), active.untracked())
  t.key(@ui.key_code_right)
  let hot_wrap = (mb_focus(t), active.untracked())
  // Escape closes and keeps focus on "文件"
  t.key(@ui.key_escape)
  let after_esc = (mb_focus(t), active.untracked(), t.get(MenuItem, label="文件").expanded)
  // End -> "帮助", Enter opens "帮助", Space toggles it closed
  t.key(@ui.key_code_end)
  t.enter()
  let opened_enter = (mb_focus(t), active.untracked())
  t.key(@ui.key_of_char(' '))
  let closed_space = active.untracked()
  assert_eq(
    (
      has_bar,
      tab_in,
      tab_out,
      moved_closed,
      opened_down,
      hot_help,
      hot_wrap,
      after_esc,
      opened_enter,
      closed_space,
    ),
    (
      true,
      "文件",
      "后",
      ("视图", None),
      (Some("view"), Some(true)),
      ("帮助", Some("help")),
      ("文件", Some("file")),
      ("文件", None, Some(false)),
      ("帮助", Some("help")),
      None,
    ),
  )
}

///|
test "menubar: pointer hover hot-switches active only when already open; rtl=true flips ←/→" {
  let active : @signals.Signal[String?] = @signals.signal(None)
  let t = window(fn(root) {
    @headless.menubar(
      root,
      fn() { "菜单栏" },
      fn() { active.get() },
      fn(to) { active.set(to) },
      rtl=true,
      fn(v, mb) {
        v.row(Is(true)) |> ignore
        mb.trigger(v, "a", fn() { "甲" }, fn(n, _) {
          n.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
        mb.trigger(v, "b", fn() { "乙" }, fn(n, _) {
          n.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
  })
  // Hovering "乙" while closed does NOT open it
  t.move_to(110.0, 14.0)
  let hover_closed = active.untracked()
  // Click "甲" to open it
  t.click(MenuItem, label="甲")
  let after_click = active.untracked()
  // Hovering "乙" while open hot-switches active to "b"
  t.move_to(110.0, 14.0)
  let hover_open = active.untracked()
  // RTL: focus "甲", ← advances forward to "乙" and hot-switches active
  active.set(Some("a"))
  t.draw()
  t.act(MenuItem, Focus, label="甲")
  t.key(@ui.key_code_left)
  let rtl_left = (mb_focus(t), active.untracked())
  assert_eq((hover_closed, after_click, hover_open, rtl_left), (None, Some("a"), Some("b"), ("乙", Some("b"))))
}
