// A chat's Farview tab drawn here (farview_tab.mbt), over a core made up for it: `farview.view` asked as it is shown,
// the stage's Hello and viewport said as it goes live (the viewport as tall as the window less the tab's bar), the
// host's document (fvclient's doc wire, made as a host makes it: fvclient/doc's Mirror) laid out and drawn here as
// nodes, a tap said to the host on the element under it, a box of the page's that scrolls scrolled here and its place
// told the host, the view let go as the tab goes; the same tab shown twice at once, each a stage and a view of its own;
// a page of a real tab's size, what each change of it makes, lays out and measures, laid out once a moment.

///|
priv struct FarviewRig {
  t : @ui.Tester
  /// what was sent by `farview.send`, in order, each with the view it was sent for
  sent : Array[(String, Bytes)]
  /// the views asked (`farview.view`): what each is told, and how many were let go
  views : Array[(Json, (Json, Bytes?) -> Unit)]
  cancelled : Array[Int]
  /// how many places show the tab
  places : @signals.Signal[Int]
}

///|
/// Long enough for what the host sent to be drawn, and for a box let go of after a drag to come to rest.
let farview_drawn_ms : Double = 3000.0

///|
/// `w` wide; `over` and `under`: a shell's bars over and under the tab (what holds it gives it the rest).
fn farview_rig(
  screen? : String = "browser:fv_t1",
  places? : Int = 1,
  w? : Double = 390.0,
  over? : Double = 0.0,
  under? : Double = 0.0,
  font_scale? : Double = 1.0,
) -> FarviewRig {
  @sfbase.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sf.set_dark(Some(false))
  let sent : Array[(String, Bytes)] = []
  let views : Array[(Json, (Json, Bytes?) -> Unit)] = []
  let cancelled : Array[Int] = []
  let base = @sfbase.made_source(topic=fn(name, _) { if name == "prefs" { Some(Json::object({})) } else { None } })
  let src : Source = {
    ..base,
    call_bytes: fn(name, params, bytes, done) {
      if name == "farview.send" {
        let view = match params {
          Object(o) => match o.get("view") { Some(String(v)) => v; _ => "" }
          _ => ""
        }
        sent.push((view, bytes))
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
  let shown = @signals.signal(places)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(col) {
        col.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        col.box(fn(b) { b.height(Is(Some(over))) |> ignore }) |> ignore
        col.box(fn(row) {
          row.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
          for i in 0..<2 {
            row.show(fn() { shown.get() > i }, fn(p) {
              p.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
              farview_tab_node(p, src, "ws-1/st-1", screen)
            })
          }
        })
        |> ignore
        col.box(fn(b) { b.height(Is(Some(under))) |> ignore }) |> ignore
      })
      |> ignore
    },
    w~,
    h=844.0,
  )
  t.set_font_scale(font_scale)
  t.draw()
  { t, sent, views, cancelled, places: shown }
}

///|
/// What a host of a page says of it as it sends it whole, then as it changes (fvclient/doc's Mirror).
priv struct FarviewHost {
  doc : @html.Node
  css : String
  mirror : @doc.Mirror
  mut seq : Int
}

///|
/// A page of a red block 1000 tall (its body's margin none), a white box in it at 20 down, and a box that scrolls
/// (id `box`) 300 tall from 400 down, its content 900 tall, a green band at its top.
let farview_page_html : String = "<!doctype html><html><head><link rel=stylesheet href=s.css></head><body>" +
  "<div id=page class=page><div id=white class=white></div><div id=box class=box><div class=band></div>" +
  "<div class=rest></div></div></div></body></html>"

///|
let farview_page_css : String = "body { margin: 0 } .page { position: relative; height: 1000px; background: rgb(255, 0, 0) } " +
  ".white { position: absolute; left: 20px; top: 20px; width: 100px; height: 40px; background: rgb(255, 255, 255) } " +
  ".box { position: absolute; left: 0; right: 0; top: 400px; height: 300px; overflow: auto } " +
  ".band { height: 50px; background: rgb(0, 255, 0) } .rest { height: 850px }"

