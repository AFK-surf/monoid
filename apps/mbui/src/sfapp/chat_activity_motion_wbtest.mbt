// Anti-Silent-Snap regression tests for Chat Activity motion (never listed in motion_counted or any exemption table):
// 1. idle -> queued (started=true, since=None) -> running (since=Some) on Small (390x844, platform=2):
//    above message slides up smoothly across frames without 1-frame snap, and elapsed clock fades in smoothly.
// 2. CoMoveWithBarrier (sending a reply that spawns Working in the same frame):
//    activity row stays hidden before shows_at and fades in with intermediate alpha frames afterward (not 0->1 snap).
// 3. Progress message agent_out_return:
//    while the avatar flies home (spit_end < t < spit_end + back_ms), the outer ring stays hidden (alpha == 0)
//    and fades in smoothly after landing.
// 4. Ending message replacing a lingering activity row when status is already idle and last_turn == "":
//    no residual empty foot_room gap and no snap.

///|
let cam_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
let cam_base_msg : String = "基准参考消息"

///|
let cam_progress_msg : String = "下一条：好的，接着看"

///|
let cam_ending_msg : String = "再下一条：都改完了"

///|
fn cam_is_chat(name : String, params : Map[String, Json]) -> Bool {
  name == "chat" && text(Some(Json::object(params)), "session") == cam_ref.session
}

///|
fn cam_agent_json(status : String, started : Bool, since : Double?, last_turn_id : String) -> Json {
  let last_turn : Map[String, Json] = Map([])
  if last_turn_id != "" {
    last_turn["id"] = Json::string(last_turn_id)
  }
  let o : Map[String, Json] = {
    "key": "s-c1",
    "name": "Claude",
    "provider": "anthropic",
    "model": "claude",
    "status": Json::string(status),
    "session": {
      "key": "s-c1",
      "runtime": "claude",
      "maker": { "id": "anthropic", "name": "Anthropic" },
      "agentText": "Claude",
      "status": Json::string(status),
      "lastTurn": Json::object(last_turn),
    },
  }
  if started {
    o["started"] = Json::boolean(true)
  }
  match since {
    Some(s) => o["since"] = Json::number(s)
    None => ()
  }
  Json::object(o)
}

///|
fn cam_agent_msg_json(seq : Int, body : String, ending : String) -> Json {
  let extra : Map[String, Json] = {
    "ts": Json::string("17954265\{seq}.000000"),
    "said": Json::boolean(true),
  }
  if ending != "" {
    extra["ending"] = Json::string(ending)
  }
  @sffixture.msg(seq, "agent", @sffixture.by_agent("anthropic", "claude", "s-c1"), body, "刚刚", extra)
}

///|
fn cam_person_msg_json(seq : Int, body : String) -> Json {
  @sffixture.msg(
    seq,
    "person",
    @sffixture.by_person("左子健"),
    body,
    "刚刚",
    {
      "ts": Json::string("17954265\{seq}.000000"),
      "mine": true,
      "said": true,
    },
  )
}

///|
priv struct CamHeld {
  mut value : Json?
  mut version : Int
  changes : @signals.Signal[Int]
  mut ops : Array[Json]?
}

///|
fn cam_change(h : CamHeld, ops : Array[Json]) -> Unit {
  guard h.value is Some(v) else { return }
  h.value = Some(@core.apply_delta(v, ops))
  h.ops = Some(ops)
  h.version += 1
  h.changes.set(h.version)
}

