// A chat's messages as nodes (chat_body_node.mbt) set beside the old view's (chat_list.mbt chat_list) on the same
// fixture's chat: the same words where they were and the same rectangles drawn in the list, as it opens, at its top and
// in its middle; on 小屏 (a finger's, narrow), 中屏 and 大屏 (a mouse's, wide); as its view changes at rest.
//
// Those comparisons are a sweep of screens at rest, as the app's sweeps are (mbui's AGENTS.md, Time in a test is
// declared): run at the default rate alone (@ui.test_at_a_rate), their Testers' frames not judged for how what moves
// goes (Tester::motion_unjudged); they go with the old list. Not looked into for that: at 24 and 7 frames a second the
// old page's shell draws more of its round buttons over the list (317 things, 310 at the default rate: its bell and its
// outline's button come in a frame after the frame its list was laid out in, chat-viz's at its top and its middle);
// judged at 60 and 120, the old list put at a row at once by Tester::scroll_to is said to step, which is no motion but
// how each is put where it is compared. What only the nodes' list does (the page before read in, what was sent going on
// by its key, 正在发送 as the old shows it) is held at every rate and judged.

///|
/// The fixture's chat (open_fixture_mode's: the first row's).
// kept across runs: a value
let body_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
// kept across runs: a value
let body_ws : Workspace = { id: "ws1", name: "星火工作室", emoji: "", icon: "", email: "" }

///|
/// The composer's room under the rows in both (what the list keeps clear for it: chat_list's `room`).
let body_room : Double = 96.0

///|
/// The room under a chat's rows (chat_list's Foot row's): the composer's, the list's foot, and where something waits to be
/// decided the bell's room over it (ask_clears).
fn body_foot(v : ChatView) -> Double {
  body_room + list_foot + (if @sfbase.ask_clears(v) { float_ask_clear } else { 0.0 })
}

///|
/// A screen a body is drawn on: its name, width, height and platform (0 a mouse's, 2 a finger's).
fn body_screens() -> Array[(String, Double, Double, Int)] {
  [("小屏", 390.0, 844.0, 2), ("中屏", 900.0, 760.0, 0), ("大屏", 1280.0, 800.0, 0)]
}

///|
/// Read the chat's view and entries from `src` (view_of_chat).
fn body_read(src : Source) -> (ChatView, Array[Entry])? {
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let (v, read, _) = @sfbase.view_of_chat(src, body_ref)
  v.map(fn(v) { (v, read) })
}

///|
/// What chat_body_node draws of chat view `view` (its entries `entries`, what was sent from here `sending`) over `src`,
/// `w` by `h` on `platform`; `place` where its list is asked to go; `made` told each row made; `unjudged` where it is a
/// sweep's screen at rest.
fn body_new(
  src : Source,
  w : Double,
  h : Double,
  platform : Int,
  view : @signals.Signal[ChatView],
  entries : @signals.Signal[Array[Entry]],
  place? : @view.ListPlace[String] = @view.ListPlace::new(),
  made? : (String, @view.View) -> Unit = fn(_, _) {  },
  begun? : (@view.View) -> Unit = fn(_) {  },
  px? : Double = 2.0,
  unjudged? : Bool = false,
) -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: body_ref.station,
        session: body_ref.session,
        view: fn() { view.get() },
        width: fn() { w },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(
          f,
          src,
          here,
          fn() { entries.get() },
          sending=fn() { @sfbase.sending_now(body_ref.station + "\u{1}" + body_ref.session) },
          core=Some(@sfbase.settings_core(src, body_ws)),
          foot=fn() { body_foot(view.get()) },
          place~,
          made~,
        )
        |> ignore
        begun(f)
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w~,
    h~,
    platform~,
    scale=px,
  )
  // (its rows on the device's pixels as every platform's host lays them: body_pixels)
  t.set_rows_on_pixels(true)
  // (a sweep's screen at rest: how what moves goes not judged on its frames, `unjudged`)
  t.motion_unjudged(unjudged)
  t
}

///|
/// A place to a hundredth of a point (the old view's sums leave tails the nodes' do not).
fn body_r(x : Double) -> Double {
  (x * 100.0).round() / 100.0
}

///|
/// A row as a Tester draws it: its key, its top in the window, how high it is laid out (on whole pixels: row_slot's),
/// what is drawn in it, each from its top.
priv struct BodyRow {
  key : String
  top : Double
  h : Double
}

///|
/// What a Tester draws of a chat's list in its window: its rows shown, top to bottom; what is drawn in none of them
/// (from the window's top); how many things floated over it (body_floats'); the most bytes its host held for decodes.
priv struct BodyDrawn {
  rows : Array[BodyRow]
}

///|
/// What Tester `t` (the old view's where `old`) draws in its window `w` by `h`, its list's rows where `rows` says they
/// are (each its key, top and height), those seen in it, each thing drawn in the row its top is in; what is in none
/// of them, as far as it is seen.
fn body_drawn(_t : @ui.Tester, _w : Double, h : Double, rows : Array[(String, Double, Double)]) -> BodyDrawn {
  let shown = rows.filter(fn(r) { r.2 > 0.0 && r.1 + r.2 > 0.0 && r.1 < h })
  shown.sort_by(fn(a, b) { a.1.compare(b.1) })
  let drawn : Array[BodyRow] = shown.map(fn(r) { { key: r.0, top: r.1, h: r.2 } })
  { rows: drawn }
}

///|
/// Fixture `mode`'s chat's source with the page before held back: its ask (chat.older) never answered, so neither
/// list reads a page in as it comes to its top and what both show is the screen before that answer, at every rate of
/// frames (a page read in is body_page_read's).
fn body_src(mode : String) -> Source {
  let src = @sffixture.fixture(mode)
  { ..src, call: fn(name, params, done) { if name != "chat.older" { (src.call)(name, params, done) } } }
}

///|
/// The nodes' key of each of chat view `v`'s entries `read` (chat_body_rows'; its Foot "foot", the list's room under
/// its rows and no row of the nodes').
fn body_keys(v : ChatView, read : Array[Entry]) -> Array[String] {
  // (a long message's slices one row, as the old list draws it: its key)
  let keys = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, v, read, []).keys
  let out : Array[String] = []
  let mut j = 0
  for e in read {
    if e is Foot {
      out.push("foot")
    } else if e is Top {
      out.push("top")
    } else {
      out.push(keys[j])
      j += 1
    }
  }
  out
}

