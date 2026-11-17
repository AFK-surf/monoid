// What is read as pointed at (View::pointed) is pointed at, whatever it takes of the hand: one that takes no press (a
// mark a tip says, a status) as the pointer comes over it, as one said to point is (View::points); what takes a press
// under it or in it taking it as ever. Before, only what took a press could be pointed at, so a tip on what took none
// never showed (the sync key's, #6151 to #6855).

///|
priv struct ReadCase {
  tree : @view.Tree
  card : Ref[@view.View?]
  mark : Ref[@view.View?]
  key : Ref[@view.View?]
}

///|
/// A card 300 wide taking a press, holding a row: a mark 40 wide at 0 to 40 taking nothing, its pointed read
/// (as a tip reads it), then a key 60 wide at 40 to 100 taking a press, its pointed read too.
fn read_case() -> ReadCase {
  let card_at : Ref[@view.View?] = Ref(None)
  let mark : Ref[@view.View?] = Ref(None)
  let key : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(
    fn(root) {
      root.box(fn(card) {
        card_at.val = Some(card)
        card.width(Is(Some(300.0))).height(Is(Some(100.0))).on_press(fn() {  }) |> ignore
        card.box(fn(r) {
          r.row(Is(true)) |> ignore
          r.box(fn(m) {
            mark.val = Some(m)
            m.width(Is(Some(40.0))).height(Is(Some(40.0))) |> ignore
          })
          |> ignore
          r.box(fn(k) {
            key.val = Some(k)
            k.width(Is(Some(60.0))).height(Is(Some(40.0))).on_press(fn() {  }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  tree.frame(390.0, 844.0) |> ignore
  { tree, card: card_at, mark, key }
}

///|
/// Whether the mark and the key are pointed at with the pointer at (x, y).
fn ReadCase::at(self : ReadCase, x : Double, y : Double) -> (Bool, Bool) {
  self.tree.frame(390.0, 844.0) |> ignore
  self.tree.point_at(x, y)
  self.tree.frame(390.0, 844.0) |> ignore
  @signals.untracked(fn() { (self.mark.val.unwrap().pointed(), self.key.val.unwrap().pointed()) })
}

///|
test "what takes no press, read as pointed at, is pointed at as the pointer comes over it" {
  let c = read_case()
  // (read first, as a tip reads it as it is made)
  @signals.untracked(fn() { (c.mark.val.unwrap().pointed(), c.key.val.unwrap().pointed()) }) |> ignore
  assert_eq(c.at(20.0, 20.0), (true, false))
  assert_eq(c.at(70.0, 20.0), (false, true))
  assert_eq(c.at(200.0, 60.0), (false, false))
  assert_eq(c.at(20.0, 20.0), (true, false))
  assert_eq(c.at(-1.0, -1.0), (false, false))
}

///|
test "what is read as pointed at takes no press for itself: a press on it goes to what holds it" {
  let c = read_case()
  @signals.untracked(fn() { c.mark.val.unwrap().pointed() }) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  let card = c.card.val.unwrap().id()
  let key = c.key.val.unwrap().id()
  assert_true(c.tree.target_at(20.0, 20.0) is Pressed(id) && id == card, msg="on the mark: the card's")
  assert_true(c.tree.target_at(70.0, 20.0) is Pressed(id) && id == key, msg="on the key: the key's")
}

///|
test "said not to point, what takes no press is not pointed at, read so or not" {
  let c = read_case()
  c.mark.val.unwrap().points(Is(false)) |> ignore
  @signals.untracked(fn() { c.mark.val.unwrap().pointed() }) |> ignore
  assert_eq(c.at(20.0, 20.0), (false, false))
}
