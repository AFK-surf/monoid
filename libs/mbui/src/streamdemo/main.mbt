// A picture decoded frame by frame (@ui.Stream): the sample's H.264 (scripts/stream_sample.py: an avcC, then access
// units in AVCC), or its JPEG frames where the host decodes no H.264 or MBUI_STREAM=jpeg, handed over as a remote
// screen's station sends them: at most two ahead of the last one said shown. Each frame said shown and the decoder
// broken go on the log ("STREAM shown TS", "STREAM broken"), then "STREAM done" once every frame was. The picture is
// drawn contained in the window, the frame's time over it. For the hosts' checks: `APP=streamdemo scripts/mac.sh`,
// `scripts/android.sh` (a run at its rest shows the last frame), scripts/android-streams.sh.
//
// MBUI_STREAM_LAYER=1: on the host's system video layer (@ui.Stream's `layer`), its frames fed on and on at 10 a
// second, the sample's 15 over again, each round of them a part of their own (as a remote screen zoomed in sends
// another part): its first frame one that moves the picture (Stream::new's `quiet` false), drawn the other side of
// the window, high or low, in the frame that shows it. On a host that puts that frame on the layer with the place it
// is drawn at, the picture is never seen with one round's frame at the other round's place: as recorded
// (`ENV=MBUI_STREAM_LAYER=1 APP=streamdemo scripts/android.sh record layer 25`), each round's first frame (its colours
// scrolled furthest right) shows first at its own side.

///|
let stream : Ref[@ui.Stream?] = Ref(None)

///|
/// The frames handed over, and those said shown (the highest, counted from 1).
let fed : Ref[Int] = Ref(0)

///|
let acked : Ref[Int] = Ref(0)

///|
fn jpeg_mode() -> Bool {
  @ui.env("MBUI_STREAM") == "jpeg" || !@ui.h264_here()
}

///|
fn total() -> Int {
  if jpeg_mode() {
    sample_jpegs.length()
  } else {
    sample_frames.length()
  }
}

///|
/// The next frames, as a station sends them: at most two ahead of the last one said shown.
fn feed(s : @ui.Stream) -> Unit {
  while fed.val < total() && fed.val - acked.val < 2 {
    let i = fed.val
    let ts = ((i + 1) * 100).to_double()
    if jpeg_mode() {
      s.jpeg(@codec.from_base64(sample_jpegs[i]), ts)
    } else {
      let (key, data) = sample_frames[i]
      s.frame(@codec.from_base64(data), key, ts)
    }
    fed.val = i + 1
  }
}

