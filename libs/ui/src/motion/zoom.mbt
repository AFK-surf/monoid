// Zooming and panning a picture in a stage (an image, a video's frames, a remote screen: still.fail's Android app's
// shared ui/Zoom.kt ZoomState, the web's FilePreview.tsx useZoom): fitted to the stage (a margin round it, enlarged
// or not), zoomed around a point (two fingers' pinch, a double tap, the wheel, a button), panned, and kept within the
// stage: smaller than it, centred; larger, no gap at its edges (or, free, anywhere: a page on a canvas, dragged about
// it). A zoom said with a glide goes there on a Move as long as its way is far; one let go by a finger moving goes on at
// its speed, slowing, to its edges (fling): each a way said once as it sets out, at the moment of what told it (an
// input's, a frame's), where it is at a moment a function of that way and the moment (ZPath). What the fingers do is
// the view's: it says what they came to (transform, pan, fling, zoom_to, double_tap). Each command starts from where
// the picture is at its moment, by what it was told and the way it is on, whatever frames were drawn (Zoom::settle),
// and tells what reads it once, as it leaves it (Zoom::moved).

///|
/// Where a picture shows in its stage: `scale` is stage points per picture pixel, `x` and `y` move its centre from the
/// stage's. `nw` × `nh` is the picture's size (its pixels; 0 until known), `bw` × `bh` the stage's.
pub struct Zoom {
  mut nw : Double
  mut nh : Double
  mut bw : Double
  mut bh : Double
  /// how much of the stage's top and of its foot bars over it take (Zoom::under_bars)
  mut bar : Double
  mut foot_bar : Double
  /// extra top/foot pan clearance when zoomed (Zoom::pan_under_bars), without shrinking fitted stage height
  mut pan_bar : Double
  mut pan_foot_bar : Double
  mut scale : Double
  mut x : Double
  mut y : Double
  mut fitted : Bool
  /// the margin round the fitted picture, for a stage this wide
  margin_of : (Double) -> Double
  /// fitted larger than the picture's own size where the stage has room (else never over 1)
  enlarge : Bool
  /// the least and the most it zooms to, for the fitted scale
  min_of : (Double) -> Double
  max_of : (Double) -> Double
  /// moved anywhere on the stage, not kept within it (its scale still within its bounds)
  free : Bool
  /// the fitted scale a whole number of these (0: as it comes)
  fit_step : Double
  // a glide: whether one goes on, how far (0 … 1, its way), from, to (scale, x, y)
  mut gliding : Bool
  priv glide : ZPath
  g_from : FixedArray[Double]
  g_to : FixedArray[Double]
  // a fling: whether one goes on, the ways of x and of y (Motion's inertia, stopped at the edges)
  mut flinging : Bool
  priv fling_x : ZPath
  priv fling_y : ZPath
  /// what it was told to show, as each change of it leaves it (Zoom::said: its sizes, where it is or the way it goes):
  /// read where what it shows is followed (Zoom::told, sized), so that what was built by it is built again as that changes, by
  /// whatever way, whoever changed it, as it was built or between frames; told the same, none
  priv place : @signals.Signal[ZoomSaid]
}

///|
/// What a zoom was told to show: the picture's size and the stage's, where it is (scale, x, y) and whether fitted, the
/// glide or the fling it is on (where a glide goes; a fling's own way its motions'). Where it shows at a moment is a
/// function of this and of those motions (Zoom::rect_at).
#derive(Eq)
priv struct ZoomSaid {
  nw : Double
  nh : Double
  bw : Double
  bh : Double
  scale : Double
  x : Double
  y : Double
  fitted : Bool
  gliding : Bool
  to : (Double, Double, Double)
  flinging : Bool
}

///|
/// One number's way, said once as it sets out (from where, how fast, to where, by what, from when): where it is at a
/// moment worked out from that alone, whatever frames were drawn; said to move till it ends (the frames come).
priv struct ZPath {
  mut from : Double
  mut v0 : Double
  mut to : Double
  mut spec : Spec
  mut start : Double
  mut dur : Double
  mut on : Bool
}

///|
fn ZPath::new() -> ZPath {
  { from: 0.0, v0: 0.0, to: 0.0, spec: Snap(0.0), start: 0.0, dur: 0.0, on: false }
}

