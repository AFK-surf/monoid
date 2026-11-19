// The one player of films and songs (the web's one player too; as nodes: player_node.mbt, player_list_node.mbt, what they
// share here): a video is a video,
// whether a chat's recording of a screen or a film of a station's drive, and is watched both ways. To look closely:
// paused, a step to the frame before or after (the file's own frames, read by the host), the time to the millisecond
// and which frame of how many at what rate, slow speeds (0.1×, 0.25×, 0.5×), the picture zoomed and moved, the frame
// shown saved as a picture. To watch: opened where it was left on this device (viewer_file.mbt place; from its start
// again when it was left within 5 s of its end), the subtitle beside it (names.mbt side_subtitle), faster speeds,
// 15 s back and on, the folder's others of its kind as its playlist, the next one played at its end after a moment.
// A film is shown on black, the controls over it a deep tint with words near white, whatever the theme; a song has no
// picture, and is on the page's own colours. Embedded in a page (player_node's `embedded`: a file's tab beside a
// chat) it is part of the page, not a cinema in it: no ground of its own, its picture fitted in a room over its
// controls, which are always there, in the page's colours and on its ground; only what lies over the picture keeps the
// colours over a picture. How it plays is mbui's player's (@player.Media: the system's player in a native view, its bytes
// asked a part at a time of the file's `stream`).
//
// On a desktop's layout (player_node's desk_player_node): the bar every file opened has along the top
// (viewer_bar.mbt), the controls floating over the foot (media.mbt), both there till a click or a finger's tap takes
// them away and another brings them back, or while the pointer is over where they are. A double click or tap as on a
// phone: in the middle it plays or pauses, on the left or right third it jumps 15 s; the wheel with ⌘ or ⌃ (a trackpad's pinch) zooms round the pointer, the wheel
// alone moves what is zoomed in. Keys: Space or K plays or pauses; paused, ← → and , . step a frame, playing ← → jump
// 15 s; J L jump 15 s; ↑ ↓ the sound; M mutes; F fills the screen; C the subtitle; ⇧N ⇧P the next one and the one
// before; + − 0 1 zoom as a picture's. 选集 docks the others at the right.
//
// With a finger (a phone's): a tap brings or takes the controls, a double tap on the left or right third jumps 15 s, in
// the middle plays or pauses; held, it plays at 2× until let go; a finger along it moves through the time, down it
// closes it; two fingers zoom. Paused, its controls step frames; playing, they jump 15 s. Sideways, filling the screen
// or fitted; 选集 a sheet of the page's.

///|
/// `m:ss`, or `h:mm:ss` past an hour (to the second).
pub fn clock(ms : Double) -> String {
  let total = ((if ms < 0.0 { 0.0 } else { ms }) + 500.0).to_int64() / 1000L
  let h = total / 3600L
  let m = total % 3600L / 60L
  let s = total % 60L
  if h > 0L {
    "\{h}:\{two_digits(m)}:\{two_digits(s)}"
  } else {
    "\{m}:\{two_digits(s)}"
  }
}

///|
/// `m:ss.mmm` (`h:mm:ss.mmm` past an hour): a frame's time, to the millisecond.
pub fn clock_ms(ms : Double) -> String {
  let all = (if ms < 0.0 { 0.0 } else { ms }).round().to_int64()
  let total = all / 1000L
  let h = total / 3600L
  let m = total % 3600L / 60L
  let s = total % 60L
  let r = all % 1000L
  let mmm = if r < 10L { "00\{r}" } else if r < 100L { "0\{r}" } else { "\{r}" }
  if h > 0L {
    "\{h}:\{two_digits(m)}:\{two_digits(s)}.\{mmm}"
  } else {
    "\{m}:\{two_digits(s)}.\{mmm}"
  }
}

///|
/// A speed as it is shown: 1×, 1.5×, 0.25×.
pub fn speed_label(speed : Double) -> String {
  let whole = speed.floor()
  (if whole == speed { whole.to_int().to_string() } else { speed.to_string() }) +
  "×"
}

