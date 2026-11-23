// The library's people overlapping (avatar_stack_node): as many faces as asked, each ringed and over the one before
// it by as much as asked, the first over them all; past as many as are shown, +n; read out a group by its name or by
// the initials and the +n it shows.

///|
/// A stack of `n` faces made in a row at the window's top: 24 across, ringed 1.5, 5 over, the first `most`.
fn stack_case(n : Int, most : Int, label? : () -> String) -> @ui.Tester {
  let names = ["林青", "Ada", "Grace", "王小明", "Linus"]
  let faces = Array::makei(n, fn(i) {
    let face : StackFace = { id: "u\{i}", name: names[i % names.length()], pictured: false, picture: fn() { "" } }
    face
  })
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=200.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      avatar_stack_node(r, faces, 24.0, fn() { theme().p.bg }, most~, label?) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "avatar_stack_node: as many as asked, +n past them, read out as a group of the initials it shows" {
  let t = stack_case(5, 3)
  let group = t.get(Group, has="+2")
  let (_, _, w, h) = group.rect
  // (three ringed faces 27 across, each 22 after the one before: 27 + 2 × 22, then +2 after them)
  assert_eq((t.find("+2") is Some(_), h, w > 71.0), (true, 27.0, true))
}

///|
test "avatar_stack_node: all shown where no most is said, none +n; named by its label where given" {
  let t = stack_case(4, 0, label=fn() { "四个人" })
  let (_, _, w, h) = t.get(Group, label="四个人").rect
  assert_eq((t.find("+") is None, w, h), (true, 27.0 + 3.0 * 22.0, 27.0))
}
