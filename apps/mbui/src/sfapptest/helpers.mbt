// Shared blackbox test helpers for test packages outside `stillfail/sfapp` (such as `stillfail/sfapp_pages_test`).

///|
/// A screen a cell walks on: its name, the window's size and the input it was started with (`platform`, as @ui's).
pub(all) struct Screen {
  name : String
  w : Double
  h : Double
  platform : Int
}

///|
pub let daily_small : Screen = { name: "小屏", w: 390.0, h: 844.0, platform: 2 }

///|
pub let daily_medium : Screen = { name: "中屏", w: 864.0, h: 954.0, platform: 2 }

///|
pub let daily_large : Screen = { name: "大屏", w: 1280.0, h: 800.0, platform: 0 }

///|
pub let corner_windows : Array[(String, Double, Double, Int, String)] = [
  ("phone", 360.0, 740.0, 2, ""),
  ("touch", 600.0, 900.0, 2, "medium"),
  ("desk", 600.0, 760.0, 0, ""),
  ("desk-win", 600.0, 760.0, 3, ""),
  ("tablet", 840.0, 900.0, 2, "expanded"),
  ("wide", 1280.0, 800.0, 0, ""),
  ("wide-win", 1280.0, 800.0, 3, ""),
]

///|
pub let squeeze_windows : Array[String] = ["desk", "touch", "tablet", "phone"]

///|
pub let words_large_scale : Double = 1.3

///|
pub let place_core_soon_ms : Double = 40.0

///|
pub let left_alone_ms : Double = 10000.0

///|
pub let between_frames_ms : Double = 10.0

///|
pub let tap_step_ms : Double = 5.0

///|
pub fn named(calls : Array[Made], name : String) -> Array[Made] {
  calls.filter(fn(m) { m.name == name })
}

///|
pub fn sheet_rested(t : @ui.Tester, key : String) -> Unit {
  t.draw()
  let e = if key == "sf-present" { @sf.presented_rest() } else { -1.0 }
  if e > t.time() && e < 1.0e300 {
    t.run_for(e - t.time())
  }
}

///|
pub fn nav_rested(t : @ui.Tester) -> Unit {
  t.draw()
  let e = @ui.nav_rest()
  if e > t.time() && e < 1.0e300 {
    t.run_for(e - t.time())
  }
}

///|
pub fn presented_rested(t : @ui.Tester) -> Unit {
  t.draw()
  let e = @sf.presented_rest()
  if e > t.time() && e < 1.0e300 {
    t.run_for(e - t.time())
  }
}

///|
pub fn said(seq : Int, words : String) -> Json {
  {
    "seq": Json::number(seq.to_double()),
    "thread": 1,
    "ts": Json::string("t\{seq}"),
    "authorKind": "person",
    "author": "林",
    "text": Json::string(words),
  }
}

///|
pub fn says(t : @ui.Tester, words : String) -> Bool {
  t.words().any(fn(w) { w.0.contains(words) })
}

///|
pub fn runs(t : @ui.Tester) -> String {
  "\{Repr(t.text_runs().map(fn(r) { r.text }))} \{Repr(t.words().filter(fn(w) { w.5 > 0.5 }).map(fn(w) { w.0 }))}"
}

///|
pub fn shows(t : @ui.Tester, words : String) -> Bool {
  t.text_runs().iter().any(fn(r) { r.text == words }) || t.words().iter().any(fn(w) { w.0 == words && w.5 > 0.5 })
}

///|
pub fn pressed(t : @ui.Tester, role : @ui.Role, label : String) -> Unit {
  let found = t.all(role, label~)
  if found.length() != 1 {
    @halt.saying("pressed: expected 1 \{Repr(role)} labeled \{label}, got \{found.length()}:\n\{t.semantics_dump()}")
  }
  let (x, y, w, h) = found[0].rect
  let at = t.time() + tap_step_ms
  t.advance(tap_step_ms)
  t.touch_raw(0, 9, x + w / 2.0, y + h / 2.0, at)
  t.advance(tap_step_ms)
  t.touch_raw(2, 9, x + w / 2.0, y + h / 2.0, at + tap_step_ms)
  t.frames_owed()
}