///|
/// When it is there: its time goes in whole ms (Spec::value_at), so at the first whole ms its length is out.
fn ZPath::end(self : ZPath) -> Double {
  self.start + self.dur.ceil()
}

///|
/// Off from `from` (as fast as `v0`, per second) to `to` by `spec`, from the moment `at` (its cause's).
fn ZPath::go(self : ZPath, from : Double, to : Double, spec : Spec, v0 : Double, at : Double) -> Unit {
  self.from = from
  self.v0 = v0
  self.to = to
  self.spec = spec
  self.start = at
  self.dur = spec.duration(from, to, v0)
  self.on = true
}

///|
/// Stopped at `t`, where it is then: there from here on, as what was told of it before says (read anywhere after).
fn ZPath::halt(self : ZPath, t : Double) -> Unit {
  let v = self.at(t)
  self.on = false
  self.from = v
  self.to = v
}

///|
/// Where it is at `t`.
fn ZPath::at(self : ZPath, t : Double) -> Double {
  if !self.on {
    return self.to
  }
  self.spec.value_at(zmax(0.0, t - self.start), self.dur, self.from, self.to, self.v0).0
}

///|
/// A picture's zoom, as Zoom.kt's: fitted within a margin (12, or 32 on a stage 640 wide or more), never enlarged;
/// down to half the fitted size (of 100% at most) and up to 16 times its own; its glides a Move as long as the
/// picture's corners go far (@ui.move_ms). A stage's own (a
/// remote screen, fitted edge to edge, as far as 5 times the fitted size): `margin`, `enlarge`, `min_scale` and
/// `max_scale` (each of the fitted scale) say so. `free`: moved anywhere on the stage (a page on a canvas); `fit_step`:
/// the fitted scale a whole number of these, rounded down.
pub fn Zoom::new(
  margin? : (Double) -> Double = fn(bw) { if bw < 640.0 { 12.0 } else { 32.0 } },
  enlarge? : Bool = false,
  min_scale? : (Double) -> Double = fn(fit) { zmin(fit, 1.0) / 2.0 },
  max_scale? : (Double) -> Double = fn(_) { 16.0 },
  free? : Bool = false,
  fit_step? : Double = 0.0,
) -> Zoom {
  {
    nw: 0.0,
    nh: 0.0,
    bw: 0.0,
    bh: 0.0,
    bar: 0.0,
    foot_bar: 0.0,
    pan_bar: 0.0,
    pan_foot_bar: 0.0,
    scale: 1.0,
    x: 0.0,
    y: 0.0,
    fitted: true,
    margin_of: margin,
    enlarge,
    min_of: min_scale,
    max_of: max_scale,
    free,
    fit_step,
    gliding: false,
    glide: ZPath::new(),
    g_from: FixedArray::make(3, 0.0),
    g_to: FixedArray::make(3, 0.0),
    flinging: false,
    fling_x: ZPath::new(),
    fling_y: ZPath::new(),
    place: @signals.signal(
      { nw: 0.0, nh: 0.0, bw: 0.0, bh: 0.0, scale: 1.0, x: 0.0, y: 0.0, fitted: true, gliding: false, to: (0.0, 0.0, 0.0), flinging: false },
      same=fn(a, b) { a == b },
    ),
  }
}

///|
fn zmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn zabs(a : Double) -> Double {
  if a < 0.0 {
    -a
  } else {
    a
  }
}

///|
fn zmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// How far under the stage's top the fitted picture's room starts: its margin, or under a bar half of it past the bar
/// (the web's useZoom padTop).
fn Zoom::fit_top(self : Zoom) -> Double {
  let m = (self.margin_of)(self.bw)
  if self.bar > 0.0 {
    self.bar + m / 2.0
  } else {
    m
  }
}

///|
/// How far over the stage's foot the fitted picture's room ends, as Zoom::fit_top.
fn Zoom::fit_foot(self : Zoom) -> Double {
  let m = (self.margin_of)(self.bw)
  if self.foot_bar > 0.0 {
    self.foot_bar + m / 2.0
  } else {
    m
  }
}

///|
/// Where a picture no taller than the room between the bars sits: `y` of the middle of its fitted room.
fn Zoom::rest_y(self : Zoom) -> Double {
  (self.fit_top() - self.fit_foot()) / 2.0
}