///|
/// MBUI_STREAM_REOPEN=N: the stream closed once frame N is said shown (its decoder busy with those after it) and a
/// new one fed from the start, as the viewer does going from one screen to another; "STREAM done" the new one's.
fn reopen_at() -> Int {
  let mut n = 0
  for c in @ui.env("MBUI_STREAM_REOPEN") {
    if c < '0' || c > '9' {
      return 0
    }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  n
}

///|
let reopened : Ref[Bool] = Ref(false)

///|
fn layer_mode() -> Bool {
  @ui.env("MBUI_STREAM_LAYER") == "1"
}

///|
/// Which round of the sample frame `ts` is of, 0 or 1: the side it is drawn at.
fn side_of(ts : Double) -> Int {
  ((ts / 100.0).to_int() - 1) / 15 % 2
}

///|
/// The side the frame shown now is drawn at (0 before any).
fn side_now() -> Int {
  match stream.val.bind(fn(s) { s.shown_at() }) {
    Some(ts) => side_of(ts)
    None => 0
  }
}

///|
/// The next frame fed, on its round's place in the sample (layer mode), and when the one after it is.
let next_feed_at : Ref[Double] = Ref(0.0)

///|
fn feed_round(s : @ui.Stream) -> Unit {
  let i = fed.val % 15
  let (key, data) = sample_frames[i]
  s.frame(@codec.from_base64(data), key, ((fed.val + 1) * 100).to_double())
  fed.val += 1
}

///|
fn start_layer() -> Unit {
  let s = @ui.Stream::new(
    shown=fn(ts) {
      @ui.log("STREAM shown \{ts} side \{side_of(ts)}")
      let n = (ts / 100.0).to_int()
      if n > acked.val {
        acked.val = n
      }
    },
    broken=fn() { @ui.log("STREAM broken") },
    layer=true,
    // (a frame of the round shown now changes nothing drawn; the first of the next moves the picture)
    quiet=Some(fn(ts) { side_of(ts) == side_now() }),
  )
  stream.val = Some(s)
  @ui.log("STREAM start layer")
  s.h264(@codec.from_base64(sample_avcc), sample_w, sample_h)
}

///|
fn start() -> Unit {
  if layer_mode() {
    start_layer()
    return
  }
  let s = @ui.Stream::new(
    shown=fn(ts) {
      @ui.log("STREAM shown \{ts}")
      // (and drawn, when it is the frame the stream shows: decoded, not let go; android-streams.sh's judge)
      match stream.val {
        Some(s) if s.shown_at() == Some(ts) => @ui.log("STREAM drawn \{ts}")
        _ => ()
      }
      let n = (ts / 100.0).to_int()
      if n > acked.val {
        acked.val = n
      }
      if !reopened.val && reopen_at() > 0 && acked.val >= reopen_at() {
        reopened.val = true
        match stream.val {
          Some(old) => old.close()
          None => ()
        }
        @ui.log("STREAM reopen")
        fed.val = 0
        acked.val = 0
        start()
        return
      }
      if acked.val == total() {
        @ui.log("STREAM done")
        // (a host's check: the run's own end, MBUI_STREAM_EXIT=1)
        if @ui.env("MBUI_STREAM_EXIT") == "1" {
          @hostapi.exit(0)
        }
      }
      match stream.val {
        Some(s) => feed(s)
        None => ()
      }
    },
    broken=fn() { @ui.log("STREAM broken") },
  )
  stream.val = Some(s)
  @ui.log("STREAM start \{if jpeg_mode() { "jpeg" } else { "h264" }} \{total()} frames")
  if !jpeg_mode() {
    s.h264(@codec.from_base64(sample_avcc), sample_w, sample_h)
  }
  feed(s)
}

///|
fn view(c : @ui.Ctx) -> Unit {
  if stream.val is None {
    c.after_build("start", start)
  }
  if layer_mode() {
    match stream.val {
      Some(s) => {
        if next_feed_at.val == 0.0 {
          next_feed_at.val = c.moment()
        }
        // (fed on at 10 a second, at most two ahead of the last said shown)
        c.at_moment("feed", next_feed_at.val, fn() {
          if fed.val - acked.val < 2 {
            feed_round(s)
          }
          next_feed_at.val = next_feed_at.val + 100.0
        })
        let side = side_now()
        // (its node the height of both places, the picture drawn at its side's)
        let top = if side == 0 { 0.0 } else { 276.0 }
        c.stream(s, w=Px(320.0), h=Px(456.0), at=Some((0.0, top, 320.0, 180.0))) |> ignore
        c.text("side \{side}") |> ignore
      }
      None => ()
    }
    return
  }
  match stream.val {
    Some(s) => {
      c.stream(s, fit=FitContain) |> ignore
      let at = match s.shown_at() {
        Some(ts) => "frame \{ts}"
        None => "no frame yet"
      }
      let size = match s.size() {
        Some((w, h)) => " \{w}x\{h}"
        None => ""
      }
      c.text("stream: " + at + size) |> ignore
    }
    None => ()
  }
}

///|
fn main {
  @hostapi.window_setup(480.0, 320.0, 720.0, 480.0)
  @ui.run_legacy_ctx("mbui streams", view)
}