///|
pub fn side_now(r : @sfbase.ChatRef) -> (Array[String], String) {
  match @sfbase.link_src.val {
    Some(src) => @sfdesk.side_now(src, r)
    None => ([], "")
  }
}

///|
pub fn side_change(r : @sfbase.ChatRef, action : String, tab : String?) -> Unit {
  match @sfbase.link_src.val {
    Some(src) => @sfdesk.side_change(src, r, action, tab)
    None => ()
  }
}

///|
pub fn open_share(t : @ui.Tester) -> Unit {
  match t.query(MenuItem, label="分享") {
    Some(n) => {
      let (x, y, w, h) = n.rect
      t.tap(x + w / 2.0, y + h / 2.0)
    }
    None => t.tap_text("分享")
  }
  t.frame()
  let rest = @sf.presented_rest()
  t.run_for(if rest > t.time() && rest < 1.0e12 { rest - t.time() } else { @ui.move_most_ms })
}

///|
pub fn list_up_to_top(t : @ui.Tester) -> Unit {
  let c = t.ctx()
  t.wheel(150.0, c.height / 2.0, -4000.0)
  t.run_for(@ui.move_most_ms)
}

///|
pub fn scroll_to_words(t : @ui.Tester, words : String) -> Unit {
  t.move_to(195.0, 400.0)
  for _ in 0..<8 {
    if t.find(words) is Some(_) {
      break
    }
    t.wheel(195.0, 400.0, -300.0)
  }
}

///|
pub fn out_of_sight(t : @ui.Tester) -> Unit {
  t.back()
  t.run_for(@ui.move_most_ms)
  @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.run_for(@ui.move_most_ms)
  t.run_for(@sfpages.reveal_ms)
}

///|
pub fn bring(at : Double) -> Unit {
  match @ui.view_tree() {
    Some(tree) => tree.bring_to(at)
    None => ()
  }
}

///|
pub fn lease_ended(sent : Array[String], id : Int) -> Int {
  sent.filter(fn(s) {
    let message = try Some(@json.parse(s)) catch { _ => None }
    @sfbase.flag(message, "unsubscribe") && @sfbase.number(message, "id") == id.to_double()
  }).length()
}

///|
pub fn contrast_wrong(at : String, faults : Array[String]) -> String? {
  guard faults.length() > 0 else { None }
  Some(
    "\{at}: \{faults.length()} drawn too faint to be read or seen on what they lie on (words and icons in the theme's " +
    "inks, what has nothing in it in its line; mbui ui/contrast.mbt)\n  " +
    faults.join("\n  "),
  )
}

///|
pub fn words_over(t : @ui.Tester, start : Double, upto : Double, words : Array[String]) -> Array[(Double, Array[String])] {
  let out : Array[(Double, Array[String])] = []
  while t.time() - start < upto {
    t.run_for(@ui.frame_period_default)
    out.push((t.time() - start, words.filter(fn(w) { t.find(w) is Some(_) })))
  }
  out
}

///|
pub fn words_whole(t : @ui.Tester, name : String, sheet : (Double, Double, Double, Double)) -> (Double, Double, Double, Double)? {
  let (sx, sy, sw, sh) = sheet
  t
  .text_runs()
  .iter()
  .find_first(fn(r) { r.text == name && r.top >= sy && r.bottom <= sy + sh + 0.5 && r.x0 >= sx && r.x1 <= sx + sw + 0.5 })
  .map(fn(r) { (r.x0, r.top, r.x1 - r.x0, r.bottom - r.top) })
}

