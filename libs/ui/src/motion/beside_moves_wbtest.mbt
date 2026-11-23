// A panel beside the anchor a signal names (View::beside_by), its ground and its words going for that signal's change
// (moves_for: the ground changing shape, the words going): where a change lays it out is beside its new anchor
// (View::laid_window_now through what goes beside another), so it shows first beside its anchor, never at the
// window's top left; goes from the one it was by to the next, wider as its words are, and stops beside it; turned
// to a third on its way, going on from where it was as fast as it went; moved by nothing it moves for (its anchor moved,
// the window made narrower), at once with its anchor, nothing set going. The same at each moment, frames drawn all along
// or none.

///|
let beside_ground : Int64 = 0x223344FFL

///|
let beside_names : Array[String] = ["A", "Wider words here", "Mid words"]

///|
/// Where the anchors are across (from the window's middle, their row centred) and how wide each is, how tall, and how
/// far the row is from the window's top.
let beside_anchor_w : Array[Double] = [40.0, 80.0, 60.0]

///|
let beside_anchor_h : Double = 32.0

///|
let beside_row_top : Double = 20.0

///|
/// A moment well into a Move between two anchors, before its end.
let beside_mid_ms : Double = 60.0

///|
/// Long enough for every way here to be over.
let beside_over_ms : Double = 1000.0

