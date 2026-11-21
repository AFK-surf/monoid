// Words sent from a chat on its page made as nodes (sfbase's chat_page_nodes on), its station taking them: what was
// sent from here and taken over by the core's rows is no more on its way (sfbase's local_sending), so a list made
// again (the chat opened again) has nothing of it to match anew. Till 2026-11-15 the page
// made as nodes never let go of what it took over: every word sent stayed on its way for the run, and a list made again
// matched it anew against rows it no longer read, the last sent drawn again under the rest, 正在发送 under them (the
// user's screenshot: 「这他妈又是什么 bug」).

///|
let sa_words : Array[String] = ["先看一下", "然后改", "所以怎么改？"]

///|
/// How many times each of `sa_words` is drawn, and whether 正在发送 is.
fn sa_look(t : @ui.Tester) -> (Array[Int], Bool) {
  let drawn = @ui.view_tree().unwrap().drawn()
  let n = sa_words.map(fn(w) { drawn.iter().filter(fn(d) { d.words == w && d.alpha > 0.0 }).count() })
  let sending = @sf.t("web-main.chat.sending")
  (n, t.drawn_of(sending) is Some(_))
}

///|
test "a chat's page made as nodes, 小屏 and 大屏: words sent and taken by the station leave what is on its way, each drawn once, none sending" {
  for screen in ss_screens {
    let (name, w, h, platform) = screen
    new_run()
    @sfbase.hold_chat_page_nodes(Some(true))
    fix_pace.val = (100.0, 30000.0, fix_turn_end_ms)
    fix_sent_for.val = -1.0
    fix_core_for.val = 0.0
    let src = fixture("chat")
    let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    let rk = r.station + "\u{1}" + r.session
    open_chat(r)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@ui.move_most_ms)
    guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("\{name}: no composer's field") }
    t.tap(fx + fw / 2.0, fy + fh / 2.0)
    for words in sa_words {
      t.type_text(words)
      tap_send(t)
      t.run_for(1000.0 + @ui.move_most_ms)
    }
    let (sent, sending) = sa_look(t)
    assert_eq(sent, [1, 1, 1], msg="\{name}: each sent drawn once, as sent")
    assert_false(sending, msg="\{name}: none sending once the station took them")
    assert_eq(@sfbase.sending_of(rk).length(), 0, msg="\{name}: what the core's rows took over left what is on its way")
    fix_core_for.val = 0.0
  }
}

///|
/// What the station took of `n` words sent, each its own: sent 1, sent 2, ….
fn sa_many(n : Int) -> Array[String] {
  Array::makei(n, fn(i) { "第 \{i + 1} 条" })
}

///|
test "a chat's page made as nodes, 小屏: more words sent than its window holds, the chat opened again, each drawn once and none sending" {
  // The core sends a chat opened only its last messages (`chat.window`, chat_first_window: 30 on 小屏), so a chat
  // opened again holds only the last of what was sent from here: what was sent earlier and is on its way still has no
  // row of the core's to match there (the user's screenshot of 2026-11-15, 「这他妈又是什么 bug」, three sent drawn again
  // under the rest with 正在发送). The made-up chat is given only its window, as the core gives it.
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  fix_pace.val = (100.0, 30000.0, fix_turn_end_ms)
  fix_sent_for.val = -1.0
  fix_core_for.val = 0.0
  // (through the app's own client of its core, which tells the core a chat's window before each time it asks it)
  let src = round_trip_again(fixture("chat"), 0.0)
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let window = @sfbase.chat_first_window(844.0)
  let words = sa_many(window + 3)
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("no composer's field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  for w in words {
    t.type_text(w)
    tap_send(t)
    t.run_for(400.0 + @ui.move_most_ms)
  }
  t.back()
  t.run_for(@ui.move_most_ms)
  open_chat(r)
  t.run_for(1000.0 + @ui.move_most_ms)
  let drawn = @ui.view_tree().unwrap().drawn()
  let twice = words.filter(fn(w) { drawn.iter().filter(fn(d) { d.words == w && d.alpha > 0.0 }).count() > 1 })
  assert_eq(twice, [], msg="each sent drawn once in the chat opened again")
  assert_false(t.drawn_of(@sf.t("web-main.chat.sending")) is Some(_), msg="none sending once the station took them")
}
