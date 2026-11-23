// A node drawn bigger or smaller beside what it goes beside (View::scale about FromBeside) with `max_shift`: its corner
// farthest from where it grows from stands off where it is laid out no more than that, from the first frame it went to
// the other side on, drawn, pressed and read out there; one small enough drawn as big as it says; its way in and out
// narrowed in proportion, never held still at the cap, its anchor gone or not.

///|
/// Whether `a` and `b` are the same to within rounding.
fn near(a : Double, b : Double) -> Bool {
  (a - b).abs() < 1.0e-9
}

///|
/// A window 400 by 800, an anchor 40 by 20 at (100, 760) while `anchored`, and beside it below (no room there: above)
/// a node `w` by `h` drawn `s` as big about the edge it goes out from, kept within `most`, holding two rows 36 high
/// that do something when pressed (counted in `presses`) and say what they are.
fn shifted(
  s : @signals.Signal[Double],
  anchored : @signals.Signal[Bool],
  w : Double,
  h : Double,
  most : Double,
  presses : Array[Int],
) -> (@view.Tree, Map[String, @view.NodeId]) {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.show(at_once=true, fn() { anchored.get() }, fn(a) {
        ids["a"] = a.id()
        a.over(Is(true)).width(Is(Some(40.0))).height(Is(Some(20.0))).offset(Is((100.0, 760.0))) |> ignore
      })
      root.box(fn(p) {
        ids["p"] = p.id()
        p
        .width(Is(Some(w)))
        .height(Is(Some(h)))
        .beside(ids["a"], side=Bottom, along=Start)
        .scale(By(fn() { s.get() }), about=FromBeside, max_shift=most)
        |> ignore
        for i in 0..<2 {
          p.box(fn(r) {
            ids["r\{i}"] = r.id()
            r
            .width(Is(Some(w)))
            .height(Is(Some(36.0)))
            .on_press(fn() { presses[i] = presses[i] + 1 })
            .says(Is(Some(@view.said(Button, label="row \{i}"))))
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 800.0) |> ignore
  (t, ids)
}

///|
/// How far the top of what `id` is drawn stands below `top`, where it is laid out.
fn top_off(t : @view.Tree, id : @view.NodeId, top : Double) -> Double {
  t.drawn_of(id).unwrap().y - top
}

///|
test "scale max_shift: a tall node gone above its anchor on its first frame, its top row drawn, pressed and read out 8 below where it is laid out" {
  // (laid out above its anchor: its top 760 - 4 - 705)
  let top = 51.0
  // (no cap: 0.95 about its foot leaves its top 705 * 0.05 below)
  let s = @signals.signal(0.95, same=fn(a, b) { a == b })
  let presses = [0, 0]
  let (t, ids) = shifted(s, @signals.signal(true), 220.0, 705.0, 0.0, presses)
  assert_true(near(t.drawn_scale(ids["p"]), 0.95), msg="as big as it says, no cap")
  assert_true(near(top_off(t, ids["r0"], top), 35.25), msg="its top row 35.25 below, no cap")
  assert_true(!t.press(110.0, top + 18.0), msg="where its top row is laid out: nothing there, no cap")
  // (capped at 8: 0.97 as 0.95, its top 8 below either way, from the first frame)
  for said in [0.97, 0.95] {
    let s = @signals.signal(said, same=fn(a, b) { a == b })
    let presses = [0, 0]
    let (t, ids) = shifted(s, @signals.signal(true), 220.0, 705.0, 8.0, presses)
    let d = t.drawn_of(ids["p"]).unwrap()
    assert_true(d.y + d.h < 760.0, msg="above its anchor on its first frame: \{d.y}, \{d.h}")
    assert_true(near(t.drawn_scale(ids["p"]), 1.0 - 8.0 / 705.0), msg="\{said} kept within 8")
    assert_true(near(top_off(t, ids["p"], top), 8.0), msg="its top 8 below")
    assert_true(near(top_off(t, ids["r0"], top), 8.0), msg="its top row 8 below")
    // (read out where it is drawn)
    let row = t.said_order().filter(fn(n) { n.id == ids["r0"] })
    assert_eq(row.length(), 1)
    assert_true(near(row[0].rect.1 - top, 8.0), msg="read out 8 below: \{Repr(row[0].rect)}")
    // (pressed where it is laid out: the top row, not the next)
    assert_true(t.target_at(110.0, top + 18.0) is Pressed(id) && id == ids["r0"], msg="found there")
    assert_true(t.press(110.0, top + 18.0))
    assert_eq(presses, [1, 0], msg="the top row pressed")
  }
}

///|
test "scale max_shift: a node small enough to stay within it drawn as big as it says" {
  let s = @signals.signal(0.97, same=fn(a, b) { a == b })
  let (t, ids) = shifted(s, @signals.signal(true), 200.0, 180.0, 8.0, [0, 0])
  // (its farthest corner 200 off where it grows from: 200 * 0.03 = 6, within 8)
  assert_eq(t.drawn_scale(ids["p"]), 0.97)
}

///|
test "scale max_shift: in and out narrowed in proportion, its anchor gone on the way out, never held at the cap" {
  let top = 51.0
  let s = @signals.signal(0.95, same=fn(a, b) { a == b })
  let anchored = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, ids) = shifted(s, anchored, 220.0, 705.0, 8.0, [0, 0])
  let off = fn() { top_off(t, ids["p"], top) }
  assert_true(near(off(), 8.0), msg="coming: 8")
  t.event(10.0, fn() { s.set(0.975) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 4.0), msg="half way in: 4, not held at 8 (\{off()})")
  t.event(20.0, fn() { s.set(1.0) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 0.0), msg="in: as laid out")
  // (its anchor gone as it goes: where it last was beside it, about the same point)
  t.event(30.0, fn() { anchored.set(false) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 0.0), msg="its anchor gone: where it was (\{off()})")
  t.event(40.0, fn() { s.set(0.975) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 4.0), msg="half way out: 4 (\{off()})")
  t.event(50.0, fn() { s.set(0.95) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 8.0), msg="out: 8 (\{off()})")
  assert_true(near(t.drawn_scale(ids["p"]), 1.0 - 8.0 / 705.0), msg="as big as at its first frame")
}

///|
test "scale max_shift: going smaller from whole with no way in, held at the cap past it" {
  let top = 51.0
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let (t, ids) = shifted(s, @signals.signal(true), 220.0, 705.0, 8.0, [0, 0])
  let off = fn() { top_off(t, ids["p"], top) }
  assert_true(near(off(), 0.0))
  t.event(10.0, fn() { s.set(0.98) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 8.0), msg="past 8 / 705 (0.98): at the cap (\{off()})")
  t.event(20.0, fn() { s.set(0.95) })
  t.frame(400.0, 800.0) |> ignore
  assert_true(near(off(), 8.0), msg="further: still at the cap (\{off()})")
}