///|
fn FarviewHost::new(html? : String = farview_page_html, css? : String = farview_page_css) -> FarviewHost {
  { doc: @html.parse(html), css, mirror: @doc.Mirror::new(), seq: 0 }
}

///|
fn FarviewHost::state(self : FarviewHost) -> @doc.DocState {
  {
    base: "https://example.test/",
    root: self.doc,
    frames: [],
    sheets: [("https://example.test/s.css", self.css)],
    cssom: [],
    defined: fn(_) { false },
    states: fn(_) { 0 },
    target: "",
  }
}

///|
/// The tab's address, then the document whole.
fn FarviewHost::reset(self : FarviewHost) -> Bytes {
  self.seq += 1
  let out = Buffer()
  out.write_bytes(@proto.encode_host(Meta("https://example.test/", "Example", false, false, false)))
  out.write_bytes(@proto.encode_host(Reset(self.seq, 0, self.mirror.reset(self.state()))))
  out.to_bytes()
}

///|
/// What changed since.
fn FarviewHost::patch(self : FarviewHost) -> Bytes {
  self.seq += 1
  @proto.encode_host(Patch(self.seq, 0, self.mirror.diff(self.state()).unwrap()))
}

///|
fn FarviewHost::find(self : FarviewHost, id : String) -> @html.Node {
  fn walk(n : @html.Node) -> @html.Node? {
    if n.attr("id") == Some(id) {
      return Some(n)
    }
    for c in n.children {
      if walk(c) is Some(x) {
        return Some(x)
      }
    }
    None
  }

  walk(self.doc).unwrap()
}

///|
/// What `bytes` say, as the client's messages.
fn farview_said(sent : Array[(String, Bytes)], view? : String = "") -> Array[@proto.ClientMsg] {
  let framer = @proto.Framer::new()
  for s in sent {
    if view == "" || s.0 == view {
      framer.push(s.1[:])
    }
  }
  let out = []
  while framer.next() is Some(body) {
    if @proto.decode_client(body) is Some(m) {
      out.push(m)
    }
  }
  out
}

///|
fn farview_live(tell : (Json, Bytes?) -> Unit) -> Unit {
  tell(Json::object({ "state": Json::object({ "phase": "live", "opens": Json::number(1.0) }) }), None)
}

///|
fn farview_feed(tell : (Json, Bytes?) -> Unit, bytes : Bytes) -> Unit {
  @ui.answered_from_outside(fn() { tell(Json::object({ "data": Json::boolean(true) }), Some(bytes)) })
}

///|
fn farview_view_of(params : Json) -> String {
  match params {
    Object(o) => match o.get("view") { Some(String(v)) => v; _ => "" }
    _ => ""
  }
}

