// A video or a song played as it streams, how a player behaves (still.fail's Android drive/Player.kt, its media app's
// videos): the system's player in a native view under the canvas (@ui.NativeView::video), its bytes asked a part at a
// time of the `read` it is given, never fetched whole first; opened at a place, tried again where it failed; its
// controls left alone while it plays fading away and a tap bringing them back (a song's stay); a tap or a double tap on
// the picture (a double one on its left or right third jumping back or on, in its middle playing or pausing, said a
// moment); its timeline tapped or dragged (the time following the finger, the player sent there once let go); its speed
// stepped, its subtitle's words at their time and turned off, the picture fitted or filling the screen turned sideways.
// How it looks and what it says are the view's (still.fail's src/player): this is what the fingers and the clock do.

///|
/// What is played: its name, its media type, whether it is known to be a song, and how its bytes are read
/// (`read(offset, length, answer)`: `answer(bytes, total, more)` as they come, what it gives back stopping it, as
/// `@ui.NativeView::video` reads), and how a host may read them itself (its `direct`; "": none).
pub(all) struct MediaTrack {
  name : String
  mime : String
  audio : Bool
  read : (Double, Int, (Bytes, Double, Bool) -> Unit) -> () -> Unit
  direct : String
}

///|
/// How a player stands, as its view says (or pinned, for a fixture's shot).
#derive(Eq, Debug)
pub(all) struct MediaStatus {
  /// -1 failed, -2 unsupported format, -3 damaged file, -4 unsupported or damaged, 0 opening, 1 ready
  state : Int
  duration : Double
  position : Double
  buffered : Double
  playing : Bool
  buffering : Bool
  ended : Bool
  /// the picture's own size (0 × 0: none, or not known yet)
  width : Double
  height : Double
}

///|
/// How `n` stands now (nothing open: opening, of no length).
pub fn media_status(n : @ui.NativeView?) -> MediaStatus {
  match n {
    Some(n) => {
      let (w, h) = n.natural()
      {
        state: if n.state() == 2 { 0 } else { n.state() },
        duration: n.duration(),
        position: n.position(),
        buffered: n.buffered(),
        playing: n.playing(),
        buffering: n.buffering(),
        ended: n.ended(),
        width: w,
        height: h,
      }
    }
    None =>
      {
        state: 0,
        duration: -1.0,
        position: 0.0,
        buffered: 0.0,
        playing: false,
        buffering: false,
        ended: false,
        width: 0.0,
        height: 0.0,
      }
  }
}

///|
/// What is playing, in the terms a person cares about.
#derive(Eq, Debug)
pub(all) enum MediaPhase {
  Opening
  Buffering
  Playing
  Paused
  Ended
  Failed
}

///|
/// What a double tap did, said a moment (the view's words for it): `nudge_ms` back, on, paused, played.
#derive(Eq, Debug)
pub(all) enum MediaNote {
  Back(Double)
  Ahead(Double)
  Paused
  Played
}

///|
/// A player: what it plays and how its controls stand. One per page that plays; `key` keeps its widgets and its clocks
/// apart from another's.
pub struct Media {
  priv key : String
  priv speeds : Array[Double]
  priv nudge_ms : Double
  priv double_tap_ms : Double
  priv note_ms : Double
  priv wake_ms : Double
  priv sleep_ms : Double
  priv wait_ms : Double
  priv mut track : MediaTrack?
  priv mut view : @ui.NativeView?
  /// Whether the current first-frame wait has expired.
  priv mut decode_failed : Bool
  priv mut start_at : Double
  priv mut started : Bool
  priv mut speed : Double
  priv mut subs_on : Bool
  priv mut subtitle : Bool
  priv mut cues : Array[@codec.Cue]
  // (the subtitle told and its words shown or not, followed by what reads them: Media::subtitle, Media::cue_now)
  priv subs_told : @signals.Signal[Int]
  // (its view opened or let go of, followed by what reads it: Media::native, a player's nodes made before it opened)
  priv view_told : @signals.Signal[Int]
  priv mut fill : Bool
  // (turned sideways or not, as it is told: what reads it follows it, a frame round the player laid out by it)
  priv sideways : @signals.Signal[Bool]
  /// where the timeline is dragged to (ms); -1: it is not
  priv mut scrub : Double
  /// where the player was last sent while it is dragged (ms; -1: not yet), whether it played when the finger came
  priv mut scrub_sent : Double
  priv mut scrub_played : Bool
  priv mut pinned : MediaStatus?
  /// how loud (0 … 1), and its sound off, kept for what it plays next
  priv mut volume : Double
  priv mut muted : Bool
}

