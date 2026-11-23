// Regression tests for:
// 1. User reply staying visible after outbox/messages overlap + scroll remount (chat_body_keyed owner clobber).
// 2. Agent working row staying visible when replying after an ending turn (with lastTurn.id present or empty).

///|
fn init {
  @ui.host_image_bytes_known([("src/sfapp/chat_reply_kept_wbtest.mbt", 513184)])
}

///|
let rk_reply : String = "发布前再看一眼签名"

///|
let rk_settle_extra_ms : Double = 300.0

///|
let rk_wheel_step_ms : Double = 50.0

///|
let rk_core_echo_ms : Double = 1.0

///|
let rk_post_ack_ms : Double = 111.0

///|
let rk_overlap_gap_ms : Double = 17.0

///|
let rk_scroll_step_ms : Double = 30.0

///|
let rk_replied : String = "你 回复了"

///|
let rk_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
fn rk_is_chat(name : String, params : Map[String, Json]) -> Bool {
  name == "chat" && text(Some(Json::object(params)), "session") == rk_ref.session
}

///|
fn rk_agent_json(status : String, last_turn_id : String) -> Json {
  let last_turn : Map[String, Json] = Map([])
  if last_turn_id != "" {
    last_turn["id"] = Json::string(last_turn_id)
  }
  {
    "key": "s-c1",
    "name": "Claude",
    "provider": "anthropic",
    "model": "claude",
    "status": Json::string(status),
    "session": {
      "key": "s-c1",
      "status": Json::string(status),
      "lastTurn": Json::object(last_turn),
    },
  }
}

///|
fn rk_m337_json(resolved : Bool) -> Json {
  let paras : Array[Json] = Array::makei(14, fn(i) {
    Json::array([Json::string("p"), Json::array([Json::string("第 \{i + 1} 段分析内容：检查圆角、间距与视觉层级。")])])
  })
  let text_body = Array::makei(14, fn(i) { "第 \{i + 1} 段分析内容：检查圆角、间距与视觉层级。" }).join("\n\n")
  let files : Array[Json] = Array::makei(10, fn(i) {
    {
      "name": Json::string("shot\{i}.png"),
      "path": Json::string("/w/uploads/shot\{i}.png"),
      "size": 120,
      "width": 1200,
      "height": 800,
      "owner": "s-c1",
    }
  })
  let options : Json = [
    { "label": "改成大圆角", "detail": "统一调整为 18pt 圆角" },
    { "label": "保持现状", "detail": "维持当前 10pt 圆角", "recommended": true },
  ]
  let decision : Json = if resolved {
    { "resolved": true, "text": Json::string(rk_replied) }
  } else {
    { "resolved": false }
  }
  @sffixture.msg(
    337,
    "agent",
    @sffixture.by_agent("anthropic", "claude", "s-c1"),
    text_body,
    "刚刚",
    {
      "ts": "1795426440.000000",
      "md": Json::array(paras),
      "attachments": Json::array(files),
      "ending": "need_help",
      "said": true,
      "asked": !resolved,
      "card": {
        "type": "options",
        "assignee": "zuozijian@cue.surf",
        "assigneeText": "等 左子健 决定",
        "options": options,
      },
      "decision": decision,
    },
  )
}

///|
fn rk_m338_json() -> Json {
  @sffixture.msg(
    338,
    "person",
    @sffixture.by_person("左子健"),
    rk_reply,
    "刚刚",
    {
      "ts": "1795426459.008000",
      "mine": true,
      "said": true,
      "outgoing": "out-1",
    },
  )
}

///|
fn rk_out1_json(seq : Json) -> Json {
  {
    "id": "out-1",
    "seq": seq,
    "text": Json::string(rk_reply),
    "state": "sending",
    "createdAt": 1795426459000.0,
    "joined": false,
    "followed": false,
    "time": { "ago": "刚刚", "full": "" },
  }
}

///|
priv struct RkHeld {
  mut value : Json?
  mut version : Int
  changes : @signals.Signal[Int]
  mut ops : Array[Json]?
}

///|
fn rk_change(h : RkHeld, ops : Array[Json]) -> Unit {
  guard h.value is Some(v) else { return }
  h.value = Some(@core.apply_delta(v, ops))
  h.ops = Some(ops)
  h.version += 1
  h.changes.set(h.version)
}