///|
/// The block `p` holds row `k` now (chat_body_node's `made`: made for it, or a block put by and taken for it), what
/// `views` says of each row's block: none other said to be held by it.
fn body_view_holds(views : Map[String, @view.View], k : String, p : @view.View) -> Unit {
  let gone : Array[String] = []
  for kv in views {
    if kv.0 != k && kv.1.id() == p.id() {
      gone.push(kv.0)
    }
  }
  for g in gone {
    views.remove(g)
  }
  views[k] = p
}

///|
/// The key of the row a block told as made (chat_body_node's `made`) is of: a slice after a long message's first told as
/// `k#b`, its message's `k`.
fn body_slice_of(k : String) -> String {
  match k.rev_find("#") {
    Some(i) if k.has_prefix("m:") => k.unsafe_substring(start=0, end=i)
    _ => k
  }
}

///|
/// The nodes' rows, each the node its row was made in (`views`, chat_body_node's `made`) while it is: its key, its top,
/// its height on whole pixels `g` a point (row_slot's, as the list lays its blocks on the pixels).
fn body_new_rows(views : Map[String, @view.View], g : Double, h : Double) -> Array[(String, Double, Double)] {
  // (a long message's pieces (chat_body_pieces) one row, as the old list draws the message: from its first's top to
  // its last's foot, by its first's key)
  let spans : Map[String, (Double, Double)] = Map([])
  let order : Array[String] = []
  body_piece_counts.clear()
  for kv in views {
    // (one put by out of sight for the next of its make (chat_body_shape) is no row that shows)
    let r = kv.1.placed_window_now()
    if kv.1.alive() && !kv.1.shown_nowhere() && r.1 < h && r.1 + r.3 > 0.0 {
      let k = body_slice_of(kv.0)
      body_piece_counts[k] = body_piece_counts.get(k).unwrap_or(0) + 1
      let foot = r.1 + (r.3 * g - 0.000001).ceil() / g
      match spans.get(k) {
        Some((top, bottom)) => spans[k] = (dmin(top, r.1), dmax(bottom, foot))
        None => {
          spans[k] = (r.1, foot)
          order.push(k)
        }
      }
    }
  }
  order.map(fn(k) {
    let (top, bottom) = spans[k]
    (k, top, bottom - top)
  })
}

///|
/// The fixture's modes of a chat (sffixture's, corner_modes' chat-* that put nothing over the chat but its rows' own
/// states): its first row's chat as each says it.
fn body_modes() -> Array[String] {
  [
    "chat", "chat-ask-end", "chat-working", "chat-done", "chat-cards", "chat-quote", "chat-image-coming", "chat-download",
    "chat-sending", "chat-failed", "chat-need", "chat-login", "chat-rig", "chat-vault", "chat-phone", "chat-md", "chat-long",
    "chat-letters", "chat-viz", "chat-screens", "chat-update", "chat-agent", "chat-feishu",
  ]
}

///|
/// How many pieces each long message's row was drawn in by the nodes (body_new_rows'), by its first piece's key.
// kept across runs: written by body_new_rows as each case is read
let body_piece_counts : Map[String, Int] = Map([])

///|
/// Whether a fault of the nodes' audit is one known of a row's head (message_head_node.mbt's time, pressed in a room
/// short of a press's least where the old arrangement has it: 「刚刚」, 「昨天」), the agent rows' test's rule
/// (message_agent_node_wbtest's ag_rooms): the old arrangement's, held exactly, only to fall.
fn body_time_short(f : String) -> Bool {
  f.has_prefix("room: ") && f.contains("stillfail/src/sfpages/message_head_node.mbt:") && f.contains("to be pressed in, under")
}

///|
test "a chat's messages made once as nodes pass audit across each fixture's chat on 小屏, 中屏 and 大屏, at its end, its top and its middle" {
  if @ui.test_at_a_rate() {
    return
  }
  let said : Array[String] = []
  for mode in body_modes() {
    for s in body_screens() {
      for at in ["end", "top", "mid"] {
        @sfbase.reset()
        reset()
        let src = body_src(mode)
        guard body_read(src) is Some((v0, read0)) else {
          said.push("\{mode} \{s.0} \{at}: no view")
          continue
        }
        let keys0 = body_keys(v0, read0)
        let at_i = match at {
          "top" => 0
          "mid" => read0.length() / 2
          _ => read0.length() - 2
        }
        let put = keys0[at_i]
        let view = @signals.signal(v0)
        let entries = @signals.signal(read0)
        let place : @view.ListPlace[String] = @view.ListPlace::new()
        let t = body_new(src, s.1, s.2, s.3, view, entries, place~, unjudged=true)
        let rest = @ui.move_most_ms + (if mode == "chat-sending" { sending_shows_ms } else { 0.0 })
        t.run_for(rest)
        if at != "end" {
          if put == "top" {
            place.bring(keys0.iter().find_first(fn(k) { k != "top" }).unwrap(), offset=bar_foot - list_top)
          } else {
            place.bring(put, offset=bar_foot)
          }
          t.run_for(@ui.move_most_ms)
        }
        for f in t.audit() {
          if !body_time_short(f) {
            said.push("\{mode} \{s.0} \{at}: \{f}")
          }
        }
      }
    }
  }
  assert_eq(said, [], msg=said.join("\n"))
}

///|
test "a chat's messages made once as nodes at the system's words set to 1.3, on 小屏: pass audit and every box holds its words" {
  if @ui.test_at_a_rate() {
    return
  }
  let said : Array[String] = []
  let s = body_screens()[0]
  for mode in body_modes() {
    @sfbase.reset()
    reset()
    let src = body_src(mode)
    guard body_read(src) is Some((v0, read0)) else {
      said.push("\{mode} 1.3: no view")
      continue
    }
    let view = @signals.signal(v0)
    let entries = @signals.signal(read0)
    let t = body_new(src, s.1, s.2, s.3, view, entries, unjudged=true)
    t.set_font_scale(1.3)
    let rest = @ui.move_most_ms + (if mode == "chat-sending" { sending_shows_ms } else { 0.0 })
    t.run_for(rest)
    for f in t.audit() {
      if !body_time_short(f) {
        said.push("\{mode} 1.3: \{f}")
      }
    }
    for f in t.fixed_outgrown() {
      said.push("\{mode} 1.3 outgrown: \{f}")
    }
  }
  assert_eq(said, [], msg=said.join("\n"))
}

