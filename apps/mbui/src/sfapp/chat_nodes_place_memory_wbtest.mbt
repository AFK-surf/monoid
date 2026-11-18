// Where a chat's page made as nodes (试用新对话页) is left, kept and told, and opened again: in a piece of a long
// message (a block a paragraph) after its first, again and again; back where the reader was after a go-to; from the
// core's `chat.place` alone (another run); under a bar of two rows; left as a fling still glides, and as the app goes
// behind; beside the board, closed and opened again.

///|
/// The long chat (chat_window_wbtest's) opened on screen `s` with its page's inside nodes, at rest, the calls the app
/// made kept in `calls`; the core saying where it was left (`at`: the message's seq, its top under the list's in pixels).
fn pm_open(
  l : LongChat,
  s : (String, Double, Double, Int),
  calls : Array[(String, Json)],
  at? : (Double, Double)? = None,
) -> @ui.Tester {
  let (_, w, h, platform) = s
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let base = long_source(l)
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = (base.topic_read)(name, params)
      guard name == "chat" && at is Some((seq, px)) && got.value is Some(Object(v)) else { return got }
      let out = v.copy()
      out["at"] = Json::number(seq)
      out["atOffset"] = Json::number(px)
      { ..got, value: Some(Json::object(out)) }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      (base.call)(name, params, done)
    },
  }
  open_chat(long_ref)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, begun=fn() {
    @sfbase.window_tall.val = h
  })
  long_run(t, l, long_opened_ms)
  t
}

///|
/// The first paragraph after a long message's first (第n条第i段：, i ≥ 2) drawn in the middle half of the window's
/// height `h`, of the messages `pieced`: its words and how far down they are drawn.
fn pm_piece_in_sight(t : @ui.Tester, pieced : Array[Int], h : Double) -> (String, Double)? {
  for n in pieced {
    for i in 2..<8 {
      let words = "第\{n}条第\{i}段："
      match t.rect_of(words) {
        Some((_, y, _, _)) if y > h * 0.25 && y < h * 0.7 => return Some((words, y))
        _ => ()
      }
    }
  }
  None
}

///|
/// Read up by the wheel (on 小屏 too: where it rests is what is looked at) till a paragraph after a long message's
/// first is in the middle of what shows (pm_piece_in_sight).
fn pm_read_up_to_piece(
  t : @ui.Tester,
  l : LongChat,
  s : (String, Double, Double, Int),
  pieced : Array[Int],
  first? : Double = -400.0,
) -> (String, Double) raise {
  let (name, w, h, _) = s
  t.move_to(w / 2.0, h / 2.0)
  t.wheel(w / 2.0, h / 2.0, first)
  long_run(t, l, long_rest_ms)
  for _ in 0..<40 {
    match pm_piece_in_sight(t, pieced, h) {
      Some(p) => return p
      None => ()
    }
    t.wheel(w / 2.0, h / 2.0, -90.0)
    long_run(t, l, long_rest_ms)
  }
  fail("\{name}: no paragraph after a long message's first read up to")
}

///|
test "a chat's page made as nodes left in a piece of a long message after its first opens there again, the same words as far down, left and opened five times over, on 小屏 and 大屏" {
  let pieced = [184, 188, 192, 196]
  for s in long_screens {
    let name = s.0
    let l = long_chat(pieced~)
    let calls = []
    let t = pm_open(l, s, calls)
    let (words, y) = pm_read_up_to_piece(t, l, s, pieced)
    for round in 1..=5 {
      place_left_and_opened(t, l)
      let now = t.rect_of(words).map(fn(r) { r.1 })
      assert_true(
        now is Some(ny) && (ny - y).abs() <= 1.0,
        msg="\{name}, opened again the \{round}th time: \{words} read at \{y}, now at \{Repr(now)}",
      )
    }
  }
}

