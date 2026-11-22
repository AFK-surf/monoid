///|
test "a station's choice: with one station, words alone, nothing to press; with others, a button that opens its menu" {
  let stations = @signals.signal([{ station: "a", name: "办公室", emoji: "", icon: "" }])
  let chosen = Ref("")
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=390.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    station_choice_node(root, fn() { stations.get() }, fn() { "a" }, fn(s) { chosen.val = s }, title="工作站", label=fn(n) {
      "在 " + n
    })
    |> ignore
  })
  t.draw()
  assert_true(t.query(Button, label="在 办公室") is None, msg="one station: no button")
  assert_true(t.rect_of("办公室") is Some(_))
  stations.set([{ station: "a", name: "办公室", emoji: "", icon: "" }, { station: "b", name: "家里", emoji: "", icon: "" }])
  t.draw()
  let b = t.get(Button, label="在 办公室", expanded=false)
  let (x, y, w, h) = b.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="在 办公室", expanded=true) is Some(_), msg="its menu open")
}
