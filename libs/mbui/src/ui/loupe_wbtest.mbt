// What a finger hides, for a loupe (loupe.mbt): where a finger reads, and a node showing the frame larger.

///|
test "a node magnifying (View::magnifies): what the frame drew round its point, larger, in it; none once it says none" {
  let at = @signals.signal(Some((200.0, 275.0, 2.0)), same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0)
  set_view_app(fn(root) {
    root.box(fn(b) { b.over(Is(true)).ground(Is(0xFFFFFFFFL)) |> ignore }) |> ignore
    root.box(fn(b) {
      b.over(Is(true)).offset(Is((190.0, 270.0))).width(Is(Some(20.0))).height(Is(Some(10.0))).ground(Is(0x336699FFL))
      |> ignore
    })
    |> ignore
    root.box(fn(l) {
      l
      .over(Is(true))
      .width(Is(Some(120.0)))
      .height(Is(Some(48.0)))
      .radius(Is(24.0))
      .ground(Is(0xFFFFFFFFL))
      .magnifies(By(fn() { at.get() }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let copied = fn() {
    let c = g()
    let out = []
    for k in 0..<c.ninst {
      let q = k * inst_size
      if c.inst[q + 2] == 40.0 && c.inst[q + 3] == 20.0 {
        out.push(c.inst[q] + 20.0)
      }
    }
    out
  }
  // (about the node's middle: its own middle where the point was)
  assert_eq(copied(), [60.0])
  at.set(None)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(copied(), [])
}

///|
test "where a finger reads: none unless it drags what needs seeing" {
  let t = Tester::new(fn(c) { c.box(w=Fill(1.0), h=Fill(1.0), fn() {  }) |> ignore }, w=400.0, h=400.0, platform=2)
  t.press_at(100.0, 100.0)
  assert_eq(finger_reads(), None)
  t.release(100.0, 100.0)
}
