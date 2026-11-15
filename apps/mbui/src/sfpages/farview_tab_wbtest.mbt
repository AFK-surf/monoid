// A chat's Farview tab drawn here (farview_tab.mbt), over a core made up for it: `farview.view` asked as it is shown,
// the stage's Hello said as it goes live, the host's bytes drawn as nodes of the window's tree, a tap said to the host,
// a box of the page's that scrolls scrolled here and its place told the host, and the view let go as the tab goes.

///|
priv struct FarviewRig {
  t : @ui.Tester
  /// what was sent by `farview.send`, in order
  sent : Array[Bytes]
  /// the views asked (`farview.view`): what each is told, and how many were let go
  views : Array[(Json, (Json, Bytes?) -> Unit)]
  cancelled : Array[Int]
  shown : @signals.Signal[Bool]
}

///|
/// Long enough for what the host sent to be drawn, and for a box let go of after a drag to come to rest.
let farview_drawn_ms : Double = 2000.0

///|
fn farview_rig(screen? : String = "browser:fv_t1") -> FarviewRig {
  @sfbase.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sf.set_dark(Some(false))
  let sent : Array[Bytes] = []
  let views : Array[(Json, (Json, Bytes?) -> Unit)] = []
  let cancelled : Array[Int] = []
  let base = @sfbase.made_source(topic=fn(name, _) { if name == "prefs" { Some(Json::object({})) } else { None } })
  let src : Source = {
    ..base,
    call_bytes: fn(name, _, bytes, done) {
      if name == "farview.send" {
        sent.push(bytes)
      }
      done(Ok(Json::null()))
    },
    stream: fn(name, params, bytes, on_value, done) {
      if name != "farview.view" {
        return (base.stream)(name, params, bytes, on_value, done)
      }
      views.push((params, on_value))
      views.length()
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  let shown = @signals.signal(true)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.show(fn() { shown.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        farview_tab_node(p, src, "ws-1/st-1", screen)
      })
    },
    w=390.0,
    h=844.0,
  )
  t.draw()
  { t, sent, views, cancelled, shown }
}

///|
/// What the host says of a page 390 wide and 1000 tall: its address, then a frame of one piece, red with a white box,
/// and a box that scrolls (id 7) 300 tall from 400 down, its content 900 tall, a green band at its top.
fn farview_page_bytes() -> Bytes {
  let ops : Array[@proto.Op] = [
    Rect(0.0, 0.0, 390.0, 1000.0, 0xFF0000FF),
    Rect(20.0, 20.0, 100.0, 40.0, 0xFFFFFFFF),
    ScrollBox(7, 0.0, 400.0, 390.0, 300.0, 390.0, 900.0),
    Rect(0.0, 400.0, 390.0, 50.0, 0x00FF00FF),
    Unclip,
  ]
  let out = Buffer()
  out.write_bytes(@proto.encode(Page("https://example.test/")))
  out.write_bytes(@proto.encode(Frame(390.0, 1000.0, [(1, 0.0)], [(1, ops)])))
  out.to_bytes()
}

///|
/// What `bytes` say, as messages.
fn farview_said(bytes : Bytes) -> Array[@proto.Message] {
  let framer = @proto.Framer::new()
  framer.push(bytes)
  let out = []
  while framer.next() is Some(body) {
    out.push(@proto.decode(body))
  }
  out
}

