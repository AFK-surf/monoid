// Adaptive Small-screen chat top bar title (chat_bar_node.mbt):
// 1. Whole title fits on Row 1 -> single 50pt bar, people drop first, title not toggleable.
// 2. Overflows Row 1 with >= max(44pt, width("一二三…")) left -> Row 1 truncated with ellipsis, tap expands
//    smoothly (280ms) to Row 2 full width keeping Row 1 controls horizontally locked; tap Row 2 collapses (260ms).
// 3. Overflows Row 1 with < max(44pt, width("一二三…")) left -> auto-expanded immediately to Row 2, non-collapsible.

///|
fn chat_bar_node_tester(
  title : String,
  extra_agents? : Int = 0,
  archivable? : Bool = false,
  has_jobs? : Bool = false,
  jobs_on? : @signals.Signal[Bool],
  archivable_on? : @signals.Signal[Bool],
  people? : Int = 0,
  font_scale? : Double = 1.0,
  w? : Double = 390.0,
  h? : Double = 844.0,
  msg_count? : Int = 0,
  at? : Double,
) -> (@ui.Tester, @signals.Signal[String]) {
  new_run()
  let base = fixture("chat")
  let title_sig = @signals.signal(title, same=fn(a, b) { a == b })
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      // (its services and jobs: some all along, or while `jobs_on` says so, none else: told as the core tells its
      // summary, a value all along, its first never changing to say there are some)
      let jobs_now = match jobs_on {
        Some(on) => on.get()
        None => has_jobs
      }
      if name == "chatJobs" && (jobs_now || jobs_on is Some(_)) {
        let jobs : Map[String, Json] = match got.value {
          Some(Object(m)) => m.copy()
          _ => Map([])
        }
        jobs["hasJobs"] = Json::boolean(jobs_now)
        return { ..got, value: Some(Json::object(jobs)) }
      }
      guard name == "chat" && got.value is Some(Object(chat)) else { return got }
      let changed = chat.copy()
      changed["title"] = Json::string(title_sig.get())
      // (nothing left in it: all along, or while `archivable_on` says so)
      changed["archivable"] = Json::boolean(
        match archivable_on {
          Some(on) => on.get()
          None => archivable
        },
      )
      if people > 0 {
        changed["people"] = Json::array(
          Array::makei(people, fn(i) {
            Json::object({
              "id": Json::string("u\{i}"),
              "shown": Json::object({ "name": Json::string("人\{i}"), "display": Json::string("Person \{i}") }),
            })
          }),
        )
      }
      changed["archived"] = Json::boolean(false)
      if extra_agents > 0 {
        let agents = items(got.value, "agents").copy()
        for idx in 0..<extra_agents {
          agents.push({
            "session": {
              "key": "s-extra-\{idx}",
              "runtime": "codex",
              "maker": { "id": "openai", "name": "OpenAI" },
              "agentText": "Codex",
              "statusText": "未开始",
              "tone": "neutral",
            },
            "status": "idle",
          })
        }
        changed["agents"] = Json::array(agents)
      }
      if msg_count > 0 {
        let msgs = items(got.value, "messages")
        if msgs.length() > 0 && msgs[msgs.length() - 1] is Object(last) {
          let base_seq = number(Some(msgs[msgs.length() - 1]), "seq")
          let built : Array[Json] = []
          for idx in 0..<msg_count {
            let m = last.copy()
            m.remove("attachments")
            m.remove("placed")
            m["seq"] = Json::number(base_seq + idx.to_double())
            m["ts"] = Json::string("ts\{idx + 1}")
            m["id"] = Json::string("m-\{idx + 1}")
            // (where the core says it was left: each its own words, to be found by)
            if at is Some(_) {
              m["text"] = Json::string("第\{idx + 1}条：这一条讲清单里的一项，写得长一些，占两三行。")
            }
            built.push(Json::object(m))
          }
          changed["messages"] = Json::array(built)
        }
      }
      match at {
        Some(a) => changed["at"] = Json::number(a)
        None => ()
      }
      { ..got, value: Some(Json::object(changed)) }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title, station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=2)
  if font_scale != 1.0 {
    t.set_font_scale(font_scale)
  }
  t.run_for(@ui.move_most_ms)
  (t, title_sig)
}

