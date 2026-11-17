// X11 video for a client that takes H.264 (src/screens/x11-h264.ts). Capture runs continuously, but only the newest
// raw picture is retained. A second ffmpeg encodes one picture when the transport asks for one: dropping an encoded
// delta frame would break every frame that refers to it. FLV gives each encoded packet a length and carries the avcC
// the clients already use.

///|
const MAX_PACKET : Int = 16777216

///|
const H264_OPEN_TIMEOUT : Double = 10000

///|
const RESTART_MS : Double = 1500

///|
const MIN_RATE : Double = 300000

///|
const MAX_RATE : Double = 60000000

///|
/// A frame being captured: told it once encoded (or none), whether its picture went to the encoder, and its time.
priv struct Pending {
  resolve : (Frame?) -> Unit
  mut submitted : Bool
  mut ts : Double
}

///|
/// ffmpeg may be blocked waiting for another raw picture; closing its input lets it observe termination.
fn stop_encoder(child : Child?) -> Unit {
  match child {
    Some(c) => {
      (c.destroy_input)()
      (c.kill)("SIGTERM")
    }
    None => ()
  }
}

///|
/// The X11 desktop as H.264 (x11-h264.ts `X11H264`).
pub struct X11H264 {
  priv io : Io
  /// Its first frame had, or why not.
  ready : @effect.Deferred[Unit]
  priv ffmpeg : String
  priv env : Env
  priv size : (Double, Double)
  priv fps : Double
  priv mut capture : Child?
  priv gone : () -> Unit
  priv raw_size : Int
  priv building : @buffer.Buffer
  priv mut latest : (Bytes, Double)?
  priv mut encoder : (Int, Child)?
  priv carry : @buffer.Buffer
  priv mut header : Bool
  priv mut description : Bytes?
  priv mut config : Bool
  priv mut requested : Double
  priv mut encoding : Double
  priv mut restarted : Double
  priv mut force : Bool
  priv mut pending : Pending?
  priv mut first : Frame?
  priv mut last_ts : Double
  priv mut ended : Bool
  priv mut closed : Bool
  priv mut failure : String
  priv mut stderr : String
  priv mut timer : () -> Unit
  priv mut encoders : Int
}

///|
pub fn X11H264::new(
  io : Io,
  ffmpeg : String,
  env : Env,
  screen : (Double, Double),
  picture : (Double, Double),
  fps : Double,
  bitrate : Double?,
  gone : () -> Unit,
) -> X11H264 {
  let v = {
    io,
    ready: @effect.Deferred::new(),
    ffmpeg,
    env,
    size: picture,
    fps,
    capture: None,
    gone,
    raw_size: (picture.0 * picture.1 * 3.0 / 2.0).to_int(),
    building: Buffer(),
    latest: None,
    encoder: None,
    carry: Buffer(),
    header: false,
    description: None,
    config: true,
    requested: js_min(MAX_RATE, js_max(MIN_RATE, bitrate.unwrap_or(1500000.0))),
    encoding: 0.0,
    restarted: @double.neg_infinity,
    force: false,
    pending: None,
    first: None,
    last_ts: 0.0,
    ended: false,
    closed: false,
    failure: "X11 H.264 capture ended",
    stderr: "",
    timer: () => (),
    encoders: 0,
  }
  let args = [
    "-nostdin", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-framerate", num_text(fps), "-video_size",
    "\{num_text(screen.0)}x\{num_text(screen.1)}", "-i", env.get("DISPLAY").unwrap_or(""), "-vf", "scale=\{num_text(picture.0)}:\{num_text(picture.1)}:flags=fast_bilinear",
    "-pix_fmt", "yuv420p", "-threads", "1", "-f", "rawvideo", "pipe:1",
  ]
  let capture = (io.procs.spawn)(ffmpeg, args, SpawnOptions::piped(env=Some(env)), {
    out: d => v.raw(d),
    err: d => v.error_text(d),
    error: e => v.end(e),
    close: (_, _) => v.end(if v.stderr != "" { v.stderr } else { "X11 capture ended" }),
  })
  v.capture = Some(capture)
  (capture.end_input)(None)
  v.timer = (io.clock.after)(H264_OPEN_TIMEOUT, () => v.end("X11 H.264 capture did not produce a frame"))
  // Open waits for an actual encoded frame, so a missing encoder or inaccessible display is reported to the viewer.
  io.go(async fn() {
    let frame = v.acquire() catch {
      e => {
        ignore(v.ready.fail(e))
        return
      }
    }
    match frame {
      Some(f) if !v.ended => {
        v.first = Some(f)
        (v.timer)()
        ignore(v.ready.succeed(()))
      }
      _ => ignore(v.ready.fail(fail(v.failure)))
    }
  })
  v
}

