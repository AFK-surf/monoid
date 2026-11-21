// A chat's page made as nodes, on 大屏: the time under one's own message (刚刚), as it takes the place of what was under
// it, comes in on the side the message is on, where it rests (the user, 2026-11-17: 「81-82 帧」,
// 刚刚 drawn from the start of a place held as wide as what it took the place of, then at its end in one frame:
// mbui's pick_leave: a place laid out at once as the change has it, what fades drawn where it stood).

///|
/// The most either edge of 刚刚 moves from one frame to the next as it grows (points): on main it went 39 across.
let time_step_most : Double = 8.0

///|
test "the time under one's own message comes in where it rests, never jumping across" {
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  let src = fixture("chat")
  fix_core_for.val = 100.0
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  nav_rested(t)
  files_page_over(t, 1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { @halt.saying("no composer's field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text("发布前再看一眼签名")
  t.key(@ui.key_code_enter)
  // (where 刚刚 under one's own message (on the window's right) starts and ends, each frame it is seen, as drawn)
  let sides : Array[(Double, Double)] = []
  t.each_frame(
    Some(fn() {
      match t.words().search_by(fn(w) { w.0 == "刚刚" && w.5 > 0.0 && w.1 > 640.0 }) {
        Some(i) => {
          let w = t.words()[i]
          sides.push((w.1, w.1 + w.3))
        }
        None => ()
      }
    }),
  )
  t.run_shown(@sfbase.flight_desk_ms * 4.0)
  t.each_frame(None)
  fix_core_for.val = 0.0
  assert_true(sides.length() > 2, msg="刚刚 seen in \{sides.length()} frames")
  // (from one frame to the next its edges move as it grows, a few points; never across in one frame)
  for i in 1..<sides.length() {
    let (x0, e0) = sides[i - 1]
    let (x1, e1) = sides[i]
    assert_true(
      (x1 - x0).abs() <= time_step_most && (e1 - e0).abs() <= time_step_most,
      msg="刚刚 from \{x0}..\{e0} to \{x1}..\{e1} in one frame",
    )
  }
}

///|
test "the time under one's own message, once seen, is not drawn from nothing again as an answer comes under it" {
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  let src = fixture("chat")
  fix_core_for.val = 100.0
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  nav_rested(t)
  files_page_over(t, 1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { @halt.saying("no composer's field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text("发布前再看一眼签名")
  t.key(@ui.key_code_enter)
  // (how opaque 刚刚 under one's own message (on the window's right) is drawn, each frame it is drawn, once it has been
  // seen whole: the agent's answer coming in under it moves its row, and nothing of it changes)
  let whole = Ref(false)
  let least = Ref(1.0)
  let answered = Ref(false)
  t.each_frame(
    Some(fn() {
      for w in t.words() {
        if w.0 == "收到：「发布前再看一眼签名」。我先看一下，有结果再告诉你。" {
          answered.val = true
        }
        if w.0 == "刚刚" && w.1 > 640.0 {
          if whole.val {
            least.val = @cmp.minimum(least.val, w.5)
          } else if w.5 >= 0.999 {
            whole.val = true
          }
        }
      }
    }),
  )
  t.run_shown(4000.0)
  t.each_frame(None)
  fix_core_for.val = 0.0
  assert_true(whole.val, msg="刚刚 under one's own message never seen whole")
  assert_true(answered.val, msg="the agent's answer never came")
  assert_true(least.val >= 0.999, msg="刚刚 drawn at \{least.val} after it was seen whole")
}
