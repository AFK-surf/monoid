// A station's screen in the viewer (screen_view.mbt, screen_stage.mbt) on a fake core, on a phone (with keyboard and
// mouse: screen_mouse_wbtest.mbt), as Android's ScreenViewerTest has it: `screen.view` held open, its states and JPEG frames said as the core would (bytes beside the
// JSON), the frames shown by the Tester's stream (stream_shows) and acknowledged; a tap a click at the right place in
// the frame, a press held a right click, a drag a drag, the trackpad's pointer moved; 只看 sends nothing. Driving it,
// the clipboard goes both ways and files picked go onto its machine.

///|
/// The fake core's side of a view: what was asked, what the call says next.
priv struct ScreenRig {
  t : @ui.Tester
  /// every call told the core: its name, its params, the bytes beside it
  calls : Array[(String, Json, Bytes?)]
  /// the `screen.view` calls open: how each says a value, how it ends
  views : Array[((Json, Bytes?) -> Unit, (Result[Json, Json]) -> Unit)]
  cancelled : Array[Int]
  /// how the fake core answers a call (None: as the fixture does)
  answer : Ref[(String, Json) -> Result[Json, Json]?]
  /// the prefs' `screenQuality`, `screenBitrate` (0: none), `screenChroma444`, `screenGamepadMouse`, `screenFps` (0: none), `screenKeyMap` / `screenKeepCtrl` ("": default on, "off": off)
  quality : @signals.Signal[String]
  bitrate : @signals.Signal[Int]
  chroma444 : @signals.Signal[Bool]
  gamepad_mouse : @signals.Signal[Bool]
  fps : @signals.Signal[Int]
  key_map : @signals.Signal[String]
  keep_ctrl : @signals.Signal[String]
}

///|
let rig_w : Double = 1280.0

///|
let rig_h : Double = 720.0

///|
fn screen_rig(
  w? : Double = 390.0,
  h? : Double = 844.0,
  dark? : Bool = false,
  touch? : String = "",
  platform? : Int = 2,
  until_gone? : Bool = false,
  screen? : String = "browser:tab-1",
  here? : String = "",
  h264? : Bool = false,
  os? : String = "",
  key_map? : String = "",
  keep_ctrl? : String = "",
  screens? : Json,
  terminals? : Json,
  in_tab? : Bool = false,
  tab_pads? : Bool = false,
  keep_screen? : Bool = false,
  net? : Json,
) -> ScreenRig {
  @sfbase.reset()
  // this machine's station, as its host says (`here`); none by default
  if here != "" {
    @sfbase.machine_here.val = Some(here)
  }
  reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sf.set_dark(Some(dark))
  // the core as this page reads it: the device's prefs, and what is told it (screen_node alone over it, no app)
  let base = @sfbase.made_source(
    topic=fn(name, _) {
      if name == "prefs" {
        Some(Json::object({}))
      } else if name == "screens" {
        screens
      } else if name == "terminals" {
        terminals
      } else if name == "stationNet" {
        // how this device reaches the station (`net`), as the core says it; none by default (null, as the core answers
        // a station it has no network for: views.ts stationNet)
        Some(net.unwrap_or(Json::null()))
      } else {
        None
      }
    },
    call=fn(_, _, done) { done(Ok(Json::null())) },
  )
  let calls : Array[(String, Json, Bytes?)] = []
  let views : Array[((Json, Bytes?) -> Unit, (Result[Json, Json]) -> Unit)] = []
  let cancelled : Array[Int] = []
  let answer : Ref[(String, Json) -> Result[Json, Json]?] = Ref(fn(_, _) { None })
  let touch_ = @signals.signal(touch)
  let quality_ = @signals.signal("")
  let bitrate_ = @signals.signal(0)
  let chroma444_ = @signals.signal(false)
  let gamepad_mouse_ = @signals.signal(false)
  let fps_ = @signals.signal(0)
  let key_map_ = @signals.signal(key_map)
  let keep_ctrl_ = @signals.signal(keep_ctrl)
  let ask = fn(name : String, params : Json, bytes : Bytes?, done : (Result[Json, Json]) -> Unit, fallback : () -> Unit) {
    calls.push((name, params, bytes))
    match (answer.val)(name, params) {
      Some(r) => done(r)
      None =>
        if name.has_prefix("screen.") || name == "drive.upload.part" {
          done(Ok(Json::null()))
        } else {
          fallback()
        }
    }
  }
  let src : Source = {
    ..base,
    asks_terminals: if terminals is Some(_) { fn() { true } } else { base.asks_terminals },
    topic_read: fn(name, params) {
      let tp = base.topic(name, params).get().snapshot()
      if name == "stations" && os != "" {
        { ..tp, value: Some([{ "station": "ws-1/st-1", "host": { "os": os } }]) }
      } else if name == "prefs" &&
        (touch_.get() != "" ||
          quality_.get() != "" ||
          bitrate_.get() != 0 ||
          chroma444_.get() ||
          gamepad_mouse_.get() ||
          fps_.get() != 0 ||
          key_map_.get() != "" ||
          keep_ctrl_.get() != "") {
        let m = match tp.value {
          Some(Object(m)) => m.copy()
          _ => {}
        }
        if touch_.get() != "" {
          m["screenTouch"] = Json::string(touch_.get())
        }
        if quality_.get() != "" {
          m["screenQuality"] = Json::string(quality_.get())
        }
        if bitrate_.get() != 0 {
          m["screenBitrate"] = Json::number(bitrate_.get().to_double())
        }
        if chroma444_.get() {
          m["screenChroma444"] = Json::boolean(true)
        }
        if gamepad_mouse_.get() {
          m["screenGamepadMouse"] = Json::boolean(true)
        }
        if fps_.get() != 0 {
          m["screenFps"] = Json::number(fps_.get().to_double())
        }
        if key_map_.get() != "" {
          m["screenKeyMap"] = Json::string(key_map_.get())
        }
        if keep_ctrl_.get() != "" {
          m["screenKeepCtrl"] = Json::string(keep_ctrl_.get())
        }
        { ..tp, value: Some(Json::object(m)) }
      } else {
        tp
      }
    },
    call: fn(name, params, done) {
      if name == "prefs.set" {
        match field(Some(params), "screenTouch") {
          Some(String(v)) => touch_.set(v)
          Some(Null) => touch_.set("")
          _ => ()
        }
        match field(Some(params), "screenQuality") {
          Some(String(v)) => quality_.set(v)
          Some(Null) => quality_.set("")
          _ => ()
        }
        match field(Some(params), "screenBitrate") {
          Some(Number(n, ..)) => bitrate_.set(n.to_int())
          Some(Null) => bitrate_.set(0)
          _ => ()
        }
        match field(Some(params), "screenChroma444") {
          Some(True) => chroma444_.set(true)
          Some(False) | Some(Null) => chroma444_.set(false)
          _ => ()
        }
        match field(Some(params), "screenGamepadMouse") {
          Some(True) => gamepad_mouse_.set(true)
          Some(False) | Some(Null) => gamepad_mouse_.set(false)
          _ => ()
        }
        match field(Some(params), "screenFps") {
          Some(Number(n, ..)) => fps_.set(n.to_int())
          Some(Null) => fps_.set(0)
          _ => ()
        }
        match field(Some(params), "screenKeyMap") {
          Some(String(v)) => key_map_.set(v)
          Some(Null) => key_map_.set("")
          _ => ()
        }
        match field(Some(params), "screenKeepCtrl") {
          Some(String(v)) => keep_ctrl_.set(v)
          Some(Null) => keep_ctrl_.set("")
          _ => ()
        }
      }
      ask(name, params, None, done, fn() { (base.call)(name, params, done) })
    },
    call_bytes: fn(name, params, bytes, done) {
      ask(name, params, Some(bytes), done, fn() { (base.call_bytes)(name, params, bytes, done) })
    },
    stream: fn(name, params, bytes, on_value, done) {
      if name != "screen.view" {
        return (base.stream)(name, params, bytes, on_value, done)
      }
      calls.push((name, params, bytes))
      views.push((on_value, done))
      views.length()
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  // the page alone, while it is the stack's top, the presenters over it; left (closed), let go of as the shell lets a
  // page go (screen_left): by a node of the window's tree for each screen on top, which lets it go as it goes
  let t = @ui.Tester::new(
    // (the old frame around the window's tree, its old view put here, in still.fail's theme, as the app's)
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.each(
        fn() {
          match app.nav.top() {
            Screen(at) => [(at.station, at.screen)]
            _ => []
          }
        },
        fn(k) { k },
        fn(row, k) {
          let (station, screen) = k.untracked()
          row.owns(fn() {
            if !keep_screen { screen_left(src, station, screen) }
          })
          |> ignore
        },
      )
      // the page as nodes, made again for another screen on top (as the shells make it)
      root.pick(at_once=true, fn() {
        match app.nav.top() {
          Screen(at) => Some(at)
          _ => None
        }
      }, fn(p, at) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        match at {
          Some(at) =>
            if tab_pads {
              screen_pane_node(
                p,
                src,
                at,
                fn() { @sf.no_frame },
                in_tab~,
                tab_pads={ start: fn() { 0.0 }, end: fn() { 0.0 }, over: fn() { 0.0 } },
              )
            } else {
              screen_node(p, src, at, fn() { @sf.no_frame }, in_tab~)
            }
          None => ()
        }
      })
      // what is presented over the page (as the app's tree has it): the presenters' old views, then what of the
      // presented the tree draws
      @ui.old(root, fn(c) { @sf.presented(c) }).over(Is(true)) |> @ui.old_takes_own |> ignore
      @sf.presented_nodes(root)
      // what the page said, as the shell shows it (sfbase's toasts_node, at the window's foot)
      @sfbase.toasts_node(root, fn() { @sf.toast_bottom }) |> ignore
    },
    w~,
    h~,
    platform~,
    h264~,
  )
  t.draw()
  app.nav.push(Screen({ station: "ws-1/st-1", screen, title: "Chrome", until_gone }))
  nav_rested(t)
  {
    t,
    calls,
    views,
    cancelled,
    answer,
    quality: quality_,
    bitrate: bitrate_,
    chroma444: chroma444_,
    gamepad_mouse: gamepad_mouse_,
    fps: fps_,
    key_map: key_map_,
    keep_ctrl: keep_ctrl_,
  }
}

///|
fn ScreenRig::sess(self : ScreenRig) -> ScreenSess {
  ignore(self)
  // (the one this rig opened, whichever screen it was asked for)
  for _, sess in screens_open {
    return sess
  }
  @halt.saying("no screen open")
}

///|
fn ScreenRig::ui(self : ScreenRig) -> ScreenUi {
  ignore(self)
  for _, ui in screen_uis {
    return ui
  }
  @halt.saying("no screen open")
}

///|
/// What it told the core, of one call: its params.
fn ScreenRig::told(self : ScreenRig, name : String) -> Array[Json] {
  self.calls.filter(fn(c) { c.0 == name }).map(fn(c) { c.1 })
}

///|
fn ScreenRig::inputs(self : ScreenRig) -> Array[Json] {
  self.told("screen.input").map(fn(p) { field(Some(p), "input").unwrap() })
}

///|
fn ScreenRig::acked(self : ScreenRig, ts : Double) -> Bool {
  self.told("screen.ack").iter().any(fn(p) { number(Some(p), "ts") == ts })
}

///|
/// A value of the last view opened, delivered as the core's messages are (between frames), then a frame.
fn ScreenRig::say(self : ScreenRig, value : Json, bytes? : Bytes) -> Unit {
  let (on_value, _) = self.views[self.views.length() - 1]
  on_value(value, bytes)
  self.t.draw()
}

///|
/// The last view's call answered (Ok: the view ended), or failed with why.
fn ScreenRig::finish(self : ScreenRig, error? : Json) -> Unit {
  let (_, done) = self.views[self.views.length() - 1]
  match error {
    Some(e) => done(Err(e))
    None => done(Ok(Json::null()))
  }
  self.t.draw()
}

///|
fn ScreenRig::state(
  self : ScreenRig,
  phase : String,
  control? : Bool = true,
  may? : Bool = true,
  others? : Array[String] = ["李雷"],
  message? : String = "",
  access? : Json,
  controllers? : Array[String],
  take_over? : Bool,
  line? : String,
  clipboard? : Array[String],
  drop? : Json,
  more? : Map[String, Json] = {},
) -> Unit {
  let m : Map[String, Json] = {
    "phase": Json::string(phase),
    "title": Json::string("still.fail — Chrome"),
    "kind": Json::string("browser"),
    "control": Json::boolean(control),
    "may": Json::boolean(may),
    "others": Json::array(others.map(Json::string)),
    "line": Json::string(
      match line {
        Some(l) => l
        None =>
          (if control { "控制" } else { "只看" }) +
          (if others.is_empty() { "" } else { " · " + others.join("、") + "也在看" })
      },
    ),
    "codec": Json::string("jpeg"),
    "width": Json::number(rig_w),
    "height": Json::number(rig_h),
  }
  if message != "" {
    m["message"] = Json::string(message)
  }
  match access {
    Some(a) => m["access"] = a
    None => ()
  }
  match controllers {
    Some(cs) => m["controllers"] = Json::array(cs.map(Json::string))
    None => ()
  }
  match take_over {
    Some(b) => m["takeOver"] = Json::boolean(b)
    None => ()
  }
  match clipboard {
    Some(cs) => m["clipboard"] = Json::array(cs.map(Json::string))
    None => ()
  }
  match drop {
    Some(d) => m["drop"] = d
    None => ()
  }
  for k, v in more {
    m[k] = v
  }
  self.say(Json::object({ "state": Json::object(m) }))
}

///|
fn ScreenRig::config(self : ScreenRig) -> Unit {
  self.say({ "config": { "codec": "jpeg", "width": rig_w, "height": rig_h } })
}

///|
/// A frame of `ts`, its JPEG beside it, shown by the device's decoder (the Tester's stream says so).
fn ScreenRig::frame(self : ScreenRig, ts : Double) -> Unit {
  self.say({ "frame": { "key": true, "ts": ts } }, bytes=b"\xFF\xD8\xFF\xE0jpeg")
  self.t.stream_shows(self.sess().stream.unwrap().id(), ts, rig_w.to_int(), rig_h.to_int())
  self.t.draw()
}

///|
/// A point of the frame (0..1 each way), in the window.
fn ScreenRig::at(self : ScreenRig, x : Double, y : Double) -> (Double, Double) {
  let u = self.ui()
  let s = u.shown(self.t.ctx())
  let (sx, sy) = u.stage_xy()
  (sx + s.x + x * s.w, sy + s.y + y * s.h)
}

///|
/// Where the frame is drawn on the stage now (ScreenUi::shown_at, at the Tester's moment `c` builds at).
fn ScreenUi::shown(self : ScreenUi, c : @ui.Ctx) -> SRect {
  self.shown_at(c.moment())
}

///|
/// Where the stage is in the window (its top left), as it is drawn.
fn ScreenUi::stage_xy(self : ScreenUi) -> (Double, Double) {
  match self.stage_node {
    Some(v) => {
      let (x, y, _, _) = v.rect()
      (x, y)
    }
    None => (0.0, 0.0)
  }
}

///|
/// The middle of what is labelled `label` for those who cannot see it (its first), if it is there.
fn ScreenRig::labelled(self : ScreenRig, label : String) -> (Double, Double)? {
  for s in self.t.semantics() {
    if s.label == label && !s.hidden {
      let (x, y, w, h) = s.rect
      return Some((x + w / 2.0, y + h / 2.0))
    }
  }
  None
}

///|
fn ScreenRig::tap_label(self : ScreenRig, label : String) -> Unit {
  match self.labelled(label) {
    Some((x, y)) => self.t.tap(x, y)
    None => @halt.saying("nothing labelled " + label)
  }
}

///|
/// Key `label` of the keys row pressed: in the row, else (the row short of room for it) the row turned to it by its
/// ⋯, then on round to its first face (Esc in it).
fn ScreenRig::press_key(self : ScreenRig, label : String) -> Unit {
  // (a key on a turned face pressed there, the row turned back round to its first, Esc in it)
  if self.labelled(label) is Some(_) {
    self.tap_label(label)
    let mut back = 0
    while self.labelled("Esc") is None && self.labelled(tr("common.more")) is Some(_) && back < 12 {
      back += 1
      self.tap_label(tr("common.more"))
    }
    return
  }
  // (the keys row shows while typing, since 2026-11-13: the keyboard raised first from the foot)
  if self.labelled("Esc") is None && self.labelled(tr("android-misc.screen.keyboard")) is Some(_) {
    self.tap_label(tr("android-misc.screen.keyboard"))
  }
  // (turned at most a few times: a key never shown says so, not a test that never ends)
  let mut turns = 0
  while self.labelled(label) is None {
    turns += 1
    if turns > 12 {
      @halt.saying("no key \"\{label}\" on the keys row")
    }
    self.tap_label(tr("common.more"))
  }
  self.tap_label(label)
  turns = 0
  while self.labelled("Esc") is None && turns < 12 {
    turns += 1
    self.tap_label(tr("common.more"))
  }
}

///|
fn ScreenRig::tap_at(self : ScreenRig, x : Double, y : Double) -> Unit {
  let (px, py) = self.at(x, y)
  self.t.tap(px, py)
}

///|
fn ScreenRig::live(self : ScreenRig, others? : Array[String] = ["李雷"], clipboard? : Array[String], drop? : Json) -> Unit {
  self.state("live", others~, clipboard?=clipboard, drop?=drop)
  self.config()
  self.frame(1000.0)
}

///|
fn kind_of_input(j : Json) -> String {
  text(Some(j), "kind")
}

///|
fn close_to(a : Double, b : Double) -> Bool {
  (a - b).abs() < 0.01
}

///|
test "it asks for the view by its name, JPEG only here, as large as its stage; 正在连接 said after a moment" {
  let r = screen_rig()
  let asked = r.told("screen.view")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0]), "station"), "ws-1/st-1")
  assert_eq(text(Some(asked[0]), "screen"), "browser:tab-1")
  assert_eq(text(Some(asked[0]), "view"), r.sess().view)
  assert_eq(items(Some(asked[0]), "codecs"), [Json::string("jpeg")])
  // (no H.265 decoded here: nor its 4:4:4)
  assert_true(field(Some(asked[0]), "chroma444") is None)
  // 自动: the stage it is shown on, in the device's pixels
  let (sw, sh) = r.sess().stage_px
  assert_true(sw > 0 && sh > 0)
  assert_eq(number(Some(asked[0]), "maxWidth"), sw.to_double())
  assert_eq(number(Some(asked[0]), "maxHeight"), sh.to_double())
  // not said: the core decides (only looking while someone else drives it)
  assert_true(field(Some(asked[0]), "control") is None)
  // the device kept awake while it is looked at
  assert_true(r.t.awake())
  r.t.run_for(@sf.later_ms)
  assert_true(r.t.find("正在连接") is Some(_))
  screen_done(r.t)
}

///|
test "live frames are drawn and acknowledged; driven directly a tap clicks, a press held right-clicks, a drag drags" {
  let r = screen_rig(touch="direct")
  r.live()
  assert_true(r.acked(1000.0))
  r.frame(1033.0)
  assert_true(r.acked(1033.0))
  assert_true(r.t.find("控制 · 李雷也在看") is Some(_))
  assert_true(r.t.find("still.fail — Chrome") is Some(_))
  // a tap: down and up with the primary button, where it was in the frame
  r.tap_at(0.25, 0.75)
  let ins = r.inputs()
  assert_eq(ins.length(), 2)
  assert_eq(kind_of_input(ins[0]), "down")
  assert_eq(number(Some(ins[0]), "buttons"), 1.0)
  assert_eq(kind_of_input(ins[1]), "up")
  assert_true(close_to(number(Some(ins[0]), "x"), 0.25))
  assert_true(close_to(number(Some(ins[0]), "y"), 0.75))
  // felt, as the mouse's buttons are
  assert_eq(r.t.haptics(), [@ui.KeyboardTap])
  // held: a right click, the device buzzing
  let (hx, hy) = r.at(0.5, 0.5)
  r.t.press_at(hx, hy)
  r.t.run_for(screen_hold_ms)
  r.t.release(hx, hy)
  let held = r.inputs()[2:].to_owned()
  assert_eq(held.length(), 2)
  assert_eq(kind_of_input(held[0]), "down")
  assert_eq(number(Some(held[0]), "buttons"), 2.0)
  assert_true(close_to(number(Some(held[0]), "x"), 0.5))
  assert_eq(r.t.haptics(), [@ui.KeyboardTap, @ui.LongPress])
  // a drag: down where it began, moves, up where it ended
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.6, 0.5)
  r.t.drag(ax, ay, bx, by)
  let drag = r.inputs()[4:].to_owned()
  assert_eq(kind_of_input(drag[0]), "down")
  assert_true(close_to(number(Some(drag[0]), "x"), 0.2))
  assert_true(drag.iter().filter(fn(j) { kind_of_input(j) == "move" }).count() >= 2)
  assert_eq(kind_of_input(drag[drag.length() - 1]), "up")
  assert_true(close_to(number(Some(drag[drag.length() - 1]), "x"), 0.6))
  // a drag held still: no move again, however many frames are drawn while it is
  let was = r.inputs().length()
  r.t.press_at(ax, ay)
  r.t.move_to(bx, by)
  let moved = r.inputs()[was:].to_owned()
  assert_eq(kind_of_input(moved[0]), "down")
  assert_eq(kind_of_input(moved[moved.length() - 1]), "move")
  let still = r.inputs().length()
  r.t.run_for(held_still_ms)
  assert_eq(r.inputs().length(), still)
  r.t.release(bx, by)
  assert_eq(kind_of_input(r.inputs()[r.inputs().length() - 1]), "up")
  screen_done(r.t)
}