///|
fn X11H264::error_text(self : X11H264, data : Bytes) -> Unit {
  self.stderr = trim_js(last_units(self.stderr + @utf8.decode_lossy(data), 2000))
}

///|
/// `s.slice(-n)`.
fn last_units(s : String, n : Int) -> String {
  let l = units_len(s)
  slice_units(s, if l > n { l - n } else { 0 }, l)
}

///|
fn X11H264::raw(self : X11H264, chunk : Bytes) -> Unit {
  if self.ended {
    return
  }
  let mut at = 0
  while at < chunk.length() {
    let room = self.raw_size - self.building.length()
    let take = if chunk.length() - at < room { chunk.length() - at } else { room }
    self.building.write_bytesview(chunk[at:at + take])
    at += take
    if self.building.length() != self.raw_size {
      continue
    }
    self.latest = Some((self.building.to_bytes(), self.io.clock.us()))
    self.building.reset()
    self.submit()
  }
}

///|
fn X11H264::start_encoder(self : X11H264) -> Unit {
  let old = self.encoder.map(e => e.1)
  self.encoder = None
  stop_encoder(old)
  self.carry.reset()
  self.header = false
  self.description = None
  self.config = true
  self.force = false
  self.encoding = js_round(self.requested)
  self.restarted = self.io.clock.ms()
  let (w, h) = self.size
  let rate = num_text(self.encoding)
  let args = [
    "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "\{num_text(w)}x\{num_text(h)}",
    "-framerate", num_text(self.fps), "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
    "-profile:v", "baseline", "-pix_fmt", "yuv420p", "-g", num_text(self.fps * 2.0), "-b:v", rate, "-maxrate", rate,
    "-bufsize", num_text(js_max(100000.0, js_round(self.encoding * 0.25))), "-x264-params", "vbv-init=0.5", "-threads", "1",
    "-flvflags", "no_duration_filesize", "-flush_packets", "1", "-f", "flv", "pipe:1",
  ]
  self.encoders += 1
  let id = self.encoders
  let mine = () => match self.encoder {
    Some((i, _)) => i == id
    None => false
  }
  let encoder = (self.io.procs.spawn)(self.ffmpeg, args, SpawnOptions::piped(env=Some(self.env)), {
    out: d => if mine() { self.flv(d) },
    err: d => if mine() { self.error_text(d) },
    error: e => if mine() { self.end(e) },
    close: (_, _) => if mine() { self.end(if self.stderr != "" { self.stderr } else { "H.264 encoder ended" }) },
  })
  self.encoder = Some((id, encoder))
}

///|
fn X11H264::submit(self : X11H264) -> Unit {
  guard self.pending is Some(pending) else { return }
  if self.ended || pending.submitted || self.latest is None {
    return
  }
  // Lower the rate promptly when the link worsens; increase it more cautiously.
  let elapsed = self.io.clock.ms() - self.restarted
  let down = self.requested < self.encoding * 0.7 && elapsed >= RESTART_MS
  let up = self.requested > self.encoding * 1.8 && elapsed >= RESTART_MS * 3.0
  if self.encoder is None || self.force || down || up {
    self.start_encoder()
  }
  let (data, ts) = self.latest.unwrap()
  self.latest = None
  pending.ts = ts
  pending.submitted = true
  match self.encoder {
    Some((id, e)) => (e.write)(data, Some(err => match (err, self.encoder) {
      (Some(m), Some((i, _))) if i == id => self.end(m)
      _ => ()
    }))
    None => ()
  }
}