///|
/// A paragraph of the core's Markdown saying `words`.
fn body_md(words : String) -> Json {
  Json::array([Json::array([Json::string("p"), Json::array([Json::string(words)])])])
}

///|
/// A paragraph of the core's Markdown saying `words`, a block of it.
fn body_para(words : String) -> Json {
  Json::array([Json::string("p"), Json::array([Json::string(words)])])
}

///|
/// What a chat's view comes to, step by step, from the fixture's (`v`): its name and the view after it.
fn body_steps(v : ChatView) -> Array[(String, ChatView)] {
  let last = v.messages[v.messages.length() - 1]
  let came : Message = {
    ..last,
    seq: 900.0,
    ts: "ts900",
    text: "又来了一条：列表的高度也量过了。",
    md: Some(body_md("又来了一条：列表的高度也量过了。")),
    decision: None,
    options: None,
    card: None,
    asked: false,
    followed: false,
    joined: false,
  }
  let v1 = { ..v, messages: v.messages + [came] }
  let changed = { ..came, text: "改过的字：列表的高度量过一次就记住，换了宽度再量，滚到时才量没量过的那些行。", md: Some(body_md("改过的字：列表的高度量过一次就记住，换了宽度再量，滚到时才量没量过的那些行。")) }
  let v2 = { ..v1, messages: v.messages + [changed] }
  let a = v2.agents[0]
  let v3 = { ..v2, agents: [{ ..a, status: "running", started: true }] + v2.agents[1:].to_owned() }
  let v4 = { ..v3, agents: v2.agents }
  let failed : Outgoing = { ..chat_body_no_out, id: "o-9", text: "这条没发出去", state: "failed", error: "station 不在线" }
  let v5 = { ..v4, outbox: [failed] }
  let v6 = { ..v5, outbox: [{ ..failed, state: "sent", error: "", seq: 901.0, time: last.time }] }
  let mine : Message = {
    ..came,
    seq: 901.0,
    ts: "ts901",
    text: "这条没发出去",
    md: None,
    author_kind: "person",
    mine: true,
    outgoing: "o-9",
    by: { ..came.by, name: "林", agent: "" },
  }
  let v7 = { ..v6, outbox: [], messages: v2.messages + [mine] }
  [
    ("a message comes", v1),
    ("its words change", v2),
    ("its agent at work", v3),
    ("its turn over", v4),
    ("one not sent", v5),
    ("sent after all", v6),
    ("the core has it as a message", v7),
  ]
}

///|
test "a chat's messages as nodes as its view changes, at rest after each: a row made only as it comes, what was not sent going on by its key" {
  // (a sweep of screens at rest: the default rate's alone, its frames not judged; the file's head says why)
  if @ui.test_at_a_rate() {
    return
  }
  let said : Array[String] = []
  for s in [body_screens()[0], body_screens()[2]] {
    @sfbase.reset()
    reset()
    let src = @sffixture.fixture("chat")
    let v0 = body_read(src).unwrap().0
    let steps = body_steps(v0)
    @sfbase.reset()
    reset()
    let src = @sffixture.fixture("chat")
    let view = @signals.signal(v0)
    let entries = @signals.signal(@sfbase.entries_of(v0))
    let made : Map[String, Int] = Map([])
    let views : Map[String, @view.View] = Map([])
    let t = body_new(
      src,
      s.1,
      s.2,
      s.3,
      view,
      entries,
      made=fn(k, p) {
        made[k] = made.get(k).unwrap_or(0) + 1
        body_view_holds(views, k, p)
      },
      unjudged=true,
    )
    t.run_for(@ui.move_most_ms)
    let mut before : BodyDrawn? = None
    for st in steps {
      let was = made.copy()
      let read = @sfbase.entries_of(st.1)
      view.set(st.1)
      entries.set(read)
      t.run_for(@ui.move_most_ms)
      let drawn = body_drawn(t, s.1, s.2, body_new_rows(views, 2.0, s.2))
      if st.0 == "its turn over" {
        match before {
          Some(b) => body_turn_over_held(s.0 + " " + st.0, b, drawn, said)
          None => said.push(s.0 + " " + st.0 + ": no step before it")
        }
      }
      before = Some(drawn)
      // what was made for it: only the row that came (or came to be another kind of row), and a row the list let go
      // of as it went out of view coming into it again; none made again for nothing
      let again = made.iter().filter(fn(kv) { was.get(kv.0).unwrap_or(0) != kv.1 }).map(fn(kv) { kv.0 }).collect()
      let want = match st.0 {
        "a message comes" => ["m:ts900"]
        "its agent at work" => ["act:s-c1"]
        // (its agent's line gone leaving its room: nothing comes down, so none comes into view to be made; the old
        // list's case, which came down and made m:ts7 again on a phone's window, turned on purpose (above))
        "one not sent" => ["o:o-9"]
        // (what was sent from here as the core's message: its key the outbox entry's, its row the same, none made: what
        // is sent and what it becomes are one row, its words' node kept so a finger's pick over them stays)
        _ => []
      }
      again.sort()
      if again != want {
        said.push("\{s.0} \{st.0}: rows made " + again.join(" ") + ", wanted " + want.join(" "))
      }
    }
    for f in t.audit() {
      if !body_time_short(f) {
        said.push("\{s.0}: " + f)
      }
    }
  }
  assert_eq(said, [], msg=said.join("\n"))
}

