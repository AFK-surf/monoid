// The pointer's shape where the window is a tree (view_host.mbt view_cursor_tell): a node's of what the pointer is over
// (what it says, else a hand where a press on it does something), the old views' over theirs, the one a press is held
// by while held; told as the pointer moves, and as what a still pointer is over changes, at no frame of a test's.

///|
/// In a row: a tree button "B" (a hand, said nothing), an edge "E" 10 wide (dragged, its shape `edge`), and an old view
/// with a button of its own (its hand); over the old view's button, while `cover`, a ground of the tree's taking presses,
/// said to be the arrow. "B" taking presses while `b_on`. Over all of it while `layer`, a layer of the old frame's.
fn shaped_tester(
  edge : @signals.Signal[Cursor?],
  cover : @signals.Signal[Bool],
  b_on : @signals.Signal[Bool],
  layer? : @signals.Signal[Bool] = @signals.signal(false),
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.row(Is(true)) |> ignore
    root.box(fn(b) {
      b
      .width(Is(Some(80.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { b_on.get() }))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(e) {
      e.width(Is(Some(10.0))).height(Is(Some(40.0))).cursor(By(fn() { edge.get() })).on_drag(fn(_) {  }) |> ignore
    })
    |> ignore
    root.box(fn(h) {
      h.width(Is(Some(200.0))) |> ignore
      old(h, fn(c) {
        let id = c.id("old button")
        c.takes_presses(id)
        c.box(w=Px(80.0), h=Px(40.0), id~, fn() {  }) |> ignore
        // (a layer of the old frame's over all of the window, taking no press itself, while `layer`)
        if layer.get() {
          c.overlay("sheet", modal=true, fn() { c.box(w=Px(400.0), h=Px(200.0), fn() {  }) |> ignore }) |> ignore
        }
      }).grow(Is(1.0))
      |> ignore
      // (the tree's ground over the old view's button, said to be the arrow)
      h.show(at_once=true, fn() { cover.get() }, fn(g) {
        g
        .over(Is(true))
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .on_press(fn() {  })
        .cursor(Is(Some(Arrow)))
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "the pointer's shape over the tree and the old views: a node's hand, an edge's own, the old view's button's hand; an arrow said over it, the arrow, not the hand of what lies under it" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
  let cover = on(false)
  let t = shaped_tester(edge, cover, on(true))
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand, msg="over the tree's button")
  finger(1, 85.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), ResizeX, msg="over the edge")
  finger(1, 130.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand, msg="over the old view's button")
  cover.set(true)
  t.frames_owed()
  assert_eq(t.cursor(), Arrow, msg="the tree's ground said to be the arrow over it: the arrow")
}

///|
test "a still pointer over a node: its shape said anew, and the node taking presses no more, told the host by the frames owed, no move" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
  let b_on = on(true)
  let t = shaped_tester(edge, on(false), b_on)
  finger(1, 85.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), ResizeX)
  edge.set(Some(Grab))
  t.frames_owed()
  assert_eq(t.cursor(), Grab, msg="said anew")
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand)
  b_on.set(false)
  t.frames_owed()
  assert_eq(t.cursor(), Arrow, msg="the button taking presses no more: the arrow of the ground under it")
}

///|
test "a press held on an edge: its shape kept as the pointer goes off it over a button, and once let go, the button's" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
  let t = shaped_tester(edge, on(false), on(true))
  finger(1, 85.0, 20.0)
  finger(0, 85.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), ResizeX)
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), ResizeX, msg="held: the edge's, over the button")
  finger(2, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand, msg="let go: the button's under it")
}

///|
test "a still pointer over a node's hand, a layer of the old frame's opening over it: its shape, the arrow, by the frame it opens in; closed, the node's again" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
  let layer = on(false)
  let t = shaped_tester(edge, on(false), on(true), layer~)
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand)
  layer.set(true)
  t.draw()
  assert_eq(t.cursor(), Arrow, msg="the layer's over it")
  layer.set(false)
  t.draw()
  assert_eq(t.cursor(), Hand, msg="closed: the node's again")
}

///|
test "the pointer's shape told the host at each event of the mouse's, no frame drawn: moved between a button and an edge, pressed on the edge and moved off it, let go; as with the frames drawn" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let run = fn(frames : Bool) {
    let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
    let t = shaped_tester(edge, on(false), on(true))
    let seen : Array[Cursor] = []
    let step = fn(kind : Int, x : Double) {
      finger(kind, x, 20.0)
      if frames {
        t.frames_owed()
      }
      seen.push(t.cursor())
    }
    step(1, 40.0)
    step(1, 85.0)
    step(1, 40.0)
    step(1, 85.0)
    step(0, 85.0)
    step(1, 40.0)
    step(2, 40.0)
    seen
  }
  let want : Array[Cursor] = [Hand, ResizeX, Hand, ResizeX, ResizeX, ResizeX, Hand]
  assert_eq(run(false), want, msg="no frame drawn")
  assert_eq(run(true), want, msg="the frames drawn")
}

///|
test "a node's shape said by a saying, said anew as a value or the node let go: the saying let go of then" {
  let shape : @signals.Signal[Cursor?] = @signals.signal(Some(Grab), same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let v : Ref[@view.View?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.show(at_once=true, fn() { there.get() }, fn(n) {
      v.val = Some(n)
      n.width(Is(Some(40.0))).height(Is(Some(40.0))).cursor(By(fn() { shape.get() })) |> ignore
    })
  })
  t.draw()
  assert_true(shape.watched(), msg="followed")
  v.val.unwrap().cursor(Is(Some(Arrow))) |> ignore
  assert_false(shape.watched(), msg="said anew as a value: let go of then")
  v.val.unwrap().cursor(By(fn() { shape.get() })) |> ignore
  assert_true(shape.watched(), msg="followed again")
  let tree = view_app.val.unwrap()
  tree.event(view_moment(), fn() { there.set(false) })
  assert_false(shape.watched(), msg="the node let go: let go of then")
}

