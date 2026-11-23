// The window's tree drawn in the same phase as what it is worked out of: its theme said before its first node is made
// (run_tree's, Tester::tree's and set_view_app's `theme`), glass solid or not as it is set (set_glass_solid), the
// window made to fill the screen as the old view's build says it, all of it in the frame that says it; and the
// Tester's three holds on a frame nothing asks for (tester_unasked.mbt) each finding what it is there to find.

///|
/// A theme whose digits are all one width (tabular) and whose focus colour is its own.
let phase_theme : Theme = { ..Theme::light(), tabular: true, focus: 0x224466FFL }

///|
/// A box 40 tall over the window's top left, 120 wide in a theme whose digits are all one width and 60 in any other,
/// grounded in the theme's focus colour; `runs` counts its width's binding worked out. The box's node.
fn phase_box(root : @view.View, runs : Ref[Int]) -> Ref[@view.NodeId?] {
  let id : Ref[@view.NodeId?] = Ref(None)
  root.box(fn(n) {
    id.val = Some(n.id())
    n
    .over(Is(true))
    .offset(Is((10.0, 10.0)))
    .width(By(fn() {
      runs.val = runs.val + 1
      Some(if tree_theme().tabular { 120.0 } else { 60.0 })
    }))
    .height(Is(Some(40.0)))
    .ground(By(fn() { tree_theme().focus }))
    |> ignore
  })
  |> ignore
  id
}

///|
test "a tree made alone in the theme it says: no old frame round it, laid out once in that theme from its first frame, at rest as it stands" {
  let runs = Ref(0)
  let id : Ref[Ref[@view.NodeId?]] = Ref(Ref(None))
  let t = Tester::tree(fn(root) { id.val = phase_box(root, runs) }, w=300.0, h=200.0, theme=fn() { phase_theme })
  assert_false(old_around.val, msg="no old frame round it")
  let d = view_app.val.unwrap().drawn_of(id.val.val.unwrap()).unwrap()
  assert_eq((d.w, d.ground), (120.0, 0x224466FFL), msg="in its theme from its first frame")
  assert_eq(runs.val, 1, msg="its width worked out once")
  assert_eq(view_words_style(), @hostapi.style_tabular, msg="its words shaped in its theme")
  assert_eq(t.audit(), [])
  let before = t.drawn_rects()
  t.frame()
  assert_eq(t.drawn_rects(), before, msg="a frame after it draws the same")
  assert_eq(runs.val, 1, msg="nothing worked out again")
}

///|
test "a theme said beside an old frame is the tree's still once the run has begun: not let go as the tree is made" {
  let runs = Ref(0)
  let id : Ref[Ref[@view.NodeId?]] = Ref(Ref(None))
  let begun = Ref(false)
  let t = Tester::new(
    fn(_c) {  },
    w=300.0,
    h=200.0,
    tree=fn(root) { id.val = phase_box(root, runs) },
    theme=fn() { phase_theme },
    begun=fn() { begun.val = true },
  )
  assert_true(begun.val)
  assert_true(old_around.val, msg="its old frame round it")
  assert_eq(view_app.val.unwrap().drawn_of(id.val.val.unwrap()).unwrap().w, 120.0)
  assert_eq(runs.val, 1)
  assert_eq(t.unasked_faults(), [])
}

///|
test "glass made solid before the tree is made: what shows by it as it is from the first frame, and again in the frame it changes" {
  let made = Ref(0)
  let seen : Array[Bool] = []
  let t = Tester::tree(
    fn(root) {
      root.reacts(fn() { root.glass_solid() }, fn(s) { seen.push(s) })
      root.show(fn() { !root.glass_solid() }, fn(v) {
        made.val = made.val + 1
        v.box(fn(n) { n.over(Is(true)).width(Is(Some(30.0))).height(Is(Some(30.0))).ground(Is(0x3366CCFFL)) |> ignore })
        |> ignore
      })
    },
    w=300.0,
    h=200.0,
    begun=fn() { set_glass_solid(Some(true)) },
  )
  assert_eq(made.val, 0, msg="no glass's part made as the first frame is")
  assert_eq(seen, [true])
  set_glass_solid(Some(false))
  t.frame()
  assert_eq(made.val, 1, msg="glass again: made in the frame after it was set")
  assert_eq(seen, [true, false])
  // (as the system says: the device slowed for its heat, then less transparency asked for)
  set_glass_solid(None)
  t.set_thermal_throttled(true)
  t.frame()
  assert_eq(seen, [true, false, true])
  t.set_thermal_throttled(false)
  t.set_reduce_transparency(true)
  t.frame()
  assert_eq(seen, [true, false, true])
  t.set_reduce_transparency(false)
  t.frame()
  assert_eq(seen, [true, false, true, false])
}