///|
/// Its turn over on the page made as nodes (`name`), `now` against `before` (the step before, its agent's line the last
/// row): each row both draw where it was, no row of before's but the line gone, and the room under the last row as tall
/// as the line was drawn then (the line's foot where it was), in `said` where not.
fn body_turn_over_held(name : String, before : BodyDrawn, now : BodyDrawn, said : Array[String]) -> Unit {
  guard before.rows.iter().find_first(fn(r) { r.key.has_prefix("act:") }) is Some(line) else {
    said.push(name + ": no agent's line the step before")
    return
  }
  for r in now.rows {
    match before.rows.iter().find_first(fn(b) { b.key == r.key }) {
      Some(b) =>
        if body_r(b.top) != body_r(r.top) {
          said.push(name + " " + r.key + ": its top \{body_r(b.top)} the step before, \{body_r(r.top)} now (held)")
        }
      None => said.push(name + " " + r.key + ": a row not drawn the step before")
    }
  }
  for b in before.rows {
    if b.key != line.key && b.top + b.h > 0.0 && !now.rows.iter().any(fn(r) { r.key == b.key }) {
      said.push(name + " " + b.key + ": drawn the step before, not now")
    }
  }
  match now.rows.last() {
    Some(last) => {
      let room = line.top + line.h - (last.top + last.h)
      if body_r(room) != body_r(line.h) {
        said.push(name + ": the room under the last row \{body_r(room)}, the line \{body_r(line.h)} high the step before")
      }
    }
    None => said.push(name + ": no row drawn")
  }
  if now.rows.iter().any(fn(r) { r.key == line.key }) {
    said.push(name + ": the agent's line still drawn")
  }
}

///|
/// The fixture's chat's source, its time of day the Tester's clock (`t`'s, once it is made): what was sent counts from
/// when it was sent on it (chat_rows.mbt outbox_row's).
fn body_clocked(t : Ref[@ui.Tester?]) -> Source {
  { ..@sffixture.fixture("chat"), now: fn() { t.val.map(fn(t) { t.time() }).unwrap_or(0.0) } }
}

///|
/// How opaque each 正在发送 a Tester draws is.
fn body_sending(t : @ui.Tester) -> Array[Double] {
  t.words().filter(fn(w) { w.0 == @sf.t("web-main.chat.sending") }).map(fn(w) { w.5 })
}

///|
/// What is sent from here in fixture `case` ("pressed": words sent now; "opened": a chat opened on what has been on its
/// way 5 s; "taken": words sent now, the core's outbox entry taking it over, another id, half way to sending_shows_ms),
/// as a Tester draws it, `given` its view as each step says: how opaque its 正在发送 is half way to sending_shows_ms
/// from the press (or the opening), then at it, then after it.
fn body_sent_steps(
  t : @ui.Tester,
  src : Source,
  v0 : ChatView,
  case : String,
  give : (ChatView) -> Unit,
) -> Array[Array[Double]] {
  let rk = body_ref.station + "\u{1}" + body_ref.session
  let out : Outgoing = { ..chat_body_no_out, id: "core-1", text: "刚发的一句", state: "sending" }
  match case {
    "opened" => {
      let v = { ..v0, outbox: [{ ..out, created_at: (src.now)() - 5000.0 }] }
      give(v)
    }
    _ => {
      give(v0)
      @sfbase.sent_local(rk, Some(v0), "刚发的一句", [], now=(src.now)()) |> ignore
    }
  }
  let sent_at = (src.now)()
  let said : Array[Array[Double]] = []
  t.run_for(sending_shows_ms / 2.0)
  said.push(body_sending(t))
  if case == "taken" {
    give({ ..v0, outbox: [{ ..out, created_at: sent_at }] })
  }
  t.run_for(sending_shows_ms / 2.0 + msg_part_leave_ms)
  said.push(body_sending(t))
  t.run_for(sending_shows_ms / 2.0)
  said.push(body_sending(t))
  said
}

///|
test "words sent from here as nodes: 正在发送 seen sending_shows_ms after they were sent: just sent, opened on one long on its way, taken over by the core's outbox entry" {
  for case in ["pressed", "opened", "taken"] {
    @sfbase.reset()
    reset()
    let held : Ref[@ui.Tester?] = Ref(None)
    let src = body_clocked(held)
    let v0 = body_read(src).unwrap().0
    @sfbase.reset()
    reset()
    let held : Ref[@ui.Tester?] = Ref(None)
    let src = body_clocked(held)
    let view = @signals.signal(v0)
    let entries = @signals.signal(@sfbase.entries_of(v0))
    let made : Map[String, Int] = Map([])
    let t = body_new(src, 390.0, 844.0, 2, view, entries, made=fn(k, _) { made[k] = made.get(k).unwrap_or(0) + 1 })
    held.val = Some(t)
    t.run_for(@ui.move_most_ms)
    let now = body_sent_steps(t, src, v0, case, fn(v) {
      view.set(v)
      entries.set(@sfbase.entries_of(v))
    })
    let want = match case {
      "opened" => [[1.0], [1.0], [1.0]]
      // (half way to it, its time in 正在发送's place: none drawn at all, not one unseen; outbox_mine_under)
      _ => [[], [1.0], [1.0]]
    }
    assert_eq(now, want, msg="\{case}: \{Repr(now)}")
    if case == "taken" {
      // (the core's outbox entry is the row sent from here: no row of its own, the row not made again)
      assert_eq(made.get("o:core-1"), None, msg=case)
      assert_eq(made.get("o:local:1"), Some(1), msg=case)
    }
    assert_eq(t.audit(), [], msg=case)
  }
}