///|
test "a Farview tab: asked as shown, its viewport as tall as the window less its bar, the page drawn as nodes, a tap the host's, a box scrolled here, let go as it goes" {
  let r = farview_rig()
  // asked as it is shown, of its station and its tab
  assert_eq(r.views.length(), 1)
  let (params, tell) = r.views[0]
  guard params is Object(p) else { fail("no params") }
  assert_eq((p.get("station"), p.get("screen")), (Some(Json::string("ws-1/st-1")), Some(Json::string("browser:fv_t1"))))
  // live: its wire said, then its viewport (the stage's room, the window's scale)
  farview_live(tell)
  r.t.run_for(farview_drawn_ms)
  guard farview_said(r.sent) is [Hello(@proto.VERSION, "doc"), ..] else { fail("no Hello first") }
  let ports = farview_said(r.sent).filter_map(fn(m) { if m is Viewport(w, h, s) { Some((w, h, s)) } else { None } })
  guard ports.last() is Some((w, h, scale)) else { fail("no Viewport") }
  assert_eq((w, scale), (390.0, 2.0))
  // the page: laid out and drawn here as nodes (its rectangles), no pictures of it
  let host = FarviewHost::new()
  farview_feed(tell, host.reset())
  r.t.run_for(farview_drawn_ms)
  let red = r.t.drawn_rects().filter(fn(d) { d.4 == 0xFF0000FFL && d.2 == 390.0 })
  guard red is [page, ..] else { fail("no page drawn") }
  let top = page.1
  assert_true(top > 0.0)
  // (the viewport exactly the window's height less the bar over the page)
  assert_true((h - (844.0 - top)).abs() < 0.01)
  assert_true(r.t.drawlist_images().all(fn(i) { !i.1.has_prefix("farview-") }))
  let green = fn() { r.t.drawn_rects().filter(fn(d) { d.4 == 0x00FF00FFL && d.2 == 390.0 }) }
  assert_true(green() is [band] && (band.1 - (top + 400.0)).abs() < 0.5)
  // a tap on the white box: the host's, on that element, pressed and let go
  r.sent.clear()
  r.t.tap(60.0, top + 40.0)
  r.t.run_for(farview_drawn_ms)
  let white = host.find("white").uid
  let presses = farview_said(r.sent).filter_map(fn(m) {
    if m is Pointer(_, kind, _, _, id, _, _, _, _) && id == white && kind != @proto.POINTER_MOVE {
      Some(kind)
    } else {
      None
    }
  })
  assert_true(presses.contains(@proto.POINTER_DOWN) && presses.contains(@proto.POINTER_UP))
  // the box that scrolls, dragged up 120: scrolled here, under the finger, and where it came to told the host
  r.sent.clear()
  r.t.drag(200.0, top + 650.0, 200.0, top + 530.0)
  r.t.run_for(farview_drawn_ms)
  let box = host.find("box").uid
  let told = farview_said(r.sent).filter_map(fn(m) { if m is ScrollSync(id, _, y) && id == box { Some(y) } else { None } })
  guard told.last() is Some(y) && y > 60.0 else { fail("box scroll told: \{told.length()}") }
  // (the green band at the box's top gone up by as much, cut where the box starts)
  assert_true(green().all(fn(d) { d.1 + d.3 <= top + 400.0 + 50.0 - y + 1.0 }))
  // gone: the view let go
  r.places.set(0)
  r.t.draw()
  assert_eq(r.cancelled.length(), 1)
}

///|
test "a Farview tab: the host's bytes cut anywhere, changes one after another: the page as the last says" {
  let r = farview_rig(screen="browser:fv_cut")
  let (_, tell) = r.views[0]
  farview_live(tell)
  r.t.draw()
  let host = FarviewHost::new()
  let all = Buffer()
  all.write_bytes(host.reset())
  let white = host.find("white")
  let style : @html.Attr = { prefix: "", name: "style", value: "", ns: "" }
  white.attrs.push(style)
  for y in [30, 40, 50] {
    style.value = "top: \{y}px"
    all.write_bytes(host.patch())
  }
  let bytes = all.to_bytes()
  // (in pieces of 7 bytes, cut through the messages, each told as the core tells one)
  let mut at = 0
  while at < bytes.length() {
    let cut = Buffer()
    for k in at..<(at + 7).min(bytes.length()) {
      cut.write_byte(bytes[k])
    }
    farview_feed(tell, cut.to_bytes())
    at += 7
  }
  r.t.run_for(farview_drawn_ms)
  let whites = r.t.drawn_rects().filter(fn(d) { d.4 == 0xFFFFFFFFL && d.2 == 100.0 })
  guard whites is [w] else { fail("white boxes: \{whites.length()}") }
  guard r.t.drawn_rects().filter(fn(d) { d.4 == 0xFF0000FFL && d.2 == 390.0 }) is [red, ..] else { fail("no page") }
  assert_eq(w.1 - red.1, 50.0)
}

///|
test "a Farview tab widened with its window says its new width to the host, laid out here at once" {
  let r = farview_rig(screen="browser:fv_wide")
  let (_, tell) = r.views[0]
  farview_live(tell)
  farview_feed(tell, FarviewHost::new().reset())
  r.t.run_for(farview_drawn_ms)
  let widths = fn() {
    farview_said(r.sent).filter_map(fn(m) { if m is Viewport(w, _, _) { Some(w) } else { None } })
  }
  assert_eq(widths().last(), Some(390.0))
  r.t.resize(900.0, 844.0)
  r.t.draw()
  // (the page as wide as the tab in the frame of the resize, before the host has said anything)
  assert_true(r.t.drawn_rects().any(fn(d) { d.4 == 0xFF0000FFL && d.2 == 900.0 }))
  r.t.run_for(farview_drawn_ms)
  assert_eq(widths().last(), Some(900.0))
}

