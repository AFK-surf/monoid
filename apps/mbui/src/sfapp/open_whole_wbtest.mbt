// A card, a panel or a sheet opened the first time, and a station's page opened by a press, over a core that answers
// what they read of the device a moment late (MBUI_OPEN_WHOLE: @sf.OpenGate, sfbase's Source::topic and
// route_open_asks): nothing of it seen till what it shows is answered, then it comes in whole from there; one that waits
// on a station comes in at once, showing that it waits; one the core is slow on comes in as it is open_hold_ms after
// it opened. Before it (a fixture's source, gates_opens off), each came in at once on what it had.

///|
/// How late the made-up core answers what the card, the panel or the sheet reads (each within open_hold_ms).
let open_late_ms : Double = 40.0

///|
/// What a probe panel reads (the fixture's station Willow whole) and shows of it.
let probe_topic : String = "station"

///|
fn probe_params() -> Map[String, Json] {
  { "scope": Json::string("ws1"), "station": Json::string("ws1/st1") }
}

///|
/// The probe panel's title, and what it shows once what it reads is answered (its summary).
let probe_title : String = "核对面板"

///|
let probe_whole : String = "概要：Apple M1 Pro · 2 个 agent 在工作"

///|
/// Whether `words` is seen on `t`'s screen, `h` tall: drawn not clear, within the window.
fn open_seen(t : @ui.Tester, words : String, h : Double) -> Bool {
  t.words().iter().any(fn(w) { w.0 == words && w.5 > 0.01 && w.2 < h && w.2 + w.4 > 0.0 })
}

///|
/// A window (`wide`: a Mac's 1280 × 800, else a phone's 390 × 844) at rest over the settings' fixture answered through
/// the app's client, the probe's topic `late` ms late (none: never), each else at once; `gates`: as the app has it since
/// MBUI_OPEN_WHOLE; `waits`: the core saying the probe's topic waits on a station meanwhile.
fn open_whole_tester(wide : Bool, late : Double?, gates~ : Bool, waits? : Bool = false) -> (@ui.Tester, Source, Double) {
  new_run()
  let base = fixture("settings")
  let answered = @signals.signal(false)
  let src : Source = match late {
    Some(ms) =>
      {
        ..round_trip_again(base, 0.0, late=fn(name, _) { if name == probe_topic { ms } else { 0.0 } }),
        gates_opens: fn() { gates },
      }
    None =>
      {
        ..base,
        topic_read: fn(name, params) {
          if name == probe_topic && !answered.get() {
            { value: None, error: None, version: 0 }
          } else {
            base.topic(name, params).get().snapshot()
          }
        },
        waits: fn(name, params) { (name == probe_topic && waits && !answered.get()) || (base.waits)(name, params) },
        gates_opens: fn() { gates },
      }
  }
  let (w, h) = if wide { (1280.0, 800.0) } else { (390.0, 844.0) }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  (t, src, h)
}

///|
/// The probe panel opened now from `from`: its title, and what it reads shown once it is answered.
fn probe_open(t : @ui.Tester, src : Source, from : @sf.Anchor) -> Unit {
  @ui.view_tree().unwrap().event(t.time(), fn() {
    @sf.panel_nodes(probe_title, fn(v, _close) {
      // (read as a panel's body reads: by a source of its own, let go with it)
      let src = src.owned_by(v)
      let card = fn() { src.topic(probe_topic, probe_params()).get().value }
      @sf.words_node(v, fn() { if card() is Some(_) { "概要：" + text(card(), "summary") } else { "" } }, fn() { @sf.ask_title }) |> ignore
      @sf.words_node(v, fn() { text(card(), "summary") }, fn() { @sf.ask_note }) |> ignore
    }, from~)
  })
}

