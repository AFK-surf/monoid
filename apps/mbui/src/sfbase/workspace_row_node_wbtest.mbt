///|
fn u5_case(make : (@view.View) -> Unit, scale? : Double = 1.0) -> @ui.Tester {
  @sf.presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(e) {
      e
      .width(Is(Some(40.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    make(root)
  })
  t.draw()
  t
}

// The workspaces' list's parts and a vendor's marks (workspace_row_node.mbt): a row pressed once a press, the one in
// use checked where it stands, its words on the same line as the others', a workspace's letter giving way to its mark, an
// invitation's 加入 and 忽略 each pressed alone and waiting while asked.

///|
test "workspace rows: pressed once a press; the one in use checked where it stands, its words on the others' line" {
  let pressed = Ref(0)
  let in_use = @signals.signal("Acme")
  let tr = u5_case(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(360.0))) |> ignore
      for name in ["Acme", "Globex"] {
        workspace_row_node(
          col,
          fn() { name },
          fn() { if name == "Acme" { "me@acme.dev" } else { "" } },
          fn() {
            pressed.val += 1
            in_use.set(name)
          },
          checked=fn() { in_use.get() == name },
          lead=fn(l) { workspace_mark_node(l, fn() { "" }, fn() { "" }, fn() { name }) },
        )
      }
      workspace_row_node(col, fn() { "新建 workspace" }, fn() { "" }, icon="plus", fn() { pressed.val += 100 })
    })
    |> ignore
  })
  let ys = fn() { (tr.rect_of("Acme").map(fn(r) { r.1 }), tr.rect_of("Globex").map(fn(r) { r.1 })) }
  let was = ys()
  tr.click(Button, label="Globex")
  tr.run_for(@ui.move_most_ms)
  assert_eq(pressed.val, 1)
  // (the one in use another: each row where it was)
  assert_eq(ys(), was)
  let x = fn(w : String) { tr.rect_of(w).map(fn(r) { r.0 }) }
  // (the one in use's words where the others' are; an action's too)
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
  let tr = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=460.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
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
  tr.draw()
  let join = @sf.t("android-misc.invite.join")
  let decline = @sf.t("android-misc.invite.ignore")
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
/// An invitation saying `words` in a column `w` wide: the Tester, then its words' rectangle, its account's, 加入's and
/// 忽略's.
fn invite_at(
  words : String,
  w : Double,
) -> (
  @ui.Tester,
  (Double, Double, Double, Double),
  (Double, Double, Double, Double),
  (Double, Double, Double, Double),
  (Double, Double, Double, Double),
) {
  @sf.presenters_reset()
  // (a window wider than the others': a test's labels are their keys, 加入 as wide as `android-misc.invite.join`)
  let tr = @ui.Tester::new(fn(_c) {  }, w=800.0, h=400.0, platform=0)
  tr.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(w))) |> ignore
      invitation_line_node(
        col,
        fn() { words },
        fn() { "me@acme.dev" },
        fn() {  },
        fn() {  },
        joining=fn() { false },
        ignoring=fn() { false },
      )
    })
    |> ignore
  })
  tr.draw()
  (
    tr,
    tr.rect_of(words).unwrap(),
    tr.rect_of("me@acme.dev").unwrap(),
    tr.get(Button, label=@sf.t("android-misc.invite.join")).rect,
    tr.get(Button, label=@sf.t("android-misc.invite.ignore")).rect,
  )
}

///|
test "an invitation of several lines: its buttons by its words' first line; narrow, under its words" {
  // (one line: its buttons by it, where they are beside a line of the body's)
  let (t1, (wx1, wy1, ww1, wh1), _, (jx1, jy1, jw1, jh1), (ix1, _, iw1, _)) = invite_at("左子健 邀请你加入 Acme", 720.0)
  let one = jy1 + jh1 / 2.0 - wy1
  assert_true(
    (one - wh1 / 2.0).abs() <= 1.0,
    msg="\{jy1} \{jh1} \{wy1} \{wh1} \{wx1} \{ww1} \{jx1} \{jw1} \{ix1} \{iw1}",
  )
  assert_eq(t1.audit(), [])
  // (its words on several lines: its buttons where they are by one, by the first of them, not across their middle)
  let long = "左子健 邀请你加入 Initech Research Lab 的工作区，一起处理还没合并的修复、本周的发布计划和下个月的路线图"
  let (t2, (wx, wy, ww, wh), (_, ay, _, ah), (jx, jy, _, jh), (_, iy, _, _)) = invite_at(long, 720.0)
  assert_true(wh >= 2.0 * wh1 - 1.0, msg="\{wh} \{wh1}")
  assert_true(jx >= wx + ww, msg="\{jx} \{wx} \{ww}")
  assert_true((jy + jh / 2.0 - wy - one).abs() <= 1.0, msg="\{jy} \{jh} \{wy} \{one}")
  assert_true(jy + jh < ay + ah, msg="\{jy} \{jh} \{ay} \{ah}")
  assert_eq(iy, jy)
  assert_eq(t2.audit(), [])
  // (narrow: its words keep the row's width, its buttons go on under them, from the same start)
  let (t3, (nx, _, nw, _), (_, nay, _, nah), (njx, njy, _, _), (_, niy, _, _)) = invite_at(long, 300.0)
  assert_true(njy >= nay + nah, msg="\{njy} \{nay} \{nah}")
  assert_eq(niy, njy)
  assert_true((njx - nx).abs() <= 0.5, msg="\{njx} \{nx}")
  assert_true(nw >= 300.0 - 2.0 * 20.0 - 0.5, msg="\{nw}")
  assert_eq(t3.audit(), [])
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
