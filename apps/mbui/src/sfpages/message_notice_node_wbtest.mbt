// What still.fail said as nodes (message_notice_node.mbt's notice_said_node) set beside the old view's (message.mbt
// message_row: system_notice) on the same fixture: closed on one line and open, a failure in red with what failed said
// of it, · 安装 and · 上报 (and each under way), 取消 while its agent waits to retry and 重试 on a failed turn (and under
// way, and read only), a chat's run changed (whole, what changed, open), a profile's link, a chat opened; wide and
// narrow, at 1.3; and what each press asks of the core.

///|
/// One of the fixture's notices (seq 9, ts9): `words` (its Markdown's tree, `md`), a failure (`failed`), what failed
/// said (`detail`); about `profile` (`link` where its link starts, or `profile_action`, what to do of it at its end); a runtime the station lacks (`install`); reportable;
/// its agent waiting to retry (`retry`), or its failed turn to try again (`again`); a chat's run changed (`short`, `lines`,
/// `sides`); failures said alike folded into it (`count` of them, the last at `last`).
fn nt_msg(
  words? : String = "Willow 的 codex 这一轮超时了，已经停下",
  md? : Json? = None,
  failed? : Bool = false,
  detail? : String = "",
  link? : Int = -1,
  profile_action? : String = "",
  profile? : String = "p1",
  install? : Bool = false,
  reportable? : Bool = false,
  retry? : Bool = false,
  again? : Bool = false,
  reassign? : Bool = false,
  short? : String = "",
  lines? : Array[String] = [],
  sides? : Json? = None,
  count? : Int = 1,
  last? : Int = 9,
) -> Message {
  let n : Map[String, Json] = { "failed": Json::boolean(failed), "words": Json::string(words) }
  if count > 1 {
    n["count"] = Json::number(count.to_double())
    n["lastSeq"] = Json::number(last.to_double())
  }
  // (as the core reads its words: one paragraph, where it says no other)
  n["md"] = md.unwrap_or([["p", [[0, words.length()]]]])
  if detail != "" {
    n["detail"] = Json::string(detail)
  }
  if link >= 0 {
    n["linkAt"] = Json::number(link.to_double())
  }
  if profile_action != "" {
    n["profileAction"] = Json::string(profile_action)
  }
  if retry {
    n["retrySession"] = "s-c1"
  }
  if again {
    n["againSession"] = "s-c1"
  }
  if reassign {
    n["reassignSession"] = "s-c1"
  }
  if short != "" {
    n["short"] = Json::string(short)
  }
  if lines.length() > 0 {
    n["lines"] = Json::array(lines.map(fn(l) { Json::string(l) }))
  }
  if sides is Some(d) {
    n["sides"] = d
  }
  @sfbase.message_of({
    "seq": 9,
    "thread": 7,
    "ts": "ts9",
    "authorKind": "ember",
    "system": true,
    "author": "still.fail",
    "text": Json::string(words),
    "by": { "name": "still.fail" },
    "profile": if link >= 0 || profile_action != "" { Json::string(profile) } else { "" },
    "install": if install {
      { "runtime": "codex", "state": "missing", "title": "Willow 上没有 codex", "action": "安装" }
    } else {
      Json::null()
    },
    "reportable": reportable,
    "notice": Json::object(n),
    "chats": [{ "href": "https://app.still.fail/o/ws1/st1/s-c2", "title": "共享调试：配对后连不上" }],
    "createdAt": 9,
    "time": @sffixture.ago("1 分钟前", "2026-11-11 21:07"),
  })
}

///|
/// The core's tree of a notice that a chat was opened (sessions/opened.ts sayOpened): its link to the chat.
fn nt_opened() -> Message {
  let link = "https://app.still.fail/o/ws1/st1/s-c2"
  let words = "已创建对话：[共享调试：配对后连不上](\{link})"
  nt_msg(words~, md=Some([["p", [[0, 6], ["a", [[7, 18]], { "href": Json::string(link), "to": { "chat": true } }]]]]))
}

///|
/// The core's doing with `call` (session.cancelRetry, chat.report, software.update) on the fixture's notice.
fn nt_doing(call : String, seq? : String = "9") -> Json {
  let params : Json = match call {
    "session.cancelRetry" | "session.retry" | "session.reassign" => { "station": "ws1/st1", "key": "s-c1" }
    "software.update" => { "station": "ws1/st1", "id": "codex" }
    _ => { "station": "ws1/st1", "thread": "7", "seq": Json::string(seq) }
  }
  { "doing": [{ "call": Json::string(call), "stage": "running", "params": params }] }
}

///|
/// The fixture's source, its `doing` as `doing` says, its calls kept in `calls` (answered `answer`), read only where
/// `read_only`.
fn nt_src(doing : Json?, calls : Array[(String, Json)], answer? : Json = Json::object({}), read_only? : Bool = false) -> Source {
  let base = @sffixture.fixture("history")
  {
    ..base,
    read_only,
    topic_read: fn(name, params) {
      if name == "doing" {
        { value: Some(doing.unwrap_or({ "doing": [] })), error: None, version: 1 }
      } else {
        (base.topic_read)(name, params)
      }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      done(Ok(answer))
    },
  }
}