///|
fn bar_node_audit(t : @ui.Tester) -> Array[String] {
  t.audit().filter(fn(f) { f.contains("chat_bar_node") })
}

///|
fn bar_agent_x(t : @ui.Tester) -> Double? {
  for s in t.semantics() {
    if s.role == @ui.Role::Button && s.label.contains("Willow") && s.rect.1 < 50.0 {
      return Some(s.rect.0)
    }
  }
  None
}

///|
test "小屏顶栏：短标题稳居第 1 行，点击不展开，零 audit 告警" {
  let (t, _) = chat_bar_node_tester("梳理发布清单")
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "梳理发布清单", station_name: "Willow" }
  assert_eq(bar_extra_target(bar_ref), 0.0)
  let hits = t.words().filter(fn(w) { w.0 == "梳理发布清单" && w.5 > 0.5 })
  assert_eq(hits.length(), 1, msg="\{Repr(hits)}")
  assert_true(hits[0].2 < 50.0, msg="short title on Row 1: \{Repr(hits[0])}")
  assert_eq(bar_node_audit(t), [])
  // Tapping short title must NOT expand Row 2
  t.tap(hits[0].1 + hits[0].3 / 2.0, hits[0].2 + hits[0].4 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(bar_extra_target(bar_ref), 0.0)
  let hits_after = t.words().filter(fn(w) { w.0 == "梳理发布清单" && w.5 > 0.5 })
  assert_eq(hits_after.length(), 1)
  assert_true(hits_after[0].2 < 50.0)
  assert_eq(bar_node_audit(t), [])
}

///|
fn first_msg_top(t : @ui.Tester, text : String) -> Double? {
  let ys = t.words().filter(fn(w) { w.0 == text && w.5 > 0.5 }).map(fn(w) { w.2 })
  if ys.length() == 0 {
    None
  } else {
    Some(ys.fold(init=ys[0], fn(a, b) { if b < a { b } else { a } }))
  }
}

