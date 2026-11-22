// How fast a view's frames go (station/src/mesh/screen-pace.ts, "Pace"): which may be sent now, and the bit rate its
// source is asked to encode at, both from what the client's acknowledgements say of the link; when a still screen's
// picture goes again sharper (`Sharpener`); how large a picture a view asks of its source by the rate (`Sizer`); how
// late its frames are (`FrameLatency`); and how long the station's own loop stood still (`LoopStall`), left out of
// round trips and waits. Every clock is given (ms, as a Double), so a test's is the one it reads. What each constant
// is for, and why, the TypeScript says.

///|
pub let start_unacked : Int = 2

///|
pub let max_unacked : Int = 16

///|
pub let queue_least_ms : Double = 30.0

///|
pub let queue_share : Double = 0.5

///|
pub fn queue_ms(rtt : Double) -> Double {
  dmax(queue_least_ms, rtt * queue_share)
}

///|
/// How much longer a key frame on the way may wait (`KEY_QUEUE_MS`).
pub let key_queue_ms : Double = 25.0

///|
pub let rtt_window_ms : Double = 10_000.0

///|
pub let viewer_hold_limit_ms : Double = 100.0

///|
pub let delivery_window_ms : Double = 1000.0

///|
pub let min_rate : Double = 300_000.0

///|
pub let down : Double = 0.85

///|
pub let cut : Double = 0.65

///|
/// The first lowering of a hold where what went through was under USED of the rate (`LIGHT_CUT`).
pub let light_cut : Double = 0.8

///|
pub let hold_ms : Double = 200.0

///|
pub let up : Double = 1.2

///|
pub let up_fast : Double = 1.3

///|
pub let up_fast_after_ms : Double = 2000.0

///|
pub let up_every_ms : Double = 500.0

///|
pub let up_after_ms : Double = 1000.0

///|
pub let start_rate : Double = 1_500_000.0

///|
/// Where the view's link is known as it opens, a higher start (`startRate`).
pub let lan_rtt_ms : Double = 12.0

///|
pub let lan_rate : Double = 25_000_000.0

///|
pub let near_rtt_ms : Double = 40.0

///|
pub let near_rate : Double = 12_000_000.0

///|
pub let far_rtt_ms : Double = 100.0

///|
pub let direct_rate : Double = 4_000_000.0

///|
pub let relay_rtt_ms : Double = 35.0

///|
pub let relay_rate : Double = 4_000_000.0

///|
fn direct_path(p : LinkPath) -> Bool {
  (p.relay is None || p.relay is Some("")) && p.ip is Some(ip) && ip != ""
}

///|
/// The rate a view starts at by its connection's ways as it opens (`startRate`): the selected way, else the first
/// direct one, else the first.
pub fn start_rate_of(paths : Array[LinkPath]) -> Double {
  if paths.length() == 0 {
    return start_rate
  }
  let p = match paths.search_by(w => w.selected) {
    Some(i) => paths[i]
    None =>
      match paths.search_by(direct_path) {
        Some(i) => paths[i]
        None => paths[0]
      }
  }
  let rtt = match p.rtt_ms {
    Some(ms) if !ms.is_nan() && !ms.is_inf() && ms > 0.0 => Some(ms)
    _ => None
  }
  if direct_path(p) {
    match rtt {
      Some(ms) if ms <= lan_rtt_ms => lan_rate
      Some(ms) if ms <= near_rtt_ms => near_rate
      Some(ms) if ms > far_rtt_ms => start_rate
      _ => direct_rate
    }
  } else {
    match rtt {
      Some(ms) if ms <= relay_rtt_ms => relay_rate
      _ => start_rate
    }
  }
}

///|
/// `start_rate_of` of the ways as JSON says them (`[{selected, relay?, ip?, rttMs?}]`; none: START_RATE).
pub fn start_rate_for(paths : Json?) -> Double {
  match paths {
    Some(Array(xs)) => start_rate_of(xs.map(LinkPath::of_json))
    _ => start_rate
  }
}

