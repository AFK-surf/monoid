// The chat's page made as nodes on 大屏 (1280×800) and 小屏 (390×844), every frame a host draws round each cause:
// a card taken off the composer by its ✕ till none is left, the side panel opened and closed beside the chat (by its
// switch, as a press asks it: sfdesk's side_toggle), words sent beside it, and the bell to what waits to be decided.
// Each held to what its cause makes of it frame by frame: what the composer's ground does the list's room under the
// last row does with it, one way (sfbase's composer_set_out, foot_resizes); the chat's column slides across with the
// page as the panel takes its room, what is in its foot with it, never standing still to step to its place at the end
// (sfbase's chat_page_made: its column's one offset, its way across and its way aside together).

///|
/// The screens: name, width, height, platform.
let dk_screens : Array[(String, Double, Double, Int)] = [("大屏", 1280.0, 800.0, 0), ("小屏", 390.0, 844.0, 2)]

///|
let dk_chat : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// The last agent's words in the fixture's chat: the list's last row, over the composer.
let dk_last : String = "做完了：列表、跳到最新的按钮"

///|
/// How far into the side panel's slide words are sent beside it.
let dk_into_slide_ms : Double = 100.0

///|
/// How far apart the frames looked at are (a display's at 60 a second).
let dk_frame_ms : Double = 1000.0 / 60.0

