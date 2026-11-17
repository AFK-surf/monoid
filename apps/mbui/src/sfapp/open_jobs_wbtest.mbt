// What is left up long on 小屏 (sfdesk/open_jobs.mbt in 待处理, attention.mbt's open_attention_panel): not on Home's
// list, which opens on the chats; in 待处理's sheet the top bar's bell opens, under what waits on the viewer, the
// viewer's own first and the others' folded under 其他运行中 · N till pressed. A row leads where it is (a simulator its
// screen, a service its page over Home, a task its chat; one of no chat nowhere), its stop takes it out of the list at
// once (back where that could not be done); the bell lit by the viewer's own alone.

///|
/// Home on 小屏 (390 by 844, touch) over the home fixture's chats, with `long` what is left up long; the calls asked of
/// the core into `calls`, each answered by `answer` (none: not answered).
fn open_jobs_tester(
  long : Json,
  calls? : Array[(String, Json)] = [],
  answers? : Array[(Result[Json, Json]) -> Unit] = [],
  w? : Double = 390.0,
  words? : Double = 1.0,
) -> @ui.Tester {
  new_run()
  let base = fixture("home")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      if name == "longJobs" {
        { ..got, value: Some(long) }
      } else {
        got
      }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      answers.push(done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=844.0, platform=2)
  if words != 1.0 {
    t.set_font_scale(words)
  }
  t
}

///|
/// What is left up long in a workspace others are members of: the viewer's service, the others' (a colleague's service
/// and task, a shared simulator, a colleague's view of a screen), as the core sends them.
fn open_jobs_shared() -> Json {
  let mine = @sffixture.long_job()
  let theirs = match @sffixture.long_job() {
    Object(m) => m.copy()
    _ => {}
  }
  theirs["id"] = Json::string("j-ana")
  theirs["name"] = Json::string("ana-preview")
  theirs["whereText"] = Json::string("Willow · Ana 的发布")
  theirs["chat"] = { "id": "s-ana", "title": "Ana 的发布", "archived": false }
  let task = match @sffixture.long_job() {
    Object(m) => m.copy()
    _ => {}
  }
  task["id"] = Json::string("j-task")
  task["name"] = Json::string("e2e soak")
  task["service"] = Json::boolean(false)
  task["port"] = Json::null()
  task["whereText"] = Json::string("Willow · 不属于任何对话")
  task.remove("chat")
  {
    "groups": [{ "key": "services", "head": "长时间运行的网页服务 · 1", "jobs": [mine] }],
    "lit": true,
    "ids": ["ws1/st1/j-web"],
    "otherGroups": [
      { "key": "services", "head": "长时间运行的网页服务 · 1", "jobs": [Json::object(theirs)] },
      { "key": "jobs", "head": "长时间运行的后台任务 · 1", "jobs": [Json::object(task)] },
      {
        "key": "simulators",
        "head": "长时间开着的模拟器 · 1",
        "jobs": [
          @sffixture.long_screen("screen:simulator:A", "Demo iPhone · iOS 27.2", "Willow · iOS 模拟器", "5 小时", "screen.close", "simulator:A", "", "关闭"),
        ],
      },
      {
        "key": "views",
        "head": "长时间开着的远程连接 · 1",
        "jobs": [@sffixture.long_screen("view:desktop/v1", "Willow 的桌面", "Willow · Ana · iPhone", "2 小时", "screen.endView", "desktop", "v1", "断开")],
      },
    ],
    "otherCount": 4,
    "otherText": "其他运行中 · 4",
  }
}

///|
/// 待处理's sheet opened from Home's top bar, at rest.
fn open_bell(t : @ui.Tester) -> Unit raise {
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="待处理") is Some(b) else { fail("no bell") }
  let (x, y, w, h) = b.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
test "小屏 Home: what is left up long is not on the list, which opens on the chats" {
  let t = open_jobs_tester(open_jobs_shared())
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("长时间运行的网页服务") is None, msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("Willow · 整理发布清单 · 3 小时") is None)
  assert_true(t.find("其他运行中") is None)
}

