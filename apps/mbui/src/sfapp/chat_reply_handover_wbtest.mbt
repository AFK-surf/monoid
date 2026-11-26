// What is sent from here under a pending card stays drawn once, whichever way the core hands it over, and the list's
// check for what was sent and not seen (chat_body_node's sent_watched) tells no fault for any of them.

///|
fn rv_send(t : @ui.Tester) -> Unit raise {
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("no composer field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text(rk_reply)
  t.key(@ui.key_code_enter)
}

///|
fn rv_card_resolved() -> Json {
  {
    "path": ["messages"],
    "key": ["seq", "outgoing"],
    "patch": [337, Json::null()],
    "ops": [
      { "path": ["asked"], "set": false },
      { "path": ["decision"], "set": { "resolved": true, "text": Json::string(rk_replied) } },
    ],
  }
}

///|
fn rv_m338(outgoing : Bool) -> Json {
  let extra : Map[String, Json] = { "ts": "1795426459.008000", "mine": true, "said": true }
  if outgoing {
    extra["outgoing"] = "out-1"
  }
  @sffixture.msg(338, "person", @sffixture.by_person("左子健"), rk_reply, "刚刚", extra)
}

///|
/// The reply drawn once after `steps` (each: how long after the one before, the core's change), past the list's
/// check for what was sent and not seen.
fn rv_drawn_once(name : String, steps : Array[(Double, Array[Json])]) -> Unit raise {
  let (t, held) = rk_open("t1")
  rv_send(t)
  for s in steps {
    t.run_for(s.0)
    rk_change(held, s.1)
    t.draw()
  }
  t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
  let seen = rk_reply_drawn()
  assert_eq(seen.length(), 1, msg="\{name}: expected reply drawn once, got \{seen.length()}")
  assert_true(seen[0].alpha > 0.99 && seen[0].h > 10.0, msg="\{name}: expected full alpha and height")
  t.run_for(rv_past_check_ms)
}

///|
let rv_past_check_ms : Double = 5000.0

///|
test "reply under a pending card stays drawn whichever way the core hands it over" {
  let agent_q : Json = { "path": ["agents"], "set": Json::array([rk_agent_json("queued", "t1")]) }
  let agent_r : Json = { "path": ["agents"], "set": Json::array([rk_agent_json("running", "t2")]) }
  let out0 : Json = { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::null())]) }
  let out338 : Json = { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::number(338.0))]) }
  let clear : Json = { "path": ["outbox"], "set": Json::array([]) }
  let put : Json = { "path": ["messages"], "key": ["seq", "outgoing"], "put": rv_m338(true) }
  let put_bare : Json = { "path": ["messages"], "key": ["seq", "outgoing"], "put": rv_m338(false) }
  // (the POST answered first, then the message with the outbox let go in one change: the Windows app's 92 ms and 141 ms)
  rv_drawn_once("answer first", [
    (1.0, [out0, agent_q]),
    (91.0, [out338]),
    (49.0, [put, clear, rv_card_resolved(), agent_r]),
  ])
  // (the message come before the POST's answer)
  rv_drawn_once("message first", [(1.0, [out0, agent_q]), (5.0, [put, clear, rv_card_resolved(), agent_r])])
  // (the message come with no outbox entry it was taken from, by its own key, the outbox let go after)
  rv_drawn_once("message by its own key", [
    (1.0, [out0, agent_q]),
    (5.0, [put_bare, rv_card_resolved(), agent_r]),
    (111.0, [clear]),
  ])
}

///|
/// The Windows app's POST answered 92 ms after it was sent (1 ms of it the core's echo).
let rv_post_answered_ms : Double = 91.0

///|
/// The Windows app's message come 141 ms after it was sent.
let rv_message_after_ms : Double = 49.0

///|
/// Past a chat switch: the chat let go of parks, the one opened comes in, and the core's change reaches it.
let rv_switch_past_ms : Double = 500.0