///|
test "小屏顶栏：放得下 3 字+省略号的长标题点击平滑展开到第 2 行、第 1 行控件横坐标锁定、再点收起，全过程零 audit 告警" {
  let long_title = "重新设计手机端小屏顶部栏标题展开与收起动画节奏验证"
  let (t, _) = chat_bar_node_tester(long_title, msg_count=14)
  t.move_to(195.0, 400.0)
  t.wheel(195.0, 400.0, -10000.0)
  t.run_for(@ui.move_most_ms)
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: long_title, station_name: "Willow" }
  let r2_ref = "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。"
  // Collapsed baseline
  assert_eq(bar_extra_target(bar_ref), 0.0)
  assert_eq(bar_node_audit(t), [], msg="collapsed audit: \{Repr(bar_node_audit(t))}")
  guard bar_agent_x(t) is Some(agent_x0) else { fail("missing Row 1 agent mark") }
  guard first_msg_top(t, r2_ref) is Some(msg_y0) else {
    fail("missing top message: \{Repr(t.words().filter(fn(w) { w.2 < 300.0 }))}")
  }
  assert_true(msg_y0 >= 60.0 && msg_y0 < 160.0, msg="top message anchored under bar: \{msg_y0}")
  // Row 1 has truncated words in the top 50pt
  let row1_words = t.words().filter(fn(w) { w.2 < 50.0 && w.1 > 44.0 && w.5 > 0.5 && w.0 == long_title })
  assert_true(row1_words.length() > 0, msg="Row 1 title expected: \{Repr(t.words().filter(fn(w) { w.2 < 60.0 }))}")
  let tap_x = row1_words[0].1 + 20.0
  let tap_y = 25.0
  // Tap Row 1 title to expand (280ms)
  t.tap(tap_x, tap_y)
  t.run_for(chat_bar_expand_ms / 2.0)
  assert_eq(bar_node_audit(t), [], msg="mid-expand audit: \{Repr(bar_node_audit(t))}")
  guard bar_agent_x(t) is Some(agent_x_mid) else { fail("missing Row 1 agent mid-expand") }
  assert_true((agent_x_mid - agent_x0).abs() < 0.2, msg="agent X jumped mid-expand: \{agent_x0} vs \{agent_x_mid}")
  guard first_msg_top(t, r2_ref) is Some(msg_y_mid) else { fail("missing message mid-expand") }
  assert_true(msg_y_mid > msg_y0 + 10.0, msg="message list should move smoothly downward mid-expand: \{msg_y0} -> \{msg_y_mid}")
  t.run_for(chat_bar_expand_ms)
  assert_eq(bar_node_audit(t), [], msg="expanded audit: \{Repr(bar_node_audit(t))}")
  assert_true(bar_extra_target(bar_ref) >= 50.0, msg="expanded Row 2 height >= 50pt")
  guard bar_agent_x(t) is Some(agent_x_exp) else { fail("missing Row 1 agent expanded") }
  assert_true((agent_x_exp - agent_x0).abs() < 0.2, msg="agent X jumped expanded: \{agent_x0} vs \{agent_x_exp}")
  // Row 1 title is laid_nowhere once settled expanded; Row 2 shows full title below 50pt
  let row1_after = t.words().filter(fn(w) { w.2 < 48.0 && w.0 == long_title && w.5 > 0.0 })
  assert_eq(row1_after.length(), 0, msg="Row 1 title hidden when settled expanded")
  let row2_hits = t.words().filter(fn(w) { w.2 >= 48.0 && w.0 == long_title && w.5 > 0.5 })
  assert_eq(row2_hits.length(), 1, msg="Row 2 shows full title: \{Repr(row2_hits)}")
  guard first_msg_top(t, r2_ref) is Some(msg_y_exp) else { fail("missing message expanded") }
  assert_true(msg_y_exp >= msg_y0 + 50.0 - 0.5, msg="message list pushed down by Row 2 height: \{msg_y0} -> \{msg_y_exp}")
  // Tap Row 2 title to collapse (260ms)
  t.tap(row2_hits[0].1 + row2_hits[0].3 / 2.0, row2_hits[0].2 + row2_hits[0].4 / 2.0)
  t.run_for(chat_bar_collapse_ms / 2.0)
  assert_eq(bar_node_audit(t), [], msg="mid-collapse audit: \{Repr(bar_node_audit(t))}")
  t.run_for(chat_bar_collapse_ms)
  assert_eq(bar_node_audit(t), [], msg="collapsed-back audit: \{Repr(bar_node_audit(t))}")
  assert_eq(bar_extra_target(bar_ref), 0.0)
  guard bar_agent_x(t) is Some(agent_x_end) else { fail("missing Row 1 agent collapsed back") }
  assert_true((agent_x_end - agent_x0).abs() < 0.2, msg="agent X jumped after collapse")
  guard first_msg_top(t, r2_ref) is Some(msg_y_end) else { fail("missing message after collapse") }
  assert_true((msg_y_end - msg_y0).abs() < 0.5, msg="message list returned to baseline: \{msg_y0} vs \{msg_y_end}")
}