///|
/// How far `y` goes with the picture `scale`: no taller than the room between the bars, its middle only; taller, no gap
/// at that room's edges.
fn Zoom::y_range(self : Zoom, scale : Double) -> (Double, Double) {
  let h = self.nh * scale
  let top_clear = zmax(self.bar, self.pan_bar)
  let foot_clear = zmax(self.foot_bar, self.pan_foot_bar)
  let a = (self.bh - h) / 2.0 - foot_clear
  let b = (h - self.bh) / 2.0 + top_clear
  if h <= self.bh - top_clear - foot_clear {
    let y = self.rest_y()
    if (self.pan_bar > 0.0 || self.pan_foot_bar > 0.0) && (y < b || y > a) {
      (zmin(b, y), zmax(a, y))
    } else {
      (y, y)
    }
  } else {
    (a, b)
  }
}

///|
/// The fitted scale: the whole picture within the stage, its margin round it and clear of the bars over it (not
/// enlarged, unless it may be).
pub fn Zoom::fit(self : Zoom) -> Double {
  if self.nw <= 0.0 || self.nh <= 0.0 || self.bw <= 0.0 || self.bh <= 0.0 {
    return 1.0
  }
  let m = (self.margin_of)(self.bw)
  let k = zmin((self.bw - 2.0 * m) / self.nw, (self.bh - self.fit_top() - self.fit_foot()) / self.nh)
  let k = if self.enlarge { k } else { zmin(1.0, k) }
  if self.fit_step > 0.0 {
    (k / self.fit_step).floor() * self.fit_step
  } else {
    k
  }
}

///|
/// The least it zooms to.
pub fn Zoom::min_scale(self : Zoom) -> Double {
  (self.min_of)(self.fit())
}

///|
/// The most it zooms to.
pub fn Zoom::max_scale(self : Zoom) -> Double {
  (self.max_of)(self.fit())
}

///|
/// The picture's size known (again): fitted, it is fitted to it; else kept within the stage.
pub fn Zoom::natural(self : Zoom, w : Double, h : Double, at~ : Double) -> Unit {
  if w == self.nw && h == self.nh {
    return
  }
  // (what it was on settled where it is: the picture fitted again or kept within from there)
  self.settle(at) |> ignore
  self.nw = w
  self.nh = h
  if self.fitted {
    self.scale = self.fit()
    self.x = 0.0
    self.y = self.rest_y()
  } else {
    self.clamp()
  }
  self.moved()
}

///|
/// The stage's size (again): fitted, the picture is fitted to it; else kept within it.
pub fn Zoom::boxed(self : Zoom, w : Double, h : Double, at~ : Double) -> Unit {
  if w == self.bw && h == self.bh {
    return
  }
  self.settle(at) |> ignore
  self.bw = w
  self.bh = h
  if self.fitted {
    self.scale = self.fit()
    self.x = 0.0
    self.y = self.rest_y()
  } else {
    self.clamp()
  }
  self.moved()
}

///|
/// How much of the stage's top and of its foot bars over it take (the web's `data-floats`: faded or not, a fitted
/// picture stays clear of them): fitted, the picture is fitted to what is left; else kept within it.
pub fn Zoom::under_bars(self : Zoom, bar : Double, foot : Double, at~ : Double) -> Unit {
  if bar == self.bar && foot == self.foot_bar {
    return
  }
  self.settle(at) |> ignore
  self.bar = bar
  self.foot_bar = foot
  if self.fitted {
    self.scale = self.fit()
    self.x = 0.0
    self.y = self.rest_y()
  } else {
    self.clamp()
  }
  self.moved()
}

///|
/// Extra top and foot clearance applied only to zoomed vertical pan bounds (`Zoom::y_range`), leaving fitted scale
/// (`Zoom::fit`) and resting position (`Zoom::rest_y`) untouched so floating overlays cause zero image jump.
pub fn Zoom::pan_under_bars(self : Zoom, bar : Double, foot : Double, at~ : Double) -> Unit {
  if bar == self.pan_bar && foot == self.pan_foot_bar {
    return
  }
  self.settle(at) |> ignore
  self.pan_bar = bar
  self.pan_foot_bar = foot
  if !self.fitted {
    self.clamp()
  }
  self.moved()
}