///|
test "a Farview tab shown in two places at once: each a stage and a view of its own, its own viewport; idle ones taken again" {
  let r = farview_rig(screen="browser:fv_two", places=2)
  assert_eq(r.views.length(), 2)
  let (p0, tell0) = r.views[0]
  let (p1, tell1) = r.views[1]
  let v0 = farview_view_of(p0)
  let v1 = farview_view_of(p1)
  assert_true(v0 != v1)
  farview_live(tell0)
  farview_live(tell1)
  r.t.run_for(farview_drawn_ms)
  // each says its own viewport, half the window wide
  let width_of = fn(view : String) {
    farview_said(r.sent, view~).filter_map(fn(m) { if m is Viewport(w, _, _) { Some(w) } else { None } }).last()
  }
  assert_eq((width_of(v0), width_of(v1)), (Some(195.0), Some(195.0)))
  // the page given to one alone is drawn in that one alone
  farview_feed(tell0, FarviewHost::new().reset())
  r.t.run_for(farview_drawn_ms)
  let reds = r.t.drawn_rects().filter(fn(d) { d.4 == 0xFF0000FFL && d.2 == 195.0 })
  assert_true(reds.length() > 0 && reds.all(fn(d) { d.0 < 195.0 }))
  // given its page too, a tap on the other: said on its own view, not the first's
  farview_feed(tell1, FarviewHost::new().reset())
  r.t.run_for(farview_drawn_ms)
  r.sent.clear()
  r.t.tap(195.0 + 60.0, reds[0].1 + 40.0)
  r.t.run_for(farview_drawn_ms)
  assert_true(r.sent.length() > 0 && r.sent.all(fn(s) { s.0 == v1 }))
  // both gone, then one shown again: an idle stage taken again, no new one made
  r.places.set(0)
  r.t.draw()
  assert_eq(r.cancelled.length(), 2)
  r.places.set(1)
  r.t.draw()
  assert_eq(r.views.length(), 3)
  let again = farview_view_of(r.views[2].0)
  assert_true(again == v0 || again == v1)
}

///|
// The tab under a shell's bar and over its foot (a phone's page under its bar, the window's top band, a panel under its
// own): the page's viewport as tall as the tab is given less its own bar, not the window's (100vh and what is fixed at
// its foot where the tab's foot is).
test "a Farview tab: its viewport as tall as what holds it gives it, less its bar, under a shell's bars" {
  let r = farview_rig(screen="browser:fv_shell", over=60.0, under=34.0)
  let (_, tell) = r.views[0]
  farview_live(tell)
  r.t.run_for(farview_drawn_ms)
  let host = FarviewHost::new()
  farview_feed(tell, host.reset())
  r.t.run_for(farview_drawn_ms)
  let ports = farview_said(r.sent).filter_map(fn(m) { if m is Viewport(_, h, _) { Some(h) } else { None } })
  guard ports.last() is Some(h) else {
    fail("no Viewport: \{r.sent.length()} sent, \{farview_said(r.sent).length()} said, \{r.views.length()} views, rects " + r.t.drawn_rects().map(fn(d) { "\{d.0},\{d.1},\{d.2},\{d.3}" }).join(" "))
  }
  let red = r.t.drawn_rects().filter(fn(d) { d.4 == 0xFF0000FFL && d.2 == 390.0 })
  guard red is [page, ..] else { fail("no page drawn") }
  // (from the page's top to the shell's foot bar)
  assert_true((h - (844.0 - 34.0 - page.1)).abs() < 0.01, msg="viewport \{h}, page from \{page.1}, all " + ports.map(fn(p) { p.to_string() }).join(" ") + " rects " + r.t.drawn_rects().map(fn(d) { "\{d.0},\{d.1},\{d.2},\{d.3}" }).join(" "))
  assert_true(page.1 > 60.0)
}