///|
/// From now till `ms` on, each display's frame: whether `words` was seen in any, or on its way (drawn not clear where
/// it was not as first drawn: a sheet rising from under the window's foot), and whether, in the first it was so in,
/// `whole` was drawn with it.
fn open_frames(t : @ui.Tester, h : Double, words : String, whole : String, ms : Double) -> (Bool, Bool) {
  let till = t.time() + ms
  let mut seen = false
  let mut first_whole = false
  let mut first_y : Double? = None
  while t.time() < till {
    t.run_for(@ui.frame_period_default)
    let y = t.words().iter().find_first(fn(w) { w.0 == words && w.5 > 0.01 }).map(fn(w) { w.2 })
    if first_y is None {
      first_y = y
    }
    let going = y is Some(now) && first_y is Some(was) && (now - was).abs() > 0.5
    if !seen && (going || open_seen(t, words, h)) {
      seen = true
      // (in it, whether yet in the window or not: a sheet rises from under the window's foot)
      first_whole = t.words().iter().any(fn(w) { w.0 == whole && w.5 > 0.01 })
    }
  }
  (seen, first_whole)
}

///|
/// Where each kind of panel opens: beside what opened it (大屏, a popover), in the window's middle (大屏, a dialog), from
/// the window's foot (小屏, a sheet).
fn open_kinds() -> Array[(String, Bool, @sf.Anchor)] {
  [("popover", true, At(600.0, 300.0, 40.0, 30.0)), ("dialog", true, Unanchored), ("sheet", false, Unanchored)]
}

///|
test "a panel opened the first time over a core 40 ms late: nothing of it seen till what it reads is answered, then whole from its first frame; before MBUI_OPEN_WHOLE, seen at once on its bones" {
  for kind in open_kinds() {
    let (name, wide, from) = kind
    for gates in [false, true] {
      let at = "\{name}, gates \{gates}"
      let (t, src, h) = open_whole_tester(wide, Some(open_late_ms), gates~)
      probe_open(t, src, from)
      // (till the core answers: with the gate nothing of it)
      let (early, _) = open_frames(t, h, probe_title, probe_whole, open_late_ms - @ui.frame_period_default)
      let (late, late_whole) = open_frames(t, h, probe_title, probe_whole, @ui.move_most_ms)
      if gates {
        assert_false(early, msg="\{at}: seen before the core answered")
        // (from the answer on: seen, whole in the first frame it is seen in)
        assert_true(late && late_whole, msg="\{at}: whole in its first frame (\{late}, \{late_whole})")
      } else {
        // (before it: seen first with nothing of what it reads, its title over nothing, grown as that came)
        assert_true(early || (late && !late_whole), msg="\{at}: seen first on its bones (\{early}, \{late}, \{late_whole})")
      }
      t.run_for(@ui.move_most_ms)
      assert_true(open_seen(t, probe_title, h) && open_seen(t, probe_whole, h), msg="\{at}: open, whole, at rest")
      assert_eq(t.bones_drawn(), 0, msg="\{at}")
      // (every rule at rest; a dialog's close button stands a point over the probe's bare words, which no panel of the
      // app's holds so: not judged there)
      if name != "dialog" {
        // (the sidebar's edge lies half over the pane on purpose, the frame's: not this page's)
        assert_eq(t.audit().filter(fn(f) { !f.contains("stillfail/src/sf/edge_node.mbt") }), [], msg=at)
      }
    }
  }
}

///|
test "a panel whose topic waits on a station comes in at once, showing that it waits; one the core is slow on comes in as it is open_hold_ms after it opened" {
  for kind in open_kinds() {
    let (name, wide, from) = kind
    // (said to wait on a station: in at once, as without the gate)
    let (t, src, h) = open_whole_tester(wide, None, gates=true, waits=true)
    probe_open(t, src, from)
    t.run_for(@ui.move_most_ms)
    assert_true(open_seen(t, probe_title, h), msg="\{name}: waiting on a station, in at once")
    assert_false(open_seen(t, probe_whole, h), msg="\{name}: nothing answered")
    // (never answered, waiting on nothing: held open_hold_ms, then in as it is)
    let (t, src, h) = open_whole_tester(wide, None, gates=true)
    probe_open(t, src, from)
    let (early, _) = open_frames(t, h, probe_title, probe_whole, @sf.open_hold_ms - @ui.frame_period_default)
    assert_false(early, msg="\{name}: seen before open_hold_ms")
    t.run_for(@ui.move_most_ms + @ui.frame_period_default)
    assert_true(open_seen(t, probe_title, h), msg="\{name}: in once open_hold_ms has gone by")
  }
}