///|
/// The fixture's chat on `screen` (`h` high, else the screen's), made as nodes (its composer too where `composer_nodes`
/// says), its rows on the host's pixels, at rest at its end.
fn dk_open(
  screen : (String, Double, Double, Int),
  h? : Double,
  composer_nodes? : Bool = false,
) -> (@ui.Tester, Source) {
  let (_, w, sh, platform) = screen
  let h = h.unwrap_or(sh)
  new_run()
  @sfbase.chat_page_nodes.set(true)
  @sfbase.composer_nodes.set(composer_nodes)
  fix_pace.val = (fix_deliver_ms, fix_answer_ms, 1.0e7)
  let src = fixture("chat")
  open_chat(dk_chat)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.set_rows_on_pixels(true)
  t.set_frame_period(dk_frame_ms)
  nav_rested(t)
  files_page_over(t, w, h)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// Where words containing `part` are drawn now, the lowest of them (x, y, w).
fn dk_at(t : @ui.Tester, part : String) -> (Double, Double, Double)? {
  let mut at : (Double, Double, Double)? = None
  for w in t.words() {
    let (txt, x, y, ww, _, a) = w
    if a > 0.05 && txt.contains(part) {
      match at {
        Some((_, ay, _)) if ay >= y => ()
        _ => at = Some((x, y, ww))
      }
    }
  }
  at
}

///|
/// Each frame a host draws over `ms` after a cause: where `part`'s words and the composer's ground are, a frame each.
fn dk_frames(
  t : @ui.Tester,
  part : String,
  ms : Double,
) -> Array[((Double, Double, Double)?, (Double, Double, Double, Double)?)] {
  let out = []
  let start = t.time()
  let look = fn() {
    let g = back_round_ground(t).map(fn(g) { (g.0, g.1, g.2, g.3) })
    out.push((dk_at(t, part), g))
  }
  look()
  while t.time() - start < ms {
    t.run_for(dk_frame_ms)
    look()
  }
  out
}

///|
test "a card taken off by its ✕ till none is left, nothing typed: the list's last row goes down with the composer's ground, never in one frame" {
  for screen in dk_screens {
    let name = screen.0
    let (t, src) = dk_open(screen)
    guard composer_field(t) is Some((x, y, w, h)) else { fail("\{name}: no composer's field") }
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    let draft = @sfbase.writing(src, sent_nodes_draft)
    @sfbase.writing_add(src, draft, "ws1/st1", "夜构建日志.log", @utf8.encode("夜里的构建日志"))
    t.run_for(@ui.move_most_ms * 2.0)
    guard dk_at(t, dk_last) is Some((_, y0, _)) else { fail("\{name}: 「\{dk_last}」 not drawn") }
    guard back_round_ground(t) is Some((_, g0, _, _, _, _)) else { fail("\{name}: no composer's ground") }
    tap_said(t, "移除 夜构建日志.log")
    let seen = dk_frames(t, dk_last, @ui.move_most_ms * 2.0)
    let mut was = (y0, g0)
    for i, s in seen {
      guard s is (Some((_, y, _)), Some((_, g, _, _))) else { fail("\{name}, frame \{i}: not drawn") }
      // (as far down as the ground came down that frame, a pixel either way: never the whole of it at once)
      assert_true(
        (y - was.0 - (g - was.1)).abs() <= 1.5,
        msg="\{name}, frame \{i}: the last row down \{y - was.0} as the ground came down \{g - was.1}",
      )
      was = (y, g)
    }
    assert_true(was.0 - y0 > 30.0, msg="\{name}: the last row did not come down (\{y0} to \{was.0})")
  }
}

///|
/// What a frame draws of the chat beside the side panel: the composer's ground (x, w), one's own words sent `mine`
/// in their bubble (x, y, w), the agent's last words (x, y).
fn dk_beside(t : @ui.Tester, mine : String) -> ((Double, Double)?, (Double, Double, Double)?, (Double, Double)?) {
  let ground = back_round_ground(t).map(fn(g) { (g.0, g.2) })
  let bubble = mf_drawn_part_box(t, mine, whole=true).map(fn(b) { (b.0, b.1, b.2) })
  let last = dk_at(t, dk_last).map(fn(l) { (l.0, l.1) })
  (ground, bubble, last)
}

///|
test "大屏: the side panel opened and closed by its switch pressed, one's own words sent: the composer, one's bubble and the agent's words go one way every frame, from the first frame to the last, never a step" {
  let (t, _) = dk_open(dk_screens[0])
  let mine = "先在右边发一句"
  guard composer_field(t) is Some((x, y, w, h)) else { fail("no composer's field") }
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t.type_text(mine)
  t.run_for(@ui.move_most_ms)
  tap_send(t)
  t.run_for(fix_deliver_ms + fix_answer_ms + fix_turn_end_ms + @ui.move_most_ms * 3.0)
  for open in [true, false] {
    let at = if open { "opening" } else { "closing" }
    let seen = [dk_beside(t, mine)]
    let script = if open { "tap icon:panel-open\nwait 1200\nexit\n" } else { "tap icon:panel-close\nwait 1200\nexit\n" }
    let logs = t.drive(script, each=fn(t) { seen.push(dk_beside(t, mine)) })
    guard !logs.iter().any(fn(l) { l.has_prefix("DRIVE") && l.contains("FAIL") }) else {
      fail("\{at}: the switch not pressed: \{logs.filter(fn(l) { l.has_prefix("DRIVE") }).join(" | ")}")
    }
    // (each of what is measured: a frame's step no more than a way's, 15; one way only, never back by more than a
    // hair; and going somewhere at all)
    let steps : Array[(String, Array[Double])] = [
      ("the composer's x", []),
      ("the composer's width", []),
      ("one's bubble's x", []),
      ("one's bubble's y", []),
      ("one's bubble's width", []),
      ("the agent's words' x", []),
      ("the agent's words' y", []),
    ]
    for i, s in seen {
      guard s is (Some((cx, cw)), Some((bx, by, bw)), Some((lx, ly))) else {
        fail("\{at}, frame \{i}: not all drawn: \{Repr(s)}")
      }
      for k, v in [cx, cw, bx, by, bw, lx, ly] {
        steps[k].1.push(v)
      }
    }
    // (the first frame it moves in and the last: no more than 15, a way setting off from still and coming to rest, never
    // a step of what it is laid out at; between, as fast as the page's way goes, one way)
    let report = seen.mapi(fn(i, s) { "\{i}: \{Repr(s)}" }).join("\n")
    for e in steps {
      let (what, vs) = e
      let mut dir = 0.0
      let moving = []
      for i in 1..<vs.length() {
        let d = vs[i] - vs[i - 1]
        if d.abs() > 0.5 {
          moving.push(i)
          assert_true(
            dir == 0.0 || d * dir > 0.0,
            msg="\{at}, frame \{i}: \{what} turned back (\{d}) on its way\n\{report}",
          )
          dir = d
        }
      }
      // (the composer goes with the page's own way, the panel's Move, whose first and last frames are its own; what is
      // laid out in the list is held to them)
      let ends = if what.has_prefix("the composer") { [] } else { [moving.get(0), moving.last()] }
      for i in ends {
        guard i is Some(i) else { continue }
        let d = vs[i] - vs[i - 1]
        assert_true(
          d.abs() <= 15.0,
          msg="\{at}, frame \{i} of \{vs.length() - 1}: \{what} stepped \{d} (\{vs[i - 1]} to \{vs[i]}) as it set off or came to rest\n\{report}",
        )
      }
    }
    assert_true(
      (steps[1].1[steps[1].1.length() - 1] - steps[1].1[0]).abs() > 30.0,
      msg="\{at}: the composer kept its width (\{steps[1].1[0]})",
    )
  }
}

///|
test "大屏, either composer: one's own words broken anew as the side panel opens and closes are drawn at their size every frame, never squeezed and sprung back; the rows and the composer's room under it go the page's one way, never a step nor a way of their own after" {
  for nodes in [true, false] {
  let (t, _) = dk_open(dk_screens[0], composer_nodes=nodes)
  let which = if nodes { "composer made as nodes" } else { "old composer" }
  // (lines enough that its bubble is as wide as one may be, at either width: wider where the panel is gone than the
  // column is drawn as it sets off closing, and fewer lines there than beside the panel)
  let mine = "侧栏打开的时候这一段会在气泡里多折几行，收起的时候又少几行，字的大小每一帧都不变才对；这段话故意写得很长，让气泡在窄栏和宽栏里都撑到最宽，收起侧栏的那一刻它按宽栏排好、比当时画出来的栏还宽，开头的字也不能被栏的左边裁掉。"
  guard composer_field(t) is Some((x, y, w, h)) else { fail("no composer's field") }
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t.type_text(mine)
  t.run_for(@ui.move_most_ms)
  tap_send(t)
  t.run_for(fix_deliver_ms + fix_answer_ms + fix_turn_end_ms + @ui.move_most_ms * 3.0)
  // (how tall its words are drawn, and how wide)
  let size = fn(t : @ui.Tester) -> (Double, Double)? {
    for wd in t.words() {
      let (txt, _, _, ww, wh, a) = wd
      if a > 0.05 && txt == mine {
        return Some((ww, wh))
      }
    }
    None
  }
  // (where its words start across, as the page goes: and where the composer's field stands)
  let left = fn(t : @ui.Tester) -> Double {
    let mut at = @double.infinity
    for wd in t.words() {
      let (txt, wx, _, _, _, a) = wd
      if a > 0.05 && txt == mine && wx < at {
        at = wx
      }
    }
    at
  }
  let field_y = fn(t : @ui.Tester) -> Double {
    match composer_field(t) {
      Some((_, y, _, _)) => y
      None => 0.0
    }
  }
  for open in [true, false] {
    let at = if open { "opening" } else { "closing" }
    guard size(t) is Some(from) else { fail("\{at}: 「\{mine}」 not drawn") }
    let seen = []
    let lefts = []
    let fields = []
    let script = if open { "tap icon:panel-open\nwait 1200\nexit\n" } else { "tap icon:panel-close\nwait 1200\nexit\n" }
    // (from the frame before the press, at rest: where its words start at that end is where they start before it)
    seen.push(size(t))
    lefts.push(left(t))
    fields.push(field_y(t))
    t.drive(script, each=fn(t) {
      seen.push(size(t))
      lefts.push(left(t))
      fields.push(field_y(t))
    })
    |> ignore
    // (the composer's field goes with the rows on the page's one way: no step in a frame, and at rest by the frame the
    // page is, never going on by itself after)
    let last_moved = fn(xs : Array[Double]) -> Int {
      let mut k = 0
      for i in 1..<xs.length() {
        if (xs[i] - xs[i - 1]).abs() > 0.05 {
          k = i
        }
      }
      k
    }
    for i in 1..<fields.length() {
      assert_true(
        (fields[i] - fields[i - 1]).abs() < 4.0,
        msg="\{which}, \{at}, frame \{i}: its field stepped \{fields[i - 1]} to \{fields[i]}\n\{Repr(fields)}",
      )
    }
    assert_true(
      last_moved(fields) <= last_moved(lefts) + 1,
      msg="\{which}, \{at}: its field still going at frame \{last_moved(fields)}, the page at rest at \{last_moved(lefts)}\n\{Repr(fields)}",
    )
    // (its words' start never past where it starts at either end, the chat's column standing still at its left: a
    // bubble laid out wider than the column is drawn at cut at its right as the panel's edge goes, never at its start)
    let n = lefts.length()
    if n > 1 {
      let least = @cmp.minimum(lefts[0], lefts[n - 1])
      for i in 0..<n {
        assert_true(
          lefts[i] >= least - 4.0,
          msg="\{which}, \{at}, frame \{i}: its words start at \{lefts[i]}, at either end \{least}\n\{Repr(lefts)}",
        )
      }
    }
    guard size(t) is Some(to) else { fail("\{at}: 「\{mine}」 not drawn at rest") }
    assert_true(
      (to.0 - from.0).abs() > 10.0 || (to.1 - from.1).abs() > 10.0,
      msg="\{at}: its words not broken anew (\{Repr(from)} to \{Repr(to)}): the panel took too little of the chat",
    )
    // (laid out anew at once as the page sets off, as the window made another size has it: drawn at where it was or
    // where it goes, whole, never between, as words grown from their top are)
    for i, s in seen {
      guard s is Some(s) else { fail("\{at}, frame \{i}: 「\{mine}」 not drawn") }
      let whole = fn(e : (Double, Double)) { (s.0 - e.0).abs() < 0.5 && (s.1 - e.1).abs() < 0.5 }
      assert_true(
        whole(from) || whole(to),
        msg="\{at}, frame \{i}: its words drawn \{Repr(s)}, at rest \{Repr(from)} and \{Repr(to)}\n\{Repr(seen)}",
      )
    }
  }
  }
}

///|
test "大屏: words sent as the side panel slides in set out from the field as words sent at rest do, and fly on with no step" {
  let (t, src) = dk_open(dk_screens[0])
  // (where words sent set out against the composer's field: at rest, then as the side panel slides in)
  let sent = fn(words : String) -> (Double, Double) raise {
    guard composer_field(t) is Some((x, y, w, h)) else { fail("no composer's field") }
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    t.type_text(words)
    t.run_for(@ui.move_most_ms)
    guard composer_field(t) is Some((fx, fy, _, _)) else { fail("no composer's field") }
    tap_send(t)
    guard dk_at(t, words) is Some((sx, sy, _)) else { fail("「\{words}」 not drawn as they are sent") }
    (sx - fx, sy - fy)
  }
  let at_rest = sent("先发一句")
  t.run_for(fix_deliver_ms + fix_answer_ms + @ui.move_most_ms * 2.0)
  guard composer_field(t) is Some((x, y, w, h)) else { fail("no composer's field") }
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  @sfdesk.side_toggle(src, dk_chat, "s-c1")
  t.run_for(dk_into_slide_ms)
  let sliding = sent("看一下列表")
  assert_true(
    // (within what the composer goes on its own way in a frame as the page slides: 2)
    (sliding.0 - at_rest.0).abs() <= 2.0 && (sliding.1 - at_rest.1).abs() <= 2.0,
    msg="as the panel slides the words set out \{Repr(sliding)} off the field, at rest \{Repr(at_rest)}",
  )
  // (every frame after: on their way, never a step)
  let seen = dk_frames(t, "看一下列表", fix_deliver_ms + @ui.move_most_ms)
  let mut was : (Double, Double)? = None
  for i, s in seen {
    match (s.0, was) {
      (Some((sx, sy, _)), Some((px, py))) => {
        assert_true(
          (sx - px).abs() <= 120.0 && (sy - py).abs() <= 60.0,
          msg="frame \{i}: the words stepped from \{px},\{py} to \{sx},\{sy}",
        )
        was = Some((sx, sy))
      }
      (Some((sx, sy, _)), None) => was = Some((sx, sy))
      _ => ()
    }
  }
}

///|
test "the bell to what waits to be decided shows while any of it is out of sight: the second card in sight, the first above it" {
  // (a window short enough that the first card (post 8) is over what shows at the chat's end, the second (post 10) in it)
  let h = 440.0
  let (t, _) = dk_open(dk_screens[1], h~)
  let in_sight = fn(part : String) {
    match dk_at(t, part) {
      Some((_, y, _)) => y > 0.0 && y < h
      None => false
    }
  }
  // (the first card's question and its choices over what shows, the second's in it)
  for part in ["要不要把旧的截图也一起换掉？", "把首页和聊天页的截图都更新"] {
    assert_false(in_sight(part), msg="「\{part}」 in sight: the window is not short enough")
  }
  assert_true(in_sight("在 Willow 上登录 gh"), msg="the second card not in sight")
  assert_true(
    t.semantics().iter().any(fn(s) { s.label == @sf.t("web-main.chat.asks.go") && !s.hidden }),
    msg="no bell while the first card waiting is out of sight",
  )
}

///|
/// The pictures the tree draws now whose keys are not among `before`, at all opaque: each drawn (node, x, y).
fn dk_new_pictures(before : Array[String]) -> Array[(@view.NodeId, Double, Double)] {
  let out = []
  for d in @ui.view_tree().unwrap().drawn() {
    match d.image {
      Some((k, _, _)) if !before.contains(k) && d.alpha > 0.0 && d.bones == 0L => out.push((d.id, d.x, d.y))
      _ => ()
    }
  }
  out
}

///|
test "大屏: a picture sent with a file and words, past the station delivering it with its size: the same picture's node every frame, on its way with no step" {
  let (t, src) = dk_open(dk_screens[0])
  let draft = @sfbase.writing(src, sent_nodes_draft)
  // (a photo the host holds, handed over by its picture alone, not read here (a phone's picker's: writing_add_held): its
  // row sent from here drawn in the box of a picture whose size nobody said yet, the core's that takes it over in its
  // own, as the station read it)
  t.add_image("pick://看图", 1500, 1000)
  @sfbase.writing_add_held(src, draft, "ws1/st1", { name: "看图.png", bytes: Bytes::make(0, b'\x00'), held: 1, size: 4000.0, src: "pick://看图" })
  @sfbase.writing_add(src, draft, "ws1/st1", "构建日志.log", @utf8.encode("夜里的构建日志"))
  t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
  guard composer_field(t) is Some((x, y, w, h)) else { fail("no composer's field") }
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t.type_text("截图和日志都在这里")
  t.run_for(@ui.move_most_ms)
  let before = []
  for d in @ui.view_tree().unwrap().drawn() {
    match d.image {
      Some((k, _, _)) => before.push(k)
      None => ()
    }
  }
  tap_send(t)
  // (the station reads its size as it takes it: the core's row that takes over from the one sent from here says it,
  // the one sent from here never did)
  let mut told = false
  for o in @sffixture.fix_chat("s-c1").outbox {
    guard o is Object(om) && om.get("attachments") is Some(Array(files)) else { continue }
    for a in files {
      if a is Object(m) && m.get("name") == Some(Json::string("看图.png")) {
        m["width"] = Json::number(1500.0)
        m["height"] = Json::number(1000.0)
        told = true
      }
    }
  }
  assert_true(told, msg="the picture not on its way")
  t.run_for(dk_frame_ms)
  let press = t.time()
  // (its row given way to the core's as the station delivers it (fix_deliver_ms), the picture's size said then: the
  // node it flies in is the one drawn from the press to its rest, never made again under it, so its flight goes on and
  // it is never drawn waiting again)
  let mut was : (@view.NodeId, Double, Double)? = None
  while t.time() - press <= fix_deliver_ms + @ui.move_most_ms * 2.0 {
    let at = "\{t.time() - press} ms after the press"
    guard dk_new_pictures(before) is [now] else { fail("\{at}: \{Repr(dk_new_pictures(before))} pictures sent drawn") }
    match was {
      Some(p) => {
        assert_true(now.0 == p.0, msg="\{at}: the picture drawn by another node, made again under it")
        assert_true(
          (now.1 - p.1).abs() <= 120.0 && (now.2 - p.2).abs() <= 60.0,
          msg="\{at}: the picture stepped from \{p.1},\{p.2} to \{now.1},\{now.2}",
        )
      }
      None => ()
    }
    was = Some(now)
    t.run_for(dk_frame_ms)
  }
}

///|
/// Each frame of `script` driven over fixture mode `mode` as nodes, `w` × `h` playing `platform`, as a host draws it
/// (check_looks off: an old view in the window's tree built only as it is asked, its rows on the device's pixels, 60 a
/// second): the words each draws once where they show (text and how far down), and those it draws more than once.
fn dk_host_words(
  mode : String,
  w : Double,
  h : Double,
  platform : Int,
  script : String,
) -> Array[(Double, Map[String, Double], Array[String])] {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture_app(mode, chat_nodes=true)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=false)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  let start = t.time()
  let frames = []
  let _ = t.drive(script, each=fn(t) {
    let m : Map[String, Double] = Map([])
    let twice : Array[String] = []
    for wd in t.words() {
      let (txt, _, y, _, _, a) = wd
      if a > 0.05 && txt != "" && y > 0.0 && y < h {
        if m.contains(txt) {
          twice.push(txt)
        } else {
          m[txt] = y
        }
      }
    }
    for k in twice {
      m.remove(k)
    }
    frames.push((t.time() - start, m, twice))
  })
  frames
}