///|
/// The agent's line's words and 接管's (each as drawn: its top, its height), with an agent driving the tab, `w` wide at
/// the system's size of words `scale`.
fn farview_agent_line(w : Double, scale : Double) -> ((Double, Double), (Double, Double), Array[String]) raise {
  let r = farview_rig(screen="browser:fv_agent_\{w}_\{scale}", w~, font_scale=scale)
  let (_, tell) = r.views[0]
  farview_live(tell)
  r.t.run_for(farview_drawn_ms)
  farview_feed(tell, FarviewHost::new().reset())
  farview_feed(tell, @proto.encode_host(AgentOn(true)))
  r.t.run_for(farview_drawn_ms)
  let words = r.t.words()
  let said = @sf.t("web-pages.chat.screenAgent")
  let take = @sf.t("android-misc.screen.takeOver")
  guard words.iter().find_first(fn(x) { x.0 == said }) is Some(a) else { fail("no agent line") }
  guard words.iter().find_first(fn(x) { x.0 == take }) is Some(b) else { fail("no 接管") }
  ((a.2, a.4), (b.2, b.4), r.t.audit())
}

///|
// 接管 beside the agent's line, its middle on that line's, the words on one line (cut short where a narrow pane at the
// system's largest words leaves them less, never wrapped beside it) at a phone's width, wide, and at the system's
// words set larger; every rule the audit holds kept.
test "a Farview tab: 接管 on the agent's line's middle, its words on one line, at the system's size of words" {
  for c in [(320.0, 1.0), (390.0, 1.0), (390.0, 1.3), (1200.0, 1.0), (200.0, 2.0)] {
    let (w, scale) = c
    let ((at, ah), (bt, bh), faults) = farview_agent_line(w, scale)
    let line = @ui.sp_at(scale, @sf.ui_theme().text_size(Body).1)
    assert_eq(faults, [], msg="\{w} at \{scale}: " + faults.join(" / "))
    // (its words' middle on the first line's middle)
    assert_true((bt + bh / 2.0 - (at + line / 2.0)).abs() < 1.0, msg="\{w} at \{scale}: words from \{at}, 接管 \{bt}+\{bh}")
    assert_true(ah < line * 1.5, msg="one line at \{w}: \{ah}")
  }
}

///|
/// A page of a real tab's size (still.fail's Screen page on a phone, 2026-11-15: 611-660 nodes laid out): a bar of
/// links over a side list and a list of `cards` cards that scrolls, each a title, a badge (id `b<i>`), a line under it,
/// its time and a button.
fn farview_real_html(cards : Int) -> String {
  let out = StringBuilder()
  out.write_string("<!doctype html><html><head><link rel=stylesheet href=s.css></head><body><div class=top>")
  for i in 0..<6 {
    out.write_string("<a class=nav href=#\{i}>Section \{i}</a>")
  }
  out.write_string("</div><div class=main><div class=side>")
  for i in 0..<8 {
    out.write_string("<div class=item><span class=dot></span><span>Folder \{i}</span></div>")
  }
  out.write_string("</div><div id=list class=list>")
  for i in 0..<cards {
    out.write_string(
      "<div class=card><div class=head><span class=title>Card title \{i}</span>" +
      "<span id=b\{i} class=badge>\{i % 9}</span></div><p class=sub>Subtitle line of card \{i}, a few words</p>" +
      "<div class=foot><span class=meta>\{i} min ago</span><button class=btn>Open</button></div></div>",
    )
  }
  out.write_string("</div></div></body></html>")
  out.to_string()
}