///|
test "what was sent from here goes on by the key it was sent as: the core's outbox entry, then its message, no row of their own" {
  @sfbase.reset()
  reset()
  let held : Ref[@ui.Tester?] = Ref(None)
  let src = body_clocked(held)
  // (a chat with a message in it already: the first sent into an empty one, its empty row and the room over the sent
  // one going in the frame it comes, is the list's way to make (xfer/l1-plan.md §5, PR C's), back here once it is)
  let first = @sfbase.message_of({
    "seq": 1,
    "thread": 7,
    "ts": "ts1",
    "authorKind": "agent",
    "text": "在这里。",
    "md": [["p", ["在这里。"]]],
    "by": { "name": "Claude", "agent": "s-c1" },
    "time": @sffixture.ago("刚刚", "2026-11-12 09:59"),
  })
  let v0 = @sfbase.chat_view_made({ "title": "整理发布清单", "messages": [], "thread": { "id": 7 } })
  let v0 = { ..v0, messages: [first] }
  let view = @signals.signal(v0)
  let entries = @signals.signal(@sfbase.entries_of(v0))
  let made : Map[String, Int] = Map([])
  let t = body_new(src, 390.0, 844.0, 2, view, entries, made=fn(k, _) { made[k] = made.get(k).unwrap_or(0) + 1 })
  held.val = Some(t)
  t.run_for(@ui.move_most_ms)
  let rk = body_ref.station + "\u{1}" + body_ref.session
  let key = @sfbase.sent_local(rk, Some(v0), "刚发的一句", [], now=(src.now)())
  t.run_for(@ui.move_most_ms)
  assert_eq(made.get(key), Some(1), msg="its row made as it is sent")
  let out : Outgoing = { ..chat_body_no_out, id: "core-1", text: "刚发的一句", state: "sent", seq: 3.0 }
  let v1 = { ..v0, outbox: [out] }
  view.set(v1)
  entries.set(@sfbase.entries_of(v1))
  t.run_for(@ui.move_most_ms)
  assert_eq(made.get("o:core-1"), None, msg="the core's outbox entry is the row sent from here")
  assert_eq(made.get(key), Some(1), msg="not made again for the core's entry")
  let m = @sfbase.message_of({
    "seq": 3,
    "thread": 7,
    "ts": "ts3",
    "authorKind": "person",
    "mine": true,
    "text": "刚发的一句",
    "outgoing": "core-1",
    "by": { "name": "林" },
    "time": @sffixture.ago("刚刚", "2026-11-12 10:00"),
  })
  let v2 = { ..v0, messages: [first, m] }
  view.set(v2)
  entries.set(@sfbase.entries_of(v2))
  t.run_for(@ui.move_most_ms)
  assert_eq(made.get("m:ts3"), None, msg="the core's message is the row sent from here")
  assert_eq(made.get("o:core-1"), None, msg="the core's message is the row sent from here")
  // (its block the same, by the key it was sent as, and what it holds not made again: what is sent and what it becomes
  // are one row, its words' node the one made as it was sent, so a finger's pick over them keeps its handles and menu)
  assert_eq(made.get(key), Some(1), msg="no row made as the core's message takes it over: its words' node the same")
  assert_true(t.words().iter().any(fn(w) { w.0 == "刚发的一句" }))
  assert_eq(t.audit().filter(fn(f) { !f.contains("刚刚") }), [])
}

///|
///|
test "the page before read in over a chat's list as nodes at its top: what is read does not move" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat-working")
  let s = body_screens()[0]
  // (the chat's view as its first frame reads it (view_of_chat in chat_list's build), then once the core has read the
  // page before in: both read as a list's frame reads them, no list drawn of them)
  let (v0, read0) = body_read(src).unwrap()
  let answered : Ref[Bool] = Ref(false)
  (src.call)("chat.older", { "station": Json::string(body_ref.station), "thread": Json::number(v0.thread.unwrap()) }, fn(
    r,
  ) {
    answered.val = r is Ok(_)
  })
  let (v1, read1) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat-working")
  let view = @signals.signal(v0)
  let entries = @signals.signal(read0)
  let views : Map[String, @view.View] = Map([])
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  let t = body_new(src, s.1, s.2, s.3, view, entries, place~, made=fn(k, p) { body_view_holds(views, k, p) })
  t.run_for(@ui.move_most_ms)
  let keys0 = body_keys(v0, read0)
  // (at its very top: its first row under its head, the chat's bar's room, as far as the list goes: a bring's offset
  // is from under what covers the list's top, the bar)
  place.bring(keys0.iter().find_first(fn(k) { k != "top" }).unwrap())
  t.run_for(@ui.move_most_ms)
  let read_key = keys0.iter().find_first(fn(k) { k.has_prefix("m:") }).unwrap()
  let before = views[read_key].placed_window_now().1
  // (the core's answer to the page before, asked as the list came to its top: the chat's view as it says it then)
  assert_true(body_keys(v1, read1).length() > keys0.length(), msg="the page before read in")
  view.set(v1)
  entries.set(read1)
  t.run_for(@ui.move_most_ms)
  // (what is read does not move: the page in over it, its head gone up with what comes in, the message read at its
  // top where it was, as the old list holds it)
  match views.get(read_key) {
    Some(p) if p.alive() =>
      assert_eq(body_r(p.placed_window_now().1), body_r(before), msg="\{read_key} where it was")
    _ => fail("\{read_key}, at \{body_r(before)} before, let go")
  }
  assert_eq(t.audit().filter(fn(f) { !body_time_short(f) }), [])
}

///|
/// How many of the tree's bindings were looked at again so far (Tree::work's `bound`).
fn body_bound() -> Int {
  @ui.view_tree().unwrap().work().bound
}

///|
test "a chat's list as nodes given the same entries again reads none of its rows again; one row changed, fewer than every row's" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let s = body_screens()[0]
  let (v0, read0) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let view = @signals.signal(v0)
  let entries = @signals.signal(read0)
  let made : Map[String, Int] = Map([])
  let t = body_new(src, s.1, s.2, s.3, view, entries, made=fn(k, _) { made[k] = made.get(k).unwrap_or(0) + 1 })
  t.run_for(@ui.move_most_ms)
  let made0 = made.copy()
  // the same entries again (another array, each entry as it was): no row's binding looked at again
  let b0 = body_bound()
  entries.set(read0.copy())
  t.run_for(@ui.move_most_ms)
  let same = body_bound() - b0
  assert_eq(same, 0, msg="the same entries again looked at \{same} bindings")
  // the last message's words changed: that row's
  let mut last = -1
  for i, e in read0 {
    if e is Said(_) {
      last = i
    }
  }
  guard last >= 0 && read0[last] is Said(m) else { fail("no message") }
  let words = "改过的字：只有这一行重读。"
  let one = read0.copy()
  one[last] = Said({ ..m, text: words, md: Some(body_md(words)) })
  let b1 = body_bound()
  entries.set(one)
  t.run_for(@ui.move_most_ms)
  let one_row = body_bound() - b1
  assert_true(t.find(words) is Some(_), msg="its new words drawn")
  // every message made anew as it was (read again from its JSON): the same, no row's binding looked at again
  let anew = one.map(fn(e : Entry) -> Entry {
    match e {
      Said(m) => Said({ ..m, text: m.text })
      e => e
    }
  })
  let b_anew = body_bound()
  entries.set(anew)
  t.run_for(@ui.move_most_ms)
  let anew_rows = body_bound() - b_anew
  assert_eq(anew_rows, 0, msg="every message made anew as it was looked at \{anew_rows} bindings")
  // every message another: every row's
  let all = one.map(fn(e : Entry) -> Entry {
    match e {
      Said(m) => {
        // (its Markdown made here, as the one changed above: nothing asked of the core)
        let words = m.text + "。"
        Said({ ..m, text: words, md: Some(body_md(words)) })
      }
      e => e
    }
  })
  let b2 = body_bound()
  entries.set(all)
  t.run_for(@ui.move_most_ms)
  let every = body_bound() - b2
  assert_true(
    one_row > 0 && one_row < every,
    msg="one row changed looked at \{one_row} bindings, every row \{every}",
  )
  assert_eq(made, made0, msg="no row made again")
}

