// A file of the drive coming down (download_chip_node): told a new share, its fill goes there as each frame is
// painted, from where it is, its chip as wide all along.

///|
test "a file coming down told a new share: its chip's fill goes there as each frame is painted, as wide as the share at its end" {
  let percent = @signals.signal(20, same=fn(a, b) { a == b })
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      h.box(fn(c) {
        c.width(Is(Some(120.0))) |> ignore
        download_chip_node(c, fn() { percent.get() })
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // (the fill: the accent at 20%; the chip's ground, the rect it starts at, as high)
  let fill = fn() { t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) == 51L }) }
  let first = fill()
  assert_eq(first.length(), 1, msg="\{Repr(t.drawn_rects())}")
  let ground = t.drawn_rects().filter(fn(r) { r.0 == first[0].0 && r.3 == first[0].3 && r.4 != first[0].4 })
  assert_eq(ground.length(), 1, msg="\{Repr(t.drawn_rects())}")
  let whole = ground[0].2
  assert_true((first[0].2 - whole * 0.2).abs() < 0.01, msg="\{Repr(first)} of \{whole}")
  // (told 60%: its fill told to go there, from where it is, with zero flex relayout)
  percent.set(60)
  t.draw()
  t.tree_frames_from_now()
  let end = t.time() + chip_fill_ms
  let widths : Array[Double] = []
  while t.time() < end {
    let w = t.wanted_after()
    if w == @double.infinity {
      break
    }
    t.frame_at(if w <= t.time() { t.next_frame_time() } else { t.display_frame(w) })
    match fill() {
      [r] => if !widths.contains(r.2) { widths.push(r.2) }
      f => widths.push(-f.length().to_double())
    }
  }
  t.frame_at(t.display_frame(end))
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="download_chip fill animation relaid out: \{Repr(f)}")
  }
  let ascending = widths.length() > 3 &&
    Array::makei(widths.length() - 1, fn(k) { widths[k] < widths[k + 1] }).iter().all(fn(b) { b })
  assert_true(ascending, msg="\{Repr(widths)}")
  match fill() {
    [r] => assert_true((r.2 - whole * 0.6).abs() < 0.01, msg="\{Repr(r)} of \{whole}")
    f => fail("\{Repr(f)}")
  }
}