///|
/// The speeds it plays at: slow ones to look closely, fast ones to get through.
pub let player_speeds : Array[Double] = [0.1, 0.25, 0.5, 1.0, 1.25, 1.5, 2.0]

///|
/// A player for a page (`key` keeps its widgets apart from another's), its waits said once they have waited later_ms;
/// its controls there till a tap (a click) on its picture hides them, never going of themselves (the user, 2026-10-28).
pub fn new_media(key : String) -> @player.Media {
  @player.Media::new(key~, speeds=player_speeds, wait_ms=later_ms)
}

///|
/// A file played, kept while its page is open: its player, whether it was opened, the subtitle asked for (its name),
/// the places kept (each next one player_keep_ms after it).
pub(all) struct Playing {
  media : @player.Media
  /// the file as last given (where it is is kept with it)
  mut file : ViewerFile?
  opened : @signals.Signal[Bool]
  mut subtitle_of : String
  mut keeps : Int
}

///|
/// The files played, by their key (let go of as their page goes: player_let_go).
// kept across runs: put back by players_reset (viewer_reset), as a run begins (run_begin)
let playings : Map[String, Playing] = Map([])

///|
/// The file played as `key` (a new player the first time).
pub fn playing_for(key : String) -> Playing {
  match playings.get(key) {
    Some(p) => p
    None => {
      let p : Playing = { media: new_media("drive-play"), file: None, opened: @signals.signal(false), subtitle_of: "", keeps: 0 }
      playings[key] = p
      p
    }
  }
}

///|
/// How long where a file was left is waited on before it plays from the start.
pub let player_place_ms : Double = 1000.0

///|
/// How often where it is is kept while it plays.
pub let player_keep_ms : Double = 5000.0

///|
/// Left this near its end, it plays from its start again.
let player_near_end_ms : Double = 5000.0

///|
/// A subtitle bigger than this is not read.
let player_subtitle_most : Double = 8.0 * 1024.0 * 1024.0

///|
/// How the player reads `file` a part at a time: as it streams, or from its bytes here already, or (neither) read
/// whole once and answered from that (a read let go of meanwhile answered no more).
fn player_read(file : ViewerFile) -> (Double, Int, (Bytes, Double, Bool) -> Unit) -> () -> Unit {
  match (file.stream, file.bytes) {
    (Some(stream), _) => stream
    (None, Some(b)) =>
      fn(offset, length, answer) {
        answer(player_slice(b, offset, length), b.length().to_double(), false)
        fn() {  }
      }
    (None, None) => {
      let whole : Ref[Bytes?] = Ref(None)
      let waiting : Array[(Double, Int, (Bytes, Double, Bool) -> Unit, Ref[Bool])] = []
      let asked = Ref(false)
      fn(offset, length, answer) {
        match whole.val {
          Some(b) => {
            answer(player_slice(b, offset, length), b.length().to_double(), false)
            fn() {  }
          }
          None => {
            let gone = Ref(false)
            waiting.push((offset, length, answer, gone))
            if !asked.val {
              asked.val = true
              (file.read)(-1, fn(_) {  }, fn(r) {
                match r {
                  Ok(b) => {
                    whole.val = Some(b)
                    for w in waiting {
                      if !w.3.val {
                        (w.2)(player_slice(b, w.0, w.1), b.length().to_double(), false)
                      }
                    }
                  }
                  Err(_) =>
                    for w in waiting {
                      if !w.3.val {
                        (w.2)(b"", -2.0, false)
                      }
                    }
                }
                waiting.clear()
              })
            }
            fn() { gone.val = true }
          }
        }
      }
    }
  }
}

///|
/// `length` bytes of `b` from `offset` (none past its end).
fn player_slice(b : Bytes, offset : Double, length : Int) -> Bytes {
  let from = offset.to_int()
  let to = if from + length < b.length() { from + length } else { b.length() }
  if from >= to {
    b""
  } else {
    b[from:to].to_owned()
  }
}

///|
/// Where it is, kept with its file (its time and its length, in ms).
fn player_keep(pl : Playing, file : ViewerFile) -> Unit {
  let pos = pl.media.position()
  let dur = pl.media.duration()
  if dur <= 0.0 {
    return
  }
  (file.keep_place)(pos.round(), dur.round())
}

