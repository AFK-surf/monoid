///|
test "two identical Mermaid blocks in one message are two pictures, the chart asked of the core once" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let fixture = @sffixture.fixture("chat-viz")
  let asked = Ref(0)
  let src = {
    ..fixture,
    call: fn(name, params, done) {
      if name == "mermaid.chart" {
        asked.val += 1
      }
      (fixture.call)(name, params, done)
    },
  }
  let chat = src.topic("chat", { "station": "ws1/st1", "session": "s-c1" }).get().value.unwrap()
  let view = @sfbase.chat_view_made(chat)
  let original = view.messages[view.messages.length() - 1]
  let block : Json = ["pre", { "code": "graph TD; A-->B", "lang": "mermaid" }]
  let message = { ..original, text: "two charts", md: Some(Json::array([block, block])), attachments: [], placed: [] }
  let here : MessageHere = { station: "ws1/st1", session: "s-c1", view, go: None, inline: false, gutter: 0.0, list: None, core: None }
  let t = @ui.Tester::new(fn(c) {
    @sf.begin(c) |> ignore
    c.with_theme(@sf.ui_theme(), fn() { prose_with_files(c, src, here, message, []) })
  }, w=390.0, h=700.0, platform=1)
  t.check_looks(false)
  t.draw()
  t.frames_owed()
  assert_eq(asked.val, 1)
  // each with its own way to the whole screen, in its own place
  let ways = t.semantics().filter(fn(s) { s.label == @sfbase.viz_tr("android-misc.viz.fullscreen") })
  assert_eq(ways.length(), 2)
  assert_true(ways[0].rect.1 != ways[1].rect.1)
}

///|
test "a mermaid chart the core makes is drawn as a picture in the theme's colours, no page for it" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let fixture = @sffixture.fixture("chat-viz")
  let asked : Array[Json] = []
  let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><rect width=\"200\" height=\"100\"/></svg>"
  let src = {
    ..fixture,
    call: fn(name, params, done) {
      if name == "mermaid.chart" {
        asked.push(params)
        done(Ok({ "svg": ToJson::to_json(svg), "width": ToJson::to_json(200.0), "height": ToJson::to_json(100.0) }))
      } else {
        (fixture.call)(name, params, done)
      }
    },
  }
  let chat = src.topic("chat", { "station": "ws1/st1", "session": "s-c1" }).get().value.unwrap()
  let view = @sfbase.chat_view_made(chat)
  let original = view.messages[view.messages.length() - 1]
  let block : Json = ["pre", { "code": "graph TD; A-->B", "lang": "mermaid" }]
  let message = { ..original, text: "a chart", md: Some(Json::array([block])), attachments: [], placed: [] }
  let here : MessageHere = { station: "ws1/st1", session: "s-c1", view, go: None, inline: false, gutter: 0.0, list: None, core: None }
  let t = @ui.Tester::new(fn(c) {
    @sf.begin(c) |> ignore
    c.with_theme(@sf.ui_theme(), fn() { prose_with_files(c, src, here, message, []) })
  }, w=390.0, h=700.0, platform=1)
  t.check_looks(false)
  t.draw()
  t.frames_owed()
  // asked once, its code and the theme's colours, each #rrggbb
  assert_eq(asked.length(), 1)
  match asked[0] {
    { "code": String(code), "colours": Object(colours), "width": Number(_, ..), .. } => {
      assert_eq(code, "graph TD; A-->B")
      assert_eq(colours.length(), 8)
      for _, v in colours {
        guard v is String(hex) && hex.length() == 7 && hex.has_prefix("#") else { fail("a colour as #rrggbb: \{Repr(v)}") }
      }
    }
    _ => fail("asked \{Repr(asked[0])}")
  }
  // drawn as a picture at its size as written (200 wide, in a column wider than that), and no page opened for it
  assert_true(t.image_loads().length() > 0)
  let opened = t.views().filter(fn(line) { line.has_prefix("open ") })
  assert_eq(opened.length(), 0)
}

