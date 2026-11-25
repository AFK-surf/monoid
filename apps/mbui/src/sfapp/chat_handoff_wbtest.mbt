// A chat whose station does not answer gone on with on another station (sfpages chat_handoff.mbt): offered in its
// "…" only then, the stations that answer picked among, what it means said, then `copies.handoff` asked of the one
// picked and its new chat opened; a refusal said in the station's words, asked again under the same key.

///|
/// The fixture's chat in `mode` on 大屏 with what the mode puts up over it, its calls kept in `calls` and answered as
/// the fixture answers them (chat-handoff…: Willow away, Maple up; chat_fixture.mbt fix_handoff_call).
fn handoff_tester(calls : Array[Made], mode : String) -> @ui.Tester {
  new_run()
  let base = fixture(mode)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a chat whose station is away offers 在其他 station 接着做; Maple picked, 接着做 asks it of Maple and opens the new chat there" {
  let calls : Array[Made] = []
  let t = handoff_tester(calls, "chat-handoff")
  t.click(MenuItem, label="在其他 station 接着做")
  t.run_for(@ui.move_most_ms)
  // (the workspace's other stations: Maple, which answers)
  assert_true(t.find("选择接着做的 station") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  t.click(MenuItem, label="Maple")
  t.run_for(@ui.move_most_ms)
  for words in [
    "在 Maple 上接着做", "Willow 可能还在运行。从现在起，新对话和 Willow 上的原对话各自继续，不会同步。", "新对话从 Willow 的备份开始。",
    "Maple 有这个对话的消息，但没有 Willow 的工作目录：Willow 上的文件和没推送的提交都不在 Maple 上。",
  ] {
    assert_true(t.find(words) is Some(_), msg="\{words}: \{Repr(t.words().map(fn(w) { w.0 }))}")
  }
  assert_true(named(calls, "copies.handoff").is_empty())
  t.click(Button, label="接着做")
  t.run_for(@ui.move_most_ms)
  let asked = named(calls, "copies.handoff")
  assert_eq(asked.length(), 1)
  let p = Some(asked[0].params)
  assert_eq(text(p, "station"), "ws1/st2")
  assert_eq(text(p, "origin"), "st1")
  assert_true(number(p, "thread") > 0.0, msg="\{Repr(asked[0].params)}")
  assert_true(text(p, "key") != "", msg="\{Repr(asked[0].params)}")
  // (at work while Maple reads the backup: its words say so, 接着做 turning)
  assert_true(t.find("正在 Maple 上打开新对话…可能需要几十秒。") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(app.nav.top() is Chat({ session: "s-c1", .. }))
  t.run_for(1500.0 + @ui.move_most_ms * 2.0)
  match app.nav.top() {
    Chat(r) => {
      assert_eq(r.session, "s-h1")
      assert_eq(r.station, "ws1/st2")
    }
    _ => fail("not the new chat")
  }
  assert_true(t.find("在 Maple 上接着做") is None)
}

///|
test "a refused 接着做 says the station's words in its dialog; asked again, the same key goes" {
  let calls : Array[Made] = []
  let t = handoff_tester(calls, "chat-handoff-confirm")
  @sffixture.fix_handoff_refused.val = true
  t.click(Button, label="接着做")
  t.run_for(@ui.move_most_ms)
  let refused = "没有 station 保存着 Willow 的对话备份，所以不能从备份继续：等 Willow 重新上线后，在那里打开这个对话"
  assert_true(t.find(refused) is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(app.nav.top() is Chat({ session: "s-c1", .. }))
  @sffixture.fix_handoff_refused.val = false
  t.click(Button, label="接着做")
  t.run_for(1500.0 + @ui.move_most_ms * 2.0)
  let asked = named(calls, "copies.handoff")
  assert_eq(asked.length(), 2)
  assert_eq(text(Some(asked[0].params), "key"), text(Some(asked[1].params), "key"))
  assert_true(app.nav.top() is Chat({ session: "s-h1", .. }))
}

///|
test "a chat whose station answers offers no 在其他 station 接着做" {
  let calls : Array[Made] = []
  let t = handoff_tester(calls, "chat-actions")
  assert_true(t.find("分享") is Some(_) || t.find("重命名") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(t.find("在其他 station 接着做") is None)
}
