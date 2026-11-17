// A shared element's old copy (View::shared, shared.mbt's Tree::paired) takes nothing as it flies: what in it reads
// whether it takes input (View::takes_input, a tip's anchor say) is told so at that change, as a node said to take no
// press is, never left saying it takes input while working it out whole says it takes none.

///|
test "an old copy flying holds what reads whether it takes input: told it takes none, as worked out whole" {
  let flight : @view.Flight = { way: fn(_) { (200.0, fn(ms) { ms / 200.0 }) } }
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  let inner : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.show(fn() { !open.get() }, fn(t) {
        t.width(Is(Some(40.0))).height(Is(Some(40.0))).shared(Is("a"), flight) |> ignore
        t.box(fn(k) {
          inner.val = Some(k)
          k
          .width(Is(Some(10.0)))
          .height(Is(Some(10.0)))
          .ground(By(fn() { if k.takes_input() { 0xFF0000FFL } else { 0x0000FFFFL } }))
          |> ignore
        })
        |> ignore
      })
      p.show(fn() { open.get() }, fn(b) { b.height(Is(Some(100.0))).shared(Is("a"), flight) |> ignore })
    })
    |> ignore
  })
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let k = inner.val.unwrap()
  assert_true(@signals.untracked(fn() { k.takes_input() }))
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  // (its old copy flying under the new one: what it holds takes nothing, and is told so)
  assert_true(k.alive())
  assert_false(@signals.untracked(fn() { k.takes_input() }))
  assert_eq(tree.kept_inputs_said(), None)
  tree.frame(400.0, 800.0, now=1100.0) |> ignore
  assert_eq(tree.kept_inputs_said(), None)
}