///|
/// The page playing `key` gone: where it was kept, its player stopped and let go of.
pub fn player_let_go(key : String) -> Unit {
  match playings.get(key) {
    Some(pl) => {
      match pl.file {
        Some(f) if pl.media.started() => player_keep(pl, f)
        _ => ()
      }
      // (its view's 选集 stays open for the next one played in its place: the same player's key)
      pl.media.close()
    }
    None => ()
  }
  playings.remove(key)
}

///|
/// The folder's others of its kind, in their names' order: the playlist.
pub fn playlist_for(file : ViewerFile, siblings : Array[ViewerEntry]) -> Array[String] {
  playlist_of(siblings.filter(fn(e) { !e.dir && e.kind == file.kind }).map(fn(e) { e.name }), fn(_) { true })
}

///|
/// What a player's view holds while it is open (by its player's key): 选集 open, the speeds' menu open, whether it
/// made the window fill the screen; the picture's zoom; which frame is being saved; the end whose next was let go of;
/// the file it shows; where its picture is (player_node's).
// (`rates` read by its tests alone: whether the speeds' menu is open, player_told_wbtest)
#warnings("-unused_field")
priv struct PlayerView {
  mut listing : Bool
  mut rates : Bool
  mut fulled : Bool
  zoom : @motion.Zoom
  mut grab_at : Int
  mut ended_off : String
  mut file : String
  /// where a player's nodes have its picture now (player_node's: at the moment of what asks, else of what the window's
  /// tree last did), while they live
  mut placed_by : (() -> (Double, Double, Double, Double)?)?
  /// 选集 open, as its nodes show it (PlayerNode's `listing`, the same signal: what reads it from outside, the system's
  /// bars' 选集 lit, follows it, and what sets it there opens or closes it: player_list_toggle)
  list_shown : @signals.Signal[Bool]
}

///|
/// Whether the player fills the window beside the system's bars (an iPhone Duo's): the bars put away (no title, no
/// actions), its picture edge to edge, its controls over it as anywhere; 全屏 among the bars' actions and the controls,
/// back leaving it first.
// kept across runs: the player over the window is one at a time; put back as another file is shown in it
let native_full : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// Whether the player fills the window beside the system's bars (native_full).
pub fn player_full_native() -> Bool {
  native_full.get()
}

///|
/// The player filling the window beside the system's bars, or not (native_full).
pub fn player_full_native_set(on : Bool) -> Unit {
  native_full.set(on)
}

///|
/// Whether the player drawn `width` wide fills the window beside the system's bars: a phone's player (laid out Small)
/// turns sideways instead, the bars as they were.
pub fn player_fills_native(width : Double) -> Bool {
  native_full.get() && !(layout(width) is Small)
}

///|
/// 全屏 among the actions in the system's bars for film `p` played `width` wide: its words, whether it is on, what it
/// does. Laid out Small, turned sideways as a phone's player's 全屏 turns it; wider, the window filled, the bars put
/// away (native_full).
pub fn player_full_act(p : @player.Media, width : Double) -> (String, Bool, () -> Unit) {
  if layout(width) is Small {
    let on = p.is_sideways()
    (t(if on { "android-misc.drive.player.unfull" } else { "android-misc.drive.player.full" }), on, fn() {
      p.toggle_sideways()
    })
  } else {
    (t("android-misc.drive.player.full"), false, fn() {
      native_full.set(true)
    })
  }
}

///|
/// How wide the window's player is laid out in a window `width` wide: clear of the column of the system's bars down its
/// trailing edge (an iPhone Duo's on its side: native_clear), but where it fills the window beside them
/// (player_fills_native).
pub fn player_stage_w(width : Double) -> Double {
  if player_fills_native(width) {
    width
  } else {
    dmax(0.0, width - native_clear())
  }
}

///|
/// Whether 选集 is open in the player played as `key`, followed: where its action is the system's bars' (an iPhone
/// Duo's), lit as the player's own 选集 is.
pub fn player_listing(key : String) -> Bool {
  match player_views.get(key) {
    Some(v) => v.list_shown.get()
    None => false
  }
}

