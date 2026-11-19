// 大屏 (1280×800): what settles where it is, nothing set moving by what no hand did there. A chat switched to while
// another field keeps the cursor (the sidebar's search) has its composer laid out as it rests from its first frame,
// never as the chat left had it a moment after its cursor left (sfpages' composer: composing.let_go is the chat's own).
// The bar's buttons go along their row as the side panel's switch comes and goes beside them (sfdesk's
// chat_bar_wide_node). The sidebar takes what the stations bring in while it catches up (ChatsView's syncing) at once
// (sfpages' sidebar_node, RowsMotion). A chat the device kept nothing of, drawn empty, has its first page there at once
// as the station answers it (sfbase's chat_list, paged_in).

///|
/// The fixture's chat s-c1 on 大屏 at rest, its page made as nodes where `nodes` says, its frames a
/// display's at 60 a second; the fixture's source as `over` makes it.
fn ms_open(nodes : Bool, over? : (String, Map[String, Json], Topic) -> Topic = fn(_, _, t) { t }) -> @ui.Tester {
  new_run()
  @sfbase.chat_page_nodes.set(nodes)
  let base = fixture("chat")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) { over(name, params, base.topic(name, params).get().snapshot()) },
  }
  open_fixture_over("chat", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.set_frame_period(dk_frame_ms)
  nav_rested(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The lowest words of the chat's list drawn now (over its composer), their top.
fn ms_list_low(t : @ui.Tester) -> Double {
  let mut y = 0.0
  for w in t.words() {
    if w.5 > 0.05 && w.1 > 320.0 && w.2 < 690.0 && w.2 > y {
      y = w.2
    }
  }
  y
}

///|
/// Where the composer's field is drawn now (the field that says 发消息), if anywhere.
fn ms_composer_field(t : @ui.Tester) -> (Double, Double, Double, Double)? {
  match t.semantics().filter(fn(s) { s.role == @ui.Role::TextField && s.label == "发消息" }) {
    [f, ..] => Some(f.rect)
    _ => None
  }
}

///|
/// What a drive's run said of its steps.
fn ms_drive_said(logs : Array[String]) -> String {
  logs.filter(fn(l) { l.has_prefix("DRIVE") }).join(" | ")
}

///|
/// The chat on top now, by its session.
fn ms_top() -> String {
  match app.nav.top() {
    Chat(r) => r.session
    _ => ""
  }
}

///|
test "大屏, either chat's page: a chat switched to from the sidebar while its search keeps the cursor has its composer as it rests from its first frame, the list's last row still; the chat left's composer, the cursor gone from it a moment before, lets go of none of it there" {
  for nodes in [false, true] {
    let at = if nodes { "新对话页" } else { "旧对话页" }
    let t = ms_open(nodes)
    guard composer_field(t) is Some((x, y, w, h)) else { fail("\{at}: no composer's field") }
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_true(composer_focused(), msg="\{at}: the cursor in s-c1's composer")
    // (the list's search pulled into view over its first row and pressed: the cursor in it)
    let logs = t.drive("wheelat -400 夜里的构建又失败了\nwait 600\ntap 搜索\nwait 600\nexit\n")
    guard !logs.iter().any(fn(l) { l.has_prefix("DRIVE") && l.contains("FAIL") }) else {
      fail("\{at}: the search not pressed: \{ms_drive_said(logs)}")
    }
    let search = t.focused().map(fn(f) { f.label }).unwrap_or("")
    assert_true(search.contains("搜索"), msg="\{at}: the cursor in the search, not \{search}")
    // every frame from the press on the row of s-c2 till its composer would have let go of a box and closed it
    let seen : Array[(Double, String, (Double, Double, Double, Double)?, Double)] = []
    let look = fn(t : @ui.Tester) { seen.push((t.time(), ms_top(), ms_composer_field(t), ms_list_low(t))) }
    let script = "tap 首页的列表改成按天分组\nwait \{(@sfpages.let_go_ms + @ui.move_most_ms + 100.0).to_int()}\nexit\n"
    let logs = t.drive(script, each=look)
    guard !logs.iter().any(fn(l) { l.has_prefix("DRIVE") && l.contains("FAIL") }) else {
      fail("\{at}: s-c2 not pressed: \{ms_drive_said(logs)}")
    }
    let on = seen.filter(fn(s) { s.1 == "s-c2" && s.2 is Some(_) })
    guard on is [first, ..] else { fail("\{at}: s-c2's composer never drawn") }
    let report = on.map(fn(s) { "\{(s.0 * 10.0).round() / 10.0}: \{Repr(s.2)} \{s.3}" }).join("\n")
    for s in on {
      assert_eq(s.2, first.2, msg="\{at}: s-c2's composer moved at \{s.0} after it was first drawn\n\{report}")
      assert_eq(s.3, first.3, msg="\{at}: s-c2's last row moved at \{s.0}\n\{report}")
    }
    assert_true(
      on[on.length() - 1].0 - first.0 >= @sfpages.let_go_ms + @ui.move_most_ms,
      msg="\{at}: looked at past its let go\n\{report}",
    )
    let still = t.focused().map(fn(f) { f.label }).unwrap_or("")
    assert_true(still.contains("搜索"), msg="\{at}: the search kept the cursor, not \{still}")
  }
}

///|
/// Where the bar's buttons stand against the side panel as a frame draws them: how far 更多 is from the panel's own
/// 收起侧栏 (or its tab's 关闭, the first of them drawn); none while the panel is not drawn.
fn ms_bar_gap(t : @ui.Tester) -> Double? {
  let more = @sf.t("common.more")
  let buttons = t.all(Button).filter(fn(b) { b.rect.1 < 50.0 })
  guard buttons.iter().find_first(fn(b) { b.label == more }) is Some(m) else { return None }
  match buttons.iter().find_first(fn(b) { b.label == "收起侧栏" || b.label.has_prefix("关闭 ") }) {
    Some(p) => Some(p.rect.0 - m.rect.0)
    None => None
  }
}

///|
test "大屏, either chat's page: the side panel opened and closed by its switch, the bar's buttons go with it along their row as its switch comes and goes, never 8 in a frame against it, never squeezed" {
  for nodes in [false, true] {
    let at = if nodes { "新对话页" } else { "旧对话页" }
    let t = ms_open(nodes)
    let info = @sf.t("web-pages.chat.info")
    let more = @sf.t("common.more")
    for open in [true, false] {
      let way = if open { "opening" } else { "closing" }
      let seen : Array[(Double, Double?, Double, Double)] = []
      let look = fn(t : @ui.Tester) {
        let h = fn(label) {
          match wide_bar_button(t, label) {
            Some(r) => r.3
            None => -1.0
          }
        }
        seen.push((t.time(), ms_bar_gap(t), h(info), h(more)))
      }
      look(t)
      let script = if open { "tap icon:panel-open\nwait 700\nexit\n" } else { "tap icon:panel-close\nwait 700\nexit\n" }
      let logs = t.drive(script, each=look)
      guard !logs.iter().any(fn(l) { l.has_prefix("DRIVE") && l.contains("FAIL") }) else {
        fail("\{at}, \{way}: the switch not pressed: \{ms_drive_said(logs)}")
      }
      let report = seen.map(fn(s) { "\{(s.0 * 10.0).round() / 10.0}: \{Repr(s.1)} \{s.2} \{s.3}" }).join("\n")
      let gaps = seen.filter_map(fn(s) { s.1 })
      assert_true(gaps.length() > 10, msg="\{at}, \{way}: the panel drawn on its way\n\{report}")
      for i in 1..<gaps.length() {
        let d = gaps[i] - gaps[i - 1]
        assert_true(d.abs() <= 8.0, msg="\{at}, \{way}: 更多 stepped \{d} against the panel in a frame\n\{report}")
      }
      for s in seen {
        assert_true(s.2 == 32.0 && s.3 == 32.0, msg="\{at}, \{way}: 对话信息 \{s.2} and 更多 \{s.3} high at \{s.0}\n\{report}")
      }
    }
  }
}

///|
/// `chats`' value as the core sends it with the rows `new` put first in its first day, that day's next two rows
/// swapped where `swap`, and what is still coming said where `syncing`.
fn ms_chats(v : Json, new : Array[(String, String)], swap : Bool, syncing : Bool) -> Json {
  guard v is Object(o) && o.get("days") is Some(Array(days)) && days.length() > 0 else { return v }
  guard days[0] is Object(d0) && d0.get("items") is Some(Array(rows)) && rows.length() > 2 else { return v }
  let out = o.copy()
  if syncing {
    out["syncing"] = Json::string("正在同步")
  } else {
    out.remove("syncing")
  }
  let items : Array[Json] = new.map(fn(n) {
    guard rows[0] is Object(r0) else { return rows[0] }
    let r = r0.copy()
    r["id"] = Json::string(n.0)
    r["session"] = Json::string(n.0)
    r["clientKey"] = Json::string("")
    r["title"] = Json::string(n.1)
    Json::object(r)
  })
  let rest = rows.copy()
  if swap {
    let a = rest[0]
    rest[0] = rest[1]
    rest[1] = a
  }
  for r in rest {
    items.push(r)
  }
  let d = d0.copy()
  d["items"] = Json::array(items)
  let ds = days.copy()
  ds[0] = Json::object(d)
  out["days"] = Json::array(ds)
  Json::object(out)
}

///|
test "大屏: the sidebar while what changed since the app was last with the stations is still coming (syncing): chats come and move there at once, the batch that ends it too; a chat that comes after it comes on its way" {
  let stage = @signals.signal(0)
  let t = ms_open(false, over=fn(name, _, tp) {
    guard name == "chats" && tp.value is Some(v) else { return tp }
    let n1 = ("s-n1", "离线时新开的对话")
    let n2 = ("s-n2", "同步最后一批")
    let n3 = ("s-n3", "同步完后的新对话")
    let value = match stage.get() {
      // (the first said: what the device kept, still catching up)
      0 => ms_chats(v, [], false, true)
      // (a batch brought in: a chat new to it, two moved)
      1 => ms_chats(v, [n1], true, true)
      // (the last batch, ending it)
      2 => ms_chats(v, [n2, n1], true, false)
      // (caught up: a chat said now)
      _ => ms_chats(v, [n3, n2, n1], true, false)
    }
    { ..tp, value: Some(value) }
  })
  t.ways_set_out() |> ignore
  let ways = []
  for s in 1..=3 {
    stage.set(s)
    t.run_for(@ui.move_most_ms)
    ways.push(t.ways_set_out().map(fn(w) { "\{w.kind} \{w.made} \{w.part}" }))
  }
  let words = fn(w : String) { t.words().iter().any(fn(x) { x.0 == w && x.1 < 300.0 && x.5 > 0.5 }) }
  assert_true(words("离线时新开的对话") && words("同步最后一批") && words("同步完后的新对话"), msg="the chats in the sidebar")
  assert_eq(ways[0], [], msg="a batch while catching up")
  assert_eq(ways[1], [], msg="the batch that ends it")
  assert_true(ways[2].length() > 0, msg="a chat come after it, on its way: none set out")
}

///|
test "大屏, the old chat's page: a chat the device kept nothing of, drawn empty, its first page there at once as the station answers, what is at work in it too" {
  let stage = @signals.signal(0)
  let t = ms_open(false, over=fn(name, params, tp) {
    guard name == "chat" && params.get("session") is Some(String("s-c1")) && tp.value is Some(Object(o)) else {
      return tp
    }
    let e = o.copy()
    if stage.get() == 0 {
      // (none of it kept: drawn empty till the station answers)
      e["messages"] = Json::array([])
      e.remove("firstEntry")
      e["more"] = Json::boolean(false)
      // (nothing at work in it as far as the device knows)
      e.remove("stateText")
      e["agents"] = Json::array([])
    } else {
      // (its last page, more before it, where it stands and its agent at work)
      e["more"] = Json::boolean(true)
      return { ..tp, value: Some(@sffixture.with_state(@sffixture.with_working(Json::object(e)), ("正在处理", "", ""))) }
    }
    { ..tp, value: Some(Json::object(e)) }
  })
  assert_true(dk_at(t, dk_last) is None, msg="drawn empty first")
  let seen : Array[(Double, (Double, Double, Double)?, Double)] = []
  let look = fn() { seen.push((t.time(), dk_at(t, dk_last), ms_list_low(t))) }
  t.each_frame(Some(look))
  stage.set(1)
  t.run_shown(@ui.move_most_ms + 100.0)
  t.each_frame(None)
  let report = seen.map(fn(s) { "\{(s.0 * 10.0).round() / 10.0}: \{Repr(s.1)} \{s.2}" }).join("\n")
  guard seen is [first, ..] && first.1 is Some(_) else { fail("its last row not there in the frame it came\n\{report}") }
  for s in seen {
    assert_eq(s.1, first.1, msg="its last row moved at \{s.0}\n\{report}")
    assert_eq(s.2, first.2, msg="its list's foot moved at \{s.0}\n\{report}")
  }
}

///|
test "大屏: chat_bar_wide_node settles at once when station, people, agents and chatJobs arrive late outside a transition" {
  let stage = @signals.signal(0)
  let jobs = wide_bar_jobs("")
  let t = ms_open(true, over=fn(name, params, tp) {
    if name == "chatJobs" {
      if stage.get() > 0 {
        return jobs(name, tp)
      }
      return tp
    }
    guard name == "chat" && params.get("session") is Some(String("s-c1")) && tp.value is Some(Object(o)) else {
      return tp
    }
    let e = o.copy()
    if stage.get() == 0 {
      e["agents"] = Json::array([])
      e["people"] = Json::array([])
      e["archivable"] = Json::boolean(false)
    } else {
      e["archivable"] = Json::boolean(true)
    }
    { ..tp, value: Some(Json::object(e)) }
  })
  let archive = @sf.t("web-pages.chat.archive")
  assert_true(wide_bar_button(t, archive) is None, msg="archive absent before late chat arrives")
  t.ways_set_out() |> ignore
  stage.set(1)
  t.run_for(@ui.move_most_ms)
  let ways = t.ways_set_out().map(fn(w) { "\{w.kind} \{w.made} \{w.part}" })
  assert_eq(ways, [], msg="late chat + chatJobs arrival must set out zero ways")
  assert_true(wide_bar_button(t, archive) is Some(_), msg="archive button rendered after late arrival")
}

///|
test "大屏: sidebar chat_row_node background status, tone and unread updates settle at once with zero ways" {
  let stage = @signals.signal(0)
  let t = ms_open(true, over=fn(name, _, tp) {
    guard name == "chats" && tp.value is Some(Object(o)) && o.get("days") is Some(Array(days)) && days.length() > 0 else {
      return tp
    }
    guard days[0] is Object(d0) && d0.get("items") is Some(Array(rows)) && rows.length() > 0 else { return tp }
    guard rows[0] is Object(r0) else { return tp }
    let r = r0.copy()
    if stage.get() == 0 {
      r["unread"] = Json::boolean(false)
      r["tone"] = Json::string("")
      r["state"] = Json::string("")
      r.remove("stateText")
    } else {
      r["unread"] = Json::boolean(true)
      r["tone"] = Json::string("attention")
      r["state"] = Json::string("need")
      r["stateText"] = Json::string("等待回复")
    }
    let next_rows = rows.copy()
    next_rows[0] = Json::object(r)
    let d = d0.copy()
    d["items"] = Json::array(next_rows)
    let ds = days.copy()
    ds[0] = Json::object(d)
    let out = o.copy()
    out["days"] = Json::array(ds)
    { ..tp, value: Some(Json::object(out)) }
  })
  t.ways_set_out() |> ignore
  stage.set(1)
  t.run_for(@ui.move_most_ms)
  let ways = t.ways_set_out().map(fn(w) { "\{w.kind} \{w.made} \{w.part}" })
  assert_eq(ways, [], msg="sidebar chat_row_node background state update must set out zero ways")
}

///|
test "大屏, 新对话页: unread line disappearing from chat_body_node sets out zero ways (structural placeholder is not a live cause)" {
  let stage = @signals.signal(0)
  let t = ms_open(true, over=fn(name, params, tp) {
    guard name == "chat" && params.get("session") is Some(String("s-c1")) && tp.value is Some(Object(o)) else {
      return tp
    }
    guard o.get("messages") is Some(Array(msgs)) && msgs.length() > 0 else { return tp }
    let last_seq = match msgs[msgs.length() - 1] {
      Object(m) => m.get("seq")
      _ => None
    }
    let e = o.copy()
    if stage.get() == 0 {
      match last_seq {
        Some(seq) => e["unreadLine"] = seq
        None => ()
      }
    } else {
      e.remove("unreadLine")
    }
    { ..tp, value: Some(Json::object(e)) }
  })
  let label = @sf.t("web-main.chat.unreadLine")
  let has_line = fn() { t.words().iter().any(fn(w) { w.0 == label && w.5 > 0.5 }) }
  assert_true(has_line(), msg="unread line visible initially")
  t.ways_set_out() |> ignore
  stage.set(1)
  t.run_for(@ui.move_most_ms)
  let ways = t.ways_set_out().map(fn(w) { "\{w.kind} \{w.made} \{w.part}" })
  assert_eq(ways, [], msg="removing unread line must set out zero ways")
  assert_true(!has_line(), msg="unread line gone")
}