///|
/// How long a drag is held still in it: a dozen frames and more at any rate.
let held_still_ms : Double = 200.0

///|
test "turned sideways the same view goes on, the controls down the side" {
  let r = screen_rig()
  r.live()
  r.t.resize(844.0, 390.0)
  r.t.draw()
  r.frame(1066.0)
  assert_true(r.acked(1066.0))
  assert_eq(r.told("screen.view").length(), 1)
  // the rail: close at its top, 全屏 at its foot; no title bar
  assert_true(r.labelled("关闭") is Some(_))
  assert_true(r.labelled("全屏") is Some(_))
  assert_true(r.t.find("still.fail — Chrome") is None)
  screen_done(r.t)
}

///|
/// The streams the last frame drew, each where (x, y, w, h) and what it showed ("stream WxH ts=TS").
fn drawn_streams(t : @ui.Tester) -> Array[(Double, Double, Double, Double, String)] {
  t
  .drawn_text()
  .split("\n")
  .filter_map(fn(line) {
    let l = line.to_owned()
    guard l.has_prefix("inst ") && l.contains(" stream ") else { return None }
    let words = l.split(" ").map(fn(w) { w.to_owned() }).to_array()
    let n = fn(i : Int) {
      match (try Some(@json.parse(words[i])) catch { _ => None }) {
        Some(Number(d, ..)) => d / 64.0
        _ => 0.0
      }
    }
    let said = l.split(" stream ").map(fn(w) { w.to_owned() }).to_array()
    Some((n(1), n(2), n(3), n(4), "stream " + said[said.length() - 1]))
  })
  .to_array()
}

///|
test "zoomed in, the part in sight is asked for, as sharp as it is shown; its frames drawn over the whole where it is; zoomed out, the whole again once its frame comes" {
  let r = screen_rig()
  r.live()
  let u = r.ui()
  // not zoomed: nothing told
  assert_eq(r.told("screen.look").length(), 0)
  u.zoom.zoom_to(u.zoom.fit() * 4.0, u.box_w.get() / 2.0, u.box_h.get() / 2.0, false, at=r.t.ctx().moment())
  r.t.draw()
  r.t.draw()
  let looks = r.told("screen.look")
  assert_eq(looks.length(), 1)
  let region = field(Some(looks[0]), "region")
  let shown = u.shown(r.t.ctx())
  // a quarter of its width in the middle, all the stage's height of it, in the pixels it is shown in
  assert_true(close_to(number(region, "x"), 0.375))
  assert_true(close_to(number(region, "w"), 0.25))
  let rh = number(region, "h")
  assert_true(close_to(rh, u.box_h.get() / shown.h))
  assert_true(close_to(number(Some(looks[0]), "width") / number(Some(looks[0]), "height"), 0.25 * shown.w / (rh * shown.h)))
  // the part's frames (the station's config saying the part): a decoder of their own, drawn over the whole there
  let part : Json = { "x": 0.375, "y": number(region, "y"), "w": 0.25, "h": rh }
  r.say({ "config": { "codec": "jpeg", "width": 1170.0, "height": 1000.0, "region": part } })
  r.say({ "frame": { "key": true, "ts": 2000.0 } }, bytes=b"\xFF\xD8\xFF\xE0jpeg")
  let pst = r.sess().part.unwrap()
  assert_true(pst.id() != r.sess().stream.unwrap().id())
  r.t.stream_shows(pst.id(), 2000.0, 1170, 1000)
  r.t.draw()
  assert_true(r.acked(2000.0))
  let streams = drawn_streams(r.t)
  assert_eq(streams.length(), 2)
  let (px, py, pw, ph, what) = streams[1]
  assert_eq(what, "stream 1170x1000 ts=2000")
  assert_true(close_to(pw, 0.25 * shown.w))
  assert_true(close_to(ph, rh * shown.h))
  assert_true(close_to(px - streams[0].0, 0.375 * shown.w))
  assert_true(close_to(py - streams[0].1, number(region, "y") * shown.h))
  // laid out by the whole screen's size still
  assert_eq(r.sess().frame_size(), Some((1280, 720)))
  // zoomed out: the whole told; the part drawn until the whole's frame comes, then the whole alone
  u.zoom.fit_now(at=r.t.ctx().moment())
  r.t.draw()
  r.t.draw()
  assert_eq(r.told("screen.look").length(), 2)
  assert_true(field(Some(r.told("screen.look")[1]), "region") is Some(Null))
  assert_eq(drawn_streams(r.t).length(), 2)
  r.config()
  r.frame(3000.0)
  assert_true(r.acked(3000.0))
  let streams = drawn_streams(r.t)
  assert_eq(streams.length(), 1)
  assert_eq(streams[0].4, "stream 1280x720 ts=3000")
  screen_done(r.t)
}

///|
test "zoomed in again: the first frame of the new part is drawn where that part is in the frame that shows it, never at the last part's place" {
  let r = screen_rig()
  r.live()
  let u = r.ui()
  u.zoom.zoom_to(u.zoom.fit() * 4.0, u.box_w.get() / 2.0, u.box_h.get() / 2.0, false, at=r.t.ctx().moment())
  r.t.draw()
  r.t.draw()
  let rh = number(field(Some(r.told("screen.look")[0]), "region"), "h")
  let y = number(field(Some(r.told("screen.look")[0]), "region"), "y")
  // the first part (the middle quarter) shown
  let a : Json = { "x": 0.375, "y": y, "w": 0.25, "h": rh }
  r.say({ "config": { "codec": "jpeg", "width": 1170.0, "height": 1000.0, "region": a } })
  r.say({ "frame": { "key": true, "ts": 2000.0 } }, bytes=b"\xFF\xD8\xFF\xE0jpeg")
  let pst = r.sess().part.unwrap()
  r.t.stream_shows(pst.id(), 2000.0, 1170, 1000)
  r.t.draw()
  r.t.draw()
  // the next part (the quarter left of it, as a pinch at rest there asks), its first frame decoded: the frame that
  // shows it draws it at its own place, not the first part's
  let b : Json = { "x": 0.125, "y": y, "w": 0.25, "h": rh }
  r.say({ "config": { "codec": "jpeg", "width": 1170.0, "height": 1000.0, "region": b } })
  r.say({ "frame": { "key": true, "ts": 3000.0 } }, bytes=b"\xFF\xD8\xFF\xE0jpeg")
  r.t.stream_shows(pst.id(), 3000.0, 1170, 1000)
  // (one frame: the one that takes it, as a host draws it)
  r.t.frame()
  let shown = u.shown(r.t.ctx())
  let streams = drawn_streams(r.t)
  let part = streams.filter(fn(s) { s.4 == "stream 1170x1000 ts=3000" })
  assert_eq(part.length(), 1, msg=streams.map(fn(s) { s.4 }).join(", "))
  let (px, _, pw, _, _) = part[0]
  let whole = streams.filter(fn(s) { s.4 != "stream 1170x1000 ts=3000" })
  assert_true(close_to(pw, 0.25 * shown.w))
  assert_true(
    close_to(px - whole[0].0, 0.125 * shown.w),
    msg="the new part's first frame at \{px - whole[0].0}, its place \{0.125 * shown.w}, the last part's \{0.375 * shown.w}",
  )
  screen_done(r.t)
}

///|
test "a trackpad moves the pointer and clicks where it points; two fingers tapped right-click; the keys row" {
  let r = screen_rig()
  // a desktop's screen (a page of the station's browser is laid out for the phone, and tapped where it is)
  r.state("live", others=[], more={ "kind": "desktop" })
  r.config()
  r.frame(1000.0)
  assert_true(r.sess().pad(r.sess().src))
  // a tap far from the pointer: a click where it points (the middle)
  r.tap_at(0.1, 0.1)
  let ins = r.inputs()
  assert_eq(ins.length(), 2)
  assert_eq(kind_of_input(ins[0]), "down")
  assert_true(close_to(number(Some(ins[0]), "x"), 0.5))
  assert_true(close_to(number(Some(ins[0]), "y"), 0.5))
  // the double tap's wait over: a finger moved right, the pointer goes right, no button held
  r.t.run_for(screen_double_tap_ms)
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.4, 0.5)
  r.t.drag(ax, ay, bx, by)
  let moves = r.inputs()[2:].to_owned()
  assert_true(moves.length() > 0)
  assert_true(moves.iter().all(fn(j) { kind_of_input(j) == "move" && number(Some(j), "buttons") == 0.0 }))
  let x = number(Some(moves[moves.length() - 1]), "x")
  assert_true(x > 0.55 && x <= 1.0)
  assert_true(close_to(number(Some(moves[moves.length() - 1]), "y"), 0.5))
  // two fingers tapped: a right click where it points
  r.t.run_for(screen_double_tap_ms)
  let before = r.inputs().length()
  let (p1x, p1y) = r.at(0.3, 0.5)
  let (p2x, p2y) = r.at(0.6, 0.5)
  r.t.press_at(p1x, p1y)
  r.t.touch(4, p2x, p2y)
  r.t.draw()
  r.t.touch(6, p2x, p2y)
  r.t.release(p1x, p1y)
  let right = r.inputs()[before:].to_owned()
  assert_eq(kind_of_input(right[0]), "down")
  assert_eq(number(Some(right[0]), "buttons"), 2.0)
  assert_true(close_to(number(Some(right[0]), "x"), x))
  assert_true(r.t.haptics().contains(@ui.ContextClick))
  // ⌘ held, then Tab: ⌘Tab; Tab again goes alone
  let from = r.inputs().length()
  r.press_key("Command")
  r.press_key("Tab")
  r.press_key("Tab")
  let keys = r.inputs()[from:].to_owned()
  assert_eq(keys.length(), 4)
  assert_eq(text(Some(keys[0]), "code"), "Tab")
  assert_eq(number(Some(keys[0]), "mods"), 4.0)
  assert_eq(number(Some(keys[1]), "mods"), 4.0)
  assert_eq(number(Some(keys[2]), "mods"), 0.0)
  // chosen direct (控制中心's 触控板): kept on this device
  pad_turned(r)
  assert_eq(text(r.told("prefs.set").last(), "screenTouch"), "direct")
  assert_true(!r.sess().pad(r.sess().src))
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "the keyboard: words committed go as text, Enter between lines; with ⌘ held a character goes as its key" {
  let r = screen_rig()
  r.live(others=[])
  r.tap_label("键盘")
  assert_true(r.t.key_catching())
  r.t.type_text("hi 你好")
  let ins = r.inputs()
  assert_eq(text(Some(ins[0]), "t"), "text")
  assert_eq(text(Some(ins[0]), "text"), "hi 你好")
  r.press_key("Command")
  r.t.type_text("c")
  let k = r.inputs()[1:].to_owned()
  assert_eq(k.length(), 2)
  assert_eq(text(Some(k[0]), "key"), "c")
  assert_eq(text(Some(k[0]), "code"), "KeyC")
  assert_eq(number(Some(k[0]), "mods"), 4.0)
  // only looking: the keyboard goes
  r.state("live", control=false, others=[])
  assert_true(!r.t.key_catching())
  screen_done(r.t)
}

///|
test "only looking, a double tap zooms in where it is and another back to fitted; taps further apart do not" {
  let r = screen_rig()
  r.state("live", control=false, others=[])
  r.config()
  r.frame(1000.0)
  let u = r.ui()
  assert_false(u.zoom.zoomed_at(r.t.time()))
  r.tap_at(0.25, 0.25)
  r.tap_at(0.25, 0.25)
  r.t.run_for(@ui.move_most_ms)
  assert_true(u.zoom.zoomed_at(r.t.time()))
  assert_eq(r.inputs().length(), 0)
  // the same point of the screen, still under the finger
  r.t.run_for(screen_double_tap_ms)
  r.tap_at(0.25, 0.25)
  r.tap_at(0.25, 0.25)
  r.t.run_for(@ui.move_most_ms)
  assert_false(u.zoom.zoomed_at(r.t.time()))
  // one tap, then the wait over before the next: no zoom
  r.t.run_for(screen_double_tap_ms)
  r.tap_at(0.25, 0.25)
  r.t.run_for(screen_double_tap_ms)
  r.tap_at(0.25, 0.25)
  r.t.run_for(@ui.move_most_ms)
  assert_false(u.zoom.zoomed_at(r.t.time()))
  screen_done(r.t)
}

///|
test "the keys row short of room on a phone: Esc and the arrows in it, the least used out; its ⋯ turns it to them, a modifier held there stays in it once back" {
  let r = screen_rig()
  r.live(others=[])
  // (the row is the keyboard's, since 2026-11-13: raised from the foot)
  r.tap_label(tr("android-misc.screen.keyboard"))
  assert_true(r.labelled("Esc") is Some(_))
  assert_true(r.labelled(tr("android-misc.screen.key.left")) is Some(_))
  assert_true(r.labelled(tr("android-misc.screen.key.option")) is None)
  // turned: the keys that were out (the most used of them first), Esc not among them
  r.tap_label(tr("common.more"))
  assert_true(r.labelled(tr("android-misc.screen.key.command")) is Some(_))
  assert_true(r.labelled("Esc") is None)
  // ⌥ reached by turning on, held; back round: ⌥ held, in the row with Esc
  r.press_key(tr("android-misc.screen.key.option"))
  assert_true(r.labelled("Esc") is Some(_))
  let opt = r.t.get(@ui.Role::Button, label=tr("android-misc.screen.key.option"))
  assert_eq(opt.pressed, Some(true))
  // nothing over another, nothing cut
  assert_eq(r.t.squeeze_faults(), [])
  screen_done(r.t)
}

///|
test "the keys row turned on a narrow phone: what was out does not all fit either, so it too leaves keys for a next turn; nothing over the keyboard's button, every key reached, then back" {
  for w in [390.0, 360.0, 320.0] {
    let r = screen_rig(w~)
    r.live(others=[])
    // (the row is the keyboard's, since 2026-11-13: raised from the foot; the mouse's buttons are the foot's)
    r.tap_label(tr("android-misc.screen.keyboard"))
    let names = screen_row_keys().filter(fn(k) { k.button == 0 }).map(fn(k) { k.name })
    let reached : Array[String] = []
    let seen = fn() {
      for n in names {
        if r.labelled(n) is Some(_) && !reached.contains(n) {
          reached.push(n)
        }
      }
    }
    seen()
    // ⋯ pressed till the row is back where it began (Esc in it again), each face whole
    for turns = 0; turns < names.length(); turns = turns + 1 {
      r.tap_label(tr("common.more"))
      assert_eq(r.t.squeeze_faults(), [])
      seen()
      if r.labelled("Esc") is Some(_) {
        break
      }
    }
    assert_true(r.labelled("Esc") is Some(_))
    assert_eq(reached.length(), names.length())
    screen_done(r.t)
  }
}

///|
test "全屏 (控制中心's upright): the screen alone, sideways, its tools folded into one button; opened, the same tools; 退出全屏 upright" {
  let r = screen_rig()
  r.live(others=[])
  assert_true(r.labelled("全屏") is None)
  open_center(r)
  r.t.tap_text("全屏")
  r.t.run_for(@motion.presence_out_ms + @sf.later_ms)
  r.t.resize(844.0, 390.0)
  r.t.draw()
  let u = r.ui()
  assert_true(u.full.get())
  // edge to edge: the stage is the whole window
  assert_eq((u.box_w.get(), u.box_h.get()), (844.0, 390.0))
  assert_true(r.labelled("工具") is Some(_))
  assert_true(r.labelled("关闭") is None)
  r.tap_label("工具")
  assert_true(r.labelled("退出全屏") is Some(_))
  assert_true(r.labelled("键盘") is Some(_))
  r.tap_label("退出全屏")
  r.t.resize(390.0, 844.0)
  r.t.draw()
  assert_true(!r.ui().full.get())
  assert_true(r.labelled("控制中心") is Some(_))
  screen_done(r.t)
}

///|
test "the keyboard up keeps the frame as large, the pointer in sight; down again, fitted as before" {
  let zoom = screen_zoom()
  zoom.natural(1280.0, 720.0, at=@ui.current().moment())
  zoom.boxed(800.0, 360.0, at=@ui.current().moment())
  let before = fit_in(800.0, 360.0, 1280.0, 720.0)
  zoom.resize_keeping(800.0, 150.0, Some((0.5, 0.9)), 40.0, when=@ui.current().moment())
  let (_, sy, sw, sh) = zoom.rect_at(@ui.current().moment()).unwrap()
  assert_true((sw - before.w).abs() < 1.0)
  let y = sy + 0.9 * sh
  assert_true(y >= 0.0 && y <= 150.0)
  zoom.resize_keeping(800.0, 360.0, Some((0.5, 0.9)), 40.0, when=@ui.current().moment())
  assert_true(!zoom.zoomed_at(@ui.current().moment()))
  let (x, y, w, h) = zoom.rect_at(@ui.current().moment()).unwrap()
  assert_true((x - before.x).abs() < 0.001 && (y - before.y).abs() < 0.001)
  assert_true((w - before.w).abs() < 0.001 && (h - before.h).abs() < 0.001)
}

///|
test "an agent driving it: only looking, who drives said with 接管; 接管 asks for control, the line then says it waits" {
  let r = screen_rig()
  let agent = "Agent「修登录」"
  r.state(
    "live",
    control=false,
    others=[agent, "Bob"],
    controllers=[agent],
    take_over=true,
    line="只看 · \{agent} 正在控制 · Bob 也在查看",
  )
  r.config()
  r.frame(1000.0)
  assert_true(r.t.find("\{agent} 正在控制") is Some(_))
  // who drives it is said with 接管, not twice
  assert_true(r.t.find("只看 · \{agent}") is None)
  // only looking: a tap is not sent
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 0)
  r.t.tap_text("接管")
  let asked = r.told("screen.control")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0]), "view"), r.sess().view)
  assert_eq(field(Some(asked[0]), "control"), Some(Json::boolean(true)))
  r.state(
    "live",
    control=true,
    others=[agent, "Bob"],
    controllers=[],
    take_over=false,
    line="控制 · \{agent} 已暂停 · Bob 也在查看",
  )
  assert_true(r.t.find("接管") is None)
  assert_true(r.t.find("控制 · \{agent} 已暂停 · Bob 也在查看") is Some(_))
  // (只看/控制's thumb gone over to 控制: its slide's declared length)
  r.t.run_for(@ui.cover_slide_ms)
  screen_done(r.t)
}

///|
test "made to only look from elsewhere: 只看 chosen for it, input not sent, 控制 a tap away" {
  let r = screen_rig()
  r.state("live", control=true)
  r.config()
  r.frame(1000.0)
  assert_true(r.sess().controlling())
  r.state("live", control=false, line="只看 · 还开在 still.fail iOS", more={ "watchOnly": Json::number(1.0) })
  assert_false(r.sess().controlling())
  assert_true(r.t.find("只看 · 还开在 still.fail iOS") is Some(_))
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 0)
  // 只看 turned off in 控制中心 (off the bar since 2026-11-13)
  look_switch(r)
  let asked = r.told("screen.control")
  assert_eq(asked.length(), 1)
  assert_eq(field(Some(asked[0]), "control"), Some(Json::boolean(true)))
  r.t.run_for(@ui.cover_slide_ms)
  screen_done(r.t)
}

///|
test "taken by another as it drove: who said once, only looking, 接管 a tap away; one taken by nobody named says so plainly" {
  let r = screen_rig()
  r.state("live", control=true)
  r.config()
  r.frame(1000.0)
  let said = app.toast.get().n
  let took_by = fn(n : Double, by : Array[String]) {
    r.state(
      "live",
      control=false,
      controllers=["李雷"],
      take_over=true,
      line="只看 · 李雷 正在控制",
      more={
        "watchOnly": Json::number(n),
        "taken": Json::number(n),
        "takenBy": Json::array(by.map(Json::string)),
      },
    )
  }
  took_by(1.0, ["李雷"])
  assert_eq(@sfbase.toast_words(), "李雷 接管了控制，你现在是只看")
  assert_eq(app.toast.get().n, said + 1)
  assert_false(r.sess().controlling())
  assert_true(r.labelled("接管") is Some(_))
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 0)
  // the same take told again (who is on it changed): not said again
  took_by(1.0, ["李雷"])
  assert_eq(app.toast.get().n, said + 1)
  // taken again, by the viewer on another device (unnamed)
  took_by(2.0, [])
  assert_eq(@sfbase.toast_words(), "控制已被接管，你现在是只看")
  assert_eq(app.toast.get().n, said + 2)
  screen_done(r.t)
}

