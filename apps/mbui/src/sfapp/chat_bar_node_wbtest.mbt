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
  over? : (String, Topic) -> Topic = fn(_, t) { t },
  no_agents? : Bool = false,
) -> (@ui.Tester, @signals.Signal[String]) {
  new_run()
  let base = fixture("chat")
  let title_sig = @signals.signal(title, same=fn(a, b) { a == b })
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = over(name, base.topic(name, params).get().snapshot())
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
      if no_agents {
        changed["agents"] = Json::array([])
      }
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
fn bar_info_x(t : @ui.Tester) -> Double? {
  for s in t.semantics() {
    if s.role == @ui.Role::Button && s.label == tr("android-chat.info.title") && s.rect.1 < 50.0 {
      return Some(s.rect.0)
    }
  }
  None
}

///|
fn composer_agent_rect(t : @ui.Tester) -> (Double, Double, Double, Double)? {
  for s in t.semantics() {
    if s.role == @ui.Role::Button && s.label.contains("Willow") && s.rect.1 > 400.0 {
      return Some(s.rect)
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
  guard bar_info_x(t) is Some(info_x0) else { fail("missing Row 1 info button") }
  assert_true(composer_agent_rect(t) is Some(_), msg="agent mark must sit above composer")
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
  guard bar_info_x(t) is Some(info_x_mid) else { fail("missing Row 1 info mid-expand") }
  assert_true((info_x_mid - info_x0).abs() < 0.2, msg="info X jumped mid-expand: \{info_x0} vs \{info_x_mid}")
  guard first_msg_top(t, r2_ref) is Some(msg_y_mid) else { fail("missing message mid-expand") }
  assert_true(msg_y_mid > msg_y0 + 10.0, msg="message list should move smoothly downward mid-expand: \{msg_y0} -> \{msg_y_mid}")
  t.run_for(chat_bar_expand_ms)
  assert_eq(bar_node_audit(t), [], msg="expanded audit: \{Repr(bar_node_audit(t))}")
  assert_true(bar_extra_target(bar_ref) >= 50.0, msg="expanded Row 2 height >= 50pt")
  guard bar_info_x(t) is Some(info_x_exp) else { fail("missing Row 1 info expanded") }
  assert_true((info_x_exp - info_x0).abs() < 0.2, msg="info X jumped expanded: \{info_x0} vs \{info_x_exp}")
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
  guard bar_info_x(t) is Some(info_x_end) else { fail("missing Row 1 info collapsed back") }
  assert_true((info_x_end - info_x0).abs() < 0.2, msg="info X jumped after collapse")
  guard first_msg_top(t, r2_ref) is Some(msg_y_end) else { fail("missing message after collapse") }
  assert_true((msg_y_end - msg_y0).abs() < 0.5, msg="message list returned to baseline: \{msg_y0} vs \{msg_y_end}")
}

///|
test "小屏顶栏：放不下 3 字+省略号时默认直接展开到第 2 行，且不可点收起" {
  let tight_title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  // w=230 with archivable + info + more leaves < width("一二三…") on Row 1
  let (t, _) = chat_bar_node_tester(
    tight_title,
    extra_agents=0,
    archivable=true,
    has_jobs=false,
    w=230.0,
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
  for label in ["返回", "对话信息", "更多"] {
    let found = t.semantics().iter().find_first(fn(s) { s.role == @ui.Role::Button && s.label == label })
    guard found is Some(s) else { fail("missing button \{label}") }
    let btn_mid = s.rect.1 + s.rect.3 / 2.0
    assert_true((title_mid - btn_mid).abs() < 0.5, msg="title mid \{title_mid} != \{label} mid \{btn_mid}")
  }
  assert_true(composer_agent_rect(t) is Some(_), msg="agent mark sits above composer")
  assert_eq(bar_node_audit(t), [])
}

///|
test "小屏活动条：对话有服务和后台任务时，打开它们的胶囊位于 composer 上方且有名字（读屏念得出、测试按名字找得到）" {
  let (t, _) = chat_bar_node_tester("短标题", has_jobs=true)
  let keys = t.all(Button, label="服务和后台任务")
  assert_eq(keys.length(), 1, msg="the jobs key, by its name")
  assert_true(keys[0].rect.1 > 400.0, msg="jobs pill sits above composer: \{Repr(keys[0].rect)}")
}

///|
test "小屏顶栏：放不下而直接展开到第 2 行的对话，打开在上次离开的消息：那条消息整条在展开后的顶栏下，不被第 2 行盖住" {
  let tight_title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  let (t, _) = chat_bar_node_tester(tight_title, archivable=true, w=230.0, msg_count=14, at=14.0)
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: tight_title, station_name: "Willow" }
  t.run_for(@ui.move_most_ms)
  let extra = bar_extra_target(bar_ref)
  assert_true(extra > 30.0, msg="must auto-expand on mount")
  let foot = bar_foot_at(290.0) + extra
  let at = t.words().filter(fn(w) { w.0.has_prefix("第4条：") && w.5 > 0.5 }).map(fn(w) { w.2 })
  assert_true(at.length() > 0, msg="the message left at not drawn: \{Repr(t.words().map(fn(w) { (w.0, w.2) }))}")
  assert_true(at[0] >= foot, msg="its first line at \{at[0]}, the bar's foot at \{foot}")
  // (and just under it, as where it was left puts it: not further down by the second row twice)
  assert_true(at[0] < foot + 60.0, msg="its first line at \{at[0]}, the bar's foot at \{foot}")
}

test "小屏顶栏：归档键出现使人头栈刚好放不下时，人头在那一刻一步离开、消失时一步回来，全过程零 audit 告警" {
  let archivable = @signals.signal(false)
  let (t0, _) = chat_bar_node_tester("梳理发布清单", people=1, archivable_on=@signals.signal(false))
  guard bar_button_x(t0, tr("android-chat.info.title")) is Some(end0) else { fail("no 对话信息 in the bar") }
  let people_rects = t0.drawn_rects().filter(fn(r) { r.1 < 60.0 && (r.2 - 19.0).abs() < 0.5 && (r.3 - 19.0).abs() < 0.5 })
  assert_true(people_rects.length() > 0, msg="person drawn at 390")
  let p_end = people_rects[0].0 + people_rects[0].2
  let left = end0 - 8.0 - p_end
  let w = 390.0 - left + 16.0
  let (t, _) = chat_bar_node_tester("梳理发布清单", people=1, archivable_on=archivable, w~)
  assert_true(bar_people_drawn(t), msg="at \{w}: person drawn while there is room")
  archivable.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(!bar_people_drawn(t), msg="at \{w}: person left short of room")
  archivable.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(bar_people_drawn(t), msg="at \{w}: person back when room returns")
  assert_eq(bar_node_audit(t), [])
}

///|
/// Whether the chat's people are drawn in the bar (their faces' rings, 19 across).
fn bar_people_drawn(t : @ui.Tester) -> Bool {
  t.drawn_rects().iter().any(fn(r) { r.1 < 60.0 && (r.2 - 19.0).abs() < 0.5 && (r.3 - 19.0).abs() < 0.5 })
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
test "小屏顶栏：归档键出现使标题放不下 3 字时，实时出现则第 2 行平滑展开；作为订阅首次应答出现则在其布局那一帧直接展开，不在页面横滑中途做展开动画" {
  let title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  let bar_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title, station_name: "Willow" }
  // (the widest bar where 归档 leaves the title less than 3 characters, found once: without it, more)
  let mut lo = 180.0
  let mut hi = 360.0
  while hi - lo > 1.0 {
    let mid = (lo + hi) / 2.0
    chat_bar_node_tester(title, archivable_on=@signals.signal(true), w=mid, msg_count=1) |> ignore
    let open = bar_extra_target(bar_ref) > 30.0
    if open {
      lo = mid
    } else {
      hi = mid
    }
  }
  let w = lo.floor()
  let archivable = @signals.signal(false)
  let (t, _) = chat_bar_node_tester(title, archivable_on=archivable, w~, msg_count=1)
  assert_true(bar_extra_target(bar_ref) < 0.5, msg="at \{w}: its second row open without archive key")
  // live: on its way
  let came = bar_row2_way(t, title, fn() { archivable.set(true) }, @ui.move_most_ms)
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="at \{w}: its second row not opened by archive key")
  let between = came.filter(fn(a) { a > 0.0 && a < 0.99 })
  assert_true(between.length() > 3, msg="at \{w}: live, not on its way: \{Repr(came)}")
  assert_eq(bar_node_audit(t), [])
  // told as an answer (first value as chat opens again): open at once, as it is laid out
  let archivable = @signals.signal(false)
  let (t, _) = chat_bar_node_tester(title, archivable_on=archivable, w~, msg_count=1)
  assert_true(bar_extra_target(bar_ref) < 0.5, msg="at \{w}: its second row open without archive key")
  let told = bar_row2_way(t, title, fn() { @view.answering(fn() { archivable.set(true) }) }, @ui.move_most_ms)
  assert_true(bar_extra_target(bar_ref) > 30.0, msg="at \{w}: its second row not opened by answer")
  let between = told.filter(fn(a) { a > 0.0 && a < 0.99 })
  assert_eq(between, [], msg="at \{w}: an answer's on its way: \{Repr(told)}")
  assert_true(told[told.length() - 1] >= 0.99, msg="at \{w}: \{Repr(told)}")
  assert_eq(bar_node_audit(t), [])
}

///|
test "小屏输入框上方胶囊：station 有图标（glyph、emoji，1.0x 与 1.3x 字号）时状态点在图标右下角，无图标时退回名字前的行内圆点；有 agent 与无 agent 两种胶囊皆然，状态点随连接方式变色、未说时隐藏，零 audit 告警" {
  let cases : Array[(String, String, Bool)] = [("glyph:desktop", "", true), ("", "🍁", true), ("", "", false)]
  for c in cases {
    for scale in [1.0, 1.3] {
      for alone in [false, true] {
        let (icon, emoji, marked) = c
        let via = @signals.signal("direct")
        let (t, _) = chat_bar_node_tester("整理发布清单", font_scale=scale, over=bar_station_as(icon, emoji, via), no_agents=alone)
        let msg = "\{icon}\{emoji} \{scale}x\{if alone { " alone" } else { "" }}"
        // (with an agent: its capsule a button named with both; alone: the station's own, a group of its name)
        let found = if alone {
          t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }).map(fn(g) { g.rect })
        } else {
          match composer_agent_rect(t) {
            Some(r) => [r]
            None => []
          }
        }
        guard found is [whole, ..] else { fail("\{msg}: no capsule") }
        guard bar_words_in(t, "Willow", whole) is Some(name) else { fail("\{msg}: no name in \{Repr(whole)}") }
        // (the station's part of it: from the capsule's start to past the station's name, before the agent's mark)
        let cap = if alone {
          whole
        } else {
          guard bar_words_in(t, "Claude", whole) is Some(agent) else { fail("\{msg}: no agent's name") }
          assert_true(name.0 < agent.0, msg="\{msg}: station left of agent: \{Repr(name)} \{Repr(agent)}")
          let to = name.0 + 24.0
          (whole.0, whole.1, to - whole.0, whole.3)
        }
        for v in ["direct", "relay", "offline", "", "direct"] {
          via.set(v)
          t.run_for(@ui.move_most_ms)
          bar_via_placed(t, cap, name, marked, v, "\{msg} \{v}")
        }
        let audit = t.audit().filter(fn(f) { f.contains("chat_bar_node") || f.contains("agent_badge_node") || f.contains("mark_node") })
        assert_eq(audit, [], msg~)
      }
    }
  }
}