///|
/// How long a player's controls stay left alone while it plays, a note a double tap said is said
/// (0.8 s), its controls take to come as they are woken (0.12 s) and to fade as they rest (0.32 s, both on the
/// ease-out: still.fail's, viewer/media.css.ts): what a player's nodes go by (Media::times), unless said otherwise.
pub let media_rest_ms : Double = 2500.0

///|
pub let media_note_ms : Double = 800.0

///|
pub let media_wake_ms : Double = 120.0

///|
pub let media_sleep_ms : Double = 320.0

///|
/// How long to give a system decoder after it has received the whole file but shown no first frame.
pub let media_decode_wait_ms : Double = 20000.0

///|
/// How long a frame asked of a player is waited for, its read and its seek together.
pub let media_grab_wait_ms : Double = 10000.0

///|
/// A player with nothing in it yet. Its ways, as Player.kt's: the speeds a tap steps through, what a double tap on a
/// side jumps, a double tap's second tap's time,
/// how long a note is said, how long its controls take to come and to go, how long it waits before it says it is
/// waiting.
pub fn Media::new(
  key? : String = "media",
  speeds? : Array[Double] = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75],
  nudge_ms? : Double = 15000.0,
  double_tap_ms? : Double = @ui.double_tap_ms,
  note_ms? : Double = media_note_ms,
  wake_ms? : Double = media_wake_ms,
  sleep_ms? : Double = media_sleep_ms,
  wait_ms? : Double = 400.0,
) -> Media {
  {
    key,
    speeds,
    nudge_ms,
    double_tap_ms,
    note_ms,
    wake_ms,
    sleep_ms,
    wait_ms,
    track: None,
    view: None,
    decode_failed: false,
    start_at: 0.0,
    started: false,
    speed: 1.0,
    subs_on: true,
    subtitle: false,
    cues: [],
    subs_told: @signals.signal(0),
    view_told: @signals.signal(0),
    fill: false,
    sideways: @signals.signal(false, same=fn(a, b) { a == b }),
    scrub: -1.0,
    scrub_sent: -1.0,
    scrub_played: false,
    pinned: None,
    volume: 1.0,
    muted: false,
  }
}

///|
/// `track` played from `start` ms in (0: its start), at the speed chosen; what played before stops. `play` false: opened
/// paused there, showing that frame, until it is played.
pub fn Media::open(self : Media, track : MediaTrack, start? : Double = 0.0, play? : Bool = true) -> Unit {
  self.close_view()
  self.decode_failed = false
  let n = @ui.NativeView::video(track.mime, track.read, direct=track.direct)
  if self.speed != 1.0 {
    n.rate(self.speed)
  }
  if self.muted || self.volume < 1.0 {
    n.volume(if self.muted { 0.0 } else { self.volume })
  }
  if start > 0.0 {
    n.seek(start)
  }
  if play {
    n.play()
  }
  self.view = Some(n)
  self.view_told.set(self.view_told.untracked() + 1)
  self.track = Some(track)
  self.start_at = start
  self.started = false
  self.scrub = -1.0
  self.scrub_sent = -1.0
  @ui.log("player: open \{track.name} (\{track.mime}) from \{start.to_int()} ms")
}