///|
test "接管 from a person: said once whose views only look now" {
  let r = screen_rig()
  r.state("live", control=false, controllers=["李雷"], take_over=true, line="只看 · 李雷 正在控制")
  r.config()
  r.frame(1000.0)
  let said = app.toast.get().n
  r.tap_label("接管")
  assert_eq(field(Some(r.told("screen.control")[0]), "control"), Some(Json::boolean(true)))
  r.state(
    "live",
    control=true,
    controllers=[],
    take_over=false,
    line="控制 · 李雷也在看",
    more={ "took": Json::number(1.0), "tookFrom": Json::array([Json::string("李雷")]) },
  )
  assert_eq(@sfbase.toast_words(), "已接管控制，李雷 改为只看")
  assert_eq(app.toast.get().n, said + 1)
  assert_true(r.t.find("已接管控制，李雷 改为只看") is Some(_))
  // told again with the same take: not said again
  r.state("live", control=true, more={ "took": Json::number(1.0), "tookFrom": Json::array([Json::string("李雷")]) })
  assert_eq(app.toast.get().n, said + 1)
  screen_done(r.t)
}

///|
test "read only: no 只看/控制 to choose, no keyboard, a tap not sent" {
  let r = screen_rig()
  r.state("live", control=false, may=false)
  r.config()
  r.frame(1000.0)
  assert_true(r.labelled("控制") is None)
  assert_true(r.labelled("键盘") is None)
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 0)
  screen_done(r.t)
}

///|
test "控制 chosen but the station cannot take input: seen, nothing sent, why said quietly" {
  let r = screen_rig()
  r.state(
    "live",
    control=false,
    others=[],
    access={
      "capture": true,
      "control": false,
      "message": "在 辅助功能 里打开 stillfail-station",
      "app": "stillfail-station",
    },
  )
  r.config()
  r.frame(1000.0)
  assert_true(r.t.find("在 辅助功能 里打开 stillfail-station") is Some(_))
  assert_true(r.sess().undriven() is Some(_))
  // nothing of driving it: no keys row, keyboard, trackpad or pasting
  for label in ["键盘", "触控板", "Esc", "粘贴手机剪贴板"] {
    assert_true(r.labelled(label) is None, msg=label)
  }
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 0)
  screen_done(r.t)
}

///|
test "reconnecting keeps the frame, faded, why said over it" {
  let r = screen_rig()
  r.live()
  r.state("reconnecting", message="和 station 的连接断了，正在重新连接…")
  r.t.run_for(@sf.later_ms)
  assert_true(r.t.find("和 station 的连接断了，正在重新连接…") is Some(_))
  screen_done(r.t)
}

///|
test "over: ended, outdated, gone, denied said in the screen's place; 重新打开 opens it again; the call's failure" {
  let r = screen_rig()
  r.live()
  r.state("ended", message="agent 关掉了这个标签页")
  r.finish()
  assert_true(r.t.find("已结束") is Some(_))
  assert_true(r.t.find("agent 关掉了这个标签页") is Some(_))
  assert_true(r.t.find("重新打开") is Some(_))
  // (no grant missing: nothing to go and ask for)
  assert_true(r.t.find("前往权限设置") is None)
  // gone, the core saying the headline's words: said once
  r.t.tap_text("重新打开")
  assert_eq(r.told("screen.view").length(), 2)
  r.state("gone", others=[], message="此屏幕已不存在")
  r.finish()
  let mut n = 0
  for s in r.t.semantics() {
    if s.label.contains("此屏幕已不存在") {
      n += 1
    }
  }
  assert_true(n <= 1)
  assert_true(r.t.find("重新打开") is None)
  // denied, for a grant the station lacks: what to turn on where
  r.t.click(@ui.Role::Button, label="关闭")
  nav_rested(r.t)
  assert_true(!(app.nav.top() is Screen(_)))
  r.t.draw()
  screen_done(r.t)
}

///|
test "denied for a grant the station lacks: its station's 权限 a tap away (前往权限设置), beside 重新打开" {
  // (2026-10-31 the user: 「这个交互不合格，需要用户自己找入口」「你至少能跳到设置」)
  let r = screen_rig()
  r.state(
    "denied",
    message="此 Mac 尚未允许 still.fail Helper 录制屏幕和进行操作。",
    access={
      "capture": false,
      "control": false,
      "message": "那台 Mac 上已弹出授权窗口：请在其中点击「允许」，将 still.fail Helper 拖入系统设置的列表，然后重新打开画面。",
      "app": "still.fail Helper",
    },
  )
  r.finish()
  assert_true(r.t.find("重新打开") is Some(_))
  r.t.tap_text("前往权限设置")
  nav_rested(r.t)
  assert_true(app.nav.top() == Setting(@settings.Route::Station("ws-1/st-1")))
  assert_eq(@settings.station_parts.get("ws-1/st-1"), Some("settings"))
  @settings.station_parts.remove("ws-1/st-1")
  screen_done(r.t)
}

///|
test "a Linux desktop failure offers reopening without a macOS permissions button" {
  let r = screen_rig(os="Linux 6.8")
  r.state(
    "denied",
    message="正在为 Linux 屏幕控制准备所需组件，完成后请重新打开。",
    access={ "capture": false, "control": false, "message": "正在为 Linux 屏幕控制准备所需组件，完成后请重新打开。" },
  )
  r.finish()
  assert_true(r.t.find("重新打开") is Some(_))
  assert_true(r.t.find("前往权限设置") is None)
  assert_true(r.t.find("安装说明") is None)
  screen_done(r.t)
}

///|
test "a Linux component failure offers the installation guide at either page width" {
  for w in [390.0, 1200.0] {
    let r = screen_rig(w~, os="Linux 6.8")
    r.state(
      "denied",
      message="无法连接 Wayland 桌面。",
      access={ "capture": false, "control": false, "message": "无法连接 Wayland 桌面。", "help": "linux-desktop" },
    )
    r.finish()
    assert_true(r.t.find("重新打开") is Some(_))
    r.t.tap_text("安装说明")
    assert_true(r.t.opened().contains("https://github.com/AFK-surf/monoid/blob/main/docs/linux-desktop-setup.md"))
    screen_done(r.t)
  }
}

///|
test "on a phone a page of the station's browser is laid out for the stage it is shown on, and a tap is where it is; one opened for a login goes back by itself once its tab is gone" {
  let r = screen_rig(until_gone=true)
  let u = r.ui()
  let fit = field(Some(r.told("screen.view")[0]), "fit")
  assert_true(u.box_w.get() > 0.0 && u.box_h.get() > 0.0)
  assert_eq(number(fit, "width"), u.box_w.get().round())
  assert_eq(number(fit, "height"), u.box_h.get().round())
  assert_true(number(fit, "scale") > 0.0)
  r.live()
  assert_true(!r.sess().pad(r.sess().src), msg="driven directly, as the phone's own browser")
  // its tab closed as the login ended: back to where it was opened from
  r.state("gone", others=[], message="此屏幕已不存在")
  r.finish()
  nav_rested(r.t)
  assert_true(!(app.nav.top() is Screen(_)))
  r.t.draw()
  screen_done(r.t)
}

///|
test "a computer lays nothing out for itself; a screen opened from its list stays once it is gone" {
  let r = mouse_rig()
  assert_true(field(Some(r.told("screen.view")[0]), "fit") is None)
  r.live()
  r.state("gone", others=[], message="此屏幕已不存在")
  r.finish()
  nav_rested(r.t)
  assert_true(app.nav.top() is Screen(_))
  mouse_done(r)
}

///|
test "the call itself failed: said with the core's words; 重新打开 there" {
  let r = screen_rig()
  r.finish(error={ "code": "offline", "message": "station 不在线" })
  assert_true(r.t.find("无法打开此屏幕") is Some(_))
  assert_true(r.t.find("station 不在线") is Some(_))
  assert_true(r.t.find("重新打开") is Some(_))
  // (past the moment 正在连接 would have been said, asked for as the page opened)
  r.t.run_for(@sf.later_ms)
  screen_done(r.t)
}

///|
test "auth_stale reopens screen.view automatically up to retry bound" {
  let r = screen_rig()
  let v0 = text(Some(r.told("screen.view")[0]), "view")
  r.finish(error={ "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" })
  assert_eq(r.told("screen.view").length(), 2)
  let v1 = text(Some(r.told("screen.view")[1]), "view")
  assert_true(v1 != v0 && v1 == r.sess().view, msg="auth_stale retry must allocate a fresh view name")
  assert_true(r.t.find("无法打开此屏幕") is None)
  r.finish(error={ "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" })
  assert_eq(r.told("screen.view").length(), 3)
  let v2 = text(Some(r.told("screen.view")[2]), "view")
  assert_true(v2 != v1 && v2 != v0 && v2 == r.sess().view, msg="each retry must allocate a distinct view name")
  assert_true(r.t.find("无法打开此屏幕") is None)
  r.finish(error={ "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" })
  assert_eq(r.told("screen.view").length(), 3)
  assert_true(r.t.find("无法打开此屏幕") is Some(_))
  assert_true(r.t.find("授权或锁定状态已变化，请重试") is Some(_))
  screen_done(r.t)
}

///|
test "synchronous stream rejection leaves call zero so manual reopen works" {
  let r = screen_rig()
  let s = r.sess()
  s.pause(s.src)
  let opens : Ref[Int] = Ref(0)
  let sync_fail : Ref[Bool] = Ref(true)
  let base = s.src
  let wrapped : Source = {
    ..base,
    stream: fn(name, params, bytes, on_value, on_done) {
      if name == "screen.view" {
        opens.val += 1
        if sync_fail.val {
          on_done(Err({ "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" }))
          return 999
        }
      }
      (base.stream)(name, params, bytes, on_value, on_done)
    },
  }
  s.open(wrapped)
  assert_eq(opens.val, 1)
  assert_eq(s.call, 0, msg="synchronous rejection must not leave stale call id")
  assert_eq(s.phase(), "failed")
  sync_fail.val = false
  s.open(wrapped)
  assert_eq(opens.val, 2, msg="reopen after synchronous rejection must open a new stream")
  assert_true(s.call != 0)
  screen_done(r.t)
}

///|
test "stale callbacks from a paused or superseded view do not clobber the active view" {
  let r = screen_rig()
  let s = r.sess()
  let first_value = r.views[0].0
  let first_done = r.views[0].1
  s.pause(s.src)
  // Late value or failure from the paused view must be ignored.
  first_value({ "state": { "phase": "live", "title": "stale" } }, None)
  first_done(Err({ "code": "offline", "message": "stale failure" }))
  assert_eq(s.failure.get(), None, msg="paused view's late on_done must not set failure")
  // Reopening allocates a new view; late callbacks from the superseded view must not clobber it.
  s.open(s.src)
  let active_call = s.call
  let active_view = s.view
  assert_true(active_call != 0)
  first_value({ "state": { "phase": "ended", "message": "old" } }, None)
  first_done(Err({ "code": "offline", "message": "old failure" }))
  assert_eq(s.call, active_call, msg="superseded view's late on_done must not zero active call")
  assert_eq(s.view, active_view)
  assert_eq(s.failure.get(), None, msg="superseded view's late on_done must not fail active view")
  screen_done(r.t)
}

///|
test "out of sight the view is let go of, the last frame kept; back in sight it opens again" {
  let r = screen_rig()
  let v0 = text(Some(r.told("screen.view")[0]), "view")
  r.live()
  r.t.app_state(false, false)
  r.t.draw()
  assert_eq(r.cancelled.length(), 1)
  assert_true(r.sess().shown_any)
  r.t.app_state(true, true)
  r.t.draw()
  assert_eq(r.told("screen.view").length(), 2)
  let v1 = text(Some(r.told("screen.view")[1]), "view")
  assert_true(v1 != v0 && v1 == r.sess().view, msg="reopen after pause must use a fresh view name")
  screen_done(r.t)
}

///|
test "while it is looked at a phone may turn as it is held (the system's turn button with the rotation lock on); out of sight, upright only" {
  let r = screen_rig()
  r.live()
  assert_true(r.ui().turnable)
  r.t.app_state(false, false)
  r.t.draw()
  assert_true(!r.ui().turnable)
  r.t.app_state(true, true)
  r.t.draw()
  assert_true(r.ui().turnable)
  screen_done(r.t)
}

///|
test "a login field in focus while driving a tab: 用 1Password 填入; its logins for the site picked from, the one picked filled; none on a host without one" {
  let r = screen_rig()
  r.live(others=[])
  // no password manager on this host: nothing offered
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "password" } })
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is None)
  // (a host's password manager is there from its start: the page reads it as the state comes)
  screen_fix_one_password()
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "password" } })
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))
  assert_true(r.t.find("github.com") is Some(_))
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  // two for github.com (gitlab.com's not among them): picked from
  assert_eq(@ui.fake_op_runs[0], ["item", "list", "--categories", "Login", "--format", "json"])
  assert_true(r.t.find("选一个 github.com 的登录") is Some(_))
  assert_true(r.labelled("GitLab") is None)
  r.tap_label("GitHub 工作 · demo-work")
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_op_runs[1], ["item", "get", "gh2", "--fields", "label=username,label=password", "--reveal", "--format", "json"])
  let fill = r.inputs().filter(fn(i) { text(Some(i), "t") == "fill" })
  assert_eq(fill.length(), 1)
  assert_eq(text(Some(fill[0]), "host"), "github.com")
  assert_eq(text(Some(fill[0]), "username"), "demo-work")
  assert_eq(text(Some(fill[0]), "password"), "pw-demo-work")
  // the focus left the login: nothing offered
  r.state("live", others=[])
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is None)
  // a site 1Password has no login for: said so
  r.state("live", others=[], more={ "login": { "host": "example.org", "field": "username" } })
  r.t.draw()
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  assert_true(r.t.find("1Password 里没有 example.org 的登录") is Some(_))
  screen_done(r.t)
  // (the host's 1Password let go of once the run is done: taken away before, the page lost its offer between two
  // frames with nothing said, a frame painted from the last build showing it still, MBUI_TEST_FPS=24)
  @ui.fake_op.val = None
}

///|
test "1Password fill caches non-secret login metadata across fills, passes --vault to item get, and invalidates on get error" {
  let r = screen_rig()
  r.live(others=[])
  let fail_get = Ref(false)
  @ui.fake_op_runs.clear()
  @ui.fake_op.val = Some(fn(args) {
    if args.length() >= 2 && args[0] == "item" && args[1] == "list" {
      (
        0,
        "[{\"id\":\"gh1\",\"title\":\"GitHub\",\"additional_information\":\"demo-user\",\"vault\":{\"id\":\"v-work\"},\"urls\":[{\"href\":\"https://github.com/login\"}]},{\"id\":\"gl1\",\"title\":\"GitLab\",\"additional_information\":\"gl-user\",\"vault\":{\"id\":\"v-priv\"},\"urls\":[{\"href\":\"https://gitlab.com\"}]}]",
        "",
      )
    } else if args.length() >= 3 && args[0] == "item" && args[1] == "get" {
      if fail_get.val {
        (1, "", "item not found")
      } else {
        (0, "[{\"id\":\"username\",\"label\":\"username\",\"value\":\"u-\{args[2]}\"},{\"id\":\"password\",\"label\":\"password\",\"purpose\":\"PASSWORD\",\"value\":\"pw-\{args[2]}\"}]", "")
      }
    } else {
      (1, "", "unknown command")
    }
  })
  // First fill: runs item list once, then item get with --vault v-work.
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "password" } })
  r.t.draw()
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_op_runs.length(), 2)
  assert_eq(@ui.fake_op_runs[0], ["item", "list", "--categories", "Login", "--format", "json"])
  assert_eq(@ui.fake_op_runs[1], ["item", "get", "gh1", "--vault", "v-work", "--fields", "label=username,label=password", "--reveal", "--format", "json"])
  // Second fill for another cached site within TTL: skips item list and goes straight to item get with --vault v-priv.
  r.state("live", others=[], more={ "login": { "host": "gitlab.com", "field": "password" } })
  r.t.draw()
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_op_runs.length(), 3)
  assert_eq(@ui.fake_op_runs[2], ["item", "get", "gl1", "--vault", "v-priv", "--fields", "label=username,label=password", "--reveal", "--format", "json"])
  // Failed item get invalidates the cache so the next fill lists again.
  fail_get.val = true
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_op_runs.length(), 4)
  let closes = r.t.semantics().filter(fn(s) { s.label == tr("common.close") && !s.hidden && s.rect.1 > 200.0 })
  assert_eq(closes.length(), 1)
  let (cx, cy, cw, ch) = closes[0].rect
  r.t.tap(cx + cw / 2.0, cy + ch / 2.0)
  r.t.draw()
  fail_get.val = false
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "username" } })
  r.t.draw()
  r.tap_label("填入")
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_op_runs.length(), 6)
  assert_eq(@ui.fake_op_runs[4], ["item", "list", "--categories", "Login", "--format", "json"])
  assert_eq(@ui.fake_op_runs[5], ["item", "get", "gh1", "--vault", "v-work", "--fields", "label=username,label=password", "--reveal", "--format", "json"])
  screen_done(r.t)
  @ui.fake_op.val = None
}

///|
test "no 1Password tool but the system's autofill: 用密码管理器填入 asks it for the site; the login picked there filled, for that site only, the page's focus gone or not" {
  let r = screen_rig()
  r.live(others=[])
  @ui.fake_autofill.val = true
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "username" } })
  r.t.draw()
  assert_true(r.t.find("用密码管理器填入") is Some(_))
  assert_true(r.t.find("用 1Password 填入") is None)
  r.tap_label("填入")
  r.t.draw()
  assert_eq(@ui.fake_autofill_asks, ["github.com"])
  assert_true(r.t.find("在密码管理器里选一个 github.com 的登录") is Some(_))
  // a login for another site than the one asked for: not filled
  @ui.fake_autofill_picks("evil.example", "demo-user", "pw-evil")
  r.t.draw()
  r.t.draw()
  assert_eq(r.inputs().filter(fn(i) { text(Some(i), "t") == "fill" }).length(), 0)
  @ui.fake_autofill_picks("github.com", "demo-work", "pw-demo-work")
  r.t.draw()
  r.t.draw()
  let fill = r.inputs().filter(fn(i) { text(Some(i), "t") == "fill" })
  assert_eq(fill.length(), 1)
  assert_eq(text(Some(fill[0]), "host"), "github.com")
  assert_eq(text(Some(fill[0]), "username"), "demo-work")
  assert_eq(text(Some(fill[0]), "password"), "pw-demo-work")
  assert_eq(@ui.fake_autofill_asks, ["github.com", ""])
  assert_true(r.t.find("用密码管理器填入") is Some(_))
  // asked again, and the page's focus leaves the login while the service is asked (as the station says it as the app
  // takes the tap, before the service answers, 2026-11-01): the ask goes on, and the login picked is filled as
  // 1Password's is, the station filling the page's form only while the tab is on the site
  let pointers = r.inputs().filter(fn(i) { text(Some(i), "t") == "pointer" }).length()
  r.tap_label("填入")
  r.t.draw()
  assert_eq(r.inputs().filter(fn(i) { text(Some(i), "t") == "pointer" }).length(), pointers)
  r.state("live", others=[])
  r.t.draw()
  r.t.draw()
  assert_eq(@ui.fake_autofill_asks, ["github.com", "", "github.com"])
  assert_true(r.t.find("在密码管理器里选一个 github.com 的登录") is Some(_))
  @ui.fake_autofill_picks("github.com", "demo-user", "pw-demo-user")
  r.t.draw()
  r.t.draw()
  let fill = r.inputs().filter(fn(i) { text(Some(i), "t") == "fill" })
  assert_eq(fill.length(), 2)
  assert_eq(text(Some(fill[1]), "username"), "demo-user")
  assert_eq(@ui.fake_autofill_asks, ["github.com", "", "github.com", ""])
  assert_true(r.t.find("在密码管理器里选一个 github.com 的登录") is None)
  screen_done(r.t)
}

///|
test "the autofill service's sign-in takes the app out of sight: the login picked there filled once the view is live again" {
  let r = screen_rig()
  r.live(others=[])
  @ui.fake_autofill.val = true
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "username" } })
  r.t.draw()
  r.tap_label("填入")
  r.t.draw()
  // 1Password asks for a fingerprint in a screen of its own: the app goes out of sight, the view is let go of
  r.t.app_state(false, false)
  r.t.draw()
  @ui.fake_autofill_picks("github.com", "demo-work", "pw-demo-work")
  r.t.draw()
  r.t.draw()
  let fills = fn() { r.inputs().filter(fn(i) { text(Some(i), "t") == "fill" }) }
  assert_eq(fills().length(), 0)
  // back in sight: opened again, nothing sent until it says it is live
  r.t.app_state(true, true)
  r.t.draw()
  r.t.draw()
  assert_eq(r.told("screen.view").length(), 2)
  assert_eq(fills().length(), 0)
  r.state("live", others=[], more={ "login": { "host": "github.com", "field": "username" } })
  r.t.draw()
  r.t.draw()
  assert_eq(fills().length(), 1)
  assert_eq(text(Some(fills()[0]), "host"), "github.com")
  assert_eq(text(Some(fills()[0]), "username"), "demo-work")
  r.t.draw()
  assert_eq(fills().length(), 1)
  screen_done(r.t)
}

