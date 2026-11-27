// The chat's info popover (sfdesk's chat_page.mbt, kit's popover) on 大屏: its fade and growth are drawn as each frame
// is painted (@motion.presence_by), so the chat's old view that opens it is not built again at each frame of its way in
// or out.

///|
/// The frames drawn every 16 ms over `span` ms after `act` that built the chat's old view again, and why each.
fn info_pop_island_builds(t : @ui.Tester, act : () -> Unit raise, span? : Double = 240.0) -> Array[String] raise {
  let t0 = t.time()
  t.advance(between_frames_ms)
  act()
  let built : Array[String] = []
  let mut at = 16.0
  while at <= span {
    t.frame_at(t0 + at)
    let why = t.built_why()
    if why.contains("old island") {
      built.push("at \{at}: \{why}")
    }
    at += 16.0
  }
  built
}

///|
test "大屏: the chat's info popover opens and closes without building the chat's old view at each frame" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  // (the keyboard taken from the composer first: what it says while empty changes as the keyboard leaves it, a fade of
  // its own)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  t.back()
  t.run_for(@ui.move_most_ms)
  let opened = info_pop_island_builds(t, fn() { t.click(Button, label="对话信息") })
  // (none at the frames of its way in)
  assert_true(opened.length() <= 1, msg=opened.join("\n"))
  assert_true(t.query(Dialog) is Some(_))
  t.run_for(@ui.move_most_ms)
  let closed = info_pop_island_builds(t, fn() { t.back() })
  // (once as it has gone, none at the frames of its way out)
  assert_true(closed.length() <= 1, msg=closed.join("\n"))
  assert_true(t.query(Dialog) is None)
}