///|
fn rk_open(last_turn_id : String) -> (@ui.Tester, RkHeld) {
  new_run()
  @sf.presenters_reset()
  let base = fixture("chat")
  let held : RkHeld = { value: None, version: 0, changes: @signals.signal(0), ops: None }
  let inner : Source = {
    ..base,
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard rk_is_chat(name, params) else { return t }
      held.changes.get() |> ignore
      if held.value is None {
        match t.value {
          Some(Object(o)) => {
            let copy = o.copy()
            copy["agents"] = Json::array([rk_agent_json("running", last_turn_id)])
            copy["outbox"] = Json::array([])
            held.value = Some(Json::object(copy))
          }
          _ => held.value = t.value
        }
      }
      match held.value {
        Some(v) => { value: Some(v), error: None, version: 1 + held.version }
        None => t
      }
    },
    call: fn(name, params, done) {
      match name {
        "chat.send" => done(Ok({ "n": 338 }))
        "session.warm" | "client.focus" | "chat.place" => done(Ok(Json::object({})))
        _ => (base.call)(name, params, done)
      }
    },
  }
  let src = round_trip_again(inner, 0.0, delta_of=fn(name, params) {
    if rk_is_chat(name, params) {
      held.ops
    } else {
      None
    }
  })
  open_chat(rk_ref)
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w=1280.0,
    h=800.0,
    platform=0,
    scale=2.0,
    begun=fn() { @sfbase.window_tall.val = 800.0 },
  )
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  nav_rested(t)
  files_page_over(t, 1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  rk_change(held, [
    { "path": ["messages"], "key": ["seq", "outgoing"], "put": rk_m337_json(false) },
    { "path": ["agents"], "set": Json::array([rk_agent_json("idle", last_turn_id)]) },
  ])
  t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
  for _ in 0..<25 {
    t.wheel(700.0, 400.0, 600.0)
    t.run_for(rk_wheel_step_ms)
  }
  t.run_for(@ui.move_most_ms)
  (t, held)
}

///|
fn rk_chat_list() -> @view.ListSeen? {
  let tree = @ui.view_tree().unwrap()
  let mut best : @view.ListSeen? = None
  for l in tree.lists_seen() {
    if l.rows.iter().any(fn(r) { r.2.0 > 260.0 }) {
      best = Some(l)
    }
  }
  best
}

///|
fn rk_reply_drawn() -> Array[@view.Drawn] {
  @ui.view_tree()
  .unwrap()
  .drawn()
  .filter(fn(d) { d.words.contains(rk_reply) && d.x > 260.0 && d.alpha > 0.01 })
}

///|
test "reply stays drawn once after outbox/messages overlap and scroll remount" {
  let (t, held) = rk_open("")
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("no composer field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text(rk_reply)
  t.key(@ui.key_code_enter)
  t.run_for(rk_core_echo_ms)
  rk_change(held, [
    { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::null())]) },
    { "path": ["agents"], "set": Json::array([rk_agent_json("queued", "")]) },
    {
      "path": ["messages"],
      "key": ["seq", "outgoing"],
      "patch": [337, Json::null()],
      "ops": [
        { "path": ["asked"], "set": false },
        { "path": ["decision"], "set": { "resolved": true, "text": Json::string(rk_replied) } },
      ],
    },
  ])
  t.draw()
  t.run_for(rk_post_ack_ms)
  rk_change(held, [{ "path": ["outbox"], "set": Json::array([rk_out1_json(Json::number(338.0))]) }])
  t.draw()
  t.run_for(rk_core_echo_ms)
  // Same-frame overlap: m338 enters messages while out-1 is still in outbox
  rk_change(held, [{ "path": ["messages"], "key": ["seq", "outgoing"], "put": rk_m338_json() }])
  t.draw()
  t.run_for(rk_overlap_gap_ms)
  // Next frame: outbox clears
  rk_change(held, [{ "path": ["outbox"], "set": Json::array([]) }])
  t.draw()
  t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
  // Scroll far up and back to bottom to force slot unmount + remount
  for _ in 0..<15 {
    t.wheel(700.0, 400.0, -800.0)
    t.run_for(rk_scroll_step_ms)
  }
  for _ in 0..<25 {
    t.wheel(700.0, 400.0, 800.0)
    t.run_for(rk_scroll_step_ms)
  }
  t.run_for(@ui.move_most_ms)
  let seen = rk_reply_drawn()
  assert_eq(seen.length(), 1, msg="expected reply drawn once after remount, got \{seen.length()}")
  assert_true(seen[0].alpha > 0.99 && seen[0].h > 10.0, msg="expected full alpha and non-zero height")
}

///|
test "agent working row stays visible when replying after an ending turn (with or without lastTurn.id)" {
  for turn_id in ["t1", ""] {
    let (t, held) = rk_open(turn_id)
    let before_count = rk_chat_list().unwrap().count
    guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("no composer field") }
    t.tap(fx + fw / 2.0, fy + fh / 2.0)
    t.type_text(rk_reply)
    t.key(@ui.key_code_enter)
    // t=0ms: reply row + optimistic working row (before_count + 2)
    let c0 = rk_chat_list().unwrap().count
    assert_eq(c0, before_count + 2, msg="turn=\{turn_id} t=0ms: expected reply + working row")
    t.run_for(rk_core_echo_ms)
    // t=1ms: core sends outbox + agent queued with unchanged lastTurn
    rk_change(held, [
      { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::null())]) },
      { "path": ["agents"], "set": Json::array([rk_agent_json("queued", turn_id)]) },
      {
        "path": ["messages"],
        "key": ["seq", "outgoing"],
        "patch": [337, Json::null()],
        "ops": [
          { "path": ["asked"], "set": false },
          { "path": ["decision"], "set": { "resolved": true, "text": Json::string(rk_replied) } },
        ],
      },
    ])
    t.draw()
    let c1 = rk_chat_list().unwrap().count
    assert_eq(c1, before_count + 2, msg="turn=\{turn_id} t=1ms: working row vanished when status became queued")
    t.run_for(@ui.move_most_ms)
    let c500 = rk_chat_list().unwrap().count
    assert_eq(c500, before_count + 2, msg="turn=\{turn_id} t=500ms: working row vanished")
  }
}