///|
/// Live and driven, a station that carries the clipboard both ways and takes files.
fn driven(r : ScreenRig) -> Unit {
  r.live(others=[], clipboard=["text", "png"], drop={ "folder": "/Users/alice/Downloads", "reveal": true })
}

///|
/// 控制中心's 触控板 pressed (trackpad or direct, turned), 控制中心 shut again.
fn pad_turned(r : ScreenRig) -> Unit {
  open_center(r)
  r.tap_label("触控板")
  r.t.draw()
  shut(r)
}

///|
test "driving it: 粘贴 beside the keyboard (发送文件 in 控制中心); 粘贴 sends the device's clipboard; refused, said; empty, said" {
  let r = screen_rig()
  driven(r)
  assert_true(r.labelled("发送文件") is None)
  assert_true(r.labelled("粘贴手机剪贴板") is Some(_))
  assert_true(r.labelled("键盘") is Some(_))
  r.t.clipboard_gives("hello from the phone")
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  let asked = r.told("screen.clipboard")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0]), "view"), r.sess().view)
  assert_eq(text(Some(asked[0]), "text"), "hello from the phone")
  assert_eq(field(Some(asked[0]), "paste"), Some(Json::boolean(true)))
  // refused: said
  r.answer.val = fn(name, _) {
    if name == "screen.clipboard" {
      Some(Err({ "code": "unsupported", "message": "这个屏幕不支持剪贴板" }))
    } else {
      None
    }
  }
  r.t.clipboard_gives("again")
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  assert_true(r.t.find("无法粘贴：这个屏幕不支持剪贴板") is Some(_))
  r.t.run_for(@sf.toast_ms)
  // nothing on the clipboard: said, nothing sent
  r.t.clipboard_gives("")
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  assert_true(r.t.find("剪贴板是空的") is Some(_))
  assert_eq(r.told("screen.clipboard").length(), 2)
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "a copy made on the screen lands on the device's clipboard: text as it is, a PNG as a picture; not from a text-only screen" {
  let r = screen_rig()
  driven(r)
  r.say({ "clipboard": { "type": "text", "text": "copied on the Mac 复制的" } })
  assert_eq(r.t.clipboard(), "copied on the Mac 复制的")
  let png = b"\x89PNG\r\n\x1a\n-a-picture"
  r.say({ "clipboard": { "type": "png", "size": png.length().to_double() } }, bytes=png)
  assert_eq(r.t.clipboard_png(), Some(png))
  // not a PNG: not put there
  r.say({ "clipboard": { "type": "png", "size": 6.0 } }, bytes=b"\xFF\xD8\xFF\xE0\x00\x10")
  assert_eq(r.t.clipboard_png(), Some(png))
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "the device's picture pasted as PNG; past 8 MB said, not sent; a text-only screen never sent one" {
  let r = screen_rig()
  driven(r)
  let png = b"\x89PNG\r\n\x1a\n-a-picture"
  r.t.clipboard_gives_png(png)
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  let sent = r.calls.filter(fn(c) { c.0 == "screen.clipboard" })
  assert_eq(sent.length(), 1)
  assert_eq(field(Some(sent[0].1), "png"), Some(Json::boolean(true)))
  assert_eq(sent[0].2, Some(png))
  // The clipboard reader accepts attachments now; this screen's transport still refuses pictures past its bound.
  r.t.clipboard_gives_png(Bytes::make(8 * 1024 * 1024 + 1, b'\x00'))
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  assert_true(r.t.find("图片过大，上限 8 MB") is Some(_))
  assert_eq(r.told("screen.clipboard").length(), 1)
  r.t.run_for(@sf.toast_ms)
  r.t.clipboard_gives_clip({ text: "", picture: TooLarge, files: [] })
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  assert_true(r.t.find("图片过大，上限 8 MB") is Some(_))
  r.t.run_for(@sf.toast_ms)
  r.state(
    "live",
    others=[],
    clipboard=["text"],
    drop={ "folder": "/Users/alice/Downloads", "reveal": true },
  )
  r.t.clipboard_gives_png(png)
  r.tap_label("粘贴手机剪贴板")
  r.t.draw()
  assert_true(r.t.find("此屏幕不支持粘贴图片") is Some(_))
  assert_eq(r.told("screen.clipboard").length(), 1)
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "a station from before the clipboard and files, or only looking: neither offered" {
  let r = screen_rig()
  r.live(others=[])
  assert_true(r.labelled("键盘") is Some(_))
  assert_true(r.labelled("发送文件") is None)
  assert_true(r.labelled("粘贴手机剪贴板") is None)
  r.state("live", control=false, others=[])
  assert_true(r.labelled("发送文件") is None)
  assert_true(r.labelled("键盘") is None)
  screen_done(r.t)
}

///|
test "files go onto the machine one after another, the first beside the one of its name there, as the station keeps both; then their paths pasted or shown" {
  let r = screen_rig()
  driven(r)
  r.answer.val = fn(name, p) {
    // the name beside the one taken, as the core gives it (drive.name, beside: `a 2.pdf`)
    if name == "drive.name" && text(Some(p), "name") == "季度报告.pdf" {
      return Some(Ok({ "name": "季度报告 2.pdf" }))
    }
    if name != "drive.upload.part" {
      return None
    }
    let path = text(Some(p), "path")
    if text(Some(p), "root") != "/Users/alice/Downloads" {
      @halt.saying("the upload's root: " + text(Some(p), "root"))
    }
    if path == "季度报告.pdf" {
      return Some(Err({ "code": "exists", "message": "there is already a file by that name", "status": 409.0 }))
    }
    let have = number(Some(p), "offset") + r.calls[r.calls.length() - 1].2.unwrap().length().to_double()
    let total = number(Some(p), "total")
    let a : Map[String, Json] = { "have": Json::number(have) }
    if have >= total {
      a["entry"] = { "name": Json::string(path), "dir": false }
    }
    Some(Ok(Json::object(a)))
  }
  r.t.picks([("季度报告.pdf", Bytes::make(300 * 1024, b'\x01')), ("notes.txt", b"still.fail\n")])
  // 控制中心's 发送文件
  open_center(r)
  r.t.tap_text("发送文件")
  r.t.run_for(@sf.later_ms)
  r.t.draw()
  r.t.draw()
  assert_true(r.t.find("/Users/alice/Downloads/季度报告 2.pdf") is Some(_))
  assert_true(r.t.find("/Users/alice/Downloads/notes.txt") is Some(_))
  r.t.tap_text("粘贴路径")
  assert_eq(text(Some(r.told("screen.clipboard")[0]), "text"), "/Users/alice/Downloads/季度报告 2.pdf")
  let reveals = r.t.locate("在访达中显示")
  let (rx, ry) = reveals[1]
  r.t.tap(rx, ry)
  let inputs = r.told("screen.input")
  let reveal = inputs[inputs.length() - 1]
  assert_eq(text(field(Some(reveal), "input"), "t"), "reveal")
  assert_eq(text(field(Some(reveal), "input"), "path"), "/Users/alice/Downloads/notes.txt")
  screen_done(r.t)
}

///|
/// A test's end: what moves when it ends run to its declared rest (the bar's springs as the viewer comes and goes, a
/// toast's time out then its leaving), then nothing left moving or waited on.
fn screen_done(t : @ui.Tester) -> Unit {
  // (只看/控制's thumb at rest, gone over where a state turned the view to only looking)
  t.run_for(@ui.cover_slide_ms)
  to_sheet_rest(t)
  if @sf.toast_rest("toast").unwrap_or(-1.0) > t.time() {
    t.run_for(@sf.toast_ms)
    let rest = @sf.toast_rest("toast").unwrap_or(-1.0)
    if rest > t.time() {
      t.run_for(rest - t.time())
    }
  }
  t.assert_idle()
}

///|
/// The app's words for `key`, as the page says them (@sf.t over the app's tables, sfbase's).
fn tr(key : String) -> String {
  @sf.t(key)
}

///|
/// On to where the stack's slide is over (the page put on it or taken off): the stack the shell draws, not drawn here,
/// its slide's time (@ui.move_most_ms).
fn nav_rested(t : @ui.Tester) -> Unit {
  t.draw()
  t.run_for(@ui.move_most_ms)
}

///|
test "this machine's own display is not opened from here: said so, without 重新打开; its browser's tabs and another station's display are" {
  let r = screen_rig(screen="desktop", here="ws-1/st-1")
  assert_eq(r.told("screen.view").length(), 0)
  assert_true(r.t.find("这是本机的屏幕") is Some(_))
  assert_true(r.t.find("你就在这台机器上，在这里查看它的屏幕只会看到自己。") is Some(_))
  assert_true(r.t.find("重新打开") is None)
  screen_done(r.t)
  let r = screen_rig(here="ws-1/st-1")
  assert_eq(r.told("screen.view").length(), 1)
  r.t.run_for(@sf.later_ms)
  screen_done(r.t)
  let r = screen_rig(screen="desktop", here="ws-1/st-2")
  assert_eq(r.told("screen.view").length(), 1)
  r.t.run_for(@sf.later_ms)
  screen_done(r.t)
}

///|
test "the keys row's mouse buttons click where the pointer is: 右键 a right click, 左键 a left one with ⌘ held round it" {
  let r = screen_rig()
  r.state("live", others=[], more={ "kind": "desktop" })
  r.config()
  r.frame(1000.0)
  assert_true(r.sess().pad(r.sess().src))
  // 右键: down and up of the secondary button where the trackpad's pointer is (the middle)
  r.press_key(tr("android-misc.screen.key.mouseRight"))
  let right = r.inputs()
  assert_eq(right.length(), 2)
  assert_eq(kind_of_input(right[0]), "down")
  assert_eq(number(Some(right[0]), "buttons"), btn_secondary.to_double())
  assert_true(close_to(number(Some(right[0]), "x"), 0.5))
  assert_true(close_to(number(Some(right[0]), "y"), 0.5))
  assert_eq(kind_of_input(right[1]), "up")
  // felt as it went down
  assert_eq(r.t.haptics(), [@ui.ContextClick])
  // ⌘ held, then 左键: ⌘ down, the click, ⌘ up; ⌘ let go after it
  r.press_key("Command")
  // (⌘ on the keyboard's row, 左键 on the foot once the keyboard is put away: what is held stays)
  r.tap_label(tr("android-misc.screen.keyboard"))
  r.press_key(tr("android-misc.screen.key.mouseLeft"))
  let left = r.inputs()[2:].to_owned()
  assert_eq(left.length(), 4)
  assert_eq(text(Some(left[0]), "key"), "Meta")
  assert_eq(kind_of_input(left[0]), "down")
  assert_eq(kind_of_input(left[1]), "down")
  assert_eq(number(Some(left[1]), "buttons"), btn_primary.to_double())
  assert_eq(kind_of_input(left[2]), "up")
  assert_eq(text(Some(left[3]), "key"), "Meta")
  assert_eq(kind_of_input(left[3]), "up")
  // ⌘ let go after it: the next click goes alone
  r.press_key(tr("android-misc.screen.key.mouseLeft"))
  assert_eq(r.inputs().length(), 8)
  screen_done(r.t)
}

///|
test "全屏 and sideways, driving: 左键 and 右键 in a capsule of their own over the frame's foot corner, dragged anywhere; a tap clicks where the pointer is" {
  let r = screen_rig()
  r.live(others=[])
  // sideways: over the frame's corner, without the keyboard
  r.t.resize(844.0, 390.0)
  r.t.draw()
  r.tap_label(tr("android-misc.screen.key.mouseRight"))
  let right = r.inputs()
  assert_eq(right.length(), 2)
  assert_eq(number(Some(right[0]), "buttons"), btn_secondary.to_double())
  // 全屏: the same capsule, apart from the folded tools (not opened)
  r.t.resize(390.0, 844.0)
  r.t.draw()
  open_center(r)
  r.t.tap_text("全屏")
  r.t.run_for(@motion.presence_out_ms + @sf.later_ms)
  r.t.resize(844.0, 390.0)
  r.t.draw()
  assert_true(r.ui().full.get())
  assert_true(r.labelled("退出全屏") is None)
  r.tap_label(tr("android-misc.screen.key.mouseLeft"))
  let left = r.inputs()[2:].to_owned()
  assert_eq(left.length(), 2)
  assert_eq(number(Some(left[0]), "buttons"), btn_primary.to_double())
  // each felt once, as it went down
  assert_eq(r.t.haptics(), [@ui.ContextClick, @ui.KeyboardTap])
  // held down, felt before it is let go, and not again as it is
  let (hx, hy) = r.labelled(tr("android-misc.screen.key.mouseLeft")).unwrap()
  r.t.press_at(hx, hy)
  r.t.draw()
  assert_eq(r.t.haptics().length(), 3)
  assert_eq(r.inputs().length(), 4)
  r.t.release(hx, hy)
  r.t.draw()
  assert_eq(r.t.haptics().length(), 3)
  assert_eq(r.inputs().length(), 6)
  assert_eq(r.t.squeeze_faults(), [])
  // dragged by a button of it: moved with the finger, no click sent
  let (rx, ry) = r.labelled(tr("android-misc.screen.key.mouseRight")).unwrap()
  r.t.drag(rx, ry, rx - 300.0, ry - 150.0)
  r.t.draw()
  assert_eq(r.inputs().length(), 6)
  let (mx, my) = r.labelled(tr("android-misc.screen.key.mouseRight")).unwrap()
  assert_true((mx - (rx - 300.0)).abs() < 2.0 && (my - (ry - 150.0)).abs() < 2.0, msg="moved to \{mx}, \{my}")
  // only looking: none
  r.state("live", control=false)
  r.t.draw()
  assert_true(r.labelled(tr("android-misc.screen.key.mouseLeft")) is None)
  screen_done(r.t)
}

///|
test "自动 asks again as the stage grows a tenth a side, not as it grows less or shrinks" {
  let r = screen_rig(w=1200.0, h=800.0, platform=0)
  r.live()
  let s = r.sess()
  let (w, _) = s.stage_px
  assert_true(w > 0)
  // a little larger (as a window is dragged) or smaller: nothing asked again
  r.t.resize(1230.0, 800.0)
  r.t.draw()
  r.t.resize(800.0, 600.0)
  r.t.draw()
  assert_eq(r.told("screen.bounds").length(), 0)
  assert_eq(s.stage_px.0, w)
  // much larger: asked again as large as the stage is now, the view going on
  r.t.resize(2400.0, 1600.0)
  r.t.draw()
  let asked = r.told("screen.bounds")
  assert_eq(asked.length(), 1)
  assert_true(s.stage_px.0 > w)
  assert_eq(number(Some(asked[0]), "maxWidth"), s.stage_px.0.to_double())
  assert_eq(r.told("screen.view").length(), 1)
  shut(r)
  screen_done(r.t)
}

///|
test "a page asking for a passkey while driving a tab: 用通行密钥登录; signed on this device, what it signed sent; a no told the page; none on a host without passkeys" {
  let r = screen_rig()
  r.live(others=[])
  assert_eq(r.told("screen.view")[0] is { "passkeys": False, .. }, true)
  let ask = fn(rp : String) -> Json {
    {
      "id": "7",
      "host": rp,
      "rpId": rp,
      "clientData": "{\"type\":\"webauthn.get\"}",
      "allow": ["CQk"],
      "userVerification": "required",
    }
  }
  // no passkeys on this host: nothing offered
  r.state("live", others=[], more={ "passkey": ask("github.com") })
  r.t.draw()
  assert_true(r.t.find("用通行密钥登录") is None)
  // (a host's passkeys are there from its start: the page reads them as the state comes)
  screen_fix_passkeys()
  r.state("live", others=[], more={ "passkey": ask("github.com") })
  r.t.draw()
  assert_true(r.t.find("用通行密钥登录") is Some(_))
  assert_true(r.t.find("github.com") is Some(_))
  r.tap_label("登录")
  r.t.draw()
  r.t.draw()
  // asked for the site, the client data as the station made it, the passkeys it takes (hex)
  assert_eq(@ui.fake_passkey_asks[0], ("github.com", "{\"type\":\"webauthn.get\"}", "required", "0909"))
  let signed = r.inputs().filter(fn(i) { text(Some(i), "t") == "passkey" })
  assert_eq(signed.length(), 1)
  assert_eq(text(Some(signed[0]), "id"), "7")
  assert_eq(text(Some(signed[0]), "credential"), "CQk")
  assert_eq(text(Some(signed[0]), "authenticatorData"), "q83v")
  assert_eq(text(Some(signed[0]), "signature"), "BwcH")
  assert_eq(text(Some(signed[0]), "userHandle"), "BQ")
  // answered: the station takes it away
  r.state("live", others=[])
  r.t.draw()
  assert_true(r.t.find("用通行密钥登录") is None)
  // a site the device has none for: the page told no, as a browser tells it
  r.state("live", others=[], more={ "passkey": ask("example.org") })
  r.t.draw()
  r.tap_label("登录")
  r.t.draw()
  r.t.draw()
  let no = r.inputs().filter(fn(i) { text(Some(i), "t") == "passkey" && text(Some(i), "error") != "" })
  assert_eq(no.length(), 1)
  assert_eq(text(Some(no[0]), "error"), "NotAllowedError")
  screen_done(r.t)
}

///|
/// This device's passkeys as the tests have them (the Tester's): github.com's signs (credential 09 09, its authenticator
/// data, signature and user handle); any other site's none (the person told no passkey of it here).
fn screen_fix_passkeys() -> Unit {
  @ui.fake_passkey_asks.clear()
  @ui.fake_passkey.val = Some(fn(rp, _client, _uv, _ids) {
    if rp == "github.com" {
      "0\u{1f}0909\u{1f}abcdef\u{1f}070707\u{1f}05\u{1f}\u{1f}"
    } else {
      "1\u{1f}\u{1f}\u{1f}\u{1f}\u{1f}NotAllowedError\u{1f}"
    }
  })
}

///|
/// The pointer's inputs told the screen.
fn pointers_of(r : ScreenRig) -> Array[Json] {
  r.inputs().filter(fn(j) { text(Some(j), "t") == "pointer" })
}

///|
/// Whether what is labelled `label` says it is pressed (None: it is not there).
fn pressed_of(r : ScreenRig, label : String) -> Bool? {
  for s in r.t.semantics() {
    if s.label == label && !s.hidden {
      return Some(s.pressed == Some(true))
    }
  }
  None
}

///|
test "sideways, driven directly: a tap on a drop row's 在访达中显示 over the picture is its alone, no click on the screen under it" {
  let r = screen_rig(touch="direct")
  driven(r)
  r.t.resize(844.0, 390.0)
  r.t.draw()
  screen_fix_drops(true)
  r.t.draw()
  r.t.draw()
  let (x, y) = r.labelled(tr("android-misc.screen.reveal")).unwrap()
  // (over the picture: a press there would be a click on the screen too)
  let u = r.ui()
  let sh = u.shown(r.t.ctx())
  assert_true(
    x > u.stage_xy().0 + sh.x && x < u.stage_xy().0 + sh.x + sh.w && y > u.stage_xy().1 + sh.y && y < u.stage_xy().1 + sh.y + sh.h,
    msg="\{x},\{y}",
  )
  let before = pointers_of(r).length()
  r.t.tap(x, y)
  r.t.draw()
  assert_eq(pointers_of(r).length(), before)
  assert_eq(r.inputs().filter(fn(j) { text(Some(j), "t") == "reveal" }).length(), 1)
  // held there: no right click either
  r.t.press_at(x, y)
  r.t.run_for(screen_hold_ms)
  r.t.release(x, y)
  r.t.draw()
  assert_eq(pointers_of(r).length(), before)
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "a modifier held on the keys row goes round what a press on the stage clicks or drags, then is let go" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  let meta = fn(j : Json, kind : String) { text(Some(j), "key") == "Meta" && kind_of_input(j) == kind }
  // a tap: ⌘ down, the click, ⌘ up
  r.press_key("Command")
  assert_eq(r.ui().held.mods, mod_meta)
  r.tap_at(0.5, 0.5)
  let tap = r.inputs()
  assert_eq(tap.length(), 4)
  assert_true(meta(tap[0], "down"))
  assert_eq(kind_of_input(tap[1]), "down")
  assert_eq(kind_of_input(tap[2]), "up")
  assert_true(meta(tap[3], "up"))
  assert_eq(r.ui().held.mods, 0)
  assert_true(pressed_of(r, tr("android-misc.screen.key.command")) != Some(true))
  // the next tap goes alone
  r.t.run_for(screen_double_tap_ms)
  r.tap_at(0.5, 0.5)
  assert_eq(r.inputs().length(), 6)
  // a drag: ⇧ down before its button, up after it lets go
  r.press_key(tr("android-misc.screen.key.shift"))
  let from = r.inputs().length()
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.6, 0.5)
  r.t.drag(ax, ay, bx, by)
  let drag = r.inputs()[from:].to_owned()
  assert_eq(text(Some(drag[0]), "key"), "Shift")
  assert_eq(kind_of_input(drag[0]), "down")
  assert_eq(kind_of_input(drag[1]), "down")
  assert_eq(kind_of_input(drag[drag.length() - 2]), "up")
  assert_eq(text(Some(drag[drag.length() - 1]), "key"), "Shift")
  assert_eq(kind_of_input(drag[drag.length() - 1]), "up")
  // held: a right click with ⌥ round it
  r.press_key(tr("android-misc.screen.key.option"))
  let from = r.inputs().length()
  let (hx, hy) = r.at(0.5, 0.5)
  r.t.press_at(hx, hy)
  r.t.run_for(screen_hold_ms)
  r.t.release(hx, hy)
  let held = r.inputs()[from:].to_owned()
  assert_eq(held.length(), 4)
  assert_eq(text(Some(held[0]), "key"), "Alt")
  assert_eq(number(Some(held[1]), "buttons"), btn_secondary.to_double())
  assert_eq(text(Some(held[3]), "key"), "Alt")
  assert_eq(kind_of_input(held[3]), "up")
  assert_eq(r.ui().held.mods, 0)
  screen_done(r.t)
}

///|
test "a modifier held on the keys row goes round the trackpad's click and its two fingers' right click" {
  let r = screen_rig()
  r.state("live", others=[], more={ "kind": "desktop" })
  r.config()
  r.frame(1000.0)
  assert_true(r.sess().pad(r.sess().src))
  r.press_key("Command")
  r.tap_at(0.5, 0.5)
  let tap = r.inputs()
  assert_eq(tap.length(), 4)
  assert_eq(text(Some(tap[0]), "key"), "Meta")
  assert_eq(kind_of_input(tap[1]), "down")
  assert_eq(text(Some(tap[3]), "key"), "Meta")
  assert_eq(r.ui().held.mods, 0)
  r.t.run_for(screen_double_tap_ms)
  r.press_key(tr("android-misc.screen.key.control"))
  let from = r.inputs().length()
  let (p1x, p1y) = r.at(0.3, 0.5)
  let (p2x, p2y) = r.at(0.6, 0.5)
  r.t.press_at(p1x, p1y)
  r.t.touch(4, p2x, p2y)
  r.t.draw()
  r.t.touch(6, p2x, p2y)
  r.t.release(p1x, p1y)
  let right = r.inputs()[from:].to_owned()
  assert_eq(right.length(), 4)
  assert_eq(text(Some(right[0]), "key"), "Control")
  assert_eq(number(Some(right[1]), "buttons"), btn_secondary.to_double())
  assert_eq(text(Some(right[3]), "key"), "Control")
  assert_eq(r.ui().held.mods, 0)
  screen_done(r.t)
}

///|
test "a modifier held on the keys row is let go as the view stops driving: 只看 and back to 控制 finds none held" {
  let r = screen_rig()
  r.live(others=[])
  r.press_key("Command")
  assert_eq(r.ui().held.mods, mod_meta)
  look_switch(r)
  r.state("live", control=false, others=[])
  assert_eq(r.ui().held.mods, 0)
  look_switch(r)
  r.state("live", control=true, others=[])
  r.t.draw()
  assert_true(pressed_of(r, tr("android-misc.screen.key.command")) != Some(true))
  assert_eq(r.ui().held.mods, 0)
  // a key typed now goes alone
  r.press_key("Tab")
  let last = r.inputs()[r.inputs().length() - 1]
  assert_eq(number(Some(last), "mods"), 0.0)
  screen_done(r.t)
}

///|
test "zoomed in, driven directly: two fingers moving together pan the picture here, nothing sent; fitted, they scroll the screen" {
  let r = screen_rig(touch="direct")
  r.state("live", control=false, others=[])
  r.config()
  r.frame(1000.0)
  let u = r.ui()
  r.tap_at(0.5, 0.5)
  r.tap_at(0.5, 0.5)
  r.t.run_for(@ui.move_most_ms)
  assert_true(u.zoom.zoomed_at(r.t.time()))
  r.state("live", control=true, others=[])
  r.t.run_for(screen_double_tap_ms)
  let two = fn(cx : Double, cy : Double) {
    r.t.press_at(cx - 50.0, cy)
    r.t.touch(4, cx + 50.0, cy)
    r.t.draw()
    for i in [1, 2, 3, 4, 5, 6] {
      let d = i.to_double() * 20.0
      r.t.touch(1, cx - 50.0 + d, cy)
      r.t.touch(5, cx + 50.0 + d, cy)
      r.t.draw()
    }
    r.t.touch(6, cx + 50.0 + 120.0, cy)
    r.t.release(cx - 50.0 + 120.0, cy)
    r.t.run_for(@ui.move_most_ms)
  }
  let rect0 = u.shown(r.t.ctx())
  let before = r.inputs().length()
  two(195.0, 400.0)
  let rect1 = u.shown(r.t.ctx())
  assert_true(rect1.x - rect0.x > 60.0, msg="\{rect0.x} → \{rect1.x}")
  assert_eq(r.inputs().length(), before)
  // fitted again: they scroll the screen
  u.zoom.fit_now(at=r.t.ctx().moment())
  r.t.run_for(@ui.move_most_ms)
  assert_false(u.zoom.zoomed_at(r.t.time()))
  let (mx, my) = r.at(0.4, 0.5)
  two(mx, my)
  assert_true(r.inputs()[before:].iter().any(fn(j) { text(Some(j), "t") == "wheel" }))
  screen_done(r.t)
}

///|
test "左键 driven directly with no pointer said by the station: clicks where the last tap was, not the middle" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  assert_true(r.sess().cursor() is None)
  r.tap_at(0.25, 0.75)
  r.t.run_for(screen_double_tap_ms)
  let from = r.inputs().length()
  // (directly, the foot has no 左键 since 2026-11-13: a tap clicks; the floating buttons, sideways, click so)
  button_clicked(r.sess(), r.ui(), btn_primary)
  r.t.draw()
  let left = r.inputs()[from:].to_owned()
  assert_eq(left.length(), 2)
  assert_true(close_to(number(Some(left[0]), "x"), 0.25), msg="\{number(Some(left[0]), "x")}")
  assert_true(close_to(number(Some(left[0]), "y"), 0.75))
  screen_done(r.t)
}