///|
test "the window made to fill the screen by the old view's build: the tree's corner following the window's in that frame" {
  let full = @signals.signal(false)
  let id : Ref[@view.NodeId?] = Ref(None)
  let t = Tester::new(
    fn(c) {
      if full.get() {
        c.set_full_screen(true)
      }
    },
    w=300.0,
    h=200.0,
    window_corner=16.0,
    tree=fn(root) {
      root.box(fn(n) {
        id.val = Some(n.id())
        n
        .over(Is(true))
        .offset(Is((6.0, 6.0)))
        .width(Is(Some(60.0)))
        .height(Is(Some(40.0)))
        .radius(corner_of(Follow(Window, 6.0, 9.0)))
        .ground(Is(0x3366CCFFL))
        |> ignore
      })
      |> ignore
    },
  )
  let radius = fn() { view_app.val.unwrap().drawn_of(id.val.unwrap()).unwrap().radius }
  let windowed = radius()
  full.set(true)
  t.frame()
  let filled = radius()
  assert_true(filled != windowed, msg="the frame its build said it in: \{windowed} then \{filled}")
  t.frame()
  assert_eq(radius(), filled, msg="and so after it")
}

///|
/// A Tester of the window's tree showing phase_box, at rest, its old frame's theme then changed as nothing tells (the
/// Ctx's field set by hand, between frames): what the next frame draws is not what shows.
fn phase_untold() -> Tester {
  let runs = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, tree=fn(root) { phase_box(root, runs) |> ignore })
  t.ctx().set_theme(phase_theme)
  t
}

///|
test "unasked_faults: the screen at rest not what a frame drawn again draws, said with where it was made; none once drawn" {
  let t = phase_untold()
  let faults = t.unasked_faults()
  assert_eq(faults.length(), 1, msg=faults.join("\n"))
  assert_true(faults[0].has_prefix("unasked-frame: "), msg=faults[0])
  assert_true(faults[0].contains("tree_phase_wbtest.mbt"), msg=faults[0])
  // (the screen drawn again so, as it is worked out of)
  assert_eq(t.unasked_faults(), [])
}

///|
test "audit: the screen at rest not what a frame drawn again draws, first of what it says" {
  let t = phase_untold()
  let faults = t.audit()
  assert_true(faults.length() >= 1 && faults[0].has_prefix("unasked-frame: "), msg=faults.join("\n"))
}

///|
test "a frame nothing asks for that draws otherwise than the screen before it: said, where it was made" {
  let t = phase_untold()
  let next = t.at_due(t.tick_after(t.time()))
  assert_true(t.frame_unasked(next), msg="nothing asks for it")
  assert_true(t.unasked_before(next) is Some(_), msg="looked at as it is drawn")
  // (drawn as a run whose frames are not judged draws it: what its judge says read here, not stopped on)
  t.frames_unjudged(true)
  let seen = unasked_seen(g())
  t.frame()
  match t.unasked_said(seen, t.time(), "the frame nothing asked for after it") {
    Some(s) => {
      assert_true(s.has_prefix("unasked-frame: "), msg=s)
      assert_true(s.contains("tree_phase_wbtest.mbt"), msg=s)
    }
    None => fail("the frame after it drew otherwise, said nothing")
  }
  // (and a frame after that one: the same)
  let seen = unasked_seen(g())
  t.frame()
  assert_eq(t.unasked_said(seen, t.time(), "the frame nothing asked for after it"), None)
}

///|
test "a frame nothing asks for, drawn after a screen at rest as it is worked out of: nothing said" {
  let runs = Ref(0)
  let t = Tester::tree(fn(root) { phase_box(root, runs) |> ignore }, w=300.0, h=200.0)
  t.frame()
  t.frame()
  assert_eq(t.unasked_faults(), [])
}

///|
test "sizes_steady: a step in a measure's first frame and then standing still, said; a way setting out, not so" {
  let p = frame_period_default
  let (stood, _) = sizes_steady_fault([(0.0, 0.0, 60.0), (p, p, 120.0), (2.0 * p, 2.0 * p, 120.0)], p, turned=-1.0e9)
  match stood {
    Some(s) => assert_true(s.has_prefix("stepped 60 in its first frame then stood (0)"), msg=s)
    None => fail("a step in its first frame and then still said nothing")
  }
  let (eased, _) = sizes_steady_fault([(0.0, 0.0, 0.0), (p, p, 10.0), (2.0 * p, 2.0 * p, 16.0)], p, turned=-1.0e9)
  assert_false(eased is Some(f) && f.has_prefix("stepped"), msg="a way slowing to rest")
  // (with a frame missing between them: not one after another)
  let (gap, _) = sizes_steady_fault([(0.0, 0.0, 60.0), (2.0 * p, 2.0 * p, 120.0), (3.0 * p, 3.0 * p, 120.0)], p, turned=-1.0e9)
  assert_false(gap is Some(f) && f.has_prefix("stepped"))
}