///|
/// The inks the glyphs of the drawn line `words` inside `cap` are drawn in (each once, sorted; none fully clear).
fn bar_words_inks(t : @ui.Tester, words : String, cap : (Double, Double, Double, Double)) -> Array[Int64] {
  let (x, y, w, h) = cap
  let out : Array[Int64] = []
  for r in t.text_runs() {
    guard r.text == words && r.x0 >= x - 0.5 && r.x1 <= x + w + 0.5 && r.top >= y - 0.5 && r.bottom <= y + h + 0.5 else {
      continue
    }
    for g in t.drawn_glyphs() {
      if g.0 >= r.x0 - 0.5 && g.0 <= r.x1 + 0.5 && g.1 >= r.top - 0.5 && g.1 <= r.bottom + 0.5 && (g.2 & 0xFFL) != 0L && !out.contains(g.2) {
        out.push(g.2)
      }
    }
  }
  out.sort()
  out
}

///|
test "小屏输入框上方胶囊：station 名字与 agent 名字同为 Fg 墨色（p.text），有 agent 的合并胶囊与无 agent 的独立 station 胶囊皆然，浅色与深色皆然" {
  for dark in [false, true] {
    for alone in [false, true] {
      let (t, _) = chat_bar_node_tester("整理发布清单", no_agents=alone)
      t.set_dark(dark)
      t.run_for(@ui.move_most_ms)
      let msg = "\{if dark { "dark" } else { "light" }}\{if alone { " alone" } else { "" }}"
      let found = if alone {
        t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }).map(fn(g) { g.rect })
      } else {
        match composer_agent_rect(t) {
          Some(r) => [r]
          None => []
        }
      }
      guard found is [cap, ..] else { fail("\{msg}: no capsule") }
      let text = @sf.theme().p.text
      assert_eq(bar_words_inks(t, "Willow", cap), [text], msg="\{msg}: the station's name")
      if !alone {
        assert_eq(bar_words_inks(t, "Claude", cap), [text], msg="\{msg}: the agent's name")
      }
    }
  }
}

