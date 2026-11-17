// Inline drawings (a formula's outlines: Span::drawing) in a node's words_runs: their bands' pieces kept with the
// node's ViewBlock from 0 and offset by where the frame's pieces stand each time the node is composed, after shapes
// drawn before it and alongside shapes drawn after it, both when first made and when drawn again as kept.

///|
test "inline drawings in a node's words_runs keep their own pieces across frames, between other nodes' shapes" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  let ring = fn(x : Double, y : Double, s : Double, back : Bool) -> (Array[Double], Bool) {
    if back {
      ([x, y, x, y + s, x + s, y + s, x + s, y], true)
    } else {
      ([x, y, x + s, y, x + s, y + s, x, y + s], true)
    }
  }
  let d1 : InlineDrawing = {
    width: 2.0,
    height: 2.0,
    baseline: 1.5,
    paths: [[ring(0.0, 0.0, 2.0, false), ring(0.5, 0.5, 1.0, true)]],
    words: [],
  }
  let d2 : InlineDrawing = {
    width: 2.0,
    height: 2.0,
    baseline: 1.5,
    paths: [[ring(0.0, 0.0, 2.0, false), ring(0.5, 0.5, 1.0, true)]],
    words: [],
  }
  let blue = 0x1559C4FFL
  let green = 0x117733FFL
  set_view_app(fn(root) {
    root.ground(Is(0xFFFFFFFFL)) |> ignore
    root.box(fn(page) {
      // (a shape before the card: the frame's pieces do not begin at the card's own)
      page.box(fn(n) {
        n
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .shapes(Is([@paint.shape_of([ring(0.0, 0.0, 20.0, false), ring(5.0, 5.0, 10.0, true)], fill=0xCC3333FFL)]))
        |> ignore
      })
      |> ignore
      page.box(fn(card) {
        card
        .width(Is(Some(240.0)))
        .padding(Is((8.0, 8.0, 8.0, 8.0)))
        .edge(Is((1.0, 0xCCCCCCFFL)))
        .box(fn(n) {
          n
          .fills_across(Is(true))
          .ink(Is(0x111111FFL))
          .words_runs(
            Is([
              plain("a "),
              span("x_1", color=blue, drawing=Some(d1)),
              plain(" + "),
              span("x_2", color=green, drawing=Some(d2)),
              plain(" = 0"),
            ]),
            look={ size: 10.0, weight: 400, line: 24.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // (and another shape after it, so pieces past the card's own exist in the frame too)
      page.box(fn(n) {
        n
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .shapes(Is([@paint.shape_of([ring(0.0, 0.0, 20.0, false)], fill=0x884400FFL)]))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let bounds_of = fn(color : Int64) -> (Double, Double, Double, Double) {
    let bs = t.drawn_shapes().filter(fn(b) { b.5 == color })
    let mut x0 = 1.0e9
    let mut y0 = 1.0e9
    let mut x1 = -1.0e9
    let mut y1 = -1.0e9
    for b in bs {
      if b.0 < x0 {
        x0 = b.0
      }
      if b.1 < y0 {
        y0 = b.1
      }
      if b.0 + b.2 > x1 {
        x1 = b.0 + b.2
      }
      if b.1 + b.3 > y1 {
        y1 = b.1 + b.3
      }
    }
    (x0, y0, x1 - x0, y1 - y0)
  }
  let look = fn() raise {
    for pair in [("first formula", blue), ("second formula", green)] {
      let (name, color) = pair
      let (x, y, w, h) = bounds_of(color)
      assert_true(w >= 20.0 && h >= 20.0, msg="\{name} bounds: \{x}, \{y}, \{w}, \{h}")
      // (the band carries 1pt of margin around its 20x20 outline: its rim is inked, its 10x10 hole stays clear)
      let cx = x + w / 2.0
      let cy = y + h / 2.0
      assert_true(t.shape_cover(cx - 7.5, cy) > 0.99, msg="\{name} left rim covered")
      assert_true(t.shape_cover(cx + 7.5, cy) > 0.99, msg="\{name} right rim covered")
      assert_eq(t.shape_cover(cx, cy), 0.0, msg="\{name} hole stays clear, not filled as a solid block")
    }
  }
  t.draw()
  look()
  // (drawn again from its kept ViewBlock via view_blit)
  t.draw()
  look()
}
