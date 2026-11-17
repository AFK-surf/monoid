// A chat's list made as nodes scrolled through a long history (chat_body_node's `reused`): the blocks of messages read
// before the chat showed them put by as they leave what shows and taken for the next of their make to come into it
// (chat_body_shape), each of the viewer's, a person's, still.fail's notices and an agent's (whole, and a long one's
// first piece, one after it and its last), drawn as a block made for that row draws it: what each row shows, set
// beside the same chat drawn whole in a window as tall as all of it (no row put by, each made for its own), at every
// rate of frames. What is picked in one taken for another row is held by chat_nodes_open_budget_wbtest.mbt (sfapp, chat_nodes_reused_picked).

///|
/// Message `i` of a long chat read before it showed (none `said`), its make by `i`: the viewer's, a person's, still.fail's
/// notice, an agent's of one paragraph, an agent's of three (a long one: a piece a paragraph); its words its own.
fn reuse_message(i : Int) -> Json {
  let words = "第 \{i} 条：列表的块收起来留着，下一条同样的拿去用"
  let base : Map[String, Json] = {
    "seq": Json::number(i.to_double()),
    "thread": Json::number(7.0),
    "ts": Json::string("tr" + i.to_string()),
    "createdAt": Json::number(1.7e12 + i.to_double() * 60000.0),
  }
  match i % 5 {
    0 => {
      base["authorKind"] = Json::string("person")
      base["author"] = Json::string("me@x.com")
      base["mine"] = Json::boolean(true)
      base["text"] = Json::string(words)
      base["md"] = body_md(words)
      base["by"] = Json::object({ "name": Json::string("我") })
    }
    1 => {
      base["authorKind"] = Json::string("person")
      base["author"] = Json::string("li@x.com")
      base["text"] = Json::string(words)
      base["md"] = body_md(words)
      base["by"] = Json::object({ "name": Json::string("李雷") })
    }
    2 => {
      base["authorKind"] = Json::string("system")
      base["system"] = Json::boolean(true)
      base["text"] = Json::string(words)
      base["md"] = body_md(words)
      base["by"] = Json::object({ "name": Json::string("still.fail") })
    }
    3 => {
      base["authorKind"] = Json::string("agent")
      base["author"] = Json::string("Claude")
      base["text"] = Json::string(words)
      base["md"] = body_md(words)
      base["by"] = Json::object({ "name": Json::string("Claude"), "agent": Json::string("s-c1") })
    }
    _ => {
      let a = words + "，第一段"
      let b = "第 \{i} 条的第二段：放回去的块不让出节点"
      let c = "第 \{i} 条的第三段：换了键重读它自己的那一行"
      base["authorKind"] = Json::string("agent")
      base["author"] = Json::string("Claude")
      base["text"] = Json::string(a + "\n\n" + b + "\n\n" + c)
      base["md"] = Json::array([body_para(a), body_para(b), body_para(c)])
      base["by"] = Json::object({ "name": Json::string("Claude"), "agent": Json::string("s-c1") })
    }
  }
  Json::object(base)
}

///|
/// A chat of `n` such messages, in its thread.
fn reuse_view(n : Int) -> ChatView {
  let v = @sfbase.chat_view_made({ "title": "很长的历史", "messages": [], "thread": { "id": 7 } })
  { ..v, messages: Array::makei(n, fn(i) { @sfbase.message_of(reuse_message(i)) }) }
}

///|
/// What a row shows, in its own terms: each piece of words and each rectangle drawn within its block (`at`, where it
/// is in the window: x, y, w, h), where it is from the block's top left, at a hundredth.
fn reuse_shows(t : @ui.Tester, at : (Double, Double, Double, Double)) -> Array[String] {
  let (x0, y0, w, h) = at
  let r = fn(d : Double) { (d * 100.0).round() / 100.0 }
  let within = fn(x : Double, y : Double) { x >= x0 - 0.01 && x < x0 + w + 0.01 && y >= y0 - 0.01 && y < y0 + h + 0.01 }
  let out : Array[String] = []
  for s in t.words_said() {
    if within(s.1, s.2) {
      out.push("words \{s.0} \{r(s.1 - x0)} \{r(s.2 - y0)} \{r(s.3)} \{r(s.4)}")
    }
  }
  for d in t.drawn_rects() {
    // (the list's bar at the window's edge over it is the list's, not the row's)
    if within(d.0, d.1) && d.0 + d.2 < x0 + w - 8.0 {
      out.push("rect \{r(d.0 - x0)} \{r(d.1 - y0)} \{r(d.2)} \{r(d.3)} \{d.4}")
    }
  }
  out.sort()
  out
}