///|
fn cam_open(
  init_agent : Json,
  clock : Ref[Double],
  extra_msgs? : Array[Json] = [],
) -> (@ui.Tester, CamHeld) {
  new_run()
  @sf.presenters_reset()
  let base = fixture("chat")
  let held : CamHeld = { value: None, version: 0, changes: @signals.signal(0), ops: None }
  let inner : Source = {
    ..base,
    now: fn() { clock.val },
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard cam_is_chat(name, params) else { return t }
      held.changes.get() |> ignore
      if held.value is None {
        match t.value {
          Some(Object(o)) => {
            let copy = o.copy()
            copy["agents"] = Json::array([init_agent])
            copy["outbox"] = Json::array([])
            if !extra_msgs.is_empty() {
              let msgs = match copy.get("messages") {
                Some(Array(arr)) => arr.copy()
                _ => []
              }
              for m in extra_msgs {
                msgs.push(m)
              }
              copy["messages"] = Json::array(msgs)
            }
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
        "chat.send" => done(Ok({ "n": 401 }))
        "session.warm" | "client.focus" | "chat.place" => done(Ok(Json::object({})))
        _ => (base.call)(name, params, done)
      }
    },
  }
  let src = round_trip_again(inner, 0.0, delta_of=fn(name, params) {
    if cam_is_chat(name, params) {
      held.ops
    } else {
      None
    }
  })
  open_chat(cam_ref)
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w=390.0,
    h=844.0,
    platform=2,
    scale=2.0,
    words_over_held=true,
  )
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  nav_rested(t)
  t.run_for(@ui.move_most_ms)
  (t, held)
}

///|
fn cam_word_alpha(t : @ui.Tester, needle : String) -> Double? {
  let mut best : Double? = None
  for w in t.words() {
    if w.0.contains(needle) {
      match best {
        Some(a) => if w.5 > a { best = Some(w.5) }
        None => best = Some(w.5)
      }
    }
  }
  best
}

///|
fn cam_word_y_alpha(t : @ui.Tester, needle : String) -> (Double, Double)? {
  for w in t.words() {
    if w.0.contains(needle) && w.5 > 0.01 {
      return Some((w.2, w.5))
    }
  }
  None
}

///|
fn cam_ring_max_alpha(t : @ui.Tester, min_y : Double, max_y : Double) -> Double {
  let mut best = 0.0
  for l in t.drawn_lines() {
    // Activity ring arcs are on the left side of the activity row (x < 60pt)
    if l.0 < 60.0 && l.1 >= min_y && l.1 <= max_y {
      let a = ((l.5 >> 24) & 0xFFL).to_int().to_double() / 255.0
      if a > best {
        best = a
      }
    }
  }
  best
}

///|
fn cam_chat_list() -> @view.ListSeen? {
  let tree = @ui.view_tree().unwrap()
  let lists = tree.lists_seen()
  if lists.is_empty() {
    None
  } else {
    Some(lists[lists.length() - 1])
  }
}