///|
/// Its scale within its bounds, the picture within the stage: smaller than it, centred; larger, no gap at its edges.
fn Zoom::clamp(self : Zoom) -> Unit {
  if self.nw <= 0.0 {
    return
  }
  self.scale = zmax(self.min_scale(), zmin(self.max_scale(), self.scale))
  if self.free {
    return
  }
  let sx = zmax(0.0, (self.nw * self.scale - self.bw) / 2.0)
  let (y0, y1) = self.y_range(self.scale)
  self.x = zmax(-sx, zmin(sx, self.x))
  self.y = zmax(y0, zmin(y1, self.y))
}

///|
/// What it was told to show, as it is now (place).
fn Zoom::said(self : Zoom) -> ZoomSaid {
  {
    nw: self.nw,
    nh: self.nh,
    bw: self.bw,
    bh: self.bh,
    scale: self.scale,
    x: self.x,
    y: self.y,
    fitted: self.fitted,
    gliding: self.gliding,
    to: (self.g_to[0], self.g_to[1], self.g_to[2]),
    flinging: self.flinging,
  }
}

///|
/// What it was told to show, told (each way it is told anything ends so): what reads where it shows, told where that
/// is otherwise; told the same, nothing.
fn Zoom::moved(self : Zoom) -> Unit {
  self.place.set(self.said())
}

///|
/// Read where what is worked out from what it was told (at a moment of its own: Zoom::rect_at) follows each time it is
/// told otherwise.
pub fn Zoom::told(self : Zoom) -> Unit {
  self.place.get() |> ignore
}

///|
/// Whether the picture's size is known (and so where it shows: Zoom::rect_at), as it is told.
pub fn Zoom::sized(self : Zoom) -> Bool {
  let d = self.place.get()
  d.nw > 0.0 && d.nh > 0.0
}

///|
/// Where the picture shows at the moment `at` (an event's: what it is decided by, where the finger is on it then), by
/// what it was told and the ways it is on, read of nothing followed.
pub fn Zoom::rect_at(self : Zoom, at : Double) -> (Double, Double, Double, Double)? {
  if self.nw <= 0.0 || self.nh <= 0.0 {
    return None
  }
  let (scale, x, y) = self.shown_now(at)
  let w = self.nw * scale
  let h = self.nh * scale
  Some((self.bw / 2.0 + x - w / 2.0, self.bh / 2.0 + y - h / 2.0, w, h))
}

///|
/// How big it is shown at the moment `at` (by what it was told and the ways it is on, read of nothing followed).
pub fn Zoom::scale_at(self : Zoom, at : Double) -> Double {
  self.shown_now(at).0
}

///|
/// Whether it is zoomed in at the moment `at` (nothing followed).
pub fn Zoom::zoomed_at(self : Zoom, at : Double) -> Bool {
  let (scale, _, _) = self.shown_now(at)
  scale > self.fit() * 1.01
}

///|
/// Where (`x`, `y`) at `scale` is, kept within the stage (Zoom::clamp's, read only).
fn Zoom::kept_within(self : Zoom, scale : Double, x : Double, y : Double) -> (Double, Double, Double) {
  if self.free {
    return (scale, x, y)
  }
  let sx = zmax(0.0, (self.nw * scale - self.bw) / 2.0)
  let (y0, y1) = self.y_range(scale)
  (scale, zmax(-sx, zmin(sx, x)), zmax(y0, zmin(y1, y)))
}

///|
/// Where it shows at the moment a command is told (the command's moment: an input's, between frames; a frame's, in one), by what
/// it was told and the ways it is on, read of nothing followed: where that command starts from.
fn Zoom::shown_now(self : Zoom, t : Double) -> (Double, Double, Double) {
  if self.flinging {
    self.kept_within(self.scale, self.fling_x.at(t), self.fling_y.at(t))
  } else if self.gliding {
    let e = self.glide.at(t)
    (
      self.g_from[0] + (self.g_to[0] - self.g_from[0]) * e,
      self.g_from[1] + (self.g_to[1] - self.g_from[1]) * e,
      self.g_from[2] + (self.g_to[2] - self.g_from[2]) * e,
    )
  } else {
    (self.scale, self.x, self.y)
  }
}

///|
/// A glide or a fling it is on called off where it has it now (shown_now: what was told and the motions, whether a
/// frame sampled them or not), the place it is at said so; nothing told yet (Zoom::moved, once its command is done).
/// Whether one went on.
fn Zoom::settle(self : Zoom, t : Double) -> Bool {
  if !self.gliding && !self.flinging {
    return false
  }
  let (s, x, y) = self.shown_now(t)
  self.gliding = false
  self.glide.halt(t)
  self.flinging = false
  self.fling_x.halt(t)
  self.fling_y.halt(t)
  self.scale = s
  self.x = x
  self.y = y
  true
}