///|
let farview_real_css : String = "body { margin: 0; font: 14px sans-serif } " +
  ".top { display: flex; gap: 8px; padding: 8px; background: rgb(240, 240, 245) } .nav { color: rgb(20, 60, 200) } " +
  ".main { display: flex; height: 760px } .side { width: 90px; padding: 4px; background: rgb(250, 250, 250) } " +
  ".item { display: flex; gap: 4px; padding: 4px 0 } .dot { width: 8px; height: 8px; border-radius: 4px; background: rgb(0, 160, 90) } " +
  ".list { flex: 1; overflow: auto } " +
  ".card { margin: 6px; padding: 8px; border-radius: 8px; background: rgb(255, 255, 255); border: 1px solid rgb(220, 220, 225) } " +
  ".head { display: flex; justify-content: space-between } .title { font-weight: bold } " +
  ".badge { padding: 0 6px; border-radius: 8px; background: rgb(230, 60, 60); color: rgb(255, 255, 255) } " +
  ".sub { margin: 4px 0; color: rgb(110, 110, 120) } .foot { display: flex; justify-content: space-between } " +
  ".btn { border-radius: 6px; background: rgb(20, 60, 200); color: rgb(255, 255, 255); border: 0; padding: 2px 8px }"

///|
/// What the frames drawn since `Tester::tree_frames_from_now` did, all told: made, let go, laid out, measured, bindings.
fn farview_frames_did(r : FarviewRig) -> (Int, Int, Int, Int, Int) {
  r.t
  .tree_frames()
  .fold(init=(0, 0, 0, 0, 0), fn(a, f) { (a.0 + f.made, a.1 + f.let_go, a.2 + f.laid, a.3 + f.measured, a.4 + f.bindings) })
}

///|
// A page of a real tab's size (30 cards: 680 nodes laid out, as still.fail's Screen page on a phone laid 611-660,
// 2026-11-15), then what its host sends as it changes: what the tab makes, lets go, lays out, measures and binds held
// to what the change is, and the page laid out (fvclient's own styling, layout and painting, which no count of the
// tree's sees: `@stage.phase_mark`) once a moment, in the frame, however many messages came in it. Its ui_hang
// (build 9298 on: 24 freezes of 0.3-3.2 s in 7.5 min, all of them `tree structures` and `core progress farview.view`)
// was messages coming several at once, each laying out the whole page as it came: 15 at one moment were 15 layouts of
// the page in the messages before the frame.
test "a Farview tab of a real page's size: a change makes and lays out what it changed, the page laid out once a moment" {
  let layouts = Ref(0)
  @stage.phase_mark.val = fn(p) { if p == "start" { layouts.val += 1 } }
  let r = farview_rig(screen="browser:fv_real")
  let (_, tell) = r.views[0]
  farview_live(tell)
  r.t.run_for(farview_drawn_ms)
  let host = FarviewHost::new(html=farview_real_html(30), css=farview_real_css)
  // the page whole: made once, laid out once
  layouts.val = 0
  r.t.tree_frames_from_now()
  farview_feed(tell, host.reset())
  assert_eq(layouts.val, 0, msg="laid out in the messages")
  r.t.run_for(farview_drawn_ms)
  let (made, let_go, laid, measured, bindings) = farview_frames_did(r)
  assert_eq(layouts.val, 1)
  // (laid 686: the address the place's capsule, @sf.address_field_node's, as the web service's: its room and its
  // capsule round the words, 2026-11-18)
  assert_true(made <= 657 && let_go == 0 && laid <= 686 && measured <= 1 && bindings <= 1471, msg="whole: made \{made} let go \{let_go} laid \{laid} measured \{measured} bindings \{bindings}")
  assert_true(laid >= 550, msg="not a real page's size: laid \{laid}")
  // one badge's words: that word's node made again, nothing measured
  layouts.val = 0
  r.t.tree_frames_from_now()
  host.find("b3").children[0].data = "77"
  farview_feed(tell, host.patch())
  r.t.run_for(farview_drawn_ms)
  let (made, let_go, laid, measured, bindings) = farview_frames_did(r)
  assert_eq(layouts.val, 1)
  assert_true(made <= 1 && let_go <= 1 && laid <= 16 && measured == 0 && bindings <= 9, msg="a badge's words: made \{made} let go \{let_go} laid \{laid} measured \{measured} bindings \{bindings}")
  // one badge's ground: its box made again; the badges after it of the same look keyed by the how-many-th such each
  // take the place of the one before (scene.mbt's keys: one a card, 40 laid at 30 cards, 60 at 50)
  layouts.val = 0
  r.t.tree_frames_from_now()
  host.find("b4").attrs.push({ prefix: "", name: "style", value: "background: rgb(0, 0, 255)", ns: "" })
  farview_feed(tell, host.patch())
  r.t.run_for(farview_drawn_ms)
  let (made, let_go, laid, measured, bindings) = farview_frames_did(r)
  assert_eq(layouts.val, 1)
  assert_true(made <= 1 && let_go <= 1 && laid <= 40 && measured == 0 && bindings <= 78, msg="a badge's ground: made \{made} let go \{let_go} laid \{laid} measured \{measured} bindings \{bindings}")
  // 15 changes at one moment, each a message of its own: none laid out as it comes, the page laid out once in the
  // frame, each changed word's node made again
  layouts.val = 0
  r.t.tree_frames_from_now()
  for k in 0..<15 {
    host.find("b\{k + 5}").children[0].data = "x\{k}"
    farview_feed(tell, host.patch())
  }
  assert_eq(layouts.val, 0, msg="laid out in the messages")
  r.t.run_for(farview_drawn_ms)
  let (made, let_go, laid, measured, bindings) = farview_frames_did(r)
  assert_eq(layouts.val, 1)
  assert_true(made <= 15 && let_go <= 15 && laid <= 44 && measured == 0 && bindings <= 95, msg="15 at once: made \{made} let go \{let_go} laid \{laid} measured \{measured} bindings \{bindings}")
  assert_true(r.t.words().any(fn(w) { w.0 == "x14" }))
  @stage.phase_mark.val = fn(_) {  }
}