///|
/// The fixture's chat's view (offline where `offline`).
fn nt_view(offline? : Bool = false) -> ChatView {
  @sfbase.chat_view_made({
    "title": "发布",
    "messages": [],
    "offline": offline,
    "agents": [{ "session": { "key": "s-c1" } }],
  })
}

///|
/// Notice `m` as the old view draws it in its row (message_row in row_box), in a chat's list (its 取消 shown there
/// alone: a list of the test's own, nothing gone to), `w` wide.
fn nt_old(w : Double, src : Source, m : Message, view? : ChatView = nt_view(), platform? : Int = 0) -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  notices_open.clear()
  let rk = "nt-list"
  let here : MessageHere = {
    station: "ws1/st1",
    session: "s1",
    view,
    go: None,
    inline: w <= chat_narrow_w,
    gutter: 0.0,
    list: Some({ rk, turns: @sfbase.turns_of(rk), emits: @sfbase.emits_of(rk), flight: None }),
    core: None,
  }
  @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() {
        c.box(style=head_frame, fn() { row_box(c, row_side(w), 0.0, fn() { message_row(c, src, here, m) }) |> ignore })
        |> ignore
      })
    },
    w~,
    h=420.0,
    platform~,
  )
}

///|
/// The same notice as the nodes draw it in its row (notice_said_node), `m` as it changes, kept open in `opened`; what
/// is presented over it drawn; `row`, the row's node and key as it is made.
fn nt_new(
  w : Double,
  src : Source,
  m : () -> Message,
  opened? : @sf.LiveMap[String, Bool] = @sf.LiveMap::new(),
  copied? : @sf.LiveMap[String, Double] = @sf.LiveMap::new(),
  view? : ChatView = nt_view(),
  platform? : Int = 0,
  row? : Ref[(@view.View, String)?] = Ref(None),
) -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: "ws1/st1",
        session: "s1",
        view: fn() { view },
        width: fn() { w },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        @sf.style_node(f, fn() { head_frame })
        let made = notice_said_node(f, src, here, fn() { "m:ts9" }, fn() { row_side(w) }, fn() { 0.0 }, m, opened, copied)
        row.val = Some((made.node, (made.key)()))
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w~,
    h=420.0,
    platform~,
  )
}

///|
/// The fixture's states by name: the notice, what the core's doing says, whether it is opened, the chat read only.
fn nt_cases() -> Array[(String, Message, Json?, Bool)] {
  let detail = "Error: request timed out after 600s\n  at Session.run (session.ts:412)"
  let run = nt_msg(
    words="Claude Code · Sonnet 5.5 · 中 · 标准 → Codex · GPT-6 Astra · 高 · Fast",
    short="换成 Codex · GPT-6 Astra · 高 · Fast",
    lines=["之前：Claude Code · Sonnet 5.5 · 中 · 标准 · 自动 · lin@example.com", "现在：Codex · GPT-6 Astra · 高 · Fast · 自动 · lin@example.com"],
  )
  let sided = nt_msg(
    words="Claude Code · Opus 5.5 → Codex · GPT-6",
    short="换成 Codex · GPT-6",
    lines=["之前：Claude Code · Opus 5.5 · 高 · 自动 · lin@example.com", "现在：Codex · GPT-6 · 高 · 自动 · lin@example.com"],
    sides=Some({
      "was": "Claude Code · Opus 5.5",
      "now": "Codex · GPT-6",
      "to": "换成",
      "wasMaker": "anthropic",
      "wasRuntime": "claude",
      "nowMaker": "openai",
      "nowRuntime": "codex",
    }),
  )
  let lost = "与模型服务的连接中断，回复即可重试"
  let report_long = "本轮 agent 未在对话中回复，以下是它最后输出的文字，由 station 代为转发（并非它发出的消息），请留意"
  [
    ("closed", nt_msg(), None, false),
    ("open", nt_msg(), None, true),
    ("failed", nt_msg(failed=true, detail~), None, false),
    ("failed open", nt_msg(failed=true, detail~), None, true),
    ("install", nt_msg(install=true), None, false),
    ("installing", nt_msg(install=true), Some(nt_doing("software.update")), false),
    ("report", nt_msg(failed=true, reportable=true), None, false),
    ("report long", nt_msg(words=report_long, failed=true, reportable=true), None, false),
    ("reporting", nt_msg(failed=true, reportable=true), Some(nt_doing("chat.report")), false),
    ("retry", nt_msg(words="模型满载，自动重试，与额度无关", failed=true, retry=true), None, false),
    ("cancelling", nt_msg(words="模型满载，自动重试，与额度无关", failed=true, retry=true), Some(nt_doing("session.cancelRetry")), false),
    // (the model's failure's words: the connection's, longer, are cut otherwise by the nodes than by the old view at
    // 390 and 1.3, as 取消's are with words as long, with or without either)
    ("again", nt_msg(words="模型服务出错，回复即可重试", failed=true, again=true), None, false),
    ("trying again", nt_msg(words="模型服务出错，回复即可重试", failed=true, again=true), Some(nt_doing("session.retry")), false),
    ("reassign", nt_msg(words="Fable 额度已用完", failed=true, reassign=true), None, false),
    ("reassigning", nt_msg(words="Fable 额度已用完", failed=true, reassign=true), Some(nt_doing("session.reassign")), false),
    ("run changed", run, None, false),
    ("run changed open", run, None, true),
    ("run changed sides", sided, None, false),
    ("run changed sides open", sided, None, true),
    ("profile", nt_msg(words="Willow 上 codex 的登录已失效：请在设置里重新登录", failed=true, link=22), None, false),
    ("profile open", nt_msg(words="Willow 上 codex 的登录已失效：请在设置里重新登录", failed=true, link=22), None, true),
    // (one the station says what to do of: that at its end, · 重新登录, · 设置代理, before · 上报 would be)
    ("profile action", nt_msg(words="「Gemini-Pro」认证失败", failed=true, detail="401 UNAUTHENTICATED", profile_action="重新登录"), None, false),
    ("profile action open", nt_msg(words="「Gemini-Pro」认证失败", failed=true, detail="401 UNAUTHENTICATED", profile_action="重新登录"), None, true),
    ("profile action reportable", nt_msg(words="「Gemini-Pro」认证失败", failed=true, reportable=true, profile_action="重新登录"), None, false),
    ("profile proxy", nt_msg(words="模型服务不支持此 station 所在地区", failed=true, profile_action="设置代理"), None, false),
    ("chat opened", nt_opened(), None, false),
    // (eleven failures said alike, folded: ×11 after its words, before what it ends in; its words cut short, never ×11
    // nor 重试 or 上报)
    ("folded", nt_msg(words=lost, failed=true, count=11, last=19), None, false),
    ("folded again", nt_msg(words=lost, failed=true, again=true, count=11, last=19), None, false),
    ("folded again open", nt_msg(words=lost, failed=true, detail~, again=true, count=11, last=19), None, true),
    ("folded trying again", nt_msg(words=lost, failed=true, again=true, count=11, last=19), Some(nt_doing("session.retry")), false),
    ("folded report", nt_msg(words=lost, failed=true, reportable=true, count=11, last=19), None, false),
    ("folded report long", nt_msg(words=report_long, failed=true, reportable=true, count=11, last=19), None, false),
    ("folded report long open", nt_msg(words=report_long, failed=true, reportable=true, count=11, last=19), None, true),
  ]
}

