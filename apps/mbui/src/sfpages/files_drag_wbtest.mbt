///|
test "drag_ghost_node draws panel liquid glass chip with zero audit faults on light and dark themes" {
  for dark in [false, true] {
    let at = if dark { "dark" } else { "light" }
    ndrag.item.set(
      Some({
        station: "ws1/st1",
        station_name: "Willow",
        root: "docs",
        path: "notes.md",
        abs: "/docs/notes.md",
        name: "notes.md",
        size: 1024.0,
        dir: false,
      }),
    )
    ndrag.at.set((80.0, 60.0))
    let t = @ui.Tester::tree(
      w=400.0,
      h=300.0,
      platform=0,
      dark~,
      theme=fn() { @sf.ui_theme() },
      fn(root) {
        root.width(Is(Some(400.0))).height(Is(Some(300.0))) |> ignore
        drag_ghost_node(root)
      },
    )
    t.draw()
    assert_true(t.find("notes.md") is Some(_), msg="\{at}: ghost label drawn")
    assert_true(t.drawn_glass().iter().any(fn(g) { g.4 == 6 }), msg="\{at}: ghost chip draws liquid glass")
    assert_eq(t.audit(), [], msg="\{at}: ghost chip audit")
    ndrag.item.set(None)
    ndrag.at.set((0.0, 0.0))
  }
}