///|
pub let measured_ms : Double = 500.0

///|
pub let start_up : Double = 1.5

///|
fn dmax(a : Double, b : Double) -> Double {
  // Math.max: NaN wins
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else {
    b
  }
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a < b {
    a
  } else {
    b
  }
}

///|
/// The bit rate a source encodes a picture of this size at when not asked.
pub fn own_rate(width : Double, height : Double) -> Double {
  dmax(1_000_000.0, width * height * 3.0)
}

///|
pub let max_rate : Double = 100_000_000.0

///|
pub let fps_scale_most : Double = 1.6

///|
/// How much more a picture is asked at for a 帧率 over 60 (`fpsScale`).
pub fn fps_scale(fps : Double?) -> Double {
  match fps {
    Some(f) if f > 60.0 => dmin(fps_scale_most, 1.0 + (f - 60.0) / 120.0)
    _ => 1.0
  }
}

///|
/// The most a picture of this size is asked at (its 画质: "smooth", "hd", "qhd", "original"; None for 自动), at the
/// 帧率 `fps` (None: 自动).
pub fn rate_ceiling(width : Double, height : Double, quality : String?, fps? : Double? = None) -> Double {
  let own = own_rate(width, height)
  let per = match quality {
    Some("smooth") => 6.0
    Some("qhd" | "original") => 20.0
    _ => 16.0
  }
  dmax(own, dmin(max_rate, width * height * per * fps_scale(fps)))
}

///|
/// The frame rates a view may ask (its 帧率).
pub let fps_choices : Array[Int] = [120, 90, 60, 30, 15]

///|
/// `isFps`.
pub fn is_fps(v : Json?) -> Bool {
  match v {
    Some(Number(n, ..)) => fps_choices.iter().any(f => f.to_double() == n)
    _ => false
  }
}

///|
pub let stall_tick_ms : Double = 10.0

///|
/// How long the station's own loop stood still, counted while a view uses it (`LoopStall`): a tick each STALL_TICK_MS
/// (`every`, given: what it gives stops it), each one late by more than that counted.
pub struct LoopStall {
  mut total : Double
  mut last : Double
  mut stop : (() -> Unit)?
  mut users : Int
  now : () -> Double
  every : (Double, () -> Unit) -> () -> Unit
}

///|
pub fn LoopStall::new(now : () -> Double, every : (Double, () -> Unit) -> () -> Unit) -> LoopStall {
  { total: 0.0, last: 0.0, stop: None, users: 0, now, every }
}

///|
/// One use begun; what it gives ends it (once).
pub fn LoopStall::use_(self : LoopStall) -> () -> Unit {
  if self.users == 0 {
    self.users = 1
    self.last = (self.now)()
    self.stop = Some((self.every)(stall_tick_ms, () => self.tick()))
  } else {
    self.users += 1
  }
  let done = Ref(false)
  () => {
    if done.val {
      return
    }
    done.val = true
    self.users -= 1
    if self.users == 0 && self.stop is Some(stop) {
      stop()
      self.stop = None
    }
  }
}

///|
/// How long it stood still so far, the stand it is in now with it.
pub fn LoopStall::stalled(self : LoopStall) -> Double {
  self.total + dmax(0.0, (self.now)() - self.last - stall_tick_ms)
}

///|
fn LoopStall::tick(self : LoopStall) -> Unit {
  let now = (self.now)()
  self.total += dmax(0.0, now - self.last - stall_tick_ms)
  self.last = now
}

///|
pub struct Out {
  ts : Double
  bytes : Double
  at : Double
  stall : Double
  key : Bool
}

///|
pub struct Trip {
  at : Double
  ms : Double
}

///|
pub struct Through {
  at : Double
  bytes : Double
}

///|
/// Which frames may go and the bit rate asked (`Pacer`).
pub struct Pacer {
  out : Array[Out]
  trips : Array[Trip]
  viewer_waits : Array[Trip]
  through : Array[Through]
  mut rate : Double?
  mut ceiling : Double?
  mut down : Double
  mut up : Double
  mut since : Double?
  mut held : Double
  mut first : Double
  gap : Double?
  mut due : Double
  now : () -> Double
  stalled : () -> Double
}