///|
/// The fixture's notice's pill pressed open (both views): at the start of its words, the first drawn.
fn nt_open(t : @ui.Tester) -> Unit {
  let (_, x, y, _, h, _) = match t.words().get(0) {
    Some(w) => w
    None => @halt.saying("no notice's words drawn")
  }
  t.tap(x + 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
/// What `t.audit()` says of a notice's row, but what the old notice's row was laid out with, said exactly so many times
/// each (xfer/ra5-notice-rooms.md: the old view checks no press's room; all of it to go before the row is in the app,
/// its way the owner's to say, the coordinator 2026-11-11), one more or one fewer a fault:
/// - `time`: its time under the open pill, 18 high, the pill a neighbour 4 over it that takes presses: their rooms
///   parted between them, 29 (a keyboard and mouse's 36);
/// - `copy`: 复制 at the open pill's foot, 22 high, in the pill that takes presses (opening and closing it), its room
///   cut at the pill's edge: 35;
/// - `act`: · 安装 or · 上报 in the pill, 22 high, cut to the pill's 34;
/// - `dot`: the · before them, the ink at 60% the old one's (3.95:1 on the pill, 3.05:1 failed), the product's colour.
fn nt_audit(t : @ui.Tester, time : Int, copy : Int, act : Int, dot : Int) -> Array[String] {
  let room = fn(f : String, words : Array[String], file : String) {
    words.iter().any(fn(w) { f.has_prefix("room: 「" + w + "」") }) &&
    f.contains("stillfail/src/sfpages/" + file) &&
    f.contains("to be pressed in, under 36")
  }
  let kinds : Array[(String, (String) -> Bool, Int)] = [
    ("time", fn(f) { room(f, ["1 分钟前"], "message_head_node.mbt") }, time),
    ("copy", fn(f) { room(f, ["复制"], "message_notice_node.mbt") }, copy),
    ("act", fn(f) { room(f, ["安装", "上报", "取消", "重试", "重新分配账号", "重新登录", "设置代理"], "message_notice_node.mbt") }, act),
    (
      "dot",
      // (the dot is the library's notice_end_action_node's, asked for by the notice's page)
      fn(f) {
        f.has_prefix("words \"·\"") &&
        f.contains("stillfail/sf/src/chat_notice_pill_node.mbt") &&
        f.contains(":1, under 4.5")
      },
      dot,
    ),
  ]
  let all = t.audit()
  let faults = all.filter(fn(f) { !kinds.iter().any(fn(k) { (k.1)(f) }) })
  for k in kinds {
    let n = all.filter(k.1).length()
    if n != k.2 {
      faults.push("\{k.0} said \{n} times, \{k.2} known: " + all.filter(k.1).join(" | "))
    }
  }
  faults
}

///|
/// How many times each of nt_audit's is said of case `c` drawn (open or not) at the system's size of words `scale`:
/// time, copy, act, dot. At 1.3 复制 is 25 high and the pill 40.6: those in it have their room.
fn nt_known(c : (String, Message, Json?, Bool), scale : Double) -> (Int, Int, Int, Int) {
  let (_, m, doing, open) = c
  let small = scale == 1.0
  let ends = (m.install is Some(_) || notice_after(m) is Some(_) || m.notice_profile_action != "" || m.reportable) &&
    m.notice_short == "" &&
    m.notice_lines.is_empty()
  (
    0,
    0,
    // (open, the pill is as tall as what it holds: its end has its room)
    if small && ends && doing is None && !open { 1 } else { 0 },
    if ends { 1 } else { 0 },
  )
}

///|
/// What a Tester draws (head_drawn's), each place and size to a hundredth (the old view's sums leave tails the nodes'
/// do not: 31.200000000000003 against 31.2); each underline of `under` (its x, its y) drawn at the y it says instead.
fn nt_drawn(t : @ui.Tester, under? : Array[(Double, Double, Double)] = []) -> String {
  let r = fn(v : Double) { (v * 100.0).round() / 100.0 }
  // (but what the old view's row left out, 换成 while what a run ran on is there: words of no size, never drawn)
  t.words().filter(fn(w) { w.3 > 0.0 || w.4 > 0.0 }).map(fn(w) { "\{w.0}@\{r(w.1)},\{r(w.2)} \{r(w.3)}x\{r(w.4)} a\{w.5}" }).join("\n") +
  "\n" +
  t
  .drawn_rects()
  .map(fn(d) {
    let y = match under.iter().find_first(fn(u) { r(d.0) == r(u.0) && r(d.1) == r(u.1) && d.3 <= 1.0 }) {
      Some((_, _, to)) => to
      None => d.1
    }
    "\{r(d.0)},\{r(y)} \{r(d.2)}x\{r(d.3)} \{d.4}"
  })
  .join("\n")
}

///|
/// Where the old view underlines notice `m`'s · 安装, its 取消, 重试 or 重新分配账号, · 上报, or its 复制, at the system's
/// size of words `scale` (its x, its y), and where the nodes do, if that is not the default size of words: the old
/// view's rich line puts it 18.9 or 19 under its words' top as their place falls between pixels (at 25.6, 18.9; at 103,
/// 19; at 131.6, 18.9), the nodes' runs 19 always, as they do for the profile's link at 22.
fn nt_under(t : @ui.Tester, m : Message, scale : Double) -> Array[(Double, Double, Double)] {
  guard scale != 1.0 else { return [] }
  let act = match (m.install, notice_after(m)) {
    (Some(_), _) => "安装"
    (None, Some((_, label, _))) => label
    (None, None) =>
      if m.notice_profile_action != "" {
        m.notice_profile_action
      } else if m.reportable {
        "上报"
      } else {
        ""
      }
  }
  let said = (if act != "" && m.notice_short == "" { [act] } else { [] }) + ["复制"]
  said.filter_map(fn(s) {
    let words = t.words().iter().find_first(fn(w) { w.0 == s })
    match words {
      Some(w) =>
        t.drawn_rects().iter().find_first(fn(d) { d.3 <= 1.0 && (d.0 - w.1).abs() < 0.01 && d.1 > w.2 }).map(fn(d) {
          (d.0, d.1, w.2 + 19.0)
        })
      None => None
    }
  })
}

///|
test "what still.fail said, made once as nodes, is drawn as the old view drew it: closed and open, failed, · 安装, · 上报, 取消, a run changed, a profile's link, a chat opened; wide and narrow, at 1.3" {
  for c in nt_cases() {
    for (w, scale) in [(760.0, 1.0), (390.0, 1.0), (390.0, 1.3)] {
      let at = "\{c.0} at \{w}, \{scale}"
      let old = nt_old(w, nt_src(c.2, []), c.1)
      old.set_font_scale(scale)
      old.run_for(@ui.move_most_ms)
      if c.3 {
        nt_open(old)
      }
      let was = nt_drawn(old, under=nt_under(old, c.1, scale))
      let t = nt_new(w, nt_src(c.2, []), fn() { c.1 })
      t.set_font_scale(scale)
      t.run_for(@ui.move_most_ms)
      if c.3 {
        nt_open(t)
      }
      assert_eq(nt_drawn(t), was, msg=at)
      let (time, copy, act, dot) = nt_known(c, scale)
      let faults = nt_audit(t, time, copy, act, dot)
      assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    }
  }
}

///|
test "pressed, a notice opens, kept open by its message: all its words, its time under it; pressed again, closed" {
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let m = nt_msg()
  let t = nt_new(760.0, nt_src(None, []), fn() { m }, opened~)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("1 分钟前") is None, msg="closed: no time")
  nt_open(t)
  assert_eq(opened.get("ts9"), Some(true))
  assert_true(t.find("1 分钟前") is Some(_), msg="open: its time under it")
  nt_open(t)
  assert_eq(opened.get("ts9"), Some(false))
  assert_true(t.find("1 分钟前") is None, msg="closed again")
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "what failed said, copied: 已复制 till copied_ms from the press, then 复制; the notice stays open" {
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let copied : @sf.LiveMap[String, Double] = @sf.LiveMap::new()
  opened["ts9"] = true
  let detail = "Error: request timed out after 600s"
  let t = nt_new(760.0, nt_src(None, []), fn() { nt_msg(failed=true, detail~) }, opened~, copied~)
  t.run_for(@ui.move_most_ms)
  t.tap_run("复制")
  t.frame()
  assert_eq(t.clipboard(), detail)
  assert_true(t.find("已复制") is Some(_), msg="said copied")
  assert_eq(opened.get("ts9"), Some(true), msg="the press its own, the pill not closed")
  assert_true(copied.get("ts9") is Some(_), msg="kept by its message")
  t.run_for(@sf.copied_ms)
  assert_true(t.find("已复制") is None, msg="no more after copied_ms")
  assert_true(t.find("复制") is Some(_))
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "· 安装 installs the runtime (software.update), not offered while it installs; the pill not opened" {
  let calls : Array[(String, Json)] = []
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let t = nt_new(760.0, nt_src(None, calls), fn() { nt_msg(install=true) }, opened~)
  t.run_for(@ui.move_most_ms)
  t.tap_run("安装")
  t.frame()
  assert_eq(calls.filter(fn(c) { c.0 == "software.update" }).length(), 1)
  assert_eq(opened.get("ts9"), None, msg="the pill not opened")
  let busy : Array[(String, Json)] = []
  let t = nt_new(760.0, nt_src(Some(nt_doing("software.update")), busy), fn() { nt_msg(install=true) })
  t.run_for(@ui.move_most_ms)
  t.tap_run("安装")
  t.run_for(@ui.move_most_ms)
  assert_eq(busy.filter(fn(c) { c.0 == "software.update" }).length(), 0, msg="not while it installs")
  // (not offered: a press there is the pill's, which opens; closed again)
  assert_true(t.find("1 分钟前") is Some(_), msg="the pill's press")
  nt_open(t)
  let faults = nt_audit(t, 0, 0, 0, 1)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "· 上报 asks first, then reports the failure (chat.report) and says what it was filed as" {
  @sf.presenters_reset()
  let calls : Array[(String, Json)] = []
  let t = nt_new(760.0, nt_src(None, calls, answer={ "number": 42, "duplicate": false }), fn() {
    nt_msg(failed=true, reportable=true)
  })
  t.run_for(@ui.move_most_ms)
  t.tap_run("上报")
  t.frame()
  assert_true(@sf.presenting(), msg="asked first")
  assert_eq(calls.length(), 0)
  t.run_for(@ui.move_most_ms)
  let ok = t.get(Button, label="上报", within=t.get(Dialog))
  t.tap(ok.rect.0 + ok.rect.2 / 2.0, ok.rect.1 + ok.rect.3 / 2.0)
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "chat.report" })
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].1), "station"), "ws1/st1")
  assert_eq(number(Some(sent[0].1), "seq"), 9.0)
  assert_eq(number(Some(sent[0].1), "thread"), 7.0)
  t.frame()
  assert_eq(@sfbase.toast_words(), "已上报为 FB-42")
  t.run_for(@ui.move_most_ms)
  assert_true(!@sf.presenting(), msg="closed once it went")
  // (· 上报's room as nt_known's `act` says it, no 取消 beside the pill any more)
  let faults = nt_audit(t, 0, 0, 1, 1)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "取消 while its agent waits to retry cancels it (session.cancelRetry); not offered read only or offline; gone once the retry is over" {
  let calls : Array[(String, Json)] = []
  let retry = @signals.signal(true)
  let m = fn() { nt_msg(words="模型满载，自动重试，与额度无关", failed=true, retry=retry.get()) }
  let t = nt_new(760.0, nt_src(None, calls), m)
  t.run_for(@ui.move_most_ms)
  t.tap_text("取消")
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "session.cancelRetry" })
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].1), "key"), "s-c1")
  assert_eq(number(Some(sent[0].1), "seq"), 9.0)
  retry.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("取消") is None, msg="gone once the retry is over")
  for (ro, off) in [(true, false), (false, true)] {
    let calls : Array[(String, Json)] = []
    let t = nt_new(760.0, nt_src(None, calls, read_only=ro), fn() {
      nt_msg(words="模型满载，自动重试，与额度无关", failed=true, retry=true)
    }, view=nt_view(offline=off))
    t.run_for(@ui.move_most_ms)
    assert_true(t.get(Button, label="取消").disabled, msg="read only \{ro}, offline \{off}")
    t.tap_text("取消")
    t.frame()
    assert_eq(calls.length(), 0)
    let faults = nt_audit(t, 0, 0, 0, 1)
    assert_true(faults.is_empty(), msg=faults.join(" | "))
  }
}

