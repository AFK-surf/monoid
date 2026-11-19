// What a draft refers to, shared before it goes (outside.mbt): over the fake core of composer_wbtest.mbt, whose calls
// the test answers, and over the fixture (its 个人 workspace's chats, chat_fixture.mbt fix_outside).

///|
/// On the frames' clock to where the sharing sheet rests, risen or sunk away: a Move as long as its height makes it
/// (@sf.panel_nodes' sheet), over by the longest a Move is.
fn run_to_outside_rest(t : @ui.Tester) -> Unit {
  t.run_for(@ui.move_most_ms)
}

///|
/// Another workspace's chat as the core's `chat.outsideRefs` names it.
fn outside_chat(id : String, title : String, may : Bool) -> Json {
  {
    "station": "ws2/st9",
    "id": Json::string(id),
    "title": Json::string(title),
    "workspace": "ws2",
    "workspaceName": "个人",
    "may": Json::boolean(may),
  }
}

///|
test "words with no reference go at once: the core is not asked what they refer to" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("没有引用的话")
  tap_send(t)
  assert_eq(named(calls, "chat.outsideRefs").length(), 0)
  assert_eq(named(calls, "chat.send").length(), 1)
  t.run_for(flight_wait_ms + @ui.move_most_ms)
  // (its row under way: said so once it has been a while, sfpages chat_rows.mbt)
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

///|
test "a reference to another workspace's chat: asked first, the sheet says whose, 分享并发送 shares it, then it goes" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("先看 @[季度路线图] 再定")
  tap_send(t)
  // nothing sent yet: the core asked what the words refer to, a second tap meanwhile nothing more
  tap_send(t)
  let asked = named(calls, "chat.outsideRefs")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0].params), "text"), "先看 @[季度路线图] 再定")
  assert_eq(text(Some(asked[0].params), "station"), "ws1/st1")
  assert_eq(named(calls, "chat.send").length(), 0)
  (asked[0].done)(Ok({ "chats": [outside_chat("s-p1", "季度路线图", true)] }))
  t.draw()
  run_to_outside_rest(t)
  assert_true(t.find("分享对话") is Some(_))
  assert_true(t.find("季度路线图") is Some(_))
  // whose: 来自, then that workspace's mark (its letter, 个, where it has none) and its name
  assert_true(t.find("来自 ") is Some(_) && t.find("个") is Some(_) && t.find("个人") is Some(_))
  assert_true(t.find("你没有分享权限，需由发起人或管理员分享") is None)
  t.tap_text("分享并发送")
  // (which of them the viewer may share, and with which workspace, the core's: chat.outsideShare)
  let shared = named(calls, "chat.outsideShare")
  assert_eq(shared.length(), 1)
  let p = Some(shared[0].params)
  assert_eq(text(p, "station"), "ws1/st1")
  assert_eq(text(p, "text"), "先看 @[季度路线图] 再定")
  // not sent until it is shared
  assert_eq(named(calls, "chat.send").length(), 0)
  (shared[0].done)(Ok(Json::object({})))
  t.draw()
  let sent = named(calls, "chat.send")
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].params), "text"), "先看 @[季度路线图] 再定")
  let (_, words, _, _) = t.ime()
  assert_eq(words, "")
  // the sheet sinks away, the words wait for their row (which this core never gives), the composer's room let go
  run_to_outside_rest(t)
  assert_true(t.find("分享对话") is None)
  t.run_for(flight_wait_ms + @ui.move_most_ms)
  // (its row under way: said so once it has been a while, sfpages chat_rows.mbt)
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

///|
test "a share that fails is said in the sheet: nothing goes, the words stay; 取消 leaves them as they were" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("对照 @[季度路线图]")
  tap_send(t)
  (named(calls, "chat.outsideRefs")[0].done)(Ok({ "chats": [outside_chat("s-p1", "季度路线图", true)] }))
  t.draw()
  run_to_outside_rest(t)
  t.tap_text("分享并发送")
  (named(calls, "chat.outsideShare")[0].done)(Err({ "code": "forbidden", "message": "对方工作区不接受" }))
  t.draw()
  assert_true(t.find("分享失败：对方工作区不接受") is Some(_))
  assert_eq(named(calls, "chat.send").length(), 0)
  t.tap_text("取消")
  run_to_outside_rest(t)
  assert_true(t.find("分享对话") is None)
  assert_eq(named(calls, "chat.send").length(), 0)
  let (_, words, _, _) = t.ime()
  assert_eq(words, "对照 @[季度路线图]")
  // sent again: asked again
  tap_send(t)
  assert_eq(named(calls, "chat.outsideRefs").length(), 2)
  // the last tap's ripple shown whole, its way in and out
  t.run_for(@motion.ripple_tap_ms)
  t.assert_idle()
}