///|
test "小屏顶栏：放不下 3 字+省略号时默认直接展开到第 2 行，且不可点收起" {
  let tight_title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  // w=290 with 1 agent pill + jobs + info + more leaves ~30pt on Row 1 (< width("一二三…"))
  let (t, _) = chat_bar_node_tester(
    tight_title,
    extra_agents=0,
    archivable=false,
    has_jobs=true,
    w=290.0,
    msg_count=1,
  )
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: tight_title, station_name: "Willow" }
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="must auto-expand on mount")
  let row2_hits = t.words().filter(fn(w) { w.2 >= 48.0 && w.0 == tight_title && w.5 > 0.5 })
  assert_eq(row2_hits.length(), 1, msg="auto-expanded title shown on Row 2: \{Repr(row2_hits)}")
  assert_eq(bar_node_audit(t), [], msg="auto-expanded audit: \{Repr(bar_node_audit(t))}")
  // Tapping Row 2 must NOT collapse it back
  t.tap(row2_hits[0].1 + row2_hits[0].3 / 2.0, row2_hits[0].2 + row2_hits[0].4 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="non-collapsible when Row 1 cannot fit 3 chars")
  assert_eq(bar_node_audit(t), [])
}

///|
test "小屏顶栏：大字号(1.3x)且标题缩短为短标题时自动收起并保持 audit 通过" {
  let long_title = "大字号展开态动态变短收起测试标题内容很长会换行"
  let (t, title_sig) = chat_bar_node_tester(long_title, extra_agents=0, font_scale=1.3, msg_count=1)
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: long_title, station_name: "Willow" }
  // Expand if in State 2 (or already auto-expanded in State 3)
  if bar_extra_target(bar_ref) == 0.0 {
    let row1_words = t.words().filter(fn(w) { w.2 < 50.0 && w.1 > 44.0 && w.5 > 0.5 && w.0 == long_title })
    assert_true(row1_words.length() > 0, msg="expected Row 1 word: \{Repr(t.words().filter(fn(w) { w.2 < 60.0 }))}")
    t.tap(row1_words[0].1 + 20.0, 25.0)
    t.run_for(chat_bar_expand_ms + @ui.move_most_ms)
  }
  assert_true(bar_extra_target(bar_ref) > 30.0)
  assert_eq(bar_node_audit(t), [])
  // Title shrinks to short title -> collapses smoothly to Row 1
  title_sig.set("短")
  t.run_for(chat_bar_collapse_ms + @ui.move_most_ms)
  assert_eq(bar_extra_target(bar_ref), 0.0)
  let short_hits = t.words().filter(fn(w) { w.0 == "短" && w.5 > 0.5 })
  assert_eq(short_hits.length(), 1)
  assert_true(short_hits[0].2 < 50.0)
  assert_eq(bar_node_audit(t), [])
}

///|
test "小屏顶栏：有状态栏且可点展开时，第 1 行标题自身高度不被内边距撑大，并与返回键/agent/更多垂直居中对齐" {
  let long_title = "研究执行历史页面结构与性能"
  let (t, _) = chat_bar_node_tester(long_title, msg_count=1)
  t.post(@hostapi.system_channel, "{\"over\":false,\"bars\":{\"top\":40,\"bottom\":0,\"left\":0,\"right\":0}}")
  t.run_for(@ui.move_most_ms)
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: long_title, station_name: "Willow" }
  assert_eq(bar_extra_target(bar_ref), 0.0)
  let title_hits = t.words().filter(fn(w) { w.0 == long_title && w.5 > 0.5 })
  assert_eq(title_hits.length(), 1, msg="expected single Row 1 title: \{Repr(title_hits)}")
  let (_, _, ty, _, th, _) = title_hits[0]
  assert_true(th < 28.0, msg="words node height must not include vertical padding: h=\{th}")
  assert_true(ty >= 50.0, msg="title must stay clear of 40pt status bar: y=\{ty}")
  let title_mid = ty + th / 2.0
  for label in ["返回", "Claude · Willow", "对话信息", "更多"] {
    let found = t.semantics().iter().find_first(fn(s) { s.role == @ui.Role::Button && s.label == label })
    guard found is Some(s) else { fail("missing button \{label}") }
    let btn_mid = s.rect.1 + s.rect.3 / 2.0
    assert_true((title_mid - btn_mid).abs() < 0.5, msg="title mid \{title_mid} != \{label} mid \{btn_mid}")
  }
  assert_eq(bar_node_audit(t), [])
}

