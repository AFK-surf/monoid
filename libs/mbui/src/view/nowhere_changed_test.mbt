// What is laid out nowhere (View::laid_nowhere: a page under the one on top) changes: none of it laid out while it is
// (what it holds, a list laid out alone in it too: flex's hidden_gen, Tree::alone_laid_out), and shown again it is laid
// out as it is now, as one made so.

///|
test "laid nowhere and changed: none of it laid out while it is, shown again laid out as it is now" {
  let nowhere = @signals.signal(false, same=fn(a, b) { a == b })
  let rows = @signals.signal(3, same=fn(a, b) { a == b })
  let tall = @signals.signal(10.0, same=fn(a, b) { a == b })
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.box(fn(page) {
          page.laid_nowhere(By(fn() { nowhere.get() })) |> ignore
          page.box(fn(first) {
            ids["first"] = first.id()
            first.height(By(fn() { Some(tall.get()) })) |> ignore
          })
          |> ignore
          page.each(
            fn() { Array::makei(rows.get(), fn(i) { i }) },
            fn(k) { k.to_string() },
            fn(r, _) { r.height(Is(Some(20.0))) |> ignore },
            at_once=true,
          )
          |> ignore
          page.box(fn(last) {
            ids["last"] = last.id()
            last.height(Is(Some(5.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 600.0) |> ignore
  assert_eq(t.drawn_of(ids["last"]).map(fn(d) { d.y }), Some(70.0))
  nowhere.set(true)
  t.frame(400.0, 600.0) |> ignore
  // (changed while laid out nowhere: a row more, the first taller; none of it laid out)
  let laid_before = t.work().laid
  rows.set(5)
  tall.set(30.0)
  t.frame(400.0, 600.0) |> ignore
  // (what holds it alone laid out again: the root and its column)
  assert_true(t.work().laid - laid_before <= 2)
  assert_true(t.drawn_of(ids["last"]) is None)
  // (shown: laid out as it is now)
  nowhere.set(false)
  t.frame(400.0, 600.0) |> ignore
  assert_eq(t.drawn_of(ids["first"]).map(fn(d) { d.h }), Some(30.0))
  assert_eq(t.drawn_of(ids["last"]).map(fn(d) { d.y }), Some(130.0))
}