///|
test "none of them the viewer may share: each says so, and 仍然发送 sends it as it is" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("参考 @[预算草稿]")
  tap_send(t)
  (named(calls, "chat.outsideRefs")[0].done)(Ok({ "chats": [outside_chat("s-p2", "预算草稿", false)] }))
  t.draw()
  run_to_outside_rest(t)
  assert_true(t.find("你没有分享权限，需由发起人或管理员分享") is Some(_))
  assert_true(t.find("分享并发送") is None)
  t.tap_text("仍然发送")
  assert_eq(named(calls, "chat.outsideShare").length(), 0)
  assert_eq(named(calls, "chat.send").length(), 1)
  run_to_outside_rest(t)
  t.run_for(flight_wait_ms + @ui.move_most_ms)
  // (its row under way: said so once it has been a while, sfpages chat_rows.mbt)
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

///|
test "a core that cannot say what the words refer to: they go as they are" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("看 @[季度路线图]")
  tap_send(t)
  (named(calls, "chat.outsideRefs")[0].done)(Err({ "code": "unknown_call", "message": "chat.outsideRefs" }))
  t.draw()
  assert_eq(named(calls, "chat.send").length(), 1)
  assert_true(t.find("分享对话") is None)
  t.run_for(flight_wait_ms + @ui.move_most_ms)
  // (its row under way: said so once it has been a while, sfpages chat_rows.mbt)
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

///|
test "a new chat's first message is shared before it goes too, over the fixture's core" {
  let t = tester("home")
  let (_, y) = bar_places_at()
  t.tap(195.0, y - 28.0 - 4.0)
  t.run_for(@ui.move_most_ms)
  outside_tap_field(t, "做任何事")
  t.type_text("按 @[季度路线图] 排一下")
  tap_send(t)
  // asked first: the page is still the new chat, the sheet over it
  assert_true(!(app.nav.top() is Chat(_)))
  run_to_outside_rest(t)
  // whose: 来自, then that workspace's mark (its letter, 个, where it has none) and its name
  assert_true(t.find("来自 ") is Some(_) && t.find("个") is Some(_) && t.find("个人") is Some(_))
  t.tap_text("分享并发送")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "new:1")
    _ => fail("not the chat")
  }
  assert_true(fix_xshared.contains("s-p1"))
}

///|
test "references the core says nothing of: the words go with no sheet" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  outside_tap_field(t, "发消息")
  t.type_text("同一个工作区的 @[发布清单]")
  tap_send(t)
  (named(calls, "chat.outsideRefs")[0].done)(Ok({ "chats": [] }))
  t.draw()
  assert_eq(named(calls, "chat.send").length(), 1)
  assert_true(t.find("分享对话") is None)
  t.run_for(flight_wait_ms + @ui.move_most_ms)
  // (its row under way: said so once it has been a while, sfpages chat_rows.mbt)
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

// With keyboard and mouse, and on a wide window (a dialog in the middle there): Enter again says yes, Escape and a
// press outside are 取消; where its words stand on each screen.

///|
/// A chat of another workspace as the core's `chat.outsideRefs` says it: `title`, its workspace `name` (its mark
/// `emoji`, "" its letter), whether the viewer may share it.
fn outside_chat_of(title : String, name : String, emoji : String, may : Bool) -> Json {
  {
    "station": "ws2/st9",
    "id": Json::string("s-" + title),
    "title": Json::string(title),
    "workspace": "ws2",
    "workspaceName": Json::string(name),
    "workspaceEmoji": Json::string(emoji),
    "workspaceIcon": "",
    "may": Json::boolean(may),
  }
}