///|
test "小屏输入框上方胶囊：390 宽空间足够时，station 长名字在有 agent 的胶囊和独立 station 胶囊里都完整显示、不截断，零 audit 告警" {
  let station = "tokyo-mac-studio-0"
  for alone in [false, true] {
    let (t, _) = chat_bar_node_tester("整理发布清单", over=bar_station_named(station), no_agents=alone)
    let msg = if alone { "独立 station 胶囊" } else { "agent + station 胶囊" }
    assert_eq(t.lines_of(station), [station], msg~)
    let audit = t.audit().filter(fn(f) { f.contains("chat_bar_node") || f.contains("agent_badge_node") || f.contains("mark_node") })
    assert_eq(audit, [], msg~)
  }
}

///|
test "小屏按按钮位置切换：390x844 首页顶栏筛选/工作区/待处理与对话顶栏更多/信息在按钮下方以 popover 展开，底栏触发器仍走底部抽屉，零 audit 告警" {
  // 1) Home top bar: filter, workspace switcher, attention bell -> popover in upper half (y < 422), 0 audit faults
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  // [☰ 筛选]
  let filter_btn = t.semantics().iter().find_first(fn(s) { s.role == Button && s.label.contains("筛选") && s.rect.1 < 60.0 }).unwrap()
  t.tap(filter_btn.rect.0 + filter_btn.rect.2 / 2.0, filter_btn.rect.1 + filter_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  let (_, filter_y) = t.find("全部会话").unwrap()
  assert_true(filter_y < 422.0, msg="home filter opens as popover in upper half: y=\{filter_y}")
  assert_eq(t.audit(), [], msg="home filter audit")
  t.back()
  t.run_for(@ui.move_most_ms)
  // [⌄ 星火工作室]
  let ws_btn = t.semantics().iter().find_first(fn(s) { s.role == Button && s.label == "星火工作室" && s.rect.1 < 60.0 }).unwrap()
  t.tap(ws_btn.rect.0 + ws_btn.rect.2 / 2.0, ws_btn.rect.1 + ws_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  let ws_dlg = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Dialog }).unwrap()
  assert_true(ws_dlg.rect.1 < 422.0 && ws_dlg.rect.1 + ws_dlg.rect.3 < 650.0, msg="home workspace opens as popover hugging content: \{Repr(ws_dlg.rect)}")
  assert_eq(t.audit(), [], msg="home workspace audit")
  t.back()
  t.run_for(@ui.move_most_ms)
  // [🔔 待处理]
  let bell_btn = t.semantics().iter().find_first(fn(s) { s.role == Button && s.label == tr("web-main.attention.entry") && s.rect.1 < 60.0 }).unwrap()
  t.tap(bell_btn.rect.0 + bell_btn.rect.2 / 2.0, bell_btn.rect.1 + bell_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  let bell_dlg = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Dialog }).unwrap()
  assert_true(bell_dlg.rect.1 < 422.0, msg="home attention opens as popover in upper half: \{Repr(bell_dlg.rect)}")
  assert_eq(t.audit(), [], msg="home attention audit")
  t.back()
  t.run_for(@ui.move_most_ms)

  // 2) Chat top bar [···] & [ⓘ] -> popover in upper half; bottom bar [+] -> bottom sheet (y > 422)
  let (tc, _) = chat_bar_node_tester("梳理发布清单")
  // [···]
  let more_btn = tc.semantics().iter().find_first(fn(s) { s.role == Button && s.label == tr("common.more") && s.rect.1 < 60.0 }).unwrap()
  tc.tap(more_btn.rect.0 + more_btn.rect.2 / 2.0, more_btn.rect.1 + more_btn.rect.3 / 2.0)
  tc.run_for(@ui.move_most_ms)
  let (_, more_y) = tc.find("重命名").unwrap()
  assert_true(more_y < 422.0, msg="chat more opens as popover in upper half: y=\{more_y}")
  assert_eq(tc.audit(), [], msg="chat more audit")
  tc.back()
  tc.run_for(@ui.move_most_ms)
  // [ⓘ]
  let info_btn = tc.semantics().iter().find_first(fn(s) { s.role == Button && s.label == tr("android-chat.info.title") && s.rect.1 < 60.0 }).unwrap()
  tc.tap(info_btn.rect.0 + info_btn.rect.2 / 2.0, info_btn.rect.1 + info_btn.rect.3 / 2.0)
  tc.run_for(@ui.move_most_ms)
  let info_dlg = tc.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Dialog }).unwrap()
  assert_true(info_dlg.rect.1 < 422.0, msg="chat info opens as popover in upper half: \{Repr(info_dlg.rect)}")
  assert_eq(tc.audit(), [], msg="chat info audit")
  tc.back()
  tc.run_for(@ui.move_most_ms)
  // bottom composer [+] -> bottom sheet
  let plus_btn = tc.semantics().iter().find_first(fn(s) { s.role == Button && s.rect.1 > 700.0 && s.rect.0 < 80.0 }).unwrap()
  tc.tap(plus_btn.rect.0 + plus_btn.rect.2 / 2.0, plus_btn.rect.1 + plus_btn.rect.3 / 2.0)
  tc.run_for(@ui.move_most_ms)
  let sheet_dlg = tc.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Dialog }).unwrap()
  assert_true(sheet_dlg.rect.1 > 422.0, msg="composer + stays bottom sheet: \{Repr(sheet_dlg.rect)}")
}

