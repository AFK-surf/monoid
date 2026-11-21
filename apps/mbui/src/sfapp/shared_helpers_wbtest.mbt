// Shared whitebox test helpers retained for remaining stillfail/sfapp tests after moving pages tests to stillfail/sfapp_pages_test.

///|
fn draft_key(r : ChatRef) -> String {
  r.station + ":" + r.session
}

///|
fn bar_extra_target(r : ChatRef) -> Double {
  match chat_bar_states.get(chat_bar_key(r)) {
    Some(s) => s.extra_target.get()
    None => 0.0
  }
}

///|
/// How the client asked topic `name` with `params` of the made-up core in `heard` (round_trip_again's): how many times it
/// was subscribed to, and how many of those it let go.
fn asked_held(heard : Array[String], name : String, params : Map[String, Json]) -> (Int, Int) {
  let want : Map[String, Json] = params.copy()
  want["topic"] = Json::string(name)
  let ids : Map[Int, Bool] = Map([])
  let mut asked = 0
  let mut let_go = 0
  for h in heard {
    guard h.has_prefix("out ") else { continue }
    let j = @json.parse(h.exact_view(start=4).to_owned()) catch { _ => continue }
    guard j is Object(m) && m.get("id") is Some(Number(n, ..)) else { continue }
    let id = n.to_int()
    match (m.get("subscribe"), m.get("unsubscribe")) {
      (Some(Object(t)), _) if t.length() == want.length() && want.iter().all(fn(kv) { t.get(kv.0) == Some(kv.1) }) => {
        asked += 1
        ids[id] = true
      }
      (_, Some(_)) if ids.contains(id) => let_go += 1
      _ => ()
    }
  }
  (asked, let_go)
}

