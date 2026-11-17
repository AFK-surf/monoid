// Sizes steady across (sizes_steady.mbt, measure_across): what draws steps no more along a row than down a column. A
// ground's left edge and width and where words start are measured as its top and height are; words that say another thing
// are new words where they stand across.

///|
/// A row in a window 400 by 200: a box as wide as `lead` says, then a box on a ground of its own as wide as `wide` says,
/// then words saying what `said` says. Sizes steady said but not held (its faults read here).
fn across_case(
  lead : @signals.Signal[Double],
  wide : @signals.Signal[Double],
  said : @signals.Signal[String],
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, words_over_held=false)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      r.box(fn(b) { b.width(By(fn() { Some(lead.get()) })).height(Is(Some(40.0))) |> ignore }) |> ignore
      r.box(fn(b) {
        b.width(By(fn() { Some(wide.get()) })).height(Is(Some(40.0))).ground(Is(0x336699FFL)) |> ignore
      })
      |> ignore
      r.box(fn(b) { b.words(By(fn() { said.get() })) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// `frames` frames drawn one at a time, the display's; what sizes steady finds in each, down a column and across.
fn across_frames(t : Tester, frames : Int) -> (Array[String], Array[String]) {
  let down = []
  let across = []
  for _ in 0..<frames {
    t.frame()
    for f in g().sizes_faults(t.fake.time, t.period) {
      if f.0 {
        across.push(f.1)
      } else {
        down.push(f.1)
      }
    }
  }
  (down, across)
}

///|
test "sizes across: a ground and words stepping along their row in a frame, each found across and nothing down; at rest, none" {
  let lead = @signals.signal(100.0, same=fn(a, b) { a == b })
  let t = across_case(lead, @signals.signal(80.0), @signals.signal("刚刚"))
  let rest = across_frames(t, 4)
  lead.set(140.0)
  let (down, across) = across_frames(t, 4)
  assert_eq(rest, ([], []))
  assert_eq(down, [])
  // (each found once, as what is made at its line: the ground's box and the words')
  assert_true(across.any(fn(f) { f.contains("sizes_across_wbtest.mbt:19") }), msg="a ground stepping 40 along its row: \{Repr(across)}")
  assert_true(across.any(fn(f) { f.contains("sizes_across_wbtest.mbt:23") }), msg="words stepping 40 along their row: \{Repr(across)}")
}

///|
test "sizes across: a ground stepping 60 wider in a frame, its width found" {
  let wide = @signals.signal(80.0, same=fn(a, b) { a == b })
  let t = across_case(@signals.signal(100.0), wide, @signals.signal("x"))
  across_frames(t, 4) |> ignore
  wide.set(140.0)
  let (_, across) = across_frames(t, 4)
  assert_true(across.any(fn(f) { f.contains("its width") }), msg="a ground 60 wider at once: \{Repr(across)}")
}

///|
test "sizes across: words that say another thing, as wide as it is, are new words: none" {
  let said = @signals.signal("刚刚", same=fn(a, b) { a == b })
  let t = across_case(@signals.signal(100.0), @signals.signal(80.0), said)
  across_frames(t, 4) |> ignore
  said.set("处理中，还要一会儿")
  assert_eq(across_frames(t, 4), ([], []))
}

///|
test "sizes across: a box going along its row a frame at a time, as a way does, none" {
  let lead = @signals.signal(100.0, same=fn(a, b) { a == b })
  let t = across_case(lead, @signals.signal(80.0), @signals.signal("刚刚"))
  across_frames(t, 4) |> ignore
  let out = []
  for k in 1..=8 {
    lead.set(100.0 + 5.0 * k.to_double())
    let (d, a) = across_frames(t, 1)
    out.append(d)
    out.append(a)
  }
  assert_eq(out, [])
}
