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