///|
test "a picture sent with a file, as a host draws it: no row over what comes is let go for the frame the words are sent in and drawn again the next" {
  let drives = [
    (
      "chat",
      1280.0,
      800.0,
      0,
      (
        #|timeout 20000
        #|until 发消息
        #|wait 600
        #|tap 发消息
        #|wait 500
        #|picks 截图.png:160x120
        #|key cmd+u
        #|wait 900
        #|picks 构建日志.log:2000
        #|key cmd+u
        #|wait 900
        #|type 截图和日志都在这里
        #|wait 600
        #|tap icon:arrow-up
        #|wait 1200
        #|exit
      ),
    ),
    (
      "chat-attach-pic",
      390.0,
      844.0,
      2,
      (
        #|timeout 20000
        #|wait 1500
        #|tap icon:arrow-up
        #|wait 1200
        #|exit
      ),
    ),
  ]
  let gone = []
  for d in drives {
    let (mode, w, h, platform, script) = d
    let frames = dk_host_words(mode, w, h, platform, script)
    for i in 1..<(frames.length() - 1) {
      let (_, a, _) = frames[i - 1]
      let (at, b, b_twice) = frames[i]
      let (_, c, _) = frames[i + 1]
      for k, y in a {
        if !b.contains(k) && !b_twice.contains(k) && c.get(k) is Some(y2) && (y2 - y).abs() < 40.0 {
          gone.push("\{mode}: 「\{k}」 at \{y} gone @\{at.round()}ms, at \{y2} again the next")
        }
      }
    }
  }
  if !gone.is_empty() {
    fail("rows let go for a frame: \{gone.length()}, first \{gone[:@cmp.minimum(5, gone.length())].join("; ")}")
  }
}