///|
test "a long message a block a piece: the pointer on any of its pieces shows its ⋯, as on its first" {
  @sfbase.reset()
  reset()
  @sf.presenters_reset()
  let src = @sffixture.fixture("chat")
  let s = body_screens()[1]
  let (v0, read0) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  // (its last agent's message three paragraphs, a piece each)
  let mut last = -1
  for i, e in read0 {
    if e is Said(m) && chat_body_pieces(Said({ ..m, text: "a\n\nb", md: Some(Json::array([body_para("a"), body_para("b")])) })) is Some(_) {
      last = i
    }
  }
  guard last >= 0 && read0[last] is Said(m) else { fail("no agent's message") }
  let ps = ["头一段：列表一块是一行。", "第二段：长消息按块拆开。", "第三段：指针在哪一块上，⋯ 都在。"]
  let md = Json::array(ps.map(body_para))
  let read = read0.copy()
  read[last] = Said({ ..m, text: ps.join("\n\n"), md: Some(md) })
  let t = body_new(src, s.1, s.2, s.3, @signals.signal(v0), @signals.signal(read))
  t.run_for(@ui.move_most_ms)
  let more = fn() { t.query(Button, label=@sf.t("web-main.menu.more")) is Some(_) }
  assert_false(more(), msg="no ⋯ with the pointer off it")
  let at = fn(words : String) -> (Double, Double) {
    match t.run_rects(words).get(0) {
      Some(r) => (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
      None => @halt.saying("no words drawn holding \{words}")
    }
  }
  for p in ps {
    let (x, y) = at(p)
    t.move_to(x, y)
    t.run_for(@ui.move_most_ms)
    assert_true(more(), msg="its ⋯ with the pointer on " + p)
  }
  t.move_to(2.0, 2.0)
  t.run_for(@ui.move_most_ms)
  assert_false(more(), msg="no ⋯ with the pointer gone")
}

///|
/// The core's reading of a paragraph `words` and a table under it of `rows` rows (its head's not counted) and `cols`
/// columns, each cell's words `r<row>c<col>` and a long run of x, so that it is wider than a pane and scrolls across.
fn body_long_table(words : String, rows : Int, cols : Int) -> Json {
  let cell = fn(r : Int, c : Int) {
    Json::array([Json::string("td"), Json::array([Json::string("r\{r}c\{c}xxxxxxxxxxxxxxxxxxxxxxxxxxxx")])])
  }
  let line = fn(r : Int) { Json::array([Json::string("tr"), Json::array(Array::makei(cols, fn(c) { cell(r, c) }))]) }
  Json::array([
    body_para(words),
    Json::array([
      Json::string("table"),
      Json::array(Array::makei(rows + 1, line)),
      Json::object({ "md": Json::string(""), "csv": Json::string("") }),
    ]),
  ])
}

///|
test "a long table a few rows a piece: each piece a block of the list, all of them scrolled across as one" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let s = body_screens()[1]
  let (v0, read0) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let md = body_long_table("表格在下面。", 13, 8)
  let mut last = -1
  for i, e in read0 {
    if e is Said(m) && chat_body_pieces(Said({ ..m, text: "表格在下面。\n\n| a |", md: Some(md) })) is Some(_) {
      last = i
    }
  }
  guard last >= 0 && read0[last] is Said(m) else { fail("no agent's message") }
  let said : Entry = Said({ ..m, text: "表格在下面。\n\n| a |", md: Some(md) })
  // (its paragraph, then its 14 rows (its head's with them) 4 a piece: 4, 4, 4, 2)
  let ps = chat_body_pieces(said).unwrap()
  assert_eq(ps.map(fn(p) { p.rows }), [None, Some((0, 4)), Some((4, 8)), Some((8, 12)), Some((12, 14))])
  assert_true(ps[4].last && !ps[3].last)
  let read = read0.copy()
  read[last] = said
  let t = body_new(src, s.1, s.2, s.3, @signals.signal(v0), @signals.signal(read))
  t.run_for(@ui.move_most_ms)
  let x_of = fn(words : String) -> Double {
    match t.run_rects(words).get(0) {
      Some(r) => r.0
      None => @halt.saying("no words drawn holding \{words}")
    }
  }
  // (every row drawn, each piece's under the one before, its first column at one place)
  let first = x_of("r1c0")
  let low = x_of("r13c0")
  assert_eq(low, first)
  // (the wheel across over its first rows: its last rows moved as far)
  let (_, y, _, _) = t.run_rects("r1c0").get(0).unwrap()
  t.wheel_with(first + 40.0, y + 4.0, 200.0, 0.0, 0)
  t.run_for(@ui.move_most_ms)
  let moved = first - x_of("r1c0")
  assert_true(moved > 0.0, msg="its first rows scrolled across: \{moved}")
  assert_eq(first - x_of("r13c0"), moved, msg="its last rows scrolled as far as its first")
  assert_eq(first - x_of("r7c0"), moved, msg="its middle rows too")
}

///|
/// The core's reading of a table of `rows` rows (its head's not counted) and `cols` columns, each cell's words
/// `r<row>c<col>` and a run of x (`fill` more in its first column's), a paragraph `words` over it where it says one.
fn body_wide_table(words : String?, rows : Int, cols : Int, fill? : Int = 0) -> Json {
  let xs = fn(n : Int) { "x".repeat(n) }
  let cell = fn(r : Int, c : Int) {
    Json::array([Json::string("td"), Json::array([Json::string("r\{r}c\{c}" + xs(if c == 0 { 4 + fill } else { 28 }))])])
  }
  let line = fn(r : Int) { Json::array([Json::string("tr"), Json::array(Array::makei(cols, fn(c) { cell(r, c) }))]) }
  let table = Json::array([
    Json::string("table"),
    Json::array(Array::makei(rows + 1, line)),
    Json::object({ "md": Json::string(""), "csv": Json::string("") }),
  ])
  match words {
    Some(w) => Json::array([body_para(w), table])
    None => Json::array([table])
  }
}