///|
/// Three anchors in a row centred across the window (`left` more room before them), and a panel beside the one `sel`
/// names, saying its name, its ground and words going for `sel` (moves_for, a Move). The Tester and what moves.
fn beside_tester(
  sel : @signals.Signal[Int],
  left? : @signals.Signal[Double] = @signals.signal(0.0),
  moves? : Ref[Moves?] = Ref(None),
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let ids : Array[@view.NodeId] = []
    root.box(fn(o) {
      o.lines_up(Is(Some(Middle))).padding(Is((0.0, beside_row_top, 0.0, 0.0))) |> ignore
      o.box(fn(r) {
        r.row(Is(true)).gap(Is(20.0)).padding(By(fn() { (left.get(), 0.0, 0.0, 0.0) })) |> ignore
        for w in beside_anchor_w {
          let a = r.box(fn(a) { a.width(Is(Some(w))).height(Is(Some(beside_anchor_h))).ground(Is(0xEEEEEEFFL)) |> ignore })
          ids.push(a.id())
        }
      })
      |> ignore
    })
    |> ignore
    root.box(fn(p) {
      p
      .beside_by(By(fn() { ids[sel.get()] }), side=Bottom, along=Middle, offset=4.0)
      .row(Is(true))
      .padding(Is((8.0, 4.0, 8.0, 4.0)))
      .ground(Is(beside_ground))
      .radius(Is(6.0))
      |> ignore
      let words_at = p.box(fn(k) {
        k.words(
          By(fn() { beside_names[sel.get()] }),
          ink=0xFFFFFFFFL,
          look={ size: 13.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 },
        )
        |> ignore
      })
      let m = moves_for(p, fn() { sel.get() }, spec=move_damped)
      m.reshapes(p)
      m.moves_with(words_at)
      moves.val = Some(m)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// What is drawn of the panel: its ground (x, y, w, h) and its words' first glyph (x, y); all -1 where none is drawn.
fn beside_seen(t : @ui.Tester) -> (Double, Double, Double, Double, Double, Double) {
  let g = t.drawn_rects().filter(fn(r) { r.4 == beside_ground })
  let w = t.drawn_glyphs()
  match (g.get(0), w.get(0)) {
    (Some(r), Some(f)) => (r.0, r.1, r.2, r.3, f.0, f.1)
    _ => (-1.0, -1.0, -1.0, -1.0, -1.0, -1.0)
  }
}

///|
/// Where anchor `k`'s middle across is, its row centred in a window `w` wide with `left` more room before it.
fn beside_anchor_mid(k : Int, w : Double, left : Double) -> Double {
  let row = beside_anchor_w.fold(init=0.0, fn(a, b) { a + b }) + 20.0 * 2.0 + left
  let mut x = (w - row) / 2.0 + left
  for i in 0..<k {
    x = x + beside_anchor_w[i] + 20.0
  }
  x + beside_anchor_w[k] / 2.0
}

///|
fn beside_near(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 1.0e-6
}

///|
/// The panel at rest beside anchor `k` from the start (no change, nothing going): what it is seen as.
fn beside_rest(k : Int) -> (Double, Double, Double, Double, Double, Double) {
  let t = beside_tester(@signals.signal(k))
  beside_seen(t)
}

///|
test "a panel beside the anchor a signal names: first shown beside it, never from the window's top left" {
  let sel = @signals.signal(0)
  let moves : Ref[Moves?] = Ref(None)
  let t = beside_tester(sel, moves~)
  let (x, y, w, _, _, _) = beside_seen(t)
  assert_true(beside_near(x + w / 2.0, beside_anchor_mid(0, 400.0, 0.0)), msg="middle under its anchor: \{x} \{w}")
  assert_true(beside_near(y, beside_row_top + beside_anchor_h + 4.0), msg="under its anchor: \{y}")
  assert_true(moves.val.unwrap().over(), msg="nothing set going as it first shows")
}

///|
test "a panel beside the anchor a signal names, the signal set to another: from where it was, wider on its way, beside the next as it stops" {
  // (where it stops, as one shown there from the start: first, a Tester reads the frame of the one made last)
  let rest1 = beside_rest(1)
  let sel = @signals.signal(0)
  let t = beside_tester(sel)
  let first = beside_seen(t)
  let t0 = t.time()
  sel.set(1)
  t.draw()
  let at0 = beside_seen(t)
  assert_eq(at0, first, msg="as the change comes: where and as wide as it was, its words too")
  t.run_for(beside_mid_ms)
  let (mx, my, mw, _, _, _) = beside_seen(t)
  let mid = mx + mw / 2.0
  let (from_mid, to_mid) = (beside_anchor_mid(0, 400.0, 0.0), beside_anchor_mid(1, 400.0, 0.0))
  assert_true(mid > from_mid && mid < to_mid, msg="on its way across: \{mid} between \{from_mid} and \{to_mid}")
  assert_true(mw > first.2 && mw < rest1.2, msg="wider on its way: \{mw} between \{first.2} and \{rest1.2}")
  assert_true(beside_near(my, first.1), msg="along the same line: \{my}")
  t.run_for(beside_over_ms - (t.time() - t0))
  assert_eq(beside_seen(t), rest1, msg="stopped beside the next, as one shown there from the start")
}

///|
/// The panel told anchor 1 at 0 and anchor 2 at 80, looked at `at` after: frames drawn every 16 all along, or none
/// till then. What is seen.
fn beside_turned(at : Double, stepped : Bool) -> (Double, Double, Double, Double, Double, Double) {
  let sel = @signals.signal(0)
  let t = beside_tester(sel)
  let t0 = t.time()
  let tree = @ui.view_tree().unwrap()
  tree.event(t0, fn() { sel.set(1) })
  if stepped {
    while t.time() + 16.0 < t0 + 80.0 {
      t.frame_at(t.time() + 16.0)
    }
  }
  // (the turn only where it is looked at after it: the clock never goes back)
  if at >= 80.0 {
    tree.event(t0 + 80.0, fn() { sel.set(2) })
  }
  if stepped {
    while t.time() + 16.0 < t0 + at {
      t.frame_at(t.time() + 16.0)
    }
  }
  t.frame_at(t0 + at)
  beside_seen(t)
}

///|
test "a panel beside the anchor a signal names, turned to a third on its way: at each moment the same, frames drawn all along or none; its place and speed going on where it turned; stopped beside the third" {
  let moments = [40.0, 80.0, 96.0, 160.0, 400.0, beside_over_ms]
  let all = moments.map(fn(at) { beside_turned(at, true) })
  let none = moments.map(fn(at) { beside_turned(at, false) })
  for k, a in all {
    assert_eq(a, none[k], msg="at \{moments[k]}: \{Repr(a)} / \{Repr(none[k])}")
  }
  assert_eq(all[all.length() - 1], beside_rest(2), msg="stopped beside the third")
  // (where it turned: no step there; as fast just after as just before, the same way)
  let mid = fn(s : (Double, Double, Double, Double, Double, Double)) { s.0 + s.2 / 2.0 }
  let before = mid(beside_turned(72.0, false))
  let at = mid(beside_turned(80.0, false))
  let after = mid(beside_turned(88.0, false))
  let (v0, v1) = (at - before, after - at)
  assert_true(v0 > 0.0 && v1 > 0.0, msg="on across all along: \{before} \{at} \{after}")
  assert_true(v1 / v0 > 0.5 && v1 / v0 < 2.0, msg="as fast where it turned: \{v0} then \{v1}")
}

///|
test "a panel beside the anchor a signal names, at rest: its anchor moved, the window made narrower: with it at once, nothing set going" {
  let sel = @signals.signal(1)
  let left = @signals.signal(0.0)
  let moves : Ref[Moves?] = Ref(None)
  let t = beside_tester(sel, left~, moves~)
  left.set(60.0)
  t.draw()
  let (x, _, w, _, _, _) = beside_seen(t)
  assert_true(beside_near(x + w / 2.0, beside_anchor_mid(1, 400.0, 60.0)), msg="with its anchor moved: \{x} \{w}")
  assert_true(moves.val.unwrap().over(), msg="nothing going for its anchor moved")
  t.resize(360.0, 300.0)
  let (x, _, w, _, _, _) = beside_seen(t)
  assert_true(beside_near(x + w / 2.0, beside_anchor_mid(1, 360.0, 60.0)), msg="with the window narrower: \{x} \{w}")
  assert_true(moves.val.unwrap().over(), msg="nothing going for the window")
}

///|
/// Two anchors, 40 and 160 wide, in a row centred across the window, and a panel beside the one `sel` names as wide as
/// it (BesideWidth's Anchor), its words broken into lines in that width, its ground and words going for `sel`.
fn beside_wide_tester(sel : @signals.Signal[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let ids : Array[@view.NodeId] = []
    root.box(fn(o) {
      o.lines_up(Is(Some(Middle))).padding(Is((0.0, beside_row_top, 0.0, 0.0))) |> ignore
      o.box(fn(r) {
        r.row(Is(true)).gap(Is(20.0)) |> ignore
        for w in [40.0, 160.0] {
          let a = r.box(fn(a) { a.width(Is(Some(w))).height(Is(Some(beside_anchor_h))).ground(Is(0xEEEEEEFFL)) |> ignore })
          ids.push(a.id())
        }
      })
      |> ignore
    })
    |> ignore
    root.box(fn(p) {
      p
      .beside_by(By(fn() { ids[sel.get()] }), side=Bottom, along=Middle, offset=4.0, width=Anchor)
      .padding(Is((4.0, 4.0, 4.0, 4.0)))
      .ground(Is(beside_ground))
      |> ignore
      let words_at = p.box(fn(k) {
        k.words(
          Is("words that break into lines as wide as the anchor is"),
          ink=0xFFFFFFFFL,
          look={ size: 13.0, weight: 400, line: 18.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
        )
        |> ignore
      })
      let m = moves_for(p, fn() { sel.get() }, spec=move_damped)
      m.reshapes(p)
      m.moves_with(words_at)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a panel as wide as the anchor a signal names, its words in lines: to a wider anchor, wider and shorter on its way, as one shown there from the start once it stops" {
  let rest = beside_seen(beside_wide_tester(@signals.signal(1)))
  let sel = @signals.signal(0)
  let t = beside_wide_tester(sel)
  let first = beside_seen(t)
  assert_true(beside_near(first.2, 40.0), msg="as wide as the narrow one: \{first.2}")
  assert_true(first.3 > rest.3, msg="taller there, its words in more lines: \{first.3} against \{rest.3}")
  sel.set(1)
  t.draw()
  assert_eq(beside_seen(t), first, msg="as the change comes: as it was")
  t.run_for(beside_mid_ms)
  let (_, _, mw, mh, _, _) = beside_seen(t)
  assert_true(mw > first.2 && mw < rest.2, msg="wider on its way: \{mw}")
  assert_true(mh < first.3 && mh > rest.3, msg="shorter on its way: \{mh}")
  t.run_for(beside_over_ms)
  assert_eq(beside_seen(t), rest, msg="stopped as one shown beside the wide one from the start")
}