///|
test "小屏 the bell: lit by the viewer's own not looked at yet, never by the others' alone" {
  fresh_app()
  guard workspace_in_view(fixture("home")).0 is Some(w) else { fail("no workspace") }
  let others_only = match open_jobs_shared() {
    Object(m) => {
      let o = m.copy()
      o["groups"] = Json::array([])
      o["lit"] = Json::boolean(false)
      o["ids"] = Json::array([])
      Json::object(o)
    }
    _ => Json::null()
  }
  // (no chat waiting on the viewer and no station in trouble: what is left up long alone lights it or not)
  let lit_of = fn(long : Json) {
    let base = fixture("home")
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let got = base.topic(name, params).get().snapshot()
        if name == "longJobs" {
          { ..got, value: Some(long) }
        } else if name == "workspaceMarks" {
          { ..got, value: Some({ "workspaces": {} }) }
        } else {
          got
        }
      },
    }
    @signals.untracked(fn() { @sfdesk.bell_lit(src, w) })
  }
  assert_true(lit_of(open_jobs_shared()))
  assert_false(lit_of(others_only))
}

///|
test "小屏 the bell's sheet: the viewer's own kept as looked at as it opens; what waits on them first, theirs next, the others' folded at the foot" {
  let calls = []
  let t = open_jobs_tester(open_jobs_shared(), calls~)
  open_bell(t)
  let seen = calls.filter(fn(c) { c.0 == "prefs.set" && field(Some(c.1), "jobsSeen") is Some(_) })
  assert_eq(seen.length(), 1)
  assert_eq(field(field(Some(seen[0].1), "jobsSeen"), "ws1"), Some(Json::array([Json::string("ws1/st1/j-web")])))
  // (the viewer's own, then the others' fold, folded)
  guard t.find("Willow · 整理发布清单 · 3 小时") is Some((_, own_y)) else { fail(t.words().map(fn(w) { w.0 }).join("|")) }
  guard t.find("其他运行中 · 4") is Some((_, fold_y)) else { fail("no fold") }
  assert_true(fold_y > own_y)
  assert_true(t.find("ana-preview") is None)
  assert_true(t.find("Demo iPhone") is None)
  assert_eq(t.audit(), [])
  // pressed: the others' under it, each where it leads, its stop's word
  t.tap_text("其他运行中 · 4")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("ana-preview") is Some(_))
  assert_true(t.find("Demo iPhone · iOS 27.2") is Some(_))
  assert_true(t.query(Button, label="关闭 Demo iPhone · iOS 27.2") is Some(_))
  assert_true(t.query(Button, label="断开 Willow 的桌面") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "小屏 the bell's sheet: a simulator leads to its screen, a service to its page over Home, a task of no chat nowhere" {
  let t = open_jobs_tester(open_jobs_shared())
  open_bell(t)
  t.tap_text("其他运行中 · 4")
  t.run_for(@ui.move_most_ms)
  t.tap_text("Demo iPhone · iOS 27.2")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Screen(s) => assert_eq((s.station, s.screen), ("ws1/st1", "simulator:A"))
    _ => fail("no screen")
  }
  let t = open_jobs_tester(open_jobs_shared())
  open_bell(t)
  t.tap_text("Willow · 整理发布清单 · 3 小时")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Service(station, id) => assert_eq((station, id), ("ws1/st1", "j-web"))
    _ => fail("no service's page")
  }
  // (over Home: back comes to Home)
  assert_eq(app.nav.depth(), 2)
  let t = open_jobs_tester(open_jobs_shared())
  open_bell(t)
  t.tap_text("其他运行中 · 4")
  t.run_for(@ui.move_most_ms)
  // (a task in no chat: no link, pressing it changes nothing)
  assert_true(t.query(Link, label="e2e soak") is None)
  t.tap_text("e2e soak")
  t.run_for(@ui.move_most_ms)
  assert_eq(app.nav.depth(), 1)
  assert_true(t.find("e2e soak") is Some(_), msg="the sheet closed")
}