///|
test "小屏窄窗 320x568 + 1.3x 字号：首页与对话顶栏 popover 全部在视口内且零截断溢出" {
  // Home top bar popovers at 320x568 @ 1.3x
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=320.0, h=568.0, platform=2)
  t.set_font_scale(1.3)
  t.run_for(@ui.move_most_ms)
  for label in ["筛选", "星火工作室", tr("web-main.attention.entry")] {
    let btn = t.semantics().iter().find_first(fn(s) { s.role == Button && s.label.contains(label) && s.rect.1 < 60.0 }).unwrap()
    t.tap(btn.rect.0 + btn.rect.2 / 2.0, btn.rect.1 + btn.rect.3 / 2.0)
    t.run_for(@ui.move_most_ms)
    let dlg = t.semantics().iter().find_first(fn(s) { !s.hidden && (s.role == Dialog || s.role == Menu) }).unwrap()
    assert_true(dlg.rect.0 >= 0.0 && dlg.rect.0 + dlg.rect.2 <= 320.0 + 0.5, msg="home \{label} width within 320: \{Repr(dlg.rect)}")
    assert_true(dlg.rect.1 >= 0.0 && dlg.rect.1 + dlg.rect.3 <= 568.0 + 0.5, msg="home \{label} height within 568: \{Repr(dlg.rect)}")
    assert_eq(t.fixed_outgrown(), [], msg="home \{label} fixed_outgrown")
    assert_eq(t.squeeze_faults(), [], msg="home \{label} squeeze_faults")
    assert_eq(t.audit(), [], msg="home \{label} audit")
    t.back()
    t.run_for(@ui.move_most_ms)
  }

  // Chat top bar popovers at 320x568 @ 1.3x
  let (tc, _) = chat_bar_node_tester("梳理发布清单", w=320.0, h=568.0, font_scale=1.3)
  for label in [tr("common.more"), tr("android-chat.info.title")] {
    let btn = tc.semantics().iter().find_first(fn(s) { s.role == Button && s.label == label && s.rect.1 < 60.0 }).unwrap()
    tc.tap(btn.rect.0 + btn.rect.2 / 2.0, btn.rect.1 + btn.rect.3 / 2.0)
    tc.run_for(@ui.move_most_ms)
    let dlg = tc.semantics().iter().find_first(fn(s) { !s.hidden && (s.role == Dialog || s.role == Menu) }).unwrap()
    assert_true(dlg.rect.0 >= 0.0 && dlg.rect.0 + dlg.rect.2 <= 320.0 + 0.5, msg="chat \{label} width within 320: \{Repr(dlg.rect)}")
    assert_true(dlg.rect.1 >= 0.0 && dlg.rect.1 + dlg.rect.3 <= 568.0 + 0.5, msg="chat \{label} height within 568: \{Repr(dlg.rect)}")
    assert_eq(tc.fixed_outgrown(), [], msg="chat \{label} fixed_outgrown")
    assert_eq(tc.squeeze_faults(), [], msg="chat \{label} squeeze_faults")
    assert_eq(tc.audit(), [], msg="chat \{label} audit")
    tc.back()
    tc.run_for(@ui.move_most_ms)
  }
}