///|
test "the keyboard's button by where the keys go: on while they come here, the soft keyboard up or not; pressed again, let go" {
  let r = screen_rig()
  r.live(others=[])
  // (a keyboard plugged in: no soft keyboard comes up)
  r.tap_label("键盘")
  assert_true(r.t.key_catching())
  assert_eq(pressed_of(r, "键盘"), Some(true))
  r.tap_label("键盘")
  assert_false(r.t.key_catching())
  assert_eq(pressed_of(r, "键盘"), Some(false))
  screen_done(r.t)
}

///|
test "sideways, the rail's people button only while others are on it, named so; pressed, the line said" {
  let r = screen_rig()
  r.live(others=[])
  r.t.resize(844.0, 390.0)
  r.t.draw()
  assert_true(r.labelled(tr("android-misc.screen.people")) is None)
  assert_true(r.labelled("控制") is Some(_))
  r.state("live", others=["李雷"])
  r.t.draw()
  r.tap_label(tr("android-misc.screen.people"))
  assert_true(r.t.find("控制 · 李雷也在看") is Some(_))
  r.t.run_for(rail_say_ms)
  screen_done(r.t)
}

///|
/// 只看 turned the other way in 控制中心 (where it is since 2026-11-13: off the viewer's bar), the panel closed again.
fn look_switch(r : ScreenRig) -> Unit {
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  r.t.click(Switch, label=tr("android-misc.screen.look"))
  r.t.draw()
  r.t.key(@ui.key_escape)
  r.t.run_for(@sf.later_ms)
}

///|
test "beside its chat on its side with touch (an iPhone Duo's side panel): a browser's tab has its bar over the picture, ← → ⟳ and its whole address, the tabs' button after it" {
  let r = screen_rig(w=951.0, h=669.0, platform=1, screen="browser:u_mail", screens=browser_screens(), in_tab=true)
  r.state(
    "live",
    others=[],
    more={
      "kind": Json::string("browser"),
      "openUrl": Json::boolean(true),
      "userTab": Json::boolean(true),
      "title": Json::string("收件箱 - Proton Mail"),
      "address": Json::string("https://mail.proton.me/u/0/inbox"),
    },
  )
  r.config()
  r.frame(1000.0)
  // (sideways: the rail down its side)
  assert_true(r.labelled(tr("android-misc.screen.full")) is Some(_))
  assert_eq(address_of("browser:u_mail"), "https://mail.proton.me/u/0/inbox", msg="its whole address in its bar")
  for label in ["web-pages.screen.back", "web-pages.screen.forward", "web-pages.screen.reload"] {
    assert_true(r.labelled(tr(label)) is Some(_), msg=label)
  }
  assert_true(r.labelled(tr("web-pages.screen.tabs") + " 3") is Some(_), msg="all browser pages folded into a button")
  // (→ and ⟳ on its bar: 控制中心 offers them no second time)
  assert_false(r.ui().narrow_bar)
  assert_eq(r.t.audit(), [])
  screen_done(r.t)
}