///|
/// `t` with a popover open from the button at `label` (`open` whether it is): that button pressed and let go (as the
/// host hands it on: what closes it), a frame drawn after where `frames`, then Escape at once: whether it is open as
/// the button is let go, as Escape is taken, and once a frame is drawn after.
fn button_then_escape(t : @ui.Tester, label : String, open : () -> Bool, frames : Bool) -> Array[Bool] raise {
  t.host_says_finger(Some(false))
  t.draw()
  guard t.query(Button, label~) is Some(s) else { fail("no \{label}") }
  let (x, y) = (s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
  t.tap(x, y)
  t.frame()
  assert_true(open(), msg="opened")
  t.touch_at(0, x, y, t.time())
  t.touch_at(2, x, y, t.time())
  let seen = [open()]
  if frames {
    t.frame()
  }
  t.key_told(@ui.key_escape, 0, t.time())
  seen.push(open())
  t.draw()
  seen.push(open())
  seen
}

///|
/// The fixture `mode` with the core's `downloads` as `list` says (what it brings as `keeping`), its calls kept in
/// `calls`; `download.take` answered as taken, `download.read` (the saving's) answered with `bytes` (of `type`) a part
/// at a time, `part` at most; `list` changed, the core tells its topic changed by `told` set anew.
fn downloads_src(
  mode : String,
  list : Array[Json],
  calls : Array[(String, Json)],
  told? : @signals.Signal[Int] = @signals.signal(0),
  keeping? : Array[Json] = [],
  bytes? : Bytes = b"PK\x03\x04",
  part? : Int = 4 * 1024 * 1024,
) -> Source {
  let base = fixture(mode)
  {
    ..base,
    topic_read: fn(name, params) {
      if name == "downloads" {
        told.get() |> ignore
        { value: Some({ "downloads": Json::array(list), "keeping": Json::array(keeping) }), error: None, version: 1 }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      match name {
        "download.take" => done(Ok({ "taken": true }))
        "download.start" | "download.retry" | "download.done" | "download.cancel" | "fill.want" | "fill.stop" =>
          done(Ok({}))
        _ => (base.call)(name, params, done)
      }
    },
    read_bytes: fn(name, params, done) {
      calls.push((name, params))
      // (the saving's reads, off the device: a preview's own go to the fixture)
      if name == "download.read" {
        let from = number(Some(params), "offset").to_int()
        let to = if from + part > bytes.length() { bytes.length() } else { from + part }
        let got = Bytes::makei(to - from, fn(i) { bytes[from + i] })
        done(Ok(({ "type": "application/zip", "total": Json::number(bytes.length().to_double()) }, got)))
      } else {
        (base.read_bytes)(name, params, done)
      }
    },
  }
}

///|
/// On the tape (laid out Medium, the sidebar in use at first), what shows of the page tapped: the page over.
fn files_page_over(t : @ui.Tester, w : Double, h : Double) -> Unit {
  if @sfdesk.wide.tape.get() && @sfdesk.wide.tape_at.get() != @sfdesk.TapePane::Page {
    t.tap(w - @sfdesk.tape_shows / 2.0, h / 2.0)
    t.run_for(@ui.move_most_ms)
  }
}

///|
/// The fixture's `mode` without a workspace, a code asked for where `asked`, 390 by 844 to touch, as nodes
/// (no_workspace_node). The Tester.
fn landing_case(mode : String, asked : Bool) -> @ui.Tester {
  new_run()
  let src = fixture(mode)
  @sfpages.landing_reset()
  let ws = fn() { src.topic("workspaces", {}).get().value }
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(fn(root) { @sfpages.no_workspace_node(root, src, ws, fn() {  }) |> ignore })
  t.draw()
  if asked {
    @sfpages.landing_asked()
    t.draw()
  }
  t
}

///|
/// Each mode without a workspace with its title found drawn, as landing_case opens it, and each as it should be (all
/// found): the words of each title read in that mode's own run, once it has begun (read before, they are the run
/// before's, in its language: read_after_run_wbtest.mbt).
fn landing_titles() -> (Array[(String, Bool, Bool)], Array[(String, Bool, Bool)]) {
  let cases : Array[(String, Bool, () -> String)] = [
    ("landing", false, fn() { @sf.t("android-misc.workspace.none") }),
    ("landing", true, fn() { @sf.t("android-misc.invite.onlyInvited", args=[("app", "still.fail")]) }),
    ("landing-invited", false, fn() { @sf.t("android-misc.invite.received") }),
    ("blocked", false, fn() { "此账号暂未开放测试版" }),
  ]
  let seen = cases.map(fn(k) {
    let t = landing_case(k.0, k.1)
    (k.0, k.1, t.find((k.2)()) is Some(_) && t.drawn_glyphs().length() > 0)
  })
  (seen, cases.map(fn(k) { (k.0, k.1, true) }))
}

///|
/// 关于 on a large screen (`platform`'s input), `w` × 900, in the window's tree's frame: its page made once.
fn large_about_tester(
  _tree : Bool,
  platform : Int,
  w? : Double = 1280.0,
  mode? : String = "settings-about",
  wait? : Double = @ui.move_most_ms,
  scale? : Double = 1.0,
  window_inset? : Bool = false,
  lang? : @signals.Signal[String] = @signals.signal(""),
  topics? : Map[String, @signals.Signal[Json]] = {},
) -> @ui.Tester {
  let base = fixture_app(mode)
  // (the core's language as `lang` says it, where it says one)
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      match topics.get(name) {
        Some(v) => return { value: Some(v.get()), error: None, version: 1 }
        None => ()
      }
      let got = base.topic(name, params).get().snapshot()
      if name != "prefs" || lang.get() == "" {
        return got
      }
      let o = match got.value {
        Some(Object(m)) => m.copy()
        _ => {}
      }
      o["lang"] = Json::string(lang.get())
      { ..got, value: Some(Json::object(o)) }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=900.0, platform~, window_inset~)
  t.set_font_scale(scale)
  t.run_for(wait)
  t
}

///|
/// A download as the core lists it.
fn listed(name : String, state : String, loaded : Double, size : Double, said : String) -> Json {
  {
    "id": Json::string("ws1/st1|s-c1|" + name),
    "station": "ws1/st1",
    "key": "s-c1",
    "name": Json::string(name),
    "size": Json::number(size),
    "loaded": Json::number(loaded),
    "progress": Json::number(if size > 0.0 { loaded / size } else { 0.0 }),
    "state": Json::string(state),
    "active": Json::boolean(state != "failed"),
    "statusText": Json::string(said),
    "startedAt": 1.0,
  }
}

///|
/// 记忆 on a small screen (`platform`'s input), 390 × 2400, its stations as the fixture has them, never come (`held`) or
/// failed (`failed`): drawn by the window's tree, its page made once.
fn memories_tester(
  platform : Int,
  held? : Bool = false,
  failed? : Bool = false,
  scale? : Double = 1.0,
  mode? : String = "settings-memories",
  calls? : Array[String] = [],
  wrap? : (Source) -> Source = fn(s) { s },
  w? : Double = 390.0,
  words_over_held? : Bool = true,
) -> @ui.Tester {
  let made = fixture_app(mode)
  // (what is asked of the core, by name, kept in `calls`)
  let base : Source = {
    ..made,
    call: fn(name, params, done) {
      calls.push(name)
      (made.call)(name, params, done)
    },
  }
  let base = wrap(base)
  let src = if held {
    @sffixture.held_topics(base, ["stations"])
  } else if failed {
    @sffixture.failed_topics(base, ["stations"], "网络连接失败")
  } else {
    base
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=2400.0, platform~, words_over_held~)
  // (the system's size of words as said: what the bones' bars are as high as follows it)
  t.set_font_scale(scale)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The list scrolled until `words` are in the screen's middle half (found, they may lie under the bars at its ends).
fn middle_words(t : @ui.Tester, words : String) -> Unit {
  for _ in 0..<8 {
    guard t.rect_of(words) is Some((_, y, _, h)) else { return }
    let mid = y + h / 2.0
    if mid >= 211.0 && mid <= 633.0 {
      return
    }
    t.wheel(195.0, 400.0, mid - 422.0)
    t.run_for(@ui.move_most_ms)
  }
}

///|
/// The fixture's `mode` in a desktop's window, its model's panel open beside its control.
fn model_pop(mode : String, font_scale? : Double = 1.0) -> @ui.Tester {
  let src = fixture_app(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  if font_scale != 1.0 {
    t.set_font_scale(font_scale)
  }
  t.run_for(squeeze_opening)
  t
}
///|
/// Pages `from` to 4 of an agent's history (its words, 30 to a page), more before them while `from` is past the first.
fn older_history(from : Int) -> Json {
  let items : Array[Json] = []
  for p in from..<5 {
    for j in 0..<30 {
      let words = "第 \{p} 页第 \{j} 条"
      items.push({
        "key": Json::string("p\{p}-\{j}"),
        "entries": [Json::number((p * 30 + j).to_double()), Json::number((p * 30 + j).to_double())],
        "body": { "kind": "text", "content": { "text": Json::string(words), "line": Json::string(words), "subagent": false } },
      })
    }
  }
  { "items": Json::array(items), "live": [], "usage": [], "edge": "从 10/19 08:12 开始", "empty": false, "loaded": true, "more": from > 0 }
}

///|
/// Each width and hand the pages are drawn at: a phone with a finger, a narrow window with a mouse, a window between,
/// a tablet with a finger, a desktop's window with a mouse; and whether the page is as wide as the web's narrow app.
let one_page_cases : Array[(Double, Int, Bool, Bool)] = [
  (390.0, 2, false, true),
  (390.0, 0, false, true),
  (720.0, 0, false, false),
  (1100.0, 2, true, false),
  (1280.0, 0, false, false),
]
///|
/// What the core answers `chat.relayMentions` with for each note these tests type, for the fixture's two people
/// (pengxiao, Peng Xiao; peter): written down from client/core-ts/src/relay-pick.ts mentionView, run in Node on those
/// two and each note (2026-11-11). A note not here fails the test that typed it, saying which: add its answer as
/// mentionView gives it, never a made-up one.
fn relay_mentions_kept(note : String) -> Json {
  match note {
    "看下 @" => { "query": "", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }, { "id": "U2", "name": "peter", "note": "看下 @peter " }] }
    "看下 @p" => { "query": "p", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }, { "id": "U2", "name": "peter", "note": "看下 @peter " }] }
    "看下 @pe" => { "query": "pe", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }, { "id": "U2", "name": "peter", "note": "看下 @peter " }] }
    "看下 @P" => { "query": "P", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }, { "id": "U2", "name": "peter", "note": "看下 @peter " }] }
    "看下 @Pe" => { "query": "Pe", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }, { "id": "U2", "name": "peter", "note": "看下 @peter " }] }
    "看下 @Pen" => { "query": "Pen", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }] }
    "看下 @Peng" => { "query": "Peng", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }] }
    "看下 @Peng " => { "query": "Peng ", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }] }
    "看下 @Peng X" => { "query": "Peng X", "at": 3, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "看下 @pengxiao " }] }
    "看下 @pengxiao " => { "query": "pengxiao ", "at": 3, "rows": [] }
    "看下 @peter " => { "query": "peter ", "at": 3, "rows": [] }
    "@" => { "query": "", "at": 0, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "@pengxiao " }, { "id": "U2", "name": "peter", "note": "@peter " }] }
    "@p" => { "query": "p", "at": 0, "rows": [{ "id": "U1", "name": "pengxiao", "aka": "Peng Xiao", "note": "@pengxiao " }, { "id": "U2", "name": "peter", "note": "@peter " }] }
    _ => @halt.saying("chat.relayMentions: no answer kept for the note \"\{note}\" (relay_mentions_kept)")
  }
}

