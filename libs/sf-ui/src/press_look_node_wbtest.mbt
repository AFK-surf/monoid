// A press's ripple and sink on a node (press_look, tool_node's `ripples`) beside the old one's (@motion.ripple, as
// picture_button calls it): pressed alike, each at its own moment, drawn alike at each moment after, held, let go, on its
// way out, and gone; motion reduced, there and gone at once; let go of, nothing read of the clock. Between presses, a
// tap's ripple's whole way (@motion.ripple_tap_ms: what one press shows over, its sink back with it); a moment into a
// press, a few of the display's frames. A finger's press ripples; a pointer's lays the ink over the whole of it
// evenly, no disc (@motion.ripple's pointer's press), the same on both.

///|
/// An old view's 32 round box that ripples (picture_button's) 60 in, and a tool node that ripples 260 in, each 20 down,
/// on its chosen ground `chosen` (white at 16% by default, picture_button's) while `on`; pressed by a finger, or by a
/// pointer where `finger` is false.
fn ripple_pair(
  on : @signals.Signal[Bool],
  there : @signals.Signal[Bool],
  chosen? : Int64 = 0xFFFFFF29L,
  finger? : Bool = true,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=100.0, platform=0)
  t.host_says_finger(Some(finger))
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    root.box(fn(h) {
      h.width(Is(Some(200.0))).height(Is(Some(100.0))) |> ignore
      @ui.old(h, fn(c) {
        let id = c.id("old")
        c.box(w=Px(60.0), h=Px(20.0), fn() {  }) |> ignore
        c.box(dir=Row, fn() {
          c.box(w=Px(60.0), h=Px(32.0), fn() {  }) |> ignore
          c.box(w=Px(32.0), h=Px(32.0), radius=16.0, bg=if on.get() { chosen } else { 0L }, id~, fn() {
            @motion.ripple(c, id, 16.0)
          })
          |> ignore
        })
        |> ignore
      }).grow(Is(1.0))
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b.width(Is(Some(200.0))).height(Is(Some(100.0))).padding(Is((60.0, 20.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      b.show(fn() { there.get() }, fn(s) {
        tool_node(
          s,
          fn() { { icon: "edit", label: "new", on: on.get(), disabled: false } },
          fn() { { ground: 0L, ink: 0xFFFFFFFFL, muted: 0xFFFFFF99L, line: 0L, hover: 0L, chosen } },
          Is(tool_side / 2.0),
          fn() {  },
          lights=false,
          ripples=true,
        )
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The shadows drawn within the 32 box at (`x`, 20) (a ripple's discs), each in that box's own terms, to a millionth
/// (the box's place taken off what is drawn where it is: 60 and 260 off leave their last bits differently).
fn discs_at(t : @ui.Tester, x : Double) -> Array[Array[Double]] {
  let r = fn(v : Double) { (v * 1.0e6).round() / 1.0e6 }
  t.drawn_shadows().filter(fn(s) { s.0 >= x - 200.0 && s.0 < x + 200.0 && s.1 > -200.0 && s.1 < 220.0 }).map(fn(s) {
    [r(s.0 - x), r(s.1 - 20.0), r(s.2), r(s.3), r(s.5), (s.6 & 0xFFL).to_double()]
  })
}

///|
/// The box at (`x`, 20) pressed by the mouse 10 right and 6 down of its top left, held `held` ms, let go: its discs
/// at each of `at` ms after it went down (frames drawn at the display's pace between), and how big it is drawn then.
fn pressed_through(t : @ui.Tester, x : Double, held : Double, at : Array[Double]) -> Array[Array[Array[Double]]] {
  let t0 = t.time()
  let seen = []
  let mut up = false
  for ms in at {
    if !up && ms >= held {
      t.run_for(t0 + held - t.time())
      t.touch(2, x + 10.0, 26.0)
      up = true
    }
    t.run_for(t0 + ms - t.time())
    seen.push(discs_at(t, x))
  }
  seen
}

///|
test "a press's ripple on a node drawn as the old view's is: from where it went down, held, let go, on its way out, gone; a short one shown whole" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = ripple_pair(on, there)
  let moments = [100.0, 300.0, 500.0, 700.0, 900.0]
  for held in [400.0, 50.0] {
    t.touch(0, 70.0, 26.0)
    let old = pressed_through(t, 60.0, held, moments)
    t.run_for(@motion.ripple_tap_ms)
    t.touch(0, 270.0, 26.0)
    let new = pressed_through(t, 260.0, held, moments)
    t.run_for(@motion.ripple_tap_ms)
    assert_true(old[1].length() > 0, msg="held \{held}: the old one's disc drawn: \{Repr(old)}")
    assert_eq(new, old, msg="held \{held}: as the old one's: \{Repr(new)} and \{Repr(old)}")
  }
  assert_true(!@ui.view_tree().unwrap().clock_read(), msg="gone: nothing read of the clock")
}

///|
test "a press's ripple on a node, motion reduced: there at once as the old view's is, gone as it is; the node let go of while one goes, nothing read of the clock" {
  @ui.set_motion_chosen(Some(true))
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = ripple_pair(on, there)
  let moments = [10.0, 500.0, 900.0]
  t.touch(0, 70.0, 26.0)
  let old = pressed_through(t, 60.0, 300.0, moments)
  t.run_for(@motion.ripple_tap_ms)
  t.touch(0, 270.0, 26.0)
  let new = pressed_through(t, 260.0, 300.0, moments)
  t.run_for(@motion.ripple_tap_ms)
  // (pressed again, the node let go of as its ripple goes)
  t.touch(0, 270.0, 26.0)
  t.run_for(t.frame_period() * 3.0)
  there.set(false)
  t.touch(2, 270.0, 26.0)
  t.run_for(t.frame_period() * 3.0)
  let ticking = @ui.view_tree().unwrap().clock_read()
  @ui.set_motion_chosen(None)
  assert_eq(new, old, msg="as the old one's: \{Repr(new)} and \{Repr(old)}")
  assert_true(!ticking, msg="let go of: nothing read of the clock")
}

///|
/// Long enough for a press's sink, down or back, to have come to rest on its spring (the old box's and the node's).
let sink_rest_ms : Double = 600.0

///|
test "a press on a node standing on its own ground sinks it while held to the old view's box's depth, on the hand's spring from the moment it went down, and back as it is let go; on a faint ground (a marking tool's chosen one) neither sinks" {
  // (the old box, pressed first, is drawn at its depth from the press's first frame on: its sink's motion made at its
  // target as it is first asked for, @motion.animate; the node goes there on lift_spring from the press, sf/motion.mbt)
  let sizes = fn(chosen : Int64) {
    let on = @signals.signal(true, same=fn(a, b) { a == b })
    let there = @signals.signal(true, same=fn(a, b) { a == b })
    let t = ripple_pair(on, there, chosen~)
    // (how big each is drawn: the old box's look, the node's as the tree draws it)
    let size = fn(x : Double) {
      if x < 200.0 {
        t.look_of("old").map(fn(l) { (l.0 * 1.0e4).round() / 1.0e4 }).unwrap_or(-1.0)
      } else {
        @ui.view_tree().unwrap().drawn().filter(fn(d) { d.ground == chosen }).map(fn(d) { (d.w / 32.0 * 1.0e4).round() / 1.0e4 }).fold(init=-1.0, fn(_, v) { v })
      }
    }
    let seen_old = []
    let seen_new = []
    for p in [(70.0, 60.0, seen_old), (270.0, 260.0, seen_new)] {
      let (px, bx, seen) = p
      let t0 = t.time()
      t.touch(0, px, 26.0)
      // (a frame in, and held long enough for the spring to have come to rest)
      t.run_for(t0 + 16.0 - t.time())
      seen.push(size(bx))
      t.run_for(t0 + sink_rest_ms - t.time())
      seen.push(size(bx))
      t.touch(2, px, 26.0)
      t.run_for(sink_rest_ms)
      seen.push(size(bx))
    }
    (seen_old, seen_new)
  }
  let (old, new) = sizes(0xFFFFFFFFL)
  assert_eq(old, [0.96, 0.96, 1.0], msg="solid: the old one sunk while held, back as let go")
  assert_true(new[0] < 1.0 && new[0] > 0.96, msg="solid: the node on its way down a frame in: \{Repr(new)}")
  assert_eq([new[1], new[2]], [old[1], old[2]], msg="solid: held, as deep as the old one; let go, back: \{Repr(new)} and \{Repr(old)}")
  let (old, new) = sizes(0xFFFFFF29L)
  assert_eq(old, [1.0, 1.0, 1.0], msg="faint: the old one not sunk")
  assert_eq(new, old, msg="faint: as the old one: \{Repr(new)} and \{Repr(old)}")
}

///|
test "a press on a node held, moved off it and called off: its ripple as the old view's, on its way out from the moment it was called off" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = ripple_pair(on, there)
  let seen = []
  for x in [60.0, 260.0] {
    t.touch(0, x + 10.0, 26.0)
    t.run_for(@motion.ripple_enter_ms / 2.0)
    t.touch(1, x + 120.0, 80.0)
    t.run_for(@motion.ripple_enter_ms / 4.0)
    t.touch(3, x + 120.0, 80.0)
    let t0 = t.time()
    let marks = []
    for ms in [100.0, 400.0, 900.0] {
      t.run_for(t0 + ms - t.time())
      marks.push(discs_at(t, x))
    }
    seen.push(marks)
    t.run_for(@motion.ripple_tap_ms)
  }
  assert_true(seen[0][0].length() > 0, msg="the old one's disc on its way out: \{Repr(seen[0])}")
  assert_eq(seen[1], seen[0], msg="as the old one's: \{Repr(seen[1])} and \{Repr(seen[0])}")
}

///|
/// A rippled row 300 by 48, 20 down, in a list 200 tall that scrolls (600 under it), pressed by a finger; how many times
/// it was pressed into `pressed`.
fn scrolled_ripple(pressed : Ref[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.box(fn(v) {
      v.height(Is(Some(200.0))) |> ignore
      v.scrolls(@view.Scroll::list(), fn(s) {
        s.box(fn(gap) { gap.height(Is(Some(20.0))) |> ignore }) |> ignore
        s.box(fn(r) {
          r.width(Is(Some(300.0))).height(Is(Some(48.0))) |> ignore
          rippled_node(r, fn() { pressed.val += 1 }, 10.0, fn() { "row" })
        })
        |> ignore
        s.box(fn(tall) { tall.height(Is(Some(600.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The discs drawn now (a ripple's).
fn discs_now(t : @ui.Tester) -> Int {
  t.drawn_shadows().filter(fn(s) { (s.6 & 0xFFFFFF00L) == 0L && (s.6 & 0xFFL) > 0L }).length()
}

///|
test "a finger's press on a node in what scrolls ripples once it has stayed tap_indication_ms; going on to scroll, never; a quicker tap, from as it is let go" {
  let pressed = Ref(0)
  // (held still: nothing till tap_indication_ms, its ripple then)
  let t = scrolled_ripple(pressed)
  t.touch(0, 100.0, 44.0)
  t.draw()
  t.run_for(@ui.tap_indication_ms / 2.0)
  let before = discs_now(t)
  t.run_for(@ui.tap_indication_ms / 2.0 + @motion.ripple_enter_ms / 2.0)
  assert_eq((before, discs_now(t) > 0), (0, true))
  t.touch(2, 100.0, 44.0)
  t.draw()
  // (going on to scroll: no ripple at any move, none as it ends; nothing pressed)
  let t = scrolled_ripple(pressed)
  t.touch(0, 100.0, 44.0)
  t.draw()
  let seen = []
  for i in 1..=10 {
    t.advance(@ui.input_step_ms)
    t.touch(1, 100.0, 44.0 - i.to_double() * 6.0)
    t.draw()
    seen.push(discs_now(t))
  }
  t.touch(2, 100.0, -16.0)
  t.draw()
  seen.push(discs_now(t))
  assert_eq((seen, pressed.val), (Array::make(11, 0), 1))
  // (a tap quicker than that: its ripple as it is let go, on its way out, gone after its whole way)
  let t = scrolled_ripple(pressed)
  t.touch(0, 100.0, 44.0)
  t.draw()
  t.run_for(@ui.tap_indication_ms / 2.0)
  let before = discs_now(t)
  t.touch(2, 100.0, 44.0)
  t.draw()
  t.run_for(@motion.ripple_enter_ms / 2.0)
  let at_up = discs_now(t)
  t.run_for(@motion.ripple_tap_ms)
  assert_eq((before, at_up > 0, discs_now(t), pressed.val), (0, true, 0, 2))
}

///|
/// The veils drawn over the 32 box at (`x`, 20) (a pointer's press: its ink, black, over it), each in that box's own
/// terms: where, how big, its alpha as drawn and its corners.
fn veils_at(t : @ui.Tester, x : Double) -> Array[Array[Double]] {
  let r = fn(v : Double) { (v * 1.0e6).round() / 1.0e6 }
  t
  .drawn_rect_corners()
  .filter(fn(d) { d.0 >= x - 1.0 && d.0 < x + 33.0 && d.1 >= 19.0 && d.1 < 53.0 && (d.4 & 0xFFFFFF00L) == 0L && (d.4 & 0xFFL) > 0L })
  .map(fn(d) { [r(d.0 - x), r(d.1 - 20.0), r(d.2), r(d.3), (d.4 & 0xFFL).to_double(), r(d.5.0), r(d.5.2)] })
}

///|
/// The box at (`x`, 20) pressed 10 right and 6 down of its top left, held `held` ms, let go: its veils at each of `at`
/// ms after it went down (frames drawn at the display's pace between).
fn veiled_through(t : @ui.Tester, x : Double, held : Double, at : Array[Double]) -> Array[Array[Array[Double]]] {
  let t0 = t.time()
  let seen = []
  let mut up = false
  for ms in at {
    if !up && ms >= held {
      t.run_for(t0 + held - t.time())
      t.touch(2, x + 10.0, 26.0)
      up = true
    }
    t.run_for(t0 + ms - t.time())
    seen.push(veils_at(t, x))
  }
  seen
}

///|
test "a pointer's press on a node drawn as the old view's is: no disc, its ink over the whole of it evenly, in from the press and out once let go; a short one shown whole" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = ripple_pair(on, there, finger=false)
  let moments = [10.0, 40.0, 70.0, 120.0, 200.0, 300.0, 500.0, 700.0]
  for held in [400.0, 50.0] {
    t.touch(0, 70.0, 26.0)
    let old = veiled_through(t, 60.0, held, moments)
    let old_discs = discs_at(t, 60.0)
    t.run_for(@motion.pointer_tap_ms)
    t.touch(0, 270.0, 26.0)
    let new = veiled_through(t, 260.0, held, moments)
    t.run_for(@motion.pointer_tap_ms)
    // (whole over it once its way in is over, cut to the box's corners by what holds it; gone once out)
    assert_eq(old[2], [[0.0, 0.0, 32.0, 32.0, (@motion.pointer_veil(@motion.ripple_ink) & 0xFFL).to_double(), 0.0, 0.0]], msg="held \{held}: \{Repr(old)}")
    assert_eq(old[old.length() - 1], [], msg="held \{held}: gone: \{Repr(old)}")
    assert_eq(old_discs, [], msg="held \{held}: no disc")
    assert_eq(new, old, msg="held \{held}: as the old one's: \{Repr(new)} and \{Repr(old)}")
  }
  t.assert_idle()
  assert_true(!@ui.view_tree().unwrap().clock_read(), msg="gone: nothing read of the clock")
}

///|
test "a pointer's press on a node, motion reduced: there at once and gone at once as the old view's; the node let go of while it shows, nothing read of the clock" {
  @ui.set_motion_chosen(Some(true))
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = ripple_pair(on, there, finger=false)
  let moments = [10.0, 300.0, 500.0]
  t.touch(0, 70.0, 26.0)
  let old = veiled_through(t, 60.0, 200.0, moments)
  t.run_for(@motion.pointer_tap_ms)
  t.touch(0, 270.0, 26.0)
  let new = veiled_through(t, 260.0, 200.0, moments)
  t.run_for(@motion.pointer_tap_ms)
  // (pressed again, the node let go of as its veil shows)
  t.touch(0, 270.0, 26.0)
  t.run_for(t.frame_period() * 3.0)
  there.set(false)
  t.touch(2, 270.0, 26.0)
  t.run_for(t.frame_period() * 3.0)
  let ticking = @ui.view_tree().unwrap().clock_read()
  @ui.set_motion_chosen(None)
  assert_eq([old[0].length(), old[1].length(), old[2].length()], [1, 0, 0], msg="there at once, gone at once: \{Repr(old)}")
  assert_eq(new, old, msg="as the old one's: \{Repr(new)} and \{Repr(old)}")
  assert_true(!ticking, msg="let go of: nothing read of the clock")
}

///|
test "a pointer's press on a node standing on its own ground draws it smaller by pointer_sink while held as the old view's box; on a faint ground (a marking tool's chosen one) neither is" {
  let sizes = fn(chosen : Int64) {
    let on = @signals.signal(true, same=fn(a, b) { a == b })
    let there = @signals.signal(true, same=fn(a, b) { a == b })
    let t = ripple_pair(on, there, chosen~, finger=false)
    let size = fn(x : Double) {
      if x < 200.0 {
        t.look_of("old").map(fn(l) { (l.0 * 1.0e4).round() / 1.0e4 }).unwrap_or(-1.0)
      } else {
        @ui.view_tree().unwrap().drawn().filter(fn(d) { d.ground == chosen }).map(fn(d) { (d.w / 32.0 * 1.0e4).round() / 1.0e4 }).fold(init=-1.0, fn(_, v) { v })
      }
    }
    let seen_old = []
    let seen_new = []
    for p in [(70.0, 60.0, seen_old), (270.0, 260.0, seen_new)] {
      let (px, bx, seen) = p
      let t0 = t.time()
      t.touch(0, px, 26.0)
      t.run_for(t0 + 35.0 - t.time())
      seen.push(size(bx))
      t.run_for(t0 + 300.0 - t.time())
      seen.push(size(bx))
      t.touch(2, px, 26.0)
      t.run_for(@motion.pointer_tap_ms)
      seen.push(size(bx))
    }
    t.assert_idle()
    (seen_old, seen_new)
  }
  let (old, new) = sizes(0xFFFFFFFFL)
  assert_eq([old[1], old[2]], [0.99, 1.0], msg="solid: the old one 1% smaller while held, whole as let go: \{Repr(old)}")
  assert_eq(new, old, msg="solid: as the old one: \{Repr(new)} and \{Repr(old)}")
  let (old, new) = sizes(0xFFFFFF29L)
  assert_eq(old, [1.0, 1.0, 1.0], msg="faint: the old one not smaller")
  assert_eq(new, old, msg="faint: as the old one: \{Repr(new)} and \{Repr(old)}")
}