///|
/// The chat (`n` messages) in a window `w` by `h` on `platform`, each row's key told to the block holding it as it is
/// made or taken for it: the Tester and the blocks by what they hold now and how many rows each came to hold.
fn reuse_open(n : Int, w : Double, h : Double, platform : Int) -> (@ui.Tester, Array[(@view.View, String, Int)]) {
  @sfbase.reset()
  reset()
  let v = reuse_view(n)
  let view = @signals.signal(v)
  let entries = @signals.signal(@sfbase.entries_of(v))
  let holds : Array[(@view.View, String, Int)] = []
  let t = body_new(src_of_reuse(), w, h, platform, view, entries, made=fn(k, p) {
    match holds.search_by(fn(e) { e.0.id() == p.id() }) {
      Some(i) => holds[i] = (p, k, holds[i].2 + 1)
      None => holds.push((p, k, 1))
    }
  })
  t.run_for(@ui.move_most_ms)
  (t, holds)
}

///|
/// Which message of reuse_view's row key `k` is of (its pieces' too); -1 none.
fn reuse_index(k : String) -> Int {
  guard k.strip_prefix("m:tr") is Some(rest) else { return -1 }
  let mut n = 0
  for c in rest {
    if c >= '0' && c <= '9' {
      n = n * 10 + (c.to_int() - '0'.to_int())
    } else {
      break
    }
  }
  n
}

///|
/// The fixture's source the list reads its pictures and what it asks of (body_new's).
fn src_of_reuse() -> Source {
  @sffixture.fixture("chat")
}

///|
/// What each block wholly within `t`'s window, clear of `top` and of the room `foot` under it, shows (reuse_shows), by
/// the key it holds; a long message's pieces by their own keys.
fn reuse_rows_shown(
  t : @ui.Tester,
  holds : Array[(@view.View, String, Int)],
  h : Double,
  top : Double,
  foot : Double,
) -> Map[String, Array[String]] {
  let out : Map[String, Array[String]] = Map([])
  for e in holds {
    guard e.0.alive() && !e.0.shown_nowhere() && e.1 != "top" else { continue }
    let at = e.0.placed_window_now()
    if at.3 > 0.0 && at.1 >= top && at.1 + at.3 <= h - foot {
      out[e.1] = reuse_shows(t, at)
    }
  }
  out
}

///|
/// How long after one notch of the wheel the next comes (reuse_open's list scrolled through): a hand turning it.
let reuse_notch_ms : Double = 100.0

///|
test "a chat's history scrolled through: the blocks of the messages read before put by and taken for the next of their make, each row drawn as a block made for it draws it" {
  let n = 60
  let (w, h, platform) = (900.0, 760.0, 0)
  let (t, holds) = reuse_open(n, w, h, platform)
  // up through it a notch at a time, then back down part of the way: blocks put by at either end and taken again
  for _ in 0..<16 {
    t.wheel(w / 2.0, h / 2.0, -300.0)
    t.run_for(reuse_notch_ms)
  }
  for _ in 0..<5 {
    t.wheel(w / 2.0, h / 2.0, 300.0)
    t.run_for(reuse_notch_ms)
  }
  t.run_for(@ui.move_most_ms)
  // (blocks taken for another row: of each make, by the keys the blocks that show hold now)
  let again = holds.filter(fn(e) { e.0.alive() && e.2 > 1 })
  let makes : Map[Int, Bool] = Map([])
  for e in again {
    let i = reuse_index(e.1)
    if i >= 0 {
      // (a long message's: its first piece, one after it, its last)
      let piece = match e.1.rev_find("#") {
        Some(_) => if e.1.has_suffix("#2") { 2 } else { 1 }
        None => 0
      }
      makes[(i % 5) * 3 + piece] = true
    }
  }
  let said = makes.keys().collect()
  said.sort()
  assert_eq(said, [0, 3, 6, 9, 12, 13, 14], msg="the makes of message whose blocks were taken for another row")
  let foot = body_foot(reuse_view(n))
  let shown = reuse_rows_shown(t, holds, h, bar_foot + list_room, foot)
  assert_true(shown.length() >= 6, msg="rows wholly in sight: \{shown.length()}")
  // the same chat drawn whole, every row made for its own: each row in sight above shows the same
  let (whole, whole_holds) = reuse_open(n, w, 9000.0, platform)
  let fresh = reuse_rows_shown(whole, whole_holds, 9000.0, 0.0, 0.0)
  let apart : Array[String] = []
  for k, rows in shown {
    match fresh.get(k) {
      Some(f) if f == rows => ()
      Some(f) => apart.push("\{k}: \{rows.join(" | ")}\n  made for it: \{f.join(" | ")}")
      None => apart.push("\{k}: not drawn whole")
    }
  }
  assert_eq(apart, [], msg=apart.join("\n"))
}