///|
test "sizes_steady: a box that steps in its first frame and stands, while something else moves on, said" {
  // (frames it walks itself, judged by the default run alone: test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  for period in [1000.0 / 60.0, 1000.0 / 120.0] {
    let on = @signals.signal(false)
    let t = Tester::tree(
      fn(root) {
        // (something moving all the while: no frame at rest to look at)
        root.box(fn(n) {
          n
          .over(Is(true))
          .offset(Is((200.0, 10.0)))
          .width(Is(Some(20.0)))
          .height(Is(Some(20.0)))
          .ground(Is(0x884422FFL))
          .moved_by(fn(_w, _h, at) { (0.0, (at / 10.0).floor() % 40.0) }, fn(_w, _h) { 1.0e7 })
          |> ignore
        })
        |> ignore
        // (its ground its own: what is measured is known by it, the same before the theme and after)
        root.show(fn() { on.get() }, fn(v) {
          v.box(fn(n) {
            n
            .over(Is(true))
            .offset(Is((10.0, 10.0)))
            .width(By(fn() { Some(if tree_theme().focus == 0x224466FFL { 120.0 } else { 60.0 }) }))
            .height(Is(Some(40.0)))
            .ground(Is(0x3366CCFFL))
            |> ignore
          })
          |> ignore
        })
      },
      w=300.0,
      h=200.0,
      // (what it finds said here, not stopped on)
      words_over_held=false,
      transitions_only=false,
    )
    let found : Array[String] = []
    let judged = fn() {
      // (its width: along a row, sizes_across's)
      for f in g().sizes_faults(t.time(), t.period) {
        found.push(f.1)
      }
    }
    t.set_frame_period(period)
    // (its window known before the box shows, at any rate the run is made at)
    g().sizes_faults(t.time(), t.period) |> ignore
    on.set(true)
    t.frame()
    judged()
    assert_false(t.frame_unasked(t.at_due(t.tick_after(t.time()))), msg="something moves")
    t.ctx().set_theme(phase_theme)
    t.frame()
    judged()
    t.frame()
    judged()
    assert_true(
      found.iter().any(fn(f) { f.contains("its width stepped") && f.contains("in its first frame then stood") }),
      msg="at \{period}: " + found.join("\n"),
    )
  }
}

///|
test "sizes_steady: a box shown while a finger is held, stepping in its first frame after it is let go and standing, not said; one never seen before so, said" {
  // (frames it walks itself, judged by the default run alone: test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  for held in [true, false] {
    let on = @signals.signal(false)
    let t = Tester::tree(
      fn(root) {
        // (something moving all the while: no frame at rest to look at)
        root.box(fn(n) {
          n
          .over(Is(true))
          .offset(Is((200.0, 10.0)))
          .width(Is(Some(20.0)))
          .height(Is(Some(20.0)))
          .ground(Is(0x884422FFL))
          .moved_by(fn(_w, _h, at) { (0.0, (at / 10.0).floor() % 40.0) }, fn(_w, _h) { 1.0e7 })
          |> ignore
        })
        |> ignore
        root.show(fn() { on.get() }, fn(v) {
          v.box(fn(n) {
            n
            .over(Is(true))
            .offset(By(fn() { (if tree_theme().focus == 0x224466FFL { 16.0 } else { 10.0 }, 10.0) }))
            .width(Is(Some(60.0)))
            .height(Is(Some(40.0)))
            .ground(Is(0x3366CCFFL))
            |> ignore
          })
          |> ignore
        })
      },
      w=300.0,
      h=200.0,
      // (what it finds said here, not stopped on)
      words_over_held=false,
      transitions_only=false,
    )
    let found : Array[String] = []
    let judged = fn() {
      for f in g().sizes_faults(t.time(), t.period) {
        found.push(f.1)
      }
    }
    t.set_frame_period(1000.0 / 60.0)
    g().sizes_faults(t.time(), t.period) |> ignore
    if held {
      // (a finger down on nothing, the box shown and drawn while it is held, then let go)
      t.touch(0, 250.0, 150.0)
      on.set(true)
      t.frame()
      judged()
      t.frame()
      judged()
      t.touch(2, 250.0, 150.0)
    } else {
      on.set(true)
    }
    t.frame()
    judged()
    t.ctx().set_theme(phase_theme)
    t.frame()
    judged()
    t.frame()
    judged()
    let said = found.iter().any(fn(f) { f.contains("stepped") && f.contains("in its first frame then stood") })
    assert_eq(said, !held, msg="held \{held}: " + found.join("\n"))
  }
}