///|
/// `start`: the bit rate the source was opened at (None: its own); `fps`: the 帧率 asked (None: 自动); `stalled`: how
/// long the station's loop stood still so far.
pub fn Pacer::new(now : () -> Double, start? : Double? = None, fps? : Double? = None, stalled? : () -> Double = () => 0.0) -> Pacer {
  {
    out: [],
    trips: [],
    viewer_waits: [],
    through: [],
    rate: start,
    ceiling: None,
    down: @double.neg_infinity,
    up: @double.neg_infinity,
    since: None,
    held: @double.neg_infinity,
    first: @double.infinity,
    gap: match fps {
      Some(f) if f > 0.0 => Some(1000.0 / f)
      _ => None
    },
    due: @double.neg_infinity,
    now,
    stalled,
  }
}

///|
/// How long until the next frame may go by the 帧率 asked, in whole ms.
pub fn Pacer::wait(self : Pacer) -> Double {
  let left = match self.gap {
    None => 0.0
    Some(_) => self.due - (self.now)()
  }
  if left > 0.0 {
    left.ceil()
  } else {
    0.0
  }
}

///|
pub fn Pacer::unacked(self : Pacer) -> Int {
  self.out.length()
}

///|
/// The source's own bit rate: what it is asked goes no higher.
pub fn Pacer::set_ceiling(self : Pacer, rate : Double) -> Unit {
  self.ceiling = Some(rate)
  self.rate = Some(dmin(self.rate.unwrap_or(rate), rate))
}

///|
/// A frame went (`key`: a key frame).
pub fn Pacer::sent(self : Pacer, ts : Double, bytes : Double, key? : Bool = false) -> Unit {
  let now = (self.now)()
  self.out.push({ ts, bytes, at: now, stall: (self.stalled)(), key })
  if self.gap is Some(gap) {
    self.due = dmax(self.due + gap, now + gap / 2.0)
  }
}

///|
/// The viewer gave up these frames and asked for a key frame. Do not count them as delivered.
fn Pacer::lost(self : Pacer) -> Unit {
  self.out.clear()
}

///|
/// The client decoded every frame up to `ts`; the newest of them gives a round trip.
/// `viewer_wait_ms`: how long (ms) the client held the frame before showing or dropping it.
pub fn Pacer::acked(self : Pacer, ts : Double, viewer_wait_ms? : Double = 0.0) -> Unit {
  let now = (self.now)()
  let mut newest : Out? = None
  let mut key = false
  while self.out.length() > 0 && self.out[0].ts <= ts {
    let f = self.out.remove(0)
    self.through.push({ at: now, bytes: f.bytes })
    newest = Some(f)
    key = key || f.key
  }
  guard newest is Some(newest) else { return }
  self.first = dmin(self.first, now)
  while self.through.length() > 0 && self.through[0].at < now - delivery_window_ms {
    self.through.remove(0) |> ignore
  }
  let total_trip = dmax(0.0, now - newest.at - ((self.stalled)() - newest.stall))
  let wait = if !viewer_wait_ms.is_nan() && !viewer_wait_ms.is_inf() && viewer_wait_ms > 0.0 && viewer_wait_ms <= total_trip {
    viewer_wait_ms
  } else {
    0.0
  }
  self.viewer_waits.push({ at: now, ms: wait })
  while self.viewer_waits.length() > 1 && self.viewer_waits[0].at < now - rtt_window_ms {
    self.viewer_waits.remove(0) |> ignore
  }
  let net_trip = dmax(0.0, total_trip - wait)
  let base = self.rtt()
  self.trips.push({ at: now, ms: net_trip })
  while self.trips.length() > 1 && self.trips[0].at < now - rtt_window_ms {
    self.trips.remove(0) |> ignore
  }
  match base {
    Some(b) if net_trip > b + queue_ms(b) + (if key { key_queue_ms } else { 0.0 }) => self.queuing(now)
    _ => self.steady(now)
  }
}