///|
/// 选集 opened or closed in the player played as `key`, as its own 选集 does (PlayerNode::list_open): where its action is
/// the system's bars' (an iPhone Duo's). Nothing where its view is not open.
pub fn player_list_toggle(key : String) -> Unit {
  match player_views.get(key) {
    Some(v) => {
      let on = !v.list_shown.untracked()
      v.listing = on
      v.list_shown.set(on)
    }
    None => ()
  }
}

///|
/// What a finger dragging the picture does.
#derive(Eq)
priv enum PlayerDrag {
  NoDrag
  AlongTime
  DownClose
  MoveZoom
}

///|
/// The views open, by their player's key.
// kept across runs: put back by players_reset (viewer_reset), as a run begins (run_begin)
let player_views : Map[String, PlayerView] = Map([])

///|
fn view_for(key : String, margin? : Double = 0.0) -> PlayerView {
  match player_views.get(key) {
    Some(v) => v
    None => {
      let v : PlayerView = {
        listing: false,
        rates: false,
        fulled: false,
        // (a film edge to edge in its stage, enlarged as players do: no margin round it, but where a page holds it, as far
        // in as the page's pictures are: player_node's `margin`)
        zoom: @motion.Zoom::new(margin=fn(_) { margin }, enlarge=true),
        grab_at: 0,
        ended_off: "",
        file: "",
        placed_by: None,
        list_shown: @signals.signal(false, same=fn(a, b) { a == b }),
      }
      player_views[key] = v
      v
    }
  }
}

///|
/// Where the player keyed `key` last drew its picture in its stage (x, y, w, h: as a finger left it, zoomed in or taken
/// down), while its view is open: what a viewer closing it flies back from.
pub fn player_picture_at(key : String) -> (Double, Double, Double, Double)? {
  match player_views.get(key) {
    Some({ placed_by: Some(f), .. }) => f()
    _ => None
  }
}


///|
/// What a player's view held of its own, by its player's key, let go (the player closed).
pub fn player_view_let_go(key : String) -> Unit {
  player_views.remove(key)
}

///|
/// Every player let go of (the app begun again).
fn players_reset() -> Unit {
  playings.clear()
  player_views.clear()
}

///|
/// Where it is among its frames: the file's own (when each starts, read by the host), else a 60th of a second each;
/// how many, which one shows (the last to start by now), when that one starts, its rate (0: not known).
priv struct Frames {
  starts : Array[Double]?
  count : Int
  at : Int
  now : Double
  fps : Double
  dur : Double
}

///|
/// The frames of what `p` plays, at `pos` (ms).
fn frames_of(p : @player.Media, s : @player.MediaStatus, pos : Double) -> Frames {
  let dur = s.duration
  let (starts, read) = match p.native() {
    Some(n) =>
      match n.frames() {
        Some(list) if list.length() > 0 => (Some(list), true)
        Some(_) => (None, true)
        None => (None, !n.here())
      }
    None => (None, false)
  }
  let step = player_guess_step
  match starts {
    Some(list) => {
      let k = list.length()
      let span = list[k - 1] - list[0]
      let at = frame_at(list, pos)
      { starts, count: k, at, now: list[at], fps: if span > 0.0 { (k - 1).to_double() * 1000.0 / span } else { 0.0 }, dur }
    }
    None => {
      let count = if dur > 0.0 && read { (dur / step).round().to_int() } else { 0 }
      { starts, count, at: if dur > 0.0 { ((pos + player_frame_slack) / step).floor().to_int() } else { 0 }, now: pos, fps: 0.0, dur }
    }
  }
}

///|
/// A film's own facts as its bar says them (the web player's bar): its size in pixels, how long, its rate. What its
/// message says, there from the first frame (FileFacts: the station read them from its header), else what the host
/// has read of it (its head, and its end where its header is kept there).
fn film_facts(said : FileFacts, s : @player.MediaStatus, fr : Frames) -> String {
  let (w, h) = if said.width > 0.0 && said.height > 0.0 { (said.width, said.height) } else { (s.width, s.height) }
  guard w > 0.0 && h > 0.0 else { "" }
  let dur = if said.duration > 0.0 { said.duration } else { s.duration }
  let fps = if said.frames > 0 && said.duration > 0.0 {
    said.frames.to_double() * 1000.0 / said.duration
  } else {
    fr.fps
  }
  joined(
    ["\{w.to_int()}×\{h.to_int()}", if dur > 0.0 { clock(dur) } else { "" }, if fps > 0.0 { "\{fps.round().to_int()} fps" } else { "" }],
    " · ",
  )
}