///|
test "every shape a node says comes back as itself: the host told its own number, the Tester reading it back, its probe naming it" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(ResizeX), same=fn(a, b) { a == b })
  let t = shaped_tester(edge, on(false), on(true))
  let all : Array[Cursor] = [
    Arrow, Hand, IBeam, ResizeX, ResizeY, Grab, Grabbing, Crosshair, NotAllowed, ResizeNWSE, ResizeNESW,
  ]
  let codes : Map[Int, Cursor] = Map([])
  for c in all {
    assert_false(codes.contains(c.code()), msg="\{c}'s number \{c.code()} another's too")
    codes[c.code()] = c
    edge.set(Some(c))
    let said = t.probe_at(85.0, 20.0)
    assert_eq(t.cursor(), c, msg="over the edge said \{c}")
    assert_true(said.contains("cursor=\{c}\n"), msg="\{c} probed: \{said}")
  }
  assert_eq(Show::to_string(Cursor::ResizeNWSE), "ResizeNWSE")
  assert_eq(Show::to_string(Cursor::ResizeNESW), "ResizeNESW")
}

///|
test "the window's tree said to show no hand over what is pressed: the arrow over its button and an old view's, a shape said still its own; said again, the hand at once" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let edge : @signals.Signal[Cursor?] = @signals.signal(Some(Hand), same=fn(a, b) { a == b })
  let t = shaped_tester(edge, on(false), on(true))
  let tree = view_app.val.unwrap()
  tree.hand_over_presses(false)
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Arrow, msg="over the tree's button")
  finger(1, 130.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Arrow, msg="over the old view's button")
  finger(1, 85.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Hand, msg="over the edge said to be the hand: its own")
  finger(1, 40.0, 20.0)
  t.frames_owed()
  assert_eq(t.cursor(), Arrow)
  tree.hand_over_presses(true)
  assert_eq(t.cursor(), Hand, msg="said again: the tree's button's hand at once, the pointer still, no frame")
}

///|
test "interactive roles (button, toggle, disclosure, slider) default to Hand when enabled, Arrow when disabled, explicit cursor overrides, and roleless drag or as_ground stays Arrow" {
  let on = fn(v : Bool) { @signals.signal(v, same=fn(a, b) { a == b }) }
  let able = on(true)
  let t = Tester::new(fn(_c) {  }, w=500.0, h=100.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.row(Is(true)) |> ignore
    // 0..60: button pattern (on_press + Button)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { able.get() }))
      .says(Is(Some(@view.said(Button, label="Save"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    // 60..120: toggle pattern (on_press + Switch)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { able.get() }))
      .says(Is(Some(@view.said(Switch, label="Mute"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    // 120..180: disclosure pattern (on_press + Button expanded)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { able.get() }))
      .says(Is(Some(@view.said(Button, label="More", expanded=false))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    // 180..240: slider pattern (on_drag only, no on_press + Slider)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { able.get() }))
      .says(Is(Some(@view.said(Slider, label="Volume"))))
      .on_drag(fn(_) {  })
      |> ignore
    })
    |> ignore
    // 240..300: slider with explicit cursor override
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { able.get() }))
      .says(Is(Some(@view.said(Slider, label="Pan"))))
      .on_drag(fn(_) {  })
      .cursor(Is(Some(Grab)))
      |> ignore
    })
    |> ignore
    // 300..360: roleless drag region (stays Arrow)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .on_drag(fn(_) {  })
      |> ignore
    })
    |> ignore
    // 360..420: as_ground with interactive role (stays Arrow)
    root.box(fn(b) {
      b
      .width(Is(Some(60.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .says(Is(Some(@view.said(Slider, label="Ground"))))
      .as_ground()
      .on_drag(fn(_) {  })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Enabled: button, toggle, disclosure, slider all show Hand; explicit Grab overrides; roleless drag & as_ground show Arrow
  let enabled_cases : Array[(Double, Cursor, String)] = [
    (30.0, Hand, "button"),
    (90.0, Hand, "toggle"),
    (150.0, Hand, "disclosure"),
    (210.0, Hand, "slider"),
    (270.0, Grab, "slider explicit Grab"),
    (330.0, Arrow, "roleless drag"),
    (390.0, Arrow, "as_ground"),
  ]
  for pair in enabled_cases {
    finger(1, pair.0, 20.0)
    t.frames_owed()
    assert_eq(t.cursor(), pair.1, msg="enabled: \{pair.2}")
  }
  // Disabled: button, toggle, disclosure, slider revert to Arrow (and disabled node with presses=false is skipped by hit-testing)
  able.set(false)
  t.frames_owed()
  let disabled_cases : Array[(Double, Cursor, String)] = [
    (30.0, Arrow, "button disabled"),
    (90.0, Arrow, "toggle disabled"),
    (150.0, Arrow, "disclosure disabled"),
    (210.0, Arrow, "slider disabled"),
    (270.0, Arrow, "slider explicit Grab skipped when presses=false"),
  ]
  for pair in disabled_cases {
    finger(1, pair.0, 20.0)
    t.frames_owed()
    assert_eq(t.cursor(), pair.1, msg="disabled: \{pair.2}")
  }
}