///|
/// Recent viewer hold time (ms) credited to the in-flight window, capped at `viewer_hold_limit_ms`.
pub fn Pacer::viewer_wait(self : Pacer) -> Double {
  if self.viewer_waits.length() == 0 {
    return 0.0
  }
  let mut m = 0.0
  for w in self.viewer_waits {
    m = dmax(m, w.ms)
  }
  dmin(viewer_hold_limit_ms, m)
}

///|
/// The quickest round trip lately.
pub fn Pacer::rtt(self : Pacer) -> Double? {
  if self.trips.length() == 0 {
    return None
  }
  let mut m = @double.infinity
  for t in self.trips {
    m = dmin(m, t.ms)
  }
  Some(m)
}

///|
/// Whether the next frame may go now; when not, a queue is building.
pub fn Pacer::may(self : Pacer) -> Bool {
  let may = self.free()
  if !may && self.rtt() is Some(_) {
    let now = (self.now)()
    if self.since is None {
      self.since = Some(now)
    }
    self.held = now
    self.queuing(now)
  }
  may
}

///|
/// Whether the next frame may go now, as `may` says, asking nothing of the pace (`free`).
pub fn Pacer::free(self : Pacer) -> Bool {
  if self.out.length() == 0 {
    return true
  }
  guard self.rtt() is Some(rtt) else { return self.out.length() < start_unacked }
  self.out.length() < max_unacked && self.waited((self.now)()) <= rtt + self.viewer_wait() + self.queue(rtt)
}

///|
/// The queue a view lets build in front of the link: a key frame's more while one is on the way.
fn Pacer::queue(self : Pacer, rtt : Double) -> Double {
  queue_ms(rtt) + (if self.out.iter().any(f => f.key) { key_queue_ms } else { 0.0 })
}

///|
/// Whether the frames on the way wait in front of the link.
pub fn Pacer::backlogged(self : Pacer) -> Bool {
  if self.out.length() <= 1 {
    return false
  }
  match self.rtt() {
    Some(rtt) => self.waited((self.now)()) > rtt + self.viewer_wait() + self.queue(rtt)
    None => false
  }
}

///|
fn Pacer::waited(self : Pacer, now : Double) -> Double {
  let oldest = self.out[0]
  now - oldest.at - ((self.stalled)() - oldest.stall)
}

///|
/// The bit rate to ask of the source, or None while its own is not known.
pub fn Pacer::asked_rate(self : Pacer) -> Double? {
  self.rate
}

///|
/// What went through in the last second, in bits a second.
pub fn Pacer::through_rate(self : Pacer) -> Double {
  self.delivered((self.now)())
}

///|
fn Pacer::delivered(self : Pacer, now : Double) -> Double {
  if self.through.length() == 0 {
    return 0.0
  }
  let span = dmax(100.0, dmin(delivery_window_ms, now - self.first))
  let mut sum = 0.0
  for f in self.through {
    sum = sum + f.bytes
  }
  sum * 8.0 * 1000.0 / span
}

///|
fn Pacer::queuing(self : Pacer, now : Double) -> Unit {
  guard self.since is Some(since) else { return }
  if self.calm(now) {
    return
  }
  let rtt = self.rtt().unwrap_or(0.0)
  guard self.rate is Some(rate) else { return }
  if now - since < dmax(hold_ms, 2.0 * rtt) || now - self.down < rtt + hold_ms {
    return
  }
  if now - self.first < measured_ms {
    return
  }
  let light = self.down < since
  self.down = now
  let through = self.delivered(now)
  if through <= 0.0 {
    return
  }
  let to = if light && through < rate * used { rate * light_cut } else { dmax(rate * cut, through * down) }
  self.rate = Some(dmax(min_rate, dmin(rate, to)))
}

///|
fn Pacer::calm(self : Pacer, now : Double) -> Bool {
  if now - self.held <= dmax(up_after_ms, 2.0 * self.rtt().unwrap_or(0.0)) {
    return false
  }
  self.since = None
  true
}