///|
test "words sent the station takes before they have been on their way a while: 正在发送 never seen under them, not as their flight lands while it leaves" {
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 600
    #|tap 发消息
    #|wait 500
    #|type 发布前再看一眼签名
    #|wait 700
    #|tap icon:arrow-up
    #|wait 2500
    #|exit
  for screen in dk_screens {
    let (name, w, h, platform) = screen
    let frames = dk_host_words("chat", w, h, platform, script)
    // (read of the run just made)
    let sending = @sf.t("web-main.chat.sending")
    let seen = frames.filter(fn(f) { f.1.contains(sending) || f.2.contains(sending) })
    if !seen.is_empty() {
      fail("\{name}: \{sending} seen in \{seen.length()} frames, the first @\{seen[0].0.round()}ms")
    }
  }
}

///|
/// Each frame of `script` driven over fixture mode `mode` as nodes, `w` × `h` playing `platform`, as a host draws it
/// (dk_host_words'), handed to `each` with its moment since the drive began.
fn dk_host_each(
  mode : String,
  w : Double,
  h : Double,
  platform : Int,
  script : String,
  each : (@ui.Tester, Double) -> Unit,
  delivered_in? : Double,
) -> Unit {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture_app(mode, chat_nodes=true)
  // (the station taking what is sent this long after it is sent)
  match delivered_in {
    Some(ms) => {
      let (_, answer, end) = @sffixture.fix_pace.val
      @sffixture.fix_pace.val = (ms, answer, end)
    }
    None => ()
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=false)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  let start = t.time()
  let _ = t.drive(script, each=fn(t) { each(t, t.time() - start) })
}