///|
/// A strip far wider than tall (a 2000 × 40 screenshot of a line): in the chat 360 × 7.2, thinner than 16, so in a
/// box 16 thick, letterboxed.
fn strip(name : String) -> Attachment {
  {
    name,
    path: "uploads/fx/" + name,
    size: 4096.0,
    width: 2000.0,
    height: 40.0,
    thumbhash: "",
    owner: "s-c1",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
}

///|
/// The panel `title` opened from its key in the bar where the bar holds it (named so, or saying so as its value: how far
/// the resources came, named 资源加载), else from the ⋯'s line; at the frame that opened it.
fn svc_open(t : @ui.Tester, title : String) -> Unit raise {
  let by_value = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == @ui.Role::Button && s.value == title })
  match (t.query(Button, label=title), by_value) {
    (Some(_), _) => t.click(Button, label=title)
    (None, Some(k)) => {
      let (x, y, w, h) = k.rect
      t.tap(x + w / 2.0, y + h / 2.0)
    }
    (None, None) => {
      t.click(Button, label="更多操作")
      t.run_for(@ui.move_most_ms)
      t.tap_text(title)
    }
  }
  t.frame()
}
///|
/// The core's topic `name` as it is read, its params' `key` each time (the source `base` otherwise as it is).
fn topic_asked(base : Source, name : String, key : String, asked : Array[String]) -> Source {
  {
    ..base,
    topic_read: fn(n, params) {
      if n == name {
        asked.push(
          match params.get(key) {
            Some(String(s)) => s
            Some(Number(d, ..)) => d.to_int().to_string()
            _ => ""
          },
        )
      }
      base.topic(n, params).get().snapshot()
    },
  }
}

