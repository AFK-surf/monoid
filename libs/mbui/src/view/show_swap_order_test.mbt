// A show opening in the place of one closing next to it down a column at one moment (View::goes' `swaps`,
// View::arrives): the one opening sets out from as tall as the other was, whichever of the two the change took first.

///|
/// The word drawn `w`'s top, as the tree is drawn now; none: -1.
fn swap_top(t : @view.Tree, w : String) -> Double {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => d.y
    _ => -1.0
  }
}

///|
test "a show opening over one closing next to it at one moment, either taken first: from as tall as that one was, what is under them one way" {
  for opens_first in [true, false] {
    let a_on = @signals.signal(true, same=fn(a, b) { a == b })
    let b_on = @signals.signal(false, same=fn(a, b) { a == b })
    let t = @view.Tree::new(fn(root) {
      root.box(fn(h) { h.height(Is(Some(20.0))).words(Is("头")) |> ignore }) |> ignore
      // (the one opening over the one closing: made first where the change takes its show first)
      root.show(fn() { b_on.get() }, fn(v) { v.height(Is(Some(30.0))).words(Is("B")) |> ignore })
      root.show(fn() { a_on.get() }, fn(v) { v.height(Is(Some(56.0))).words(Is("A")) |> ignore })
      root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
    })
    t.frame(390.0, 844.0) |> ignore
    let before = swap_top(t, "下")
    assert_eq(before, 76.0)
    t.event(100.0, fn() {
      if opens_first {
        b_on.set(true)
        a_on.set(false)
      } else {
        a_on.set(false)
        b_on.set(true)
      }
    })
    let ys = []
    let mut i = 0
    while i <= 60 {
      t.at(100.0 + i.to_double() * 1000.0 / 120.0)
      t.frame(390.0, 844.0) |> ignore
      ys.push(swap_top(t, "下"))
      i = i + 1
    }
    // (as it was at the change's moment: B from A's 56, not from nothing)
    assert_eq(ys[0], before, msg="\{opens_first}: \{Repr(ys)}")
    let mut ups = 0
    for j in 1..<ys.length() {
      if ys[j] > ys[j - 1] + 0.01 {
        ups = ups + 1
      }
    }
    assert_eq(ups, 0, msg="\{opens_first}: 下 went back down on its way up: \{Repr(ys)}")
    assert_eq(ys[ys.length() - 1], 50.0, msg="\{opens_first}")
  }
}