///|
/// Opened again where it was (after it failed).
pub fn Media::retry(self : Media) -> Unit {
  match self.track {
    Some(t) => {
      let at = self.position()
      self.open(t, start=if at > 0.0 { at } else { self.start_at })
    }
    None => ()
  }
}

///|
fn Media::close_view(self : Media) -> Unit {
  match self.view {
    Some(n) => n.close()
    None => ()
  }
  if self.view is Some(_) {
    self.view = None
    self.view_told.set(self.view_told.untracked() + 1)
  }
}

///|
/// Stopped and let go of (its view closed); upright again if it was sideways.
pub fn Media::close(self : Media) -> Unit {
  self.close_view()
  self.upright()
}

///|
/// The subtitle beside it: there is one (its key shows), and its lines once read.
pub fn Media::set_subtitle(self : Media, there : Bool, cues : Array[@codec.Cue]) -> Unit {
  self.subtitle = there
  self.cues = cues
  self.subs_told.set(self.subs_told.untracked() + 1)
}

///|
/// How it stands shown as `s` whatever the view says (a fixture's shots, the same on every run).
pub fn Media::pin(self : Media, s : MediaStatus) -> Unit {
  self.pinned = Some(s)
}

///|
/// How it stands now.
pub fn Media::status(self : Media) -> MediaStatus {
  match self.pinned {
    Some(s) => s
    None => {
      // (followed as its view is opened or let go of, as its view's own signals are)
      self.view_told.get() |> ignore
      let s = media_status(self.view)
      if self.decode_failed && self.view is Some(n) && n.state() == 2 {
        { ..s, state: -4 }
      } else {
        s
      }
    }
  }
}

///|
/// Its key: what keeps its widgets apart from another's (the view's names its own after it).
pub fn Media::key(self : Media) -> String {
  self.key
}

///|
/// What it plays (None before it opens anything).
pub fn Media::track(self : Media) -> MediaTrack? {
  self.track
}

///|
/// Its native view, while one is open.
pub fn Media::native(self : Media) -> @ui.NativeView? {
  self.view_told.get() |> ignore
  self.view
}

///|
/// Where it is (ms).
pub fn Media::position(self : Media) -> Double {
  self.status().position
}

///|
/// Its length (ms; -1 not known).
pub fn Media::duration(self : Media) -> Double {
  self.status().duration
}

///|
/// Whether it has been ready to play (its length known, where it is worth keeping).
pub fn Media::started(self : Media) -> Bool {
  self.started
}

///|
/// Whether it is sideways (back turns it upright first).
pub fn Media::is_sideways(self : Media) -> Bool {
  self.sideways.get()
}

///|
/// Upright again (back while sideways).
pub fn Media::upright(self : Media) -> Unit {
  if self.sideways.untracked() {
    self.sideways.set(false)
    @hostapi.set_sideways(false)
  }
}

///|
/// The speed it plays at.
pub fn Media::speed(self : Media) -> Double {
  self.speed
}

///|
/// Whether there is a subtitle beside it, and whether its words are shown.
pub fn Media::subtitle(self : Media) -> (Bool, Bool) {
  self.subs_told.get() |> ignore
  (self.subtitle, self.subs_on)
}

///|
/// The subtitle's words where it is now, while they are shown ("" none): followed as it plays, as its subtitle is told
/// and as its words are turned on or off, outside any tracking.
pub fn Media::cue_now(self : Media) -> String {
  self.subs_told.get() |> ignore
  if self.subs_on {
    @codec.cues_at(self.cues, self.status().position)
  } else {
    ""
  }
}

///|
/// Whether the picture fills the screen (turned sideways), cropped.
pub fn Media::fills(self : Media) -> Bool {
  self.fill
}

///|
/// Where the timeline is being dragged to (ms), while it is.
pub fn Media::scrubbing(self : Media) -> Double? {
  if self.scrub >= 0.0 {
    Some(self.scrub)
  } else {
    None
  }
}