///|
/// Words with a mark written in the fixture's chat and sent, the core answering that they refer to `chats` of other
/// workspaces: the asking up, come to rest.
fn outside_asked(
  calls : Array[Made],
  chats : Array[Json],
  platform? : Int = 2,
  wide? : Bool = false,
  rest? : Bool = true,
) -> @ui.Tester {
  let t = fake_core(calls, platform~)
  if wide {
    t.resize(1200.0, 800.0)
    t.run_for(@ui.move_most_ms)
  }
  outside_tap_field(t, "发消息")
  t.type_text("@[首页] 吧")
  t.draw()
  t.draw()
  tap_send(t)
  let asked = named(calls, "chat.outsideRefs")
  guard asked.length() == 1 else { @halt.saying("the core asked \{asked.length()} times") }
  (asked[0].done)(Ok({ "chats": Json::array(chats) }))
  t.draw()
  t.frame()
  if rest {
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
/// The two chats most of these ask about: one the viewer may share, of a workspace with no mark; one they may not, of
/// one with an emoji.
fn outside_two() -> Array[Json] {
  [outside_chat_of("季度路线图", "个人", "", true), outside_chat_of("发布检查", "开源", "🌲", false)]
}

///|
test "分享对话: which chats and whose, the one that cannot be shared saying so; 分享并发送 shares, then sends" {
  let calls : Array[Made] = []
  let t = outside_asked(calls, outside_two())
  assert_true(t.find("分享对话") is Some(_))
  assert_true(t.find("发送后，此 workspace 中的 agent 可读取以下内容（连续 6 小时未使用即失效）：") is Some(_))
  assert_true(t.find("季度路线图") is Some(_))
  assert_true(t.find("发布检查") is Some(_))
  assert_true(t.find("你没有分享权限，需由发起人或管理员分享") is Some(_))
  // nothing sent while it asks
  assert_eq(named(calls, "chat.send").length(), 0)
  t.tap_text("分享并发送")
  t.draw()
  let shared = named(calls, "chat.outsideShare")
  assert_eq(shared.length(), 1)
  assert_eq(text(Some(shared[0].params), "station"), "ws1/st1")
  assert_eq(text(Some(shared[0].params), "text"), "@[首页] 吧")
  assert_eq(named(calls, "chat.send").length(), 0)
  // pressed again while it shares: asked once
  t.tap_text("分享并发送")
  t.draw()
  assert_eq(named(calls, "chat.outsideShare").length(), 1)
  (shared[0].done)(Ok(Json::object({})))
  t.draw()
  t.draw()
  assert_eq(named(calls, "chat.send").length(), 1)
  assert_eq(text(Some(named(calls, "chat.send")[0].params), "text"), "@[首页] 吧")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
}

///|
test "分享对话 with keyboard and mouse on a small window: Enter says yes, once" {
  let calls : Array[Made] = []
  let t = outside_asked(calls, outside_two(), platform=0)
  assert_true(t.find("分享对话") is Some(_))
  t.enter()
  t.draw()
  assert_eq(named(calls, "chat.outsideShare").length(), 1)
  assert_eq(named(calls, "chat.send").length(), 0)
  // (Enter again while it shares: asked once)
  t.enter()
  t.draw()
  assert_eq(named(calls, "chat.outsideShare").length(), 1)
  (named(calls, "chat.outsideShare")[0].done)(Ok(Json::object({})))
  t.draw()
  t.draw()
  assert_eq(named(calls, "chat.send").length(), 1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
}

///|
test "分享对话 with keyboard and mouse: Escape is 取消" {
  let calls : Array[Made] = []
  let t = outside_asked(calls, outside_two(), platform=0)
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
  assert_eq(named(calls, "chat.outsideShare").length(), 0)
  assert_eq(named(calls, "chat.send").length(), 0)
  let (_, words, _, _) = t.ime()
  assert_eq(words, "@[首页] 吧")
}

///|
test "分享对话 on a wide window: a dialog in the middle; Enter says yes, once" {
  let calls : Array[Made] = []
  let t = outside_asked(calls, outside_two(), platform=0, wide=true)
  // in the middle of the window: its title neither at its foot nor at its side
  let (x, y, _, _) = t.rect_of("分享对话").unwrap()
  assert_true(x > 200.0 && x < 800.0 && y > 150.0 && y < 500.0, msg="its title at \{x},\{y}")
  t.enter()
  t.draw()
  assert_eq(named(calls, "chat.outsideShare").length(), 1)
  assert_eq(named(calls, "chat.send").length(), 0)
  t.enter()
  t.draw()
  assert_eq(named(calls, "chat.outsideShare").length(), 1)
  (named(calls, "chat.outsideShare")[0].done)(Ok(Json::object({})))
  t.draw()
  t.draw()
  assert_eq(named(calls, "chat.send").length(), 1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
}

///|
test "分享对话: the focus on 分享并发送 as it opens in the middle of a wide window, never on it on a sheet (by touch or with keyboard and mouse)" {
  for screen in [(2, false), (0, false), (0, true)] {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let calls : Array[Made] = []
    let t = outside_asked(calls, outside_two(), platform~, wide~)
    let said = t.focus_said()
    if wide {
      assert_true(said.contains("分享并发送"), msg="\{at}: \{said}")
    } else {
      assert_true(!said.contains("分享并发送"), msg="\{at}: \{said}")
    }
  }
}

///|
test "分享对话 on a wide window: 取消, Escape and a press outside it send nothing" {
  let calls : Array[Made] = []
  let t = outside_asked(calls, outside_two(), platform=0, wide=true)
  t.tap_text("取消")
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
  let calls2 : Array[Made] = []
  let t = outside_asked(calls2, outside_two(), platform=0, wide=true)
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
  let calls3 : Array[Made] = []
  let t = outside_asked(calls3, outside_two(), platform=0, wide=true)
  t.tap(20.0, 780.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("分享对话") is None)
  for c in [calls, calls2, calls3] {
    assert_eq(named(c, "chat.outsideShare").length(), 0)
    assert_eq(named(c, "chat.send").length(), 0)
  }
}

///|
/// Where the first of the words `words` is drawn: its left, top, width and height.
fn outside_word(t : @ui.Tester, words : String) -> (Double, Double, Double, Double) {
  match t.words().iter().find_first(fn(w) { w.0 == words }) {
    Some(w) => (w.1, w.2, w.3, w.4)
    None => @halt.saying("\{words} is not drawn")
  }
}

///|
test "分享对话: a chat and whose it is on one line, why it cannot be shared in what is left of that line; its buttons" {
  // (touch on a small window, a sheet; keyboard and mouse there, a sheet too; a wide window, a dialog in its middle)
  for screen in [(2, false), (0, false), (0, true)] {
    let calls : Array[Made] = []
    let t = outside_asked(calls, outside_two(), platform=screen.0, wide=screen.1)
    let about = "platform \{screen.0}, wide \{screen.1}"
    let mid = fn(r : (Double, Double, Double, Double)) { r.1 + r.3 / 2.0 }
    let lead = outside_word(t, "发送后，此 workspace 中的 agent 可读取以下内容（连续 6 小时未使用即失效）：")
    // whose each is: 来自, the workspace's mark (its letter where it has none, its emoji), its name
    // (its letter the one on its name's line: a wide window's rail draws the workspace in view's too)
    let name = outside_word(t, "个人")
    let letter = t.words().iter().find_first(fn(w) { w.0 == "个" && (w.2 + w.4 / 2.0 - mid(name)).abs() < 1.0 })
    assert_true(letter is Some(w) && w.1 + w.3 <= name.0, msg="\{about}: 个 \{Repr(letter)}, 个人 \{Repr(name)}")
    let (emoji, open) = (outside_word(t, "🌲"), outside_word(t, "开源"))
    // (an emoji on the baseline its line's face gives it: within a point or two of the words' middle)
    assert_true(emoji.0 + emoji.2 <= open.0 && (mid(emoji) - mid(open)).abs() < 2.0, msg="\{about}: 🌲 \{Repr(emoji)}, 开源 \{Repr(open)}")
    // the one that cannot be shared: its title, whose it is and why not on one line, why not after them out to
    // where the panel's words end
    let title = outside_word(t, "发布检查")
    let no = outside_word(t, "你没有分享权限，需由发起人或管理员分享")
    assert_true((mid(title) - mid(open)).abs() < 1.0 && (mid(title) - mid(no)).abs() < 1.0, msg="\{about}: \{Repr(title)}, \{Repr(open)}, \{Repr(no)}")
    assert_true(no.0 > open.0 + open.2, msg="\{about}: \{Repr(open)}, \{Repr(no)}")
    assert_true((no.0 + no.2 - (lead.0 + lead.2)).abs() < 1.0, msg="\{about}: \{Repr(no)}, the lead \{Repr(lead)}")
    // 取消 before 分享并发送: across a sheet, a half each; at a dialog's end
    let (cancel, yes) = (outside_word(t, "取消"), outside_word(t, "分享并发送"))
    let half = lead.0 + lead.2 / 2.0
    assert_true((mid(cancel) - mid(yes)).abs() < 1.0, msg="\{about}: \{Repr(cancel)}, \{Repr(yes)}")
    if screen.1 {
      assert_true(cancel.0 > half && cancel.0 + cancel.2 < yes.0, msg="\{about}: \{Repr(cancel)}, \{Repr(yes)}")
    } else {
      assert_true(cancel.0 + cancel.2 < half && yes.0 > half, msg="\{about}: \{Repr(cancel)}, \{Repr(yes)}")
    }
  }
}

///|
test "分享对话 on a sheet by touch: 分享并发送, drawn less tall than a press's room, is pressed from 3 over it and 3 under it" {
  // (the window's tree reaching what is drawn smaller than its room from round it, as an old view's hit test does:
  // mbui's view/reach.mbt)
  for dy in [-3.0, 3.0] {
    let calls : Array[Made] = []
    let t = outside_asked(calls, outside_two())
    let (x, y, w, h) = t.get(Button, label="分享并发送").rect
    assert_true(h < @ui.room_least(), msg="drawn \{h} tall")
    t.tap(x + w / 2.0, if dy < 0.0 { y + dy } else { y + h + dy })
    t.draw()
    assert_eq(named(calls, "chat.outsideShare").length(), 1, msg="\{dy} from it: \{Repr((x, y, w, h))}")
  }
}

// Enter, not send pressed, over the fixture's core answering through the app's client as a device's core does (between
// frames, a round trip: round_trip_again): what Enter asks of the core and what the core and the viewer answer go at
// once, on a new chat and on a chat, a phone's window and a wide one, the frames' check of what was kept on and off
// (Tester::check_looks: off, nothing built for the Tester's eyes alone does a device's work). Enter was read as the
// composer was built, after what it asked was read there (outside.mbt then left the send to the composer's next build,
// which its island, kept as it was, never came to): the words stuck in the field till something else built it.

///|
/// How late what is answered late (outside_round_trip's `late`: a station answering what the words refer to and
/// sharing them) comes: a round trip to it, after all else the composer asked of the core has come.
let outside_late_ms : Double = 300.0

///|
/// The app over the fixture's core (`new_chat`: its new chat, else its chat), answered through the app's client
/// (round_trip_again, between frames), the calls `late` names (what the words refer to and their sharing unless said)
/// `outside_late_ms` late, with keyboard
/// and mouse in a phone's window or a wide one (`wide`), the chat's page made as nodes or not (`nodes`), what the client
/// sent kept in `heard`, the frames' check of what was kept `looks`; at rest.
fn outside_round_trip(
  heard : Array[String],
  new_chat~ : Bool,
  wide~ : Bool,
  looks~ : Bool,
  nodes~ : Bool,
  late? : Array[String] = ["chat.outsideRefs", "chat.outsideShare"],
  late_ms? : Double = outside_late_ms,
) -> @ui.Tester {
  new_run()
  // (the chat's page made as nodes, its composer too, where `nodes` says so: sfbase's chat_page_nodes)
  if nodes {
    @sfbase.chat_page_nodes.set(true)
  }
  let base = fixture(if new_chat { "home" } else { "chat" })
  let station : Source = {
    ..base,
    call: fn(name, params, done) {
      if late.contains(name) {
        (base.call)(name, params, fn(r) { @ui.later_between_frames(late_ms, "late", fn() { done(r) }) })
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let src = round_trip_again(station, 0.0, heard=fn(h) { heard.push(h) })
  if new_chat {
    @sfbase.open_page(NewChat)
  } else {
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  }
  let (w, h) = if wide { (1280.0, 800.0) } else { (390.0, 844.0) }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=0)
  t.check_looks(looks)
  // (the old chat's page in a phone's window: the gap over a reply streamed in steps as it grows, as it does on main
  // in every test that runs to its answer's end; that page made as nodes, and the wide frame, judged in full)
  if !nodes && !wide {
    t.motion_unjudged(true)
  }
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// How many times the client called `name` of the core, in what it sent (`heard`'s `out` lines).
fn outside_called(heard : Array[String], name : String) -> Int {
  let mut n = 0
  for h in heard {
    guard h.has_prefix("out ") else { continue }
    let j = @json.parse(h.exact_view(start=4).to_owned()) catch { _ => continue }
    if j is Object(m) && m.get("call") is Some(String(c)) && c == name {
      n += 1
    }
  }
  n
}

///|
/// Enter, as a device's host hands it on: told at its moment, the frames it asks for drawn as the host draws them (not
/// Tester::enter's, which takes it as the test's own change, what is kept built anew for it).
fn outside_key_enter(t : @ui.Tester) -> Unit {
  t.key_told(@ui.key_code_enter, 0, t.time())
  t.frames_owed()
}

///|
/// The composer's field pressed: by its hint `hint` where it shows it (the old one's), else where the field is (the one
/// made as nodes says nothing while the cursor is in it, as it is on a computer as its page comes).
fn outside_tap_field(t : @ui.Tester, hint : String) -> Unit {
  match (t.find(hint), composer_field(t)) {
    (None, Some((x, y, w, h))) => t.tap(x + w / 2.0, y + h / 2.0)
    _ => t.tap_text(hint)
  }
}

///|
/// Words `words` typed in the composer (its hint `hint`), the core's reading of them come, then Enter.
fn outside_enter(t : @ui.Tester, hint : String, words : String) -> Unit {
  outside_tap_field(t, hint)
  t.type_text(words)
  t.run_for(@ui.frame_period_default * 2.0)
  outside_key_enter(t)
}

///|
/// Each screen (a phone's window, a wide one), the chat's page made as nodes or not, and each way the frames are
/// checked: `f` given the Tester's every one.
fn outside_each(f : (Bool, Bool, Bool, String) -> Unit raise) -> Unit raise {
  for wide in [false, true] {
    for nodes in [false, true] {
      for looks in [false, true] {
        f(wide, looks, nodes, "wide \{wide}, nodes \{nodes}, looks checked \{looks}")
      }
    }
  }
}

///|
/// On the frames' clock past the fixture's station taking what was sent, its agent answering it and its turn ending,
/// the answer come out in full and what moved for it at rest.
fn outside_to_rest(t : @ui.Tester) -> Unit {
  t.run_for(fix_deliver_ms + fix_answer_ms + fix_turn_end_ms + emit_all_ms() + @ui.move_most_ms)
}

///|
/// What the frames after Enter (or a yes) are given to come to: the station's answer, then two of a host's.
let outside_enter_ms : Double = outside_late_ms + @ui.frame_period_default * 2.0

///|
test "Enter on a new chat, words referring to this workspace's chat: the core's round trip, then sent, the chat at once" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=true, wide~, looks~, nodes~)
    outside_enter(t, "做任何事", "同一个工作区的 @[发布清单]")
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 1, msg=at)
    assert_true(app.nav.top() is Chat(_), msg=at)
    let (_, field, _, _) = t.ime()
    assert_eq(field, "", msg=at)
    t.run_for(@ui.frame_period_default * 2.0)
    assert_eq(outside_called(heard, "chat.send"), 1, msg=at)
    assert_true(t.find("分享对话") is None, msg=at)
    outside_to_rest(t)
    t.assert_idle()
  })
}

///|
test "Enter on a new chat, words referring to another workspace's chat: 分享对话 at once, Enter again shares and sends, the chat at once, nothing left of it" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=true, wide~, looks~, nodes~)
    outside_enter(t, "做任何事", "按 @[季度路线图] 排一下")
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 1, msg=at)
    run_to_outside_rest(t)
    assert_true(t.find("分享对话") is Some(_), msg=at)
    assert_true(app.nav.top() == NewChat, msg=at)
    assert_eq(outside_called(heard, "chat.send"), 0, msg=at)
    outside_key_enter(t)
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideShare"), 1, msg=at)
    assert_true(@sffixture.fix_xshared.contains("s-p1"), msg=at)
    assert_true(app.nav.top() is Chat(_), msg=at)
    t.run_for(@ui.frame_period_default * 2.0)
    assert_eq(outside_called(heard, "chat.send"), 1, msg=at)
    run_to_outside_rest(t)
    assert_true(t.find("分享对话") is None, msg=at)
    assert_true(!@sf.presented_drawn(), msg=at)
    outside_to_rest(t)
    t.assert_idle()
  })
}