///|
pub fn walk_to_image(t : @ui.Tester, name : String) -> Unit {
  let found = fn() { t.locate("img:" + name).length() > 0 }
  let mut tries = 0
  while !found() && tries < 12 {
    let (first, _) = t.visible()
    t.scroll_to(if first > 0 { first - 1 } else { 0 })
    t.draw()
    tries += 1
    if found() {
      break
    }
    let (top, last) = t.visible()
    for k = top + 1; k <= last && !found(); k = k + 1 {
      t.scroll_to(k)
      t.draw()
    }
    if !found() {
      t.scroll_to(top)
      t.draw()
    }
  }
}

///|
pub fn say_room(t : @ui.Tester, width : String, height : String) -> Unit {
  t.post(@hostapi.system_channel, "{\"size_class\":{\"width\":\"\{width}\",\"height\":\"\{height}\"}}")
}

///|
pub fn corner_cover(a : Array[Double], px : Double, py : Double, scale : Double) -> Double {
  let cover = fn(d : Double) { @cmp.maximum(0.0, @cmp.minimum(1.0, 0.5 - d * scale)) }
  let ax : Double = a[0]
  let ay : Double = a[1]
  let aw : Double = a[2]
  let ah : Double = a[3]
  let ar : Double = a[4]
  let own = cover(@ui.sd_box(px - (ax + aw / 2.0), py - (ay + ah / 2.0), aw / 2.0, ah / 2.0, ar))
  let cut = fn(k : Int) {
    cover(
      @ui.sd_clip(
        px,
        py,
        a[k],
        a[k + 1],
        a[k + 2],
        a[k + 3],
        (a[k + 4], a[k + 5], a[k + 6], a[k + 7]),
        (a[k + 8], a[k + 9], a[k + 10], a[k + 11]),
      ),
    )
  }
  let clip = fn() {
    cover(
      @ui.sd_clip(
        px,
        py,
        a[16],
        a[17],
        a[18],
        a[19],
        (a[24], a[25], a[26], a[27]),
        (a[28], a[29], a[30], a[31]),
      ),
    )
  }
  let outer = if @cmp.maximum(@cmp.maximum(a[44], a[45]), @cmp.maximum(a[46], a[47])) > 0.0 { cut(40) } else { 1.0 }
  own * clip() * outer
}

///|
pub let decide_src : Ref[@sfbase.Source?] = Ref(None)

///|
#callsite(autofill(loc))
pub fn decide_core(
  calls : Array[Made],
  mode : String,
  wide? : Bool = false,
  pointing? : @ui.Pointing,
  loc~ : SourceLoc,
) -> @ui.Tester {
  @sfapp.new_run()
  let base = @sffixture.fixture(mode)
  let src : @sfbase.Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      if name == "history.tool" {
        (base.call)(name, params, done)
      } else {
        done(Ok(Json::object({})))
      }
    },
  }
  decide_src.val = Some(src)
  @sfapp.open_fixture_over(mode, src)
  let t = if wide {
    @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w=1280.0, h=800.0, platform=0, pointing?, loc~)
  } else {
    @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w=390.0, h=844.0, platform=2, loc~)
  }
  t.run_for(@ui.move_most_ms)
  t
}