///|
test "a chart the core will not make shows as its code" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let fixture = @sffixture.fixture("chat-viz")
  let src = {
    ..fixture,
    call: fn(name, params, done) {
      if name == "mermaid.chart" {
        done(Err({ "code": "unsupported", "message": "Parse error on line 1" }))
      } else {
        (fixture.call)(name, params, done)
      }
    },
  }
  let chat = src.topic("chat", { "station": "ws1/st1", "session": "s-c1" }).get().value.unwrap()
  let view = @sfbase.chat_view_made(chat)
  let original = view.messages[view.messages.length() - 1]
  let block : Json = ["pre", { "code": "graph TD; A-->", "lang": "mermaid" }]
  let message = { ..original, text: "a chart", md: Some(Json::array([block])), attachments: [], placed: [] }
  let here : MessageHere = { station: "ws1/st1", session: "s-c1", view, go: None, inline: false, gutter: 0.0, list: None, core: None }
  let t = @ui.Tester::new(fn(c) {
    @sf.begin(c) |> ignore
    c.with_theme(@sf.ui_theme(), fn() { prose_with_files(c, src, here, message, []) })
  }, w=390.0, h=700.0, platform=1)
  t.check_looks(false)
  t.draw()
  t.frames_owed()
  assert_true(t.find("graph TD; A-->") is Some(_))
  assert_eq(t.views().filter(fn(l) { l.has_prefix("open ") }).length(), 0)
}

///|
/// A .mbui widget placed in a message (message_viz_node, as nodes), 360 wide on a phone, its file read through `held`:
/// answered as the test says, at once where `at_once` gives what it reads (then the widget there as it is made). What it
/// cannot read drawn as a line naming the file.
fn viz_node_tester(held : Ref[((Result[(Json, Bytes), Json]) -> Unit)?], at_once? : Result[(Json, Bytes), Json]) -> @ui.Tester {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.viz_loads.clear()
  let base = @sffixture.fixture("chat-viz")
  let src = {
    ..base,
    read_bytes: fn(_, _, done) {
      match at_once {
        Some(r) => done(r)
        None => held.val = Some(done)
      }
    },
    // (what the widget kept: nothing)
    call: fn(name, _, done) { if name == "widget.state" { done(Ok({ "state": Json::null() })) } },
  }
  let a : Attachment = {
    name: "board.mbui",
    path: "work/s-c1/board.mbui",
    size: 0.0,
    width: 0.0,
    height: 0.0,
    thumbhash: "",
    owner: "s-c1",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
  @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(f) {
        f.width(Is(Some(360.0))) |> ignore
        message_viz_node(f, src, tips, "ws1/st1", "s-c1", "s-c1", "ts1", a, fn(p) {
          @sf.words_node(p, fn() { "读不了：board.mbui" }, fn() { @sf.ask_note }) |> ignore
        })
      })
      |> ignore
    },
    w=390.0,
    h=700.0,
    platform=1,
  )
}

///|
/// A widget's words as a .mbui file holds them.
let viz_node_widget : String = "{\"title\":\"看板\",\"root\":{\"type\":\"card\",\"title\":\"小看板卡片\",\"children\":[]}}"

///|
test "a .mbui widget placed in a message, made as nodes: its breathing place stays, fading where it stood, as the widget or its file's card comes in its place, never gone in the frame the file comes; read already as it is made, the widget there at once" {
  for ok in [true, false] {
    let held : Ref[((Result[(Json, Bytes), Json]) -> Unit)?] = Ref(None)
    let t = viz_node_tester(held)
    t.run_for(@ui.move_most_ms)
    let words = if ok { "小看板卡片" } else { "读不了：board.mbui" }
    assert_true(signin_seen(t, words) is None, msg="\{words} before its file is read")
    guard held.val is Some(done) else { fail("its file not asked") }
    // (the file come from the core between frames, as a device's core's message comes)
    @ui.answered_from_outside(fn() {
      done(if ok { Ok((Json::null(), @utf8.encode(viz_node_widget))) } else { Err({ "message": "没有这个文件" }) })
    })
    // (half way through the place's going: what comes waits for it to be gone)
    t.run_for(@sf.leave_ms / 2.0)
    assert_eq(signin_seen(t, words).unwrap_or(0.0), 0.0, msg="\{words} seen while its place still fades")
    t.run_for(@ui.move_most_ms)
    assert_eq(signin_seen(t, words), Some(1.0), msg="\{words} not come whole once its place is gone")
  }
  // read already as it is made: the widget in the first frame, nothing waited for
  let held : Ref[((Result[(Json, Bytes), Json]) -> Unit)?] = Ref(None)
  let t = viz_node_tester(held, at_once=Ok((Json::null(), @utf8.encode(viz_node_widget))))
  t.draw()
  assert_eq(signin_seen(t, "小看板卡片"), Some(1.0), msg="read as it is made, the widget not there whole at once")
}