///|
/// What body_table_case read of the chat by the old body, by screen.
// kept across runs: written by body_table_case as each screen is read
let body_table_read : Map[Int, (ChatView, Array[Entry])] = Map([])

///|
/// A chat's list as nodes on screen `si` (body_screens'), its last agent's message `md` and `text` (said while the chat
/// shows where `said`), its messages' files and pictures taken off (none decoded: as many cases as a test makes): the
/// Tester, the entries it is given (to give it others), that message as it is in them, its place among them and what
/// asks the list where to be.
fn body_table_case(
  si : Int,
  text : String,
  md : Json,
  said : Bool,
) -> (@ui.Tester, @signals.Signal[Array[Entry]], Message, Int, @view.ListPlace[String]) {
  let s = body_screens()[si]
  // (the chat's view and entries as view_of_chat says them on that screen: read once a screen, by the old body)
  let (v0, read0) = match body_table_read.get(si) {
    Some(r) => r
    None => {
      @sfbase.reset()
      reset()
      let src = @sffixture.fixture("chat")
      let r = body_read(src).unwrap()
      body_table_read[si] = r
      r
    }
  }
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let read = read0.map(fn(e) -> Entry {
    match e {
      Said(m) => Said({ ..m, attachments: [], placed: [] })
      e => e
    }
  })
  let mut last = -1
  for i, e in read {
    if e is Said(m) && chat_body_pieces(Said({ ..m, text: "| a |", md: Some(body_wide_table(None, 13, 2)) })) is Some(_) {
      last = i
    }
  }
  guard last >= 0 && read[last] is Said(m) else { @halt.saying("no agent's message") }
  let m = { ..m, text, md: Some(md), said }
  read[last] = Said(m)
  let entries = @signals.signal(read)
  let place = @view.ListPlace::new()
  let t = body_new(src, s.1, s.2, s.3, @signals.signal(v0), entries, place~)
  t.run_for(@ui.move_most_ms)
  (t, entries, m, last, place)
}

///|
/// The words of a table of `rows` rows (its head's not counted) under a paragraph `words` where it says one, with the
/// same intro text before it and an expanding row count (a message edited in place).
fn body_wide_text(words : String?, rows : Int) -> String {
  let lines = Array::makei(rows + 1, fn(r) { "| r\{r} |" })
  match words {
    Some(w) => w + "\n\n" + lines.join("\n")
    None => lines.join("\n")
  }
}

///|
/// Where words holding `words` are drawn first along the row, and where they end, in `t`.
fn body_x_of(t : @ui.Tester, words : String) -> (Double, Double) {
  match t.run_rects(words).get(0) {
    Some(r) => (r.0, r.0 + r.2)
    None => @halt.saying("no words drawn holding \{words}")
  }
}

///|
/// Table rows `rows` of `t` scrolled across as far as they go by the wheel over row `over`'s first cell: where each
/// row's first cell is then.
fn body_swiped(t : @ui.Tester, over : String, rows : Array[Int]) -> Array[Double] {
  let (x, _) = body_x_of(t, over)
  let (_, y, _, _) = t.run_rects(over).get(0).unwrap()
  t.wheel_with(x + 20.0, y + 4.0, 5000.0, 0.0, 0)
  t.run_for(@ui.move_most_ms)
  rows.map(fn(r) { body_x_of(t, "r\{r}c0").0 })
}

///|
test "a long table a few rows a piece scrolled across to its end, wheeled over its first rows or its last: every piece as far, on a wide pane and a phone's" {
  for si in [0, 2] {
    for over in ["r1c0", "r13c0"] {
      let (t, _, _, _, _) = body_table_case(si, body_wide_text(Some("表格在下面。"), 13), body_wide_table(Some("表格在下面。"), 13, 8), false)
      let xs = body_swiped(t, over, [1, 5, 7, 9, 13])
      assert_true(xs[0] < body_x_of(t, "表格在下面。").0, msg="\{body_screens()[si].0}: scrolled across: \{Repr(xs)}")
      assert_eq(xs, Array::make(5, xs[0]), msg="\{body_screens()[si].0}, wheeled over \{over}: \{Repr(xs)}")
      // (its last column at one place in its last rows as in its first, whole at its end: in the pane)
      assert_eq(body_x_of(t, "r13c7").0, body_x_of(t, "r1c7").0, msg="\{body_screens()[si].0}")
      assert_true(body_x_of(t, "r13c7").1 <= body_screens()[si].1, msg="\{body_screens()[si].0}: \{body_x_of(t, "r13c7").1}")
    }
  }
}

///|
test "a long table a few rows a piece a little wider than the pane, less than its copy key's room: its last rows scrolled across as far as its first" {
  // (its first column made wider a letter at a time till its first rows go across by less than the copy key's room)
  let mut found = false
  for fill in 0..<60 {
    let (t, _, _, _, _) = body_table_case(2, body_wide_text(Some("表格在下面。"), 13), body_wide_table(Some("表格在下面。"), 13, 4, fill~), false)
    let before = body_x_of(t, "r1c0").0
    let xs = body_swiped(t, "r1c0", [1, 5, 13])
    let gone = before - xs[0]
    // (less than the copy key's room, 44: table_copy.mbt's table_key_room)
    if gone > 0.0 && gone < 44.0 {
      assert_eq(xs, [xs[0], xs[0], xs[0]], msg="gone across \{gone}: \{Repr(xs)}")
      found = true
      break
    }
  }
  assert_true(found, msg="no table found a little wider than the pane")
}

