// An agent's activity once its answer comes (sfbase's chat_list.mbt chat_tick): it goes as the last of its messages
// leaves its avatar, its turn over or not, whatever page shows; a turn over stays no moment after.

///|
/// The fixture's chat open, on the frames' clock; words sent (its agent then at work, answering, its turn ending).
fn linger_core() -> @ui.Tester {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  t.tap_text("发消息")
  t.type_text("看一下列表")
  tap_send(t)
  t
}

///|
fn lingering() -> Int {
  match readings.get("ws1/st1\u{1}s-c1") {
    Some(rd) => rd.linger.length()
    None => -1
  }
}

///|
test "its turn over while another page covers its chat: gone meanwhile, not there as the chat shows again" {
  let t = linger_core()
  // scrolled up: its answer just appears (nothing comes out of an avatar)
  t.run_for(fix_deliver_ms)
  t.wheel(195.0, 400.0, -600.0)
  t.run_for(fix_answer_ms)
  assert_eq(lingering(), 0)
  // another page over the chat; its agent's turn over under it, a second gone by
  app.nav.push(Settings)
  t.run_for(@ui.move_most_ms)
  t.run_for(fix_turn_end_ms + 1000.0)
  t.back()
  t.draw()
  // the chat shown again: its activity went under the page
  assert_eq(lingering(), 0)
  t.run_for(@ui.move_most_ms)
  assert_eq(lingering(), 0)
  t.assert_idle()
}
