// A page's list said `flips` (View::scrolls_window) drawing each change from where it all was as the change came: what
// a block holds that is made anew in the place of a part let go of in the same change (a pick turned to another part,
// the tree making it in the same node's place, Tree::made) comes as a part that was nowhere, never from where the part
// let go of was; and a block in the slots' margin alone, drawn nowhere and only counted as the change came, comes into
// sight with the one under it, never from the spacer it was counted as. Looked at in one jump and at 60, 120, 24 and 7
// a second (rc_walk, from list_rows_come_test).

///|
/// A page's list 300 by 400 of keys 0 to 9 (行k, 40 each) following its foot, said `flips`; block 9 holds a row 120 wide
/// at its right end, two parts 60 by 20 across, made a column of 第一行 and 第二行 (44 each) and 240 wide as `open`
/// says (a pick); the line that holds it put in `row` as it is made. Drawn once, at 0.
fn fw_pick_case(
  open : @signals.Signal[Bool],
  row : Ref[@view.View?],
) -> @view.Tree {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        b.box(fn(w) { w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore }) |> ignore
        if k == 9 {
          b.box(fn(line) {
            row.val = Some(line)
            line.row(Is(true)) |> ignore
            line.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
            line.box(fn(p) {
              p.width(By(fn() { Some(if open.get() { 240.0 } else { 120.0 }) })).shrink(Is(0.0)) |> ignore
              p.pick(fn() { open.get() }, fn(s, open) {
                if open {
                  s.box(fn(c) {
                    c.box(fn(a) { a.height(Is(Some(44.0))).shrink(Is(0.0)).words(Is("第一行")) |> ignore }) |> ignore
                    c.box(fn(a) { a.height(Is(Some(44.0))).shrink(Is(0.0)).words(Is("第二行")) |> ignore }) |> ignore
                  })
                  |> ignore
                } else {
                  s.box(fn(c) {
                    c.row(Is(true)) |> ignore
                    c.box(fn(a) { a.width(Is(Some(60.0))).height(Is(Some(20.0))).words(Is("甲")) |> ignore }) |> ignore
                    c.box(fn(a) { a.width(Is(Some(60.0))).height(Is(Some(20.0))).words(Is("乙")) |> ignore }) |> ignore
                  })
                  |> ignore
                }
              })
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
/// Where the words `w` are drawn now: top and how tall; rc_none where they are not.
fn fw_drawn(t : @view.Tree, w : String) -> (Double, Double) {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => (d.y, d.h)
    _ => (rc_none, rc_none)
  }
}

///|
test "flips: a block's row turned by a pick to a column of two lines, made in the places the row's parts were let go of: the two lines never drawn over each other, the second 44 under the first at every look" {
  let looks = [rc_at, rc_at + 16.0, rc_at + 33.0, rc_at + 50.0, rc_at + 100.0, rc_at + 200.0, rc_at + 600.0]
  for rate in rc_rates {
    let open = @signals.signal(false, same=fn(a, b) { a == b })
    let row : Ref[@view.View?] = Ref(None)
    let tree = fw_pick_case(open, row)
    let got = rc_walk(tree, [(rc_at, fn() {
      @view.transition(fn() {
        row.val.unwrap().resizes() |> ignore
        open.set(true)
      })
    })], looks, rate, fn() { (fw_drawn(tree, "第一行"), fw_drawn(tree, "第二行")) })
    for i, g in got {
      let ((y1, h1), (y2, _)) = g
      let at = "at \{rate} a second, at \{looks[i]}"
      assert_true(y1 != rc_none && y2 != rc_none, msg="\{at}: not drawn \{Repr(g)}")
      assert_true(y2 >= y1 + h1 - 0.5, msg="\{at}: 第二行 drawn over 第一行 \{Repr(g)}\n\{Repr(got)}")
      assert_true((y2 - y1 - 44.0).abs() < 0.5, msg="\{at}: 第二行 \{y2 - y1} under 第一行, 44 wanted\n\{Repr(got)}")
    }
  }
}

///|
/// A page's list 300 by 300 opened at its foot following it, said `flips`, counted 80 a block before it is measured:
/// keys 0 to 9, 行k, blocks 0 to 6 420 tall, 7 and 8 70, 9 as `nine` says (220, then 120); block 9 put in `last` as it
/// is made. Drawn once, at 0.
fn fw_margin_case(nine : @signals.Signal[Double], last : Ref[@view.View?]) -> @view.Tree {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(10, fn(i) { i }), same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=80.0, follows=fn() { true }, from_end=true, flips=true, fn(b, k) {
        if k == 9 {
          last.val = Some(b)
          b.height(By(fn() { Some(nine.get()) })).words(Is("行9")) |> ignore
        } else {
          b.height(Is(Some(if k < 7 { 420.0 } else { 70.0 }))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
test "flips: the block at its foot made 100 shorter, the list going down: a block 420 tall over it, in the slots' margin alone and counted 80 as the change came, comes into sight over the block under it at every look, never drawn down over it" {
  let looks = rc_looks(rc_at + 600.0)
  for rate in rc_rates {
    let nine = @signals.signal(220.0, same=fn(a, b) { a == b })
    let last : Ref[@view.View?] = Ref(None)
    let tree = fw_margin_case(nine, last)
    // (as it opens: 7 the first that shows, 6 over it drawn nowhere)
    assert_true(fw_drawn(tree, "行6").0 == rc_none, msg="行6 drawn as it opens \{Repr(fw_drawn(tree, "行6"))}")
    let y7 = fw_drawn(tree, "行7").0
    assert_true(y7 < 0.0 && y7 > -70.0, msg="行7 at \{y7} as it opens")
    let got = rc_walk(tree, [(rc_at, fn() {
      @view.transition(fn() {
        last.val.unwrap().resizes() |> ignore
        nine.set(120.0)
      })
    })], looks, rate, fn() { (fw_drawn(tree, "行6"), fw_drawn(tree, "行7").0) })
    for i, g in got {
      let ((y6, h6), y7) = g
      let at = "at \{rate} a second, at \{looks[i]}"
      if y6 != rc_none {
        assert_true(y6 + h6 <= y7 + 1.0, msg="\{at}: 行6's foot at \{y6 + h6}, 行7 at \{y7}\n\{Repr(got)}")
      }
    }
    let ((y6, h6), y7) = got.last().unwrap()
    assert_true((y6 + h6 - y7).abs() < 0.5, msg="at \{rate} a second, at rest: \{Repr(got.last())}")
  }
}
