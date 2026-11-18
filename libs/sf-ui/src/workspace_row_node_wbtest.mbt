// The workspaces' list's parts and a vendor's marks (workspace_row_node.mbt): a row pressed once a press, the one in
// use's words on the same line as the others' on its card, a workspace's letter giving way to its mark, an
// invitation's 加入 and 忽略 each pressed alone and waiting while asked.

///|
test "workspace rows: pressed once a press; the one on its card has its words on the others' line, checked" {
  let pressed = Ref(0)
  let tr = u5_case(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(360.0))) |> ignore
      workspace_label_node(col, fn() { "当前" })
      workspace_card_node(col, fn(card) {
        workspace_row_node(
          card,
          fn() { "Acme" },
          fn() { "me@acme.dev" },
          fn() { pressed.val += 10 },
          checked=true,
          lead=fn(l) { workspace_mark_node(l, fn() { "" }, fn() { "" }, fn() { "Acme" }) },
          on_card=true,
        )
      })
      workspace_label_node(col, fn() { "其他" })
      workspace_row_node(
        col,
        fn() { "Globex" },
        fn() { "" },
        fn() { pressed.val += 1 },
        lead=fn(l) { workspace_mark_node(l, fn() { "" }, fn() { "" }, fn() { "Globex" }) },
      )
      workspace_row_node(col, fn() { "新建 workspace" }, fn() { "" }, icon="plus", fn() { pressed.val += 100 })
    })
    |> ignore
  })
  tr.click(Button, label="Globex")
  tr.draw()
  assert_eq(pressed.val, 1)
  let x = fn(w : String) { tr.rect_of(w).map(fn(r) { r.0 }) }
  // (the one in use's words where the others' are, on its card or not; an action's too)
  assert_eq(x("Acme"), x("Globex"))
  assert_eq(x("Acme"), x("新建 workspace"))
  assert_true(tr.rect_of("me@acme.dev") is Some(_))
  assert_eq(tr.audit(), [])
}

///|
test "a workspace's mark: its letter till it has a mark of its own, then the mark in its place" {
  let emoji = @signals.signal("")
  let tr = u5_case(fn(root) {
    workspace_row_node(root, fn() { "Initech" }, fn() { "" }, fn() {  }, lead=fn(l) {
      workspace_mark_node(l, fn() { emoji.get() }, fn() { "" }, fn() { "Initech" })
    })
  })
  let letters = fn() { tr.words().filter(fn(w) { w.0 == "I" }).length() }
  assert_eq(letters(), 1)
  emoji.set("🚀")
  tr.run_for(@ui.move_most_ms)
  assert_eq(letters(), 0)
  assert_eq(tr.audit(), [])
}

///|
test "an invitation: 加入 and 忽略 each pressed alone, waiting while asked" {
  let answered : Array[String] = []
  let joining = @signals.signal(false)
  let tr = u5_case(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(420.0))) |> ignore
      invitation_line_node(
        col,
        fn() { "左子健 邀请你加入 Acme" },
        fn() { "me@acme.dev" },
        fn() { answered.push("join") },
        fn() { answered.push("decline") },
        joining=fn() { joining.get() },
        ignoring=fn() { false },
      )
    })
    |> ignore
  })
  let join = t("android-misc.invite.join")
  let decline = t("android-misc.invite.ignore")
  tr.click(Button, label=decline)
  tr.click(Button, label=join)
  tr.draw()
  assert_eq(answered, ["decline", "join"])
  assert_eq(tr.audit(), [])
  joining.set(true)
  tr.run_for(@ui.move_most_ms)
  // (at work: read out disabled, a press on it doing nothing more)
  assert_eq(tr.get(Button, label=join).disabled, true)
  tr.click(Button, label=join)
  tr.draw()
  assert_eq(answered, ["decline", "join"])
}

///|
test "a vendor's mark: made again as what it is changes; on a card's neutral ground" {
  let runtime = @signals.signal("claude")
  let tr = u5_case(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(12.0)) |> ignore
      provider_mark_node(r, fn() { (runtime.get(), "subscription", "") }, 18.0)
      provider_badge_node(r, "codex", "subscription", 18.0)
    })
    |> ignore
  })
  runtime.set("codex")
  tr.run_for(@ui.move_most_ms)
  assert_eq(tr.audit(), [])
}