///|
test "用 1Password 填入: always has a close button, closing dismisses the focused field on its page until focus moves, and filled fields do not prompt" {
  let r = screen_rig()
  r.live(others=[])
  screen_fix_one_password()
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/login",
      "login": { "host": "account.line.biz", "field": "password" },
    },
  )
  let card_closes = fn() {
    r.t.semantics().filter(fn(s) { s.label == tr("common.close") && !s.hidden && s.rect.1 > 200.0 })
  }
  let dismiss_card = fn() raise {
    let cs = card_closes()
    assert_eq(cs.length(), 1)
    let (x, y, w, h) = cs[0].rect
    r.t.tap(x + w / 2.0, y + h / 2.0)
    r.t.draw()
  }
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))
  assert_eq(card_closes().length(), 1)
  assert_eq(r.t.audit(), [])

  // Closing hides the offer for this field on this page, even across unrelated state updates.
  dismiss_card()
  assert_true(r.t.find("用 1Password 填入") is None)
  r.state(
    "live",
    others=["李雷"],
    more={
      "address": "https://account.line.biz/login",
      "login": { "host": "account.line.biz", "field": "password" },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is None)

  // Moving focus to another login field offers again; dismissing it and leaving focus resets dismissal.
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/login",
      "login": { "host": "account.line.biz", "field": "username" },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))
  dismiss_card()
  assert_true(r.t.find("用 1Password 填入") is None)
  r.state("live", others=[], more={ "address": "https://account.line.biz/login" })
  r.t.draw()
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/login",
      "login": { "host": "account.line.biz", "field": "username" },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))

  // Dismissing on one URL re-offers if the tab navigates to another URL.
  dismiss_card()
  assert_true(r.t.find("用 1Password 填入") is None)
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/reauth",
      "login": { "host": "account.line.biz", "field": "username" },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))

  // A field that already holds a value (filled by an agent or typed) does not prompt.
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/reauth",
      "login": { "host": "account.line.biz", "field": "password", "filled": true },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is None)
  r.state(
    "live",
    others=[],
    more={
      "address": "https://account.line.biz/reauth",
      "login": { "host": "account.line.biz", "field": "password" },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用 1Password 填入") is Some(_))
  screen_done(r.t)
  @ui.fake_op.val = None
}

///|
test "a screen left covered by a background tab opens at once when mounted in another tab" {
  let r = screen_rig(in_tab=true)
  let s = r.sess()
  assert_eq(r.told("screen.view").length(), 1)
  // Simulate a backgrounded remote workbench tab leaving covered=true on the shared ScreenUi.
  let key = screen_key("ws-1/st-1", "browser:tab-1")
  screen_lease_apply_hidden(s.src, key)
  r.t.draw()
  assert_eq(r.cancelled.length(), 1)
  assert_true(r.ui().covered.get())
  // Mounting the screen in a tab clears stale covered state and opens screen.view immediately.
  app.nav.push(Screen({ station: "ws-1/st-1", screen: "browser:tab-2", title: "Other", until_gone: false }))
  nav_rested(r.t)
  screen_ui(screen_key("ws-1/st-1", "browser:tab-1")).covered.set(true)
  app.nav.pop() |> ignore
  nav_rested(r.t)
  assert_false(screen_ui(screen_key("ws-1/st-1", "browser:tab-1")).covered.get())
  assert_eq(r.told("screen.view").length(), 3)
  screen_done(r.t)
}

///|
test "switching browser tabs keeps the fitted or manually zoomed picture" {
  for zoomed in [false, true] {
    let r = screen_rig(w=900.0, h=600.0, platform=0, in_tab=true, keep_screen=true)
    r.live()
    let u = screen_ui(screen_key("ws-1/st-1", "browser:tab-1"))
    if zoomed {
      u.zoom.zoom_to(u.zoom.fit() * 2.0, u.box_w.get() / 2.0, u.box_h.get() / 2.0, false, at=r.t.time())
      r.t.draw()
    }
    let before = u.shown(r.t.ctx())
    assert_eq(u.zoom.zoomed_at(r.t.time()), zoomed)
    for _ in 0..<3 {
      app.nav.push(Screen({ station: "ws-1/st-1", screen: "browser:tab-2", title: "Other", until_gone: false }))
      nav_rested(r.t)
      app.nav.pop() |> ignore
      nav_rested(r.t)
      let after = u.shown(r.t.ctx())
      assert_true(close_to(before.x, after.x) && close_to(before.y, after.y))
      assert_true(close_to(before.w, after.w) && close_to(before.h, after.h), msg="before \{before.w}×\{before.h}, after \{after.w}×\{after.h}")
      assert_eq(u.zoom.zoomed_at(r.t.time()), zoomed)
    }
    assert_eq(r.t.audit(), [])
    screen_done(r.t)
  }
}

///|
test "a screen keeps its fitted size when its stage temporarily has no height" {
  let r = screen_rig(w=900.0, h=600.0, platform=0, in_tab=true)
  r.live()
  let u = r.ui()
  let before = u.shown(r.t.ctx())
  r.t.resize(900.0, 1.0)
  r.t.draw()
  r.t.resize(900.0, 600.0)
  r.t.draw()
  let after = u.shown(r.t.ctx())
  assert_true(close_to(before.w, after.w) && close_to(before.h, after.h))
  assert_false(u.zoom.zoomed_at(r.t.time()))
  screen_done(r.t)
}

///|
test "browser tab bar with keyboard and mouse, passkey close button, and blocked agent-operating prompt" {
  // 1. In a wide window, a chat side-panel browser tab shows ← → ⟳ directly on its bar.
  let r = screen_rig(w=1100.0, h=760.0, screen="browser:tab-1", in_tab=true)
  r.state(
    "live",
    others=[],
    more={
      "kind": Json::string("browser"),
      "openUrl": Json::boolean(true),
      "title": Json::string("Welcome"),
      "address": Json::string("https://accounts.google.com/v3/signin/challenge/pk"),
    },
  )
  r.config()
  r.frame(1000.0)
  for label in ["web-pages.screen.back", "web-pages.screen.forward", "web-pages.screen.reload"] {
    assert_true(r.labelled(tr(label)) is Some(_), msg=label)
  }
  assert_false(r.ui().narrow_bar)

  // 2. 用通行密钥登录 always has a close button (×), and pressing it dismisses the card and sends NotAllowedError.
  screen_fix_passkeys()
  r.state(
    "live",
    others=[],
    more={
      "kind": Json::string("browser"),
      "openUrl": Json::boolean(true),
      "address": Json::string("https://accounts.google.com/v3/signin/challenge/pk"),
      "passkey": {
        "id": "pk-1",
        "host": "accounts.google.com",
        "rpId": "google.com",
        "clientData": "{\"type\":\"webauthn.get\"}",
        "allow": [],
        "userVerification": "preferred",
      },
    },
  )
  r.t.draw()
  assert_true(r.t.find("用通行密钥登录") is Some(_))
  let closes = r.t.semantics().filter(fn(s) { s.label == tr("common.close") && !s.hidden && s.rect.1 > 200.0 })
  assert_eq(closes.length(), 1)
  let (cx, cy, cw, ch) = closes[0].rect
  r.t.tap(cx + cw / 2.0, cy + ch / 2.0)
  r.t.draw()
  assert_true(r.t.find("用通行密钥登录") is None)
  let cancelled = r.inputs().filter(fn(i) { text(Some(i), "t") == "passkey" && text(Some(i), "error") == "NotAllowedError" })
  assert_eq(cancelled.length(), 1)
  assert_eq(text(Some(cancelled[0]), "id"), "pk-1")

  // 3. While an agent operates the browser (watch-only: openUrl omitted, address kept), the browser bar stays visible
  //    in read-only mode (no height jump), and clicking the picture sends no pointer input and nudges the 接管 capsule.
  let addr_rect = fn() {
    r.t.semantics().filter(fn(s) { s.label == tr("web-pages.screen.addressHint") && !s.hidden })[0].rect
  }
  let bar_before = addr_rect()
  r.state(
    "live",
    control=false,
    take_over=true,
    controllers=["Agent「查询 Google 账号」"],
    line="只看 · Agent「查询 Google 账号」 正在控制",
    more={
      "kind": Json::string("browser"),
      "address": Json::string("https://accounts.google.com/"),
    },
  )
  r.t.draw()
  assert_true(r.t.find("Agent「查询 Google 账号」 正在控制") is Some(_))
  assert_true(r.labelled(tr("android-misc.screen.takeOver")) is Some(_))
  let addr_ro = addr_rect()
  assert_eq(addr_ro.1, bar_before.1)
  assert_eq(addr_ro.3, bar_before.3)
  let (rx, ry) = r.labelled(tr("web-pages.screen.reload")).unwrap()
  r.t.tap(rx, ry)
  r.t.draw()
  assert_eq(r.told("screen.reload").length(), 0)
  assert_eq(r.ui().held_nudge.get(), 0)
  let before_ptr = pointers_of(r).length()
  let (px, py) = r.at(0.5, 0.5)
  r.t.tap(px, py)
  r.t.run_for(@sf.later_ms + 20.0)
  assert_eq(pointers_of(r).length(), before_ptr)
  assert_eq(r.ui().held_nudge.get(), 1)
  r.t.run_for(@sf.refused_ms)
  assert_eq(r.t.idle_said(), None)
  screen_done(r.t)
}

///|
/// The screen's virtual microphone as its station says it while this viewer drives it (`mic`): recorded there now or
/// not, a desktop's.
fn mic_said(r : ScreenRig, active : Bool, control? : Bool = true) -> Unit {
  let more : Map[String, Json] = { "kind": Json::string("desktop") }
  // (the core says none while only looking)
  if control {
    more["mic"] = { "available": true, "active": active, "epoch": 1.0 }
  }
  r.state("live", control~, others=[], more~)
  // (the bar's 麦克风 coming or going along its row, to its end)
  r.t.run_for(@ui.move_most_ms)
}

///|
test "麦克风 on the bar only while something on the screen records it or this device's is shared: pressed, shared and told the core; opened again, told again" {
  // (a browser's: its microphone taken, web/src/mbui/screen-peripherals.ts)
  let r = screen_rig(platform=4)
  r.live(others=[])
  let asked = tr("web-pages.screen.micAsked")
  let on = tr("web-pages.screen.micMute")
  let off = tr("web-pages.screen.micUnmute")
  let none = fn() { r.labelled(asked) is None && r.labelled(on) is None && r.labelled(off) is None }
  // a screen with no virtual microphone, and one nobody records: nothing on the bar
  assert_true(none())
  mic_said(r, false)
  assert_true(none())
  // recorded there: on the bar, not lit, saying so
  mic_said(r, true)
  assert_eq(pressed_of(r, asked), Some(false))
  assert_eq(r.t.audit(), [])
  // pressed: shared, lit, told the core
  r.tap_label(asked)
  r.t.draw()
  let s = r.sess()
  assert_true(s.mic_on.get())
  assert_eq(pressed_of(r, on), Some(true))
  assert_eq(r.told("screen.micOn").last().unwrap().stringify(), "{\"view\":\"" + s.view + "\",\"on\":true}")
  // the recording over: there still while shared, to switch it off
  mic_said(r, false)
  assert_eq(pressed_of(r, on), Some(true))
  // only looking: gone, shared still (the core sends nothing meanwhile)
  mic_said(r, true, control=false)
  assert_true(none())
  mic_said(r, true)
  assert_eq(pressed_of(r, on), Some(true))
  // let go of out of sight and opened again: told again once the view says it is there, not before
  let told = r.told("screen.micOn").length()
  s.pause(s.src)
  s.open(s.src)
  assert_eq(r.told("screen.micOn").length(), told)
  mic_said(r, true)
  assert_eq(r.told("screen.micOn").length(), told + 1)
  assert_true(r.told("screen.micOn").last().unwrap().stringify().contains("\"on\":true"))
  // pressed again: no more, told so; the bar saying the app there records it
  r.tap_label(on)
  r.t.draw()
  assert_false(s.mic_on.get())
  assert_true(r.told("screen.micOn").last().unwrap().stringify().contains("\"on\":false"))
  assert_eq(pressed_of(r, asked), Some(false))
  // its recording over, nothing shared: gone from the bar
  mic_said(r, false)
  assert_true(none())
  screen_done(r.t)
}

///|
test "麦克风 in the viewer's bar with keyboard and mouse: there as on the phone's, lit while shared" {
  let r = screen_rig(w=1280.0, h=800.0, platform=0)
  r.live(others=[])
  let asked = tr("web-pages.screen.micAsked")
  let on = tr("web-pages.screen.micMute")
  assert_true(r.labelled(asked) is None)
  mic_said(r, true)
  assert_eq(pressed_of(r, asked), Some(false))
  assert_eq(r.t.audit(), [])
  r.tap_label(asked)
  r.t.draw()
  assert_eq(pressed_of(r, on), Some(true))
  assert_true(r.told("screen.micOn").last().unwrap().stringify().contains("\"on\":true"))
  assert_eq(r.t.audit(), [])
  screen_done(r.t)
}

///|
test "a copy a password manager marked on the screen lands on the device's clipboard as a secret: concealed taken off after a while, transient kept, auto as any words" {
  let r = screen_rig()
  driven(r)
  r.say({ "clipboard": { "type": "text", "text": "hunter2", "privacy": "concealed" } })
  assert_eq(r.t.clipboard(), "hunter2")
  assert_eq(r.t.clipboard_secret(), Some(@sf.secret_copied_life))
  r.t.run_for(@sf.secret_copied_life)
  assert_eq(r.t.clipboard(), "")
  assert_eq(r.t.clipboard_secret(), None)
  // words an app made up: as any
  r.say({ "clipboard": { "type": "text", "text": "made up", "privacy": "auto" } })
  assert_eq(r.t.clipboard(), "made up")
  assert_eq(r.t.clipboard_secret(), None)
  // not to be kept: a secret, left there
  r.say({ "clipboard": { "type": "text", "text": "one-time 123456", "privacy": "transient" } })
  assert_eq(r.t.clipboard(), "one-time 123456")
  assert_eq(r.t.clipboard_secret(), Some(0.0))
  r.t.run_for(@sf.secret_copied_life)
  assert_eq(r.t.clipboard(), "one-time 123456")
  screen_done(r.t)
}

///|
test "no 麦克风 where this device's microphone is not taken (an Android phone's): neither on the bar nor in 控制中心" {
  let r = screen_rig()
  r.live(others=[])
  mic_said(r, true)
  assert_false(r.sess().mic_available())
  assert_true(r.labelled(tr("web-pages.screen.micAsked")) is None)
  open_center(r)
  assert_true(r.labelled(tr("web-pages.screen.mic")) is None)
  shut(r)
  screen_done(r.t)
}

///|
test "remote-screen floating notice cards keep full text, first-line alignment, and concentric corners across locales and scales" {
  // 1. login_fill_node in `said` state (1Password CLI notice): zh (desktop + phone + narrow + 1.3x) and en (phone)
  let cases : Array[(Double, Double, Int, String?, Double, String)] = [
    (1280.0, 800.0, 0, None, 1.0, "集成"),
    (390.0, 844.0, 2, None, 1.0, "集成"),
    (390.0, 844.0, 2, None, 1.3, "集成"),
    (320.0, 640.0, 2, None, 1.0, "集成"),
    (390.0, 844.0, 2, Some("en"), 1.0, "Developer"),
  ]
  for c in cases {
    let (w, h, platform, lang, scale, tail_word) = c
    let r = screen_rig(w~, h~, platform~)
    @sf.set_language(lang)
    @ui.fake_op.val = Some(fn(_) { (-1, "", "") })
    if scale != 1.0 {
      r.t.set_font_scale(scale)
    }
    r.state(
      "live",
      others=[],
      more={
        "kind": Json::string("browser"),
        "address": Json::string("https://github.com/login"),
        "login": { "host": "github.com", "field": "password" },
      },
    )
    r.config()
    r.frame(1000.0)
    r.sess().fill_host = "github.com"
    r.sess().fill_said(tr("android-misc.screen.fill.noOp"))
    r.t.draw()
    // Full multi-line message shown without truncation (no max_lines=2 clip)
    assert_true(r.t.find(tail_word) is Some(_), msg="missing '\{tail_word}' at \{w}x\{h} scale=\{scale}")
    assert_eq(r.t.audit(), [])
    assert_eq(r.t.corner_faults(), [])
    assert_eq(r.t.first_line_faults(), [])
    assert_eq(r.t.squeeze_faults(), [])
    // Dismissing clears the notice cleanly
    let closes = r.t.semantics().filter(fn(s) { s.label == tr("common.close") && !s.hidden && s.rect.1 > 200.0 })
    assert_eq(closes.length(), 1)
    let (cx, cy, cw, ch) = closes[0].rect
    r.t.tap(cx + cw / 2.0, cy + ch / 2.0)
    r.t.draw()
    assert_true(r.t.find(tail_word) is None)
    @ui.fake_op.val = None
    screen_done(r.t)
  }
  @sf.set_language(None)

  // 2. login_fill_node waiting (`listing`) state: compact single-row capsule, no empty vertical bloat
  {
    let r = screen_rig(w=390.0, h=844.0, platform=2)
    @ui.fake_op.val = Some(fn(_) { (-1, "", "") })
    r.state(
      "live",
      others=[],
      more={
        "kind": Json::string("browser"),
        "address": Json::string("https://github.com/login"),
        "login": { "host": "github.com", "field": "password" },
      },
    )
    r.config()
    r.frame(1000.0)
    r.sess().fill_host = "github.com"
    r.sess().fill_step.set("listing")
    r.t.draw()
    assert_eq(r.t.audit(), [])
    assert_eq(r.t.corner_faults(), [])
    assert_eq(r.t.first_line_faults(), [])
    assert_eq(r.t.squeeze_faults(), [])
    @ui.fake_op.val = None
    screen_done(r.t)
  }

  // 3. passkey_sign_node in `said` error state: uses shared notice row, clean audit + dismissible
  {
    let r = screen_rig(w=390.0, h=844.0, platform=2)
    screen_fix_passkeys()
    r.state(
      "live",
      others=[],
      more={
        "kind": Json::string("browser"),
        "address": Json::string("https://github.com/login"),
        "passkey": {
          "id": "pk-err",
          "host": "github.com",
          "rpId": "github.com",
          "clientData": "{\"type\":\"webauthn.get\"}",
          "allow": [],
          "userVerification": "preferred",
        },
      },
    )
    r.config()
    r.frame(1000.0)
    let err_msg = @sf.t("android-misc.screen.passkey.failed", args=[("why", "webauthn.dll")])
    r.sess().passkey_note = err_msg
    r.sess().passkey_step.set("said")
    r.t.draw()
    assert_true(r.t.find("webauthn.dll") is Some(_))
    assert_eq(r.t.audit(), [])
    assert_eq(r.t.corner_faults(), [])
    assert_eq(r.t.first_line_faults(), [])
    assert_eq(r.t.squeeze_faults(), [])
    screen_done(r.t)
  }

  // 4. undriven_box with long multi-line message: top-aligned icon on first line, zero faults
  {
    let r = screen_rig(w=390.0, h=844.0, platform=2)
    r.state(
      "live",
      control=false,
      may=false,
      others=[],
      message="当前屏幕处于受限状态，请先在目标机器的「系统设置 › 隐私与安全性 › 辅助功能」里勾选允许控制后再试",
    )
    r.config()
    r.frame(1000.0)
    assert_eq(r.t.audit(), [])
    assert_eq(r.t.corner_faults(), [])
    assert_eq(r.t.first_line_faults(), [])
    assert_eq(r.t.squeeze_faults(), [])
    screen_done(r.t)
  }
}

///|
test "screen_view 1s stats tick clears timeline when parked and resets fps/bps baseline on wake (no spike)" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.workspace_owner_set("ws-1", "u1")
  let view_cbs : Array[(Json, Bytes?) -> Unit] = []
  let next_call = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, on_val, _done) {
      if name == "screen.view" {
        next_call.val += 1
        view_cbs.push(on_val)
        next_call.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:tab-stats", title: "Stats", until_gone: false }
  let active = @signals.signal(true)
  let screen_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick_kept(at_once=true, fn() { active.get() }, fn(slot, on) {
        if on {
          screen_root.val = Some(slot)
          slot.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          screen_node(slot, src, at, fn() { @sf.no_frame })
        }
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(view_cbs.length(), 1)
  (view_cbs[0])({ "state": { "phase": "live", "control": true, "may": true, "others": [] } }, None)
  t.draw()
  let s = screens_open.get(screen_key(at.station, at.screen)).unwrap()
  let u = screen_uis.get(screen_key(at.station, at.screen)).unwrap()
  let sv = screen_root.val.unwrap()
  assert_true(t.subtree_timeline_count(sv) > 0, msg="live screen_view should have 1s stats tick active")
  // Feed 10 frames / 1000 bytes and advance 1s.
  s.frames += 10
  s.bytes += 1000
  t.run_for(second_ms)
  assert_eq(u.fps, Some(10.0))
  assert_eq(u.bps, Some(8000.0))
  let seen_before_park = u.seen.untracked()
  // Park -> 0 timeline entries.
  active.set(false)
  t.draw()
  assert_eq(
    t.subtree_timeline_count(sv),
    0,
    msg="parked screen_view must have 0 timeline entries, got: \{Repr(t.subtree_timeline_bys(sv))}",
  )
  // Simulate 500 frames / 50000 bytes accumulating while parked over 5s.
  s.frames += 500
  s.bytes += 50000
  t.run_for(second_ms * 5.0)
  assert_eq(u.seen.untracked(), seen_before_park, msg="stats tick must not fire while parked")
  // Wake -> baseline resets to current frames/bytes and stale fps/bps cleared to None; only post-wake frames count.
  active.set(true)
  t.draw()
  assert_eq(u.rate_frames, s.frames, msg="wake must reset rate_frames baseline")
  assert_eq(u.rate_bytes, s.bytes, msg="wake must reset rate_bytes baseline")
  assert_true(u.fps is None, msg="wake must clear stale fps before first post-wake interval")
  assert_true(u.bps is None, msg="wake must clear stale bps before first post-wake interval")
  s.frames += 5
  s.bytes += 500
  t.run_for(second_ms)
  assert_eq(u.fps, Some(5.0), msg="fps after wake must reflect only post-wake frames, not accumulated spike")
  assert_eq(u.bps, Some(4000.0), msg="bps after wake must reflect only post-wake bytes, not accumulated spike")
  @ui.run_let_go()
}

///|
test "passkey request completes while briefly covered, cancels on owner destroy or account revocation, and has 0 timers when idle" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.account_principal_set("acct-passkey-a")
  let ready = Ref(false)
  let inputs : Array[Json] = []
  let base = @sffixture.fixture("settings")
  @sfbase.workspace_owner_set("ws-1", "acct-passkey-a")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.push(params)
      }
      done(Ok(Json::null()))
    },
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" { 1 } else { 0 }
    },
    cancel: fn(_) {  },
  }
  let s = screen_sess(src, "ws-1/st-1", "browser:pk-1")
  s.call = 1
  s.heard = true
  s.state = Some({
    "phase": "live",
    "control": true,
    "may": true,
    "others": [],
    "passkey": {
      "id": "pk-1",
      "host": "github.com",
      "rpId": "github.com",
      "clientData": "{\"type\":\"webauthn.get\"}",
      "allow": ["0909"],
      "userVerification": "required",
    },
  })
  let mounted = @signals.signal(true)
  let pk_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick_kept(at_once=true, fn() { mounted.get() }, fn(slot, on) {
        if on {
          pk_root.val = Some(slot)
          passkey_sign_node(slot, s)
        }
      })
    },
    w=800.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  @ui.fake_passkey_asks.clear()
  @ui.fake_passkey.val = Some(fn(_rp, _client, _uv, _ids) {
    if ready.val {
      "0\u{1f}0909\u{1f}abcdef\u{1f}070707\u{1f}05\u{1f}\u{1f}"
    } else {
      ""
    }
  })
  let pv = pk_root.val.unwrap()
  // Idle passkey_sign_node has 0 timeline entries.
  assert_eq(t.subtree_timeline_count(pv), 0, msg="idle passkey_sign_node must have 0 timeline entries")
  // Start request, then briefly cover/park the container -> request MUST NOT pause and completes when host finishes.
  s.passkey_start()
  t.draw()
  assert_true(s.passkey_run is Some(_))
  mounted.set(false)
  t.draw()
  ready.val = true
  t.run_for(passkey_look_ms * 2.0)
  assert_eq(inputs.length(), 1, msg="in-flight passkey request must complete while briefly covered")
  assert_true(s.passkey_run is None)
  // Start a new request, then revoke via account switch -> cancels native handle and rejects late completion (0 extra inputs).
  mounted.set(true)
  t.draw()
  ready.val = false
  s.passkey_start()
  t.draw()
  assert_true(s.passkey_run is Some(_))
  let old_gen = s.passkey_gen
  let old_principal = s.passkey_owner_principal
  @sfbase.account_principal_set("acct-passkey-b")
  assert_true(s.revoked, msg="account switch must revoke old screen session")
  assert_true(s.passkey_run is None, msg="account switch must cancel native passkey handle")
  ready.val = true
  s.passkey_took(old_gen, old_principal)
  t.run_for(passkey_look_ms * 2.0)
  assert_eq(inputs.length(), 1, msg="revoked passkey request must deliver 0 inputs")
  @ui.fake_passkey.val = None
  @ui.run_let_go()
}

///|
test "multi-holder screen lease preserves stream across handoff, pauses on last leave, and isolates two accounts on same workspace+screen" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.account_principal_set("acct-a")
  let opens : Array[Json] = []
  let cancelled : Array[Int] = []
  let inputs : Array[Json] = []
  let view_cbs : Array[(Json, Bytes?) -> Unit] = []
  let next_call = Ref(0)
  let base = @sffixture.fixture("settings")
  @sfbase.workspace_owner_set("ws-1", "acct-a")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.push(params)
      }
      done(Ok(Json::null()))
    },
    stream: fn(name, params, _bytes, on_val, _done) {
      if name == "screen.view" {
        next_call.val += 1
        opens.push(params)
        view_cbs.push(on_val)
        next_call.val
      } else {
        0
      }
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:shared-1", title: "Shared", until_gone: false }
  let show_side = @signals.signal(true)
  let show_full = @signals.signal(false)
  let show_remote = @signals.signal(false)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      // Holder 1: side panel
      root.show(at_once=true, fn() { show_side.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame }, in_tab=true)
      })
      // Holder 2: fullscreen
      root.show(at_once=true, fn() { show_full.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame })
      })
      // Holder 3: Place("remote") parked via pick_kept
      root.pick_kept(at_once=true, fn() { show_remote.get() }, fn(p, on) {
        if on {
          p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          screen_pane_node(p, src, at, fn() { @sf.no_frame }, in_tab=true)
        }
      })
    },
    w=1000.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(opens.length(), 1, msg="initial side-panel holder opens 1 stream")
  assert_eq(cancelled.length(), 0)
  // Handoff 1: side panel -> fullscreen in the same batch: stream stays live (0 cancels, still 1 open).
  show_side.set(false)
  show_full.set(true)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 0, msg="side-panel -> fullscreen handoff must not pause stream")
  assert_eq(opens.length(), 1)
  // Handoff 2: fullscreen -> Place("remote") in the same batch: stream stays live (0 cancels, still 1 open).
  show_full.set(false)
  show_remote.set(true)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 0, msg="fullscreen -> Place(remote) handoff must not pause stream")
  assert_eq(opens.length(), 1)
  // Last visible holder (Place("remote")) parks -> stream pauses!
  show_remote.set(false)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 1, msg="parking last visible holder must pause stream")
  // Wake Place("remote") -> stream resumes!
  show_remote.set(true)
  t.draw()
  t.draw()
  assert_eq(opens.length(), 2, msg="waking Place(remote) must reopen paused stream")
  // Make Account A live, deliver a frame & send input.
  (view_cbs[1])({ "state": { "phase": "live", "control": true, "may": true, "others": [] } }, None)
  let s_a = screens_open.get(screen_key(at.station, at.screen)).unwrap()
  s_a.frames = 3
  s_a.shown_any = true
  s_a.input(src, Json::object({ "t": Json::string("key"), "key": Json::string("a") }))
  assert_eq(inputs.length(), 1, msg="acct-a driving input should succeed before switch")
  // Switch to Account B in the SAME workspace ("ws-1") and SAME screen ("browser:shared-1")!
  let old_key = screen_key(at.station, at.screen)
  @sfbase.account_principal_set("acct-b")
  assert_true(s_a.revoked, msg="acct-a session must be synchronously revoked on account switch")
  assert_eq(cancelled.length(), 2, msg="acct-a stream must be synchronously cancelled on account switch")
  assert_false(screens_open.contains(old_key), msg="old account session must be cleared from screens_open")
  assert_false(screen_uis.contains(old_key), msg="old account UI must be cleared from screen_uis")
  assert_false(screen_leases.contains(old_key), msg="old account lease must be cleared from screen_leases")
  // Late frame & late input on revoked acct-a session: old frames == 0 and old input == 0!
  (view_cbs[1])({ "frame": { "ts": 100.0 } }, Some(Bytes::make(16, b'\x01')))
  assert_eq(s_a.frames, 0, msg="late frame after account switch must result in 0 old frames")
  assert_false(s_a.shown_any, msg="shown_any must remain false after account switch")
  s_a.input(src, Json::object({ "t": Json::string("key"), "key": Json::string("b") }))
  assert_eq(inputs.length(), 1, msg="late input after account switch must deliver 0 old inputs")
  // Account B opens the exact same (ws-1/st-1, browser:shared-1) -> fresh isolated session, 0 stale frames.
  @sfbase.workspace_owner_set("ws-1", "acct-b")
  let s_b = screen_sess(src, at.station, at.screen)
  assert_false(physical_equal(s_a, s_b), msg="acct-b must get a distinct ScreenSess from acct-a")
  assert_eq(s_b.account, "acct-b")
  assert_eq(s_b.frames, 0)
  assert_false(s_b.shown_any)
  @ui.run_let_go()
}