///|
fn Pacer::steady(self : Pacer, now : Double) -> Unit {
  if self.since is Some(_) && !self.calm(now) {
    return
  }
  guard self.rate is Some(rate) && self.ceiling is Some(ceiling) && rate < ceiling else { return }
  let starting = self.down == @double.neg_infinity
  if (!starting && now - self.down < up_after_ms) || now - self.up < up_every_ms {
    return
  }
  self.up = now
  let step = if starting {
    start_up
  } else if now - dmax(self.held, self.down) >= up_fast_after_ms {
    up_fast
  } else {
    up
  }
  self.rate = Some(dmin(ceiling, rate * step))
}

///|
pub let still_ms : Double = 250.0

///|
pub let sharper : Double = 1.1

///|
pub let moving_sharpen_ms : Double = 2000.0

///|
pub let moving_sharpen_up : Double = 2.0

///|
/// When a still screen's picture is sent again sharper, and a moving one's key frame asked again (`Sharpener`).
pub struct Sharpener {
  mut at : Double
  mut rate : Double?
  mut key : Bool
  mut key_at : Double
  mut key_rate : Double?
}

///|
pub fn Sharpener::new() -> Sharpener {
  { at: @double.neg_infinity, rate: None, key: false, key_at: @double.neg_infinity, key_rate: None }
}

///|
/// A frame went at `now`, encoded at `rate` (None: a source with no rate of its own); `key`: a key frame.
pub fn Sharpener::sent(self : Sharpener, now : Double, rate : Double?, key? : Bool = false) -> Unit {
  self.at = now
  self.rate = rate
  self.key = key
  if rate is None {
    self.key_at = @double.neg_infinity
    self.key_rate = None
  } else if key || self.key_rate is None {
    self.key_at = now
    self.key_rate = rate
  }
}

///|
/// Whether a moving screen's key frame is to be asked now, the pace asking `rate` (`dueMoving`): taken as asked.
pub fn Sharpener::due_moving(self : Sharpener, now : Double, rate : Double?) -> Bool {
  match (rate, self.key_rate) {
    (Some(r), Some(was)) if now - self.key_at >= moving_sharpen_ms && r >= was * moving_sharpen_up => {
      self.key_at = now
      self.key_rate = Some(r)
      true
    }
    _ => false
  }
}

///|
/// How long until the screen has been still for STILL_MS, or UP_EVERY_MS after a key frame.
pub fn Sharpener::left(self : Sharpener, now : Double) -> Double {
  dmax(0.0, self.at + (if self.key { dmax(still_ms, up_every_ms) } else { still_ms }) - now)
}

///|
/// Whether the last frame's picture is to go again now, the pace asking `rate`.
pub fn Sharpener::due(self : Sharpener, now : Double, rate : Double?) -> Bool {
  match (rate, self.rate) {
    (Some(r), Some(was)) => self.left(now) == 0.0 && r > was * sharper
    _ => false
  }
}

///|
/// A picture's bounds.
#derive(Eq, Debug)
pub(all) struct Bounds {
  max_width : Double
  max_height : Double
}

///|
pub fn Bounds::to_json(self : Bounds) -> Json {
  jobj([("maxWidth", jnum(self.max_width)), ("maxHeight", jnum(self.max_height))])
}

///|
pub let low_bounds : Bounds = { max_width: 1280.0, max_height: 720.0 }

///|
pub let downsize_share : Double = 0.25

///|
pub let used : Double = 0.6

///|
pub let downsize_ms : Double = 3000.0

///|
pub let upsize_ms : Double = 3000.0

///|
/// How large a picture a view asks of its source by the rate the pace asks (`Sizer`).
pub struct Sizer {
  now : () -> Double
  mut asked : Bounds
  mut low : Bool
  mut since : Double?
  whole : Bool
}

///|
pub fn Sizer::new(now : () -> Double, asked : Bounds, quality? : String? = None) -> Sizer {
  { now, asked, low: false, since: None, whole: quality is Some("original" | "qhd") }
}

