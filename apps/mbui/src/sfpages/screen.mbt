// One view of a station's screen (still.fail apps/android app/remote/ScreenSession.kt
// `screen.view`): the core's call kept open while the viewer is in sight, its values taken apart (the state, a config,
// frames with their bytes), frames handed to the decoder (@ui.Stream: H.264 or JPEG, drawn as the picture the viewer
// shows), each acknowledged once shown (the stream says so) or dropped; input, 只看/控制 and key frames told back to
// the core. While it drives the screen, the screen's clipboard goes both ways (a copy made on it comes as a `{clipboard}`
// value, `screen.clipboard` pastes) and files picked go onto its machine (screen_drops.mbt). Zoomed in, the part of the
// screen shown is told (`screen.look`): the station then sends that part alone, as sharp as this device shows it, each
// config saying which part. Its frames go to a decoder of their own (`part`), drawn over the whole screen's last picture
// where the part is, while its picture is newer than the whole's: so a part's frame shows only once one has come, and
// the whole again only once the whole's has. The connection, the credentials and the reconnecting are the core's; this
// only draws what it says.

///|
/// Where a file dropped into the view goes on the screen's machine (ScreenDrop): the folder, and whether the view can
/// show it there in the machine's file manager.
priv struct DropTo {
  folder : String
  reveal : Bool
  /// the file is an app to install on the device once it is there (`screen.install`)
  install : Bool
}