///|
test "小屏顶栏：对话有服务和后台任务时，打开它们的圆键有名字（读屏念得出、测试按名字找得到）" {
  let (t, _) = chat_bar_node_tester("短标题", has_jobs=true)
  let keys = t.all(Button, label="服务和后台任务")
  assert_eq(keys.length(), 1, msg="the jobs key, by its name")
}

///|
test "小屏顶栏：放不下而直接展开到第 2 行的对话，打开在上次离开的消息：那条消息整条在展开后的顶栏下，不被第 2 行盖住" {
  let tight_title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  let (t, _) = chat_bar_node_tester(tight_title, has_jobs=true, w=290.0, msg_count=14, at=14.0)
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: tight_title, station_name: "Willow" }
  t.run_for(@ui.move_most_ms)
  let extra = bar_extra_target(bar_ref)
  assert_true(extra > 30.0, msg="must auto-expand on mount")
  let foot = bar_foot() + extra
  let at = t.words().filter(fn(w) { w.0.has_prefix("第4条：") && w.5 > 0.5 }).map(fn(w) { w.2 })
  assert_true(at.length() > 0, msg="the message left at not drawn: \{Repr(t.words().map(fn(w) { (w.0, w.2) }))}")
  assert_true(at[0] >= foot, msg="its first line at \{at[0]}, the bar's foot at \{foot}")
  // (and just under it, as where it was left puts it: not further down by the second row twice)
  assert_true(at[0] < foot + 60.0, msg="its first line at \{at[0]}, the bar's foot at \{foot}")
}

test "小屏顶栏：归档或服务键刚出现就又消失（两帧之间，或刚画出第一帧），agent 标签从它半路所在之处直接回原位，每帧移动不到 8pt，不残留上一段位移" {
  for cause in ["archive", "jobs"] {
    for back in ["between", "frame"] {
      let archivable = @signals.signal(false)
      let jobs = @signals.signal(false)
      let on = if cause == "archive" { archivable } else { jobs }
      let (t, w) = bar_at_drops(archivable, jobs, 20.0)
      let x0 = bar_tile_drawn(t).map(fn(d) { d.0 }).unwrap_or(-1000.0)
      // it comes and goes again: 5 ms on, before a frame draws it (between), or at its first frame (frame)
      let (xs, steps) = bar_tile_way(
        t,
        fn() {
          on.set(true)
          if back == "between" {
            t.advance(between_frames_ms)
          } else {
            t.frame()
          }
          on.set(false)
        },
        @ui.move_most_ms,
      )
      assert_eq(steps, [], msg="\{cause} \{back} at \{w}: turned back: \{Repr(xs)}")
      assert_eq(xs[xs.length() - 1].0, x0, msg="\{cause} \{back} at \{w}: back where it was: \{Repr(xs)}")
      assert_eq(bar_node_audit(t), [], msg="\{cause} \{back}")
    }
  }
}

///|
/// Where the first agent's tile in the bar is drawn now (its ground: the soft card it stands on, a mark's height), on
/// its way too.
fn bar_tile_drawn(t : @ui.Tester) -> (Double, Double)? {
  let card = @sf.theme().p.card
  for r in t.drawn_rects() {
    if r.4 == card && r.1 < 60.0 && (r.3 - mark_side()).abs() < 0.5 && r.2 > mark_side() {
      return Some((r.0, r.2))
    }
  }
  None
}

///|
/// Whether the chat's people are drawn in the bar (their faces' rings, 19 across).
fn bar_people_drawn(t : @ui.Tester) -> Bool {
  t.drawn_rects().iter().any(fn(r) { r.1 < 60.0 && (r.2 - 19.0).abs() < 0.5 && (r.3 - 19.0).abs() < 0.5 })
}