///|
test "重试 on a failed turn's notice tries it again (session.retry); gone once its agent goes on" {
  let calls : Array[(String, Json)] = []
  let again = @signals.signal(true)
  let m = fn() { nt_msg(words="与模型服务的连接中断，回复即可重试", failed=true, again=again.get()) }
  let t = nt_new(760.0, nt_src(None, calls), m)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="取消") is None)
  t.click(Button, label="重试")
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "session.retry" })
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].1), "key"), "s-c1")
  assert_eq(number(Some(sent[0].1), "thread"), 7.0)
  assert_eq(number(Some(sent[0].1), "seq"), 9.0)
  again.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="重试") is None, msg="gone once its agent goes on")
  assert_true(t.query(Button, label="取消") is None, msg="never 取消 on its way out")
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "a notice about a profile: what went wrong leads to the profile's page" {
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let t = nt_new(760.0, nt_src(None, []), fn() {
    nt_msg(words="Willow 上 codex 的登录已失效：请在设置里重新登录", failed=true, link=22)
  }, opened~)
  t.run_for(@ui.move_most_ms)
  t.tap_run("请在设置里重新登录")
  t.frame()
  assert_true(app.nav.top() == Setting(@settings.Route::Profile("ws1/st1", "p1")))
  assert_eq(opened.get("ts9"), None, msg="the pill not opened")
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "a notice about a profile the station says what to do of: · 重新登录 opens the profile's page, its words open what failed said, never · 上报 beside it" {
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let m = fn() {
    // (a profile of its own: the app's pages are the run's, another test's press may have left p1's open)
    nt_msg(
      words="「Gemini-Pro」认证失败",
      failed=true,
      detail="401 UNAUTHENTICATED",
      reportable=true,
      profile_action="重新登录",
      profile="p2",
    )
  }
  let t = nt_new(760.0, nt_src(None, []), m, opened~)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="上报") is None, msg="what to do of it, not 上报")
  assert_true(t.find("401 UNAUTHENTICATED") is None, msg="closed: what failed said not shown")
  // (its words: the pill's press, which opens what failed said; once more, closed)
  nt_open(t)
  assert_eq(opened.get("ts9"), Some(true))
  assert_true(t.find("401 UNAUTHENTICATED") is Some(_), msg="open: what failed said")
  assert_true(app.nav.top() != Setting(@settings.Route::Profile("ws1/st1", "p2")), msg="the words open the pill, not the page")
  nt_open(t)
  assert_eq(opened.get("ts9"), Some(false))
  t.click(Button, label="重新登录")
  t.frame()
  assert_true(app.nav.top() == Setting(@settings.Route::Profile("ws1/st1", "p2")))
  assert_eq(opened.get("ts9"), Some(false), msg="the pill not opened by it")
  let faults = nt_audit(t, 0, 0, 1, 1)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "the row's node, with the row's key as it is made, across the list round its pill" {
  let row : Ref[(@view.View, String)?] = Ref(None)
  let t = nt_new(760.0, nt_src(None, []), fn() { nt_msg() }, row~)
  t.run_for(@ui.move_most_ms)
  match row.val {
    Some((r, k)) => {
      assert_eq(k, "m:ts9")
      let (_, _, w, h) = r.rect()
      let (_, ty, _, th) = t.rect_of("Willow 的 codex 这一轮超时了，已经停下").unwrap_or((0.0, 0.0, 0.0, 0.0))
      assert_true((w - 760.0).abs() < 0.5 && h >= th && ty > 0.0, msg="the row across the list round its pill")
    }
    None => fail("no row told")
  }
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "取消 comes at the end of the pill's line as a retry begins and goes as it ends, as · 安装 does" {
  let calls : Array[(String, Json)] = []
  let retry = @signals.signal(false)
  let words = "模型满载，自动重试，与额度无关"
  let m = fn() { nt_msg(words~, failed=true, retry=retry.get()) }
  let t = nt_new(760.0, nt_src(None, calls), m)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("取消") is None)
  retry.set(true)
  t.run_for(@ui.move_most_ms)
  let (wx, wy, ww, _) = t.rect_of(words).unwrap()
  let (cx, cy, _, _) = t.rect_of("取消").unwrap()
  assert_true(cx > wx + ww && (cy - wy).abs() < 2.0, msg="取消 after its words, on their line: \{Repr((wx, wy, ww, cx, cy))}")
  retry.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("取消") is None, msg="gone once the retry is over")
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "重新分配账号 on a notice whose allowance showed a limit moves it (session.reassign); gone once it goes on" {
  let calls : Array[(String, Json)] = []
  let offered = @signals.signal(true)
  let m = fn() { nt_msg(words="查了额度：Fable 在这个账号上已用完", failed=true, reassign=offered.get()) }
  let t = nt_new(760.0, nt_src(None, calls), m)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="重试") is None)
  t.click(Button, label="重新分配账号")
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "session.reassign" })
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].1), "key"), "s-c1")
  assert_eq(number(Some(sent[0].1), "thread"), 7.0)
  assert_eq(number(Some(sent[0].1), "seq"), 9.0)
  offered.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="重新分配账号") is None, msg="gone once its agent goes on")
  let faults = nt_audit(t, 0, 0, 0, 0)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "a notice's action at the end of its first line, closed and opened: it never changes its place" {
  let said = "You've hit your Fable limit · resets Nov 20 at 9am (Asia/Tokyo). Switch to another model to continue."
  let words = "这个账号的 Fable 额度已用完"
  let t = nt_new(390.0, nt_src(None, []), fn() { nt_msg(words~, detail=said, failed=true, reassign=true) })
  t.run_for(@ui.move_most_ms)
  let (wx, wy, ww, _) = t.rect_of(words).unwrap()
  let (ax, ay, _, _) = t.rect_of("重新分配账号").unwrap()
  assert_true(ax > wx + ww && (ay - wy).abs() < 2.0, msg="closed, after its words on their line: \{Repr((wx, wy, ww, ax, ay))}")
  nt_open(t)
  let (ox, oy, ow, _) = t.rect_of(words).unwrap()
  let (bx, by, _, _) = t.rect_of("重新分配账号").unwrap()
  assert_true(bx > ox + ow && (by - oy).abs() < 2.0, msg="opened, still after its words on their line: \{Repr((ox, oy, ow, bx, by))}")
  // (what was pressed never moves across as it opens: its first line in the middle of the pill, which opens about its
  // middle; its action with it)
  assert_true((ox - wx).abs() < 0.5 && (bx - ax).abs() < 0.5, msg="opened, its first line where it was: \{Repr((wx, ox, ax, bx))}")
  let faults = nt_audit(t, 0, 0, 0, 1)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
  // Even when a long notice wraps onto multiple lines once opened, its trailing action stays aligned with the first line.
  let long_words = "与模型服务的连接中断，回复即可重试；同一报错连续出现时请检查中转节点"
  let t_long = nt_new(390.0, nt_src(None, []), fn() { nt_msg(words=long_words, detail=said, failed=true, again=true) })
  t_long.run_for(@ui.move_most_ms)
  nt_open(t_long)
  let first_y = t_long.words().iter().fold(init=1.0e9, fn(m, w) { if w.2 < m { w.2 } else { m } })
  let (_, ry, _, _) = t_long.rect_of("重试").unwrap()
  assert_true((ry - first_y).abs() < 2.0, msg="wrapped open notice keeps action on first line: \{ry} vs \{first_y}")
}

