// Switching on 中屏 and 大屏 sets nothing moving that the switch is not (the coordinator of the review, 2026-11-16): a chat
// picked in the sidebar, 新建对话 and back, another filter, another workspace, 设置 and back, the hand leaving the sidebar
// for the chat. A chat switched to is in its place at once: its composer laid out as it stays (no capsule opened into a
// box the frame after, the messages over it not lifted), its bar, its page and what floats over its list there as they
// are found; a workspace's lists made at their own filter, no slide along the track nor way down the column; the list's
// first answer, and the one that follows what was kept of it, taken at once; the order held while the hand was on the
// list put in place quietly as it leaves. Only what the person did moves: the filter's slide, a new chat's first words
// flying to their chat, and in one workspace the composer going between a chat's foot and a new chat's page as the
// sidebar switches the two (#1259, sfdesk's switch.mbt); never from a new chat left for another workspace or 设置. Each
// on the old chat page and the one made as nodes, at each rate of frames (run_for's way).

///|
/// A screen switched on: its name, the window's size (a mouse's, as a desktop's).
priv struct StillScreen {
  name : String
  w : Double
  h : Double
}

///|
let still_screens : Array[StillScreen] = [
  { name: "大屏", w: 1280.0, h: 800.0 },
  { name: "中屏", w: 900.0, h: 700.0 },
]

///|
/// How late the made-up core answers each call and every subscription (ms): a subscription asked again answered late
/// again, as a device's core does.
let still_late : Double = 60.0

///|
/// What of the composer and what floats over a chat's list moves by an old view's Anim, by its key: none of it is to
/// move for a switch.
let still_anims : Array[String] = ["composer/hint", "layout composer/box", "chat-jump", "chat-ask", "chat-outline"]

///|
/// A chat of the made-up workspace, by its session and title.
fn still_chat(session : String, title : String) -> ChatRef {
  { station: if session == "s-c3" { "ws1/st2" } else { "ws1/st1" }, session, title, station_name: "Willow" }
}

///|
/// The chats' list `params` asks for as the made-up core says it, `n` changes on: a chat come at the top of the first
/// day, the newest (another workspace's lists, empty in the fixture, given it as their first day).
fn still_chats(v : Json?, n : Int, params : Map[String, Json]) -> Json? {
  guard n > 0 && v is Some(Object(m)) else { return v }
  let m = m.copy()
  let come = @sffixture.row("z\{n}", "新来的对话 \{n}", "ws1/st1", "刚刚", {})
  let days = match m.get("days") {
    Some(Array(ds)) => ds.copy()
    _ => []
  }
  match days.get(0) {
    Some(Object(d)) => {
      let d = d.copy()
      let items = match d.get("items") {
        Some(Array(a)) => [come] + a
        _ => [come]
      }
      d["items"] = Json::array(items)
      days[0] = Json::object(d)
    }
    _ => days.push({ "daysAgo": 0, "at": 0, "label": "今天", "items": [come] })
  }
  ignore(params)
  m["days"] = Json::array(days)
  Some(Json::object(m))
}

///|
/// The app over the made-up workspace with chat 整理发布清单 open, in screen `s`
/// as a desktop's host draws it, the core answering still_late late and keeping what the lists said (lasting, read
/// ahead, as on a device); at rest, its composer's cursor gone long enough for it to be a capsule. And the chats' lists'
/// changes, a number: each one more a chat come at their top.
fn still_open(s : StillScreen) -> (@ui.Tester, Source, @signals.Signal[Int]) {
  new_run()
  let base = @sffixture.fixture("chat")
  // (read as the core's topic is worked out: a change of it told as the core tells one, to what holds the list)
  let bump = @signals.signal(0)
  let made : Source = {
    ..base,
    reads_ahead: fn() { true },
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      if name == "chats" {
        { ..t, value: still_chats(t.value, bump.get(), params) }
      } else {
        t
      }
    },
  }
  let src = round_trip_again(@sffixture.round_trip(made, still_late), 0.0, late=fn(_, _) { still_late })
  open_chat(still_chat("s-c1", "整理发布清单"))
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=s.w, h=s.h, platform=0)
  t.check_looks(false)
  t.draw()
  t.run_for(still_late * 8.0 + @ui.move_most_ms)
  still_cold(t)
  t.ways_set_out() |> ignore
  (t, src, bump)
}

///|
/// The cursor taken out of the composer (gone elsewhere, as a press outside it does), long enough for it to have let go
/// of its box: a capsule.
fn still_cold(t : @ui.Tester) -> Unit {
  t.ctx().blur()
  t.draw()
  t.run_for(@sfpages.let_go_ms + @sfpages.composer_shape_ms + @ui.move_most_ms)
}