///|
pub fn Sizer::is_low(self : Sizer) -> Bool {
  self.low
}

///|
pub fn Sizer::asked_bounds(self : Sizer) -> Bounds {
  self.asked
}

///|
/// The view asks for other bounds: the bounds to ask of the source now.
pub fn Sizer::ask(self : Sizer, asked : Bounds) -> Bounds {
  self.asked = asked
  self.since = None
  self.bounds()
}

///|
/// With the rate asked now, what went through and the picture's size now: the bounds to ask for, when they change.
pub fn Sizer::step(self : Sizer, rate : Double, through : Double, width : Double, height : Double) -> Bounds? {
  if self.whole || (self.asked.max_width <= low_bounds.max_width && self.asked.max_height <= low_bounds.max_height) {
    return None
  }
  let own = own_rate(width, height)
  let now = (self.now)()
  let holds = if self.low {
    rate >= own * 0.98
  } else {
    rate <= own * downsize_share && through >= rate * used
  }
  if !holds {
    self.since = None
    return None
  }
  let since = match self.since {
    Some(s) => s
    None => {
      self.since = Some(now)
      now
    }
  }
  if now - since < (if self.low { upsize_ms } else { downsize_ms }) {
    return None
  }
  self.since = None
  self.low = !self.low
  Some(self.bounds())
}

///|
/// The bounds to ask of the source as things are.
pub fn Sizer::bounds(self : Sizer) -> Bounds {
  let a = self.asked
  if self.low {
    { max_width: dmin(a.max_width, low_bounds.max_width), max_height: dmin(a.max_height, low_bounds.max_height) }
  } else {
    a
  }
}

///|
pub let latency_every_ms : Double = 1000.0

///|
pub let latency_window_ms : Double = 2000.0

///|
pub struct Sample {
  at : Double
  frame : Double
  before : Double
}

///|
/// How late a view's frames are (`FrameLatency`).
pub struct FrameLatency {
  now : () -> Double
  out : Map[Double, (Double, Double)]
  samples : Array[Sample]
  mut said : Double
}

///|
pub fn FrameLatency::new(now : () -> Double) -> FrameLatency {
  { now, out: Map([]), samples: [], said: @double.neg_infinity }
}

///|
/// A frame of capture time `ts` (µs) went out now.
pub fn FrameLatency::sent(self : FrameLatency, ts : Double) -> Unit {
  let now = (self.now)()
  let capture = ts / 1000.0
  if now - capture < 0.0 || now - capture > 10_000.0 {
    return
  }
  self.out[ts] = (capture, now)
}

///|
/// Frames the viewer gave up will not contribute latency samples.
fn FrameLatency::lost(self : FrameLatency) -> Unit {
  self.out.clear()
}

///|
/// The client drew every frame up to `ts`; `rtt`: the link's quickest round trip (ms).
pub fn FrameLatency::acked(self : FrameLatency, ts : Double, rtt : Double) -> Unit {
  let now = (self.now)()
  let mut newest = None
  let gone = []
  for t, f in self.out {
    if t > ts {
      continue
    }
    if t == ts {
      newest = Some(f)
    }
    gone.push(t)
  }
  for t in gone {
    self.out.remove(t)
  }
  guard newest is Some((capture, sent)) else { return }
  self.samples.push({ at: now, frame: dmax(0.0, now - rtt / 2.0 - capture), before: sent - capture })
  self.prune(now)
}

///|
fn FrameLatency::prune(self : FrameLatency, now : Double) -> Unit {
  while self.samples.length() > 0 && self.samples[0].at < now - latency_window_ms {
    self.samples.remove(0) |> ignore
  }
}

///|
fn median(xs : Array[Double]) -> Double {
  let s = xs.copy()
  s.sort_by((a, b) => a.compare(b))
  s[s.length() / 2]
}