///|
test "小屏 the bell's sheet: a task run for a chat leads to that chat, on its own station" {
  let job = match @sffixture.long_job() {
    Object(m) => m.copy()
    _ => {}
  }
  job["service"] = Json::boolean(false)
  job["chat"] = { "id": "s-elsewhere", "title": "修登录", "archived": false, "station": "ws1/st2" }
  job["whereText"] = Json::string("Studio · 修登录 · 来自 Willow")
  let t = open_jobs_tester({ "groups": [{ "key": "jobs", "head": "长时间运行的后台任务 · 1", "jobs": [Json::object(job)] }], "lit": false, "ids": [] })
  open_bell(t)
  t.tap_text("Studio · 修登录 · 来自 Willow · 3 小时")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq((r.station, r.session, r.title), ("ws1/st2", "s-elsewhere", "修登录"))
    _ => fail("no chat")
  }
}

///|
test "小屏 the bell's sheet: a stop takes its row out at once, back where it could not be done" {
  let calls = []
  let answers = []
  let t = open_jobs_tester(open_jobs_shared(), calls~, answers~)
  open_bell(t)
  t.tap_text("其他运行中 · 4")
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="关闭 Demo iPhone · iOS 27.2") is Some(s) else { fail("no stop") }
  let (x, y, w, h) = s.rect
  calls.clear()
  answers.clear()
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.map(fn(c) { c.0 }), ["screen.close"])
  assert_true(t.find("Demo iPhone · iOS 27.2") is None, msg="still listed")
  assert_true(t.find("其他运行中 · 3") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_eq(app.nav.depth(), 1)
  // (not done: listed again)
  answers[0](Err({ "code": "http_500", "message": "no" }))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Demo iPhone · iOS 27.2") is Some(_))
  assert_true(t.find("其他运行中 · 4") is Some(_))
}

///|
test "小屏 the bell's sheet: a group of five, three shown, the rest under 还有 2 个 until it is pressed" {
  let jobs : Array[Json] = []
  for i in 0..<5 {
    jobs.push(
      @sffixture.long_screen("screen:simulator:" + i.to_string(), "模拟器 " + i.to_string(), "Willow · iOS 模拟器", "5 小时", "screen.close", "simulator:" + i.to_string(), "", "关闭"),
    )
  }
  let t = open_jobs_tester({ "groups": [{ "key": "simulators", "head": "长时间开着的模拟器 · 5", "jobs": Json::array(jobs) }], "lit": true })
  open_bell(t)
  assert_true(t.find("模拟器 2") is Some(_))
  assert_true(t.find("模拟器 3") is None)
  t.tap_text("还有 2 个")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("模拟器 4") is Some(_))
  assert_true(t.find("还有 2 个") is None)
}

///|
test "小屏 the bell's sheet at 320 wide, words at 1.3: a long name cut short on its line, its stop whole at its end, nothing faulted" {
  let job = match @sffixture.long_job() {
    Object(m) => m.copy()
    _ => {}
  }
  job["name"] = Json::string("CFT local stack for mail mode screenshots and the rest of a long name")
  job["whereText"] = Json::string("tokyo-mac-studio-0-vm · Review 邮件权限 PR #5033 · and more of where it is")
  let long = match open_jobs_shared() {
    Object(m) => {
      let o = m.copy()
      o["groups"] = [{ "key": "services", "head": "长时间运行的网页服务 · 1", "jobs": [Json::object(job)] }]
      Json::object(o)
    }
    _ => Json::null()
  }
  let t = open_jobs_tester(long, w=320.0, words=1.3)
  open_bell(t)
  t.tap_text("其他运行中 · 4")
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="停止「CFT local stack for mail mode screenshots and the rest of a long name」") is Some(stop) else {
    fail("no stop")
  }
  let (sx, sy, sw, sh) = stop.rect
  assert_eq(t.audit(), [])
  assert_true(sx + sw <= 320.0, msg="its stop at \{sx},\{sy} \{sw}×\{sh}; " + t.sources_at(sx + sw / 2.0, sy + sh / 2.0))
}
