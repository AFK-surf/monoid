// A row of tools sharing one hover ground (RovingHover, tool_node's `roving`): the pointer come to the row, its
// ground faded in under the tool it is on, nowhere else; gone on to the next, from where it was to there, as wide as
// each; turned to a third on its way, from where it was then; the pointer gone off the row, faded out where it was;
// the keyboard's focus taken along the row the same; a finger's press lit under the tool it is on at once, out at once
// as it is let go. The same at each moment whatever frames are drawn between (run_for's, at every rate).

///|
let rove_labels : Array[String] = ["复制", "下载", "在新窗口打开"]

///|
/// A moment well into the ground's way from one tool to the next, before its end.
let rove_mid_ms : Double = 40.0

///|
/// Long enough for the ground's every way to be over.
let rove_over_ms : Double = 1000.0

///|
/// A row of three tools sharing one hover ground. The Tester.
fn rove_tester() -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let rove = RovingHover::new()
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(8.0)).padding(Is((40.0, 40.0, 0.0, 0.0))) |> ignore
      for label in rove_labels {
        r.box(fn(b) {
          tool_node(
            b,
            fn() { { icon: "copy", label, on: false, disabled: false } },
            fn() { page_viewer_ink() },
            Is(tool_side / 2.0),
            fn() {  },
            roving=rove,
          )
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The hover grounds drawn (the ink's hover, as much of it as is seen): where each is, and how much of it is seen (its
/// colour's alpha against the hover's own).
fn rove_grounds(t : @ui.Tester) -> Array[(Double, Double, Double, Double, Double)] {
  let hover = page_viewer_ink().hover
  t
  .drawn_rects()
  .filter(fn(r) { (r.4 & 0xFFFFFF00L) == (hover & 0xFFFFFF00L) && (r.4 & 0xFFL) > 0L })
  .map(fn(r) { (r.0, r.1, r.2, r.3, (r.4 & 0xFFL).to_double() / (hover & 0xFFL).to_double()) })
}

///|
/// Tool `k`'s box.
fn rove_tool(t : @ui.Tester, k : Int) -> (Double, Double, Double, Double) raise {
  t.get(Button, label=rove_labels[k]).rect
}

///|
fn rove_mid(r : (Double, Double, Double, Double)) -> (Double, Double) {
  (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
}

///|
/// The ground at rest under tool `k`, whole.
fn rove_whole(t : @ui.Tester, k : Int) -> Array[(Double, Double, Double, Double, Double)] raise {
  let (x, y, w, h) = rove_tool(t, k)
  [(x, y, w, h, 1.0)]
}

///|
test "a row's shared hover ground: faded in under the first tool the pointer comes to, from nowhere else" {
  let t = rove_tester()
  assert_eq(rove_grounds(t), [], msg="none lit")
  let (x, y) = rove_mid(rove_tool(t, 0))
  t.move_to(x, y)
  t.run_for(rove_in_ms / 2.0)
  let half = rove_grounds(t)
  let (tx, ty, tw, th) = rove_tool(t, 0)
  assert_eq(half.length(), 1, msg="one: \{Repr(half)}")
  assert_eq((half[0].0, half[0].1, half[0].2, half[0].3), (tx, ty, tw, th), msg="where the tool is")
  assert_true(half[0].4 > 0.0 && half[0].4 < 1.0, msg="fading in: \{half[0].4}")
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 0), msg="whole under it")
}

///|
test "a row's shared hover ground: the pointer gone to the next, from where it was to there, one ground all the way; turned to a third on its way, from where it was then; gone off the row, faded out where it was" {
  let t = rove_tester()
  let (x, y) = rove_mid(rove_tool(t, 0))
  t.move_to(x, y)
  t.run_for(rove_over_ms)
  let (x, y) = rove_mid(rove_tool(t, 1))
  t.move_to(x, y)
  assert_eq(rove_grounds(t), rove_whole(t, 0), msg="as the pointer comes: where it was")
  t.run_for(rove_mid_ms)
  let mid = rove_grounds(t)
  assert_eq(mid.length(), 1, msg="one ground on its way: \{Repr(mid)}")
  let (from, to) = (rove_mid(rove_tool(t, 0)).0, rove_mid(rove_tool(t, 1)).0)
  let m = mid[0].0 + mid[0].2 / 2.0
  assert_true(m > from && m < to, msg="on its way: \{m} between \{from} and \{to}")
  assert_eq(mid[0].4, 1.0, msg="whole on its way")
  // (on to a third on its way: from where it is then)
  let (x, y) = rove_mid(rove_tool(t, 2))
  t.move_to(x, y)
  assert_eq(rove_grounds(t), mid, msg="turned: from where it was on its way")
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 2), msg="under the third")
  // (off the row: fading out where it was, then none)
  t.leave()
  t.run_for(rove_out_ms / 2.0)
  let out = rove_grounds(t)
  let (tx, ty, tw, th) = rove_tool(t, 2)
  assert_eq(out.length(), 1, msg="fading: \{Repr(out)}")
  assert_eq((out[0].0, out[0].1, out[0].2, out[0].3), (tx, ty, tw, th), msg="where it was")
  assert_true(out[0].4 > 0.0 && out[0].4 < 1.0, msg="fading out: \{out[0].4}")
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), [], msg="gone")
}