///|
/// What to say now (once each LATENCY_EVERY_MS, when there are frames to say it of): the medians, in whole ms.
pub fn FrameLatency::take(self : FrameLatency) -> (Double, Double)? {
  let now = (self.now)()
  self.prune(now)
  if self.samples.length() == 0 || now - self.said < latency_every_ms {
    return None
  }
  self.said = now
  Some((js_round(median(self.samples.map(s => s.frame))), js_round(median(self.samples.map(s => s.before)))))
}

///|
/// How much of what went over a view's link was lost, as its station counts it (`LinkLoss`, the statistics' 丢包率):
/// sampled every LOSS_EVERY_MS from the connection's selected path, over the last LOSS_WINDOW_MS; a path changed or
/// counters gone back start again from it; fewer than LOSS_MIN_PACKETS with fewer than LOSS_MIN_LOST lost says 0.
pub let loss_every_ms : Int = 1000

///|
pub let loss_window_ms : Double = 60_000.0

///|
pub let loss_min_packets : Double = 20.0

///|
pub let loss_min_lost : Double = 3.0

///|
/// One way of a connection as the loss reads it (`LinkPath`).
pub(all) struct LinkPath {
  id : String?
  selected : Bool
  relay : String?
  ip : String?
  rtt_ms : Double?
  tx_packets : Double
  lost_packets : Double
}

///|
/// A way as JSON says it (`{id?, selected, relay?, ip?, rttMs?, txPackets, lostPackets}`).
pub fn LinkPath::of_json(v : Json) -> LinkPath {
  {
    id: str_of(field(v, "id")),
    selected: field(v, "selected") is Some(True),
    relay: str_of(field(v, "relay")),
    ip: str_of(field(v, "ip")),
    rtt_ms: num_of(field(v, "rttMs")),
    tx_packets: num_of(field(v, "txPackets")).unwrap_or(0.0),
    lost_packets: num_of(field(v, "lostPackets")).unwrap_or(0.0),
  }
}

///|
priv struct LossSample {
  at : Double
  sent : Double
  lost : Double
}

///|
pub struct LinkLoss {
  priv now : () -> Double
  priv mut last : (String, Double, Double)?
  priv samples : Array[LossSample]
  priv mut said : Double?
}

///|
pub fn LinkLoss::new(now : () -> Double) -> LinkLoss {
  { now, last: None, samples: [], said: None }
}

///|
/// The connection's paths now: the share to say now (percent, to a tenth), when it changed since it was last said.
pub fn LinkLoss::step(self : LinkLoss, paths : Array[LinkPath]) -> Double? {
  guard self.sample(paths) is Some(pct) else { return None }
  if self.said == Some(pct) {
    return None
  }
  self.said = Some(pct)
  Some(pct)
}

///|
/// The share over the window as of now (None: nothing went in it), the counters taken in.
pub fn LinkLoss::sample(self : LinkLoss, paths : Array[LinkPath]) -> Double? {
  let now = (self.now)()
  match paths.search_by(p => p.selected) {
    None => self.last = None
    Some(i) => {
      let way = paths[i]
      let key = match (way.id, way.relay, way.ip) {
        (Some(k), _, _) => k
        (None, Some(r), _) => r
        (None, None, Some(ip)) => ip
        _ => ""
      }
      if self.last is Some((k, sent, lost)) && k == key && way.tx_packets >= sent && way.lost_packets >= lost {
        self.samples.push({ at: now, sent: way.tx_packets - sent, lost: way.lost_packets - lost })
      }
      self.last = Some((key, way.tx_packets, way.lost_packets))
    }
  }
  while self.samples.length() > 0 && self.samples[0].at < now - loss_window_ms {
    self.samples.remove(0) |> ignore
  }
  let mut sent = 0.0
  let mut lost = 0.0
  for s in self.samples {
    sent = sent + s.sent
    lost = lost + s.lost
  }
  if sent == 0.0 {
    return None
  }
  if sent < loss_min_packets && lost < loss_min_lost {
    return Some(0.0)
  }
  Some(dmin(100.0, js_round(lost / sent * 1000.0) / 10.0))
}