///|
test "小屏悬浮液态玻璃底抽屉（+ 附件）：390x844 中文对称内缩与三列对齐、显示最近照片单行，390x844 英文与 320x568 中文零挤压零圆角告警" {
  let open_attach = fn(w : Double, h : Double, locale : String) -> @ui.Tester raise {
    new_run()
    @sf.presenters_reset()
    let src = fixture("chat")
    wide_src.val = Some(src)
    open_chat(chat_a)
    let t = @ui.Tester::new(
      fn(c) { view(c, src) },
      tree=app_tree(src),
      w~,
      h~,
      platform=2,
      env=[("MBUI_LOCALE", locale)],
    )
    t.run_for(@ui.move_most_ms)
    guard t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Button && s.label == tr("web-main.composer.attach") }) is Some(plus_btn) else {
      fail("plus button not found at \{w}x\{h} \{locale}")
    }
    t.tap(plus_btn.rect.0 + plus_btn.rect.2 / 2.0, plus_btn.rect.1 + plus_btn.rect.3 / 2.0)
    t.run_for(@ui.move_most_ms)
    t
  }

  // 1) 390x844 zh-CN: symmetric 6pt window_in glass inset + 16pt panel_card_in -> left 22, right 368, bottom 822; single-line label
  let tz = open_attach(390.0, 844.0, "zh-CN")
  guard tz.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Button && s.label == tr("android-chat.attach.camera") }) is Some(cam) else {
    let btns = tz.semantics().filter(fn(s) { !s.hidden && s.role == Button }).map(fn(s) { "\{s.label}@\{@ui.rect_text(s.rect)}" })
    fail("camera tile not found (want \{tr("android-chat.attach.camera")}); buttons=\{Repr(btns)}")
  }
  guard tz.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Button && s.label == tr("android-chat.attach.photos") }) is Some(photos) else {
    fail("photos tile not found")
  }
  guard tz.semantics().iter().find_first(fn(s) { !s.hidden && s.role == Button && s.label == tr("web-pages.chat.files") }) is Some(st_files) else {
    fail("station files tile not found")
  }
  assert_true((cam.rect.0 - 22.0).abs() < 0.5, msg="camera left at 22pt: \{Repr(cam.rect)}")
  assert_true((photos.rect.0 - 22.0).abs() < 0.5, msg="photos tile left at 22pt: \{Repr(photos.rect)}")
  assert_true((cam.rect.0 - photos.rect.0).abs() < 0.5, msg="strip left aligns with bottom tiles")
  assert_true((st_files.rect.0 + st_files.rect.2 - 368.0).abs() < 0.5, msg="rightmost tile ends at 368pt: \{Repr(st_files.rect)}")
  assert_true((photos.rect.1 + photos.rect.3 - 822.0).abs() < 0.5, msg="bottom tiles end at 822pt (16pt above 838pt glass bottom): \{Repr(photos.rect)}")
  assert_eq(tz.lines_of("显示最近照片"), ["显示最近照片"], msg="显示最近照片 fits on one line: \{Repr(tz.lines_of("显示最近照片"))}")
  assert_eq(tz.squeeze_faults(), [], msg="zh 390 squeeze_faults")
  assert_eq(tz.corner_faults(), [], msg="zh 390 corner_faults")
  assert_eq(tz.audit(), [], msg="zh 390 audit")

  // 2) 390x844 en-US: Photos & videos and Show recent photos clean, no squeeze/corner/audit faults
  let te = open_attach(390.0, 844.0, "en-US")
  assert_true(te.find("Photos & videos") is Some(_), msg="en Photos & videos shown")
  assert_true(te.find("Show recent photos") is Some(_), msg="en Show recent photos shown")
  assert_eq(te.squeeze_faults(), [], msg="en 390 squeeze_faults")
  assert_eq(te.corner_faults(), [], msg="en 390 corner_faults")
  assert_eq(te.audit(), [], msg="en 390 audit")

  // 3) 320x568 zh-CN: narrow screen clean, no squeeze/corner/audit faults
  let tn = open_attach(320.0, 568.0, "zh-CN")
  assert_true(tn.find("Station 文件") is Some(_), msg="zh 320 Station 文件 shown")
  assert_true(tn.find("显示最近照片") is Some(_), msg="zh 320 显示最近照片 shown")
  assert_eq(tn.squeeze_faults(), [], msg="zh 320 squeeze_faults: \{Repr(tn.squeeze_faults())}")
  assert_eq(tn.corner_faults(), [], msg="zh 320 corner_faults: \{Repr(tn.corner_faults())}")
  assert_eq(tn.audit(), [], msg="zh 320 audit: \{Repr(tn.audit())}")
}

