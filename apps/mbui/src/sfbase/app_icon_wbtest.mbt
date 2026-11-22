///|
test "the avatars: each pressed by its name picks it, the one picked read out selected" {
  let picked = @signals.signal("")
  let got = Ref("")
  let tips = @sf.TipLayer::new(fn() { None })
  let tt = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=640.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    avatar_tiles_node(root, fn() { app_makers }, fn() { picked.get() }, fn() { 560.0 }, fn(a) {
      got.val = a.id
      picked.set(a.id)
    }, tips)
    |> ignore
  })
  tt.draw()
  let first = app_makers[0]
  let label = if first.label.has_prefix("android-") { @sf.t(first.label) } else { first.label }
  tt.click(Button, label~)
  tt.run_for(@ui.move_most_ms)
  assert_eq(got.val, first.id)
  assert_eq(picked.get(), first.id)
  assert_eq(tt.fixed_outgrown(), [])
}