///|
test "Chat Activity Anti-Silent-Snap: idle -> queued -> running slides smoothly and fades clock in" {
  let clock : Ref[Double] = { val: 100000.0 }
  let (t, held) = cam_open(
    cam_agent_json("idle", false, None, ""),
    clock,
    extra_msgs=[cam_person_msg_json(350, cam_base_msg)],
  )
  let base_y = match p4_word_y(t, cam_base_msg) {
    Some(y) => y
    None => fail("baseline message not visible")
  }
  // 1) idle -> queued (started=true, since=None): above message must slide up smoothly, not snap in 1 frame
  let slide_ys : Array[(Double, Double)] = []
  t.each_frame(Some(fn() {
    match p4_word_y(t, cam_base_msg) {
      Some(y) => slide_ys.push((t.time(), y))
      None => ()
    }
  }))
  cam_change(held, [{ "path": ["agents"], "set": Json::array([cam_agent_json("queued", true, None, "")]) }])
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.each_frame(None)
  assert_true(t.find(tr("android-chat.chat.working")) is Some(_), msg="working row missing in queued state")
  assert_true(cam_word_y_alpha(t, "0s") is None, msg="clock should not appear while queued (since=None)")
  assert_true(slide_ys.length() >= 2, msg="expected >= 2 slide samples, got \{slide_ys.length()}")
  let end_y = slide_ys[slide_ys.length() - 1].1
  assert_true(
    base_y - end_y > 10.0,
    msg="expected baseline message to slide up > 10pt (base=\{base_y}, end=\{end_y})",
  )
  let dt = p4_step_dt(slide_ys)
  let mut mid_frames = 0
  for s in slide_ys {
    if s.1 < base_y - 1.0 && s.1 > end_y + 1.0 {
      mid_frames += 1
    }
  }
  let need = if dt <= 50.0 { 2 } else { 1 }
  assert_true(
    mid_frames >= need,
    msg="queued arrival snapped @dt=\{dt}ms (base=\{base_y}, end=\{end_y}, mid=\{mid_frames})",
  )
  // 2) queued -> running (since=Some): elapsed clock must fade in from 0 -> 1 smoothly
  let clock_fades : Array[(Double, Double)] = []
  t.each_frame(Some(fn() {
    match cam_word_alpha(t, "0s") {
      Some(a) if a > 0.01 && a < 0.99 => clock_fades.push((t.time(), a))
      _ => ()
    }
  }))
  cam_change(held, [
    { "path": ["agents"], "set": Json::array([cam_agent_json("running", true, Some(clock.val), "")]) },
  ])
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.each_frame(None)
  match cam_word_alpha(t, "0s") {
    Some(a) => assert_true(a > 0.99, msg="clock did not reach full alpha (got \{a})")
    None => fail("clock 0s missing after queued -> running")
  }
  let need_fades = if dt <= 20.0 { 2 } else { 1 }
  assert_true(
    clock_fades.length() >= need_fades,
    msg="queued -> running clock snapped without fade frames @dt=\{dt}ms (got \{clock_fades.length()}, need \{need_fades})",
  )
}

///|
///|
fn cam_open_card_msg_json(seq : Int) -> Json {
  let options : Json = [
    { "label": "继续执行", "detail": "按当前方案继续", "recommended": true },
    { "label": "暂缓处理", "detail": "先保持现状" },
  ]
  @sffixture.msg(
    seq,
    "agent",
    @sffixture.by_agent("anthropic", "claude", "s-c1"),
    "好的，我来处理。",
    "刚刚",
    {
      "ts": Json::string("17954265\{seq}.000000"),
      "ending": "need_help",
      "said": true,
      "asked": true,
      "card": {
        "type": "options",
        "assignee": "zuozijian@cue.surf",
        "assigneeText": "等 左子健 决定",
        "options": options,
      },
      "decision": { "resolved": false },
    },
  )
}

