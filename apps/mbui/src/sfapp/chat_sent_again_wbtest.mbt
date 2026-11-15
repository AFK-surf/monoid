// Words sent from a chat on its page made as nodes (sfbase's chat_page_nodes on), its station taking them, the chat
// opened again: what was sent from here and taken over by the core's rows is no more on its way (sfbase's
// local_sending), so the list made again shows each sent once and none of them as sending. Till 2026-11-15 the page
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
test "a chat's page made as nodes, 小屏 and 大屏: words sent and taken by the station leave what is on its way; the chat opened again shows each once, none sending" {
  for screen in ss_screens {
    let (name, w, h, platform) = screen
    new_run()
    @sfbase.chat_page_nodes.set(true)
    fix_pace.val = (100.0, 30000.0, fix_turn_end_ms)
    fix_sent_for.val = -1.0
    fix_core_for.val = 0.0
    let src = fixture("chat")
    let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    let rk = r.station + "\u{1}" + r.session
    open_chat(r)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@ui.move_most_ms)
    for words in sa_words {
      guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("\{name}: no composer's field") }
      t.tap(fx + fw / 2.0, fy + fh / 2.0)
      t.type_text(words)
      tap_send(t)
      t.run_for(1000.0 + @ui.move_most_ms)
    }
    let (sent, sending) = sa_look(t)
    assert_eq(sent, [1, 1, 1], msg="\{name}: each sent drawn once, as sent")
    assert_false(sending, msg="\{name}: none sending once the station took them")
    assert_eq(@sfbase.sending_of(rk).length(), 0, msg="\{name}: what the core's rows took over left what is on its way")
    // (the chat opened again: its list made anew)
    open_chat({ station: "ws1/st1", session: "s-c2", title: "首页的列表改成按天分组", station_name: "Willow" })
    t.run_for(@ui.move_most_ms)
    open_chat(r)
    t.run_for(@ui.move_most_ms)
    let (again, sending_again) = sa_look(t)
    assert_eq(again, [1, 1, 1], msg="\{name}: opened again, each sent drawn once")
    assert_false(sending_again, msg="\{name}: opened again, none sending")
    fix_core_for.val = 0.0
  }
}