///|
test "multi-account workspace owner switch revokes only affected workspace, clears clipboard, guards RPCs, and re-mounts live node" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-a", "acct-b", "acct-c"])
  @sfbase.workspace_owner_set("ws-1", "acct-a")
  @sfbase.workspace_owner_set("ws-2", "acct-c")
  let opens : Array[String] = []
  let view_cbs : Array[(Json, Bytes?) -> Unit] = []
  let cancelled : Array[Int] = []
  let rpcs : Array[String] = []
  let next_call = Ref(0)
  let src : Source = {
    ..base,
    call: fn(name, _params, done) {
      rpcs.push(name)
      done(Ok(Json::null()))
    },
    stream: fn(name, params, _bytes, on_val, _done) {
      if name == "screen.view" {
        next_call.val += 1
        opens.push(text(Some(params), "station"))
        view_cbs.push(on_val)
        next_call.val
      } else {
        0
      }
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  let at1 : ScreenAt = { station: "ws-1/st-1", screen: "browser:tab-1", title: "WS1", until_gone: false }
  let at2 : ScreenAt = { station: "ws-2/st-2", screen: "browser:tab-2", title: "WS2", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      screen_node(root, src, at1, fn() { @sf.no_frame }, in_tab=true)
      screen_node(root, src, at2, fn() { @sf.no_frame }, in_tab=true)
    },
    w=1000.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(opens.length(), 2)
  let s_a = screens_open.get(screen_key(at1.station, at1.screen)).unwrap()
  let s_c = screens_open.get(screen_key(at2.station, at2.screen)).unwrap()
  (view_cbs[0])({ "state": { "phase": "live", "control": true, "may": true, "others": [] } }, None)
  (view_cbs[1])({ "state": { "phase": "live", "control": true, "may": true, "others": [] } }, None)
  s_a.frames = 5
  s_a.copied.push(CopiedText("secret-from-a", None))
  // Workspace ws-1 ownership moves from acct-a to acct-b while acct-a, acct-b, acct-c all remain signed in.
  @sfbase.workspace_owner_set("ws-1", "acct-b")
  assert_true(s_a.revoked, msg="ws-1 acct-a session must be revoked on workspace owner change")
  assert_true(s_a.copied.is_empty(), msg="revoked session clipboard queue must be cleared")
  assert_false(s_c.revoked, msg="unrelated ws-2 acct-c session must remain untouched")
  assert_true(screens_open.contains(screen_key(at2.station, at2.screen)), msg="ws-2 session must remain open")
  // Late outbound RPCs on revoked s_a must all be dropped.
  let rpcs_before = rpcs.length()
  reload_asked(s_a)
  browser_act(s_a, "screen.back", "back")
  s_a.input(src, Json::object({ "t": Json::string("key"), "key": Json::string("x") }))
  assert_eq(rpcs.length(), rpcs_before, msg="revoked session must emit 0 outbound RPCs")
  // Live mounted screen_node on ws-1/st-1 re-mounts cleanly for acct-b on next draw.
  t.draw()
  t.draw()
  assert_eq(opens.length(), 3, msg="mounted ws-1 screen_node must reopen cleanly under acct-b")
  let s_b = screens_open.get(screen_key(at1.station, at1.screen)).unwrap()
  assert_eq(s_b.account, "acct-b")
  assert_false(physical_equal(s_a, s_b))
  assert_eq(s_b.frames, 0)
  // Core reconnect (generation bump 0 -> 1) must NOT drift screen_key or revoke active principal.
  let gen = Ref(0)
  let src_gen : Source = { ..src, generation: fn(_name, _params) { (gen.val, true) } }
  let key_before = screen_key(at1.station, at1.screen)
  gen.val = 1
  assert_eq(screen_key(at1.station, at1.screen), key_before, msg="core reconnect must not change screen_key")
  assert_true(s_b.is_active_principal(), msg="core reconnect must not revoke active principal")
  assert_true(physical_equal(screen_sess(src_gen, at1.station, at1.screen), s_b), msg="core reconnect must reuse same ScreenSess")
  @ui.run_let_go()
}

///|
test "real workspaces JSON snapshot revokes on A->B owner change and on workspace disappearance while A stays online" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let snap_a : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([]),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_a))
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let s_a = screen_sess(src, "ws-1/st-1", "browser:snap-1")
  s_a.open(src)
  assert_eq(opens.val, 1)
  s_a.copied.push(CopiedText("a-secret", None))
  // (a) Real JSON snapshot moves ws-1 from acct-a to acct-b: s_a revoked, clipboard cleared, 0 clipboard writes.
  let snap_b : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_b))
  assert_true(s_a.revoked, msg="JSON snapshot A->B must revoke acct-a session")
  assert_true(s_a.copied.is_empty(), msg="JSON snapshot A->B must clear clipboard queue")
  let s_b = screen_sess(src, "ws-1/st-1", "browser:snap-1")
  s_b.open(src)
  assert_eq(opens.val, 2)
  assert_eq(s_b.account, "acct-b")
  // (b) ws-1 disappears from ALL signed-in accounts' snapshot while acct-a and acct-b remain online!
  let snap_gone : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([]),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_gone))
  assert_true(s_b.revoked, msg="disappearing workspace must synchronously revoke old session")
  assert_false(s_b.is_active_principal(), msg="revoked workspace session must not remain active")
  assert_true(@sfbase.workspace_is_revoked("ws-1"), msg="disappearing workspace must be marked revoked")
  assert_not_eq(@sfbase.workspace_owner_of("ws-1"), "acct-a", msg="revoked workspace must never fall back to first signed-in account")
  // Attempting to reopen a screen in the revoked workspace must be refused (0 new opens).
  let s_refused = screen_sess(src, "ws-1/st-1", "browser:snap-1")
  s_refused.open(src)
  assert_eq(opens.val, 2, msg="revoked workspace must refuse to reopen screen.view")
  // (c) Live mounted screen_node on ws-1 recovers automatically when ws-1 reappears in workspaces snapshot!
  let at_live : ScreenAt = { station: "ws-1/st-1", screen: "browser:snap-1", title: "Snap", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      screen_node(root, src, at_live, fn() { @sf.no_frame }, in_tab=true)
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(opens.val, 2, msg="mounted screen_node in revoked workspace must stay refused")
  @sfbase.workspace_owners_sync_json(Some(snap_b))
  t.draw()
  t.draw()
  assert_false(@sfbase.workspace_is_revoked("ws-1"), msg="restored workspace must clear revoked flag")
  assert_eq(opens.val, 3, msg="mounted screen_node must automatically reopen when workspace reappears in snapshot")
  @ui.run_let_go()
}

///|
test "passkey survives pair flip and side-panel <-> fullscreen handoff, cancels on last host close and workspace switch with 0 leaks" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-pk"])
  @sfbase.workspace_owner_set("ws-1", "acct-pk")
  let ready = Ref(false)
  let opens = Ref(0)
  let cancelled : Array[Int] = []
  let inputs : Array[Json] = []
  let view_cbs : Array[(Json, Bytes?) -> Unit] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.push(params)
      }
      done(Ok(Json::null()))
    },
    stream: fn(name, _params, _bytes, on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        view_cbs.push(on_val)
        opens.val
      } else {
        0
      }
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:pk-full", title: "PK", until_gone: false }
  let show_side = @signals.signal(true)
  let show_full = @signals.signal(false)
  let pair_flip = @signals.signal(false)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.show(at_once=true, fn() { show_side.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame }, in_tab=true)
      })
      root.show(at_once=true, fn() { show_full.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame })
      })
      // Simulates `pair` layout flip rebuilding passkey_sign_node while ScreenSess stays alive.
      root.pick(at_once=true, fn() { pair_flip.get() }, fn(slot, _flipped) {
        match screens_open.get(screen_key(at.station, at.screen)) {
          Some(s) => passkey_sign_node(slot, s)
          None => ()
        }
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  @ui.fake_passkey_asks.clear()
  @ui.fake_passkey.val = Some(fn(_rp, _client, _uv, _ids) {
    if ready.val { "0\u{1f}0909\u{1f}abcdef\u{1f}070707\u{1f}05\u{1f}\u{1f}" } else { "" }
  })
  (view_cbs[0])(
    {
      "state": {
        "phase": "live",
        "control": true,
        "may": true,
        "others": [],
        "passkey": {
          "id": "pk-2",
          "host": "github.com",
          "rpId": "github.com",
          "clientData": "{\"type\":\"webauthn.get\"}",
          "allow": ["0909"],
          "userVerification": "required",
        },
      },
    },
    None,
  )
  t.draw()
  let s = screens_open.get(screen_key(at.station, at.screen)).unwrap()
  s.passkey_start()
  t.draw()
  assert_true(s.passkey_run is Some(_))
  // (a) `pair` layout flip rebuild does NOT cancel in-flight passkey.
  pair_flip.set(true)
  t.draw()
  assert_true(s.passkey_run is Some(_), msg="pair layout flip must not cancel in-flight passkey")
  // (b) side-panel -> fullscreen handoff does NOT cancel in-flight passkey or pause stream.
  show_side.set(false)
  show_full.set(true)
  t.draw()
  t.draw()
  assert_true(s.passkey_run is Some(_), msg="side-panel -> fullscreen handoff must not cancel passkey")
  assert_eq(cancelled.length(), 0, msg="handoff must keep stream alive")
  // Complete passkey and confirm signed input delivered.
  ready.val = true
  t.run_for(passkey_look_ms * 2.0)
  assert_eq(inputs.length(), 1, msg="passkey must deliver signed input after pair flip and handoff")
  assert_true(s.passkey_run is None)
  // (c) Start another passkey, then workspace switch away from ws-1 -> cancels passkey immediately.
  ready.val = false
  s.passkey_start()
  t.draw()
  assert_true(s.passkey_run is Some(_))
  (@sfbase.on_workspace_switched.val)("ws-1", "ws-2")
  assert_true(s.passkey_run is None, msg="workspace switch must cancel in-flight passkey on left workspace")
  assert_eq(s.passkey_keepalive_key, "", msg="workspace switch must release passkey keepalive")
  // (d) Start another passkey, then permanently destroy the last real UI host -> cancels passkey & pauses stream (0 leak!).
  s.passkey_start()
  t.draw()
  assert_true(s.passkey_run is Some(_))
  show_full.set(false)
  t.draw()
  t.draw()
  assert_true(s.passkey_run is None, msg="permanent close of last UI host must cancel in-flight passkey")
  assert_eq(s.passkey_keepalive_key, "", msg="permanent close of last UI host must release passkey keepalive")
  assert_eq(cancelled.length(), 1, msg="permanent close of last UI host must pause/close stream with 0 leak")
  assert_true(screen_leases.is_empty(), msg="screen_leases must be empty after last host permanent close")
  @ui.fake_passkey.val = None
  @ui.run_let_go()
}

///|
test "screen lease table preserves equivalence without remote_shelf_pause_node across Nav shelf, narrow cover, tape hide, and layout switch" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-eq"])
  @sfbase.workspace_owner_set("ws-1", "acct-eq")
  let opens = Ref(0)
  let cancelled : Array[Int] = []
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(id) { cancelled.push(id) },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:eq-1", title: "EQ", until_gone: false }
  let shelf_on = @signals.signal(true)
  let narrow_top = @signals.signal(true)
  let tape_visible = @signals.signal(false)
  let wide_mode = @signals.signal(false)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      // 1. Place("remote") shelf parked via pick_kept (Nav shelf equivalent)
      root.pick_kept(at_once=true, fn() { shelf_on.get() }, fn(p, on) {
        if on {
          p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          screen_pane_node(p, src, at, fn() { @sf.no_frame }, in_tab=true)
        }
      })
      // 2. Narrow stack page covered via shown=narrow_top (on_top equivalent)
      root.show(at_once=true, fn() { !wide_mode.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame }, shown=fn() { narrow_top.get() })
      })
      // 3. Tape / wide side-panel hidden via shown=tape_visible
      root.show(at_once=true, fn() { wide_mode.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame }, in_tab=true, shown=fn() { tape_visible.get() })
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(opens.val, 1)
  assert_eq(cancelled.length(), 0)
  // Park Place("remote") shelf while narrow stack is still on top -> stream stays live (0 cancels).
  shelf_on.set(false)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 0, msg="parking Place(remote) while narrow stack is visible must not pause")
  // Cover narrow stack (on_top = false) -> last visible holder gone -> pauses!
  narrow_top.set(false)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 1, msg="covering last visible holder must pause stream")
  // Switch narrow -> wide layout with tape side-panel visible -> resumes!
  wide_mode.set(true)
  tape_visible.set(true)
  t.draw()
  t.draw()
  assert_eq(opens.val, 2, msg="switching to wide with visible tape side-panel must resume stream")
  // Hide tape side-panel -> pauses!
  tape_visible.set(false)
  t.draw()
  t.draw()
  assert_eq(cancelled.length(), 2, msg="hiding tape side-panel must pause stream")
  // Wake Place("remote") shelf -> resumes!
  shelf_on.set(true)
  t.draw()
  t.draw()
  assert_eq(opens.val, 3, msg="waking Place(remote) shelf must resume stream")
  @ui.run_let_go()
}

///|
test "passkey_muted revokes native Stream::route audio and suppresses 3840-byte PCM packets through hidden passkey release" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-mute"])
  @sfbase.workspace_owner_set("ws-1", "acct-mute")
  let s = screen_sess(base, "ws-1/st-1", "browser:mute-1")
  let t = @ui.Tester::tree(fn(_) {  }, w=400.0, h=300.0)
  t.draw()
  let h = @hostapi.host()
  let orig_audio_here = h.st_audio_here
  let orig_audio = h.st_audio
  let orig_direct = h.st_direct
  let audio_packets = Ref(0)
  let audio_flushes = Ref(0)
  let routed_audio_true = Ref(0)
  let routed_audio_false = Ref(0)
  h.st_audio_here = fn() { 1 }
  h.st_audio = fn(id, data) {
    if data.length() > 0 {
      audio_packets.val += 1
    } else {
      audio_flushes.val += 1
    }
    orig_audio(id, data)
  }
  h.st_direct = fn(id, route, after, what) {
    if (what & 2) != 0 {
      routed_audio_true.val += 1
    } else {
      routed_audio_false.val += 1
    }
    orig_direct(id, route, after, what)
  }
  s.own_stream()
  s.call = 7
  s.heard = true
  let pcm_3840 = Bytes::make(3840, b'\x01')
  // Deliver audioConfig + valid 3840-byte sequenced PCM packet while unmuted -> 1 audio packet + 1 audio=true route.
  s.take({ "audioConfig": { "codec": "pcm_s16le", "sampleRate": 48000.0, "channels": 2.0 } }, None)
  s.take({ "audio": { "n": 10.0 } }, Some(pcm_3840))
  assert_true(s.audio_ready.untracked())
  assert_eq(audio_packets.val, 1, msg="unmuted 3840-byte PCM must deliver to host")
  assert_true(routed_audio_true.val >= 1, msg="unmuted sequenced audio must route audio=true")
  // Enable passkey keepalive mute -> flushes audio and immediately revokes native audio route (audio=false).
  audio_packets.val = 0
  routed_audio_true.val = 0
  routed_audio_false.val = 0
  s.set_passkey_muted(true)
  assert_true(s.passkey_muted)
  assert_true(audio_flushes.val >= 1, msg="muting must flush native audio buffer")
  assert_true(routed_audio_false.val >= 1, msg="muting must immediately refresh native route with audio=false")
  // Subsequent 3840-byte sequenced PCM while passkey_muted == true -> 0 native audio deliveries and 0 audio=true routes!
  s.take({ "audio": { "n": 11.0 } }, Some(pcm_3840))
  assert_eq(audio_packets.val, 0, msg="passkey_muted must drop all 3840-byte PCM packets")
  assert_eq(routed_audio_true.val, 0, msg="passkey_muted must never route audio=true")
  // Releasing passkey keepalive while still hidden (with real ScreenLease) MUST keep passkey_muted == true,
  // and running real screen_leases_settle() pauses the stream BEFORE clearing passkey_muted so 0 audio=true routes fire!
  let lease_key = screen_key(s.station, s.screen)
  let _ = screen_ui(lease_key)
  screen_lease_set(base, lease_key, 1, false)
  screen_lease_set_passkey(base, lease_key, true)
  s.passkey_keepalive_key = lease_key
  s.passkey_release_keepalive()
  assert_true(s.passkey_muted, msg="passkey_release_keepalive must keep session muted until settle")
  s.take({ "audio": { "n": 12.0 } }, Some(pcm_3840))
  assert_eq(audio_packets.val, 0, msg="hidden session after passkey_release_keepalive must still deliver 0 audio")
  assert_eq(routed_audio_true.val, 0, msg="hidden session after passkey_release_keepalive must still route 0 audio=true")
  // Now run real end-of-frame settle: pauses stream first, then clears passkey_muted with 0 audio=true routes!
  screen_leases_settle()
  assert_eq(s.call, 0, msg="hidden settle after passkey release must pause stream")
  assert_false(s.passkey_muted, msg="passkey_muted resets only after stream is paused")
  assert_eq(audio_packets.val, 0, msg="hidden settle must deliver 0 audio packets")
  assert_eq(routed_audio_true.val, 0, msg="hidden settle must emit 0 audio=true routes")
  h.st_audio_here = orig_audio_here
  h.st_audio = orig_audio
  h.st_direct = orig_direct
  @ui.run_let_go()
}

///|
test "child-process standalone screen waits for workspaces snapshot with 0 screen.view RPCs and auto-wakes on matching snapshot" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  reset()
  @sfbase.accounts_subs_sync(["acct-a"])
  @sfbase.set_startup_window_owner(Some("acct-a"))
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:child-1", title: "Child", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick(
        at_once=true,
        fn() {
          screen_revokes_now() |> ignore
          @sfbase.workspace_owners_version.get() |> ignore
          @sfbase.window_here_owner_state(0, at.station)
        },
        fn(slot, st) {
          if st == Matched {
            slot.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            screen_node(slot, src, at, fn() { @sf.no_frame })
          }
        },
      )
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  // Before workspaces snapshot arrives: Waiting, 0 screen.view RPCs!
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 0, msg="Waiting child-process screen must emit 0 screen.view RPCs")
  // Offline cached snapshot (loaded=false, non-blocked) carrying ws-1 -> acct-a:
  // aligned with Core recomputeOwners() so offline mesh works immediately (Matched, opens screen.view)!
  let snap_offline : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_offline))
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched, msg="offline cached snapshot must Match for mesh continuity")
  assert_eq(opens.val, 1, msg="child-process screen must auto-wake and open once offline cached snapshot confirms ws-1 -> acct-a")
  // Subsequent online snapshot (loaded=true) with same ws-1 -> acct-a: stays Matched, 0 redundant opens!
  let snap_a : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_a))
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 1, msg="online confirmation of same owner must not reopen screen.view")
  @ui.run_let_go()
}

///|
test "post-sync A loses ws while B is loaded=false: A window immediately Denied & session/lease revoked with 0 RPC, B Waits then Matches" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let snap_both : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_both))
  let opens = Ref(0)
  let inputs = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.val += 1
        done(Ok(Json::object({})))
      } else {
        (base.call)(name, params, done)
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:e2e-1", title: "E2E", until_gone: false }
  @sfbase.set_startup_window_owner(Some("acct-a"))
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick(
        at_once=true,
        fn() {
          screen_revokes_now() |> ignore
          @sfbase.workspace_owners_version.get() |> ignore
          match @sfbase.window_here_owner_state(0, at.station, screen=at.screen) {
            Matched => 0
            Waiting => 1
            Denied => 2
          }
        },
        fn(q, st) {
          if st == 0 {
            q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            screen_node(q, src, at, fn() { @sf.no_frame })
          }
        },
      )
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  assert_eq(opens.val, 1, msg="A must open screen.view initially")
  assert_true(screens_open.contains(key_a), msg="A session must be open")
  assert_true(screen_leases.contains(key_a), msg="A lease must be active")
  let sess_a = screens_open.get(key_a).unwrap()
  // Push snapshot: A (loaded=true, lost ws-1), B (loaded=false, cached ws-1)
  let snap_a_lost_b_pending : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_a_lost_b_pending))
  t.draw()
  t.draw()
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), None)
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Denied, msg="A window must immediately turn Denied")
  assert_false(screens_open.contains(key_a), msg="A session must be revoked immediately")
  assert_false(screen_leases.contains(key_a), msg="A lease must be revoked immediately")
  // Subsequent input on A's old session must emit 0 RPCs
  sess_a.input(src, Json::object({ "t": Json::string("click") }))
  assert_eq(inputs.val, 0, msg="revoked A session must emit 0 screen.input RPCs")
  // Switch standalone window identity to B while B is still loaded=false -> Waiting, 0 new opens, 0 inputs!
  @sfbase.set_startup_window_owner(Some("acct-b"))
  @sfbase.workspace_owners_version.set(@sfbase.workspace_owners_version.untracked() + 1)
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting, msg="B window must Wait while loaded=false")
  assert_eq(opens.val, 1, msg="Waiting B window must emit 0 additional screen.view RPCs")
  assert_eq(inputs.val, 0)
  // Push snapshot: A (loaded=true, no ws-1), B (loaded=true, has ws-1) -> B Matches and remounts!
  let snap_b_loaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_b_loaded))
  t.draw()
  t.draw()
  let key_b = screen_key_for_owner("acct-b", at.station, at.screen)
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched, msg="B window must transition to Matched")
  assert_eq(opens.val, 2, msg="B window must open fresh screen.view on Matched")
  assert_true(screens_open.contains(key_b), msg="B session must be active")
  assert_true(screen_leases.contains(key_b), msg="B lease must be active")
  // Verify A remains Denied
  @sfbase.set_startup_window_owner(Some("acct-a"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Denied, msg="A must stay Denied after B takes ownership")
  @ui.run_let_go()
}

///|
test "normal screen_node (no lone_tree) gates pending/revoked: 0 RPC on remount during B pending, auto-remounts when B loads" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let snap_both : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_both))
  let opens = Ref(0)
  let inputs = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.val += 1
        done(Ok(Json::object({})))
      } else {
        (base.call)(name, params, done)
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:plain-1", title: "Plain", until_gone: false }
  let mounted = @signals.signal(true)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.show(at_once=true, fn() { mounted.get() }, fn(q) {
        q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(q, src, at, fn() { @sf.no_frame })
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  assert_eq(opens.val, 1, msg="normal screen_node must open screen.view for A")
  assert_true(screens_open.contains(key_a))
  let sess_a = screens_open.get(key_a).unwrap()
  // Push A (loaded=true, no ws-1) + B (loaded=false, cached ws-1): ws-1 enters pending!
  let snap_a_lost_b_pending : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_a_lost_b_pending))
  t.draw()
  t.draw()
  assert_false(screens_open.contains(key_a), msg="A session must be revoked on pending transition")
  // Unmount and remount normal screen_node while B is still pending -> 0 additional screen.view RPCs & 0 input RPCs!
  mounted.set(false)
  t.draw()
  mounted.set(true)
  t.draw()
  t.draw()
  assert_eq(opens.val, 1, msg="remounting normal screen_node during pending must emit 0 additional screen.view RPCs")
  sess_a.input(src, Json::object({ "t": Json::string("click") }))
  assert_eq(inputs.val, 0, msg="input on revoked A session must emit 0 RPCs")
  // Push B (loaded=true, ws-1): normal screen_node auto-remounts and opens screen.view for B!
  let snap_b_loaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_b_loaded))
  t.draw()
  t.draw()
  let key_b = screen_key_for_owner("acct-b", at.station, at.screen)
  assert_eq(opens.val, 2, msg="normal screen_node must auto-remount and open screen.view for B")
  assert_true(screens_open.contains(key_b), msg="B session must be active")
  @ui.run_let_go()
}