///|
/// Moved by (dx, dy) and kept within the stage, from where it shows now; told nothing yet.
fn Zoom::pan_by(self : Zoom, dx : Double, dy : Double, t : Double) -> Unit {
  self.settle(t) |> ignore
  let (x0, y0) = (self.x, self.y)
  self.x = self.x + dx
  self.y = self.y + dy
  self.clamp()
  // (moved nowhere, by nothing or against the stage's edges: as it was, fitted still if it was)
  if self.x != x0 || self.y != y0 {
    self.fitted = false
  }
}

///|
/// Moved by a finger (dx, dy), a glide called off where it had it. (Each command below: what it was told before
/// settled at its moment first, then its whole change, then told once, as it is left: Zoom::moved.)
pub fn Zoom::pan(self : Zoom, dx : Double, dy : Double, at~ : Double) -> Unit {
  self.pan_by(dx, dy, at)
  self.moved()
}

///|
/// By `zoom` around (ax, ay) on the stage, and moved by (dx, dy): two fingers pinching, the point
/// under them staying under them.
pub fn Zoom::transform(
  self : Zoom,
  ax : Double,
  ay : Double,
  zoom : Double,
  dx : Double,
  dy : Double,
  at~ : Double,
) -> Unit {
  self.settle(at) |> ignore
  let next = zmax(self.min_scale(), zmin(self.max_scale(), self.scale * zoom))
  let f = next / self.scale
  let px = ax - self.bw / 2.0
  let py = ay - self.bh / 2.0
  let was = (self.scale, self.x, self.y)
  self.scale = next
  self.x = px - (px - self.x) * f + dx
  self.y = py - (py - self.y) * f + dy
  self.clamp()
  // (as it was, at its bounds and edges: fitted still if it was)
  if (self.scale, self.x, self.y) != was {
    self.fitted = false
  }
  self.moved()
}

///|
/// To `target` (at once, or gliding), the picture's point under (ax, ay) on the stage staying put.
pub fn Zoom::zoom_to(self : Zoom, target : Double, ax : Double, ay : Double, glide : Bool, at~ : Double) -> Unit {
  let t = at
  self.settle(t) |> ignore
  let next = zmax(self.min_scale(), zmin(self.max_scale(), target))
  let px = ax - self.bw / 2.0
  let py = ay - self.bh / 2.0
  let f = next / self.scale
  let mut tx = px - (px - self.x) * f
  let mut ty = py - (py - self.y) * f
  if !self.free {
    let sx = zmax(0.0, (self.nw * next - self.bw) / 2.0)
    let (y0, y1) = self.y_range(next)
    tx = zmax(-sx, zmin(sx, tx))
    ty = zmax(y0, zmin(y1, ty))
  }
  self.fitted = false
  self.glide_to(next, tx, ty, glide, t)
  self.moved()
}

///|
/// How small a picture pulled down a whole stage's height is, of its fitted size (Zoom::pull).
pub let zoom_pull_least : Double = 0.6

///|
/// Pulled off its fitted place by a hand taking it down to close what shows it (a finger, a trackpad's two): its middle
/// (`dx`, `dy`) from where it rests fitted, smaller the further down it is (to zoom_pull_least of its fitted size a
/// stage's height down), kept within nothing. Back with Zoom::reset.
pub fn Zoom::pull(self : Zoom, dx : Double, dy : Double, at~ : Double) -> Unit {
  self.settle(at) |> ignore
  let down = if self.bh > 0.0 { zmin(1.0, zmax(0.0, dy) / self.bh) } else { 0.0 }
  self.scale = self.fit() * (1.0 - down * (1.0 - zoom_pull_least))
  self.x = dx
  self.y = self.rest_y() + dy
  self.fitted = false
  self.moved()
}

///|
/// How far down a pull has it at `at` (Zoom::pull: 0 … 1 of the stage's height), by what it was told and its glide;
/// none where it is zoomed in or no lower than it rests.
pub fn Zoom::pulled_at(self : Zoom, at : Double) -> Double {
  if self.bh <= 0.0 || self.nw <= 0.0 {
    return 0.0
  }
  let (scale, _, y) = self.shown_now(at)
  if scale > self.fit() * 1.01 {
    return 0.0
  }
  zmax(0.0, zmin(1.0, (y - self.rest_y()) / self.bh))
}