///|
/// When frame `i` starts (the first or the last past either end).
fn Frames::start_of(self : Frames, i : Int) -> Double {
  match self.starts {
    Some(list) => list[if i < 0 { 0 } else if i >= list.length() { list.length() - 1 } else { i }]
    None => dmax(0.0, dmin(dmax(self.dur, 0.0), i.to_double() * player_guess_step))
  }
}

///|
/// The frame showing at `ms` among frames starting at `starts` (in order): the last to start by then (up to
/// player_frame_slack over taken as by then).
fn frame_at(starts : Array[Double], ms : Double) -> Int {
  let mut lo = 0
  let mut hi = starts.length() - 1
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if starts[mid] <= ms + player_frame_slack {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  lo
}

///|
/// What a finger on its time goes to at `ms`: the start of the frame showing then (the file's frames read), else `ms`.
fn Frames::snap(self : Frames, ms : Double) -> Double {
  match self.starts {
    Some(list) => list[frame_at(list, ms)]
    None => ms
  }
}

///|
/// What is said of where it is: while it plays (and of a song, and of a film not ready) the time of how long; paused
/// or moved through by a finger, the time to the millisecond, and with the file's frames read which frame of how many at what rate (not
/// guessed: without them a step is a 60th of a second, which says nothing of the file).
fn where_runs(p : @player.Media, fr : Frames, s : @player.MediaStatus, playing : Bool, picture : Bool, ink : MediaInk) -> Array[@ui.Run] {
  let at = p.scrubbing().unwrap_or(s.position)
  let long = if s.duration > 0.0 { clock(s.duration) } else { "--:--" }
  match fr.starts {
    _ if !picture || s.duration <= 0.0 || (playing && p.scrubbing() is None) =>
      [
        @ui.span(clock(at), color=ink.text, weight=media_strong, mono=true),
        @ui.span(" / " + long, color=ink.muted, mono=true),
      ]
    Some(_) => {
      let frames = t("android-chat.video.frames", args=[("at", "\{fr.at + 1}"), ("n", "\{fr.count}")])
      let rate = if fr.fps > 0.0 { " · \{fr.fps.round().to_int()} fps" } else { "" }
      [
        @ui.span(clock_ms(fr.now), color=ink.text, weight=media_strong, mono=true),
        @ui.span(" · " + frames + rate, color=ink.muted, mono=true),
      ]
    }
    None =>
      [
        @ui.span(clock_ms(at), color=ink.text, weight=media_strong, mono=true),
        @ui.span(" / " + long, color=ink.muted, mono=true),
      ]
  }
}

///|
/// How far in from the stage's top and foot a film's picture is fitted (`top`, `foot`): laid out wider than Small,
/// clear of the bar along the top and of the controls over the foot (and of the system's bars where they are over the
/// window), so neither ever hides an edge of it (a screen's recording looked at closely, its time dragged along); it
/// stays where it is as they come and go. Laid out Small (a phone's) or beside the system's bars (an iPhone Duo's:
/// its bar's actions in them, none of its own over the film) edge to edge, its controls over it. `embedded`: in
/// a stage of a page's own (a tab beside a chat), no bar over it and nothing of the window's bars: the room over its
/// controls, a phone's (phone_embedded_foot) or a desktop's, which stand as far up from the stage's foot as a panel's
/// corner is round.
pub fn player_room(width : Double, embedded? : Bool = false) -> (Double, Double) {
  if layout(width) is Small {
    return (0.0, if embedded { phone_embedded_foot() } else { 0.0 })
  }
  if embedded {
    return (0.0, desk_controls_foot(width, true))
  }
  // (beside the system's bars, an iPhone Duo's: its bar's actions in them, none of its own over the film; its
  // controls over it as a phone's are)
  if native_on() {
    return (0.0, 0.0)
  }
  let top = (viewer_host().room)().0
  (viewer_bar_h + top, desk_controls_foot(width, false))
}

///|
/// How far up from the stage's foot a desktop's controls reach (`embedded`: in a tab's stage, clear of its corner;
/// else media_bar_in over the window's foot bar).
fn desk_controls_foot(width : Double, embedded : Bool) -> Double {
  let said = if desk_narrow(width) { desk_time_over - media_bar_top + desk_time_h } else { 0.0 }
  if embedded {
    media_bar_h() + said + pane_corner
  } else {
    media_bar_h() + said + media_bar_in + (viewer_host().room)().1
  }
}

///|
/// A familiar container name, only when the media type says which it is.
fn player_format(mime : String) -> String? {
  let raw = match mime.find(";") {
    Some(i) => mime.exact_view(end=i).to_owned()
    None => mime
  }
  match raw.trim(chars=" \t\r\n").to_lower() {
    "video/webm" | "audio/webm" => Some("WebM")
    "video/mp4" | "audio/mp4" => Some("MP4")
    "video/quicktime" => Some("MOV")
    "video/3gpp" => Some("3GP")
    "video/3gpp2" => Some("3G2")
    "video/x-matroska" => Some("MKV")
    "video/x-msvideo" => Some("AVI")
    "video/ogg" | "audio/ogg" => Some("Ogg")
    "audio/mpeg" => Some("MP3")
    "audio/aac" => Some("AAC")
    "audio/wav" | "audio/x-wav" => Some("WAV")
    "audio/flac" => Some("FLAC")
    _ => None
  }
}

///|
/// What a double tap did, said a moment: 快退 15 秒, 快进 15 秒, 已暂停, 继续播放.
fn phone_note_words(note : @player.MediaNote) -> String {
  match note {
    Back(ms) => t("android-misc.drive.player.back", args=[("n", (ms / 1000.0).to_int().to_string())])
    Ahead(ms) => t("android-misc.drive.player.ahead", args=[("n", (ms / 1000.0).to_int().to_string())])
    Paused => t("android-misc.drive.player.paused")
    Played => t("android-misc.drive.player.playing")
  }
}

///|
/// A film's dark: a line on it (its words at 12%), the one chosen in its list (16%), the list's own ground.
let player_dark_line : Double = 0.12

///|
let player_dark_chosen : Double = 0.16

///|
let player_list_dark : Int64 = 0x18181BFFL

///|
/// The sound a key's step (↑ ↓) changes; zoom: a key's step, as it is, the wheel's and a pinch's (a pinch's small steps
/// under 50 by a hundredth of each, a wheel's notches by a five-hundredth), its glides.
let player_volume_key : Double = 0.05

///|
let player_zoom_step : Double = 1.25

///|
let player_whole : Double = 1.0

///|
let player_pinch_step : Double = 50.0

///|
let player_pinch_rate : Double = 0.01

///|
let player_wheel_rate : Double = 0.002

///|
/// Without the file's own frames, a step is a 60th of a second; how far past a time a frame may start and still be the
/// one showing then (a player says where it is in whole ms).
let player_guess_step : Double = 1000.0 / 60.0

///|
let player_frame_slack : Double = 1.0

///|
/// The next one plays this long after the end, unless let go; its seconds counted down.
pub let player_next_ms : Double = 5000.0

///|
let player_second_ms : Double = 1000.0

///|
/// The speeds' menu at least this wide.
let player_speeds_w : Double = 120.0

///|
/// A finger held: this fast while it is; a drag down past this closes; a screen's width along it is this much of the
/// time at most (all of a shorter one).
let player_held_speed : Double = 2.0

///|
let player_close_dy : Double = 120.0

///|
let player_drag_span : Double = 120000.0

///|
/// 选集's sheet: its share of the page.
let player_list_sheet : Double = 0.62

///|
let player_pill_spinner : Double = 12.0

///|
/// The controls at most 720 wide; the timeline 26 high, as tall as a press's room where that is more (@ui.room_least).
let phone_controls_most : Double = 720.0

///|
fn phone_timeline_h() -> Double {
  phone_timeline_least
}

///|
let phone_timeline_least : Double = 26.0

///|
/// The widest a rate of bytes is said (file_size's, a second's): what the waiting pill keeps the room of.
// kept across runs: a value (never changed)
let player_rate_widest : Array[String] = ["1023 B/s", "1024 KB/s", "999.9 MB/s"]

///|
/// How tall a phone's controls are embedded, from the picture's room's foot to the stage's (phone_foot_embedded round
/// them, their line of where it is a desktop's said one, their timeline, their keys' row): what the room is less.
fn phone_embedded_foot() -> Double {
  @ui.Space::S2.px() * 2.0 + desk_time_h + phone_timeline_h() + phone_row_h() + phone_controls_foot() + pane_corner
}

///|
/// The colours of the controls embedded in a page (its own ground under them): the page's words and its quieter ones,
/// no ground of their own.
fn media_pane_ink() -> MediaInk {
  let p = theme().p
  { text: p.text, muted: p.muted, ground: no_ground, stage: no_ground }
}

///|
let phone_keys_in : Double = @ui.capsule_in(card_corner, 40.0)

///|
/// Under the keys' row: as much less than phone_keys_in as the row is taller than its keys (phone_keys_row), the keys
/// in the foot corners concentric with them where they were.
fn phone_controls_foot() -> Double {
  phone_keys_in - (phone_row_h() - phone_key_side) / 2.0
}

///|
/// The timelines' track in from either side of what takes the pointer (their boxes' px).
pub let player_track_inset : Double = @ui.Space::S2_5.px()

///|
fn phone_row_h() -> Double {
  phone_key_side
}

///|
/// A key's side (phone_key_box's S10).
let phone_key_side : Double = 40.0

///|
/// Where the row has not the room for all its keys (a phone's narrowest with a paused picture's: its frames' steps, its
/// captions, 保存此帧), what leaves it first: 保存此帧, then the files before and after; the last key at its end stays
/// in the controls' foot corner, concentric with it, never past it.
let phone_drop_grab : Int = 1

///|
let phone_drop_steps : Int = 2

///|
/// Where the controls' row on a wider page has not the room for its keys (a finger's far apart on a narrow one), what
/// leaves it for its ⋯ first: 保存此帧, then the subtitle, then the speed (its speeds in the ⋯ under its name).
let player_drop_grab : Int = 1

///|
let player_drop_subtitle : Int = 2

///|
let player_drop_speed : Int = 3

///|
/// A song's mark (72) in the middle; the cue's words (16 on 1.6) on black at 60%; above the controls while they show
/// (112 off the foot), else 28.
let desk_cover_icon : Double = 72.0

///|
/// The time where the pointer is: over the timeline, 4 above it, on black at 75%, 11 in white.
let desk_pointed_w : Double = 56.0

///|
let desk_pointed_up : Double = 24.0

///|
/// The sound's line: in twentieths, 72 wide.
let desk_volume_steps : Double = 20.0

///|
let desk_volume_w : Double = 72.0

///|
/// A cue over a desktop's controls: as far off the foot as they reach (desk_controls_foot), and 16 more (with keyboard
/// and mouse on a wide page, the 112 it stood at before).
fn desk_cue_over(width : Double, embedded : Bool) -> Double {
  desk_controls_foot(width, embedded) + desk_cue_apart
}

///|
let desk_cue_apart : Double = 16.0

///|
/// Over a phone's controls: 112 off the foot, and as much more as the controls are taller where their
/// timeline and keys' row are a press's room (phone_timeline_h, phone_row_h, phone_controls_foot).
fn phone_cue_over() -> Double {
  phone_cue_least + (phone_timeline_h() - phone_timeline_least) + (phone_row_h() - phone_key_side) / 2.0
}

///|
let phone_cue_least : Double = 112.0

///|
// kept across runs: a value (no field of it changes)
let desk_cue_box : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Md bg=Veil")

///|
// kept across runs: a value (no field of it changes)
let desk_cue_words : @ui.TextStyle = @ui.text_style(size=Title, color=OnVeil, center=true, leading=L7)

///|
/// 选集's head (listHead: 12 over, 10 right, 6 under, 18 at its start) and rows (listRow: 40 at least, 8 and 10 in, the
/// page's corner; the one playing on the chosen ground, in 500).
// kept across runs: a value (no field of it changes)
let desk_list_head : @ui.Style = @ui.css("row w=Full pl=S4_5 pr=S2_5 pt=S3 pb=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let desk_list_row : @ui.Style = @ui.css("row w=Full min_h=S10 px=S2_5 py=S2 gap=S1 align=ACenter radius=Xl")

///|
// kept across runs: a value (no field of it changes)
let desk_list_words : @ui.TextStyle = @ui.text_style(size=Ui, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
// kept across runs: a value (no field of it changes)
let desk_list_now : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
/// Whether a desktop's controls are laid out as the web's phone sizes are (under 640: viewer_small_w): where it is said
/// on a line of its own over the timeline (as a phone's), the row under it the keys' alone.
fn desk_narrow(width : Double) -> Bool {
  width <= viewer_small_w
}

///|
/// That line: the bar 8 over it (a phone's, clear of its corner), 16 high at least, in from its side as the timeline's
/// track is.
let desk_time_over : Double = 8.0

///|
let desk_time_h : Double = 16.0

///|
/// A line of the controls' ⋯ (desk_play_controls): what a key that left their row does, `on_press` once it is chosen.
fn more_line(label : String, icon : String, disabled~ : Bool, on_press~ : () -> Unit) -> MenuItem {
  menu_item_of(label, on_press, icon~, disabled~)
}

///|
fn two_digits(n : Int64) -> String {
  if n < 10L {
    "0\{n}"
  } else {
    "\{n}"
  }
}


///|
/// The player's keys (the file's head), the keymap's own, never changed: where a player is up (`Player`), not with the
/// cursor in a field. Each its action, `player.` and what it does (desk_player's): Space and K play or pause, , and .
/// step a frame, ← → step or jump, J L jump, ↑ ↓ the sound, M mutes, F fills the screen, C the subtitle, ⇧N ⇧P the
/// next and the one before, + = − _ 0 1 zoom, Escape closes what is open over it, or it.
pub fn player_bindings() -> Array[@view.Binding] {
  let when : @view.KeyWhen = All([In("Player"), Not(In("Field"))])
  let ch = fn(c : Char) { @ui.key_of_char(c) }
  let shift = @ui.mod_shift_key
  let keys : Array[(String, Array[(Int, Int)])] = [
    ("play", [(@ui.key_space, 0), (ch('k'), 0)]),
    ("frame_back", [(ch(','), 0)]),
    ("frame_on", [(ch('.'), 0)]),
    ("back", [(@ui.key_code_left, 0)]),
    ("on", [(@ui.key_code_right, 0)]),
    ("jump_back", [(ch('j'), 0)]),
    ("jump_on", [(ch('l'), 0)]),
    ("louder", [(@ui.key_code_up, 0)]),
    ("quieter", [(@ui.key_code_down, 0)]),
    ("mute", [(ch('m'), 0)]),
    ("full", [(ch('f'), 0)]),
    ("subtitle", [(ch('c'), 0)]),
    ("next", [(ch('n'), shift), (ch('N'), 0)]),
    ("prev", [(ch('p'), shift), (ch('P'), 0)]),
    ("zoom_in", [(ch('+'), 0), (ch('+'), shift), (ch('='), 0), (ch('='), shift)]),
    ("zoom_out", [(ch('-'), 0), (ch('-'), shift), (ch('_'), 0), (ch('_'), shift)]),
    ("zoom_reset", [(ch('0'), 0)]),
    ("zoom_whole", [(ch('1'), 0)]),
    ("escape", [(@ui.key_escape, 0)]),
  ]
  let out : Array[@view.Binding] = []
  for k in keys {
    for s in k.1 {
      out.push({ keys: [{ code: s.0, mods: s.1 }], action: "player." + k.0, when })
    }
  }
  out
}
