// A login card waiting for the viewer, told in the app as it comes while they are elsewhere (sfbase's login_asks.mbt):
// a toast naming its chat, 去登录 opening it; none for the chat on top, each told once.

///|
/// The fixture's app on chat `on`, the core's 待处理 holding a login card of chat s-c2 (部署) for the viewer.
fn login_asks_run(on : String) -> @ui.Tester {
  new_run()
  let base = fixture("chat")
  let item : Json = {
    "kind": "wait",
    "workspace": "ws1",
    "station": "ws1/st1",
    "stationName": "Willow",
    "session": "s-c2",
    "title": "部署",
    "what": "要你登录 gh",
    "login": "login-9",
    // (the fixture's now is 0)
    "loginEnds": 750000,
    "at": 0,
  }
  let marks : Json = { "workspaces": { "ws1": { "items": [item] } } }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      match name {
        "workspaceMarks" => { value: Some(marks), error: None, version: 1 }
        _ => base.topic(name, params).get().snapshot()
      }
    },
  }
  open_chat({ station: "ws1/st1", session: on, title: "", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a login card waiting for the viewer in another chat: told in a toast, 去登录 opening that chat; once" {
  let t = login_asks_run("s-c1")
  assert_eq(@sfbase.toast_words(), "「部署」需要你登录 · 剩 13 分钟")
  t.tap_text("去登录")
  t.run_for(@ui.move_most_ms)
  let opened = match app.nav.top() {
    Chat(r) => r.station == "ws1/st1" && r.session == "s-c2"
    _ => false
  }
  assert_true(opened, msg="its chat opened")
}

///|
test "a login card waiting in the chat on top: no toast, the card is there" {
  let _ = login_asks_run("s-c2")
  assert_eq(@sfbase.toast_words(), "")
}

///|
test "待处理 lists a login waiting for the viewer first, with how long is left of it" {
  let t = tester("home-attention-login")
  t.frame()
  let (x, y, w, h) = named_at(t, "待处理").unwrap()
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t.frame()
  let (_, login_y) = t.find("需要你登录 gh · 剩 13 分钟").unwrap()
  let (_, other_y) = t.find("选一个发布的时间").unwrap()
  assert_true(login_y < other_y, msg="the login first")
}
