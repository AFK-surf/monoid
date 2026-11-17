// A notice over the composer (composer_notice_node): its words, what it offers pressed, why that failed under them;
// its mark's middle over the composer's ＋ wherever the capsule is.

///|
test "composer notice: its words, what it offers pressed, why that failed under its words, its mark over the ＋" {
  let tt = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  let pressed = Ref(0)
  let failed = @signals.signal("", same=fn(a, b) { a == b })
  let tips = TipLayer::new(fn() { None })
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(20.0)).width(Is(Some(380.0))) |> ignore
      composer_notice_node(
        page,
        tips,
        fn() { "archive" },
        fn() { "这个对话已归档" },
        fn() { 24.5 },
        offer={
          words: fn() { "还原对话" },
          name: fn() { "还原对话" },
          off: fn() { false },
          press: fn() { pressed.val += 1 },
        },
        failed=fn() { failed.get() },
      )
      |> ignore
    })
    |> ignore
  })
  tt.draw()
  assert_true(tt.words().iter().any(fn(w) { w.0.contains("这个对话已归档") }))
  tt.click(Button, label="还原对话")
  tt.draw()
  assert_eq(pressed.val, 1)
  failed.set("还原失败：离线")
  tt.draw()
  guard tt.words().iter().find_first(fn(w) { w.0.contains("还原失败") }) is Some(e) else { fail("why not said") }
  guard tt.words().iter().find_first(fn(w) { w.0.contains("这个对话已归档") }) is Some(said) else { fail("words gone") }
  assert_true(e.2 > said.2, msg="why not under its words")
  // (its mark's middle 24.5 in from the capsule's start, as the composer's ＋'s)
  let side = theme().t.meta_line + 2.0 * notice_pad
  assert_true(said.1 >= 20.0 + 24.5 - side / 2.0 + side - 0.5, msg="its words before its mark: \{said.1}")
}

///|
test "composer notice: its × pressed; out of reach, not pressed" {
  let tt = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  let closed = Ref(0)
  let off = @signals.signal(true, same=fn(a, b) { a == b })
  let tips = TipLayer::new(fn() { None })
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(20.0)).width(Is(Some(380.0))) |> ignore
      composer_notice_node(
        page,
        tips,
        fn() { "feedback" },
        fn() { "有回复了" },
        fn() { 24.5 },
        dismiss={
          words: fn() { "" },
          name: fn() { "关闭" },
          off: fn() { off.get() },
          press: fn() { closed.val += 1 },
        },
      )
      |> ignore
    })
    |> ignore
  })
  tt.draw()
  tt.click(Button, label="关闭") catch { _ => () }
  tt.draw()
  assert_eq(closed.val, 0)
  off.set(false)
  tt.draw()
  tt.click(Button, label="关闭")
  tt.draw()
  assert_eq(closed.val, 1)
}

///|
test "composer notice: what it offers on the first line of what it says, not in the middle of the lines it wraps to" {
  let tt = @ui.Tester::new(fn(_c) {  }, w=260.0, h=240.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  let tips = TipLayer::new(fn() { None })
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(10.0)).width(Is(Some(240.0))) |> ignore
      composer_notice_node(
        page,
        tips,
        fn() { "archive" },
        fn() { "这个对话已经归档了很久，还原以后才能接着发消息，还原可能要等一会儿" },
        fn() { 24.5 },
        offer={ words: fn() { "还原对话" }, name: fn() { "还原对话" }, off: fn() { false }, press: fn() {  } },
      )
      |> ignore
    })
    |> ignore
  })
  tt.draw()
  guard tt.words().iter().find_first(fn(w) { w.0.contains("归档") }) is Some(said) else { fail("words not drawn") }
  guard tt.words().iter().find_first(fn(w) { w.0 == "还原对话" }) is Some(offer) else { fail("offer not drawn") }
  let line = theme().t.meta_line
  assert_true(said.4 > line * 1.5, msg="did not wrap: \{said.4}")
  // (the middles of their lines: the offer's one line, the words' first)
  let offer_mid = offer.2 + offer.4 / 2.0
  let first_mid = said.2 + line / 2.0
  assert_true((offer_mid - first_mid).abs() < 1.0, msg="offer's middle at \{offer_mid}, the first line's at \{first_mid}")
}
