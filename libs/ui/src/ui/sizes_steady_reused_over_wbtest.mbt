// Sizes steady (sizes_steady.mbt) beside a page's list's blocks taken for other keys (View::scrolls_window's
// `reused`) and beside what is laid over what holds it (View::over). A block taken for another key draws that key's
// parts in the same nodes: what they were for the key before is another's, never one thing stepping, whether the block
// left sight and came back in one frame or was put by out of sight between (Tree::reused_epoch_of); the same key's
// part stepping in a quiet frame is a fault as ever. What is laid over what holds it is moved by no way in or out of
// what flows beside it, nor what flows by its way (Tree::on_way_at): an answer done at once in either while the other
// is on its way is no jolt.

///|
/// The faults sizes steady finds in each of `frames` frames drawn one at a time, the display's: down a column and
/// across, as one.
fn rso_frames(t : Tester, frames : Int) -> Array[String] {
  let out = []
  for _ in 0..<frames {
    t.frame()
    for f in g().sizes_faults(t.fake.time, t.period) {
      out.push(f.1)
    }
  }
  out
}

///|
/// How wide key `k`'s bubble is: one key to the next, another width.
fn rso_width(k : Int) -> Double {
  [300.0, 140.0, 220.0, 180.0][k % 4]
}

///|
/// A page's list 300 wide and 200 tall in a window 400 by 300 of 40 keys, each block of one kind taken for other keys,
/// 40 tall, a bubble on a ground of its own as wide as its key says (rso_width), key 1's `boost` wider. Sizes steady
/// said but not held (its faults read here).
fn rso_list(place : @view.ListPlace[Int], boost : @signals.Signal[Double]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, words_over_held=false)
  t.check_looks(false)
  let s = @view.Scroll::list()
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      page.scrolls_window(
        s,
        fn() { Array::makei(40, fn(i) { i }) },
        est=40.0,
        place~,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          b.box(fn(w) {
            w
            .width(By(fn() { Some(rso_width(key()) + (if key() == 1 { boost.get() } else { 0.0 })) }))
            .height(Is(Some(40.0)))
            .ground(Is(0x336699FFL))
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "sizes steady: a page's list's blocks taken for other keys by a wheel's turn draw those keys' widths, no fault" {
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let t = rso_list(place, @signals.signal(0.0))
  rso_frames(t, 4) |> ignore
  // (one turn of 400: the blocks of the first rows taken for rows far down in one frame, seen in the frame before)
  t.wheel(150.0, 100.0, 400.0)
  let found = rso_frames(t, 30)
  assert_eq(found, [], msg="blocks taken by a wheel's turn: \{Repr(found)}")
}

///|
test "sizes steady: a page's list put at its foot at once, its blocks in sight taken for keys in sight there in that frame, no fault" {
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let t = rso_list(place, @signals.signal(0.0))
  rso_frames(t, 4) |> ignore
  // (no hand on it: the blocks of the first rows, in sight in the frame before, taken for the last rows, in sight in
  // this one, no frame between)
  place.to_end(glide=false)
  let found = rso_frames(t, 30)
  assert_eq(found, [], msg="blocks taken as it is put at its foot: \{Repr(found)}")
}

///|
test "sizes steady: a page's list's blocks taken for other keys as it glides to a key draw those keys' widths, no fault" {
  if test_at_a_rate() {
    return
  }
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let t = rso_list(place, @signals.signal(0.0))
  rso_frames(t, 4) |> ignore
  // (a key a viewport and three fifths down, near enough to glide to: blocks leaving its top put by out of sight, then
  // taken for keys coming in at its foot)
  place.bring(8, glide=true)
  let there = rso_frames(t, 60)
  // (and back up again)
  place.bring(0, glide=true)
  let back = rso_frames(t, 60)
  assert_eq((there, back), ([], []), msg="blocks taken as it glides: \{Repr(there)} \{Repr(back)}")
}

///|
test "sizes steady: a block not taken for another key, its bubble stepping wider in a quiet frame: a fault, as ever" {
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let boost = @signals.signal(0.0, same=fn(a, b) { a == b })
  let t = rso_list(place, boost)
  rso_frames(t, 4) |> ignore
  boost.set(60.0)
  let found = rso_frames(t, 4)
  assert_true(found.any(fn(f) { f.contains("its width") }), msg="key 1's bubble 60 wider at once: \{Repr(found)}")
}

///|
/// A column 300 wide in a window 400 by 400: a box 40 tall on a ground, what `coming` shows (a box 60 tall on a
/// ground, on its way in as it comes), and a bar laid over the column (View::over, in a show as a page's bar is) holding
/// a row: a box as wide as `lead` says, then a button-like box 40 by 30 on a ground of its own; and what `over_coming`
/// shows in it laid over too (a box on its way in). Sizes steady said but not held.
fn rso_over(
  coming : @signals.Signal[Bool],
  lead : @signals.Signal[Double],
  h : @signals.Signal[Double],
  over_coming : @signals.Signal[Bool],
) -> (Tester, Ref[@view.View?], Ref[@view.View?]) {
  let button : Ref[@view.View?] = Ref(None)
  let last : Ref[@view.View?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, words_over_held=false)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))) |> ignore
      col.box(fn(b) { b.width(Is(Some(200.0))).height(Is(Some(40.0))).ground(Is(0x336699FFL)) |> ignore }) |> ignore
      col.show(fn() { coming.get() }, fn(s) {
        s.box(fn(b) { b.width(Is(Some(200.0))).height(Is(Some(60.0))).ground(Is(0x669933FFL)) |> ignore }) |> ignore
      })
      col.box(fn(b) {
        last.val = Some(b)
        b.width(Is(Some(200.0))).height(By(fn() { Some(h.get()) })).ground(Is(0x996633FFL)) |> ignore
      })
      |> ignore
      col.show(fn() { true }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(bar) {
          bar.row(Is(true)).height(Is(Some(30.0))) |> ignore
          bar.box(fn(b) { b.width(By(fn() { Some(lead.get()) })).height(Is(Some(30.0))) |> ignore }) |> ignore
          bar.box(fn(b) {
            button.val = Some(b)
            b.width(Is(Some(40.0))).height(Is(Some(30.0))).ground(Is(0x333333FFL)) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      col.show(fn() { true }, fn(o) {
        o.over(Is(true), from_top=true) |> ignore
        o.show(fn() { over_coming.get() }, fn(s) {
          s.box(fn(b) { b.width(Is(Some(120.0))).height(Is(Some(50.0))).ground(Is(0x999933FFL)) |> ignore })
          |> ignore
        })
      })
    })
    |> ignore
  })
  t.draw()
  (t, button, last)
}