///|
/// What moved after `act` (done at the moment it is called) till all its answers came and what it set out is over:
/// the ways the window's tree set out (where what went was made), and the composer's and the floats' Anims (still_anims)
/// that moved. Each a line.
fn still_after(t : @ui.Tester, act : () -> Unit, anims? : Array[String] = still_anims) -> Array[String] {
  t.ways_set_out() |> ignore
  let at = t.time()
  act()
  t.run_for(still_late * 8.0 + @ui.move_most_ms + 400.0)
  let out = t.ways_set_out().map(fn(w) { "way \{w.kind} +\{(w.at - at).round()} ms \{w.made} \{w.part}" })
  // (an Anim's line says its key, a float's with its chat's after it: chat-jump/<chat>, @sfbase.float_key)
  for name in anims {
    let rest = t.rest_of(name)
    if rest > at + 0.5 {
      out.push("anim \{name} at rest +\{(rest - at).round()} ms")
    }
  }
  out
}

///|
/// A row of the sidebar's list named `title` pressed.
fn still_pick(t : @ui.Tester, title : String) -> Unit {
  t.click(Link, label=title) catch {
    e => @halt.saying("no row 「\{title}」: \{e}")
  }
}

///|
/// The sidebar's 新建对话 pressed.
fn still_new_chat(t : @ui.Tester) -> Unit {
  t.click(Button, label="新建对话") catch {
    e => @halt.saying("no 新建对话: \{e}")
  }
}

///|
/// `f` as a person's act at the Tester's moment, between frames.
fn still_act(t : @ui.Tester, f : () -> Unit) -> Unit {
  @ui.view_tree().unwrap().event(t.time(), f)
}

///|
/// Each screen: `walk` says what moved where it should not, a line each.
fn still_each(walk : (StillScreen) -> Array[String]) -> Unit raise {
  let found = []
  for s in still_screens {
    for line in walk(s) {
      found.push("\{s.name}: \{line}")
    }
  }
  if found.length() > 0 {
    fail(found.join("\n"))
  }
}

///|
test "switch: chats picked one after another in the sidebar, the composer's cursor gone long: each in its place at once, nothing of the composer, the messages or what floats over them moving" {
  still_each(fn(s) {
    let (t, _, _) = still_open(s)
    let out = []
    // (the chat open read up from its end: the way to the newest shows over it, and stands there as it is come back to)
    let newest = @sf.t("web-main.chat.toLatest")
    let (lx, ly) = (s.w - 300.0, s.h / 2.0)
    for _ in 0..<6 {
      t.wheel(lx, ly, -240.0)
    }
    t.run_for(@ui.move_most_ms + 400.0)
    if t.query(Button, label=newest) is None {
      out.push("read up: no way to the newest")
    }
    for title in ["首页的列表改成按天分组", "夜里的构建又失败了", "整理发布清单"] {
      for line in still_after(t, fn() { still_pick(t, title) }) {
        out.push("「\{title}」 \{line}")
      }
      // (the cursor out of it again, long enough: as cold for the next as for the first)
      still_cold(t)
    }
    // (back where it was read up from: the way to the newest there as it is found)
    if t.query(Button, label=newest) is None {
      out.push("back: no way to the newest")
    }
    out
  })
}

///|
test "switch: 新建对话 and a chat back and forth: the bar, the page and the composer there at once, nothing flown across the window; a new chat's first words sent, its chat in its place" {
  still_each(fn(s) {
    let (t, _, _) = still_open(s)
    let out = []
    // (in one workspace the composer goes between the chat's foot and the new chat's page: #1259's, its own; the
    // rest there at once)
    let floats = ["chat-jump", "chat-ask", "chat-outline"]
    for line in still_after(t, fn() { still_new_chat(t) }, anims=floats) {
      out.push("新建对话: \{line}")
    }
    for line in still_after(t, fn() { still_pick(t, "首页的列表改成按天分组") }, anims=floats) {
      out.push("a chat: \{line}")
    }
    for line in still_after(t, fn() { still_new_chat(t) }, anims=floats) {
      out.push("新建对话 again: \{line}")
    }
    // (its first words sent: their chat comes in its place, as ever; how the composer goes with them is
    // newchat_send_wbtest's)
    t.tap_text("做任何事")
    t.type_text("看下进度")
    t.draw()
    tap_send(t)
    t.run_for(@sfbase.flight_desk_ms + new_leave_ms + @sfbase.sent_down_ms)
    if !(app.nav.top() is Chat(_)) {
      out.push("sent: not their chat")
    }
    out
  })
}