///|
/// Back to fitted, gliding.
pub fn Zoom::reset(self : Zoom, at~ : Double) -> Unit {
  let t = at
  self.settle(t) |> ignore
  self.glide_to(self.fit(), 0.0, self.rest_y(), true, t)
  self.fitted = true
  self.moved()
}

///|
/// Back to fitted at once.
pub fn Zoom::fit_now(self : Zoom, at~ : Double) -> Unit {
  let t = at
  self.settle(t) |> ignore
  self.glide_to(self.fit(), 0.0, self.rest_y(), false, t)
  self.fitted = true
  self.moved()
}

///|
/// A glide or a fling called off where it is (a finger took it).
pub fn Zoom::stop_glide(self : Zoom, at~ : Double) -> Unit {
  self.settle(at) |> ignore
  self.moved()
}

///|
/// A fling called off where it has got to (a finger came down on it): whether one went on (none: nothing done).
pub fn Zoom::stop_fling(self : Zoom, at~ : Double) -> Bool {
  let t = at
  // (one still going at the press's moment, by its way: whatever a frame drew or sampled meanwhile)
  if !self.flinging || t >= self.fling_end() {
    return false
  }
  // (a fling and a glide are never both on: a fling sets out from where a glide was settled)
  self.settle(t) |> ignore
  self.moved()
  true
}

///|
/// Let go by a finger moving (vx, vy) (stage points per ms): on at that speed, slowing (zoom_fling_ms), to a stop or, kept
/// within the stage, to its edge.
pub fn Zoom::fling(self : Zoom, vx : Double, vy : Double, at~ : Double) -> Unit {
  let at = at
  self.settle(at) |> ignore
  if self.nw <= 0.0 {
    self.moved()
    return
  }
  let sx = zmax(0.0, (self.nw * self.scale - self.bw) / 2.0)
  let (y0, y1) = self.y_range(self.scale)
  let go = fn(v : ZPath, from : Double, speed : Double, low : Double, high : Double) {
    v.on = false
    v.to = from
    if speed != 0.0 && (self.free || high > low) {
      let (min, max) = if self.free { (None, None) } else { (Some(low), Some(high)) }
      // at an edge it stops there (Motion's drag with no give past its ends)
      let spec = inertia_to(
        power=zoom_fling_ms / 1000.0,
        time_constant=zoom_fling_ms,
        bounce_stiffness=1000000.0,
        bounce_damping=10000000.0,
        min?=min,
        max?=max,
      )
      v.go(from, from, spec, speed * 1000.0, at)
    }
  }
  go(self.fling_x, self.x, vx, -sx, sx)
  go(self.fling_y, self.y, vy, y0, y1)
  self.fitted = false
  self.flinging = self.fling_x.on || self.fling_y.on
  self.moved()
}

///|
/// To `s` at (`x`, `y`), at once or gliding from where it is (settled by the command first); told nothing yet.
fn Zoom::glide_to(self : Zoom, s : Double, x : Double, y : Double, glide : Bool, t : Double) -> Unit {
  if !glide {
    self.scale = s
    self.x = x
    self.y = y
    return
  }
  self.g_from[0] = self.scale
  self.g_from[1] = self.x
  self.g_from[2] = self.y
  self.g_to[0] = s
  self.g_to[1] = x
  self.g_to[2] = y
  // said once as it sets out: the motion asks the frames until it is there
  self.gliding = true
  // (as long as the furthest of its corners goes; from the moment it is told)
  let far = zmax(zabs(x - self.g_from[1]), zabs(y - self.g_from[2])) +
    zmax(self.nw, self.nh) * zabs(s - self.g_from[0])
  self.glide.go(0.0, 1.0, moved(over=far), 0.0, t)
}

///|
/// Whether a glide or a fling still moves it at `t` (where it shows then not where it shows at their end: Zoom::rect_at).
pub fn Zoom::goes_at(self : Zoom, t : Double) -> Bool {
  (self.flinging && t < self.fling_end()) || (self.gliding && self.glide.on && t < self.glide.end())
}