///|
/// Played, or paused (at its end: from its start again).
pub fn Media::play_pause(self : Media) -> Unit {
  let s = self.status()
  match self.view {
    Some(n) =>
      // (at its end, whatever its host says of its playing as it gets there: from its start again, as it shows)
      if s.playing && !s.ended {
        n.pause()
      } else {
        if s.ended {
          n.seek(0.0)
        }
        n.play()
      }
    None => ()
  }
}

///|
/// Paused (another is opened in its place).
pub fn Media::pause(self : Media) -> Unit {
  match self.view {
    Some(n) => n.pause()
    None => ()
  }
}

///|
/// To `ms` in.
pub fn Media::seek(self : Media, ms : Double) -> Unit {
  match self.view {
    Some(n) => n.seek(ms)
    None => ()
  }
}

///|
/// To about `ms` in, at once (NativeView::seek_near: a jump, the very frame not waited for).
pub fn Media::seek_near(self : Media, ms : Double) -> Unit {
  match self.view {
    Some(n) => n.seek_near(ms)
    None => ()
  }
}

///|
/// About `delta` ms on (back, below 0), within its length, at once (Media::seek_near).
pub fn Media::seek_by(self : Media, delta : Double) -> Unit {
  let s = self.status()
  let mut to = s.position + delta
  if to < 0.0 {
    to = 0.0
  }
  if s.duration > 0.0 && to > s.duration {
    to = s.duration
  }
  self.seek_near(to)
}

///|
/// What a double tap on a side jumps (ms).
pub fn Media::nudge_ms(self : Media) -> Double {
  self.nudge_ms
}

///|
/// The speed after this one.
pub fn Media::step_speed(self : Media) -> Unit {
  let i = self.speeds.search(self.speed).unwrap_or(0)
  self.speed = self.speeds[(i + 1) % self.speeds.length()]
  match self.view {
    Some(n) => n.rate(self.speed)
    None => ()
  }
}

///|
/// The speeds it steps through, in order.
pub fn Media::speeds(self : Media) -> Array[Double] {
  self.speeds
}

///|
/// At `speed` from now on (one of its speeds, or another: a speed held a while, then let go).
pub fn Media::set_speed(self : Media, speed : Double) -> Unit {
  self.speed = speed
  match self.view {
    Some(n) => n.rate(speed)
    None => ()
  }
}

///|
/// How loud it plays (0 … 1), whether its sound is off.
pub fn Media::volume(self : Media) -> (Double, Bool) {
  (self.volume, self.muted)
}

///|
/// As loud as `volume` (0 … 1), its sound on again (none at 0).
pub fn Media::set_volume(self : Media, volume : Double) -> Unit {
  self.volume = if volume < 0.0 { 0.0 } else if volume > 1.0 { 1.0 } else { volume }
  self.muted = self.volume == 0.0
  match self.view {
    Some(n) => n.volume(self.volume)
    None => ()
  }
}

///|
/// Its sound off, or on again as loud as it was.
pub fn Media::toggle_mute(self : Media) -> Unit {
  self.muted = !self.muted
  match self.view {
    Some(n) => n.volume(if self.muted { 0.0 } else { self.volume })
    None => ()
  }
}

///|
/// The subtitle's words shown, or not.
pub fn Media::toggle_subtitle(self : Media) -> Unit {
  self.subs_on = !self.subs_on
  self.subs_told.set(self.subs_told.untracked() + 1)
}

///|
/// The picture filling the screen, or fitted in it.
pub fn Media::toggle_fill(self : Media) -> Unit {
  self.fill = !self.fill
}

///|
/// Turned sideways, or upright again.
pub fn Media::toggle_sideways(self : Media) -> Unit {
  let on = !self.sideways.untracked()
  self.sideways.set(on)
  @hostapi.set_sideways(on)
}

///|
/// How far short of the place it opens at a player said ready may stand and be taken as there: under it, it is sought
/// once more (a whole second let one left 0.1 … 1 s in open again from its start).
let media_start_slack_ms : Double = 100.0

