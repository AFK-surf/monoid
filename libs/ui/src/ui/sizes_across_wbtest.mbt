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

///|
/// A row in a window 400 by 200: a box as wide as `lead` says, then a tip 44 wide on a ground of its own, 10 in from
/// each side, drawn as big as `grow` says about its middle, holding a box of words put off where it is laid out by
/// `shift`. Sizes steady said but not held (its faults read here).
fn across_tip_case(
  lead : @signals.Signal[Double],
  grow : @signals.Signal[Double],
  shift : @signals.Signal[Double],
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, words_over_held=false)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      r.box(fn(b) { b.width(By(fn() { Some(lead.get()) })).height(Is(Some(40.0))) |> ignore }) |> ignore
      r.box(fn(b) {
        b
        .width(Is(Some(44.0)))
        .padding(Is((10.0, 4.0, 10.0, 4.0)))
        .ground(Is(0x336699FFL))
        .scale(By(fn() { grow.get() }), about=At(0.5, 0.5))
        |> ignore
        b.box(fn(w) { w.words(Is("更多")).offset(By(fn() { (shift.get(), 0.0) })) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// One frame `ms` on (the display's next where 0), what sizes steady finds across in it.
fn across_tip_frame(t : Tester, ms? : Double = 0.0) -> Array[String] {
  t.frame(ms~)
  g().sizes_faults(t.fake.time, t.period).filter(fn(f) { f.0 }).map(fn(f) { f.1 })
}

///|
test "sizes across: a tip stopping dead as it starts to shrink about its middle, laid out again in the frame: the tip said, never the words it carries" {
  // (frames it walks itself, judged by the default run alone: test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let lead = @signals.signal(100.0, same=fn(a, b) { a == b })
  let grow = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = across_tip_case(lead, grow, @signals.signal(0.0))
  for _ in 0..<4 {
    across_tip_frame(t) |> ignore
  }
  let out = []
  for k in 1..=3 {
    lead.set(100.0 + 10.0 * k.to_double())
    out.append(across_tip_frame(t))
  }
  // (stopped, and shrinking: its words go 10 * (1 - s) less than its edge in the frame, under 0.01 at first, then, laid
  // out again 5 ms on in that same frame, past it)
  grow.set(0.9995)
  let stop = across_tip_frame(t)
  grow.set(0.997)
  let again = across_tip_frame(t, ms=5.0)
  out.append(stop)
  out.append(again)
  let found : Set[String] = Set([])
  for f in out {
    found.insert(
      match f.find(": ") {
        Some(i) => f.unsafe_substring(start=0, end=i)
        None => f
      },
    )
  }
  assert_true(stop.length() == 1 && stop[0].contains("stopped dead"), msg="the tip stopping dead: \{Repr(stop)}")
  assert_true(again.all(fn(f) { !f.has_prefix("text") }), msg="the words it carries, said apart: \{Repr(again)}")
  assert_eq(found.length(), 1, msg="each frame the tip alone: \{Repr(out)}")
}

///|
test "sizes across: words jumping along in a tip as it shrinks about its middle: the words found" {
  if test_at_a_rate() {
    return
  }
  let lead = @signals.signal(100.0, same=fn(a, b) { a == b })
  let grow = @signals.signal(1.0, same=fn(a, b) { a == b })
  let shift = @signals.signal(0.0, same=fn(a, b) { a == b })
  let t = across_tip_case(lead, grow, shift)
  for _ in 0..<4 {
    across_tip_frame(t) |> ignore
  }
  let out = []
  for k in 1..=3 {
    lead.set(100.0 + 10.0 * k.to_double())
    out.append(across_tip_frame(t))
  }
  grow.set(0.997)
  shift.set(24.0)
  for _ in 0..<3 {
    out.append(across_tip_frame(t))
  }
  assert_true(out.any(fn(f) { f.has_prefix("text") && f.contains("sizes_across_wbtest.mbt:119") }), msg="words 24 off in a frame: \{Repr(out)}")
}
