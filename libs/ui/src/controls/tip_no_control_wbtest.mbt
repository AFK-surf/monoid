// A tip on what is no control (a mark, a status: it takes no press) shows as the pointer rests on it, as one on a
// control does: what is read as pointed at is pointed at, whatever it takes of the hand (mbui's View::pointed). Before,
// only what took a press could be pointed at, and such a tip never showed (the sync key's, till #6855).

///|
test "a tip on what takes no press shows as the pointer rests on it, and goes as it leaves" {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(k) {
      k.width(Is(Some(34.0))).height(Is(Some(34.0))).says(Is(Some(@view.said(Status, label="正在同步")))) |> ignore
      tip_node(tips, k, fn() { "正在同步 · 还剩 3 个对话" }) |> ignore
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  let tips = fn() {
    t.semantics().filter(fn(s) { s.role == Tooltip && s.label == "正在同步 · 还剩 3 个对话" }).length()
  }
  let k = t.get(Status, label="正在同步")
  t.move_to(k.rect.0 + 17.0, k.rect.1 + 17.0)
  t.run_for(tip_delay_ms + tip_settled_ms)
  let shown = tips()
  t.move_to(300.0, 250.0)
  t.run_for(@motion.pop_out_ms * 2.0)
  assert_eq((shown, tips()), (1, 0))
}