///|
test "a row's shared hover ground: the pointer back on the row as it fades out, from where it was then" {
  let t = rove_tester()
  let (x, y) = rove_mid(rove_tool(t, 0))
  t.move_to(x, y)
  t.run_for(rove_over_ms)
  t.leave()
  t.run_for(rove_out_ms / 2.0)
  let fading = rove_grounds(t)
  let (x, y) = rove_mid(rove_tool(t, 1))
  t.move_to(x, y)
  assert_eq(rove_grounds(t), fading, msg="from where it was, as much of it seen")
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 1), msg="under the one it came to")
}

///|
test "a row's shared hover ground: the keyboard's focus taken along the row, the ground with it" {
  let t = rove_tester()
  t.tab()
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 0), msg="under the first, focused")
  t.tab()
  assert_eq(rove_grounds(t), rove_whole(t, 0), msg="as the focus goes on: where it was")
  t.run_for(rove_mid_ms)
  let mid = rove_grounds(t)
  let (from, to) = (rove_mid(rove_tool(t, 0)).0, rove_mid(rove_tool(t, 1)).0)
  assert_true(mid.length() == 1 && mid[0].0 + mid[0].2 / 2.0 > from && mid[0].0 + mid[0].2 / 2.0 < to, msg="on its way: \{Repr(mid)}")
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 1), msg="under the second, focused")
}

///|
test "a row's shared hover ground: a finger's press lit under the tool at once, there; out at once as it is let go" {
  let t = rove_tester()
  t.host_says_finger(Some(true))
  let (x, y) = rove_mid(rove_tool(t, 1))
  t.touch(0, x, y)
  t.draw()
  assert_eq(rove_grounds(t), rove_whole(t, 1), msg="pressed: at once, under it: \{Repr(rove_grounds(t))}")
  t.touch(2, x, y)
  t.draw()
  assert_eq(rove_grounds(t), [], msg="let go: out at once")
  let (x, y) = rove_mid(rove_tool(t, 2))
  t.touch(0, x, y)
  t.draw()
  assert_eq(rove_grounds(t), rove_whole(t, 2), msg="the next pressed: at once, under it, from nowhere")
  t.touch(2, x, y)
  t.draw()
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), [], msg="none")
}

///|
test "roving_hover_node: critically damped handoff from tool 0 to tool 1 never overshoots [x_A, x_B]" {
  let t = rove_tester()
  let (x0, y0) = rove_mid(rove_tool(t, 0))
  let (x1, y1) = rove_mid(rove_tool(t, 1))
  let left0 = rove_tool(t, 0).0
  let left1 = rove_tool(t, 1).0
  t.move_to(x0, y0)
  t.run_for(rove_over_ms)
  t.move_to(x1, y1)
  let step = rove_mid_ms / 2.0
  for _ in 0..<25 {
    t.run_for(step)
    let gs = rove_grounds(t)
    assert_eq(gs.length(), 1, msg="one ground during handoff: \{Repr(gs)}")
    let gx = gs[0].0
    assert_true(gx >= left0 - 0.01 && gx <= left1 + 0.01, msg="roving hover overshot [\{left0}, \{left1}]: gx=\{gx}")
  }
  t.run_for(rove_over_ms)
  assert_eq(rove_grounds(t), rove_whole(t, 1), msg="settled on tool 1")
}