///|
test "a chat's page made as nodes read up into a long message from its end, its pieces over what shows never measured, left: opened again at the same words as far down, on 小屏 and 大屏" {
  // (the long messages further up than one turn of the wheel shows: their first pieces over what shows not measured as
  // the reader comes to a later one)
  let pieced = [176, 178, 180]
  for s in long_screens {
    let name = s.0
    let l = long_chat(pieced~)
    let calls = []
    let t = pm_open(l, s, calls)
    let (words, y) = pm_read_up_to_piece(t, l, s, pieced, first=-1400.0)
    place_left_and_opened(t, l)
    let now = t.rect_of(words).map(fn(r) { r.1 })
    assert_true(now is Some(ny) && (ny - y).abs() <= 1.0, msg="\{name}: \{words} read at \{y}, now at \{Repr(now)}")
  }
}

///|
test "a chat's page made as nodes in a piece of a long message, a message further up gone to, then back where the reader was: the same words as far down, on 小屏 and 大屏" {
  let pieced = [176, 178, 180]
  for s in long_screens {
    let name = s.0
    let l = long_chat(pieced~)
    let calls = []
    let t = pm_open(l, s, calls)
    let (words, y) = pm_read_up_to_piece(t, l, s, pieced, first=-1400.0)
    @sfbase.go_to(long_ref, 153.0)
    @ui.came_from_outside()
    long_run(t, l, long_rest_ms)
    assert_true(t.rect_of(words) is None || t.rect_of("第153条：") is Some(_), msg="\{name}: not gone to 153")
    assert_true(@sfbase.go_back_to(long_ref), msg="\{name}: no place kept to go back to")
    @ui.came_from_outside()
    long_run(t, l, long_rest_ms)
    let now = t.rect_of(words).map(fn(r) { r.1 })
    assert_true(now is Some(ny) && (ny - y).abs() <= 1.0, msg="\{name}: \{words} read at \{y}, back at \{Repr(now)}")
  }
}

///|
test "a chat's page made as nodes left in a piece of a long message: another run, nothing kept but where the core was told it was left (chat.place), opens at the same words as far down, on 小屏 and 大屏" {
  let pieced = [184, 188, 192, 196]
  for s in long_screens {
    let name = s.0
    let l = long_chat(pieced~)
    let calls = []
    let t = pm_open(l, s, calls)
    let (words, y) = pm_read_up_to_piece(t, l, s, pieced)
    home()
    @ui.came_from_outside()
    long_run(t, l, long_opened_ms)
    guard calls.filter(fn(c) { c.0 == "chat.place" }).last() is Some((_, p)) &&
      @sfbase.field(Some(p), "offset") is Some(Number(px, ..)) else {
      fail("\{name}: where it was left not told")
    }
    let seq = @sfbase.number(Some(p), "seq")
    // (another run: what this one kept gone with it, the core saying where it was left)
    let l2 = long_chat(pieced~)
    let t2 = pm_open(l2, s, [], at=Some((seq, px)))
    let now = t2.rect_of(words).map(fn(r) { r.1 })
    assert_true(
      now is Some(ny) && (ny - y).abs() <= 1.0,
      msg="\{name}: \{words} read at \{y}, told at \{seq} \{px}px, opened at \{Repr(now)}",
    )
  }
}

///|
test "小屏, a chat's page made as nodes under a bar of two rows from the start (a title too long for one): left read up, opened again where it was, three times over, never further down by the bar's second row" {
  let tight_title = "极窄标题测试：当第 1 行连三个汉字加省略号都放不下时自动展开"
  let (t, _) = chat_bar_node_tester(tight_title, has_jobs=true, w=290.0, msg_count=14, at=14.0)
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: tight_title, station_name: "Willow" }
  t.run_for(@ui.move_most_ms)
  assert_true(bar_extra_target(r) > 30.0, msg="the bar not of two rows")
  t.move_to(145.0, 422.0)
  // (read up from where it opened: messages over it, those its made-up core's words are kept for)
  t.wheel(145.0, 422.0, -60.0)
  t.run_for(@ui.move_most_ms * 2.0)
  let seen : Array[(Int, Double)] = []
  for n in 1..=14 {
    match t.rect_of("第\{n}条：") {
      Some((_, y, _, _)) if y > 150.0 && y < 650.0 => seen.push((n, y))
      _ => ()
    }
  }
  assert_true(seen.length() > 0, msg="nothing read in the middle of the list")
  for round in 1..=3 {
    home()
    @ui.came_from_outside()
    t.run_for(@ui.move_most_ms * 2.0)
    open_chat(r)
    @ui.came_from_outside()
    t.run_for(@ui.move_most_ms * 2.0)
    let wrong = seen.filter(fn(p) { !(t.rect_of("第\{p.0}条：") is Some((_, y, _, _)) && (y - p.1).abs() <= 1.0) })
    assert_true(
      wrong.is_empty(),
      msg="opened again the \{round}th time: read at \{Repr(seen)}, now \{Repr(wrong.map(fn(p) { t.rect_of("第\{p.0}条：").map(fn(r) { r.1 }) }))}",
    )
  }
}