///|
test "Enter on a chat, words referring to this workspace's chat: the core's round trip, then sent at once" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=false, wide~, looks~, nodes~)
    outside_enter(t, "发消息", "同一个工作区的 @[发布清单]")
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 1, msg=at)
    assert_eq(outside_called(heard, "chat.send"), 1, msg=at)
    let (_, field, _, _) = t.ime()
    assert_eq(field, "", msg=at)
    assert_true(t.find("分享对话") is None, msg=at)
    outside_to_rest(t)
    t.assert_idle()
  })
}

///|
test "Enter on a chat, words referring to another workspace's chat: 分享对话 at once, Enter again shares and sends at once" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=false, wide~, looks~, nodes~)
    outside_enter(t, "发消息", "先看 @[季度路线图] 再定")
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 1, msg=at)
    run_to_outside_rest(t)
    assert_true(t.find("分享对话") is Some(_), msg=at)
    assert_eq(outside_called(heard, "chat.send"), 0, msg=at)
    outside_key_enter(t)
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideShare"), 1, msg=at)
    assert_eq(outside_called(heard, "chat.send"), 1, msg=at)
    let (_, field, _, _) = t.ime()
    assert_eq(field, "", msg=at)
    run_to_outside_rest(t)
    assert_true(t.find("分享对话") is None, msg=at)
    assert_true(!@sf.presented_drawn(), msg=at)
    outside_to_rest(t)
    t.assert_idle()
  })
}

