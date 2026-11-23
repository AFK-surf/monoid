// What comes or goes in a page's list's pinned foot (a show in it: View::comes) makes its way from the foot's foot: what
// is last in the foot (the composer's own line) stays at the list's foot in every frame, never dropping under what
// shows and coming back, and the rows over the foot go up as it opens and down as it closes, one way.

///|
/// A page's list 300 by 400 of rows 0 to 9 (40 each) following its foot; its pinned foot a column of 件 (30 tall) while
/// `part`, over 栏 (20 tall). Drawn once, at 0.
fn lfc_case(part : @signals.Signal[Bool]) -> @view.Tree {
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { Array::makei(10, fn(i) { i }) },
        est=40.0,
        follows=fn() { true },
        foot=fn(f) {
          f.box(fn(c) {
            c.show(fn() { part.get() }, fn(p) { p.height(Is(Some(30.0))).shrink(Is(0.0)).words(Is("件")) |> ignore })
            c.box(fn(w) { w.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("栏")) |> ignore }) |> ignore
          })
          |> ignore
        },
        fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
/// Where the words `w` are drawn: their top and bottom (rc_none where none).
fn lfc_ends(t : @view.Tree, w : String) -> (Double, Double) {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => (d.y, d.y + d.h)
    _ => (rc_none, rc_none)
  }
}

///|
test "a part come in a list's pinned foot: what is last in the foot stays at the list's foot, the rows over it going up, at every look" {
  for opens in [true, false] {
    let part = @signals.signal(!opens, same=fn(a, b) { a == b })
    let t = lfc_case(part)
    let (row0, _) = lfc_ends(t, "行9")
    t.advance(rc_at)
    part.set(opens)
    let mut was = row0
    let mut ms = 0.0
    while ms <= 600.0 {
      t.frame(390.0, 844.0, now=rc_at + ms) |> ignore
      let (_, bottom) = lfc_ends(t, "栏")
      assert_true((bottom - 400.0).abs() < 0.5, msg="opens \{opens}, at \{ms}: 栏's bottom at \{bottom}, 400 wanted")
      let (row, _) = lfc_ends(t, "行9")
      if opens {
        assert_true(row <= was + 0.01, msg="opens \{opens}, at \{ms}: 行9 down from \{was} to \{row}")
      } else {
        assert_true(row >= was - 0.01, msg="opens \{opens}, at \{ms}: 行9 up from \{was} to \{row}")
      }
      was = row
      ms = ms + 1000.0 / 60.0
    }
    let moved = if opens { row0 - was } else { was - row0 }
    assert_true((moved - 30.0).abs() < 0.5, msg="opens \{opens}: 行9 moved \{moved}, 30 wanted")
  }
}