///|
/// The bar's button said `label` (its key's words), its middle and whether it is disabled.
fn farview_button(t : @ui.Tester, key : String) -> ((Double, Double), Bool) raise {
  for n in t.semantics() {
    if n.label == @sf.t(key) && !n.hidden {
      let (x, y, w, h) = n.rect
      return ((x + w / 2.0, y + h / 2.0), n.disabled)
    }
  }
  fail("no \{key}")
}

///|
// ← and → as the host says the tab can go back and forward (Meta): disabled, faded and taking no press while it has
// nothing that way; pressed, each said to the host; every rule the audit holds kept either way.
test "a Farview tab: ← and → pressed only where the host says the tab can go back and forward" {
  let r = farview_rig(screen="browser:fv_nav")
  let (_, tell) = r.views[0]
  farview_live(tell)
  farview_feed(tell, FarviewHost::new().reset())
  r.t.run_for(farview_drawn_ms)
  let navs = fn() {
    farview_said(r.sent).filter_map(fn(m) {
      if m is Nav(k, _) && (k == @proto.NAV_BACK || k == @proto.NAV_FORWARD) { Some(k) } else { None }
    })
  }
  let press_both = fn() raise {
    for key in ["web-pages.screen.back", "web-pages.screen.forward"] {
      let ((x, y), _) = farview_button(r.t, key)
      r.t.tap(x, y)
      r.t.run_for(farview_drawn_ms)
    }
  }
  assert_eq(farview_button(r.t, "web-pages.screen.back").1, true)
  assert_eq(farview_button(r.t, "web-pages.screen.forward").1, true)
  press_both()
  assert_eq(navs(), [])
  assert_eq(r.t.audit(), [])
  // gone somewhere: back now
  farview_feed(tell, @proto.encode_host(Meta("https://example.test/b", "B", false, true, false)))
  r.t.run_for(farview_drawn_ms)
  assert_eq(farview_button(r.t, "web-pages.screen.back").1, false)
  assert_eq(farview_button(r.t, "web-pages.screen.forward").1, true)
  press_both()
  assert_eq(navs(), [@proto.NAV_BACK])
  assert_eq(r.t.audit(), [])
  // back at the first: forward now, not back
  farview_feed(tell, @proto.encode_host(Meta("https://example.test/", "Example", false, false, true)))
  r.t.run_for(farview_drawn_ms)
  press_both()
  assert_eq(navs(), [@proto.NAV_BACK, @proto.NAV_FORWARD])
  assert_eq(r.t.audit(), [])
}