///|
/// When a fling has it where it rests (the frames' clock, ms; -1 none going).
pub fn Zoom::fling_ends(self : Zoom) -> Double {
  if !self.flinging {
    return -1.0
  }
  self.fling_end()
}

///|
/// When its fling's ways end (the later of the two).
fn Zoom::fling_end(self : Zoom) -> Double {
  let end = fn(p : ZPath) { if p.on { p.end() } else { -1.0 } }
  zmax(end(self.fling_x), end(self.fling_y))
}

///|
/// A double tap: fitted, in to 2.5× the fitted size (at least 100%) around it; zoomed, back to fitted.
pub fn Zoom::double_tap(self : Zoom, ax : Double, ay : Double, at~ : Double) -> Unit {
  // (zoomed or not as it is at the tap's moment, a glide's way read there)
  let t = at
  self.settle(t) |> ignore
  if self.scale > self.fit() * 1.01 {
    self.reset(at=t)
  } else {
    self.zoom_to(zmax(self.fit() * 2.5, 1.0), ax, ay, true, at=t)
  }
}

///|
/// Where the picture is on the stage now (x, y, w, h), as Zoom::rect_at has it, read of nothing followed.
fn Zoom::rect_now(self : Zoom, t : Double) -> (Double, Double, Double, Double)? {
  if self.nw <= 0.0 || self.nh <= 0.0 {
    return None
  }
  let (scale, x, y) = self.shown_now(t)
  let w = self.nw * scale
  let h = self.nh * scale
  Some((self.bw / 2.0 + x - w / 2.0, self.bh / 2.0 + y - h / 2.0, w, h))
}

///|
/// The picture's point `at` brought `margin` within the stage's edges, as little as it takes; told nothing yet.
fn Zoom::keep_in(self : Zoom, at : (Double, Double), margin : Double, t : Double) -> Unit {
  let (x, y, w, h) = match self.rect_now(t) {
    Some(r) => r
    None => return
  }
  let px = x + at.0 * w
  let py = y + at.1 * h
  let off = fn(v : Double, room : Double) {
    if room < 2.0 * margin {
      room / 2.0 - v
    } else if v < margin {
      margin - v
    } else if v > room - margin {
      room - margin - v
    } else {
      0.0
    }
  }
  let dx = off(px, self.bw)
  let dy = off(py, self.bh)
  if dx != 0.0 || dy != 0.0 {
    self.pan_by(dx, dy, t)
  }
}

///|
/// The picture's point `at` (0 … 1 of its width and height) brought `margin` within the stage's edges, the picture
/// moved as little as it takes (a pointer kept in sight while zoomed in).
pub fn Zoom::keep(self : Zoom, at : (Double, Double), margin : Double, when~ : Double) -> Unit {
  self.keep_in(at, margin, when)
  self.moved()
}

///|
/// The stage resized to `w` × `h` (a keyboard up or down): the picture drawn as large as it was (within its bounds), the
/// point `at` of it (0 … 1; None: what was in the stage's middle) where it was on the stage and then kept `margin`
/// within it.
pub fn Zoom::resize_keeping(
  self : Zoom,
  w : Double,
  h : Double,
  at : (Double, Double)?,
  margin : Double,
  when~ : Double,
) -> Unit {
  let t = when
  let was = match self.rect_now(t) {
    Some(r) => r
    None => {
      self.settle(t) |> ignore
      self.bw = w
      self.bh = h
      self.glide_to(self.fit(), 0.0, self.rest_y(), false, t)
      self.fitted = true
      self.moved()
      return
    }
  }
  let (wx, wy, ww, wh) = was
  let u = match at {
    Some(a) => a
    None => ((self.bw / 2.0 - wx) / ww, (self.bh / 2.0 - wy) / wh)
  }
  // where that point was on the stage, its new place's centre offset making it stay there
  let px = wx + u.0 * ww
  let py = wy + u.1 * wh
  self.settle(t) |> ignore
  self.bw = w
  self.bh = h
  self.fitted = false
  self.scale = zmax(self.min_scale(), zmin(self.max_scale(), self.scale))
  let nw = self.nw * self.scale
  let nh = self.nh * self.scale
  self.x = px - u.0 * nw + nw / 2.0 - w / 2.0
  self.y = py - u.1 * nh + nh / 2.0 - h / 2.0
  self.clamp()
  self.keep_in(u, margin, t)
  self.moved()
}