///|
test "sizes steady: an answer stepping a button in a bar laid over a column while a part flows in beside it: no fault, on no way" {
  let coming = @signals.signal(false)
  let lead = @signals.signal(0.0, same=fn(a, b) { a == b })
  let (t, button, _) = rso_over(coming, lead, @signals.signal(100.0), @signals.signal(false))
  rso_frames(t, 4) |> ignore
  // (a cause's part making its way in, in the column's flow, under way as the answer comes)
  coming.set(true)
  rso_frames(t, 3) |> ignore
  let b = button.val.unwrap()
  let x0 = b.placed_window_now().0
  @view.answering(fn() { lead.set(34.0) })
  let on_way = b.tree.on_way_at(b.at, t.fake.time)
  let found = rso_frames(t, 6)
  let x1 = b.placed_window_now().0
  assert_eq((on_way, found, x1 - x0), (false, [], 34.0), msg="the bar's button: \{on_way} \{Repr(found)} \{x1 - x0}")
}

///|
test "sizes steady: an answer stepping a height in a column while a part laid over it comes its way: no fault, on no way" {
  let over_coming = @signals.signal(false)
  let h = @signals.signal(100.0, same=fn(a, b) { a == b })
  let (t, _, last) = rso_over(@signals.signal(false), @signals.signal(0.0), h, over_coming)
  rso_frames(t, 4) |> ignore
  // (what is laid over the column making its way in, under way as the answer comes)
  over_coming.set(true)
  rso_frames(t, 3) |> ignore
  @view.answering(fn() { h.set(180.0) })
  let on_way = last.val.unwrap().tree.on_way_at(last.val.unwrap().at, t.fake.time)
  let found = rso_frames(t, 6)
  assert_eq((on_way, found), (false, []), msg="the column's height: \{on_way} \{Repr(found)}")
}

///|
test "sizes steady: an answer stepping a height in a column while a part flows in beside it: a fault, as ever" {
  let coming = @signals.signal(false)
  let h = @signals.signal(100.0, same=fn(a, b) { a == b })
  let (t, _, last) = rso_over(coming, @signals.signal(0.0), h, @signals.signal(false))
  rso_frames(t, 4) |> ignore
  coming.set(true)
  rso_frames(t, 3) |> ignore
  @view.answering(fn() { h.set(180.0) })
  let on_way = last.val.unwrap().tree.on_way_at(last.val.unwrap().at, t.fake.time)
  assert_true(on_way && rso_frames(t, 4).length() > 0, msg="a step while a part flows in beside it: none found")
}