///|
test "switch: the sidebar's filter 全部 → 我参与的 → 全部: the lists slide along the track, none of them making its way down" {
  still_each(fn(s) {
    let (t, src, _) = still_open(s)
    let ws = @sfbase.workspace_in_view(src).0.unwrap()
    let out = []
    for f in ["mine", "all"] {
      for line in still_after(t, fn() { still_act(t, fn() { @sfpages.set_filter(src, ws, f) }) }) {
        // (the rail's place for the list in view, where the rail holds none of its own, comes and goes with it: the
        // press's own, sfdesk's rail_shown)
        if !line.contains("sfdesk/rail_node.mbt") {
          out.push("\{f}: \{line}")
        }
      }
    }
    out
  })
}

///|
/// The workspace switched to `ws` as its picker does.
fn still_workspace(t : @ui.Tester, src : Source, ws : String) -> Unit {
  still_act(t, fn() { @sfpages.switch_workspace(src, ws) })
}

///|
test "switch: another workspace (我参与的 to 全部), its list as kept shown at once and its answer, a chat come meanwhile, taken quietly: no slide, no way down, no row moving" {
  still_each(fn(s) {
    let (t, src, bump) = still_open(s)
    let ws1 = @sfbase.workspace_in_view(src).0.unwrap()
    still_act(t, fn() { @sfpages.set_filter(src, ws1, "mine") })
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    let out = []
    for line in still_after(t, fn() { still_workspace(t, src, "ws2") }) {
      out.push("ws2: \{line}")
    }
    // (a chat come to the first while the other is in view: back to it, what was kept of its list shown, then its
    // answer with that chat, taken at once)
    bump.set(1)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    for line in still_after(t, fn() { still_workspace(t, src, "ws1") }) {
      out.push("ws1: \{line}")
    }
    bump.set(2)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    for line in still_after(t, fn() { still_workspace(t, src, "ws2") }) {
      out.push("ws2 again: \{line}")
    }
    out
  })
}

///|
test "switch: 设置 and back to the chat, a chat come to the list meanwhile: its list as kept and its answer taken at once, the composer not flown" {
  still_each(fn(s) {
    let (t, src, bump) = still_open(s)
    let out = []
    for line in still_after(t, fn() { still_act(t, fn() { open_setting("connects") }) }) {
      out.push("设置: \{line}")
    }
    bump.set(1)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    for line in still_after(t, fn() { still_act(t, fn() { open_chat(still_chat("s-c1", "整理发布清单")) }) }) {
      out.push("back: \{line}")
    }
    ignore(src)
    out
  })
}

///|
test "switch: a chat come while the hand is on the sidebar, a chat picked there and the hand gone to it: the order held put in place quietly" {
  still_each(fn(s) {
    let (t, _, bump) = still_open(s)
    let out = []
    guard t.query(Link, label="首页的列表改成按天分组") is Some(row) else { return ["no row"] }
    let (x, y, w, h) = row.rect
    t.move_to(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    // (a chat come at the top while the hand is there: the core's change of the list, told as it comes)
    bump.set(1)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    still_pick(t, "首页的列表改成按天分组")
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    for line in still_after(t, fn() { t.move_to(s.w - 200.0, s.h / 2.0) }) {
      out.push("the hand gone: \{line}")
    }
    out
  })
}

///|
test "switch: a new chat left for another workspace, and for 设置 then a chat: the composer laid out where it is, flown from nothing" {
  still_each(fn(s) {
    let out = []
    let (t, src, _) = still_open(s)
    still_new_chat(t)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    // (on 大屏 the new chat's composer in its page's middle, far from a chat's foot: what would fly, were it flown)
    if s.name == "大屏" && !still_roomy(t, s.h) {
      out.push("the new chat's composer not in its page")
    }
    for line in still_after(t, fn() { still_workspace(t, src, "ws2") }) {
      out.push("new chat → ws2: \{line}")
    }
    for line in still_after(t, fn() { still_workspace(t, src, "ws1") }) {
      out.push("ws2 → ws1: \{line}")
    }
    let (t, _, _) = still_open(s)
    still_new_chat(t)
    t.run_for(still_late * 8.0 + @ui.move_most_ms)
    for line in still_after(t, fn() { still_act(t, fn() { open_setting("connects") }) }) {
      out.push("new chat → 设置: \{line}")
    }
    for line in still_after(t, fn() { still_act(t, fn() { open_chat(still_chat("s-c2", "首页的列表改成按天分组")) }) }) {
      out.push("设置 → a chat: \{line}")
    }
    out
  })
}

///|
/// Whether the composer stands in the page's middle (a new chat's, roomy), well over the window's foot.
fn still_roomy(t : @ui.Tester, h : Double) -> Bool {
  let (_, y, _, gh) = composer_glass(t) catch { _ => return false }
  y + gh < h - 200.0
}
