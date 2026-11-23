// A page's list made with no keys, following its foot, given its first key by data: that key's block is laid out with
// the slot it comes in from the frame that takes it, all through its way in (its page saying it comes) or at once
// (saying it does not), and rests where a short list rests (its top, or the foot of what shows: `from_end`); so for a
// key given after the list was emptied again. Till 2026-11-15 the first key's slot was made only by the fill, after
// the change was taken: its block was laid out at nothing while its slot came in, blank all its way, and drawn whole
// only as it came to rest (list_window.mbt, `stale` at its foot). Looked at at 60, 120, 24 and 7 a second and in one
// jump (rc_walk).

///|
/// The moments looked at after the data's (rc_at): along its way, and well after it rests.
let fk_looks : Array[Double] = [16.0, 60.0, 120.0, 200.0, 1000.0]

///|
/// The words drawn `w`'s top and height, as the tree is drawn now; rc_none and 0 where none is.
fn fk_box(t : @view.Tree, w : String) -> (Double, Double) {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => (d.y, d.h)
    _ => (rc_none, 0.0)
  }
}

///|
/// Where `w` is drawn, and how tall, at each look after `keys` are given at `from` + rc_at, at `rate` a second.
fn fk_drawn(
  c : RcCase,
  keys : Array[Int],
  w : String,
  rate : Double,
  from? : Double = 0.0,
) -> Array[(Double, Double)] {
  rc_walk(
    c.tree,
    [(from + rc_at, fn() { c.keys.set(keys) })],
    fk_looks.map(fn(d) { from + rc_at + d }),
    rate,
    fn() { fk_box(c.tree, w) },
    from~,
  )
}

///|
/// Each look drew `w` with some of its height (`seen`), and at the end it is all there (`tall`), its top at `rest`.
fn fk_held(seen : Array[(Double, Double)], tall : Double, rest : Double, at : String) -> Unit raise {
  for i, b in seen {
    assert_true(b.0 != rc_none && b.1 > 0.0, msg="\{at}: \{b.1} of it drawn \{fk_looks[i]} ms after it came")
  }
  let (y, h) = seen[seen.length() - 1]
  assert_true((h - tall).abs() < 0.5 && (y - rest).abs() < 0.5, msg="\{at}: at rest \{h} tall at \{y}, \{tall} at \{rest} wanted")
}

///|
test "a page's list made with no keys lays out its first key's block with its slot from the frame that takes it, at every rate" {
  for from_end in [false, true] {
    for comes in [true, false] {
      for rate in rc_rates {
        let at = "\{if comes { "coming" } else { "at once" }}, from its end \{from_end}, at \{rate} a second"
        let c = rc_case([], comes=fn(_) { comes }, from_end~)
        fk_held(fk_drawn(c, [70], "行70", rate), 60.0, if from_end { 200.0 - 60.0 } else { 0.0 }, at)
      }
    }
  }
}

///|
test "a page's list emptied lays out the next key's block it is given from the frame that takes it, at every rate" {
  for from_end in [false, true] {
    for rate in rc_rates {
      let at = "from its end \{from_end}, at \{rate} a second"
      let c = rc_case([70], from_end~)
      // (its one key let go of, and well at rest)
      let gone = fk_drawn(c, [], "行70", rate)
      assert_eq(gone[gone.length() - 1].0, rc_none)
      fk_held(fk_drawn(c, [71], "行71", rate, from=rc_at + 1000.0), 40.0, if from_end { 200.0 - 40.0 } else { 0.0 }, at)
    }
  }
}

// A page's list that does not follow its foot, its blocks all coming in from none at once (from no keys, from keys let
// go of, under a head, or in place of all that showed under blocks kept above): what shows is held at the first of
// them, never at the last or at the first the list has no slot for. Till 2026-11-23 the anchor was found by the first
// block whose foot is past the top of what shows, and a block coming in from none is laid out at its top with no height
// yet: none of them was past it, so the list was held at its last block (or past the slots it keeps), and went there.

