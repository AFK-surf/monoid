// Wait cycles (View::cycle) and resident cycles (View::cycle_resident) wake frames only while an awake, visible
// reader reads them: parked/covered subtrees (Nav/EachKept), laid-nowhere nodes, off-screen/clipped nodes, and
// zero-alpha ancestors wake zero idle frames; visible fade-from-0 cycles (self alpha == 0 at t == 0) still wake.

///|
test "the wait cycle: parked covered/deep readers wake zero frames and resume immediately when woken" {
  let active = @signals.signal(["a"], same=fn(a, b) { a == b })
  let kept = @signals.signal(["a"], same=fn(a, b) { a == b })
  let holding = @signals.signal(true, same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  set_view_app(fn(root) {
    root.each(
      at_once=true,
      fn() { active.get() },
      fn(k) { k },
      keeps=fn() { kept.get() },
      keeps_holds=fn(_) { holding.untracked() },
      fn(page, _) {
        page.box(fn(s) {
          s
          .width(Is(Some(16.0)))
          .height(Is(Some(16.0)))
          .ground(Is(0x3366CCFFL))
          .turn(By(fn() { s.cycle(turn_ms) * 2.0 * 3.141592653589793 }), drawn=true)
          |> ignore
        })
        |> ignore
      },
    )
  })
  t.draw()
  let tree = view_tree().unwrap()
  assert_true(tree.cycle_read(), msg="visible spinner reads cycle")
  assert_eq(t.wanted_after(), 0.0, msg="visible spinner asks host for next frame")
  let on0 = t.frames_on()
  t.frame_at(t.time() + 16.0)
  assert_true(t.frames_on() > on0, msg="visible spinner keeps requesting frames on clock")
  // Park into covered sleep (keeps_holds=true: signals stay watched, bindings are asleep — as Nav keeps a chat)
  active.set([])
  t.draw()
  assert_true(!tree.cycle_read(), msg="covered parked spinner must not report cycle_read")
  assert_eq(t.wanted_after(), @double.infinity, msg="covered parked spinner must ask host for no frame")
  let on_cov = t.frames_on()
  t.frame_at(t.time() + 16.0)
  assert_eq(t.frames_on(), on_cov, msg="covered parked spinner must wake zero clock frames")
  // Upgrade covered -> deep sleep (keeps_holds=false)
  holding.set(false)
  kept.set(["a", "x"])
  t.draw()
  assert_true(!tree.cycle_read(), msg="deep parked spinner must not report cycle_read")
  assert_eq(t.wanted_after(), @double.infinity, msg="deep parked spinner must ask host for no frame")
  // Wake the parked page back up: animates immediately
  active.set(["a"])
  t.draw()
  assert_true(tree.cycle_read(), msg="woken spinner resumes cycle_read")
  assert_eq(t.wanted_after(), 0.0, msg="woken spinner asks host for next frame again")
}

///|
test "the wait cycle: off-screen offset, clipped out, laid_nowhere, and zero-alpha ancestor wake nothing until visible again" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  let slide_x = @signals.signal(0.0)
  let clip_y = @signals.signal(0.0)
  let fade = @signals.signal(1.0)
  let shown = @signals.signal(true)
  set_view_app(fn(root) {
    // 1. Slid horizontally off-screen (like a closed sidebar panel)
    root.box(fn(panel) {
      panel.offset(By(fn() { (slide_x.get(), 0.0) })) |> ignore
      panel.box(fn(a) {
        a
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .ground(Is(0xFF0000FFL))
        .turn(By(fn() { a.cycle(turn_ms) * 2.0 * 3.141592653589793 }), drawn=true)
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Clipped outside an ancestor clip box (like a scrolled-away chat row spinner)
    root.box(fn(viewport) {
      viewport.width(Is(Some(100.0))).height(Is(Some(40.0))).clips(Is(true)) |> ignore
      viewport.box(fn(b) {
        b
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .offset(By(fn() { (0.0, clip_y.get()) }))
        .ground(Is(0x00FF00FFL))
        .turn(By(fn() { b.cycle(turn_ms) * 2.0 * 3.141592653589793 }), drawn=true)
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 3. Zero-alpha ancestor
    root.box(fn(holder) {
      holder.alpha(By(fn() { fade.get() })) |> ignore
      holder.box(fn(c) {
        c
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .ground(Is(0x0000FFFFL))
        .alpha(By(fn() { 0.5 + 0.5 * c.cycle(turn_ms) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 4. Laid out nowhere
    root.box(fn(d) {
      d
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0xFFFF00FFL))
      .laid_nowhere(By(fn() { !shown.get() }))
      .alpha(By(fn() { 0.5 + 0.5 * d.cycle(turn_ms) }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = view_tree().unwrap()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
  // Hide all four: zero extra frames woken
  slide_x.set(-400.0)
  clip_y.set(300.0)
  fade.set(0.0)
  shown.set(false)
  t.draw()
  assert_true(!tree.cycle_read(), msg="all hidden cycle readers must not report cycle_read")
  assert_eq(t.wanted_after(), @double.infinity, msg="all hidden cycle readers must ask host for no frame")
  // Slide first back on-screen: wakes again immediately
  slide_x.set(0.0)
  t.draw()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
  slide_x.set(-400.0)
  t.draw()
  assert_eq(t.wanted_after(), @double.infinity)
  // Scroll second back into clip viewport: wakes again immediately
  clip_y.set(10.0)
  t.draw()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
  clip_y.set(300.0)
  t.draw()
  assert_eq(t.wanted_after(), @double.infinity)
  // Restore third's ancestor alpha: wakes again immediately
  fade.set(1.0)
  t.draw()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
  fade.set(0.0)
  t.draw()
  assert_eq(t.wanted_after(), @double.infinity)
  // Restore fourth from laid_nowhere: wakes again immediately
  shown.set(true)
  t.draw()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
}

///|
test "the wait cycle: visible fade-from-0 (self alpha == 0 at t == 0) still reports cycle_read and animates" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .alpha(By(fn() { v.cycle(6000.0) }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = view_tree().unwrap()
  assert_true(tree.cycle_read(), msg="self alpha == 0 at t == 0 must not suppress cycle_read")
  assert_eq(t.wanted_after(), 0.0, msg="fade-from-0 must keep asking host for next frame")
  let on0 = t.frames_on()
  t.frame_at(t.time() + 16.0)
  assert_true(t.frames_on() > on0, msg="fade-from-0 continues animating on next frame")
}

///|
test "the wait cycle: stopping a visible cycle while an off-screen cycle remains stops waking frames" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  let active = @signals.signal(true)
  set_view_app(fn(root) {
    root.box(fn(a) {
      a
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0xFF0000FFL))
      .turn(By(fn() { if active.get() { a.cycle(turn_ms) * 2.0 * 3.141592653589793 } else { 0.0 } }), drawn=true)
      |> ignore
    })
    |> ignore
    root.box(fn(off) {
      off
      .offset(Is((-400.0, 0.0)))
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0x00FF00FFL))
      .turn(By(fn() { off.cycle(turn_ms) * 2.0 * 3.141592653589793 }), drawn=true)
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = view_tree().unwrap()
  assert_true(tree.cycle_read())
  assert_eq(t.wanted_after(), 0.0)
  active.set(false)
  t.draw()
  // Advance one beat so the stopped visible node's stale timestamp is pruned while the off-screen reader stays hidden.
  t.frame_at(t.time() + 16.0)
  assert_true(!tree.cycle_read(), msg="stopped visible + hidden off-screen must not report cycle_read")
  assert_eq(t.wanted_after(), @double.infinity, msg="must ask host for no further frames")
}

///|
test "the resident clock: parked covered/deep readers wake zero frames immediately" {
  let active = @signals.signal(["a"], same=fn(a, b) { a == b })
  let kept = @signals.signal(["a"], same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  set_view_app(fn(root) {
    root.each(
      at_once=true,
      fn() { active.get() },
      fn(k) { k },
      keeps=fn() { kept.get() },
      keeps_holds=fn(_) { true },
      fn(page, _) {
        page.box(fn(s) {
          s
          .width(Is(Some(20.0)))
          .height(Is(Some(20.0)))
          .ground(Is(0xFF0000FFL))
          .alpha(By(fn() { 0.5 + 0.5 * s.cycle_resident(turn_ms) }))
          |> ignore
        })
        |> ignore
      },
    )
  })
  t.draw()
  let tree = view_tree().unwrap()
  assert_true(tree.resident_read())
  assert_true(frames_in_a_second(t) >= 8)
  active.set([])
  t.draw()
  assert_true(!tree.resident_read(), msg="parked resident reader must not report resident_read")
  assert_eq(frames_in_a_second(t), 1, msg="parked resident reader must wake zero frames")
  active.set(["a"])
  t.draw()
  assert_true(tree.resident_read())
  assert_true(frames_in_a_second(t) >= 8)
}

///|
test "the wait cycle: backgrounded app (!app_visible) asks for no frames and resumes when shown again" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(s) {
      s
      .width(Is(Some(16.0)))
      .height(Is(Some(16.0)))
      .ground(Is(0x3366CCFFL))
      .turn(By(fn() { s.cycle(turn_ms) * 2.0 * 3.141592653589793 }), drawn=true)
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(t.wanted_after(), 0.0)
  on_app_state(0)
  t.draw()
  assert_eq(t.wanted_after(), @double.infinity, msg="hidden app must not keep waking frames for wait cycle")
  on_app_state(3)
  t.draw()
  assert_eq(t.wanted_after(), 0.0, msg="foregrounded app resumes wait cycle")
}