///|
/// Each frame of words sent by `script` over the chat on `screen`, from the frame they are first seen to the drive's
/// end, as nodes: (its moment, where they are drawn, what `look` reads of that frame round them).
fn dk_sent_frames(
  screen : (String, Double, Double, Int),
  script : String,
  text : String,
  look : (@view.Tree, @ui.Tester, (Double, Double, Double, Double)) -> Double,
  delivered_in? : Double,
) -> Array[(Double, Double, Double, Double)] {
  let (_, w, h, platform) = screen
  let frames = []
  dk_host_each(
    "chat",
    w,
    h,
    platform,
    script,
    fn(t, at) {
      guard @ui.view_tree() is Some(tr) else { return }
      let drawn = tr.drawn()
      guard drawn.search_by(fn(d) { d.words == text && d.alpha > 0.05 }) is Some(i) else { return }
      let wd = drawn[i]
      frames.push((at, wd.x, wd.y, look(tr, t, (wd.x, wd.y, wd.w, wd.h))))
    },
    delivered_in?,
  )
  frames
}

///|
/// Of `frames` (dk_sent_frames'), the first index from which their words are where they rest (the last frame's place).
fn dk_landed_at(frames : Array[(Double, Double, Double, Double)]) -> Int {
  guard frames.last() is Some((_, lx, ly, _)) else { return 0 }
  let mut i = frames.length() - 1
  while i > 0 && (frames[i - 1].1 - lx).abs() < 0.5 && (frames[i - 1].2 - ly).abs() < 0.5 {
    i -= 1
  }
  i
}