///|
/// A bar of a chat of one person and its agent (the fixture's), as wide as leaves `slack` of room past its agent's
/// tile while 归档 and the services' key are not there: less than one of them takes, more than the person does. The
/// two as `archivable` and `jobs` say.
fn bar_at_drops(
  archivable : @signals.Signal[Bool],
  jobs : @signals.Signal[Bool],
  slack : Double,
) -> (@ui.Tester, Double) {
  // (the room left past the tile at 小屏's 390, its end then the info key's start, the middle's 8 before it)
  let (t0, _) = chat_bar_node_tester("梳理发布清单", people=1, archivable_on=@signals.signal(false), jobs_on=@signals.signal(false))
  guard bar_tile_drawn(t0) is Some((x0, w0)) && bar_button_x(t0, tr("android-chat.info.title")) is Some(end0) else {
    @halt.saying("no tile or 对话信息 in the bar: \{Repr(t0.drawn_rects().filter(fn(r) { r.1 < 60.0 }))}")
  }
  let left = end0 - 8.0 - (x0 + w0)
  let w = 390.0 - left + slack
  let (t, _) = chat_bar_node_tester("梳理发布清单", people=1, archivable_on=archivable, jobs_on=jobs, w~)
  (t, w)
}

///|
/// Where the bar's button said `label` stands across (its left), as laid out now.
fn bar_button_x(t : @ui.Tester, label : String) -> Double? {
  for s in t.semantics() {
    if s.role == @ui.Role::Button && s.label == label && s.rect.1 < 60.0 {
      return Some(s.rect.0)
    }
  }
  None
}

///|
/// Each frame's left of the agent's tile and whether the people are drawn, from the frame before `change` is made,
/// through `ms` of the frames a host draws after it; and what of the tile steps more than 8 in a frame.
fn bar_tile_way(t : @ui.Tester, change : () -> Unit, ms : Double) -> (Array[(Double, Bool)], Array[String]) {
  let now = fn() { (bar_tile_drawn(t).map(fn(d) { d.0 }).unwrap_or(-1000.0), bar_people_drawn(t)) }
  let xs = [now()]
  t.each_frame(Some(fn() { xs.push(now()) }))
  change()
  t.run_shown(ms)
  t.each_frame(None)
  let steps = []
  for i in 1..<xs.length() {
    let d = xs[i].0 - xs[i - 1].0
    if d > 8.0 || d < -8.0 {
      steps.push("frame \{i}: \{xs[i - 1].0} → \{xs[i].0}")
    }
  }
  (xs, steps)
}

///|
test "小屏顶栏：归档或服务键出现时人头栈刚好放不下，人头在那一刻一步离开、消失时一步回来，agent 标签每帧移动不到 8pt，不急停；作为应答首次告知时直接就位" {
  for cause in ["archive", "jobs"] {
    let archivable = @signals.signal(false)
    let jobs = @signals.signal(false)
    let on = if cause == "archive" { archivable } else { jobs }
    let (t, w) = bar_at_drops(archivable, jobs, 20.0)
    assert_true(bar_people_drawn(t), msg="\{cause} at \{w}: the person drawn while there is room")
    let x0 = bar_tile_drawn(t).map(fn(d) { d.0 }).unwrap_or(-1000.0)
    // it comes: the person leaves the row at once, the tile drawn on its way from where it was
    let (came, came_steps) = bar_tile_way(t, fn() { on.set(true) }, @ui.move_most_ms)
    let x1 = came[came.length() - 1].0
    assert_true(!came[came.length() - 1].1, msg="\{cause} at \{w}: the person left the row short of room: \{Repr(came)}")
    assert_true(!came[1].1, msg="\{cause} at \{w}: the person left at the change's frame, not on the way: \{Repr(came)}")
    assert_true(x0 - x1 >= 8.0, msg="\{cause} at \{w}: the tile moved for it: \{x0} → \{x1}")
    assert_eq(came_steps, [], msg="\{cause} at \{w}: its way: \{Repr(came)}")
    assert_true(came.length() > 3, msg="\{cause} at \{w}: drawn on its way: \{Repr(came)}")
    // gone: the person back at once, the tile on its way back
    let (went, went_steps) = bar_tile_way(t, fn() { on.set(false) }, @ui.move_most_ms)
    assert_true(went[1].1, msg="\{cause} at \{w}: the person back at the change's frame: \{Repr(went)}")
    assert_eq(went[went.length() - 1].0, x0, msg=cause)
    assert_eq(went_steps, [], msg="\{cause} at \{w}: its way back: \{Repr(went)}")
    // told as an answer (the topic's first value): at once, no way
    let (told, _) = bar_tile_way(t, fn() { @view.answering(fn() { on.set(true) }) }, @ui.move_most_ms)
    assert_true(told.length() >= 2, msg=cause)
    assert_eq(told[1].0, x1, msg="\{cause} at \{w}: an answer's at once: \{Repr(told)}")
    assert_eq(bar_node_audit(t), [], msg=cause)
  }
}