///|
/// A drawn words' place and size (Tester::words's).
fn nt_rect(w : (String, Double, Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
  (w.1, w.2, w.3, w.4)
}

///|
/// Where words drawn exactly `s` are (a word at a notice's end, not the words that hold it): x, y, w, h.
fn nt_word(t : @ui.Tester, s : String) -> (Double, Double, Double, Double) {
  match t.words().iter().find_first(fn(w) { w.0 == s }) {
    Some(w) => (w.1, w.2, w.3, w.4)
    None => @halt.saying("no words drawn " + s)
  }
}

///|
test "failures said alike folded: ×11 after their words and before 重试, both whole where the words are cut short, at 390 and 1.3" {
  let lost = "与模型服务的连接中断，回复即可重试"
  let long = "本轮 agent 未在对话中回复，以下是它最后输出的文字，由 station 代为转发（并非它发出的消息），请留意"
  for c in [(lost, true, false), (long, true, false), (long, false, true)] {
    let (words, again, reportable) = c
    let end = if again { "重试" } else { "上报" }
    for (w, scale) in [(760.0, 1.0), (390.0, 1.0), (390.0, 1.3)] {
      let at = "\{words} at \{w}, \{scale}"
      let t = nt_new(w, nt_src(None, []), fn() { nt_msg(words~, failed=true, again~, reportable~, count=11, last=19) })
      t.set_font_scale(scale)
      t.run_for(@ui.move_most_ms)
      let (nx, ny, nw, nh) = nt_word(t, "×11")
      let (ex, ey, _, eh) = nt_word(t, end)
      let (_, wy, _, wh) = t.words()[0] |> nt_rect
      // (on the words' line, at its foot as what it ends in always stood)
      assert_true(ex >= nx + nw && ny >= wy - 0.5 && (ny + nh - (wy + wh)).abs() < 0.5 && (ey + eh - (ny + nh)).abs() < 0.5, msg=at + ": ×11 then " + end + " on the words' line: \{Repr((nx, ny, nw, nh, ex, ey, wy, wh))}")
      // (only the words give way: what they end in is drawn whole, inside the row)
      let runs = t.words().filter(fn(x) { x.0 != words && x.0.has_suffix("…") })
      assert_true(runs.iter().all(fn(x) { words.has_prefix(x.0.clamped_view(end=x.0.length() - 1).to_owned()) }), msg=at + ": cut short only its words: \{Repr(runs.map(fn(x) { x.0 }))}")
      assert_true(nx + nw <= w && ex <= w, msg=at)
      // (read out with how many it folds)
      assert_true(t.query(Button, label=words + " ×11") is Some(_), msg=at + ": read out with ×11")
      let faults = nt_audit(t, 0, 0, if scale == 1.0 { 1 } else { 0 }, 1)
      assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    }
  }
}

///|
test "opened on several lines, a folded notice's ×11 and 重试 stay on its first line" {
  let long = "本轮 agent 未在对话中回复，以下是它最后输出的文字，由 station 代为转发（并非它发出的消息），请留意"
  for (w, scale) in [(390.0, 1.0), (390.0, 1.3)] {
    let at = "\{w}, \{scale}"
    let t = nt_new(w, nt_src(None, []), fn() { nt_msg(words=long, failed=true, again=true, detail="request r19: ECONNRESET", count=11, last=19) })
    t.set_font_scale(scale)
    t.run_for(@ui.move_most_ms)
    // (closed: its words on one line, cut short)
    let (_, _, _, line) = t.words()[0] |> nt_rect
    let (_, closed_n, _, _) = nt_word(t, "×11")
    let (_, closed_e, _, _) = nt_word(t, "重试")
    nt_open(t)
    let (_, first, _, bh) = nt_word(t, long)
    let (_, ny, _, nh) = nt_word(t, "×11")
    let (_, ey, _, eh) = nt_word(t, "重试")
    assert_true(bh > line * 1.5, msg=at + ": opened on several lines: \{Repr((bh, line))}")
    // (at the foot of its first line, where they stood closed: never moved down to its last)
    assert_true((ny - closed_n).abs() < 0.01 && (ey - closed_e).abs() < 0.01 && (ny + nh - (first + line)).abs() < 0.5 && (ey + eh - (first + line)).abs() < 0.5, msg=at + ": on the first line \{first}+\{line}: \{Repr((ny, nh, ey, eh, closed_n, closed_e))}")
    assert_true(t.find("request r19: ECONNRESET") is Some(_), msg=at + ": the last's failure in words under it")
    let faults = nt_audit(t, 0, 0, 0, 1)
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
  }
}

///|
test "one failure, then two, then eleven said alike: the same pill, ×2 then ×11 after its words, its words on their line, whole" {
  let count = @signals.signal(1)
  let lost = "与模型服务的连接中断，回复即可重试"
  let t = nt_new(390.0, nt_src(None, []), fn() { nt_msg(words=lost, failed=true, again=true, count=count.get(), last=8 + count.get()) })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("×1") is None && t.find("×2") is None, msg="one: no count")
  let (_, wy, ww, _) = nt_word(t, lost)
  for n in [2, 11] {
    count.set(n)
    t.run_for(@ui.move_most_ms)
    let (nx, ny, _, _) = nt_word(t, "×\{n}")
    let (x, y, w, _) = nt_word(t, lost)
    // (the pill widened round them, centred as it is: its words on their line, not cut, ×n after them)
    assert_true((y - wy).abs() < 0.01 && (w - ww).abs() < 0.01 && nx >= x + w && (ny - y).abs() < 2.0, msg="at ×\{n}: \{Repr((x, y, w, wy, ww, nx, ny))}")
    assert_true(t.query(Button, label="重试") is Some(_))
  }
  let faults = nt_audit(t, 0, 0, 1, 1)
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "重试 and · 上报 on a folded notice act on the last failure it folds (its lastSeq), as the old view does" {
  let lost = "与模型服务的连接中断，回复即可重试"
  // (the nodes)
  let calls : Array[(String, Json)] = []
  let t = nt_new(760.0, nt_src(None, calls), fn() { nt_msg(words=lost, failed=true, again=true, count=11, last=19) })
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="重试")
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "session.retry" })
  assert_eq(sent.length(), 1)
  assert_eq(number(Some(sent[0].1), "seq"), 19.0)
  // (the old view)
  let old_calls : Array[(String, Json)] = []
  let old = nt_old(760.0, nt_src(None, old_calls), nt_msg(words=lost, failed=true, again=true, count=11, last=19))
  old.run_for(@ui.move_most_ms)
  let (rx, ry, rw, rh) = nt_word(old, "重试")
  old.tap(rx + rw / 2.0, ry + rh / 2.0)
  old.frame()
  let sent = old_calls.filter(fn(c) { c.0 == "session.retry" })
  assert_eq(sent.length(), 1)
  assert_eq(number(Some(sent[0].1), "seq"), 19.0)
  // · 上报, asked first, the last's seq; under way by it
  @sf.presenters_reset()
  let calls : Array[(String, Json)] = []
  let t = nt_new(760.0, nt_src(None, calls, answer={ "number": 42, "duplicate": false }), fn() {
    nt_msg(words=lost, failed=true, reportable=true, count=11, last=19)
  })
  t.run_for(@ui.move_most_ms)
  t.tap_run("上报")
  t.run_for(@ui.move_most_ms)
  let ok = t.get(Button, label="上报", within=t.get(Dialog))
  t.tap(ok.rect.0 + ok.rect.2 / 2.0, ok.rect.1 + ok.rect.3 / 2.0)
  t.frame()
  let sent = calls.filter(fn(c) { c.0 == "chat.report" })
  assert_eq(sent.length(), 1)
  assert_eq(number(Some(sent[0].1), "seq"), 19.0)
  t.run_for(@ui.move_most_ms)
  let busy : Array[(String, Json)] = []
  let t = nt_new(760.0, nt_src(Some(nt_doing("chat.report", seq="19")), busy), fn() {
    nt_msg(words=lost, failed=true, reportable=true, count=11, last=19)
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.get(Button, label="上报").disabled, msg="under way by its last's seq")
}