///|
test "a table edited in place while the chat shows, from 3 rows to 10, as a message's first block or after a paragraph: its pieces scrolled across as one, no row drawn twice" {
  for words in [None, Some("表格在下面。")] {
    for si in [0, 2] {
      let (t, entries, m, last, place) = body_table_case(si, body_wide_text(words, 3), body_wide_table(words, 3, 8), true)
      // (more rows come: cut into pieces of 4 now)
      let read = entries.get().copy()
      read[last] = Said({ ..m, text: body_wide_text(words, 10), md: Some(body_wide_table(words, 10, 8)) })
      entries.set(read)
      t.run_for(@ui.move_most_ms)
      let label = "\{body_screens()[si].0}, \{if words is None { "first" } else { "after a paragraph" }}"
      // (the list at its foot, where the rows come: its every row in sight)
      place.to_end(glide=false)
      t.run_for(@ui.move_most_ms)
      let ys = Array::makei(11, fn(r) { t.run_rects("r\{r}c0").map(fn(q) { q.1 }) })
      for r in [1, 5, 9, 10] {
        assert_eq(t.run_rects("r\{r}c0").length(), 1, msg="\{label}: row \{r} drawn once: \{Repr(ys)}")
      }
      let xs = body_swiped(t, "r1c0", [1, 5, 9])
      assert_true(xs[0] < body_x_of(t, "r1c7").0, msg="\{label}: \{Repr(xs)}")
      assert_eq(xs, [xs[0], xs[0], xs[0]], msg=label)
      for c in 1..<8 {
        assert_eq(body_x_of(t, "r9c\{c}").0, body_x_of(t, "r1c\{c}").0, msg="\{label}: column \{c}")
      }
    }
  }
}

///|
test "a long list a few items a piece: each piece a block of the list, numbered on and in one indent as drawn whole" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let s = body_screens()[1]
  let (v0, read0) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat")
  let item = fn(i : Int) { Json::array([Json::string("li"), Json::array([Json::string("第\{i + 1}项要做的事")])]) }
  let md = Json::array([
    body_para("要做的有十件。"),
    Json::array([
      Json::string("list"),
      Json::array(Array::makei(10, item)),
      Json::object({ "ordered": Json::boolean(true), "start": Json::number(1.0) }),
    ]),
  ])
  let mut last = -1
  for i, e in read0 {
    if e is Said(m) && chat_body_pieces(Said({ ..m, text: "要做的有十件。\n\n1. a", md: Some(md) })) is Some(_) {
      last = i
    }
  }
  guard last >= 0 && read0[last] is Said(m) else { fail("no agent's message") }
  let said : Entry = Said({ ..m, text: "要做的有十件。\n\n1. a", md: Some(md) })
  // (its paragraph, then its ten items 3 a piece: 3, 3, 3, 1)
  let ps = chat_body_pieces(said).unwrap()
  assert_eq(ps.map(fn(p) { p.rows }), [None, Some((0, 3)), Some((3, 6)), Some((6, 9)), Some((9, 10))])
  let read = read0.copy()
  read[last] = said
  let t = body_new(src, s.1, s.2, s.3, @signals.signal(v0), @signals.signal(read))
  t.run_for(@ui.move_most_ms)
  let rect = fn(words : String) {
    match t.run_rects(words).get(0) {
      Some(r) => r
      None => @halt.saying("no words drawn holding \{words}")
    }
  }
  // (numbered on across its pieces, every item's words in one indent, each under the one before)
  assert_true(t.find("10.") is Some(_), msg="its last item numbered 10")
  let first = rect("第1项")
  let mut y = first.1
  for i in 1..<10 {
    let r = rect("第\{i + 1}项")
    assert_eq(r.0, first.0, msg="item \{i + 1} in the first's indent")
    assert_true(r.1 > y, msg="item \{i + 1} under the one before")
    y = r.1
  }
}

///|
test "chat_body_node scrollbar clears top cover and bottom composer by scroll_bar_clear" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat-long")
  let (v0, read0) = body_read(src).unwrap()
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat-long")
  let view = @signals.signal(v0)
  let entries = @signals.signal(read0)
  let scroll = @view.Scroll::list()
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  let cover_h = 48.0
  let composer_h = 80.0
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: body_ref.station,
        session: body_ref.session,
        view: fn() { view.get() },
        width: fn() { 900.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(
          f,
          src,
          here,
          fn() { entries.get() },
          sending=fn() { [] },
          core=Some(@sfbase.settings_core(src, body_ws)),
          cover=fn() { cover_h },
          foot=fn() { 24.0 },
          composer=fn(cv) { cv.box(fn(c) { c.height(Is(Some(composer_h))) |> ignore }) |> ignore },
          scroll~,
          place~,
        )
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=900.0,
    h=760.0,
    platform=0,
  )
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  let find_thumb = fn() {
    t
      .drawn_order()
      .filter(fn(d) { d.0 == 0 && d.3 == @ui.scroll_bar_size && d.1 > 880.0 && d.5 > 0.0 })
  }
  // Scroll all the way to the top and check top clearance
  scroll.put(0.0)
  t.run_for(@ui.move_most_ms)
  t.move_to(900.0 - @ui.scroll_bar_near + 1.0, 300.0)
  t.run_for(@ui.move_most_ms)
  let top_thumbs = find_thumb()
  assert_eq(top_thumbs.length(), 1, msg="top scrollbar thumb count")
  let tt = top_thumbs[0]
  let expected_top = cover_h + @ui.scroll_bar_clear + @ui.scroll_bar_inset
  assert_true(
    (tt.2 - expected_top).abs() <= 0.5,
    msg="top thumb y=\{tt.2} expected=\{expected_top}",
  )
  assert_true(
    (tt.1 + tt.3 - (900.0 - @ui.scroll_bar_inset)).abs() <= 0.5,
    msg="top thumb right=\{tt.1 + tt.3} expected=\{900.0 - @ui.scroll_bar_inset}",
  )
  // Scroll all the way to the bottom and check bottom clearance above composer
  place.to_end(glide=false)
  t.run_for(@ui.move_most_ms)
  t.move_to(900.0 - @ui.scroll_bar_near + 1.0, 300.0)
  t.run_for(@ui.move_most_ms)
  let bot_thumbs = find_thumb()
  assert_eq(bot_thumbs.length(), 1, msg="bottom scrollbar thumb count")
  let bt = bot_thumbs[0]
  let expected_bottom = 760.0 - composer_h - @ui.scroll_bar_clear - @ui.scroll_bar_inset
  assert_true(
    (bt.2 + bt.4 - expected_bottom).abs() <= 0.5,
    msg="bottom thumb foot=\{bt.2 + bt.4} expected=\{expected_bottom}",
  )
}