///|
test "reply under a pending card delivered while parked stays drawn after waking at unread line" {
  let other : ChatRef = { station: "ws1/st1", session: "s-c2", title: "首页的列表改成按天分组", station_name: "Willow" }
  let (t, held) = rk_open("t1")
  // Park s-c1 by switching to another chat.
  @ui.view_tree().unwrap().event(t.time(), fn() { open_chat(other) })
  t.run_for(rv_switch_past_ms)
  // Deliver an unread line on the pending card while s-c1 is parked so waking stands at "line" (s.x != infinity).
  rk_change(held, [
    { "path": ["unreadLine"], "set": Json::number(337.0) },
    { "path": ["unread"], "set": Json::number(1.0) },
    {
      "path": ["asks"],
      "set": [{ "seq": 337, "card": true, "mine": true, "text": "请选择方案" }],
    },
    { "path": ["askClear"], "set": Json::boolean(true) },
  ])
  t.run_for(rv_switch_past_ms)
  // Wake s-c1: chat_body_node's staged_keys will read scroll.follows_now() -> at_foot_now -> laid.get() while keys
  // is mid-update (RECURSED_CHECK).
  @ui.view_tree().unwrap().event(t.time(), fn() { open_chat(rk_ref) })
  t.run_for(rv_switch_past_ms)
  let before_count = rk_chat_list().unwrap().count
  let agent_q : Json = { "path": ["agents"], "set": Json::array([rk_agent_json("queued", "t1")]) }
  let agent_r : Json = { "path": ["agents"], "set": Json::array([rk_agent_json("running", "t2")]) }
  let out0 : Json = { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::null())]) }
  let out338 : Json = { "path": ["outbox"], "set": Json::array([rk_out1_json(Json::number(338.0))]) }
  let clear : Json = { "path": ["outbox"], "set": Json::array([]) }
  let asks_clear : Json = { "path": ["asks"], "set": Json::array([]) }
  let ask_clear_off : Json = { "path": ["askClear"], "set": Json::boolean(false) }
  let put : Json = { "path": ["messages"], "key": ["seq", "outgoing"], "put": rv_m338(true) }
  rv_send(t)
  // (the POST answered first, then the message with the outbox let go in one change, as the first test's "answer
  // first": the Windows app's 92 ms and 141 ms)
  let steps : Array[(Double, Array[Json])] = [
    (rk_core_echo_ms, [out0, agent_q, asks_clear, ask_clear_off]),
    (rv_post_answered_ms, [out338]),
    (rv_message_after_ms, [put, clear, rv_card_resolved(), agent_r]),
  ]
  for s in steps {
    t.run_for(s.0)
    rk_change(held, s.1)
    t.draw()
  }
  t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
  let seen = rk_reply_drawn()
  assert_eq(seen.length(), 1, msg="parked-wake: expected reply drawn once, got \{seen.length()}")
  assert_true(seen[0].alpha > 0.99 && seen[0].h > 10.0, msg="parked-wake: expected full alpha and height")
  assert_eq(rk_chat_list().unwrap().count, before_count + 2, msg="parked-wake: expected reply + working row in list")
  t.run_for(rv_past_check_ms)
}

///|
/// An outbox entry of the reply (rk_out1_json's words) by its own id, failed and held: what the core keeps of words
/// sent while their station cannot be reached (views/calls.ts's `!stations.reachable`).
fn rv_out_held(id : String) -> Json {
  {
    "id": Json::string(id),
    "seq": Json::null(),
    "text": Json::string(rk_reply),
    "state": "failed",
    "held": true,
    "createdAt": 1795426459000.0,
    "joined": false,
    "followed": false,
    "time": { "ago": "刚刚", "full": "" },
  }
}

///|
/// The faults told while `go` runs from a chat opened with `chat.send` answered `sent`, after the reply is sent there
/// (each fault told rather than stopped at).
fn rv_faults_sending(sent : Result[Json, Json], go : (@ui.Tester, RkHeld) -> Unit raise) -> Array[String] raise {
  let told : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { told.push(said) })
  defer {
    @view.faults_stop.val = true
    @view.fault_told.val = None
  }
  let (t, held) = rk_open("t1", sent~)
  rv_send(t)
  go(t, held)
  told
}

///|
test "words sent while their station cannot be reached are in the outbox at once and no fault says they went unseen" {
  let told = rv_faults_sending(Err({ "code": "mesh", "message": "waiting station" }), (t, held) => {
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([rv_out_held("out-offline-1")]) }])
    t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
    let seen = rk_reply_drawn()
    assert_eq(seen.length(), 1, msg="expected the outbox's reply drawn once, got \{seen.length()}")
    t.run_for(rv_past_check_ms)
    assert_eq(rk_reply_drawn().length(), 1, msg="expected the outbox's reply still drawn")
  })
  assert_eq(told, [])
}

///|
test "words the core refused go back to the composer and no fault says they went unseen" {
  let told = rv_faults_sending(Err({ "code": "invalid_params", "message": "refused" }), (t, _) => {
    t.run_for(rv_past_check_ms)
  })
  assert_eq(told, [])
}

///|
test "words kept in the outbox that never show in the list are still told as unseen, an older entry or one deleted before not taken for them" {
  // (each fault is told once a run (@view.fault): the steps before the one send that never shows are those that must
  // not hide it; that they tell nothing themselves is the next test's)
  let told = rv_faults_sending(Err({ "code": "mesh", "message": "waiting station" }), (t, held) => {
    // (a send before, in the outbox, deleted by the viewer and gone from the core's: never what hides a later one)
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([rv_out_held("out-offline-1")]) }])
    t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
    unsent_press(t, "删除")
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([]) }])
    t.run_for(rv_past_check_ms)
    // (an older entry there as the next words are sent, none of theirs ever coming: the older not taken for them, and
    // deleted meanwhile, not what they were)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([rv_out_held("out-older")]) }])
    t.run_for(@ui.move_most_ms)
    rv_send(t)
    t.run_for(@ui.move_most_ms)
    unsent_press(t, "删除")
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([]) }])
    t.run_for(rv_past_check_ms)
  })
  assert_true(told.iter().any(fn(s) { s.has_prefix("chat sent unseen:") }), msg="told: \{told.join(" | ")}")
}

///|
test "words kept in the outbox the viewer deletes before they are looked for are not told as unseen" {
  let told = rv_faults_sending(Err({ "code": "mesh", "message": "waiting station" }), (t, held) => {
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([rv_out_held("out-offline-1")]) }])
    t.run_for(@ui.move_most_ms + rk_settle_extra_ms)
    unsent_press(t, "删除")
    t.run_for(rk_core_echo_ms)
    rk_change(held, [{ "path": ["outbox"], "set": Json::array([]) }])
    t.run_for(rv_past_check_ms)
    assert_eq(rk_reply_drawn().length(), 0, msg="expected the deleted reply gone")
  })
  assert_eq(told, [])
}
