// A quote waiting in the composer (composer_quote_card_node): who said it and what, the line for what is said about it
// made in its foot by the caller, its ✕ on its corner taking it out; leading nowhere.

///|
test "composer quote card: its words, the line under them the caller's, ✕ taking it out; no press of its own" {
  let tt = @ui.Tester::new(fn(_c) {  }, w=360.0, h=240.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  let removed = Ref(0)
  let tips = TipLayer::new(fn() { None })
  let comment = @ui.Field::new()
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).width(Is(Some(300.0))) |> ignore
      composer_quote_card_node(
        page,
        tips,
        fn() { "agent" },
        fn() { "这段要改" },
        fn() { "" },
        fn(b) { @ui.field(b, comment, placeholder="说点什么", max_lines=1, enter_sends=true) |> ignore },
        fn() { removed.val += 1 },
        fn() { "移除引用" },
      )
      |> ignore
    })
    |> ignore
  })
  tt.draw()
  assert_true(tt.words().iter().any(fn(w) { w.0.contains("这段要改") }), msg="its words not drawn")
  assert_true(tt.semantics().iter().any(fn(s) { s.role == @ui.Role::TextField }), msg="no line for what is said")
  assert_false(tt.semantics().iter().any(fn(s) { s.role == @ui.Role::Button && s.label == t("web-main.quote.jump") }))
  tt.click(Button, label="移除引用")
  tt.draw()
  assert_eq(removed.val, 1)
}