///|
/// What of `frames` (dk_sent_frames') from their first to where they land (`landed`) breaks one way in with their
/// flight: what `look` read falling on the way, unseen a quarter of the way in, or not whole as they land.
fn dk_one_way_in(name : String, what : String, frames : Array[(Double, Double, Double, Double)], landed : Int) -> Array[String] {
  let bad = []
  guard landed > 0 else { return ["\{name}: words sent never seen on their way"] }
  let (set_out, _, _, _) = frames[0]
  let (land, _, _, _) = frames[landed]
  for i in 1..=landed {
    if frames[i].3 < frames[i - 1].3 - 0.02 {
      bad.push("\{name} @\{frames[i].0.round()}ms: \{what} fell \{frames[i - 1].3} → \{frames[i].3} on their way")
    }
  }
  let quarter = frames.search_by(fn(f) { f.0 >= set_out + 0.25 * (land - set_out) }).unwrap_or(landed)
  if frames[quarter].3 <= 0.05 {
    bad.push("\{name} @\{frames[quarter].0.round()}ms: \{what} unseen a quarter of their way in (\{frames[quarter].3})")
  }
  if frames[landed].3 < 0.99 {
    bad.push("\{name} @\{land.round()}ms: \{what} not whole as they land (\{frames[landed].3})")
  }
  bad
}

///|
test "words sent fly out of the field with their ground coming in round them as they go across, from the first, whole as they land: the old page's desktop flight_ground" {
  let text = "发布前再看一眼签名"
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 600
    #|tap 发消息
    #|wait 500
    #|type 发布前再看一眼签名
    #|wait 700
    #|tap icon:arrow-up
    #|wait 1500
    #|exit
  let bad = []
  for screen in dk_screens {
    let (name, w, _, _) = screen
    // (a ground round the words drawn by the window's tree, as big as a bubble at most (not the column's, the list's):
    // how much of it is seen)
    let frames = dk_sent_frames(screen, script, text, fn(tr, _, wd) {
      let (cx, cy) = (wd.0 + wd.2 / 2.0, wd.1 + 4.0)
      let mut seen = 0.0
      for d in tr.drawn() {
        if (d.ground & 0xFFL) > 0L && d.w < 0.6 * w && d.h < 200.0 && d.x <= cx && d.x + d.w >= cx && d.y <= cy && d.y + d.h >= cy {
          seen = @cmp.maximum(seen, (d.ground & 0xFFL).to_double() / 255.0 * d.alpha)
        }
      }
      seen
    })
    // (their ground's own alpha whole as it rests: what it is seen at as they land is the most it is)
    let most = frames.fold(init=0.0, fn(m, f) { @cmp.maximum(m, f.3) })
    let frames = frames.map(fn(f) { (f.0, f.1, f.2, if most > 0.0 { f.3 / most } else { 0.0 }) })
    bad.append(dk_one_way_in(name, "their ground", frames, dk_landed_at(frames)))
  }
  if !bad.is_empty() {
    fail("ground round words sent not on their way across: \{bad.length()}, first \{bad[0]}")
  }
}

///|
test "words sent the station takes at once: what is under them (its time, 等待 agent 接收) comes in on their flight's way across, whole as they land, never after" {
  let text = "发布前再看一眼签名"
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 600
    #|tap 发消息
    #|wait 500
    #|type 发布前再看一眼签名
    #|wait 700
    #|tap icon:arrow-up
    #|wait 1500
    #|exit
  let bad = []
  for screen in dk_screens {
    let (name, _, h, _) = screen
    let under = ["等待 agent 接收", "刚刚"]
    let frames = dk_sent_frames(
      screen,
      script,
      text,
      fn(_, t, _) {
        let mut seen = 0.0
        for wd in t.words() {
          let (txt, _, y, _, _, a) = wd
          if under.contains(txt) && y > h / 2.0 {
            seen = @cmp.maximum(seen, a)
          }
        }
        seen
      },
      delivered_in=60.0,
    )
    bad.append(dk_one_way_in(name, "what is under them", frames, dk_landed_at(frames)))
  }
  if !bad.is_empty() {
    fail("under words sent not on their way across: \{bad.length()}, first \{bad[0]}")
  }
}

