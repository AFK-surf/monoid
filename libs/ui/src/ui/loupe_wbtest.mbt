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

///|
test "a node magnifying shows words inked by the adaptive glass under them, in their own ink" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=400.0)
  set_view_app(fn(root) {
    root.box(fn(b) { b.over(Is(true)).ground(Is(0xFFFFFFFFL)) |> ignore }) |> ignore
    root.box(fn(bar) {
      bar
      .over(Is(true))
      .offset(Is((20.0, 280.0)))
      .width(Is(Some(260.0)))
      .height(Is(Some(48.0)))
      .radius(Is(24.0))
      .glass(Is(Some(Glass::liquid())))
      |> ignore
      bar.box(fn(w) { w.offset(Is((16.0, 14.0))).words(Is("words in glass"), ink=0x222222FFL) |> ignore }) |> ignore
    })
    |> ignore
    root.box(fn(l) {
      l
      .over(Is(true))
      .offset(Is((20.0, 150.0)))
      .width(Is(Some(124.0)))
      .height(Is(Some(48.0)))
      .radius(Is(24.0))
      .ground(Is(0xFFFFFFFFL))
      .magnifies(Is(Some((70.0, 304.0, 1.35))))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let c = g()
  let mut inked = 0
  let mut shown = 0
  for k in 0..<c.ninst {
    let q = k * inst_size
    let a = c.inst
    let inside = a[q] >= 20.0 && a[q] <= 144.0 && a[q + 1] >= 150.0 && a[q + 1] <= 198.0
    if a[q + 5] == 7.0 && !inside {
      inked = inked + 1
    }
    if a[q + 5] == 1.0 && inside {
      shown = shown + 1
    }
  }
  // (the bar's words inked by its glass, those of them round the point shown larger in the loupe as glyphs)
  assert_true(inked > 0, msg="the bar's words inked by its glass")
  assert_true(shown > 0, msg="the bar's words magnified in the loupe")
}

///|
test "a finger low on a field's handle reads the middle of the line its tip is under, not the handle" {
  let f = Field::new(text="注意有必要的生态库 hello world")
  let t = Tester::new(fn(_c) {  }, w=390.0, h=400.0, platform=2, pointing=Finger, native=Finger)
  set_view_app(fn(root) {
    root.box(fn(box) {
      box.over(Is(true)).offset(Is((20.0, 300.0))).width(Is(Some(340.0))) |> ignore
      field(box, f, label="字", font_size=17.0, max_lines=4) |> ignore
    })
    |> ignore
  })
  t.draw()
  t.press_at(80.0, 312.0)
  t.run_for(long_press_ms + 20.0)
  t.release(80.0, 312.0)
  t.draw()
  let st = f.st
  assert_true(st.sel_on)
  let line_h = match st.tl {
    Some(tl) => tl.line_h
    None => 0.0
  }
  let middle = st.sel_ay - line_h / 2.0
  // (the start's handle, its ball's middle a radius left of and under its tip; the finger near its foot)
  let (hx, hy) = (st.sel_ax - handle_r, st.sel_ay + handle_r + 10.0)
  t.press_at(hx, hy)
  t.draw()
  assert_eq(finger_reads(), Some((hx, middle)))
  t.move_to(hx - 5.0, hy)
  t.draw()
  assert_eq(finger_reads(), Some((hx - 5.0, middle)))
  t.release(hx - 5.0, hy)
  t.draw()
  assert_eq(finger_reads(), None)
}

///|
test "a node magnifying leaves out a field's handles, over everything as a window of their own" {
  let f = Field::new(text="注意有必要的生态库 hello world")
  let t = Tester::new(fn(_c) {  }, w=390.0, h=400.0, platform=2, pointing=Finger, native=Finger)
  set_view_app(fn(root) {
    root.box(fn(box) {
      box.over(Is(true)).offset(Is((20.0, 300.0))).width(Is(Some(340.0))) |> ignore
      field(box, f, label="字", font_size=17.0, max_lines=4) |> ignore
    })
    |> ignore
    root.box(fn(l) {
      l
      .over(Is(true))
      .offset(Is((20.0, 150.0)))
      .width(Is(Some(124.0)))
      .height(Is(Some(48.0)))
      .radius(Is(24.0))
      .ground(Is(0xFFFFFFFFL))
      .magnifies(By(fn() { finger_reads().map(fn(p) { (p.0, p.1 + 12.0, 1.35) }) }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.press_at(80.0, 312.0)
  t.run_for(long_press_ms + 20.0)
  t.release(80.0, 312.0)
  t.draw()
  let st = f.st
  let (hx, hy) = (st.sel_ax - handle_r, st.sel_ay + handle_r)
  t.press_at(hx, hy)
  t.draw()
  let c = g()
  let mut glyphs = 0
  let mut drops = 0
  for k in 0..<c.ninst {
    let q = k * inst_size
    let a = c.inst
    if a[q + 1] >= 150.0 && a[q + 1] <= 198.0 {
      if a[q + 5] == 1.0 {
        glyphs = glyphs + 1
      }
      // (a drop's circle or its corner, its 18 or 9 across larger by the zoom)
      if a[q + 5] == 0.0 && ((a[q + 2] - 2.0 * handle_r * 1.35).abs() < 0.5 || (a[q + 2] - handle_r * 1.35).abs() < 0.5) {
        drops = drops + 1
      }
    }
  }
  // (read a little lower, the drops' tops in it if they were copied)
  assert_true(glyphs > 0, msg="the field's words magnified")
  assert_eq(drops, 0, msg="no handle's drop in the loupe")
  t.release(hx, hy)
  t.draw()
}
