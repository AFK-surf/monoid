// One line of words in a column, no width said (Tree::capped_applied, an old view's `capped`): no wider than the
// column, cut short there; a most said held to the column's width where it has less (Within); in a row, said a width
// or wrapped, as wide as it is or as said. The same node told otherwise, as it changes; past a slot (show's) alike.

///|
/// Words 210 wide on one line (30 characters, 7 each, as words_measure counts them: wrapped where they say so), in a box
/// 100 wide that is a row as `row` says, with a width and a most as `width` and `most` say, wrapping as `wrap` says;
/// `shown`, made by a show in the box (past its slot). How wide they are drawn.
fn capped_tree(
  row : @signals.Signal[Bool],
  width : @signals.Signal[Double?],
  most : @signals.Signal[Double?],
  wrap : @signals.Signal[Bool],
  box_w? : @signals.Signal[Double?] = @signals.signal(Some(100.0)),
  shown? : Bool = false,
) -> () -> Double {
  let id : Ref[@view.NodeId?] = Ref(None)
  let words = fn(w : @view.View) {
    id.val = Some(w.id())
    w
    .words(Is("abcdefghijklmnopqrstuvwxyz0123"))
    .words_look(By(fn() { { ..@view.words_plain, wrap: wrap.get() } }))
    .width(By(fn() { width.get() }))
    .max_width(By(fn() { most.get() }))
    |> ignore
  }
  let t = @view.Tree::new(
    fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(c) {
        c.width(By(fn() { box_w.get() })).lines_up(Is(Some(Start))).row(By(fn() { row.get() })) |> ignore
        if shown {
          c.show(fn() { true }, words)
        } else {
          c.box(words) |> ignore
        }
      })
      |> ignore
    },
    // (on one line as wide as all of them, as a host measures words that do not wrap)
    measure=fn(s, look, w, k) { if look.wrap { @view.words_measure(s, look, w, k) } else { (s.length().to_double() * 7.0, 18.0) } },
    time=fn() { 0.0 },
  )
  fn() {
    t.frame(390.0, 844.0) |> ignore
    match t.drawn().search_by(fn(d) { Some(d.id) == id.val }) {
      Some(i) => t.drawn()[i].w
      None => -1.0
    }
  }
}

///|
test "one line of words in a column: as wide as the column; a most said, that where the column has more, the column's where it has less; said none again, the column's; in a row, said a width or wrapped, as it is; past a slot alike" {
  for shown in [false, true] {
    let row = @signals.signal(false)
    let width : @signals.Signal[Double?] = @signals.signal(None)
    let most : @signals.Signal[Double?] = @signals.signal(None)
    let wrap = @signals.signal(false)
    let box_w : @signals.Signal[Double?] = @signals.signal(Some(100.0))
    let w = capped_tree(row, width, most, wrap, box_w~, shown~)
    let seen = []
    seen.push(w())
    most.set(Some(150.0))
    seen.push(w())
    most.set(Some(80.0))
    seen.push(w())
    most.set(None)
    seen.push(w())
    row.set(true)
    seen.push(w())
    box_w.set(Some(300.0))
    seen.push(w())
    most.set(Some(150.0))
    seen.push(w())
    most.set(None)
    box_w.set(Some(100.0))
    row.set(false)
    seen.push(w())
    width.set(Some(180.0))
    seen.push(w())
    width.set(None)
    wrap.set(true)
    seen.push(w())
    wrap.set(false)
    seen.push(w())
    // (column 100: 100; most 150: 100; most 80: 80; none again: 100; row 100: 100 via last_resort; row 300: 210
    // uncapped; row 300 + most 150: 150; column 100 again: 100; 180 said: 180; wrapped: within the column; one line
    // again: 100)
    assert_eq(
      seen,
      [100.0, 100.0, 80.0, 100.0, 100.0, 210.0, 150.0, 100.0, 180.0, 100.0, 100.0],
      msg="shown \{shown}: \{Repr(seen)}",
    )
  }
}


///|
/// A box cut short (View::cuts, an old view's `w=Cut`), 320 at least where there is the room and 560 at most, holding
/// words that wrap and one line of words, each as long as `long` makes them, in a column `col` wide that lines what it
/// holds up at its start (a request's card in a chat: ui's `ask_card_room`). How wide the box is drawn.
fn cut_card_tree(col : @signals.Signal[Double], long : Int, cut : @signals.Signal[Bool]) -> () -> Double {
  let id : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(c) {
        c.width(By(fn() { Some(col.get()) })).lines_up(Is(Some(Start))) |> ignore
        c.box(fn(k) {
          id.val = Some(k.id())
          k.cuts(By(fn() { cut.get() })).min_width(Is(Some(320.0)), within=true).max_width(Is(Some(560.0))) |> ignore
          k.box(fn(w) {
            w.words(Is("word ".repeat(long))).words_look(Is({ ..@view.words_plain, wrap: true })) |> ignore
          })
          |> ignore
          k.box(fn(w) {
            w.words(Is("x".repeat(long))).words_look(Is({ ..@view.words_plain, wrap: false })) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    // (on one line as wide as all of them, as a host measures words that do not wrap)
    measure=fn(s, look, w, k) { if look.wrap { @view.words_measure(s, look, w, k) } else { (s.length().to_double() * 7.0, 18.0) } },
    time=fn() { 0.0 },
  )
  fn() {
    t.frame(1000.0, 844.0) |> ignore
    match t.drawn().search_by(fn(d) { Some(d.id) == id.val }) {
      Some(i) => t.drawn()[i].w
      None => -1.0
    }
  }
}

///|
test "cut short in a column: no wider than the column, its most said where the column has more, its least where it has the room; as wide as what it holds where that is less; not cut, its most alone" {
  let col = @signals.signal(390.0)
  let cut = @signals.signal(true)
  // (what it holds far wider than 560: a phone's column, a wide one, a narrow one; not cut short, 560 past the column)
  let w = cut_card_tree(col, 200, cut)
  let seen = []
  seen.push(w())
  col.set(760.0)
  seen.push(w())
  col.set(200.0)
  seen.push(w())
  col.set(390.0)
  cut.set(false)
  seen.push(w())
  cut.set(true)
  seen.push(w())
  assert_eq(seen, [390.0, 560.0, 200.0, 560.0, 390.0], msg="\{Repr(seen)}")
  // (what it holds narrow: 320 at least where the column has the room)
  let w = cut_card_tree(@signals.signal(390.0), 2, @signals.signal(true))
  assert_eq(w(), 320.0)
}