///|
/// The words drawn by nodes of the window's tree of their own (not an old view's, hosted): the page's own.
fn tree_words_drawn() -> Array[String] {
  match @ui.view_tree() {
    Some(tree) => tree.drawn().filter(fn(d) { !d.hosted && d.words != "" }).map(fn(d) { d.words })
    None => []
  }
}
///|
/// Whether the rect `r` is wholly in view in the panel: inside the part seen of every box of the panel's laid out round
/// it (a scroller's, the panel's own), so nothing over its foot or past a scroller's edge hides any of it.
fn wholly_in_view(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Bool raise {
  let (x, y, w, h) = r
  let (dx, _, dw, _) = t.get(@ui.Role::Dialog).rect
  t
  .boxes_held()
  .iter()
  .all(fn(b) {
    let holds = b.x >= dx - 0.5 && b.x + b.w <= dx + dw + 0.5 &&
      b.x <= x + 0.5 && x + w <= b.x + b.w + 0.5 && b.y <= y + 0.5 && y + h <= b.y + b.h + 0.5
    let (cx, cy, cw, ch) = b.cut
    !holds || (cx <= x + 0.5 && x + w <= cx + cw + 0.5 && cy <= y + 0.5 && y + h <= cy + ch + 0.5)
  })
}

///|
fn lease_ended(sent : Array[String], id : Int) -> Int {
  sent.filter(fn(s) {
    let message = try Some(@json.parse(s)) catch { _ => None }
    @sfbase.flag(message, "unsubscribe") && @sfbase.number(message, "id") == id.to_double()
  }).length()
}

///|
fn lease_test_source(client : @core.Client) -> Source {
  let base = @sfbase.made_source()
  {
    ..base,
    topic_key: @sfbase.wire_topic_key,
    topic_keyed: fn(_, _, _, _) { None },
    topic_read: fn(name, params) {
      let sub = client.follow_topic(name, params~)
      { value: sub.value, error: sub.error, version: sub.version }
    },
    waits: fn(name, params) { client.follow_topic(name, params~).waiting },
    leave: fn(name, params, __reason) {
      if __reason is @sfbase.TopicLeave::Owned(__stop) { __stop(); return }
      client.leave_topic(name, params~) },
    release: fn(name, params) { client.release_topic(name, params~) },
  }
}

///|
/// Where words that are `s` exactly are drawn now (Tester::words), the first of them.
fn words_exactly_at(t : @ui.Tester, s : String) -> (Double, Double, Double, Double)? {
  for w in t.words() {
    if w.0 == s {
      return Some((w.1, w.2, w.3, w.4))
    }
  }
  None
}

///|
#callsite(autofill(loc))
fn phone_agent_card(loc~ : SourceLoc) -> @ui.Tester {
  new_run()
  let src = fixture("chat-agent")
  open_fixture_over("chat-agent", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, loc~)
  t.run_for(@ui.move_most_ms)
  sheet_rested(t, "sf-present")
  t
}