///|
test "a panel closed while it waits goes as it is, nothing of it seen, nothing left due; opened again over what the core said, at once" {
  let (t, src, h) = open_whole_tester(true, Some(open_late_ms), gates=true)
  probe_open(t, src, At(600.0, 300.0, 40.0, 30.0))
  t.run_for(@ui.frame_period_default)
  t.key(@ui.key_escape)
  let (seen, _) = open_frames(t, h, probe_title, probe_whole, @sf.open_hold_ms + @ui.move_most_ms)
  assert_false(seen, msg="closed while it waited: never seen")
  t.assert_idle()
  probe_open(t, src, At(600.0, 300.0, 40.0, 30.0))
  t.run_for(@ui.move_most_ms)
  assert_true(open_seen(t, probe_whole, h), msg="opened again: whole")
}

///|
/// The agent's card of fixture `chat-agent-card`, its own view (`agentCard`) answered `open_late_ms` late, opened over its
/// latest message's name on a Mac's window: the Tester, and when it opened.
fn open_agent_card(gates : Bool) -> @ui.Tester {
  new_run()
  let base = fixture("chat-agent-card")
  @sfbase.chat_page_nodes.set(true)
  let src : Source = {
    ..round_trip_again(base, 0.0, late=fn(name, _) { if name == "agentCard" { open_late_ms } else { 0.0 } }),
    gates_opens: fn() { gates },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  let last = t
    .words()
    .filter(fn(w) { w.0 == "Claude" && w.5 > 0.5 })
    .iter()
    .fold(init=None, fn(acc : (String, Double, Double, Double, Double, Double)?, w) {
      match acc {
        Some(a) if a.2 >= w.2 => acc
        _ => Some(w)
      }
    })
  guard last is Some(at) else { @halt.saying("no agent's message") }
  t.move_to(at.1 - 20.0, at.2 + at.4 / 2.0)
  // (to the moment it opens: rested on hover_open_ms)
  t.run_for(@sfpages.hover_open_ms)
  t
}

///|
test "大屏: an agent's card hovered the first time over a core 40 ms late: nothing of it till its own view is answered, then whole; before MBUI_OPEN_WHOLE, its head over nothing at once" {
  // (what its own view says, its cost; its head the chat's)
  let head = "Claude · Opus 5.5"
  let whole = "$4.20"
  for gates in [false, true] {
    let t = open_agent_card(gates)
    let (early, _) = open_frames(t, 800.0, head, whole, open_late_ms - @ui.frame_period_default)
    assert_eq(early, !gates, msg="gates \{gates}: seen before its view came")
    let (seen, first_whole) = open_frames(t, 800.0, head, whole, @ui.move_most_ms)
    if gates {
      assert_true(seen && first_whole, msg="whole in its first frame (\{seen}, \{first_whole})")
    }
    t.run_for(@ui.move_most_ms)
    assert_true(open_seen(t, head, 800.0) && open_seen(t, whole, 800.0), msg="gates \{gates}: open at rest")
  }
}


///|
/// A window (`wide` or a phone's) at rest on the stations' place over the settings' fixture answered through the app's
/// client, a station whole (`station`) `open_late_ms` late, each else at once; `gates` as open_whole_tester's. Willow's
/// page then opened as a press on its row opens it (the settings' push): from that press to rest, each display's frame,
/// the most bones any draws, and whether the page on top changed before the core answered.
fn station_open(wide : Bool, gates : Bool, late? : (String) -> Double = station_late) -> (Int, Bool, @ui.Tester) {
  new_run()
  // (小屏 over the stations' place; 大屏 over Home, the pane showing no station yet)
  if !wide {
    app.nav.replace(Place("stations"))
  }
  let src : Source = {
    ..round_trip_again(fixture("settings"), 0.0, late=fn(name, _) { late(name) }),
    reads_ahead: fn() { true },
    gates_opens: fn() { gates },
  }
  let (w, h) = if wide { (1280.0, 800.0) } else { (390.0, 844.0) }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  let before = app.nav.top()
  let ws = match @sfbase.workspace_in_view(src).0 {
    Some(w) => w
    None => @halt.saying("no workspace in view")
  }
  @ui.view_tree().unwrap().event(t.time(), fn() {
    (@sfbase.settings_core(src, ws).push)(@settings.Route::Station("ws1/st1"))
  })
  let till = t.time() + open_late_ms - @ui.frame_period_default
  let mut early = false
  let mut most = t.bones_drawn()
  while t.time() < till {
    t.run_for(@ui.frame_period_default)
    early = early || app.nav.top() != before
    most = @cmp.maximum(most, t.bones_drawn())
  }
  // (from then on, each frame: and in the first the page is on top in, whether its screens' block is in it, what the
  // overview reads after the station whole, not come in under the rest a moment later)
  let till = t.time() + @ui.move_most_ms * 2.0
  while t.time() < till {
    t.run_for(@ui.frame_period_default)
    most = @cmp.maximum(most, t.bones_drawn())
    if station_first_seen.val is None && app.nav.top() != before {
      station_first_seen.val = Some(t.find(station_screens_head) is Some(_))
    }
  }
  (most, early, t)
}

///|
/// Whether the first frame Willow's page was on top in held its screens' block (station_open's), None before it is.
let station_first_seen : Ref[Bool?] = Ref(None)

///|
fn init {
  @ui.on_reset(fn() { station_first_seen.val = None })
}

///|
/// The head of a station's overview's block of its screens, its browser and its terminals.
let station_screens_head : String = "屏幕、浏览器与终端"

///|
/// How late the made-up core answers what a station's page reads as it opens: the station whole, its screens and its
/// terminals and its resources each `open_late_ms` (the screens asked only once the station is answered: two of them
/// late in a row, within open_hold_ms), all else at once.
fn station_late(name : String) -> Double {
  if name is ("station" | "screens" | "terminals" | "resources" | "stationNet") {
    open_late_ms
  } else {
    0.0
  }
}

///|
/// The same, its screens never answered: what opens waits open_hold_ms at most.
fn station_screens_never(name : String) -> Double {
  if name == "screens" {
    station_never_ms
  } else {
    station_late(name)
  }
}

///|
/// Later than any test looks.
let station_never_ms : Double = 600000.0

///|
test "a station's page opened over a core 40 ms late: the screen as it was till the station is answered, then the page whole, no bones in any frame; before MBUI_OPEN_WHOLE, opened at once on its bones" {
  for wide in [false, true] {
    for gates in [false, true] {
      let at = "\{if wide { "大屏" } else { "小屏" }}, gates \{gates}"
      let (most, early, t) = station_open(wide, gates)
      assert_true(app.nav.top() == Setting(@settings.Route::Station("ws1/st1")), msg="\{at}: open at rest")
      if gates {
        assert_eq((most, early), (0, false), msg=at)
        // (its overview whole as it comes on top: its screens' block in it from its first frame)
        assert_eq(station_first_seen.val, Some(true), msg="\{at}: its screens there as it came on top")
      } else {
        assert_true(early && most > 0, msg="\{at}: opened at the press, on its bones (\{most})")
      }
      if gates {
        // (the sidebar's edge lies half over the pane on purpose, the frame's: not this page's)
        assert_eq(t.audit().filter(fn(f) { !f.contains("stillfail/src/sf/edge_node.mbt") }), [], msg=at)
      }
    }
  }
}

///|
test "a station's page whose screens the core never answers opens open_hold_ms after the press, not before its station is answered, and never waits on" {
  for wide in [false, true] {
    let at = if wide { "大屏" } else { "小屏" }
    let (_, early, t) = station_open(wide, true, late=station_screens_never)
    assert_false(early, msg="\{at}: opened before the station was answered")
    assert_true(app.nav.top() == Setting(@settings.Route::Station("ws1/st1")), msg="\{at}: open once open_hold_ms went by")
    assert_eq(station_first_seen.val, Some(false), msg="\{at}: its screens still to come as it opened")
    ignore(t)
  }
}