///|
test "Chat Activity Anti-Silent-Snap: CoMoveWithBarrier hides mounted row before shows_at and fades in monotonically afterward" {
  let clock : Ref[Double] = { val: 100000.0 }
  let (t, held) = cam_open(
    cam_agent_json("idle", false, None, ""),
    clock,
    extra_msgs=[cam_open_card_msg_json(350)],
  )
  let working_words = tr("android-chat.chat.working")
  let samples : Array[(Double, Double)] = []
  let mut hidden_while_mounted = false
  let mut fade_frames = 0
  let revealed_alphas : Array[Double] = []
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("no composer field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text("测试一下")
  t.each_frame(Some(fn() {
    let a = cam_word_alpha(t, working_words).unwrap_or(0.0)
    samples.push((t.time(), a))
    let mounted = t.all(Button).iter().any(fn(b) { b.label.has_prefix("Claude：") && b.rect.3 > 0.0 })
    if mounted && a <= 0.01 {
      hidden_while_mounted = true
    } else if a > 0.01 {
      revealed_alphas.push(a)
      if a < 0.99 {
        fade_frames += 1
      }
    }
  }))
  // Replying on a chat with an open options card triggers chat_body_answered, inserting Out (with sent_from_waits
  // barrier) and Working (CoMoveWithBarrier) in the same frame so stage.shows_at("act:s-c1") = barrier_until > now.
  tap_send(t)
  cam_change(held, [{ "path": ["agents"], "set": Json::array([cam_agent_json("queued", true, None, "")]) }])
  t.run_for(@sfbase.flight_desk_ms + @ui.row_size_ms + @ui.move_most_ms)
  t.each_frame(None)
  assert_true(
    hidden_while_mounted,
    msg="CoMoveWithBarrier activity row was not mounted-and-hidden (shows_at) during send flight",
  )
  let final_a = cam_word_alpha(t, working_words).unwrap_or(0.0)
  assert_true(final_a > 0.99, msg="CoMoveWithBarrier activity row did not settle to full alpha (got \{final_a})")
  let dt = p4_step_dt(samples)
  let need_fades = if dt <= 20.0 { 2 } else { 1 }
  assert_true(
    fade_frames >= need_fades,
    msg="CoMoveWithBarrier activity row snapped 0->1 without fade frames @dt=\{dt}ms (got \{fade_frames}, need \{need_fades})",
  )
  for i in 1..<revealed_alphas.length() {
    assert_true(
      revealed_alphas[i] >= revealed_alphas[i - 1] - 0.001,
      msg="CoMoveWithBarrier reveal alpha was not monotonic: \{revealed_alphas[i - 1]} -> \{revealed_alphas[i]}",
    )
  }
}

///|
test "Chat Activity Anti-Silent-Snap: progress message agent_out_return keeps ring hidden during flight home and fades in after landing" {
  let clock : Ref[Double] = { val: 100000.0 }
  let (t, held) = cam_open(
    cam_agent_json("running", false, Some(clock.val - 5000.0), "t1"),
    clock,
    extra_msgs=[cam_person_msg_json(350, cam_base_msg)],
  )
  let working_words = tr("android-chat.chat.working")
  let init_wy = match cam_word_y_alpha(t, working_words) {
    Some((y, _)) => y
    None => fail("working row not visible initially")
  }
  assert_true(
    cam_ring_max_alpha(t, init_wy - 30.0, init_wy + 30.0) > 0.9,
    msg="initial working ring not visible",
  )
  let ring_samples : Array[(Double, Double)] = []
  let mut saw_zero_after_msg = false
  let mut saw_return_fade = 0
  let mut msg_appeared = false
  t.each_frame(Some(fn() {
    if !msg_appeared && cam_word_y_alpha(t, cam_progress_msg) is Some(_) {
      msg_appeared = true
    }
    if msg_appeared {
      let wy = match cam_word_y_alpha(t, working_words) {
        Some((y, _)) => y
        None => init_wy
      }
      let ra = cam_ring_max_alpha(t, wy - 40.0, wy + 40.0)
      ring_samples.push((t.time(), ra))
      if ra <= 0.01 {
        saw_zero_after_msg = true
      } else if ra < 0.95 && saw_zero_after_msg {
        saw_return_fade += 1
      }
    }
  }))
  // Push a non-ending progress message from the running agent -> Fold -> Float -> Spit -> Return
  cam_change(held, [
    { "path": ["messages"], "key": ["seq", "outgoing"], "put": cam_agent_msg_json(351, cam_progress_msg, "") },
  ])
  t.draw()
  t.run_for(@ui.move_most_ms * 5.0)
  t.each_frame(None)
  assert_true(msg_appeared, msg="progress message never appeared")
  assert_true(saw_zero_after_msg, msg="ring was not hidden while avatar was away / flying home")
  let final_wy = match cam_word_y_alpha(t, working_words) {
    Some((y, _)) => y
    None => fail("working row missing after progress message return")
  }
  let final_ra = cam_ring_max_alpha(t, final_wy - 40.0, final_wy + 40.0)
  assert_true(final_ra > 0.9, msg="ring did not return to full visibility (got \{final_ra})")
  let dt = p4_step_dt(ring_samples)
  let need_fades = if dt <= 20.0 { 2 } else { 1 }
  assert_true(
    saw_return_fade >= need_fades,
    msg="ring snapped back without fade frames on agent_out_return @dt=\{dt}ms (got \{saw_return_fade}, need \{need_fades})",
  )
}

///|
test "Chat Activity Anti-Silent-Snap: ending message replacing linger activity leaves no empty foot_room when status is idle and last_turn is empty" {
  let clock : Ref[Double] = { val: 100000.0 }
  let (t, held) = cam_open(
    cam_agent_json("running", false, Some(clock.val - 5000.0), ""),
    clock,
    extra_msgs=[cam_person_msg_json(350, cam_base_msg)],
  )
  // Measure normal resting gap between last visible row bottom and list foot_top
  let before_list = cam_chat_list().unwrap()
  let mut before_bottom = 0.0
  for r in before_list.rows {
    let b = r.2.1 + r.2.3
    if b > before_bottom {
      before_bottom = b
    }
  }
  let normal_gap = before_list.foot_top - before_bottom
  // Ending message arrives in the same snapshot as agent status becoming idle with last_turn == ""
  cam_change(held, [
    { "path": ["messages"], "key": ["seq", "outgoing"], "put": cam_agent_msg_json(351, cam_ending_msg, "all_done") },
    { "path": ["agents"], "set": Json::array([cam_agent_json("idle", false, None, "")]) },
  ])
  t.draw()
  t.run_for(@ui.move_most_ms * 4.0)
  assert_true(t.find(cam_ending_msg) is Some(_), msg="ending message missing")
  assert_true(t.find(tr("android-chat.chat.working")) is None, msg="working row should be gone after ending message")
  let after_list = cam_chat_list().unwrap()
  let mut after_bottom = 0.0
  for r in after_list.rows {
    let b = r.2.1 + r.2.3
    if b > after_bottom {
      after_bottom = b
    }
  }
  let after_gap = after_list.foot_top - after_bottom
  // Without answered_lingers fix, leaves_room returns true and leaves ~40pt extra empty foot_room
  assert_true(
    (after_gap - normal_gap).abs() < 12.0,
    msg="residual empty foot_room after linger replaced by ending message: normal_gap=\{normal_gap}, after_gap=\{after_gap}",
  )
}

///|
fn cam_avatar_discs(t : @ui.Tester) -> Array[(Double, Double, Double, Double, Int64)] {
  let side = @ui.Space::S4_5.px()
  t
  .drawn_rects()
  .filter(fn(r) { r.0 < 60.0 && (r.2 - side).abs() < 1.5 && (r.3 - side).abs() < 1.5 })
}

///|
test "Chat Activity Anti-Silent-Snap: Fold->Float->Spit->Return fades ring during Fold, flies avatar without overshoot or landing snap, and reveals neutral disc smoothly" {
  let clock : Ref[Double] = { val: 100000.0 }
  let (t, held) = cam_open(
    cam_agent_json("running", false, Some(clock.val - 5000.0), "t1"),
    clock,
    extra_msgs=[cam_person_msg_json(350, cam_base_msg)],
  )
  let working_words = tr("android-chat.chat.working")
  let init_wy = match cam_word_y_alpha(t, working_words) {
    Some((y, _)) => y
    None => fail("working row not visible initially")
  }
  let init_base_y = match cam_word_y_alpha(t, cam_base_msg) {
    Some((y, _)) => y
    None => fail("base message not visible initially")
  }
  assert_true(
    cam_avatar_discs(t).filter(fn(d) { d.1 > init_base_y }).is_empty(),
    msg="expected no agent avatar disc below base message before progress message arrives",
  )
  let mut fold_ring_fades = 0
  let mut saw_fold_phase = false
  let mut msg_appeared = false
  let float_ys : Array[(Double, Double)] = []
  let disc_samples : Array[(Double, Double, Int64)] = []
  let mut saw_soft_disc = false
  let neutral_bg = @sf.theme().p.neutral_bg
  let neutral_rgb = neutral_bg & 0xFFFFFF00L
  let neutral_alpha = (neutral_bg & 0xFFL).to_int().to_double() / 255.0
  t.each_frame(Some(fn() {
    let ra = cam_ring_max_alpha(t, init_wy - 40.0, init_wy + 40.0)
    if !msg_appeared {
      if ra > 0.05 && ra < 0.95 {
        fold_ring_fades += 1
        saw_fold_phase = true
      }
    }
    if !msg_appeared && cam_word_y_alpha(t, cam_progress_msg) is Some(_) {
      msg_appeared = true
    }
    // Track the newly added agent avatar disc (strictly below cam_base_msg on every frame) during Float
    let cur_base_y = match cam_word_y_alpha(t, cam_base_msg) {
      Some((y, _)) => y
      None => 0.0
    }
    let discs = cam_avatar_discs(t).filter(fn(d) { d.1 > cur_base_y })
    if !discs.is_empty() {
      let mut best_y = -1.0
      let mut best_c = 0L
      for d in discs {
        if d.1 > best_y {
          best_y = d.1
          best_c = d.4
        }
      }
      if best_y >= 0.0 {
        float_ys.push((t.time(), best_y))
        if disc_samples.length() < 16 {
          disc_samples.push((t.time(), best_y, best_c))
        }
        let a = (best_c & 0xFFL).to_int().to_double() / 255.0
        if (best_c & 0xFFFFFF00L) == neutral_rgb && a > 0.005 && a < neutral_alpha - 0.015 {
          saw_soft_disc = true
        }
      }
    }
  }))
  cam_change(held, [
    { "path": ["messages"], "key": ["seq", "outgoing"], "put": cam_agent_msg_json(351, cam_progress_msg, "") },
  ])
  t.draw()
  t.run_for(@ui.move_most_ms * 5.0)
  t.each_frame(None)
  assert_true(msg_appeared, msg="progress message never appeared")
  let dt = if float_ys.length() >= 2 { p4_step_dt(float_ys) } else { 16.7 }
  let need_fades = if dt <= 20.0 { 2 } else { 1 }
  assert_true(
    saw_fold_phase && fold_ring_fades >= need_fades,
    msg="Fold ring snapped out without fade frames @dt=\{dt}ms (got \{fold_ring_fades}, need \{need_fades})",
  )
  assert_true(float_ys.length() >= 2, msg="expected >= 2 Float avatar samples, got \{float_ys.length()}")
  let rest_y = float_ys[float_ys.length() - 1].1
  let from_y = init_wy
  assert_true(
    float_ys[0].1 > rest_y + 5.0,
    msg="Float avatar first sample y=\{float_ys[0].1} was not below rest_y=\{rest_y} (missed Float flight)",
  )
  let lo = @sf.dmin(from_y, rest_y) - 1.5
  let hi = @sf.dmax(from_y, rest_y) + 1.5
  let mut max_step = 0.0
  for i, s in float_ys {
    assert_true(
      s.1 >= lo && s.1 <= hi,
      msg="Float avatar y=\{s.1} at t=\{s.0} overshot bounds [\{lo}, \{hi}] (from=\{from_y}, rest=\{rest_y})",
    )
    if i > 0 {
      let step = (s.1 - float_ys[i - 1].1).abs()
      if step > max_step {
        max_step = step
      }
    }
  }
  let max_step_limit = if dt <= 20.0 { 25.0 } else if dt <= 50.0 { 45.0 } else { 90.0 }
  assert_true(
    max_step <= max_step_limit,
    msg="Float avatar snapped with single-frame jump=\{max_step}pt > \{max_step_limit}pt @dt=\{dt}ms",
  )
  if dt <= 50.0 {
    assert_true(
      saw_soft_disc,
      msg="Float avatar neutral disc popped in without bare_from smooth fade @dt=\{dt}ms neutral_bg=\{neutral_bg} samples=\{Repr(disc_samples)}",
    )
  }
}