///|
/// A page's list 300 by 200 of `keys`, as rc_case's but not following its foot, a head `head` tall with words 头 where
/// it is given. Drawn once, at 0.
fn fk_still(keys : Array[Int], head? : Double) -> RcCase {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(keys, same=fn(a, b) { a == b })
  let head = head.map(fn(h) {
    fn(v : @view.View) { v.box(fn(b) { b.height(Is(Some(h))).shrink(Is(0.0)).words(Is("头")) |> ignore }) |> ignore }
  })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { false }, head?, fn(b, k) {
        b.height(Is(Some(rc_tall(k)))).words(Is("行\{k}")) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  { tree, scroll, keys }
}

///|
/// Where it is scrolled to and where `w` is drawn (fk_box) at each look after `keys` are given at `from` + rc_at.
fn fk_still_drawn(
  c : RcCase,
  keys : Array[Int],
  w : String,
  rate : Double,
  from? : Double = 0.0,
) -> Array[(Double, (Double, Double))] {
  rc_walk(
    c.tree,
    [(from + rc_at, fn() { c.keys.set(keys) })],
    fk_looks.map(fn(d) { from + rc_at + d }),
    rate,
    fn() { (c.scroll.at(c.tree), fk_box(c.tree, w)) },
    from~,
  )
}

///|
/// Each look scrolled to `at` with `w` drawn from `y` on, and at the end `tall` of it there. `gone_over`: what goes
/// above it shrinks away over it as it comes, so along the way only where it is scrolled to is looked at.
fn fk_still_held(
  seen : Array[(Double, (Double, Double))],
  at : Double,
  y : Double,
  tall : Double,
  msg : String,
  gone_over? : Bool = false,
) -> Unit raise {
  let last = seen.length() - 1
  for i, look in seen {
    let (s, (top, h)) = look
    let placed = (gone_over && i < last) || ((top - y).abs() < 0.5 && h > 0.0)
    assert_true(
      (s - at).abs() < 0.5 && placed,
      msg="\{msg}: \{fk_looks[i]} ms after it came scrolled to \{s}, \{h} of it drawn at \{top}; at \{at}, drawn at \{y} wanted",
    )
  }
  let (_, (_, h)) = seen[last]
  assert_true((h - tall).abs() < 0.5, msg="\{msg}: at rest \{h} tall, \{tall} wanted")
}

///|
test "a list not following its foot given keys from none holds at its first block, at every rate" {
  for n in [30, 80] {
    for rate in rc_rates {
      let c = fk_still([])
      let keys = Array::makei(n, fn(i) { i })
      fk_still_held(fk_still_drawn(c, keys, "行0", rate), 0.0, 0.0, 40.0, "\{n} keys at \{rate} a second")
    }
  }
}

///|
test "a list not following its foot emptied and given keys again holds at its first block, at every rate" {
  for rate in rc_rates {
    let c = fk_still(Array::makei(30, fn(i) { i }))
    let gone = fk_still_drawn(c, [], "行0", rate)
    assert_eq(gone[gone.length() - 1].1.0, rc_none)
    let keys = Array::makei(30, fn(i) { 100 + i })
    fk_still_held(fk_still_drawn(c, keys, "行100", rate, from=rc_at + 1000.0), 0.0, 0.0, 60.0, "at \{rate} a second")
  }
}

///|
test "a list not following its foot given keys from none under its head holds at its top, at every rate" {
  for rate in rc_rates {
    let c = fk_still([], head=48.0)
    let keys = Array::makei(30, fn(i) { i })
    fk_still_held(fk_still_drawn(c, keys, "行0", rate), 0.0, 48.0, 40.0, "at \{rate} a second")
  }
}

///|
test "a list not following its foot whose blocks in sight all give way to coming ones holds at the first that comes, at every rate" {
  // (what showed goes as what comes comes, the scroll held where it was all the way: the first that comes at the top
  // of what shows as all rests, never the last)
  for rate in rc_rates {
    let kept = [0, 1, 2]
    let was = kept.copy()
    was.append(Array::makei(20, fn(i) { 10 + i }))
    let c = fk_still(was)
    c.tree.event(1.0, fn() { c.scroll.put(120.0) })
    c.tree.at(1.0)
    c.tree.frame(390.0, 844.0) |> ignore
    let keys = kept.copy()
    keys.append(Array::makei(30, fn(i) { 100 + i }))
    fk_still_held(fk_still_drawn(c, keys, "行100", rate, from=1.0), 120.0, 0.0, 60.0, "at \{rate} a second", gone_over=true)
  }
}