///|
/// The words of the long chat's messages drawn at moment's frame (their number's words) and how far down.
fn pm_drawn(t : @ui.Tester, l : LongChat, h : Double) -> Array[(Int, Double)] {
  let out = []
  for n in l.first.get()..=l.last.get() {
    match t.rect_of("第\{n}条：") {
      Some((_, y, _, _)) if y > 0.0 && y < h => out.push((n, y))
      _ => ()
    }
  }
  out
}

///|
/// A finger's stroke up the chat let go moving, 小屏's (a fling: the list glides on by itself after).
fn pm_fling(t : @ui.Tester, l : LongChat) -> Unit {
  t.hold_drag(195.0, 200.0, 195.0, 215.0, steps=1)
  long_answered(l)
  let mut y = 215.0
  while y < 640.0 {
    y += 40.0
    t.hold_move(195.0, y)
    long_answered(l)
  }
  t.release(195.0, y)
  long_answered(l)
}

///|
test "小屏, a chat's page made as nodes left as a fling still glides: opened again where it was as it was let go, not where the finger let it go" {
  let s = long_screens[0]
  let h = s.2
  let l = long_chat()
  let calls = []
  let t = pm_open(l, s, calls)
  pm_fling(t, l)
  // (a few frames of its glide: going on)
  long_frame(t, l)
  long_frame(t, l)
  let let_go = pm_drawn(t, l, h)
  long_frame(t, l)
  long_frame(t, l)
  let gliding = pm_drawn(t, l, h)
  assert_true(gliding.length() > 0 && let_go.length() > 0, msg="nothing drawn")
  assert_true(let_go != gliding, msg="not gliding: \{Repr(let_go)}")
  // left mid-glide: each frame of the page as it goes, where its messages are, to the last drawn
  home()
  @ui.came_from_outside()
  let mut last = gliding
  let mut was = gliding
  for _ in 0..<60 {
    long_frame(t, l)
    let now = pm_drawn(t, l, h)
    if now.is_empty() {
      break
    }
    was = last
    last = now
  }
  long_run(t, l, long_opened_ms)
  open_chat(long_ref)
  @ui.came_from_outside()
  long_run(t, l, long_opened_ms)
  // (where it was as it was let go: as its last frame drew it, give or take what the glide went in a frame then)
  let step = match (was.get(0), last.get(0)) {
    (Some(a), Some(b)) if a.0 == b.0 => (a.1 - b.1).abs()
    _ => 0.0
  }
  let off = last.filter(fn(p) {
    !(t.rect_of("第\{p.0}条：") is Some((_, y, _, _)) && (y - p.1).abs() <= @sf.dmax(2.0, step + 0.5))
  })
  assert_true(
    off.is_empty(),
    msg="left at \{Repr(last)} (a frame before \{Repr(was)}), opened at \{Repr(off.map(fn(p) { t.rect_of("第\{p.0}条：").map(fn(r) { r.1 }) }))}",
  )
}