///|
/// A part of the screen (0..1 of its width and height): its left, top, width, height.
#derive(Eq)
priv struct Part {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
/// A config's part of the screen (`region`), when it says one.
fn part_of(v : Json?) -> Part? {
  match field(v, "region") {
    Some(Object(_)) as r => {
      let p : Part = { x: number(r, "x"), y: number(r, "y"), w: number(r, "w"), h: number(r, "h") }
      if p.w > 0.0 && p.h > 0.0 {
        Some(p)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// A copy made on the screen, for the device's clipboard: its text and the mark the app that copied it gave it (a
/// password manager's `concealed`, `transient`, `auto`; None: none), or its PNG.
priv enum Copied {
  CopiedText(String, String?)
  CopiedPng(Bytes)
}

///|
/// A pointer of the station's own picture (a drawing tool's, a brush's, a crosshair of an app's): its PNG, its size in
/// points and its hot spot in from its top left (`cursorImage`, ScreenSess::take).
priv struct CustomCursor {
  png : Bytes
  w : Double
  h : Double
  hx : Double
  hy : Double
}

///|
/// How many of the station's own pointers a view keeps (the oldest let go of past it).
let custom_cursors_most : Int = 64

///|
/// The image key a pointer the station drew itself (`custom:<hex>`) is drawn by.
fn custom_cursor_key(shape : String) -> String {
  "mem:sf/pointer/" + shape
}

///|
/// A view of `screen` on `station` (its address, `<workspace>/<station>`), kept while its page is in the stack.
priv struct ScreenSess {
  /// where it reads and writes
  src : Source
  /// owning account of this screen's workspace (revoked synchronously on account/owner change)
  account : String
  /// workspace id extracted from `station`
  workspace : String
  /// full subject principal `(account, auth_gen)` that owns this session
  principal : String
  /// set true when revoked by principal/auth change; blocks late frames, reopens, clipboard, and RPCs
  mut revoked : Bool
  station : String
  screen : String
  /// the name the core knows this view by (unique among this app's views)
  view : String
  /// the core's latest state of the view (ScreenViewState, whole each time); None before the first
  mut state : Json?
  /// each state taken that changed more than where the station's pointer is (ScreenSess::take): what reads the state
  /// reads it again as it is told
  said : @signals.Signal[Int]
  /// each state taken that moved the station's pointer alone (its shape the same), the pointer drawn here: what draws
  /// the pointer reads it again, nothing else of the page
  cursor_said : @signals.Signal[Int]
  /// the pointer as the page has it drawn now: on a picture's system video layer by its host (moved there as the
  /// station's pointer moves, nothing drawn for it: ScreenSess::pointer_moved), or None here, by the window's tree
  mut pointer_layer : PointerLayer?
  /// where the station says its pointer is (0..1 of the frame) and its shape (a CSS cursor's name, `none` hidden), as
  /// last said: by a state, or by a word of the pointer alone (`cursor`, ScreenSess::take), read without the state
  mut cursor_pos : (Double, Double)?
  mut cursor_shape_now : String
  /// the station says its pointer on its own (a `cursor` word came): a state that says none of it keeps it as it was
  mut cursor_apart : Bool
  /// what the page draws of the pointer follows the station's word of it (not this device's mouse over the picture, nor
  /// the trackpad's own pointer): told by the stage as either changes (screen_stage_gestures); drawn while no stage is
  mut cursor_drawn : Bool
  /// the pointers of the station's own pictures it said (`cursorImage`), by the shape it names them (`custom:<hex>`),
  /// the latest few kept (custom_cursors_most)
  custom_cursors : Map[String, CustomCursor]
  /// each copy made on the screen taken (`copied`), and each file picked or let go of (`drops`): what puts the copies on
  /// the device's clipboard and what lists the files read them as they are told
  copied_told : @signals.Signal[Int]
  drops_told : @signals.Signal[Int]
  /// each stream made (`stream`, `part`: what draws them made again with them), and each change of what the decoders
  /// show that moves what is drawn round them (the first frame shown, the part shown over the whole: ScreenSess::
  /// shown_told)
  streams_told : @signals.Signal[Int]
  part_told : @signals.Signal[Int]
  /// the part shown over the whole, and the frame's size, as they were last told (ScreenSess::shown_told)
  mut part_was : Part?
  mut size_was : (Int, Int)?
  /// the call failed (the core said why), rather than the view ending
  failure : @signals.Signal[String?]
  /// the call answered: the view ended (the last state says why)
  finished : @signals.Signal[Bool]
  /// the frames' codec and size, from the latest config
  /// the view's sound coming as this device plays it, and muted here (told as they change: 控制中心's row reads them)
  audio_ready : @signals.Signal[Bool]
  audio_muted : @signals.Signal[Bool]
  /// this device's microphone shared into the screen's virtual one (麦克风, `screen.micOn`), as the person switched it:
  /// it goes only while the screen's state says something there records it (ScreenSess::mic_info)
  mic_on : @signals.Signal[Bool]
  mut codec : String?
  mut size : (Int, Int)?
  /// something was shown since it opened: a frame kept on screen through a reconnect or an end
  mut shown_any : Bool
  /// 控制 (true) or 只看 as the person chose; None until they do: the core opens it in 只看 while someone else (an
  /// agent at work) drives it, else in 控制, so opening a screen never takes it from whoever is on it
  mut wants_control : Bool?
  /// a finger drives it as a trackpad (true) or directly, as chosen here before the prefs say: a signal, so what reads
  /// how a finger drives it (the pointer drawn over the picture, 控制中心's tile) is built again in the press's frame
  pad_set : @signals.Signal[Bool?]
  /// gamepad mouse/keyboard emulation mode as toggled here before the station echoes its updated gamepad state
  gamepad_mouse_set : @signals.Signal[Bool?]
  /// the stage it is laid out for (its width and height, and this device's pixels to a point), on a phone or a tablet:
  /// a page of the station's browser is laid out as this device's own browser would; None: as it is
  mut fit : (Double, Double, Double)?
  /// the open call (the core's id of it); 0 while it is not open
  mut call : Int
  /// the last frame acknowledged
  mut acked : Double
  /// the decoder the frames go to, and the picture it shows (made as the view first opens: own_stream)
  mut stream : @ui.Stream?
  /// the decoder a part's frames go to (made as the first part's config comes), its codec; whether the frames now
  /// coming are a part's; the part the next frame shows (from its config), and the part each of its frames shows from
  /// (by the time of the first), oldest first
  mut part : @ui.Stream?
  mut part_codec : String?
  mut parting : Bool
  mut part_next : Part?
  parts : Array[(Double, Part)]
  /// the part of the screen last told the core (`screen.look`): "" the whole
  mut looked : String
  /// the copies made on the screen not yet put on the device's clipboard (the viewer takes them)
  copied : Array[Copied]
  /// the files picked for its machine (screen_drops.mbt)
  drops : Array[ScreenDropItem]
  mut drops_serial : Int
  mut pumping : Bool
  /// a paste under way
  pasting : @signals.Signal[Bool]
  /// the frames that came and their bytes, counted as they come (控制中心's 连接 reads a second's of them)
  mut frames : Int
  mut bytes : Int
  /// the 串流分辨率 the open view was asked with (prefs `screenQuality`; "": 自动), its 帧率 (prefs
  /// `screenFps`; 0: 自动), its 码率上限 (prefs `screenBitrate` in Mbps; 0: 自动) and 4:4:4 (prefs
  /// `screenChroma444`): another chosen is asked of it (`screen.bounds`)
  mut asked : String
  mut asked_fps : Int
  mut asked_bitrate : Int
  mut asked_chroma444 : Bool
  /// the bounds the open view was asked with (画质's, or 自动's: `stage_px`)
  mut asked_bounds : (Int, Int)
  /// the most device pixels the stage it is shown on has had (0 × 0 before it is laid out): 自动 asks that large
  mut stage_px : (Int, Int)
  /// filling the page's login from this device's password manager (screen_fill.mbt): where it is (`listing`,
  /// `choosing`, `getting`, `said`; "" nothing under way), the run of it under way, the logins to pick from, what it
  /// said where it did not fill, and the site it is for
  fill_step : @signals.Signal[String]
  /// the `(host, field, address)` login prompt dismissed by `×`, cleared once focus leaves or moves elsewhere
  fill_dismissed : @signals.Signal[(String, String, String)?]
  mut fill_run : @hostapi.OpRun?
  mut fill_choices : Array[@hostapi.PasswordLogin]
  mut fill_note : String
  mut fill_host : String
  /// the login picked in the system's autofill service while the view could take no input (its offer's sign-in took
  /// the app out of sight, which lets the view go): its account and password, sent as the view drives again
  mut fill_owed : (String, String)?
  /// a state heard from the view since it was opened (again): input goes to it only then
  mut heard : Bool
  /// signing the page's passkey sign-in on this device (screen_passkey.mbt): where it is (`asking`, `said`; "" nothing
  /// under way), the ask under way, what it said where it did not sign, and the page's ask it is for
  passkey_step : @signals.Signal[String]
  /// the passkey prompt `id` dismissed by `×`, cleared once the page's ask leaves or changes
  passkey_dismissed : @signals.Signal[String?]
  mut passkey_run : @hostapi.PasskeyRun?
  mut passkey_note : String
  mut passkey_id : String
  mut passkey_gen : Int
  mut passkey_owner_principal : String
  /// lease key held for in-flight passkey keepalive (`""` when idle)
  mut passkey_keepalive_key : String
  /// silently muted while kept alive solely by passkey_keepalive with no visible UI holder
  mut passkey_muted : Bool
  /// last sequence number passed to `ScreenSess::route` (used to refresh native audio routing on mute change)
  mut route_seq : Double
  /// a child browser popup opened from this tab while driving (`childOpened` / `childScreen`), to open over it once built
  mut child_screen : String?
  /// consecutive `auth_stale` stream failures retried automatically since last heard state or manual open
  mut auth_stale_retries : Int
}

///|
/// The views open, by their page's key (screen_key).
let screens_open : Map[String, ScreenSess] = Map([])

///|
/// How many views this app has opened: each one's name (`mbui-<n>`) its own, the same in every run of the same steps.
let screens_made : Ref[Int] = Ref(0)

///|
/// The frame 自动 asks for before the stage it is shown on is laid out (then as large as the stage is: stage_px).
let screen_max_w : Int = 1920

///|
let screen_max_h : Int = 1080

///|
/// Hook for PR-B2s to mix `auth_gen` into the screen principal key.
// kept across runs: put back as a run begins (pages.mbt's reset)
let screen_auth_gen : Ref[Int] = Ref(0)

///|
fn screen_workspace_and_station(station : String) -> (String, String) {
  match station.find("/") {
    Some(i) => (station.exact_view(end=i).to_owned(), station.exact_view(start=i + 1).to_owned())
    None => ("", station)
  }
}

///|
fn screen_owner_of(station : String) -> String {
  let (ws, _) = screen_workspace_and_station(station)
  @sfbase.workspace_owner_of(ws)
}

///|
/// Unified subject principal for screen isolation: `(ws_account_owner, screen_auth_gen)` using `\u{2}` separator.
fn screen_principal_for(station : String) -> String {
  screen_owner_of(station) + "\u{2}" + screen_auth_gen.val.to_string()
}

///|
/// Unified subject-isolated key for a specific `owner` account (used by standalone window lifecycle callbacks).
fn screen_key_for_owner(owner : String, station : String, screen : String) -> String {
  let (ws, st) = screen_workspace_and_station(station)
  owner + "\u{2}" + screen_auth_gen.val.to_string() + "\u{2}" + ws + "\u{2}" + st + "\u{2}" + screen
}

///|
/// Unified subject-isolated key for screen sessions, UI state, and visibility leases:
/// `(ws_account_owner, screen_auth_gen, workspace, station, screen)`.
fn screen_key(station : String, screen : String) -> String {
  screen_key_for_owner(screen_owner_of(station), station, screen)
}

///|
/// Public alias of `screen_key` for callers (e.g. `sfdesk/panel_node.mbt`) to capture the creation-time screen key.
pub fn screen_key_of(station : String, screen : String) -> String {
  screen_key(station, screen)
}

///|
/// Whether this session is still valid for the current subject principal (not revoked, workspace not revoked, and
/// owner/auth_gen unchanged).
fn ScreenSess::is_active_principal(self : ScreenSess) -> Bool {
  !self.revoked &&
  self.account != "\u{3}revoked" &&
  self.account != "\u{3}pending" &&
  !@sfbase.workspace_is_revoked(self.workspace) &&
  !@sfbase.workspace_is_pending(self.workspace) &&
  self.principal == screen_principal_for(self.station)
}

///|
/// The view of `screen` on `station`, made the first time its page asks.
fn screen_sess(src : Source, station : String, screen : String) -> ScreenSess {
  let (ws, _) = screen_workspace_and_station(station)
  let account = @sfbase.workspace_owner_of(ws)
  let principal = screen_principal_for(station)
  let key = screen_key(station, screen)
  match screens_open.get(key) {
    Some(s) => s
    None => {
      screens_made.val += 1
      let s : ScreenSess = {
        src,
        account,
        workspace: ws,
        principal,
        revoked: false,
        station,
        screen,
        view: "mbui-\{screens_made.val}",
        state: None,
        said: @signals.signal(0),
        cursor_said: @signals.signal(0),
        pointer_layer: None,
        cursor_pos: None,
        cursor_shape_now: "default",
        cursor_apart: false,
        cursor_drawn: true,
        custom_cursors: Map([]),
        copied_told: @signals.signal(0),
        drops_told: @signals.signal(0),
        streams_told: @signals.signal(0),
        part_told: @signals.signal(0),
        part_was: None,
        size_was: None,
        failure: @signals.signal(None),
        finished: @signals.signal(false),
        audio_ready: @signals.signal(false, same=fn(a, b) { a == b }),
        audio_muted: @signals.signal(false, same=fn(a, b) { a == b }),
        mic_on: @signals.signal(false, same=fn(a, b) { a == b }),
        codec: None,
        size: None,
        shown_any: false,
        wants_control: None,
        pad_set: @signals.signal(None),
        gamepad_mouse_set: @signals.signal(None),
        fit: None,
        call: 0,
        acked: -1.0,
        stream: None,
        part: None,
        part_codec: None,
        parting: false,
        part_next: None,
        parts: [],
        looked: "",
        copied: [],
        drops: [],
        drops_serial: 0,
        pumping: false,
        pasting: @signals.signal(false, same=fn(a, b) { a == b }),
        frames: 0,
        bytes: 0,
        asked: "",
        asked_fps: 0,
        asked_bitrate: 0,
        asked_chroma444: false,
        asked_bounds: (0, 0),
        stage_px: (0, 0),
        fill_step: @signals.signal(""),
        fill_dismissed: @signals.signal(None),
        fill_run: None,
        fill_choices: [],
        fill_note: "",
        fill_host: "",
        fill_owed: None,
        heard: false,
        passkey_step: @signals.signal(""),
        passkey_dismissed: @signals.signal(None),
        passkey_run: None,
        passkey_note: "",
        passkey_id: "",
        passkey_gen: 0,
        passkey_owner_principal: "",
        passkey_keepalive_key: "",
        passkey_muted: false,
        route_seq: 0.0,
        child_screen: None,
        auth_stale_retries: 0,
      }
      screens_open[key] = s
      s
    }
  }
}

///|
/// The decoder of a part's frames, made the first time one comes (acknowledged as the whole's are).
fn ScreenSess::part_stream(self : ScreenSess) -> @ui.Stream {
  match self.part {
    Some(st) => st
    None => {
      let st = @ui.Stream::new(
        shown=fn(ts) {
          let wait_us = self.part.map(fn(s) { s.wait_us() }).unwrap_or(0.0)
          screen_ack(self.src, self, ts, wait_us~)
          self.shown_told()
        },
        broken=fn() {
          if self.is_active_principal() {
            screen_tell(self.src, "screen.keyframe", { "view": Json::string(self.view) })
          }
        },
        // on the system's video layer too, over the whole's: a frame of the part shown now shown as it comes, one of
        // another part (or while the whole's shows) drawn, the picture put where its part is
        layer=true,
        quiet=Some(fn(ts) {
          match self.part_shown() {
            Some(now) => self.part_at(ts) == Some(now)
            None => false
          }
        }),
        // (another part's first frame placed where that part is in the frame that shows it, not after it is painted:
        // it would be drawn a frame at the last part's place, the picture jumping as a pinch comes to rest)
        latched=Some(fn(_) { self.shown_told() }),
      )
      self.part = Some(st)
      self.streams_told.set(self.streams_told.untracked() + 1)
      st
    }
  }
}

///|
/// The part a frame of `ts` of the part's decoder shows (the last begun by then).
fn ScreenSess::part_at(self : ScreenSess, ts : Double) -> Part? {
  let mut at = None
  for p in self.parts {
    if p.0 <= ts {
      at = Some(p.1)
    }
  }
  at
}

///|
/// The part of the screen drawn over the whole now, and where: while the part's decoder shows a frame newer than the
/// whole's, the part that frame shows; else none.
fn ScreenSess::part_shown(self : ScreenSess) -> Part? {
  guard self.part is Some(pst) && pst.shown_at() is Some(at) else { return None }
  match self.stream.bind(fn(st) { st.shown_at() }) {
    Some(whole) if whole >= at => return None
    _ => ()
  }
  let mut shown = None
  for p in self.parts {
    if p.0 <= at {
      shown = Some(p.1)
    }
  }
  shown
}

///|
/// A frame of either stream shown, or a config taken: where the part shown over the whole or the frame's size is another
/// than it was, told (what places the pictures and fits them reads it).
fn ScreenSess::shown_told(self : ScreenSess) -> Unit {
  let now = self.part_shown()
  let size = self.frame_size()
  if now != self.part_was || size != self.size_was {
    self.part_was = now
    self.size_was = size
    self.part_told.set(self.part_told.untracked() + 1)
  }
}

///|
/// The part of the screen shown (None: the whole), in `w` × `h` of this device's pixels: told the core when it is
/// another than the last told (the core asks the station once it has stayed a moment). The whole is told only after a
/// part was.
fn ScreenSess::look(self : ScreenSess, src : Source, part : Part?, w : Double, h : Double) -> Unit {
  if !self.is_active_principal() {
    return
  }
  let r4 = fn(v : Double) { (v * 10000.0).round() / 10000.0 }
  let key = match part {
    Some(p) => "\{r4(p.x)} \{r4(p.y)} \{r4(p.w)} \{r4(p.h)} \{w.round()} \{h.round()}"
    None => ""
  }
  if key == self.looked || self.call == 0 {
    return
  }
  self.looked = key
  let region = match part {
    Some(p) =>
      Json::object({
        "x": Json::number(r4(p.x)),
        "y": Json::number(r4(p.y)),
        "w": Json::number(r4(p.w)),
        "h": Json::number(r4(p.h)),
      })
    None => Json::null()
  }
  screen_tell(src, "screen.look", {
    "view": Json::string(self.view),
    "region": region,
    "width": Json::number(w.round()),
    "height": Json::number(h.round()),
  })
}

///|
/// Its picture's stream, made as the view is first opened (screen_view.mbt's screen_life_node: what it says once shown, the
/// station's frame taken, a key frame asked for, tells the core, which no build does).
fn ScreenSess::own_stream(self : ScreenSess) -> Unit {
  if self.stream is Some(_) {
    return
  }
  self.stream = Some(
    @ui.Stream::new(
      shown=fn(ts) {
        let first = !self.shown_any
        self.shown_any = true
        let wait_us = self.stream.map(fn(s) { s.wait_us() }).unwrap_or(0.0)
        screen_ack(self.src, self, ts, wait_us~)
        if first {
          self.part_told.set(self.part_told.untracked() + 1)
        }
        self.shown_told()
      },
      broken=fn() {
        if self.is_active_principal() {
          screen_tell(self.src, "screen.keyframe", { "view": Json::string(self.view) })
        }
      },
      // shown by the system's video layer where the host has one (its node's, ui's stream: screen_stage_picture): a
      // frame of it draws nothing of the app's, unless a part is drawn over it (a frame of the whole newer than the
      // part's puts the part away)
      layer=true,
      quiet=Some(fn(_) { self.part_shown() is None }),
      // (a frame of the whole newer than the part's puts the part away in the frame that shows it)
      latched=Some(fn(_) { self.shown_told() }),
    ),
  )
  self.streams_told.set(self.streams_told.untracked() + 1)
}

///|
/// A call nobody waits for (`screen.ack`): sent in order with the rest, its
/// answer (or error) let go.
fn screen_tell(src : Source, name : String, params : Map[String, Json]) -> Unit {
  (src.call)(name, Json::object(params), @sfbase.answer_unread)
}

///|
fn screen_ack(src : Source, s : ScreenSess, ts : Double, wait_us? : Double = 0.0) -> Unit {
  if !s.is_active_principal() || ts <= s.acked {
    return
  }
  s.acked = ts
  // (its call: where the engine's shell reads the view itself, the ack goes from there: src/stillfail's call)
  let params : Map[String, Json] = {
    "view": Json::string(s.view),
    "ts": Json::number(ts),
    "call": Json::number(s.call.to_double()),
  }
  if wait_us > 0.0 {
    params["waitUs"] = Json::number(wait_us)
  }
  screen_tell(src, "screen.ack", params)
}

///|
/// What the phase is as the viewer shows it: the call's own failure and end over what the state last said.
fn ScreenSess::phase(self : ScreenSess) -> String {
  // this machine's own display: never opened (own_screen), said so in its place
  if own_screen(self.station, self.screen) {
    return "here"
  }
  if self.failure.get() is Some(_) {
    return "failed"
  }
  let p = match opt_text(self.state, "phase") {
    Some(p) => p
    None => "connecting"
  }
  if self.finished.get() && (p == "connecting" || p == "live" || p == "reconnecting") {
    "ended"
  } else {
    p
  }
}

///|
/// Why, in the viewer's words, for a phase that needs saying.
fn ScreenSess::message(self : ScreenSess) -> String? {
  if own_screen(self.station, self.screen) {
    return Some(@sf.t("android-misc.screen.hereWhy"))
  }
  match self.failure.get() {
    Some(f) => Some(f)
    None => opt_text(self.state, "message")
  }
}

///|
/// The view is open (on its way, live, or back on its way), not over.
fn ScreenSess::open_now(self : ScreenSess) -> Bool {
  let p = self.phase()
  p == "connecting" || p == "live" || p == "reconnecting"
}

///|
/// Input goes to the station now: it is live and driven by this viewer.
fn ScreenSess::driving(self : ScreenSess) -> Bool {
  self.phase() == "live" && flag(self.state, "control")
}

///|
/// Input reaches the station now: the view is open (not let go of out of sight) and has said since it opened that it
/// is live and driven by this viewer.
fn ScreenSess::input_goes(self : ScreenSess) -> Bool {
  self.call != 0 && self.heard && self.driving()
}

///|
/// 控制 or 只看 as the view is meant to be now: as chosen, else as the core opened it (只看 while another drives).
fn ScreenSess::controlling(self : ScreenSess) -> Bool {
  match self.wants_control {
    Some(on) => on
    None => !flag(self.state, "takeOver")
  }
}

///|
/// Someone else (an agent) drives it and this view only looks, but may take it over (接管).
fn ScreenSess::can_take_over(self : ScreenSess) -> Bool {
  self.phase() == "live" && flag(self.state, "takeOver")
}

///|
/// 只看 / 控制, while it may be driven and the view is open.
fn ScreenSess::choosable(self : ScreenSess) -> Bool {
  flag(self.state, "may") && self.open_now()
}

///|
/// What the screen's clipboard carries both ways (`text`, `png`), while this viewer drives it: none while only
/// looking, nor from a station (or helper) from before them.
fn ScreenSess::clip_types(self : ScreenSess) -> Array[String] {
  if !self.driving() {
    return []
  }
  items(self.state, "clipboard").filter_map(fn(j) {
    match j {
      String(t) => Some(t)
      _ => None
    }
  })
}

///|
/// The device's clipboard is pasted into the screen (`screen.clipboard`): driving it, and the station carries some.
fn ScreenSess::pastes(self : ScreenSess) -> Bool {
  self.clip_types().iter().any(fn(t) { t == "text" || t == "png" })
}

///|
/// Whether this viewer drives a browser screen whose station supports URL navigation (`screen.openUrl` / `screen.reload`).
fn ScreenSess::opens_url(self : ScreenSess) -> Bool {
  self.driving() && flag(self.state, "openUrl")
}

///|
/// Whether this screen is one of the station's user-opened browser pages (`browser:u_<id>`).
fn ScreenSess::user_tab(self : ScreenSess) -> Bool {
  flag(self.state, "userTab") || self.screen.has_prefix("browser:u_")
}

///|
/// Where a file picked goes on the screen's machine, while driving it (none from a station before files).
fn ScreenSess::drops_to(self : ScreenSess) -> DropTo? {
  if !self.driving() {
    return None
  }
  match field(self.state, "drop") {
    Some(Object(_) as d) => {
      let folder = text(Some(d), "folder")
      if folder == "" {
        None
      } else {
        Some({ folder, reveal: flag(Some(d), "reveal"), install: false })
      }
    }
    _ => None
  }
}

///|
/// Why it is not driven though 控制 was chosen, live (the station lacks a grant: macOS's Accessibility), in the
/// station's words; None when it is driven, or only looked at.
fn ScreenSess::undriven(self : ScreenSess) -> String? {
  guard self.state is Some(_) else { return None }
  if self.phase() != "live" ||
    !self.controlling() ||
    flag(self.state, "control") ||
    !flag(self.state, "may") ||
    flag(self.state, "takeOver") {
    return None
  }
  let why = text(field(self.state, "access"), "message")
  if why == "" {
    None
  } else {
    Some(why)
  }
}

///|
/// The screen's display resolution while this viewer drives one whose station changes it (Windows): now, and the modes
/// it takes (landscape, the largest first); None elsewhere, or while only looking.
fn ScreenSess::resolution(self : ScreenSess) -> ((Int, Int), Array[(Int, Int)])? {
  if !self.driving() {
    return None
  }
  match field(self.state, "resolution") {
    Some(Object(_)) as r => {
      let modes = items(r, "modes").filter_map(fn(j) {
        let m = Some(j)
        let (w, h) = (number(m, "width").to_int(), number(m, "height").to_int())
        if w > 0 && h > 0 {
          Some((w, h))
        } else {
          None
        }
      })
      if modes.is_empty() {
        None
      } else {
        Some(((number(r, "width").to_int(), number(r, "height").to_int()), modes))
      }
    }
    _ => None
  }
}

///|
/// The mode of `modes` whose shape is nearest the stage's (`w`×`h`, as this device shows the screen): the one that
/// fills it best, the larger of two as near.
fn resolution_fitting(modes : Array[(Int, Int)], w : Double, h : Double) -> Int {
  if modes.is_empty() || w <= 0.0 || h <= 0.0 {
    return -1
  }
  let want = w / h
  let mut best = 0
  let mut off = @double.infinity
  for i, m in modes {
    // (how many times wider or narrower than the stage's shape, 1 the same)
    let k = m.0.to_double() / m.1.to_double() / want
    let d = if k >= 1.0 { k } else { 1.0 / k }
    // (the largest first: a later one only when nearer by more than a rounding's)
    if d < off - 0.001 {
      best = i
      off = d
    }
  }
  best
}

///|
/// The modes worth offering of `modes` (the largest first): of each shape (its width to its height, to a tenth) the
/// three largest, with the one it is at now (`now`) and the one nearest this device's (`fits`, its index; -1 none) kept
/// whatever their shape; in the order they came. A display offers some two dozen, most of them the same shapes
/// smaller: a list too long to pick from on a phone (the user, 2026-10-29).
fn resolution_shown(modes : Array[(Int, Int)], now : (Int, Int), fits : Int) -> Array[(Int, Int)] {
  let per : Map[Int, Int] = Map([])
  let shown : Array[(Int, Int)] = []
  for i, m in modes {
    let shape = (m.0.to_double() / m.1.to_double() * 10.0).round().to_int()
    let had = per.get(shape).unwrap_or(0)
    per[shape] = had + 1
    if had < 3 || m == now || i == fits {
      shown.push(m)
    }
  }
  shown
}

///|
/// The device's media volume while this viewer drives one whose station reads it (an Android device's): its level and
/// its most; None elsewhere (a simulator's, whose volume is only its keys), or while only looking.
fn ScreenSess::volume(self : ScreenSess) -> (Double, Double)? {
  if !self.driving() {
    return None
  }
  match field(self.state, "volume") {
    Some(Object(_)) as v if number(v, "max") > 0.0 => Some((number(v, "level"), number(v, "max")))
    _ => None
  }
}

///|
/// The screen's display scale while this viewer drives one whose station changes it (Windows): now, the one its system
/// recommends, the steps it takes (in percent, lowest first); None elsewhere, or while only looking.
fn ScreenSess::scale(self : ScreenSess) -> (Int, Int, Array[Int])? {
  if !self.driving() {
    return None
  }
  match field(self.state, "scale") {
    Some(Object(_)) as sc => {
      let steps = items(sc, "steps").filter_map(fn(j) {
        match j {
          Number(n, ..) => Some(n.to_int())
          _ => None
        }
      })
      if steps.is_empty() {
        None
      } else {
        Some((number(sc, "percent").to_int(), number(sc, "recommended").to_int(), steps))
      }
    }
    _ => None
  }
}

///|
/// Where the station says its pointer is (0..1 of the frame), when it says.
fn ScreenSess::cursor(self : ScreenSess) -> (Double, Double)? {
  self.cursor_pos
}

///|
/// Where pointer word `c` (a state's `cursor`, or one said alone) says it is (0..1 of the frame), and its shape (the
/// arrow's where it says none); none, the arrow, where it says no pointer.
fn cursor_of(c : Json?) -> ((Double, Double)?, String) {
  match c {
    Some(Object(_)) => {
      let at = match (field(c, "x"), field(c, "y")) {
        (Some(Number(x, ..)), Some(Number(y, ..))) => Some((x, y))
        _ => None
      }
      (
        at,
        match text(c, "shape") {
          "" => "default"
          shape => shape
        },
      )
    }
    _ => (None, "default")
  }
}

///|
/// The station's pointer as word `c` says it (ScreenSess::cursor, pointer_shape read it).
fn ScreenSess::cursor_is(self : ScreenSess, c : Json?) -> Unit {
  let (at, shape) = cursor_of(c)
  self.cursor_pos = at
  self.cursor_shape_now = shape
}

///|
/// The frame's size in pixels: the picture's as the stream last showed it, else (none yet) the config's.
fn ScreenSess::frame_size(self : ScreenSess) -> (Int, Int)? {
  // the picture's as it shows: a config says the next one's size before that is decoded (a device turned), the one showing
  // squashed into it till then
  match self.stream {
    Some(st) if st.size() is Some(_) => st.size()
    _ => self.size
  }
}

///|
/// An iOS Simulator: a touchscreen, a finger on it where it touches (no trackpad to choose, no mouse's buttons).
fn ScreenSess::simulator(self : ScreenSess) -> Bool {
  text(self.state, "kind") == "simulator"
}

///|
/// A finger drives it as a trackpad (it moves the pointer, a tap clicks where that points), or directly (a tap clicks
/// where it is): as chosen here, else directly on a simulator (a touchscreen) or a page laid out for this device (`fit`:
/// a tap is where it is, as in the device's own browser), else as this device keeps it (`prefs.screenTouch`).
fn ScreenSess::pad(self : ScreenSess, src : Source) -> Bool {
  match self.pad_set.get() {
    Some(on) => on
    None if self.simulator() => false
    None if self.fit is Some(_) && text(self.state, "kind") == "browser" => false
    None => text(src.topic("prefs", {}).get().value, "screenTouch") != "direct"
  }
}

///|
/// The host's virtual gamepad support while driving: (native_available, driver, mouse_emulation_on);
/// None while only looking or from an older station that does not report gamepad state.
fn ScreenSess::gamepad(self : ScreenSess) -> (Bool, String, Bool)? {
  if !self.driving() {
    return None
  }
  match field(self.state, "gamepad") {
    Some(Object(_)) as g => Some((flag(g, "native"), text(g, "driver"), flag(g, "mouse")))
    _ => None
  }
}

///|
/// How large a picture this device asks for (prefs `screenQuality`, 控制中心's 串流分辨率): `smooth`, `hd`, `qhd`, `uhd`,
/// `original`, or "" (自动: as large as the stage it is shown on, in device pixels: ScreenSess::bounds).
fn screen_quality(src : Source) -> String {
  match text(src.topic("prefs", {}).get().value, "screenQuality") {
    "smooth" | "hd" | "qhd" | "uhd" | "original" as q => q
    _ => ""
  }
}

///|
/// The bitrate ceiling in Mbps (prefs `screenBitrate`, 控制中心's 码率): 0 for 自动.
fn screen_bitrate(src : Source) -> Int {
  let n = number(src.topic("prefs", {}).get().value, "screenBitrate").to_int()
  if screen_bitrate_choices.contains(n) && n > 0 {
    n
  } else {
    0
  }
}

///|
/// 码率's choices in Mbps, 自动 (0) first.
// kept across runs: a table, never written
let screen_bitrate_choices : Array[Int] = [0, 5, 10, 20, 35, 50, 80, 100]

///|
/// Whether 4:4:4 chroma is enabled on this device (prefs `screenChroma444`, 控制中心's 4:4:4 色彩).
fn screen_chroma444(src : Source) -> Bool {
  flag(src.topic("prefs", {}).get().value, "screenChroma444")
}

///|
/// Whether this device's decoder can decode H.265 4:4:4 (Apple VideoToolbox; Android/Windows take Main/Main10 only).
fn screen_decodes_444() -> Bool {
  @ui.h265_here() && (@ui.platform() == 0 || @ui.platform() == 1)
}

///|
/// Whether gamepad mouse/keyboard emulation is enabled on this device (prefs `screenGamepadMouse`, default false).
fn screen_gamepad_mouse(src : Source) -> Bool {
  flag(src.topic("prefs", {}).get().value, "screenGamepadMouse")
}

///|
/// The most frames a second this device asks for (prefs `screenFps`, 控制中心's 帧率): 120, 90, 60, 30 or 15, or 0 (自动:
/// as many as the station and the link give).
fn screen_fps(src : Source) -> Int {
  let n = number(src.topic("prefs", {}).get().value, "screenFps").to_int()
  if screen_fps_choices.contains(n) && n > 0 {
    n
  } else {
    0
  }
}

///|
/// 帧率's choices, 自动 (0) first.
// kept across runs: a table, never written
let screen_fps_choices : Array[Int] = [0, 120, 90, 60, 30, 15]

///|
/// The 串流分辨率, 帧率, 码率 and 4:4:4 a view is asked with besides its size (none for 自动): `screen.view`'s and `screen.bounds`'s.
fn asks_into(params : Map[String, Json], quality : String, fps : Int, bitrate : Int, chroma444 : Bool) -> Unit {
  if quality != "" {
    params["quality"] = Json::string(quality)
  }
  if fps > 0 {
    params["fps"] = Json::number(fps.to_double())
  }
  if bitrate > 0 {
    params["bitrate"] = Json::number((bitrate * 1_000_000).to_double())
  }
  if chroma444 {
    params["chroma444"] = Json::boolean(true)
  }
}

///|
/// The bounds a 串流分辨率 asks for: `original` the largest a view may ask (the screen's own
/// size); 自动 as large as the stage the picture is shown on, in this device's pixels (the user, 2026-10-29: a 4K
/// window was sent 1920×1080 and its text blurred), screen_max_w × screen_max_h before it is laid out.
fn ScreenSess::bounds(self : ScreenSess, quality : String) -> (Int, Int) {
  match quality {
    "smooth" => (1280, 720)
    "hd" => (1920, 1080)
    "qhd" => (2560, 1440)
    "uhd" => (3840, 2160)
    "original" => (7680, 4320)
    _ =>
      match self.stage_px {
        (w, h) if w > 0 && h > 0 => (@cmp.minimum(w, 7680), @cmp.minimum(h, 4320))
        _ => (screen_max_w, screen_max_h)
      }
  }
}

///|
/// The stage the picture is shown on laid out `w` × `h` device pixels: 自动 asks that large from now where it is a
/// tenth larger a side than the most it had (a window made larger by a little, as it is dragged, asks nothing again;
/// one made smaller keeps what it asked).
fn ScreenSess::stage_is(self : ScreenSess, w : Int, h : Int) -> Unit {
  let (pw, ph) = self.stage_px
  if w * 10 > pw * 11 || h * 10 > ph * 11 {
    self.stage_px = (@cmp.maximum(w, pw), @cmp.maximum(h, ph))
  }
}

///|
/// Opens the view (again: after a pause, or 重新打开): `screen.view`, the frames it can decode said (H.265 first where
/// the host decodes it, H.264 where it does), as large as 画质 asks, and the 画质 itself (how high the station lets the
/// bit rate go) and the 帧率 (the most frames a second it sends).
fn ScreenSess::open(self : ScreenSess, src : Source) -> Unit {
  if !self.is_active_principal() || self.call != 0 || own_screen(self.station, self.screen) {
    return
  }
  // again after it ended (重新打开): on its way, not still saying how the last one ended
  if self.finished.get() || self.failure.get() is Some(_) {
    self.state = None
    self.auth_stale_retries = 0
  }
  self.failure.set(None)
  self.finished.set(false)
  // (a call of its own: the part in sight told it again)
  self.looked = ""
  // (input waits for the view opened again to say it is live: the state before is the last one's)
  self.heard = false
  let quality = screen_quality(src)
  let fps = screen_fps(src)
  let bitrate = screen_bitrate(src)
  let chroma444 = screen_decodes_444() && screen_chroma444(src)
  self.asked = quality
  self.asked_fps = fps
  self.asked_bitrate = bitrate
  self.asked_chroma444 = chroma444
  let (mw, mh) = self.bounds(quality)
  self.asked_bounds = (mw, mh)
  let codecs = if @ui.h264_here() {
    [Json::string("h264"), Json::string("jpeg")]
  } else {
    [Json::string("jpeg")]
  }
  if @ui.h265_here() {
    codecs.insert(0, Json::string("h265"))
  }
  let params : Map[String, Json] = {
    "station": Json::string(self.station),
    "screen": Json::string(self.screen),
    "view": Json::string(self.view),
    "codecs": Json::array(codecs),
    "maxWidth": Json::number(mw.to_double()),
    "maxHeight": Json::number(mh.to_double()),
    "passkeys": Json::boolean(@hostapi.passkeys()),
    // (its pointer may be said on its own, `cursor`, rather than in a whole state each time it moves)
    "cursorUpdates": Json::boolean(true),
  }
  asks_into(params, quality, fps, bitrate, chroma444)
  if screen_gamepad_mouse(src) {
    params["gamepadMouse"] = Json::boolean(true)
  }
  if @ui.stream_audio_here() {
    params["audio"] = Json::string("pcm_s16le")
    // (muted here: the station sends none from the start, `screen.sound`)
    if self.audio_muted.untracked() { params["sound"] = Json::boolean(false) }
  }
  // Shown by the system's video layer (its frames tagged colours honoured, a wide-gamut screen's shown as wide): the
  // Mac's desktop sent in Display P3; the app's canvas (a faded or ended view's picture) has it converted to sRGB.
  if @ui.stream_layers_here() { params["gamut"] = Json::string("p3") }
  match self.fit {
    Some((w, h, scale)) =>
      params["fit"] = Json::object({
        "width": Json::number(w.round()),
        "height": Json::number(h.round()),
        "scale": Json::number(scale),
      })
    None => ()
  }
  // not said until the person chooses: the core decides (only looking while another drives)
  match self.wants_control {
    Some(on) => params["control"] = Json::boolean(on)
    None => ()
  }
  let me = self
  let in_open = Ref(true)
  self.call = (src.stream)(
    "screen.view",
    Json::object(params),
    None,
    fn(value, bytes) { me.take(value, bytes) },
    fn(r) {
      me.call = 0
      me.audio_ready.set(false)
      match me.stream { Some(st) => st.audio(Bytes::make(0, b'\x00')); None => () }
      match r {
        Ok(_) => me.finished.set(true)
        Err(e) =>
          if text(Some(e), "code") == "auth_stale" &&
            !in_open.val &&
            me.is_active_principal() &&
            me.auth_stale_retries < 2 {
            me.auth_stale_retries += 1
            me.open(src)
          } else {
            me.failure.set(Some(text(Some(e), "message")))
          }
      }
    },
  )
  in_open.val = false
}

///|
/// 画质 or 帧率 chosen otherwise since the open view was asked, or 自动's stage grown (stage_is): the view goes on, its
/// pictures asked this large and this often (`screen.bounds`: the core opens its stream again, the one before kept until the new one has opened, so a
/// Windows desktop keeps the display scale set from it), the frame on screen kept meanwhile.
fn ScreenSess::asked_again(self : ScreenSess, src : Source) -> Unit {
  if !self.is_active_principal() {
    return
  }
  let quality = screen_quality(src)
  let fps = screen_fps(src)
  let bitrate = screen_bitrate(src)
  let chroma444 = screen_decodes_444() && screen_chroma444(src)
  let (mw, mh) = self.bounds(quality)
  if self.call == 0 ||
    (self.asked == quality &&
      self.asked_fps == fps &&
      self.asked_bitrate == bitrate &&
      self.asked_chroma444 == chroma444 &&
      self.asked_bounds == (mw, mh)) {
    return
  }
  self.asked = quality
  self.asked_fps = fps
  self.asked_bitrate = bitrate
  self.asked_chroma444 = chroma444
  self.asked_bounds = (mw, mh)
  let params : Map[String, Json] = {
    "view": Json::string(self.view),
    "maxWidth": Json::number(mw.to_double()),
    "maxHeight": Json::number(mh.to_double()),
  }
  asks_into(params, quality, fps, bitrate, chroma444)
  screen_tell(src, "screen.bounds", params)
}

///|
/// Stops viewing (the app went out of sight); the last frame stays, `open` goes on from it.
fn ScreenSess::pause(self : ScreenSess, src : Source) -> Unit {
  self.audio_ready.set(false)
  match self.stream { Some(st) => st.audio(Bytes::make(0, b'\x00')); None => () }
  if self.call != 0 {
    (src.cancel)(self.call)
    self.call = 0
  }
}

///|
/// Ends it for good: the view, the decoder, the files still going up.
fn ScreenSess::close(self : ScreenSess, src : Source) -> Unit {
  self.pause(src)
  self.passkey_stop()
  self.drops.clear()
  match self.stream {
    Some(st) => st.close()
    None => ()
  }
  match self.part {
    Some(st) => st.close()
    None => ()
  }
}

///|
/// 只看 or 控制: the core opens the view again with it, the frame on screen kept meanwhile.
fn ScreenSess::control(self : ScreenSess, src : Source, on : Bool) -> Unit {
  if !self.is_active_principal() {
    return
  }
  self.wants_control = Some(on)
  screen_tell(src, "screen.control", { "view": Json::string(self.view), "control": Json::boolean(on) })
}

///|
/// Input for the station (`screen.input`): only while this viewer drives it.
fn ScreenSess::input(self : ScreenSess, src : Source, input : Json) -> Unit {
  if !self.is_active_principal() {
    return
  }
  // (which of a desktop's windows it shows goes looking too: the view's own)
  let window = text(Some(input), "t") == "window"
  if !(self.input_goes() || (window && self.call != 0 && self.heard)) {
    return
  }
  // (its call: where the engine's shell drives the view itself, the input goes from there, as screen_ack's)
  screen_tell(src, "screen.input", {
    "view": Json::string(self.view),
    "input": input,
    "call": Json::number(self.call.to_double()),
  })
}

///|
/// Trackpad or direct, chosen: kept on this device for every screen (`prefs.set screenTouch`, null for the
/// trackpad); `done` gets the core's answer.
fn ScreenSess::choose_pad(
  self : ScreenSess,
  src : Source,
  on : Bool,
  done : (Result[Json, Json]) -> Unit,
) -> Unit {
  self.pad_set.set(Some(on))
  let v = if on { Json::null() } else { Json::string("direct") }
  (src.call)("prefs.set", Json::object({ "screenTouch": v }), done)
}

///|
/// `text` onto the screen's clipboard and pasted where its focus is (`screen.clipboard`).
fn ScreenSess::paste(
  self : ScreenSess,
  src : Source,
  words : String,
  done : (Result[Json, Json]) -> Unit,
) -> Unit {
  if !self.is_active_principal() {
    return
  }
  let p : Map[String, Json] = {
    "view": Json::string(self.view),
    "text": Json::string(words),
    "paste": Json::boolean(true),
  }
  (src.call)("screen.clipboard", Json::object(p), done)
}

///|
/// A PNG onto the screen's clipboard and pasted where its focus is (`screen.clipboard`, the picture beside the call).
fn ScreenSess::paste_png(
  self : ScreenSess,
  src : Source,
  png : Bytes,
  done : (Result[Json, Json]) -> Unit,
) -> Unit {
  if !self.is_active_principal() {
    return
  }
  let p : Map[String, Json] = {
    "view": Json::string(self.view),
    "png": Json::boolean(true),
    "paste": Json::boolean(true),
  }
  (src.call_bytes)("screen.clipboard", Json::object(p), png, done)
}

///|
/// A file dropped onto the machine, shown in its file manager (`screen.input` reveal).
fn ScreenSess::reveal(
  self : ScreenSess,
  src : Source,
  path : String,
  done : (Result[Json, Json]) -> Unit,
) -> Unit {
  if !self.is_active_principal() {
    return
  }
  let input = Json::object({ "t": Json::string("reveal"), "path": Json::string(path) })
  (src.call)("screen.input", Json::object({ "view": Json::string(self.view), "input": input }), done)
}

///|
/// Whether a value of `screen.view` changes nothing a frame reads, as ScreenSess::take takes it: a frame or a sound's
/// packet alone, handed to the decoder (which says what it shows: what it said is taken as the frame begins) and counted
/// where only 控制中心's second reads it; so the core takes it as it comes and builds nothing for it (@core.quiet, said
/// as the app starts: src/stillfail). A state, a config or a copy made on the screen changes what is shown: not so.
pub fn screen_value_quiet(value : Json) -> Bool {
  guard value is Object(o) else { return false }
  if o.length() > 0 && o.keys().all(fn(k) { k == "frame" || k == "audio" }) {
    return true
  }
  // a state that only moves the pointer of a view whose pointer is on its picture's layer (ScreenSess::take hands it
  // to the host); taken by another view, more changed there, its `said` tells what reads it
  match o.get("state") {
    Some(Object(_) as st) if o.length() == 1 =>
      screens_open.values().any(fn(s) { s.pointer_layer is Some(_) && cursor_moved_only(s.state, st) })
    // the pointer said alone, its shape the same: on a picture's layer the host told, or not drawn from what the
    // station says (this device's mouse, the trackpad's own, hidden), nothing drawn anew (ScreenSess::cursor_quiet)
    _ =>
      match o.get("cursor") {
        Some(c) if o.length() == 1 => screens_open.values().any(fn(s) { s.cursor_quiet(c) })
        _ => false
      }
  }
}

///|
/// Whether pointer word `c`, said alone, changes nothing drawn of this view: its shape the same, and where it points
/// drawn on a picture's layer (the host told, ScreenSess::pointer_moved), or not drawn from the station's word at all
/// (this device's mouse over the picture, the trackpad's pointer, hidden there).
fn ScreenSess::cursor_quiet(self : ScreenSess, c : Json) -> Bool {
  let (_, shape) = cursor_of(Some(c))
  shape == self.cursor_shape_now && (self.pointer_layer is Some(_) || !self.cursor_drawn || shape == "none")
}

///|
/// A pointer the station drew itself (`cursorImage` `ci`: its shape `custom:<hex>`, its size and hot spot in points; its
/// PNG `bytes`), kept where it is sound (1..128 points, its hot spot inside, a PNG of at most 64 KiB); what draws a
/// pointer of its shape said already, told.
fn ScreenSess::custom_cursor_taken(self : ScreenSess, ci : Json, bytes : Bytes?) -> Unit {
  let shape = text(Some(ci), "shape")
  let w = number(Some(ci), "w")
  let h = number(Some(ci), "h")
  let hx = number(Some(ci), "hx")
  let hy = number(Some(ci), "hy")
  guard shape.has_prefix("custom:") &&
    shape.length() <= 64 &&
    w >= 1.0 &&
    w <= 128.0 &&
    h >= 1.0 &&
    h <= 128.0 &&
    hx >= 0.0 &&
    hx <= w &&
    hy >= 0.0 &&
    hy <= h else {
    return
  }
  guard bytes is Some(png) && png.length() > 0 && png.length() <= 65536 && @pixels.is_png(png) else { return }
  if !self.custom_cursors.contains(shape) {
    if self.custom_cursors.length() >= custom_cursors_most {
      match self.custom_cursors.keys().next() {
        Some(old) => self.custom_cursors.remove(old)
        None => ()
      }
    }
    @ui.add_image(custom_cursor_key(shape), png)
  }
  self.custom_cursors[shape] = { png, w, h, hx, hy }
  if self.cursor_shape_now == shape {
    self.cursor_said.set(self.cursor_said.untracked() + 1)
  }
}

///|
/// Where the pointer is on a picture's system video layer, as the page has it drawn (screen_stage's
/// screen_pointer_layer_node): the stream it is drawn over, the part of the screen that one shows (None: the whole), and
/// whether it follows the station's pointer (not the trackpad's, nor hidden while this device's mouse drives it).
priv struct PointerLayer {
  on : @ui.Stream
  part : Part?
  follows : Bool
}

///|
/// Whether state `new` differs from `old` only in where the station's pointer is (its shape the same).
fn cursor_moved_only(old : Json?, new : Json) -> Bool {
  guard old is Some(Object(a)) && new is Object(b) && a.length() == b.length() else { return false }
  b.iter().all(fn(kv) {
    let (k, v) = kv
    match a.get(k) {
      Some(was) if k == "cursor" =>
        match (was, v) {
          (Object(c0), Object(c1)) =>
            c0.length() == c1.length() &&
            c0.get("shape") == c1.get("shape") &&
            c1.iter().all(fn(e) { e.0 == "shape" || e.0 == "x" || e.0 == "y" })
          _ => false
        }
      Some(was) => was == v
      None => false
    }
  })
}

///|
/// A point of the whole screen (0..1) on the picture of `part` (None: the whole): 0..1 of the part, outside it too.
fn point_on(at : (Double, Double), part : Part?) -> (Double, Double) {
  match part {
    Some(p) => ((at.0 - p.x) / p.w, (at.1 - p.y) / p.h)
    None => at
  }
}

///|
/// The station's pointer moved, nothing else of the state changed: where it is drawn on a picture's layer, the host told
/// (nothing drawn for it); while it is the trackpad's or hidden, nothing.
fn ScreenSess::pointer_moved(self : ScreenSess) -> Unit {
  guard self.pointer_layer is Some(pl) && pl.follows else { return }
  pl.on.pointer_at(self.cursor().map(fn(at) { point_on(at, pl.part) }))
}

///|
/// The calls of a screen whose answers nobody reads (screen_tell's `screen.ack` and `screen.input`): taken as they come, they build nothing
/// (@core.unread, said as the app starts).
pub fn screen_unread_calls() -> Array[String] {
  ["screen.ack", "screen.input"]
}

///|
/// A value of the call: taken apart, the heavy parts handed on. What screen_value_quiet says
/// changes nothing a frame reads is taken as it comes, before the frame is built: what a frame or a sound's packet sets
/// here is read by no build.
fn ScreenSess::take(self : ScreenSess, value : Json, bytes : Bytes?) -> Unit {
  if !self.is_active_principal() {
    return
  }
  guard value is Object(o) else { return }
  // the station's pointer said alone (no state rebuilt, nothing compared): on a picture's layer the host told; drawn
  // here, what draws it told; not drawn from it (the mouse's, the trackpad's, hidden) and its shape the same, nothing
  match o.get("cursor") {
    Some(c) => {
      let quiet = self.cursor_quiet(c)
      self.cursor_apart = true
      self.cursor_is(Some(c))
      if self.pointer_layer is Some(_) && quiet {
        self.pointer_moved()
      } else if !quiet {
        self.cursor_said.set(self.cursor_said.untracked() + 1)
      }
    }
    None => ()
  }
  // a pointer the station drew itself, its PNG in `bytes`: kept by the shape it is named (a pointer of that shape said
  // before it came, drawn again with it)
  match o.get("cursorImage") {
    Some(Object(_) as ci) => self.custom_cursor_taken(ci, bytes)
    _ => ()
  }
  match o.get("state") {
    Some(Object(_) as s) => {
      // the station's pointer alone moved: on a picture's layer, the host told, nothing drawn (screen_value_quiet); else
      // what draws it here told, nothing else
      let alone = self.state != Some(s) && cursor_moved_only(self.state, s)
      let layered = alone && self.pointer_layer is Some(_)
      // made to only look from elsewhere: 只看 as if chosen, 控制 a tap away
      if number(self.state, "watchOnly") != number(Some(s), "watchOnly") {
        self.wants_control = Some(false)
      }
      // taken by someone else as it drove, or taken from people by this view's 接管: said once each (a view opened again
      // starts its counts anew, none said)
      let names = fn(key) { strings(Some(s), key).join(@sf.t("web-main.list.separator")) }
      if number(Some(s), "taken") > number(self.state, "taken") {
        let by = names("takenBy")
        toast_later(
          if by == "" {
            @sf.t("android-misc.screen.taken")
          } else {
            @sf.t("android-misc.screen.takenBy", args=[("names", by)])
          },
        )
      }
      if number(Some(s), "took") > number(self.state, "took") {
        toast_later(@sf.t("android-misc.screen.took", args=[("names", names("tookFrom"))]))
      }
      if number(Some(s), "childOpened") > number(self.state, "childOpened") {
        let next = text(Some(s), "childScreen")
        if next != "" && next != self.screen {
          self.child_screen = Some(next)
        }
      }
      // (live and heard before: the screen's virtual microphone taken or let go of now, a live cause of its own)
      let was_live = self.heard && text(self.state, "phase") == "live"
      let was_mic = self.mic_active()
      self.state = Some(s)
      // (shared before the view was let go of, out of sight: said again to the view opened again, once it says it is
      // there, the core's view of it made by then)
      if !self.heard && self.mic_on.untracked() && self.call != 0 {
        screen_tell(self.src, "screen.micOn", { "view": Json::string(self.view), "on": Json::boolean(true) })
      }
      self.heard = true
      self.auth_stale_retries = 0
      // (where it says its pointer, or none; one said on its own kept where a state says nothing of it)
      match field(self.state, "cursor") {
        Some(c) => self.cursor_is(Some(c))
        None => if !self.cursor_apart { self.cursor_is(None) }
      }
      match self.fill_dismissed.untracked() {
        Some(was) if login_slot_of(self.state) != Some(was) => self.fill_dismissed.set(None)
        _ => ()
      }
      match self.passkey_dismissed.untracked() {
        Some(was) =>
          match text(field(self.state, "passkey"), "id") {
            id if id != was => self.passkey_dismissed.set(None)
            _ => ()
          }
        None => ()
      }
      if layered {
        self.pointer_moved()
      } else if alone {
        self.cursor_said.set(self.cursor_said.untracked() + 1)
      } else if was_live &&
        text(self.state, "phase") == "live" &&
        self.mic_active() != was_mic &&
        !@view.answering_now() {
        // (something there began or stopped recording it as it was watched: the bar's 麦克风 comes or goes along its
        // row; what this view comes to know of it as it is first told or told again after a break is there at once)
        @view.transition(fn() { self.said.set(self.said.untracked() + 1) })
      } else {
        self.said.set(self.said.untracked() + 1)
      }
    }
    _ => ()
  }
  match o.get("audioConfig") {
    Some(config) =>
      self.audio_ready.set(
        text(Some(config), "codec") == "pcm_s16le" && number(Some(config), "sampleRate") == 48000.0 && number(Some(config), "channels") == 2.0,
      )
    None => ()
  }
  if o.contains("audio") && !self.passkey_muted && @signals.untracked(fn() { self.audio_ready.get() && !self.audio_muted.get() }) {
    match (self.stream, bytes) { (Some(st), Some(data)) => st.audio(data); _ => () }
  }
  // (the engine's own read of the view numbers what it says: those after it the host may take, ScreenSess::route)
  let seq = match (o.get("frame"), o.get("audio")) {
    (Some(Object(_) as f), _) | (_, Some(Object(_) as f)) =>
      match field(Some(f), "n") {
        Some(Number(n, ..)) => Some(n)
        _ => None
      }
    _ => None
  }
  match o.get("config") {
    Some(Object(_) as c) => {
      let kind = text(Some(c), "codec")
      if kind != "" {
        let w = number(Some(c), "width").to_int()
        let h = number(Some(c), "height").to_int()
        // a part's frames to the part's decoder, the whole's to the whole's (whose size the stage is laid out by)
        let part = part_of(Some(c))
        self.parting = part is Some(_)
        self.part_next = part
        let st = if part is Some(_) { Some(self.part_stream()) } else { self.stream }
        match (bytes, st) {
          (Some(b), Some(st)) if kind == "h264" => st.h264(b, w, h)
          (Some(b), Some(st)) if kind == "h265" => st.hevc(b, w, h)
          _ => ()
        }
        if part is Some(_) {
          self.part_codec = Some(kind)
        } else {
          self.codec = Some(kind)
          if w > 0 && h > 0 {
            self.size = Some((w, h))
          }
          self.shown_told()
        }
      }
    }
    _ => ()
  }
  match o.get("clipboard") {
    Some(Object(_) as c) =>
      // for the device's clipboard: text, or a picture (its PNG beside, within the bound)
      match text(Some(c), "type") {
        "text" => {
          let t = text(Some(c), "text")
          // (a password manager's mark: the device's copy marked so too, screen_copies)
          let privacy = match text(Some(c), "privacy") {
            "concealed" | "transient" | "auto" as p => Some(p)
            _ => None
          }
          if t != "" {
            self.copied.push(CopiedText(t, privacy))
            self.copied_told.set(self.copied_told.untracked() + 1)
          }
        }
        "png" =>
          match bytes {
            Some(b) if b.length() > 0 && b.length() <= clip_png_max && @pixels.is_png(b) => {
              self.copied.push(CopiedPng(b))
              self.copied_told.set(self.copied_told.untracked() + 1)
            }
            _ => ()
          }
        _ => ()
      }
    _ => ()
  }
  match o.get("frame") {
    Some(Object(_) as f) => {
      guard field(Some(f), "ts") is Some(Number(ts, ..)) else { return }
      let key = flag(Some(f), "key")
      // a frame that brings nothing to show (no bytes, no codec yet): taken, as far as the station is concerned
      match bytes {
        None => screen_ack(self.src, self, ts)
        Some(b) => {
          self.frames += 1
          self.bytes += b.length()
          // a part's first frame after its config: the part it shows from (the parts its decoder shows no more let go)
          match self.part_next {
            Some(p) => {
              self.part_next = None
              let shown = self.part.bind(fn(st) { st.shown_at() }).unwrap_or(-1.0)
              let later = self.parts.filter(fn(q) { q.0 > shown })
              let now = self.parts.filter(fn(q) { q.0 <= shown }).last()
              self.parts.clear()
              match now {
                Some(q) => self.parts.push(q)
                None => ()
              }
              self.parts.append(later)
              self.parts.push((ts, p))
            }
            None => ()
          }
          let (codec, st) = if self.parting {
            (self.part_codec, self.part)
          } else {
            (self.codec, self.stream)
          }
          match (codec, st) {
            (Some("h264"), Some(st)) | (Some("h265"), Some(st)) =>
              st.frame(b, key, ts)
            (Some("jpeg"), Some(st)) => st.jpeg(b, ts)
            _ => screen_ack(self.src, self, ts)
          }
        }
      }
    }
    _ => ()
  }
  match seq {
    Some(n) => {
      self.route_seq = n
      self.route(n)
    }
    None => ()
  }
}

///|
/// Set or clear silent passkey keepalive mute, flushing any buffered audio and refreshing native direct audio routing.
fn ScreenSess::set_passkey_muted(self : ScreenSess, on : Bool) -> Unit {
  if self.passkey_muted == on {
    return
  }
  self.passkey_muted = on
  if on {
    match self.stream {
      Some(st) => st.audio(Bytes::make(0, b'\x00'))
      None => ()
    }
  }
  if self.call != 0 {
    self.route(self.route_seq)
  }
}

///|
/// The view's frames and sound after the `after`th the engine said (the last taken) taken by the host where they go,
/// straight from the engine (@ui's Stream::route), while that changes nothing the app draws: the frames to the stream
/// they show on (the whole's while no part shows over it, the part's while the last part begun shows), its picture on
/// its system video layer; the sound while it plays. Elsewhere, or as soon as that is not so, they come here as before.
fn ScreenSess::route(self : ScreenSess, after : Double) -> Unit {
  if self.call == 0 {
    return
  }
  let shown = self.part_shown()
  let to_part = self.parting &&
    self.part_next is None &&
    shown is Some(_) &&
    self.parts.last().map(fn(p) { p.1 }) == shown
  let to_whole = !self.parting && shown is None
  let audio = !self.passkey_muted && @signals.untracked(fn() { self.audio_ready.get() && !self.audio_muted.get() })
  match self.stream {
    Some(st) => st.route(self.call, after, video=to_whole, audio~)
    None => ()
  }
  match self.part {
    Some(st) => st.route(self.call, after, video=to_part, audio=false)
    None => ()
  }
}

///|
/// The frames that came and their bytes: those taken here and those the host took by its route (控制中心's 连接).
fn ScreenSess::came(self : ScreenSess) -> (Int, Int) {
  let mut frames = self.frames
  let mut bytes = self.bytes
  for st in [self.stream, self.part] {
    match st {
      Some(st) => {
        let (f, b) = st.direct_count()
        frames += f
        bytes += b
      }
      None => ()
    }
  }
  (frames, bytes)
}

///|
/// The most a clipboard carries of a picture, each way (client/core-ts/src/screen-frames.ts).
let clip_png_max : Int = 8 * 1024 * 1024


///|
fn ScreenSess::toggle_audio(self : ScreenSess) -> Unit {
  let muted = !self.audio_muted.untracked()
  self.audio_muted.set(muted)
  if muted { match self.stream { Some(st) => st.audio(Bytes::make(0, b'\x00')); None => () } }
  // Muted, the station sends the view no sound till it is on again.
  if self.call != 0 && self.is_active_principal() {
    screen_tell(self.src, "screen.sound", { "view": Json::string(self.view), "on": Json::boolean(!muted) })
  }
}

///|
/// The screen's virtual microphone while this viewer drives it (the state's `mic`): whether the screen has one, and
/// whether something on it records it now; neither while only looking, nor from a station (or a screen) without one,
/// nor where this device's microphone is not taken (mic_capture_here).
fn ScreenSess::mic_info(self : ScreenSess) -> (Bool, Bool) {
  if !self.driving() || !mic_capture_here() {
    return (false, false)
  }
  match field(self.state, "mic") {
    Some(Object(_)) as m => (flag(m, "available"), flag(m, "available") && flag(m, "active"))
    _ => (false, false)
  }
}

///|
/// Whether this device's microphone is taken where a view shares it: on a Mac (the core's engine,
/// src/host/apple_core.mm) and in a browser (web/src/mbui/screen-peripherals.ts); elsewhere nothing would go, so
/// nothing offers it.
fn mic_capture_here() -> Bool {
  let p = @ui.platform()
  p == 0 || p == 4
}

///|
/// The screen has a virtual microphone this viewer may share into (麦克风's tile, ScreenSess::mic_info).
fn ScreenSess::mic_available(self : ScreenSess) -> Bool {
  self.mic_info().0
}

///|
/// Something on the screen records its virtual microphone now (ScreenSess::mic_info).
fn ScreenSess::mic_active(self : ScreenSess) -> Bool {
  self.mic_info().1
}

///|
/// Whether the screen has a virtual microphone, followed (read again as the state is told).
fn ScreenSess::mic_available_now(self : ScreenSess) -> Bool {
  self.said.get() |> ignore
  self.mic_available()
}

///|
/// Whether something on the screen records its virtual microphone now, followed.
fn ScreenSess::mic_active_now(self : ScreenSess) -> Bool {
  self.said.get() |> ignore
  self.mic_active()
}

///|
/// The bars' 麦克风 there: driving a screen with a virtual microphone, while something there records it or this device's
/// is shared (else nothing on the bars: 控制中心's tile switches it), followed.
fn ScreenSess::mic_bar_shown(self : ScreenSess) -> Bool {
  self.driving_now() && self.mic_available_now() && (self.mic_active_now() || self.mic_on.get())
}

///|
/// What 麦克风 says it does as it is pressed, followed: shared, 关闭麦克风; something there records it, that it does
/// and that pressing shares it; else 开启麦克风.
fn ScreenSess::mic_label(self : ScreenSess) -> String {
  if self.mic_on.get() {
    @sf.t("web-pages.screen.micMute")
  } else if self.mic_active_now() {
    @sf.t("web-pages.screen.micAsked")
  } else {
    @sf.t("web-pages.screen.micUnmute")
  }
}

///|
/// 麦克风's icon as it is now, followed: a microphone while shared, struck through while not.
fn ScreenSess::mic_icon(self : ScreenSess) -> String {
  if self.mic_on.get() {
    "mic"
  } else {
    "mic-off"
  }
}

///|
/// This device's microphone shared into the screen's virtual one, or no more (`screen.micOn`): the core sends it only
/// while driving, shared and recorded there, in the recording the state says; the host's capture follows the same.
fn ScreenSess::toggle_mic(self : ScreenSess) -> Unit {
  let on = !self.mic_on.untracked()
  // (shared no more while nothing records it: the bar's 麦克风 goes along its row, not at once)
  @view.transition(fn() { self.mic_on.set(on) })
  if self.call != 0 && self.is_active_principal() {
    screen_tell(self.src, "screen.micOn", { "view": Json::string(self.view), "on": Json::boolean(on) })
  }
}