///|
/// How late the core answers what is asked of it where nothing is to wait for it: seconds, as a core busy with a
/// workspace of thousands of chats was seen to be (2026-11-17: 「new chat 发消息任何时候都应该立即发出去」).
let outside_busy_ms : Double = 3000.0

///|
test "Enter on a new chat, a chat of this workspace picked in the `@` menu: the chat and its send at once, the core not asked, however late it would answer" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=true, wide~, looks~, nodes~, late_ms=outside_busy_ms)
    outside_tap_field(t, "做任何事")
    t.type_text("看 @首页")
    t.run_for(@ui.frame_period_default * 2.0)
    t.tap_text("首页的列表改成按天分组")
    // (the menu gone as the person goes on writing)
    t.run_for(@ui.move_most_ms)
    t.type_text(" 吧")
    t.run_for(@ui.frame_period_default * 2.0)
    outside_key_enter(t)
    t.run_for(@ui.frame_period_default * 2.0)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 0, msg=at)
    assert_true(app.nav.top() is Chat(_), msg=at)
    let (_, field, _, _) = t.ime()
    assert_eq(field, "", msg=at)
    assert_eq(outside_called(heard, "chat.send"), 1, msg=at)
    outside_to_rest(t)
    t.assert_idle()
  })
}

///|
test "Enter on a new chat, a chat of another workspace picked in the `@` menu: the core asked, 分享对话 once it answers, nothing sent before" {
  outside_each(fn(wide, looks, nodes, at) raise {
    let heard : Array[String] = []
    let t = outside_round_trip(heard, new_chat=true, wide~, looks~, nodes~)
    outside_tap_field(t, "做任何事")
    t.type_text("@路线")
    t.run_for(@ui.frame_period_default * 2.0)
    t.tap_text("季度路线图")
    t.run_for(@ui.move_most_ms)
    outside_key_enter(t)
    t.run_for(outside_enter_ms)
    assert_eq(outside_called(heard, "chat.outsideRefs"), 1, msg=at)
    run_to_outside_rest(t)
    assert_true(t.find("分享对话") is Some(_), msg=at)
    assert_true(app.nav.top() == NewChat, msg=at)
    assert_eq(outside_called(heard, "chat.send"), 0, msg=at)
  })
}