///|
test "小屏, a chat's page made as nodes as the app goes behind while a fling glides: where it is that moment told the core at once (chat.place), a message then drawn" {
  let s = long_screens[0]
  let h = s.2
  let l = long_chat()
  let calls = []
  let t = pm_open(l, s, calls)
  pm_fling(t, l)
  long_frame(t, l)
  long_frame(t, l)
  let drawn = pm_drawn(t, l, h)
  let told = calls.filter(fn(c) { c.0 == "chat.place" }).length()
  t.app_state(false, false)
  let places = calls.filter(fn(c) { c.0 == "chat.place" })
  assert_true(places.length() > told, msg="where it is not told as the app went behind")
  guard places.last() is Some((_, p)) else { fail("no place") }
  let seq = @sfbase.number(Some(p), "seq").to_int()
  // (the message at its top then: drawn at that moment, at the list's top or under it)
  assert_true(
    seq >= drawn[0].0 - 1 && seq <= drawn[drawn.length() - 1].0,
    msg="told \{p.stringify()}, drawn then \{Repr(drawn)}",
  )
}

///|
/// The board's app (大屏 1440 × 900) with its chat 整理发布清单 forty messages long, each its own words
/// (第n条：), the page made as nodes.
fn pm_board_open() -> @ui.Tester {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let base = fixture("board")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = (base.topic_read)(name, params)
      guard name == "chat" && @sfbase.text(got.value, "title") == "整理发布清单" && got.value is Some(Object(chat)) else {
        return got
      }
      let msgs = items(got.value, "messages")
      guard msgs.last() is Some(Object(last)) else { return got }
      let base_seq = number(Some(Json::object(last)), "seq")
      let built : Array[Json] = []
      for i in 0..<40 {
        let m = last.copy()
        for k in ["attachments", "placed", "card", "options", "quotes", "said"] {
          m.remove(k)
        }
        let words = "第\{i + 1}条：这一条讲清单里的一项，写得长一些，占两三行，看板旁边读得到它。"
        m["seq"] = Json::number(base_seq - 40.0 + i.to_double() + 1.0)
        m["ts"] = Json::string("pm\{i + 1}")
        m["id"] = Json::string("pm-\{i + 1}")
        m["text"] = Json::string(words)
        m["words"] = Json::array([{ "text": Json::string(words) }])
        // (its tree as the core gives it, a line of words: nothing asked of the core's `markdown` for it)
        m["md"] = [["p", [[0, Json::number(words.length().to_double())]]]]
        built.push(Json::object(m))
      }
      let changed = chat.copy()
      changed["messages"] = Json::array(built)
      { ..got, value: Some(Json::object(changed)) }
    },
  }
  open_fixture_over("board", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "大屏, a chat beside the board made as nodes, read up: closed and opened again from its card, at the same messages as far down; opened over the whole page, those messages there" {
  let t = pm_board_open()
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms * 2.0)
  guard t.rect_of("第40条：") is Some((x, _, _, _)) else { fail("its last message not drawn beside the board") }
  t.move_to(x + 40.0, 450.0)
  t.wheel(x + 40.0, 450.0, -500.0)
  t.run_for(@ui.move_most_ms * 2.0)
  let seen : Array[(Int, Double)] = []
  for n in 1..=40 {
    match t.rect_of("第\{n}条：") {
      Some((_, y, _, _)) if y > 225.0 && y < 675.0 => seen.push((n, y))
      _ => ()
    }
  }
  assert_true(seen.length() > 0, msg="nothing read in the middle beside the board")
  t.click(Button, label="关闭")
  t.run_for(@ui.move_most_ms * 2.0)
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms * 2.0)
  let wrong = seen.filter(fn(p) { !(t.rect_of("第\{p.0}条：") is Some((_, y, _, _)) && (y - p.1).abs() <= 1.0) })
  assert_true(
    wrong.is_empty(),
    msg="read at \{Repr(seen)}, opened again \{Repr(wrong.map(fn(p) { t.rect_of("第\{p.0}条：").map(fn(r) { r.1 }) }))}",
  )
  // opened over the whole page from beside the board: what was read there
  t.click(Button, label="全屏打开")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(
    seen.iter().any(fn(p) { t.rect_of("第\{p.0}条：") is Some((_, y, _, _)) && y > 0.0 && y < 900.0 }),
    msg="opened over the whole page: none of \{Repr(seen)} drawn",
  )
}