///|
test "a new chat's first words sent, the page made as nodes: they fly from where they stood in its field into the chat it becomes, never there at once" {
  let script =
    #|timeout 20000
    #|wait 1200
    #|tap 做任何事
    #|wait 500
    #|type 把发布说明写一下
    #|wait 700
    #|tap icon:arrow-up
    #|wait 2000
    #|exit
  let text = "把发布说明写一下"
  let bad = []
  for screen in dk_screens {
    let (name, w, h, platform) = screen
    // (the new chat's composer as it was last measured before the chat drew them, and where the window's tree draws
    // the words each frame)
    let mut field : (Double, Double, Double, Double)? = None
    let path : Array[(Double, Double, Double)] = []
    dk_host_each("newchat", w, h, platform, script, fn(t, at) {
      let in_tree = match @ui.view_tree() {
        Some(tr) => tr.drawn().search_by(fn(d) { d.words == text && d.alpha > 0.05 }).map(fn(i) { tr.drawn()[i] })
        None => None
      }
      match in_tree {
        Some(d) => path.push((at, d.x, d.y))
        None =>
          if path.is_empty() {
            match @motion.measured_rect(t.ctx(), "new/composer") {
              Some(r) => field = Some(r)
              None => ()
            }
          }
      }
    })
    guard path.length() > 2 && field is Some((fx, fy, fw, fh)) else {
      bad.push("\{name}: the composer \{Repr(field)}, drawn by the chat in \{path.length()} frames")
      continue
    }
    // (set out where they stood: in the composer, not where they rest; and on their way from there, no frame a step)
    let (at0, x0, y0) = path[0]
    let (_, xe, ye) = path[path.length() - 1]
    if (x0 - xe).abs() + (y0 - ye).abs() < 40.0 {
      bad.push("\{name}: first drawn by the chat @\{at0.round()}ms at (\{x0}, \{y0}), where they rest")
    }
    if y0 < fy - 140.0 || y0 > fy + fh || x0 < fx - 1.0 || x0 > fx + fw {
      bad.push("\{name}: the composer at (\{fx}, \{fy}, \{fw}, \{fh}), first drawn by the chat @\{at0.round()}ms at (\{x0}, \{y0})")
    }
    for i in 1..<path.length() {
      let (at, x, y) = path[i]
      let (_, px, py) = path[i - 1]
      if (x - px).abs() + (y - py).abs() > 80.0 {
        bad.push("\{name}: a step @\{at.round()}ms from (\{px}, \{py}) to (\{x}, \{y})")
        break
      }
    }
  }
  if !bad.is_empty() {
    fail("a new chat's first words not flown from its field: \{bad.join("; ")}")
  }
}

///|
test "大屏: a new chat's composer, as its first words are sent, comes down from where it stood to the chat's foot, never there at once" {
  let script =
    #|timeout 20000
    #|wait 1200
    #|tap 做任何事
    #|wait 500
    #|type 把发布说明写一下
    #|wait 700
    #|tap icon:arrow-up
    #|wait 2000
    #|exit
  let (name, w, h, platform) = dk_screens[0]
  // (the new chat's composer as last measured before it was sent from, and where the chat's composer's hint is drawn
  // each frame after)
  let mut field : (Double, Double, Double, Double)? = None
  let path : Array[(Double, Double)] = []
  dk_host_each("newchat", w, h, platform, script, fn(t, at) {
    let hint = t.words().filter(fn(d) { d.0 == "发消息" && d.5 > 0.05 })
    match hint.get(0) {
      Some(d) => path.push((at, d.2))
      None =>
        if path.is_empty() {
          match @motion.measured_rect(t.ctx(), "new/composer") {
            Some(r) => field = Some(r)
            None => ()
          }
        }
    }
  })
  guard path.length() > 2 && field is Some((_, fy, _, fh)) else {
    fail("\{name}: the composer \{Repr(field)}, its hint drawn in \{path.length()} frames")
  }
  let (at0, y0) = path[0]
  let (_, ye) = path[path.length() - 1]
  let bad = []
  if y0 > fy + fh || y0 < fy - 40.0 {
    bad.push("first drawn @\{at0.round()}ms at y \{y0}, the new chat's composer at \{fy}..\{fy + fh}, it rests at \{ye}")
  }
  for i in 1..<path.length() {
    let (at, y) = path[i]
    let (_, py) = path[i - 1]
    if (y - py).abs() > 80.0 {
      bad.push("a step @\{at.round()}ms from \{py} to \{y}")
      break
    }
  }
  if !bad.is_empty() {
    fail("\{name}: \{bad.join("; ")}; path \{Repr(path.map(fn(p) { (p.0.round(), p.1.round()) }))}")
  }
}