///|
test "a Farview tab: asked as shown, Hello as it goes live, the page drawn as nodes, a tap the host's, a box scrolled here, let go as it goes" {
  let r = farview_rig()
  // asked as it is shown, of its station and its tab
  assert_eq(r.views.length(), 1)
  let (params, tell) = r.views[0]
  guard params is Object(p) else { fail("no params") }
  assert_eq((p.get("station"), p.get("screen")), (Some(Json::string("ws-1/st-1")), Some(Json::string("browser:fv_t1"))))
  // live: its viewport said to the host (the stage's room, the window's scale)
  tell(Json::object({ "state": Json::object({ "phase": "live", "opens": Json::number(1.0) }) }), None)
  r.t.draw()
  let hello = r.sent.map(fn(b) { farview_said(b) }).flatten().filter(fn(m) { m is Hello(_, _, _) })
  guard hello is [Hello(w, h, scale), ..] else { fail("no Hello: \{hello.length()} said") }
  assert_eq((w, scale), (390.0, 2.0))
  assert_true(h > 600.0 && h < 844.0)
  // the page: drawn as nodes (its rectangles), no tiles
  @ui.answered_from_outside(fn() { tell(Json::object({ "data": Json::boolean(true) }), Some(farview_page_bytes())) })
  r.t.run_for(farview_drawn_ms)
  let top = 844.0 - h
  let green = fn() { r.t.drawn_rects().filter(fn(d) { d.4 == 0x00FF00FFL && d.2 == 390.0 }) }
  assert_true(r.t.drawn_rects().any(fn(d) { d.4 == 0xFF0000FFL && d.2 == 390.0 }))
  assert_true(r.t.drawlist_images().all(fn(i) { !i.1.has_prefix("farview-") }))
  // (the box that scrolls where the host put it, on the window's pixels)
  assert_true(green() is [band] && (band.1 - (top + 400.0)).abs() < 0.5)
  // a tap on the page: the host's, at that point of the page, as a browser's press and let go
  r.sent.clear()
  r.t.tap(60.0, h / 2.0 + (844.0 - h))
  r.t.draw()
  let taps = r.sent
    .map(fn(b) { farview_said(b) })
    .flatten()
    .filter_map(fn(m) { if m is Person(p) && p.contains("\"pointer\"") { Some(p.contains("\"down\"")) } else { None } })
  assert_eq(taps, [true, false])
  // the box that scrolls, dragged up 120: scrolled here, under the finger, and where it came to told the host
  r.sent.clear()
  r.t.drag(200.0, top + 650.0, 200.0, top + 530.0)
  r.t.run_for(farview_drawn_ms)
  let told = r.sent
    .map(fn(b) { farview_said(b) })
    .flatten()
    .filter_map(fn(m) { if m is BoxScroll(7, _, y) { Some(y) } else { None } })
  guard told.last() is Some(y) && y > 60.0 else { fail("box scroll told: \{told.length()}") }
  // (the green band at the box's top gone up by as much, cut where the box starts)
  assert_true(green().all(fn(d) { d.1 + d.3 <= top + 400.0 + 50.0 - y + 1.0 }))
  // gone: the view let go
  r.shown.set(false)
  r.t.draw()
  assert_eq(r.cancelled.length(), 1)
}

///|
test "a Farview tab: the host's bytes cut anywhere, frames one after another, each a message of its own: the page as the last says" {
  let r = farview_rig()
  let (_, tell) = r.views[0]
  tell(Json::object({ "state": Json::object({ "phase": "live", "opens": Json::number(1.0) }) }), None)
  r.t.draw()
  let white = fn(n : Int, y : Double) {
    let ops : Array[@proto.Op] = [Rect(0.0, 0.0, 390.0, 1000.0, 0xFF0000FF), Rect(20.0, y, 100.0, 40.0, 0xFFFFFFFF)]
    @proto.encode(Frame(390.0, 1000.0, [(n, 0.0)], [(n, ops)]))
  }
  let all = Buffer()
  all.write_bytes(farview_page_bytes())
  all.write_bytes(white(2, 30.0))
  all.write_bytes(white(3, 40.0))
  all.write_bytes(white(4, 50.0))
  let bytes = all.to_bytes()
  // (in pieces of 7 bytes, cut through the messages, each told as the core tells one, before the next frame)
  let mut at = 0
  while at < bytes.length() {
    let cut = Buffer()
    for k in at..<(at + 7).min(bytes.length()) {
      cut.write_byte(bytes[k])
    }
    let piece = cut.to_bytes()
    @ui.answered_from_outside(fn() { tell(Json::object({ "data": Json::boolean(true) }), Some(piece)) })
    at += 7
  }
  r.t.draw()
  let whites = r.t.drawn_rects().filter(fn(d) { d.4 == 0xFFFFFFFFL && d.2 == 100.0 })
  guard whites is [w] else { fail("white boxes: \{whites.length()}") }
  // (50 down the page, as the last frame put it)
  guard r.t.drawn_rects().filter(fn(d) { d.4 == 0xFF0000FFL && d.2 == 390.0 }) is [red, ..] else { fail("no page") }
  assert_eq(w.1 - red.1, 50.0)
}

///|
test "a Farview tab widened with its window says its new width to the host" {
  // (a tab of its own: a tab's stage is kept while the app runs, by its id)
  let r = farview_rig(screen="browser:fv_wide")
  let (_, tell) = r.views[0]
  tell(Json::object({ "state": Json::object({ "phase": "live", "opens": Json::number(1.0) }) }), None)
  r.t.draw()
  let widths = fn() {
    r.sent.map(fn(b) { farview_said(b) }).flatten().filter_map(fn(m) { if m is Hello(w, _, _) { Some(w) } else { None } })
  }
  assert_eq(widths(), [390.0])
  r.t.resize(900.0, 844.0)
  r.t.run_for(farview_drawn_ms)
  assert_eq(widths().last(), Some(900.0))
}
