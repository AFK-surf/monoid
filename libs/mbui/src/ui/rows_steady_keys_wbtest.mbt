// Rows steady on a page's list (View::scrolls_window), what moves its rows with it at once: its keys changed with no
// way of theirs (lists_seen.mbt's `way_with_keys`), its head grown over its keys (TreeListSteady's `start`), and what
// is only drawn over its top (its `cover`), which moves none of them.

///|
/// A list of rows 0, 1 and 2 (or 3 in 2's place where `swapped`), at once as its keys change, row 0 as tall as `first`
/// says, row 1 holding a part shown while `part` is (its way closing it as it goes); its head as tall as `head`, what
/// covers its top as tall as `cover`.
fn rows_keys_app(
  first : @signals.Signal[Double],
  part : @signals.Signal[Bool],
  swapped : @signals.Signal[Bool],
  head : @signals.Signal[Double],
  cover : @signals.Signal[Double],
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=400.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      col.scrolls_window(
        @view.Scroll::list(),
        fn() { if swapped.get() { [0, 1, 3] } else { [0, 1, 2] } },
        est=40.0,
        comes=fn(_) { false },
        goes=fn(_) { false },
        top_covered=fn() { cover.get() },
        head=fn(h) { h.width(Is(Some(300.0))).height(By(fn() { Some(head.get()) })) |> ignore },
        fn(b, k) {
          b.width(Is(Some(200.0))) |> ignore
          match k {
            0 => b.height(By(fn() { Some(first.get()) })).ground(Is(0x334455FFL)).words(Is("首行")) |> ignore
            1 => {
              b.ground(Is(0x445566FFL)) |> ignore
              b.box(fn(w) { w.height(Is(Some(40.0))).words(Is("第1行")) |> ignore }) |> ignore
              b.show(fn() { part.get() }, fn(p) { p.height(Is(Some(60.0))).words(Is("可收起")) |> ignore })
            }
            _ => b.height(Is(Some(40.0))).ground(Is(0x556677FFL)).words(Is("第\{k}行")) |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  t
}

///|
test "rows steady: a list's keys changed at once as a part in a row closes on its way, a row over it another height at once: the rows moved by that no step of theirs" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let first = @signals.signal(54.0)
  let part = @signals.signal(true)
  let swapped = @signals.signal(false)
  let head = @signals.signal(0.0)
  let cover = @signals.signal(0.0)
  let t = rows_keys_app(first, part, swapped, head, cover)
  view_event(fn() {
    swapped.set(true)
    first.set(41.0)
    part.set(false)
  })
  for _ in 0..<8 {
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="rows moved by a change of its keys at once judged a step")
}

///|
test "rows steady: the same with its keys as they were: the row over it stepping at once while a part under it closes on its way is caught" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let first = @signals.signal(54.0)
  let part = @signals.signal(true)
  let swapped = @signals.signal(false)
  let head = @signals.signal(0.0)
  let cover = @signals.signal(0.0)
  let t = rows_keys_app(first, part, swapped, head, cover)
  view_event(fn() {
    first.set(41.0)
    part.set(false)
  })
  for _ in 0..<8 {
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_true(found.length() > 0, msg="a row's step at once while the list's keys stayed was not caught")
}

///|
test "rows steady: what covers a list's top grown at once, drawn over what it shows, moves none of its rows: no step of theirs; its head grown at once over its keys moves them all with it: none either" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let first = @signals.signal(40.0)
  let part = @signals.signal(false)
  let swapped = @signals.signal(false)
  let head = @signals.signal(20.0)
  let cover = @signals.signal(0.0)
  let t = rows_keys_app(first, part, swapped, head, cover)
  view_event(fn() { cover.set(60.0) })
  for _ in 0..<4 {
    t.frame_as_host() |> ignore
  }
  view_event(fn() { head.set(80.0) })
  for _ in 0..<4 {
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="rows judged a step as what covers the list or its head changed: \{Repr(found)}")
}

///|
test "rows steady: an old Ctx::list hidden under an ancestor with alpha 0.0 is skipped, while a visible one stepping row height in one frame is caught" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let run = fn(hidden : Bool) -> Array[String] {
    let first_h = @signals.signal(40.0)
    let t = Tester::new(
      fn(c) {
        let wrap = c.box(w=Px(300.0), h=Px(300.0), fn() {
          c.list("rows", 3, 40.0, fn(i) {
            let h = if i == 0 { first_h.get() } else { 40.0 }
            c.box(w=Px(200.0), h=Px(h), bg=0x445566FFL, fn() {
              c.text("第\{i}行", size=14.0) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        if hidden {
          c.look(wrap, { ..still_look, alpha: 0.0 })
        }
      },
      w=300.0,
      h=300.0,
      platform=0,
    )
    rows_steady_bars[rows_steady.file] = 99
    sizes_steady_bars[sizes_steady.file] = 99
    t.draw()
    t.run_for(row_size_ms * 2.0)
    t.frame()
    t.frame()
    first_h.set(122.0)
    t.frame()
    t.frame()
    t.frame()
    rows_steady.found.iter().collect()
  }
  let hidden_found = run(true)
  assert_eq(hidden_found, [], msg="hidden Ctx::list should not trigger rows_steady: \{Repr(hidden_found)}")
  let visible_found = run(false)
  assert_true(visible_found.length() > 0, msg="visible Ctx::list stepping row height in one frame was not caught")
}
