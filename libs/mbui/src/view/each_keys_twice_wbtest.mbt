///|
/// Where a device met it: a page's chips (still.fail's 更换模型, how hard it thinks) each by its words, the words a
/// made-up value's as the page was read (`默认|字|字|字`): the same key three times put the one row's node in the slot
/// three times, and its box in the row's laid out once, the tree's kept boxes no longer what it holds (switches_still's
/// screen 31, main 9dbcbbe0). A key said again is the row it is, where it first is.
test "a key said more than once in each's items: one row, where it first is, its box laid out once" {
  let items = @signals.signal(["a", "b"], same=fn(a, b) { a == b })
  let made = Ref(0)
  let slot_at = Ref(-1)
  let t = Tree::new(
    fn(root) {
      root.box(fn(r) {
        r.row(Is(true)).wraps(Is(Some(8.0))) |> ignore
        r.each(fn() { items.get() }, fn(k) { k }, fn(c, _) {
          made.val += 1
          c.width(Is(Some(40.0))).height(Is(Some(20.0))) |> ignore
        })
        slot_at.val = r.tree.nodes[r.at].kids[0]
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.kept_said(), None)
  assert_eq(made.val, 2)
  items.set(["a", "b", "b", "b"])
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.kept_said(), None)
  assert_eq(made.val, 2)
  assert_eq(t.nodes[slot_at.val].kids.length(), 2)
  items.set(["c", "a", "c", "b"])
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.kept_said(), None)
  assert_eq(made.val, 3)
  assert_eq(t.nodes[slot_at.val].kids.length(), 3)
}