///|
/// How the bar's second row shows on each frame a host draws through `ms` after `change` (its title's words there:
/// how opaque, 0 not drawn), the frame before it first.
fn bar_row2_way(t : @ui.Tester, title : String, change : () -> Unit, ms : Double) -> Array[Double] {
  let now = fn() {
    t.words().filter(fn(w) { w.0 == title && w.2 >= 48.0 }).fold(init=0.0, fn(a, w) { if w.5 > a { w.5 } else { a } })
  }
  let seen = [now()]
  t.each_frame(Some(fn() { seen.push(now()) }))
  change()
  t.run_shown(ms)
  t.each_frame(None)
  seen
}

///|
test "小屏顶栏：服务键出现使标题放不下 3 字时，实时出现则第 2 行平滑展开；作为订阅首次应答出现（重进带后台任务的对话）则在其布局那一帧直接展开，不在页面横滑中途做展开动画" {
  let title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title, station_name: "Willow" }
  // (the widest bar where the services' key leaves the title less than 3 characters, found once: without it, more)
  let mut lo = 260.0
  let mut hi = 420.0
  while hi - lo > 1.0 {
    let mid = (lo + hi) / 2.0
    chat_bar_node_tester(title, jobs_on=@signals.signal(true), w=mid, msg_count=1) |> ignore
    let open = bar_extra_target(bar_ref) > 30.0
    if open {
      lo = mid
    } else {
      hi = mid
    }
  }
  let w = lo.floor()
  let jobs = @signals.signal(false)
  let (t, _) = chat_bar_node_tester(title, jobs_on=jobs, w~, msg_count=1)
  assert_true(bar_extra_target(bar_ref) < 0.5, msg="at \{w}: its second row open without the services' key")
  // live: on its way
  let came = bar_row2_way(t, title, fn() { jobs.set(true) }, @ui.move_most_ms)
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="at \{w}: its second row not opened by the services' key")
  let between = came.filter(fn(a) { a > 0.0 && a < 0.99 })
  assert_true(between.length() > 3, msg="at \{w}: live, not on its way: \{Repr(came)}")
  assert_eq(bar_node_audit(t), [])
  // told as an answer (the jobs' first value as the chat opens again): open at once, as it is laid out
  let jobs = @signals.signal(false)
  let (t, _) = chat_bar_node_tester(title, jobs_on=jobs, w~, msg_count=1)
  assert_true(bar_extra_target(bar_ref) < 0.5, msg="at \{w}: its second row open without the services' key")
  let told = bar_row2_way(t, title, fn() { @view.answering(fn() { jobs.set(true) }) }, @ui.move_most_ms)
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="at \{w}: its second row not opened by the answer")
  let between = told.filter(fn(a) { a > 0.0 && a < 0.99 })
  assert_eq(between, [], msg="at \{w}: an answer's on its way: \{Repr(told)}")
  assert_true(told[told.length() - 1] >= 0.99, msg="at \{w}: \{Repr(told)}")
  assert_eq(bar_node_audit(t), [])
}