///|
#callsite(autofill(loc))
pub fn cards_core(
  calls : Array[Made],
  mode? : String = "chat",
  platform? : Int = 2,
  op? : ((Array[String]) -> (Int, String, String))? = None,
  op_pending? : Bool = false,
  autofill? : Bool = false,
  loc~ : SourceLoc,
) -> @ui.Tester {
  @sfapp.new_run()
  let base = @sffixture.fixture(mode)
  let src : @sfbase.Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  @sfapp.open_cards_fixture(mode)
  // a host's password manager is fixed when it starts: set as the run begins, before the cards are made, not after
  let t = @ui.Tester::new(
    fn(c) { @sfapp.view(c, src) },
    tree=@sfapp.app_tree(src),
    w=390.0,
    h=844.0,
    platform~,
    begun=fn() { if autofill { @ui.fake_autofill.val = true } },
    loc~,
  )
  t.run_for(@ui.move_most_ms)
  // (a password manager here, or the host's own filling: the host's from the start, as on a device; the Tester's host
  // given it once made, the chat opened again to be made with it)
  if op is Some(_) || autofill {
    @ui.fake_op.val = op
    @ui.fake_op_pending.val = op_pending
    @ui.fake_autofill.val = autofill
    t.back()
    t.run_for(@ui.move_most_ms)
    @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
#callsite(autofill(loc))
pub fn settings_tester(
  page : String,
  mode? : String = "settings",
  shows? : String = "",
  platform? : Int = 0,
  w? : Double = 390.0,
  h? : Double = 844.0,
  loc~ : SourceLoc,
) -> @ui.Tester {
  @sfapp.new_run()
  if shows != "" {
    @settings.fixture_page(shows) |> ignore
  }
  let src = @sffixture.fixture(mode)
  let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w~, h~, platform~, loc~)
  @sfbase.open_setting(page)
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
#callsite(autofill(loc))
pub fn drive_tester(mode : String, loc~ : SourceLoc) -> @ui.Tester {
  @sfapp.new_run()
  let src = @sffixture.fixture(mode)
  @sfapp.open_drive_fixture(mode)
  let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w=390.0, h=844.0, platform=2, loc~)
  nav_rested(t)
  t
}

///|
#callsite(autofill(loc))
pub fn chat_tester(mode : String, w? : Double = 390.0, loc~ : SourceLoc) -> @ui.Tester {
  @sfapp.new_run()
  let src = @sffixture.fixture(mode)
  @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w~, h=844.0, platform=2, loc~)
  t.run_for(@ui.move_most_ms)
  t
}

///|
#callsite(autofill(loc))
pub fn fake_core(
  calls : Array[Made],
  kept? : Json = Json::null(),
  read_only? : Bool = false,
  now? : Double = 0.0,
  over? : (String, @sfbase.Topic) -> @sfbase.Topic = fn(_, t) { t },
  made? : Ref[@sfbase.Source?] = Ref(None),
  ups? : Map[String, Json] = Map([]),
  platform? : Int = 2,
  on_call? : (String, Json) -> Unit = fn(_, _) {  },
  loc~ : SourceLoc,
) -> @ui.Tester {
  @sfapp.new_run()
  let drafts_named = Ref(0)
  let base = @sffixture.fixture("chat")
  let src : @sfbase.Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      on_call(name, params)
      match name {
        "draft.get" => done(Ok(kept))
        "draft.put" => {
          let blank = @sfbase.text(Some(params), "text") == "" &&
            (match @sfbase.field(Some(params), "files") {
              Some(Array(fs)) => fs.length() == 0
              _ => true
            })
          if blank {
            drafts_named.val += 1
          }
          done(Ok({ "id": Json::string("draft-\{drafts_named.val}") }))
        }
        "session.warm" | "client.focus" | "chat.place" => done(Ok(Json::object({})))
        "link.parse" => done(Ok(@sffixture.fixture_link_parse(@sfbase.text(Some(params), "url"))))
        "ref.at" | "ref.before" | "ref.marks" | "ref.words" | "ref.styles" | "ref.enter" | "ref.pasted" | "paste.info" => (base.call)(name, params, done)
        _ if name.has_prefix("composer.") => (base.call)(name, params, done)
        _ => ()
      }
    },
    call_bytes: fn(name, params, bytes, done) {
      calls.push({ name, params, bytes: Some(bytes), done })
      (base.call_bytes)(name, params, bytes, done)
    },
    stream: fn(name, params, bytes, on_value, done) {
      if name != "station.upload.part" {
        return (base.stream)(name, params, bytes, on_value, done)
      }
      calls.push({ name, params, bytes, done })
      0
    },
    topic_read: fn(name, params) {
      ignore(ups)
      over(name, base.topic(name, params).get().snapshot())
    },
    now: fn() { now },
    read_only,
  }
  made.val = Some(src)
  @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w=390.0, h=844.0, platform~, loc~)
  t.run_for(@ui.move_most_ms)
  t
}