///|
test "小屏输入框上方合并胶囊：单模型与多模型（390 与 320 宽）只渲染一颗合并胶囊且 Station 在最左，390 宽多模型+后台任务下站名完整不截断，点击多模型胶囊弹出 station 抽屉并可进入指定模型详情，零 audit 与触控告警" {
  let station = "Office-Host-2"
  let two_agents = fn(n : String, tp : Topic) -> Topic {
    let tp = bar_station_named(station)(n, tp)
    guard n == "chat" && tp.value is Some(Object(m)) else { return tp }
    let o = m.copy()
    o["agents"] = Json::array([
      {
        "session": {
          "key": "s-c1",
          "runtime": "agy",
          "maker": { "id": "google", "name": "Google" },
          "agentText": "Gemini 4 Neon",
          "statusText": "做完了",
          "tone": "green",
        },
        "status": "idle",
      },
      {
        "session": {
          "key": "s-c2",
          "runtime": "claude",
          "maker": { "id": "anthropic", "name": "Anthropic" },
          "agentText": "Opus 5.5",
          "statusText": "空闲",
          "tone": "neutral",
        },
        "status": "idle",
      },
    ])
    { ..tp, value: Some(Json::object(o)) }
  }
  // 1) 390 wide with 2 agents + jobs: single merged capsule, Office-Host-2 complete, tap opens station_agents sheet
  let (t, _) = chat_bar_node_tester("整理发布清单", has_jobs=true, over=two_agents, w=390.0)
  let caps = t.all(Button).filter(fn(b) { b.rect.1 > 400.0 && b.label.contains(station) })
  assert_eq(caps.length(), 1, msg="390 multi-agent: single merged capsule: \{Repr(t.all(Button).filter(fn(b) { b.rect.1 > 400.0 }))}")
  assert_true(caps[0].label.contains("Gemini 4 Neon") && caps[0].label.contains("Opus 5.5"), msg="merged label: \{caps[0].label}")
  assert_eq(t.lines_of(station), [station], msg="390 multi-agent: station name complete without truncation")
  assert_true(caps[0].rect.2 >= 140.0, msg="390 multi-agent: merged capsule not crushed: \{Repr(caps[0].rect)}")
  assert_true(
    bar_words_in(t, "Gemini 4 Neon", caps[0].rect) is None && bar_words_in(t, "Opus 5.5", caps[0].rect) is None,
    msg="390 multi-agent: symmetric icon-only agent group without asymmetric partial agent names",
  )
  assert_eq(t.audit().filter(fn(f) { f.contains("chat_bar_node") || f.contains("agent_badge_node") || f.contains("room") }), [], msg="390 multi-agent audit")
  // Tap merged capsule -> opens station_agents sheet with Station entry and both agent rows
  @sf.presenters_reset()
  let (cx, cy, cw, ch) = caps[0].rect
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting(), msg="tapping merged capsule opens sheet")
  assert_true(t.find("Gemini 4 Neon") is Some(_), msg="sheet lists first agent")
  guard t.find("Opus 5.5") is Some((ag2_x, ag2_y)) else { fail("sheet lists second agent") }
  assert_eq(t.audit().filter(fn(f) { f.contains("sheets") || f.contains("room") }), [], msg="station_agents sheet audit")
  // Tap second agent row -> opens open_agent sheet for Opus 5.5
  t.tap(ag2_x, ag2_y)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting(), msg="agent detail sheet open")
  assert_true(t.find("Opus 5.5") is Some(_), msg="agent detail sheet shows Opus 5.5")
  assert_true(t.find(tr("android-chat.agent.history")) is Some(_), msg="agent detail sheet shows history row")

  // 1b) 320 wide: station name still complete and capsule keeps symmetric icon-only agents
  let (t_tight, _) = chat_bar_node_tester("整理发布清单", has_jobs=true, over=two_agents, w=320.0)
  let caps_tight = t_tight.all(Button).filter(fn(b) { b.rect.1 > 400.0 && b.label.contains(station) })
  assert_eq(caps_tight.length(), 1, msg="320 multi-agent: single merged capsule")
  assert_eq(t_tight.lines_of(station), [station], msg="320 multi-agent: station name still complete")
  assert_true(caps_tight[0].rect.2 >= 140.0, msg="320 multi-agent: capsule keeps station + both icons: \{Repr(caps_tight[0].rect)}")
  assert_true(
    bar_words_in(t_tight, "Gemini 4 Neon", caps_tight[0].rect) is None &&
    bar_words_in(t_tight, "Opus 5.5", caps_tight[0].rect) is None,
    msg="320 multi-agent: symmetric icon-only agent group",
  )

  // 2) 320 wide + 1.3x font scale + station without icon/via: zero audit/room faults
  let via_empty = @signals.signal("")
  let bare_two = fn(n : String, tp : Topic) -> Topic {
    bar_station_as("", "", via_empty)(n, two_agents(n, tp))
  }
  for w in [390.0, 320.0] {
    for scale in [1.0, 1.3] {
      let (t2, _) = chat_bar_node_tester("整理发布清单", has_jobs=true, over=bare_two, w~, font_scale=scale)
      let caps2 = t2.all(Button).filter(fn(b) { b.rect.1 > 400.0 && b.label.contains(station) })
      assert_eq(caps2.length(), 1, msg="w=\{w} scale=\{scale}: single merged capsule")
      assert_eq(
        t2.audit().filter(fn(f) { f.contains("chat_bar_node") || f.contains("agent_badge_node") || f.contains("room") }),
        [],
        msg="w=\{w} scale=\{scale} audit",
      )
    }
  }
}