///|
/// For a player shown by nodes of the window's tree (told as how it stands changes, outside any tracking): ready once
/// it is, the place it opens at sought once more where the player took none before it was ready. Whether it is ready.
pub fn Media::take_ready(self : Media) -> Bool {
  let s = self.status()
  if s.state == 1 && !self.started {
    self.started = true
    let read = match self.view {
      Some(n) => n.bytes().to_int()
      None => 0
    }
    let name = match self.track {
      Some(t) => t.name
      None => ""
    }
    @ui.log("player: \{name} ready, \{s.duration.to_int()} ms long, \{read} bytes read")
    if self.start_at > 0.0 && s.position < self.start_at - media_start_slack_ms {
      self.seek(self.start_at)
    }
  }
  self.started
}

///|
/// Its decoder waited on long enough, for a player shown by nodes (media_decode_wait_ms after all its bytes came, as
/// the node's clock has it): said unplayable from now on (Media::status's -4).
pub fn Media::decode_given_up(self : Media) -> Unit {
  if self.pinned is None {
    self.decode_failed = true
  }
}

///|
/// What it was told to wait before it says it waits (Media::new's `wait_ms`), how long a double tap's second tap may
/// come after the first, how long a note is said, how long its controls take to come and to go: a node's own clock's
/// for them.
pub fn Media::times(self : Media) -> (Double, Double, Double, Double, Double) {
  (self.wait_ms, self.double_tap_ms, self.note_ms, self.wake_ms, self.sleep_ms)
}

///|
/// A finger moving it through the time, at `ms` now: paused while the finger is on it, the player told its seeks come
/// one after another (NativeView::scrub: each frame gone to shown before the next is taken up), sent there when that
/// is not where it was last sent; Media::scrubbing says where, until Media::scrub_done.
pub fn Media::scrub_to(self : Media, ms : Double) -> Unit {
  if self.scrub < 0.0 {
    self.scrub_played = self.status().playing
    self.scrub_sent = -1.0
    match self.view {
      Some(n) => {
        n.pause()
        n.scrub(true)
      }
      None => ()
    }
  }
  self.scrub = ms
  if ms != self.scrub_sent {
    self.scrub_sent = ms
    self.seek(ms)
  }
}

///|
/// Whether it plays again once the finger moving it through the time lets go (paused meanwhile).
pub fn Media::scrub_resumes(self : Media) -> Bool {
  self.scrub >= 0.0 && self.scrub_played
}

///|
/// The finger let go: sent where it was last moved to (when the last seek was not there), its seeks as before, played
/// again if it played when the finger came.
pub fn Media::scrub_done(self : Media) -> Unit {
  if self.scrub < 0.0 {
    return
  }
  if self.scrub != self.scrub_sent {
    self.seek(self.scrub)
  }
  match self.view {
    Some(n) => {
      n.scrub(false)
      if self.scrub_played {
        n.play()
      }
    }
    None => ()
  }
  self.scrub = -1.0
  self.scrub_sent = -1.0
}

///|
/// Where the picture shows in a stage `bw` × `bh` (x, y, w, h): fitted in it, or filling it turned sideways (cropped),
/// in its middle, on whole pixels (as the hole it shows through is); its size not known yet, a point in the middle (so
/// the player has somewhere to draw, and tells its size).
pub fn Media::picture_rect(self : Media, s : MediaStatus, bw : Double, bh : Double) -> (Double, Double, Double, Double) {
  if s.width > 0.0 && s.height > 0.0 {
    let kx = bw / s.width
    let ky = bh / s.height
    let k = if self.fill && self.sideways.get() {
      if kx > ky {
        kx
      } else {
        ky
      }
    } else if kx < ky {
      kx
    } else {
      ky
    }
    let w = (s.width * k).round()
    let h = (s.height * k).round()
    (((bw - w) / 2.0).round(), ((bh - h) / 2.0).round(), w, h)
  } else {
    (bw / 2.0, bh / 2.0, 1.0, 1.0)
  }
}