///|
test "child-process window for B Waits with 0 RPC when earlier A is loaded=false with empty cache, then Matches when A loads" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  assert_false(@sfbase.workspace_owners_synced(), msg="cold-start test must start before any workspaces snapshot")
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:early-1", title: "Early", until_gone: false }
  @sfbase.set_startup_window_owner(Some("acct-b"))
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick(
        at_once=true,
        fn() {
          screen_revokes_now() |> ignore
          @sfbase.workspace_owners_version.get() |> ignore
          match @sfbase.window_here_owner_state(0, at.station, screen=at.screen) {
            Matched => 0
            Waiting => 1
            Denied => 2
          }
        },
        fn(q, st) {
          if st == 0 {
            q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            screen_node(q, src, at, fn() { @sf.no_frame })
          }
        },
      )
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  let snap_earlier_empty : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_earlier_empty))
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 0, msg="B child-process window must emit 0 screen.view RPCs while earlier A is unloaded")
  let snap_b_confirmed : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_b_confirmed))
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 1, msg="B child-process window must open screen.view once earlier A finishes loading")
  @ui.run_let_go()
}

///|
test "deferred screen_left_key after_drawn_frame closes when sole holder unmounts and stays open when another visible holder remains" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.accounts_subs_sync(["acct-rem"])
  @sfbase.workspace_owner_set("ws-1", "acct-rem")
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:rem-1", title: "Rem", until_gone: false }
  let show_remote = @signals.signal(true)
  let show_other = @signals.signal(true)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.show(at_once=true, fn() { show_remote.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_pane_node(p, src, at, fn() { @sf.no_frame }, in_tab=true)
      })
      root.show(at_once=true, fn() { show_other.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(p, src, at, fn() { @sf.no_frame })
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key = screen_key(at.station, at.screen)
  assert_true(screens_open.contains(key))
  // (a) Remove remote tab while another visible holder (`show_other`) remains -> stays open!
  show_remote.set(false)
  @ui.after_drawn_frame(fn() {
    screen_left_key(src, key, at.station, at.screen, leaving_holder_released=true)
  })
  t.draw()
  t.draw()
  assert_true(screens_open.contains(key), msg="screen must stay open when another visible holder remains")
  // (b) Remove the last visible holder -> deferred screen_left_key closes cleanly!
  show_other.set(false)
  @ui.after_drawn_frame(fn() {
    screen_left_key(src, key, at.station, at.screen, leaving_holder_released=true)
  })
  t.draw()
  t.draw()
  assert_false(screens_open.contains(key), msg="screen must close cleanly when sole holder is removed")
  @ui.run_let_go()
}

///|
test "cloud offline cold start (all loaded=false with cached ws-1): main screen_node opens normally for mesh" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-a"])
  let snap_offline : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_offline))
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), Some("acct-a"))
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:offline-1", title: "Offline", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  assert_eq(opens.val, 1, msg="offline cached ws-1 must open screen.view immediately for mesh")
  assert_true(screens_open.contains(key_a))
  @ui.run_let_go()
}

///|
test "blocked (NOT_BETA) account with loaded=false immediately revokes session/lease/stream and renders denied on remount" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-a"])
  let snap_ok : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_ok))
  let opens = Ref(0)
  let cancelled = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) { cancelled.val += 1 },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:blocked-1", title: "Blocked", until_gone: false }
  let mounted = @signals.signal(true)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.show(at_once=true, fn() { mounted.get() }, fn(q) {
        q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(q, src, at, fn() { @sf.no_frame })
      })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  assert_eq(opens.val, 1)
  assert_true(screens_open.contains(key_a))
  let sess_a = screens_open.get(key_a).unwrap()
  // Production NOT_BETA shape: loaded=false, workspaces=[], blocked="not beta"
  let snap_blocked : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
      "blocked": Json::string("not beta"),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_blocked))
  t.draw()
  t.draw()
  assert_true(@sfbase.workspace_is_revoked("ws-1"), msg="blocked account must immediately revoke ws-1")
  assert_false(sess_a.is_active_principal(), msg="revoked session must fail is_active_principal")
  assert_false(screens_open.contains(key_a), msg="blocked account session must be closed")
  assert_false(screen_leases.contains(key_a), msg="blocked account lease must be removed")
  assert_true(cancelled.val >= 1, msg="blocked account stream must be cancelled")
  // Remounting normal screen_node emits 0 new RPCs and shows denied message (no blank dead-end)
  mounted.set(false)
  t.draw()
  mounted.set(true)
  t.draw()
  t.draw()
  assert_eq(opens.val, 1, msg="remounting revoked screen_node must emit 0 additional screen.view RPCs")
  assert_true(t.find(@sf.t("android-misc.screen.denied")) is Some(_), msg="revoked screen_node must render denied message")
  @ui.run_let_go()
}

///|
test "active native route transitioning Owned(A) -> Pending synchronously cancels stream, flushes audio(0), clears frame, and blocks subsequent host deliveries" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let snap_both : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_both))
  let opens = Ref(0)
  let cancelled = Ref(0)
  let inputs = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    call: fn(name, params, done) {
      if name == "screen.input" {
        inputs.val += 1
        done(Ok(Json::object({})))
      } else {
        (base.call)(name, params, done)
      }
    },
    cancel: fn(_) { cancelled.val += 1 },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:native-pending-1", title: "NativePending", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  let h = @hostapi.host()
  let orig_audio_here = h.st_audio_here
  let orig_audio = h.st_audio
  let orig_direct = h.st_direct
  let audio_packets = Ref(0)
  let audio_flushes = Ref(0)
  let routed_audio_true = Ref(0)
  h.st_audio_here = fn() { 1 }
  h.st_audio = fn(id, data) {
    if data.length() > 0 {
      audio_packets.val += 1
    } else {
      audio_flushes.val += 1
    }
    orig_audio(id, data)
  }
  h.st_direct = fn(id, route, after, what) {
    if (what & 2) != 0 {
      routed_audio_true.val += 1
    }
    orig_direct(id, route, after, what)
  }
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  let sess_a = screens_open.get(key_a).unwrap()
  sess_a.own_stream()
  sess_a.heard = true
  sess_a.frames = 5
  sess_a.shown_any = true
  let pcm_3840 = Bytes::make(3840, b'\x01')
  sess_a.take({ "audioConfig": { "codec": "pcm_s16le", "sampleRate": 48000.0, "channels": 2.0 } }, None)
  sess_a.take({ "audio": { "n": 1.0 } }, Some(pcm_3840))
  assert_eq(audio_packets.val, 1)
  assert_true(routed_audio_true.val >= 1)
  // Reset counters before Owned(A) -> Pending transition
  audio_packets.val = 0
  audio_flushes.val = 0
  routed_audio_true.val = 0
  let snap_a_lost_b_pending : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_a_lost_b_pending))
  assert_true(cancelled.val >= 1, msg="Owned(A) -> Pending must synchronously cancel screen.view")
  assert_false(screens_open.contains(key_a), msg="screens_open must be cleared on Owned(A) -> Pending")
  assert_false(screen_leases.contains(key_a), msg="screen_leases must be cleared on Owned(A) -> Pending")
  assert_true(audio_flushes.val >= 1, msg="Owned(A) -> Pending must flush st.audio(0)")
  assert_eq(sess_a.frames, 0, msg="Owned(A) -> Pending must clear frames")
  assert_false(sess_a.shown_any, msg="Owned(A) -> Pending must clear shown_any")
  // Subsequent host audio/video deliveries & input RPCs on revoked sess_a must all be 0!
  sess_a.take({ "audio": { "n": 2.0 } }, Some(pcm_3840))
  sess_a.take({ "frame": { "ts": 200.0 } }, Some(Bytes::make(16, b'\x02')))
  sess_a.input(src, Json::object({ "t": Json::string("click") }))
  assert_eq(audio_packets.val, 0, msg="subsequent audio delivery after Pending revoke must be 0")
  assert_eq(routed_audio_true.val, 0, msg="subsequent audio route after Pending revoke must be 0")
  assert_eq(sess_a.frames, 0, msg="subsequent video frame after Pending revoke must be 0")
  assert_eq(inputs.val, 0, msg="subsequent screen.input after Pending revoke must be 0")
  h.st_audio_here = orig_audio_here
  h.st_audio = orig_audio
  h.st_direct = orig_direct
  @ui.run_let_go()
}

///|
test "Pending stays idempotent across repeated snapshots while B is loaded=false (0 new RPCs) and both-unloaded cold start keeps B Waiting" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  let snap_both : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_both))
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:idemp-1", title: "Idemp", until_gone: false }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  assert_eq(opens.val, 1)
  // A loses ws-1 while B is loaded=false -> Pending!
  let snap_pending : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  let snap_pending_inv : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "invitations": Json::array([Json::object({ "id": Json::string("inv-2") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_pending))
  t.draw()
  // Repeat identical + invitations-changed snapshots while B is still loaded=false: 0 new screen.view RPCs!
  @sfbase.workspace_owners_sync_json(Some(snap_pending))
  t.draw()
  @sfbase.workspace_owners_sync_json(Some(snap_pending_inv))
  t.draw()
  t.draw()
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), None)
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  @sfbase.set_startup_window_owner(Some("acct-b"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 1, msg="repeated pending snapshots must emit 0 additional screen.view RPCs")
  // B confirms loaded=true -> opens screen.view for B!
  let snap_b_ok : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_b_ok))
  t.draw()
  t.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 2, msg="B confirmation must open screen.view")
  @ui.run_let_go()
  // Both-unloaded cold start: [A(loaded=false, []), B(loaded=false, [ws-1])] -> 0 screen.view RPCs until loaded!
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  @sfbase.set_startup_window_owner(Some("acct-b"))
  opens.val = 0
  let snap_both_unloaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(snap_both_unloaded))
  let t2 = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t2.draw()
  t2.draw()
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), None)
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 0, msg="both-unloaded cold start must emit 0 screen.view RPCs")
  @sfbase.workspace_owners_sync_json(Some(snap_b_ok))
  t2.draw()
  t2.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 1, msg="screen_node must open screen.view once A and B finish loading")
  @ui.run_let_go()
}

///|
test "Core ownedWorkspaces dual-branch offline acceptance: ownedWorkspaces=[] stays Pending/0 RPC even for first account; ownedWorkspaces=[ws-1] opens mesh offline" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  @sfbase.set_startup_window_owner(Some("acct-b"))
  let opens = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) {  },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:core-owned-1", title: "CoreOwned", until_gone: false }
  let core_multi_unowned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
  ])
  let core_multi_owned_b : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(false),
    }),
  ])
  // Branch 1: Core ownedWorkspaces=[] -> Pending/Waiting, 0 screen.view RPCs
  @sfbase.workspace_owners_sync_json(Some(core_multi_unowned))
  let t1 = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t1.draw()
  t1.draw()
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 0, msg="Core ownedWorkspaces=[] must emit 0 screen.view RPCs")
  // Branch 2: Same offline accounts, Core confirms B.ownedWorkspaces=["ws-1"] (loaded=false!) -> immediately opens mesh!
  @sfbase.workspace_owners_sync_json(Some(core_multi_owned_b))
  t1.draw()
  t1.draw()
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 1, msg="Core B.ownedWorkspaces=[ws-1] must immediately open mesh offline without waiting for /v1/me")
  @ui.run_let_go()
  // Single-account [B(loaded=false, [ws-1])]: ownedWorkspaces=[] -> 0 RPC even as first account; ownedWorkspaces=[ws-1] -> 1 RPC offline!
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.accounts_subs_sync(["acct-b"])
  @sfbase.set_startup_window_owner(Some("acct-b"))
  opens.val = 0
  let core_single_unowned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
  ])
  let core_single_owned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(false),
    }),
  ])
  @sfbase.workspace_owners_sync_json(Some(core_single_unowned))
  let t2 = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t2.draw()
  t2.draw()
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 0, msg="single-account Core ownedWorkspaces=[] must emit 0 screen.view RPCs")
  @sfbase.workspace_owners_sync_json(Some(core_single_owned))
  t2.draw()
  t2.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 1, msg="single-account Core ownedWorkspaces=[ws-1] must immediately open mesh offline")
  @ui.run_let_go()
}

///|
test "r14 two-pass order independence ([B, A]) and two-step explicit_loss preservation: A revoked with audio(0), B Waits (0 new RPC) until loaded=true" {
  // Case 1: [B(loaded=false, ownedWorkspaces=["ws-1"]), A(loaded=true, workspaces=[], ownedWorkspaces=[])] (B precedes A)
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  @sfbase.reset()
  @sfbase.accounts_subs_sync(["acct-b", "acct-a"])
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  let opens = Ref(0)
  let cancelled = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) { cancelled.val += 1 },
  }
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:r14-1", title: "R14", until_gone: false }
  let t1 = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  let h = @hostapi.host()
  let orig_audio_here = h.st_audio_here
  let orig_audio = h.st_audio
  let audio_flushes = Ref(0)
  h.st_audio_here = fn() { 1 }
  h.st_audio = fn(id, data) {
    if data.length() == 0 {
      audio_flushes.val += 1
    }
    orig_audio(id, data)
  }
  t1.draw()
  t1.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  let sess_a = screens_open.get(key_a).unwrap()
  sess_a.own_stream()
  sess_a.heard = true
  sess_a.frames = 4
  sess_a.shown_any = true
  sess_a.take({ "audioConfig": { "codec": "pcm_s16le", "sampleRate": 48000.0, "channels": 2.0 } }, None)
  sess_a.take({ "audio": { "n": 1.0 } }, Some(Bytes::make(3840, b'\x01')))
  assert_eq(opens.val, 1)
  audio_flushes.val = 0
  // Push [B(loaded=false, ownedWorkspaces=["ws-1"]), A(loaded=true, [], [])]
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  t1.draw()
  t1.draw()
  assert_true(cancelled.val >= 1, msg="A stream must be cancelled immediately when B precedes A")
  assert_true(audio_flushes.val >= 1, msg="A must flush st.audio(0) immediately")
  assert_eq(sess_a.frames, 0)
  assert_false(sess_a.shown_any)
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  @sfbase.set_startup_window_owner(Some("acct-b"))
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
  assert_eq(opens.val, 1, msg="B must emit 0 additional screen.view RPCs while loaded=false")
  // B finishes /v1/me (loaded=true, ownedWorkspaces=["ws-1"]) -> opens 2nd screen.view!
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  t1.draw()
  t1.draw()
  assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
  assert_eq(opens.val, 2, msg="B confirmation must open 2nd screen.view")
  h.st_audio_here = orig_audio_here
  h.st_audio = orig_audio
  @ui.run_let_go()
  // Case 2: Two-step A(Owned) -> Snap 1 (A lost, both ownedWorkspaces=[]) -> Snap 2 (B loaded=false, ownedWorkspaces=["ws-1"]) -> Snap 3 (B loaded=true)
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  opens.val = 0
  cancelled.val = 0
  let t2 = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t2.draw()
  t2.draw()
  assert_eq(opens.val, 1)
  // Snap 1: A lost, Core hasn't allocated B yet (both ownedWorkspaces=[])
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  t2.draw()
  assert_true(cancelled.val >= 1)
  assert_true(@sfbase.workspace_is_pending("ws-1"))
  assert_eq(opens.val, 1, msg="Snap 1 must emit 0 additional screen.view RPCs")
  // Snap 2: Core offline-assigns ws-1 to B (still loaded=false) -> explicit_loss keeps Pending, 0 new RPCs!
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  t2.draw()
  t2.draw()
  assert_true(@sfbase.workspace_is_pending("ws-1"), msg="Snap 2 must keep ws-1 Pending while B is loaded=false")
  assert_eq(opens.val, 1, msg="Snap 2 must emit 0 additional screen.view RPCs")
  // Snap 3: B loaded=true -> opens 2nd screen.view!
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  t2.draw()
  t2.draw()
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_eq(opens.val, 2, msg="Snap 3 must open 2nd screen.view once B is loaded=true")
  @ui.run_let_go()
}

///|
test "r15 sign-out order independence (both accounts-first and workspaces-first keep offline B Waiting) and legitimate re-election while A remains member immediately opens offline B" {
  let base = @sffixture.fixture("settings")
  let at : ScreenAt = { station: "ws-1/st-1", screen: "browser:r15-1", title: "R15", until_gone: false }
  let snap_ab_a_owns : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
  ])
  let snap_b_offline_only : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(false),
    }),
  ])
  let snap_b_loaded_only : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(true),
    }),
  ])
  // Run both sign-out notification orders: accounts_first=true and accounts_first=false
  for accounts_first in [true, false] {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    @sfbase.accounts_subs_sync(["acct-a", "acct-b"])
    @sfbase.workspace_owners_sync_json(Some(snap_ab_a_owns))
    let opens = Ref(0)
    let cancelled = Ref(0)
    let src : Source = {
      ..base,
      stream: fn(name, _params, _bytes, _on_val, _done) {
        if name == "screen.view" {
          opens.val += 1
          opens.val
        } else {
          0
        }
      },
      cancel: fn(_) { cancelled.val += 1 },
    }
    let t = @ui.Tester::tree(
      fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        screen_node(root, src, at, fn() { @sf.no_frame })
      },
      w=900.0,
      h=600.0,
      platform=0,
      keeps_sources=true,
    )
    let h = @hostapi.host()
    let orig_audio_here = h.st_audio_here
    let orig_audio = h.st_audio
    let audio_flushes = Ref(0)
    h.st_audio_here = fn() { 1 }
    h.st_audio = fn(id, data) {
      if data.length() == 0 {
        audio_flushes.val += 1
      }
      orig_audio(id, data)
    }
    t.draw()
    t.draw()
    let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
    let sess_a = screens_open.get(key_a).unwrap()
    sess_a.own_stream()
    sess_a.heard = true
    sess_a.take({ "audioConfig": { "codec": "pcm_s16le", "sampleRate": 48000.0, "channels": 2.0 } }, None)
    sess_a.take({ "audio": { "n": 1.0 } }, Some(Bytes::make(3840, b'\x01')))
    assert_eq(opens.val, 1)
    audio_flushes.val = 0
    if accounts_first {
      @sfbase.accounts_subs_sync(["acct-b"])
      @sfbase.workspace_owners_sync_json(Some(snap_b_offline_only))
    } else {
      @sfbase.workspace_owners_sync_json(Some(snap_b_offline_only))
      @sfbase.accounts_subs_sync(["acct-b"])
    }
    t.draw()
    t.draw()
    assert_true(cancelled.val >= 1, msg="A stream must be cancelled on sign-out")
    assert_true(audio_flushes.val >= 1, msg="A audio must be flushed on sign-out")
    assert_true(@sfbase.workspace_is_pending("ws-1"), msg="ws-1 must stay Pending while B is loaded=false after A signs out")
    @sfbase.set_startup_window_owner(Some("acct-b"))
    assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Waiting)
    assert_eq(opens.val, 1, msg="offline B must emit 0 additional screen.view RPCs after A signs out")
    @sfbase.workspace_owners_sync_json(Some(snap_b_loaded_only))
    t.draw()
    t.draw()
    assert_true(@sfbase.window_here_owner_state(0, at.station, screen=at.screen) == Matched)
    assert_eq(opens.val, 2, msg="B confirmation must open 2nd screen.view")
    h.st_audio_here = orig_audio_here
    h.st_audio = orig_audio
    @ui.run_let_go()
  }
  // Legitimate re-election while A is still a loaded member of ws-1: offline B opens immediately!
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  @sfbase.accounts_subs_sync(["acct-b", "acct-a"])
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  let opens = Ref(0)
  let cancelled = Ref(0)
  let src : Source = {
    ..base,
    stream: fn(name, _params, _bytes, _on_val, _done) {
      if name == "screen.view" {
        opens.val += 1
        opens.val
      } else {
        0
      }
    },
    cancel: fn(_) { cancelled.val += 1 },
  }
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      screen_node(root, src, at, fn() { @sf.no_frame })
    },
    w=900.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  t.draw()
  let key_a = screen_key_for_owner("acct-a", at.station, at.screen)
  assert_eq(opens.val, 1)
  assert_true(screens_open.contains(key_a))
  // Core re-elects offline B while A is STILL a loaded member of ws-1 -> immediate Owned(B), A closed, B opens offline!
  @sfbase.workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  t.draw()
  t.draw()
  let key_b = screen_key_for_owner("acct-b", at.station, at.screen)
  assert_false(@sfbase.workspace_is_pending("ws-1"), msg="legitimate re-election must not set Pending")
  assert_eq(@sfbase.workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_false(screens_open.contains(key_a), msg="old A session must be closed on owner switch")
  assert_true(cancelled.val >= 1)
  assert_true(screens_open.contains(key_b), msg="offline B must immediately open screen session")
  assert_eq(opens.val, 2, msg="offline B must immediately open 2nd screen.view without waiting for /v1/me")
  @ui.run_let_go()
}
