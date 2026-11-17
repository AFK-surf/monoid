// A node's words with a ground wider than a line (a long path's label): its pieces torn where it goes on, drawn as
// shapes (Ctx::paint_run_grounds) by their own pieces, wherever the frame's pieces stand when the node is composed:
// after another node's shape, and drawn again as kept.

///|
test "a node's label torn across its lines is drawn whole by its own pieces, after a shape drawn before it" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let label : Ground = { room: 0.6, height: 2.0, corner: 0.5, after: 0.0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      // (a shape before it: the frame's pieces do not begin at its own)
      page.box(fn(n) {
        n
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .shapes(Is([@paint.shape_of([([0.0, 0.0, 20.0, 0.0, 20.0, 20.0], true)], fill=0xCC3333FFL)]))
        |> ignore
      })
      |> ignore
      page.box(fn(n) {
        n
        .width(Is(Some(60.0)))
        .words_runs(
          Is([span("aaaa bbbb cccc", code=true, bg=0x112233FFL, ground=Some(label))]),
          look={ size: 10.0, weight: 400, line: 24.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let look = fn() raise {
    let bands = t.drawn_shapes().filter(fn(b) { b.5 == 0x112233FFL })
    assert_true(bands.length() >= 4, msg="torn on more lines than one: \{Repr(bands)}")
    // (a band's middle lies inside its ground: its teeth only at its two ends, its height 20 in bands of 8)
    for b in bands {
      let (x, y, w, h, _, _) = b
      let cover = t.shape_cover(x + w / 2.0, y + h / 2.0)
      assert_true(cover > 0.99, msg="the middle of the band at \{x}, \{y} covered \{cover}")
    }
  }
  look()
  // (drawn again as kept, by the same pieces)
  t.draw()
  look()
}
