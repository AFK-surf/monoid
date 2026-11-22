// The side panel beside the page (panel_node.mbt): what it puts past its left edge.

///|
test "the side panel at rest cuts nothing past its left edge: its edge's handle, half over the page, shows whole; sliding, it is cut to its column" {
  side_slide_reset()
  let open = @signals.signal(true)
  let src = @sfbase.made_source()
  let whole = 400.0
  panel_own.width.set(Some(whole))
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.row(Is(true)) |> ignore
      root.box(fn(page) { page.grow(Is(1.0)) |> ignore }) |> ignore
      root.box(fn(col) {
        col.reacts(fn() { open.get() }, fn(on) { side_slides(col, src, "test", "test", on) })
        let at = fn() { side_col(src, col, "test", open.get()) }
        col
        .shrink(Is(0.0))
        .width(By(fn() { Some(at()) }))
        .clips(By(fn() { at() < side_whole(src, col) }))
        |> ignore
        col.box(fn(p) {
          p.grow(Is(1.0)).width(Is(Some(whole))) |> ignore
          p.box(fn(edge) {
            edge
            .over(Is(true))
            .offset(Is((-20.0, 100.0)))
            .words(Is("past its edge"))
            .words_look(Is({ size: 13.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=1400.0,
    h=800.0,
    platform=2,
  )
  t.draw()
  let (x, _, w, _) = t.shown_of("past its edge").unwrap()
  assert_eq(x, 1000.0 - 20.0)
  assert_true(w > 20.0, msg="\{w}")
  // closing: cut to the column as it narrows
  side_changing("test", ["a"], "a", false)
  open.set(false)
  t.draw()
  t.run_for(@ui.move_most_ms / 2.0)
  match t.shown_of("past its edge") {
    Some((x, _, _, _)) => assert_true(x > 1000.0, msg="\{x}")
    None => ()
  }
  side_slide_reset()
}