///|
fn X11H264::flv(self : X11H264, chunk : Bytes) -> Unit {
  if self.ended {
    return
  }
  self.carry.write_bytes(chunk)
  if !self.header {
    let all = self.carry.to_bytes()
    if all.length() < 9 {
      return
    }
    let offset = u32be(all, 5).to_int()
    if latin1_text(all[0:3]) != "FLV" || offset < 9 || offset > 1024 {
      return self.end("invalid H.264 stream header")
    }
    if all.length() < offset + 4 {
      return
    }
    self.carry.reset()
    self.carry.write_bytesview(all[offset + 4:])
    self.header = true
  }
  while self.carry.length() >= 11 {
    let all = self.carry.to_bytes()
    let kind = all[0].to_int()
    let length = u24be(all, 1)
    if length > MAX_PACKET {
      return self.end("H.264 packet is too large")
    }
    let total = 11 + length + 4
    if all.length() < total {
      return
    }
    let payload = Bytes::from_array(all[11:11 + length].to_array())
    self.carry.reset()
    self.carry.write_bytesview(all[total:])
    if kind != 9 || payload.length() < 5 || (payload[0].to_int() & 15) != 7 {
      continue
    }
    if payload[1] == b'\x00' {
      self.description = Some(Bytes::from_array(payload[5:].to_array()))
      continue
    }
    if payload[1] != b'\x01' {
      continue
    }
    guard self.pending is Some(pending) && pending.submitted else { return self.end("unexpected H.264 frame") }
    let key = (payload[0].to_int() >> 4) == 1
    if self.config && (self.description is None || !key) {
      return self.end("H.264 stream did not start with a key frame and configuration")
    }
    let ts = js_max(self.last_ts + 1.0, pending.ts)
    self.last_ts = ts
    let config = if self.config {
      Some({ codec: H264, width: self.size.0, height: self.size.1, description: self.description, region: None })
    } else {
      None
    }
    self.config = false
    self.pending = None
    (pending.resolve)(Some({ config, key, ts, data: Bytes::from_array(payload[5:].to_array()) }))
  }
}

///|
async fn X11H264::acquire(self : X11H264) -> Frame? {
  if self.ended {
    return None
  }
  if self.pending is Some(_) {
    raise fail("a frame is already being captured")
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.pending = Some({ resolve: f => ignore(d.succeed(f)), submitted: false, ts: 0.0 })
  self.submit()
  d.wait()
}

///|
pub async fn X11H264::next(self : X11H264) -> Frame? {
  self.ready.wait()
  if self.ended {
    return None
  }
  match self.first {
    Some(f) => {
      self.first = None
      return Some(f)
    }
    None => ()
  }
  self.acquire()
}

///|
pub fn X11H264::rate(self : X11H264, bits : Double) -> Unit {
  if bits.is_finite() {
    self.requested = js_min(MAX_RATE, js_max(MIN_RATE, bits))
  }
}

///|
pub fn X11H264::keyframe(self : X11H264) -> Unit {
  self.force = true
}

///|
pub fn X11H264::video(self : X11H264) -> ScreenVideo {
  ignore(self)
  { capture: "X11", encoder: Some("ffmpeg libx264 (software)"), hardware: Some(false) }
}

///|
fn X11H264::end(self : X11H264, reason : String, closed? : Bool = false) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  self.failure = trim_js(reason)
  self.closed = closed
  (self.timer)()
  match self.capture {
    Some(c) => (c.kill)("SIGTERM")
    None => ()
  }
  let encoder = self.encoder.map(e => e.1)
  self.encoder = None
  stop_encoder(encoder)
  self.latest = None
  self.carry.reset()
  let pending = self.pending
  self.pending = None
  match pending {
    Some(p) => (p.resolve)(None)
    None => ()
  }
  (self.gone)()
}

///|
/// Why its capture or encoder ended by itself (ffmpeg's words); none once it was closed.
pub fn X11H264::why(self : X11H264) -> String? {
  if self.ended && !self.closed {
    Some(self.failure)
  } else {
    None
  }
}

///|
pub fn X11H264::close(self : X11H264) -> Unit {
  self.end("X11 H.264 view closed", closed=true)
}