///|
test "大屏: a picture sent just after the side panel opened sets out from where its tile is drawn in the composer, not where the composer was last built" {
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 600
    #|tap 发消息
    #|wait 400
    #|picks 截图.png:160x120
    #|key cmd+u
    #|wait 900
    #|tap icon:panel-open
    #|wait 1200
    #|tap icon:arrow-up
    #|wait 1200
    #|exit
  let (name, w, h, platform) = dk_screens[0]
  // (the composer's tile as last drawn, and the picture the window's tree first draws)
  let mut tile : (Double, Double, Double, Double)? = None
  let mut first : (Double, Double, Double, Double, Double)? = None
  dk_host_each("chat", w, h, platform, script, fn(t, at) {
    guard first is None else { return }
    let flown = match @ui.view_tree() {
      Some(tr) =>
        tr.drawn().filter(fn(d) { d.image is Some(_) && d.alpha > 0.05 && d.w >= 24.0 && d.y > h / 2.0 }).map(fn(d) {
          (d.x, d.y, d.w, d.h)
        })
      None => []
    }
    // (the composer an old view hosted, its tile none of the tree's: a picture the tree draws there is what flies)
    let all = t.drawn_images().filter(fn(i) { i[8] > 0.05 && i[2] >= 24.0 && i[1] > h / 2.0 })
    match flown.get(0) {
      Some(f) => first = Some((at, f.0, f.1, f.2, f.3))
      None =>
        match all.last() {
          Some(i) => tile = Some((i[0], i[1], i[2], i[3]))
          None => ()
        }
    }
  })
  match (tile, first) {
    (Some((tx, ty, _, _)), Some((at, x, y, _, _))) =>
      if (x - tx).abs() > 2.0 || (y - ty).abs() > 2.0 {
        fail("\{name}: the tile drawn at (\{tx}, \{ty}), the picture set out @\{at.round()}ms from (\{x}, \{y})")
      }
    _ => fail("\{name}: the tile \{Repr(tile)}, the picture flying \{Repr(first)}")
  }
}

///|
test "a picture, a file and words sent, as a host draws it: the file's card drawn once in the frame it is sent, not in the composer and on its way both" {
  let drives = [
    (
      "chat",
      1280.0,
      800.0,
      0,
      ["构建日志", "2 KB"],
      (
        #|timeout 20000
        #|until 发消息
        #|wait 600
        #|tap 发消息
        #|wait 500
        #|picks 截图.png:160x120
        #|key cmd+u
        #|wait 900
        #|picks 构建日志.log:2000
        #|key cmd+u
        #|wait 900
        #|type 截图和日志都在这里
        #|wait 600
        #|tap icon:arrow-up
        #|wait 1200
        #|exit
      ),
    ),
    (
      "chat-attach-pic",
      390.0,
      844.0,
      2,
      ["build", "18 KB"],
      (
        #|timeout 20000
        #|wait 1500
        #|tap icon:arrow-up
        #|wait 1200
        #|exit
      ),
    ),
  ]
  let twice = []
  for d in drives {
    let (mode, w, h, platform, sent, script) = d
    for f in dk_host_words(mode, w, h, platform, script) {
      for k in f.2 {
        if sent.contains(k) {
          twice.push("\{mode}: 「\{k}」 drawn twice @\{f.0.round()}ms")
        }
      }
    }
  }
  if !twice.is_empty() {
    fail("what is sent drawn twice: \{twice.length()}, first \{twice[:@cmp.minimum(4, twice.length())].join("; ")}")
  }
}

///|
test "大屏: a video sent flies from its tile in the composer, not drawn first where it comes to rest" {
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 600
    #|tap icon:arrow-up
    #|wait 1500
    #|exit
  let (name, w, h, platform) = dk_screens[0]
  // (the composer's tiles as last drawn, its picture's and its video's, side by side; and the pictures the window's
  // tree draws in the first frame it draws any, the sent message's)
  let tiles : Array[(Double, Double)] = []
  let first : Array[(Double, Double, Double, Double)] = []
  dk_host_each("chat-attach-video", w, h, platform, script, fn(t, _) {
    guard first.is_empty() else { return }
    let flown = match @ui.view_tree() {
      Some(tr) =>
        tr.drawn().filter(fn(d) { d.image is Some(_) && d.alpha > 0.05 && d.w >= 24.0 }).map(fn(d) { (d.x, d.y, d.w, d.h) })
      None => []
    }
    if flown.is_empty() {
      let now = t.drawn_images().filter(fn(i) { i[8] > 0.05 && i[2] >= 24.0 && i[1] > h / 2.0 }).map(fn(i) { (i[0], i[1]) })
      if now.length() == 2 {
        tiles.clear()
        tiles.append(now)
      }
    } else {
      first.append(flown)
    }
  })
  guard tiles.length() == 2 && first.length() >= 2 else {
    fail("\{name}: the composer's tiles \{Repr(tiles)}, the tree's first pictures \{Repr(first)}")
  }
  // (each tile's picture set out from it: the video's (the one further across) as the picture's)
  for tile in tiles {
    guard first.iter().any(fn(p) { (p.0 - tile.0).abs() <= 3.0 && (p.1 - tile.1).abs() <= 3.0 }) else {
      fail("\{name}: no picture set out from the tile at \{Repr(tile)}: the tree's first \{Repr(first)}")
    }
  }
}
