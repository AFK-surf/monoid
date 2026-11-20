// The block's way between open and folded (sfdesk's pane_view.mbt): each frame built once, the page getting wider or
// narrower telling nothing that reads only how tall its composer is (@motion.measured); the sidebar's rows and the
// chat's kept as they were built, what moves each frame building none of them again; the chat's old view laid out where
// the way ends and moved there by its node, built as a way sets off and at no other frame of it (page_pane.mbt
// pane_fold_held).

///|
test "大屏: on the block's way each frame built once, the lists' rows kept" {
  let calls : Array[Made] = []
  // (the old page, what stable keeps: its rows kept as built; the chat made as nodes lays out no old view to keep)
  let t = wide_tester(calls, mode="chat", before=fn(_) { @sfbase.hold_chat_page_nodes(Some(false)) })
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  // (its first frames building them once for all of its way)
  t.frame_at(t0 + 40.0)
  t.frame_at(t0 + 60.0)
  let on_way : Array[Int] = []
  for at in [80.0, 100.0, 120.0] {
    t.frame_at(t0 + at)
    // (where the frame lays the old view out, its rows kept; one that lays out nothing of it keeps none to say)
    let (kept, _) = t.rows_as_nodes()
    assert_true(kept > 0 || t.built_why() == "", msg="at \{at}: no rows kept")
    on_way.push(t.frame_perf().passes)
  }
  assert_eq(on_way, [1, 1, 1])
}

///|
test "大屏: on the block's way a chat's column as wide as at either end, its words not laid out otherwise" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-long")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let line = "和首页那边的改动有关"
  let size = fn() {
    guard t.rect_of(line) is Some((_, _, w, h)) else { return (-1.0, -1.0) }
    (w, h)
  }
  let was = size()
  assert_true(was.0 > 0.0)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  for at in [40.0, 80.0, 120.0, 200.0] {
    t.frame_at(t0 + at)
    assert_eq(size(), was)
  }
}

///|
test "大屏: folding to the board does not rebuild the old view on each frame" {
  let (t, _) = board_at("board-list", 1280.0, 800.0)
  t.click(Button, label="看板")
  let start = t.time()
  for after in [80.0, 100.0, 120.0] {
    t.frame_at(start + after)
    let p = t.frame_perf()
    assert_true(p.nodes <= 5, msg="at \{after}: \{p.nodes}, \{t.built_why()}")
  }
}

///|
test "大屏: the chats key pressed twice, the chat's old view built only as each way sets off, not at each frame" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let (x, y, w, h) = t.query(Button, label="对话").unwrap().rect
  let press = fn() { t.tap(x + w / 2.0, y + h / 2.0) }
  let t0 = t.time()
  // (pressed, and again as the sidebar is on its way to be shown a while: a double click; what the frame after each
  // press builds is that press's, every other frame of the ways builds nothing of the old view)
  let presses = [8.0, 88.0]
  let built : Array[String] = []
  let mut after_press = false
  for at = 16.0; at <= 480.0; at = at + 16.0 {
    for p in presses {
      if p > at - 16.0 && p <= at {
        t.advance(t0 + p - t.time())
        press()
        after_press = true
      }
    }
    t.frame_at(t0 + at)
    let why = t.built_why()
    if !after_press && why != "" && why != "the one before it laid out otherwise" {
      built.push("\{at}: \{why}")
    }
    after_press = false
  }
  assert_false(@sfdesk.wide.folded.get())
  assert_eq(built, [])
}

///|
/// The rail's chats key pressed on 大屏 over the new chat (platform 0, or 1 beside the system's bars), the sidebar
/// folded and then shown again: the new chat's old view is laid out anew at each width of both ways as before, not held
/// where the way ends as a chat's is (pane_fold_held), so its prompt goes with the pane and steps nowhere (the
/// Tester's sizes_steady, on the frames drawn along run_for at 60 and 120 fps).
fn fold_new_chat(platform : Int) -> Unit raise {
  // (made here, not by wide_tester: its file's motion is counted, this file's held to steady)
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform~)
  t.run_for(@ui.move_most_ms)
  let prompt = "想让 agent 做什么？"
  assert_true(t.rect_of(prompt) is Some(_), msg="no new chat: \{Repr(t.words())}")
  let keys = t.all(Button).filter(fn(b) { b.rect.0 < 70.0 })
  guard keys.search_by(fn(b) { b.label == "对话" || b.label == "全部对话" || b.label == "全部" }) is Some(i) else {
    fail("no chats' key in the rail: \{keys.map(fn(b) { b.label }).join(", ")}")
  }
  let (x, y, w, h) = keys[i].rect
  for folded in [true, false] {
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_eq((@sfdesk.side_folded(), t.rect_of(prompt) is Some(_)), (folded, true))
  }
}

///|
test "大屏: the chats key pressed twice over the new chat, its prompt going with the pane both ways" {
  fold_new_chat(0)
}

///|
test "大屏 beside the system's bars: the chats key pressed twice over the new chat, its prompt going with the pane both ways" {
  fold_new_chat(1)
}
