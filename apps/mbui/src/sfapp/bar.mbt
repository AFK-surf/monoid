// The phone's bottom bar, as Comma's Android tab bar is drawn (ShellTabBar.kt): a floating capsule of liquid glass
// holding the places of one bar, 22 in from the screen's sides and its foot (the system's bars are the host's: the
// view is laid out inside them); a grey pill under the place shown that travels on a spring stretched by its speed and
// goes where a finger takes it, a lens of clear glass lifting out of it under a finger; the page's primary action (令,
// a new chat, on the chats' pages) a glass circle of its own beside the capsule, 10 to its right, the capsule giving it
// room as it comes; with more than one bar, the glass grows upward into a panel of the other bars, one row each, open
// once a finger on the bar is drawn 24 over it and closed once back under 16, and a bar chosen there is the bar. Every
// motion is a number on a spring (or a timed glide) stepped a frame at a time. Shown on a place's top page with
// nothing over it; gone down out of the way (300 ms) under a page pushed, back up (380 ms) as it comes back.
//
// The capsule and the circle are neutral optical liquid glass over the pages (@sf.glass_tab_bar: uniform 2.1pt blur,
// quarter-circle bevel refraction, adaptive iOS 27 color transfer and glint, optional touch spot); where glass is drawn solid, their ground. What moves is only drawn so (src/motion's rule): the
// bar going down and coming back, the capsule giving the action room and the action growing and shrinking, its icon
// swapping, a bar chosen in the panel sliding down into the bar's place are looks over where they are laid out, and
// what leaves is drawn only. (The action shown or not is still called the notch here, `k`, as it stood in one cut into
// the bar's top before it was a circle of its own.)

// ── geometry (dp) ──────────────────────────────────────────────

///|
let bar_track : Double = 56.0

///|
/// How far the pill under the place shown is in from the capsule's edge (ShellTabBar.kt PILL_INSET_DP): its corner the
/// capsule's less that, concentric.
let pill_inset : Double = 4.0

///|
/// The pill's height (ShellTabBar.kt PILL_DP, as the capsule's 60 is our 56).
let pill_h : Double = bar_track - pill_inset * 2.0

///|
/// How far in from the capsule's ends its places start (ShellTabBar.kt TAB_EDGE_DP).
let tab_edge : Double = 8.0

///|
/// The action's circle: as high as the capsule, `act_gap` to its right (ShellTabBar.kt HEIGHT_DP, GAP_DP).
let act_size : Double = bar_track

///|
let act_gap : Double = 10.0

///|
/// How much taller than the capsule its lens is lifted (TabBarLens.kt LIFTED_HEIGHT_RATIO), and how wide for that
/// height, no wider than a share of a place (LIFTED_ASPECT, LIFTED_TAB_SHARE).
let lens_lift_h : Double = 1.17

///|
let lens_lift_aspect : Double = 1.45

///|
/// How far the bar and its panel are drawn up while a finger has them. Give a taller window a little more room above
/// the finger, but limit the rise to the room the fully opened panel has below the system's top inset. Only drawn so:
/// where a finger is taken stays where the bar is laid out.
fn bar_raise(height : Double, foot : Double, panel : Double, top : Double) -> Double {
  let desired = dclamp(height * 0.07, 48.0, 64.0)
  let room = dmax(0.0, height - foot - panel + over - top - 8.0)
  dmin(desired, room)
}

///|
let bar_row : Double = 56.0

///|
let over : Double = 20.0

///|
let rad : Double = bar_track / 2.0

///|
let slot_px : Double = 90.0

///|
let lean : Double = 0.25


///|
let opens : Double = 24.0

///|
let closes : Double = 16.0

///|
/// How long a finger held still on the bar takes the ball (its lens over it), as one sliding does.
let bar_hold_ms : Double = 200.0

///|
/// What a place's top page keeps clear at its foot for the bar (Places.kt BAR_ROOM: the bar, its 22 from the foot, a
/// little air, and the action standing 32 over it).
let bar_room : Double = 56.0 + 22.0 + 16.0 + 32.0

///|
/// The chats' family of places, whose pages have 令 in the notch.
// kept across runs: a table, never written
let chat_family : Array[String] = ["chats", "archive"]

///|
/// How wide the capsule is on a bar `w` wide with the notch `k` open: the whole bar, less the action's circle and its
/// gap as far as it is open.
pub fn bar_capsule_w(w : Double, k : Double) -> Double {
  w - (act_size + act_gap) * k
}

///|
/// How wide each of `n` places is in the capsule of a bar `w` wide with the notch `k` open (ShellTabBar.kt itemWidth).
fn bar_item_w(w : Double, k : Double, n : Int) -> Double {
  (bar_capsule_w(w, k) - 2.0 * tab_edge) / (if n < 1 { 1 } else { n }).to_double()
}

///|
/// The slot a place is laid out in: as wide as a place is with the action there, its icon in its middle.
fn bar_slot(w : Double, n : Int) -> Double {
  bar_item_w(w, 1.0, n)
}

///|
/// The places' middles on a bar `w` wide holding `n` with the notch `k` open: each in the middle of its share of the
/// capsule; four always, those past `n` the last's.
pub fn bar_centres(w : Double, k : Double, n : Int) -> Array[Double] {
  let m = if n < 1 { 1 } else { n }
  let iw = bar_item_w(w, k, m)
  [0, 1, 2, 3].map(fn(j) { tab_edge + ((if j < m { j } else { m - 1 }).to_double() + 0.5) * iw })
}

///|
fn nearest(cs : Array[Double], n : Int, x : Double) -> Int {
  let mut best = 0
  for j in 0..<imin(n, cs.length()) {
    if (cs[j] - x).abs() < (cs[best] - x).abs() {
      best = j
    }
  }
  best
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

// ── motion ─────────────────────────────────────────────────────────────
// Motion as data (mbui's motion_data.mbt): each number is said once, as it sets out (where to, by what, from when),
// and where it is at a moment is a function of that moment alone: the bar's nodes read each where it is at the moment
// each frame is drawn while it goes, where it went once it is there (bar_node.mbt), so the frames come until it is at
// rest and none after.

///|
/// How far the bar goes down out of the way (points): coming back (a page it shows on), a Move as long as that is far.
let bar_drop : Double = 120.0

///|
/// How long the bar takes to go (a page pushed over it): shorter than its coming, mostly gone by half of the page's push.
let bar_hide_ms : Double = 250.0

///|
/// How long the ball takes to fade in or out, and to grow back or shrink.
let ball_fade_ms : Double = 200.0

///|
let ball_grow_ms : Double = 250.0

///|
/// How long the notch's icon takes to swap for another.
pub let icon_swap_ms : Double = 300.0

///|
/// One number on a spring (react-spring's tension and friction, mass 1), its way solved
/// (@ui.SpringPath): `x`, `v` and `to` where it is, how fast it goes and where to, as of the moment it last set out.
// set_at is read by bar_moment_wbtest alone
#warnings("-unused_field")
priv struct Spr {
  mut path : @ui.SpringPath?
  /// riding something that moves itself (the ball on a bar chosen coming down: Ride), its way worked out as it set out
  mut ride : Ride?
  mut x : Double
  mut v : Double
  mut to : Double
  mut tension : Double
  mut friction : Double
  /// at rest within it
  rest : Double
  /// the moment it last set out (the frames' clock, ms)
  mut set_at : Double
  /// what it is, as Tester::moving says it (`bar/o`: the panel, `bar/k`: the notch, `bar/held`: the ball held, the
  /// ball's `bar/ball-x`, `bar/ball-y`), beside the bar's glides (`bar/vis`)
  what : String
}

///|
fn spr(start : Double, tension : Double, friction : Double, what : String, rest? : Double = 0.001) -> Spr {
  { path: None, ride: None, x: start, v: 0.0, to: start, tension, friction, rest, what, set_at: 0.0 }
}

///|
/// Where it is at `t` and how fast, by the way it is on (a ride, its spring's; none told: where it was put).
fn Spr::at(self : Spr, t : Double) -> (Double, Double) {
  match (self.ride, self.path) {
    (Some(r), _) => r.at(t)
    (None, Some(p)) => p.at(t)
    (None, None) => (self.x, self.v)
  }
}

///|
/// Sent to `to` by `tension` and `friction` from the moment `at` (its cause's; none: now), from where it is then, as
/// fast as it goes; nothing new when it goes there so already (told the same again, by any build, whenever).
fn Spr::go(self : Spr, to : Double, tension : Double, friction : Double, at~ : Double) -> Unit {
  let same = tension == self.tension && friction == self.friction
  // riding: where it rides to by the ride's spring is nothing new; anything else sets out from where the ride has it
  match self.ride {
    Some(r) if same && r.to == to => return
    _ => ()
  }
  match self.path {
    Some(p) if self.ride is None && same && p.target() == to => return
    _ => ()
  }
  let now = at
  let rode = match self.ride {
    Some(r) => {
      self.ride = None
      Some(r.at(now))
    }
    None => None
  }
  let (x, v) = match (rode, self.path) {
    (Some(xv), _) => xv
    (None, Some(p)) => p.at(now)
    (None, None) => (self.x, self.v)
  }
  let p = match self.path {
    Some(p) if same && rode is None => p
    old => {
      // (a spring of another stiffness from here: the old one's way is over)
      match old {
        Some(o) => o.put(x)
        None => ()
      }
      let p = @ui.SpringPath::new(x, k=tension, c=friction, rest=self.rest)
      self.path = Some(p)
      p
    }
  }
  p.go(now, to, v~, what=self.what)
  self.set_at = now
  // (where its new way has it then, as what reads it at that moment has it: the same to the last bit)
  let (x, v) = p.at(now)
  self.x = x
  self.v = v
  self.to = to
  self.tension = tension
  self.friction = friction
}

///|
/// When it is at rest (the frames' clock, ms; before now, or -1: it is).
fn Spr::end(self : Spr) -> Double {
  match (self.ride, self.path) {
    (Some(r), _) => r.end
    (None, Some(p)) => p.end()
    (None, None) => -1.0
  }
}

///|
/// Where it is at `t` (ms, the frames' clock), by the way it is on (Spr::at): for what rides on it (Ride), and for
/// where it is at the moment a cause tells it anew.
fn Spr::value_at(self : Spr, t : Double) -> Double {
  self.at(t).0
}

///|
/// There at once, at rest.
fn Spr::put(self : Spr, x : Double) -> Unit {
  self.ride = None
  match self.path {
    Some(p) => p.put(x)
    None => ()
  }
  self.x = x
  self.v = 0.0
  self.to = x
}

///|
/// As at the start.
fn Spr::back(self : Spr, x : Double, tension : Double, friction : Double) -> Unit {
  self.path = None
  self.ride = None
  self.x = x
  self.v = 0.0
  self.to = x
  self.tension = tension
  self.friction = friction
}

///|
/// A spring riding something that moves by itself (Bar.kt ride: the ball on a bar chosen as it comes down, sent each
/// frame to where its place is then), its way worked out once as it sets out, from the ways of what it rides on (the
/// panel's and the notch's springs, known to their end): sent at each step of `ride_step_ms` to where that is then, at
/// rest at `to` from `end` on. So it is the same however often frames come, and its end is said as it sets out, not
/// anew each frame.
priv struct Ride {
  /// each leg: when it starts, from where and how fast, and towards what
  legs : Array[(Double, Double, Double, Double)]
  /// the spring: stiffness, damping ratio
  k : Double
  ratio : Double
  to : Double
  end : Double
  /// what it was worked out from (RideFrom::same)
  from : RideFrom
}

///|
/// What a ride rides on, as it set out: the bar chosen and its place, the window, and the ways of the springs it rides
/// on (where they go, when they are at rest).
priv struct RideFrom {
  swap : Swap
  j : Int
  w : Double
  row_top : Double
  o_to : Double
  o_end : Double
  k_to : Double
  k_end : Double
  up_to : Double
  up_end : Double
}

///|
/// The step a ride is sent at (a frame's, at 60 a second: as the ball was sent each frame).
let ride_step_ms : Double = 16.0

///|
/// The longest a ride is worked out over, step by step (Ride::new): the ball's springs rest in well under a second.
let ride_most_ms : Double = 10000.0

///|
/// A ride from `x` (at `v` a second) at `t0`, by stiffness `k` and damping `c`, after `anchor` (where it is sent at a
/// time) until `still` (when what it rides on is at rest; after it, where it is sent stays), at rest within `rest`.
fn Ride::new(
  x : Double,
  v : Double,
  t0 : Double,
  k : Double,
  c : Double,
  rest : Double,
  anchor : (Double) -> Double,
  still : Double,
  from : RideFrom,
) -> Ride {
  let ratio = c / (2.0 * k.sqrt())
  let legs = []
  let mut t = t0
  let mut x = x
  let mut v = v
  let mut to = anchor(t0)
  legs.push((t, x, v, to))
  // set out long before what it rides on comes to rest (a change caught up at its own moment, long after: the iPhone's
  // clock is the time since it started, so days of 16 ms legs, gigabytes and a hang): long since at rest where it was
  // sent then, it rides only the last of that way, on the steps it would have taken from `t0` (so it is sent elsewhere
  // at the step it would have been)
  let late = t0 +
    ((still - ride_most_ms - t0) / ride_step_ms).floor() * ride_step_ms
  if late > t {
    t = late
    to = anchor(t)
    x = to
    v = 0.0
    legs.push((t, x, v, to))
  }
  while t < still {
    let next = t + ride_step_ms
    let (d, vel) = @motion.spring_at(ratio, k, x - to, v, (next - t) / 1000.0)
    x = to + d
    v = vel
    t = next
    to = anchor(dmin(t, still))
    legs.push((t, x, v, to))
  }
  let end = t + @motion.spring_duration(ratio, k, x - to, v, rest)
  { legs, k, ratio, to, end, from }
}

///|
/// Where it is at `t`, and how fast it goes (a second).
fn Ride::at(self : Ride, t : Double) -> (Double, Double) {
  if t >= self.end {
    return (self.to, 0.0)
  }
  // the leg it is on: the last one started by `t`
  let mut i = self.legs.length() - 1
  while i > 0 && self.legs[i].0 > t {
    i = i - 1
  }
  let (t0, x0, v0, to) = self.legs[i]
  let (d, v) = @motion.spring_at(self.ratio, self.k, x0 - to, v0, dmax(0.0, t - t0) / 1000.0)
  (to + d, v)
}

///|
/// Whether a ride worked out from `a` rides on what `b` says now.
fn RideFrom::same(a : RideFrom, b : RideFrom) -> Bool {
  physical_equal(a.swap, b.swap) &&
  a.j == b.j &&
  a.w == b.w &&
  a.row_top == b.row_top &&
  a.o_to == b.o_to &&
  a.o_end == b.o_end &&
  a.k_to == b.k_to &&
  a.k_end == b.k_end &&
  a.up_to == b.up_to &&
  a.up_end == b.up_end
}

///|
/// `self` set riding by `anchor` until `still` (Ride::new), from where it is now, unless it rides so already; said once
// as it sets out.
fn Spr::ride_on(
  self : Spr,
  tension : Double,
  anchor : (Double) -> Double,
  still : Double,
  from : RideFrom,
  at~ : Double,
) -> Unit {
  match self.ride {
    Some(r) if r.from.same(from) && r.k == tension => return
    _ => ()
  }
  let now = at
  let (x, v) = match (self.ride, self.path) {
    (Some(r), _) => r.at(now)
    (None, Some(p)) => p.at(now)
    (None, None) => (self.x, self.v)
  }
  // (its own spring's way is over: it rides from here)
  match self.path {
    Some(p) => p.put(x)
    None => ()
  }
  let friction = ball_damping(tension)
  let r = Ride::new(x, v, now, tension, friction, self.rest, anchor, dmax(now, still), from)
  self.ride = Some(r)
  self.set_at = now
  // (where the ride has it then, as what reads it at that moment has it)
  let (x, v) = r.at(now)
  self.x = x
  self.v = v
  self.to = r.to
  self.tension = tension
  self.friction = friction
}

///|
/// One number gliding to where it is sent over a time on a curve, its way said once as it sets out (where
/// from, how fast, where to, by what, when): where it is at a moment a function of that moment alone (Glide::at).
/// `target`: where it goes.
priv struct Glide {
  mut target : Double
  mut from : Double
  mut v0 : Double
  mut spec : @motion.Spec
  /// when it set out, and how long it goes (the frames' clock, ms)
  mut start : Double
  mut dur : Double
}

///|
fn glide(start : Double) -> Glide {
  { target: start, from: start, v0: 0.0, spec: @motion.Snap(0.0), start: 0.0, dur: 0.0 }
}

///|
/// Where it is at `t` and how fast (per second), by its way.
fn Glide::at(self : Glide, t : Double) -> (Double, Double) {
  if t >= self.start + self.dur {
    (self.target, 0.0)
  } else {
    self.spec.value_at(t - self.start, self.dur, self.from, self.target, self.v0)
  }
}

///|
/// When it is there (the frames' clock, ms).
fn Glide::end(self : Glide) -> Double {
  self.start + self.dur
}

///|
/// Sent to `target` over `ms` on `ease`, from the moment `at` (none: now); nothing new when it is going there.
fn Glide::go(self : Glide, target : Double, ms : Double, ease : @ui.Ease, at~ : Double) -> Unit {
  self.go_by(target, @motion.tween(ms, ease~), at~)
}

///|
/// Sent to `target` by `spec` from the moment `at` (its cause's; none: now), from where it is then and as fast; nothing
/// new when it is going there already (a build told the same again, whenever).
fn Glide::go_by(self : Glide, target : Double, spec : @motion.Spec, at~ : Double) -> Unit {
  if target == self.target {
    return
  }
  let (x, v) = self.at(at)
  // (turned back on its way: a tween sets out still, its speed dropped at once, a step each frame drew; it goes on
  // instead as a Move as long as the tween is, from where it is and as fast, slowing to rest and setting back out)
  let spec = match spec {
    Tween(len, _, _) if v != 0.0 => {
      let over = dmax(0.0, (len - 200.0) / 7.5)
      @motion.moved(over=over * over)
    }
    s => s
  }
  self.from = x
  self.v0 = v
  self.target = target
  self.spec = spec
  self.start = at
  self.dur = spec.duration(x, target, v)
}

///|
/// There at once, still.
fn Glide::snap(self : Glide, v : Double) -> Unit {
  self.target = v
  self.from = v
  self.v0 = 0.0
  self.dur = 0.0
}

///|
/// A bar chosen in the panel, sliding down into the bar's place: which (`i`), its row in the panel
/// (`n`), how open the panel was (`from`), the place tapped in it; the bars as they were (`sets`, `cur`), which the
/// stack sliding down is laid out by; the rows' fade and offset then and how lit each place was, which it starts
/// from.
priv struct Swap {
  i : Int
  n : Int
  from : Double
  key : String?
  sets : Array[Array[String]]
  cur : Int
  alpha : Double
  drop : Double
  lit : Map[String, Double]
  /// when it has landed (the frames' clock, ms): its panel's spring's rest as it was sent closed for it, said then
  ends : Double
}

///|
/// How far a bar chosen has come down: 0 as the panel was, 1 landed.
fn Swap::t(self : Swap, o : Double) -> Double {
  dclamp(1.0 - o / self.from, 0.0, 1.0)
}

///|
/// The rows' look as the panel opens (rowsShift): they come in over 0.35 to 1, a little low, then up
/// with its overshoot.
fn rows_alpha(o : Double) -> Double {
  dclamp((o - 0.35) / 0.65, 0.0, 1.0)
}

///|
fn rows_shift(o : Double, reach : Double) -> Double {
  (1.0 - dmin(1.0, o)) * 14.0 - dmax(0.0, o - 1.0) * reach
}

///|
/// The chosen bar's places' middles and their height (in the panel's frame) as it comes down: from
/// its row in the panel to exactly where the bar's places are drawn as the notch is (`k_now`).
fn swap_at(s : Swap, o : Double, w : Double, k_now : Double, row_top : Double) -> (Array[Double], Double) {
  let into = s.sets[s.i]
  let t = s.t(o)
  let from = bar_centres(w, 0.0, into.length())
  let row_mid = over + s.n.to_double() * bar_row + bar_row / 2.0
  let bar_mid = row_top + bar_track / 2.0
  if t <= 0.0 {
    return (from, row_mid)
  }
  let to = bar_centres(w, k_now, into.length())
  if t >= 1.0 {
    return (to, bar_mid)
  }
  (from.mapi(fn(j, x) { x + (to[j] - x) * t }), row_mid + (bar_mid - row_mid) * t)
}

///|
/// What the bar keeps between frames (BallMotion).
priv struct BarModel {
  /// the panel of the other bars open (or opening, or the finger's)
  mode : @signals.Signal[Bool]
  /// how open the panel is (0 the bar, 1 the panel); the notch (1 open); the ball held
  o : Spr
  k : Spr
  held : Spr
  /// drawn up out from under a finger that has the bar (1), back as it lets go (bar_raise)
  up : Spr
  /// the bar shown, the ball shown and its size
  vis : Glide
  ball_alpha : Glide
  ball_scale : Glide
  /// each place drawn ("bar:<place>", "row:<place>"): how lit
  tints : Map[String, Glide]
  /// the ball: where across (stiff as the way is short) and down, on springs damped as the web's (ZETA 0.635)
  ball_x : Spr
  ball_y : Spr
  /// how far the ball went to the place shown last (its spring as stiff as the way is short)
  mut trip : Double
  mut active_was : String
  /// a finger: where it has the ball (-1 none), its height once the panel is its own
  mut drag : Double
  mut drag_y : Double
  mut holds : Bool
  mut from_open : Bool
  mut open : Bool
  mut y0 : Double
  mut o0 : Double
  /// first drawn: everything where it goes at once
  mut placed : Bool
  mut width : Double
  /// a bar chosen sliding down into the bar's place; a finger that went down meanwhile (the finger's once it lands)
  mut swap : Swap?
  mut waits : Bool
  /// the place last felt under a finger ("<bar>/<place>"): another one under it is felt as it gets there
  mut felt : String
  /// the notch's icon going as another swaps in ("" none), how far the swap is (0 to 1)
  mut icon_was : String
  icon_swap : Glide
  /// capillary liquid bridge merge radius & elastic recoil between capsule and `＋` action circle
  bond_merge : @motion.Way
  bond_recoil : @motion.Way
  mut bond_bonded : Bool
  /// what it was last told by the app's state (bar_tell, at its cause's moment): told the same again, nothing new
  mut told : BarTold?
}

///|
/// The ball's springs: down and up 300; across as stiff as it is told; damped as the web's (ZETA 0.635).
let ball_down : Double = 300.0

///|
/// The bar drawn up (bar_raise): its spring as stiff as the ball's going down, critically damped (it goes up and
/// comes back without overshooting past where the bar rests).
let raise_damping : Double = 2.0 * ball_down.sqrt()

///|
fn ball_damping(tension : Double) -> Double {
  2.0 * 0.635 * tension.sqrt()
}

///|
/// The ball at rest within this (points).
let ball_rest_within : Double = 0.01

///|
let bar : BarModel = {
  mode: @signals.signal(false, same=fn(a, b) { a == b }),
  o: spr(0.0, 260.0, 17.0, "bar/o"),
  k: spr(1.0, 300.0, 30.0, "bar/k"),
  held: spr(0.0, 420.0, 16.0, "bar/held"),
  up: spr(0.0, ball_down, raise_damping, "bar/up"),
  vis: glide(0.0),
  ball_alpha: glide(1.0),
  ball_scale: glide(1.0),
  tints: {},
  ball_x: spr(0.0, 300.0, ball_damping(300.0), "bar/ball-x", rest=ball_rest_within),
  ball_y: spr(0.0, ball_down, ball_damping(ball_down), "bar/ball-y", rest=ball_rest_within),
  trip: slot_px,
  active_was: "",
  drag: -1.0,
  drag_y: -1.0,
  holds: false,
  from_open: false,
  open: false,
  y0: 0.0,
  o0: 0.0,
  placed: false,
  width: 0.0,
  swap: None,
  waits: false,
  felt: "",
  icon_was: "",
  bond_merge: @motion.Way::new(0.0),
  bond_recoil: @motion.Way::new(0.0),
  bond_bonded: false,
  told: None,
  icon_swap: glide(1.0),
}

///|
/// As at the start (tests).
fn bar_reset() -> Unit {
  let back_glide = fn(g : Glide, to : Double) {
    g.snap(to)
    g.start = 0.0
  }
  bar.mode.set(false)
  bar.o.back(0.0, 260.0, 17.0)
  bar.k.back(1.0, 300.0, 30.0)
  bar.held.back(0.0, 420.0, 16.0)
  bar.up.back(0.0, ball_down, raise_damping)
  back_glide(bar.vis, 0.0)
  back_glide(bar.ball_alpha, 1.0)
  back_glide(bar.ball_scale, 1.0)
  bar.tints.clear()
  bar.ball_x.back(0.0, 300.0, ball_damping(300.0))
  bar.ball_y.back(0.0, ball_down, ball_damping(ball_down))
  bar.trip = slot_px
  bar.active_was = ""
  bar.drag = -1.0
  bar.drag_y = -1.0
  bar.holds = false
  bar.from_open = false
  bar.open = false
  bar.y0 = 0.0
  bar.o0 = 0.0
  bar.placed = false
  bar.width = 0.0
  bar.swap = None
  bar.waits = false
  bar.felt = ""
  bar.icon_was = ""
  back_glide(bar.icon_swap, 1.0)
  bar.bond_merge.put(0.0)
  bar.bond_recoil.put(0.0)
  bar.bond_bonded = false
  m_face.val = ""
  bar.told = None
  bar_told_now.set(None)
  bar_laid_told.set(bar_laid_none())
  for i in 0..<bar_parts_told.length() {
    bar_parts_told[i] = ""
  }
  bar_said_again()
}

///|
/// The panel opened or closed from the moment `at` (its cause's; none: now).
fn BarModel::open_panel(self : BarModel, open : Bool, at~ : Double) -> Unit {
  let prev_k_end = self.k_end()
  self.mode.set(open)
  if open {
    self.o.go(1.0, 260.0, 17.0, at~)
  } else {
    self.o.go(0.0, 320.0, 26.0, at~)
  }
  self.schedule_bond(prev_k_end, at~)
}

///|
/// When all of the bar is at rest (the frames' clock, ms; before now: it is), as its springs and glides said as they
/// set out. Only for a test's end, before its assert_idle (idle is after all it said has ended); never a point a test
/// waits for midway: there a test asks the end of the one path it looks at, not of the whole bar.
fn BarModel::rest(self : BarModel) -> Double {
  let mut e = -1.0
  for s in [self.o, self.k, self.held, self.up, self.ball_x, self.ball_y] {
    e = dmax(e, s.end())
  }
  let gs = [self.vis, self.ball_alpha, self.ball_scale, self.icon_swap]
  for _, g in self.tints {
    gs.push(g)
  }
  for g in gs {
    e = dmax(e, g.end())
  }
  e = dmax(e, dmax(self.bond_merge.ends_at(), self.bond_recoil.ends_at()))
  e
}

///|
/// When the bottom bar is at rest (BarModel::rest): for a test of the app over its pages (src/sfreplay), as for this
/// package's own, only at a test's end or where a page is pushed, never a point waited for midway.
pub fn bar_rest() -> Double {
  bar.rest()
}

///|
/// When the bar chosen in the panel has landed (the frames' clock, ms): the end of the panel's own spring as it closes
/// under it, the last one chosen's once it has (its end as it was given, whichever frames were drawn on its way); -1
/// when none was ever chosen. Until then a finger does not take the panel (a bar landing lands untouched): what a test
/// runs to before it draws the panel up again.
pub fn bar_landed() -> Double {
  match bar.swap {
    Some(s) => s.ends
    None => -1.0
  }
}

///|
/// Everything where it is going, at once (the first frame; reduced motion).
fn BarModel::jump(self : BarModel) -> Unit {
  for s in [self.o, self.k, self.held, self.up, self.ball_x, self.ball_y] {
    s.put(s.to)
  }
  for g in [self.vis, self.ball_alpha, self.ball_scale, self.icon_swap] {
    g.snap(g.target)
  }
  for _, g in self.tints {
    g.snap(g.target)
  }
  self.bond_merge.put(self.bond_merge.target())
  self.bond_recoil.put(0.0)
  self.swap = None
}

///|
/// Capillary liquid bridge parameters between the bottom bar capsule and the `＋` action circle.
let bar_bond_merge_max : Double = 18.0

///|
let bar_bond_break_gap : Double = 6.5

///|
/// Schedules the closed-form capillary liquid bridge (`bond_merge` & `bond_recoil`) whenever the effective notch target
/// `k_end()` flips between closed (0) and open (1), or when an emerging bonded droplet finishes separating past
/// `break_gap` (e.g. panel drag-down releasing to `o = 0`), whether driven by tab change or panel open/close.
fn BarModel::schedule_bond(self : BarModel, prev_k_end : Double, at~ : Double) -> Unit {
  let next_k_end = self.k_end()
  let end = dmax(at, dmax(self.k.end(), self.o.end()))
  let gap_at = fn(t : Double) { (act_size + act_gap) * self.k_at(t) - act_size }
  if next_k_end > 0.5 {
    if prev_k_end > 0.5 && !self.bond_bonded {
      return
    }
    // Opening: ＋ emerges from capsule right end -> stays bonded until gap >= break_gap -> critically damped snap to 0
    match @motion.liquid_bond_cross_time(at, end, gap_at, true, bar_bond_break_gap) {
      Some(ts) => {
        let delay = dmax(0.0, ts - at)
        self.bond_bonded = false
        self.bond_merge.put(bar_bond_merge_max)
        self.bond_merge.go(0.0, @motion.liquid_split_spring.delayed(delay), at~)
        self.bond_recoil.put(0.0)
        self.bond_recoil.go(0.0, @motion.liquid_recoil_spring.delayed(delay), at~, velocity=-4.5)
      }
      None => {
        // Still emerging inside break_gap (e.g. mid-drag): stay bonded until a subsequent spring leg crosses break_gap
        self.bond_bonded = true
        self.bond_merge.put(bar_bond_merge_max)
      }
    }
  } else {
    if prev_k_end <= 0.5 {
      return
    }
    // Closing: ＋ approaches with zero magnetic attraction while gap > 0 -> blooms on physical contact (gap <= 0)
    match @motion.liquid_bond_cross_time(at, end, gap_at, false, 0.0) {
      Some(tt) => {
        let delay = dmax(0.0, tt - at)
        self.bond_bonded = true
        self.bond_merge.put(0.0)
        self.bond_merge.go(bar_bond_merge_max, @motion.liquid_merge_spring.delayed(delay), at~)
        self.bond_recoil.put(0.0)
        self.bond_recoil.go(0.0, @motion.liquid_recoil_spring.delayed(delay), at~, velocity=4.0)
      }
      None => {
        self.bond_bonded = false
        self.bond_merge.put(0.0)
      }
    }
  }
}

///|
/// Capillary liquid bridge merge radius between the capsule and `＋` circle at moment `t` (ms).
fn bar_merge_at(t : Double) -> Double {
  if bar.k_at(t) <= 0.002 {
    return 0.0
  }
  let m = bar.bond_merge.value_at(t)
  if !bar.bond_bonded && m < 0.05 {
    0.0
  } else {
    dmax(0.0, m)
  }
}

// ── what the bar is told ───────────────────────────────────────────────

///|
/// The notch's action's icon, as last shown (kept as it closes): bar_action_icon's.
let m_face : Ref[String] = { val: "" }

///|
/// The icon the notch draws for `action` (bar_action's; "" none): 令's action, a new chat, drawn as a ＋ as the others'
/// are (令's own glyph read as no shape anyone knew).
fn bar_action_icon(action : String) -> String {
  if action == "ling" {
    "plus"
  } else {
    action
  }
}

///|
/// A place's name (the bar's words for what a screen reader says, the place's page's title).
fn place_label(place : String) -> String {
  tr("android-misc.bar.place." + place)
}

///|
/// The place a page is the top of (none: it is not a place's).
pub fn place_of(page : Page) -> String? {
  match page {
    Home => Some("chats")
    Files => Some("files")
    Place(p) => Some(p)
    _ => None
  }
}

// ── drawing ────────────────────────────────────────────────────────────

///|
/// How long a place takes to light up or go dim.
let tint_ms : Double = 300.0

///|
/// The page's primary action in the notch where it is the settings' (Station's ＋ adds a station,
/// Profile's a profile, 连接's a connect: what the settings' page of the place says).
fn bar_place_add(src : Source, ws : Workspace, active : String?) -> ((@sf.Beside) -> Unit)? {
  match active {
    Some("connects") => {
      let core = settings_core(src, ws)
      match @sfpages.connects_add(src, core, @settings.here_of(core, ws.id, ws.name)) {
        Some(run) => Some(run)
        None => None
      }
    }
    // (远程: none, each station's heading has its own ＋, sfpages' remote_station_head_node)
    Some("remote") => None
    Some(a) => @settings.place_action(settings_core(src, ws), @settings.here_of(settings_core(src, ws), ws.id, ws.name), a)
    None => None
  }
}

///|
/// The notch's action's icon ("" none: the notch closed): 令 on the chats' pages, 文件's ＋ while it can lend a folder
/// , the settings' ＋ where the place's page has one (`place_add`), none on the others yet.
fn bar_action(src : Source, ws : Workspace, active : String?, place_add : ((@sf.Beside) -> Unit)?) -> String {
  match active {
    Some(a) if chat_family.contains(a) => "ling"
    Some("files") if files_can_lend(src, ws) => "plus"
    _ if place_add is Some(_) => "plus"
    _ => ""
  }
}

///|
/// The notch's key as the bar was last made (bar_node's action disc): what its action opens is opened beside it.
// kept across runs: said again as the bar is made; one of a tree let go is no node of the tree that is now
let bar_action_anchor : Ref[@view.View?] = Ref(None)

///|
/// The notch's action, pressed at `t` (its key a node of the window's tree's: bar_glass_node): 令 a new chat, ＋ what
/// the place's page adds (the files lent where it is 文件's); only with the notch open by then.
fn bar_action_run(src : Source, ws : Workspace, t : Double) -> Unit {
  let told = match bar.told {
    Some(told) => told
    None => return
  }
  if !told.shown || bar.drag >= 0.0 || bar.holds || bar.k_at(t) <= 0.9 {
    return
  }
  match told.action {
    "ling" => new_chat()
    "plus" =>
      match bar_place_add(src, ws, told.active) {
        Some(run) =>
          match bar_action_anchor.val {
            Some(n) => run(Node(n))
            None => ()
          }
        None => files_lend(src, ws)
      }
    _ => ()
  }
}

///|
/// What the bar was last told (bar_tell's), followed: where its glass is laid out and whether it takes a finger
/// (bar_glass_node's bindings) as that changes.
let bar_told_now : @signals.Signal[BarTold?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// What the bar is told by the app's state and the window: whether it shows, the notch's action ("" none: closed), the
/// place shown, the bars (`cur` the one shown, the others the panel's rows), how wide it is laid out (0: not known
/// yet). Compared whole: told the same again, nothing new.
#derive(Eq)
priv struct BarTold {
  shown : Bool
  action : String
  active : String?
  sets : Array[Array[String]]
  cur : Int
  width : Double
}

///|
/// What the bar is told in workspace `ws` with `active` the place on top, `shown` whether it shows (narrow_shell's
/// narrow_bar_shown), in a window `window` wide.
fn bar_told(src : Source, ws : Workspace, active : String?, shown : Bool, window : Double) -> BarTold {
  let (sets, cur) = bars_in(src, ws.id)
  {
    shown,
    action: bar_action(src, ws, active, bar_place_add(src, ws, active)),
    active,
    sets,
    cur,
    width: if window > 0.0 { window - 44.0 } else { 0.0 },
  }
}

///|
/// The top of the bar's track in its panel, with `bars` bars (the others the panel's rows, one at least).
fn bar_row_top(bars : Int) -> Double {
  let rows = if bars - 1 > 1 { bars - 1 } else { 1 }
  rows.to_double() * bar_row + over
}

///|
/// The bar told `told` at the moment `at` of what changed it (a page put on the stack or taken off, a place come in,
/// what the notch offers, the bars' order, the window), whatever frames are drawn after: its ways set out from then,
/// from where they are then; told the same again, nothing. A frame only reads where they are (bar_node.mbt).
/// (What a finger does on it is told so too, at each event's moment: bar_finger_at.)
fn bar_tell(told : BarTold, at : Double) -> Unit {
  let m = bar
  if m.told == Some(told) {
    return
  }
  m.told = Some(told)
  bar_told_now.set(Some(told))
  bar_laid_told.set(bar_laid(told))
  let shown = told.shown
  let notched = told.action != ""
  // shown or not
  let p_now = if shown && app.nav.root_shows() { app.nav.root_progress(fn() { at }) } else { 0.0 }
  if shown && m.vis.target < 0.5 && m.vis.at(at).0 <= 0.01 && p_now > 0.01 && p_now < 0.99 {
    // Handing off from a swipe-back gesture (the bar gone all the way down): on smoothly from its live progress
    m.vis.snap(p_now)
    m.vis.go_by(1.0, @motion.moved(points=bar_drop * (1.0 - p_now)), at~)
  } else {
    m.vis.go_by(
      if shown { 1.0 } else { 0.0 },
      if shown {
        @motion.moved(points=bar_drop)
      } else {
        @motion.tween(bar_hide_ms, ease=Leave)
      },
      at~,
    )
  }
  // going: the panel closed, a finger's slide let go
  if !shown {
    if m.mode.get() {
      m.mode.set(false)
      m.o.go(0.0, 320.0, 26.0, at~)
    }
    m.drag = -1.0
    m.drag_y = -1.0
    m.holds = false
  }
  // the notch's icon: another swaps in as the notch stays open (a short scale and fade); closed or none shown, at once.
  // By the icon drawn, not the action: 令 and ＋ draw the same ＋, which stays still as one gives way to the other.
  let face = bar_action_icon(told.action)
  if face != "" && face != m_face.val {
    let k_then = m.k_at(at)
    if m_face.val == "" || k_then <= 0.001 {
      m_face.val = face
      m.icon_was = ""
      m.icon_swap.snap(1.0)
    } else {
      m.icon_was = m_face.val
      m_face.val = face
      m.icon_swap.snap(0.0)
      m.icon_swap.go(1.0, icon_swap_ms, Linear, at~)
    }
  }
  // the notch as the place has it
  let prev_k_end = m.k_end()
  m.k.go(if notched { 1.0 } else { 0.0 }, 300.0, 30.0, at~)
  m.schedule_bond(prev_k_end, at~)
  let items = told.sets[told.cur]
  // the ball: to the place shown, from where it is then, as stiff as the way there is short (a new place's); riding
  // a bar chosen as it lands; a new width, there at once. Not while a finger has it, nor before the width is known.
  let ai = match told.active {
    Some(a) => items.search(a).unwrap_or(-1)
    None => -1
  }
  let active_key = told.active.unwrap_or("")
  let w = told.width
  let row_top = bar_row_top(told.sets.length())
  let sliding = m.drag >= 0.0
  // The bar rises and the notch closes together while a finger has it, returning together on release.
  m.held.go(if sliding { 1.0 } else { 0.0 }, 1000.0, 2.0 * 1000.0.sqrt(), at~)
  m.up.go(if m.holds || sliding { 1.0 } else { 0.0 }, ball_down, raise_damping, at~)
  if w > 0.0 {
    match m.swap_at(at) {
      // a bar chosen landing: the ball rides the place tapped with it or as it lands (bar_finger_at's on_tab), else
      // the place shown where the bar has it; nothing tells it again once it has landed, so where it rides it stays
      Some(s) =>
        match s.sets[s.i].search(s.key.unwrap_or(active_key)) {
          Some(j) => m.ride(s, j, w, row_top, at)
          None => ()
        }
      None => {
        let final_cs = bar_centres(w, m.k_end(), items.length())
        let now_cs = bar_centres(w, m.k_at(at), items.length())
        let (goal_x, goal_y) = match bar_finger(told, now_cs, m.drag, m.drag_y) {
          Some((cx, cy, set, key)) => {
            // Keep the selected ball with the same place as the notch and its places move.
            let target_x = if set == told.cur { final_cs[items.search(key).unwrap_or(0)] } else { cx }
            (target_x + (m.drag - target_x) * lean, cy + ((if m.drag_y >= 0.0 { m.drag_y } else { row_top + bar_track / 2.0 }) - cy) * lean)
          }
          None => (final_cs[if ai < 0 { 0 } else { ai }], row_top + bar_track / 2.0)
        }
        if !sliding && active_key != m.active_was {
          m.active_was = active_key
          m.trip = dmax(8.0, (goal_x - m.ball_x.value_at(at)).abs())
          // (told anew on its way, a way no stiffer than the one it is on: its speed, which its stretch draws, taken off
          // by a spring stiffer than the one that gave it is gone in a frame, the stretch and the ball's height with it, at
          // 60 a second a step of 3.6 points then 0.2 (a place switched back within its way, bar_places_kept); one as
          // stiff turns it back at the rate it went)
          if m.ball_x.end() > at {
            m.trip = dmax(m.trip, 300.0 * slot_px / m.ball_x.tension)
          }
        }
        let tension = if sliding { 300.0 } else { dclamp(300.0 * slot_px / m.trip, 90.0, 700.0) }
        if m.placed && m.width != w {
          m.ball_x.put(goal_x)
        } else {
          m.ball_x.go(goal_x, tension, ball_damping(tension), at~)
        }
        m.ball_y.go(goal_y, ball_down, ball_damping(ball_down), at~)
      }
    }
    m.width = w
  }
  // each place lit as it is the one under the finger, else the one shown, in the bar and in the panel's rows (300 ms,
  // CSS's ease); one come anew as it is; a bar chosen landing, its places as they will be as it lands
  let finger = if w > 0.0 {
    bar_finger(told, bar_centres(w, m.k_at(at), items.length()), m.drag, m.drag_y)
  } else {
    None
  }
  let landing = m.swap_at(at) is Some(_)
  for i, set in told.sets {
    for key in set {
      let id = (if i == told.cur { "bar:" } else { "row:" }) + key
      let lit = match finger {
        Some((_, _, fi, fk)) => fi == i && fk == key
        None => told.active == Some(key)
      }
      let on = if lit { 1.0 } else { 0.0 }
      match m.tints.get(id) {
        Some(g) => if landing && i == told.cur { g.snap(on) } else { g.go(on, tint_ms, Out, at~) }
        None => m.tints[id] = glide(on)
      }
    }
  }
  // the ball shown where a place of the bar is
  let ball_shown = ai >= 0 ||
    m.drag >= 0.0 ||
    (match m.swap_at(at) {
      Some({ key: Some(_), .. }) => true
      _ => false
    })
  m.ball_alpha.go(if ball_shown { 1.0 } else { 0.0 }, ball_fade_ms, Out, at~)
  m.ball_scale.go(if ball_shown { 1.0 } else { 0.6 }, ball_grow_ms, Out, at~)
  // first laid out (its width known), or under reduced motion: everything where it goes, at once
  if w > 0.0 && (!m.placed || @ui.reduced_motion()) {
    m.placed = true
    m.jump()
  }
  // (what reads its ways read again: bar_node)
  bar_said_again()
}

///|
/// The bar told again what it was told last, at the moment `at` of what the finger did on it (bar_finger_at), what goes
/// by where the finger has it set out from then.
fn bar_retell(at : Double) -> Unit {
  match bar.told {
    Some(t) => {
      bar.told = None
      bar_tell(t, at)
    }
    None => ()
  }
}

///|
/// The finger's place on the bar (`drag` across, `drag_y` down once the panel is its own; -1 none), and the place a
/// let-go would choose: where it is, its bar and its key. The bar's places at `final_cs`.
fn bar_finger(
  told : BarTold,
  final_cs : Array[Double],
  drag : Double,
  drag_y : Double,
) -> (Double, Double, Int, String)? {
  if drag < 0.0 {
    return None
  }
  let sets = told.sets
  let items = sets[told.cur]
  let others : Array[Int] = []
  for i in 0..<sets.length() {
    if i != told.cur {
      others.push(i)
    }
  }
  let row_top = bar_row_top(sets.length())
  if drag_y >= 0.0 && drag_y < row_top - 4.0 && others.length() > 0 {
    let n = dclamp(((drag_y - over) / bar_row).floor(), 0.0, (others.length() - 1).to_double()).to_int()
    let set = sets[others[n]]
    let cs = bar_centres(told.width, 0.0, set.length())
    let j = nearest(cs, set.length(), drag)
    Some((cs[j], over + n.to_double() * bar_row + bar_row / 2.0, others[n], set[j]))
  } else if items.length() > 0 {
    let j = imin(items.length() - 1, nearest(final_cs, 4, drag))
    Some((final_cs[j], row_top + bar_track / 2.0, told.cur, items[j]))
  } else {
    None
  }
}

///|
/// The ball riding place `j` of bar chosen `s` as it lands, the bar `w` wide, its track's top `row_top`:
/// where its place is at a time, by the panel's and the notch's ways (as swap_at has it each frame), ridden after on the
/// ball's springs, worked out once as it sets out at `at` (Ride), again only when those ways change.
fn BarModel::ride(self : BarModel, s : Swap, j : Int, w : Double, row_top : Double, at : Double) -> Unit {
  let from = {
    swap: s,
    j,
    w,
    row_top,
    o_to: self.o.to,
    o_end: self.o.end(),
    k_to: self.k.to,
    k_end: self.k.end(),
    up_to: self.up.to,
    up_end: self.up.end(),
  }
  let still = dmax(self.up.end(), dmax(self.o.end(), self.k.end()))
  let o = self.o
  let k = self.k
  let place_at = fn(t : Double) {
    let ot = o.value_at(t)
    let kt = k.value_at(t) * (1.0 - dclamp(2.0 * ot, 0.0, 1.0))
    let (xs, y) = swap_at(s, ot, w, kt, row_top)
    (xs[j], y + s.drop * (1.0 - s.t(ot)))
  }
  self.ball_x.ride_on(300.0, fn(t) { place_at(t).0 }, still, from, at~)
  self.ball_y.ride_on(ball_down, fn(t) { place_at(t).1 }, still, from, at~)
}

///|
/// The bar chosen landing at `now` (none once it has landed, at the end it was given as it was chosen): a function of
/// the moment, whichever frames came, and of nothing told after it.
fn BarModel::swap_at(self : BarModel, now : Double) -> Swap? {
  match self.swap {
    Some(s) if now >= s.ends => None
    s => s
  }
}

///|
/// The bar's geometry as `told` has it (bar_tell's): the bars, the one shown and the others (the panel's rows), how
/// wide, the panel's height and its track's top, how far a finger draws the panel up.
#derive(Eq)
priv struct BarLaid {
  sets : Array[Array[String]]
  cur : Int
  items : Array[String]
  others : Array[Int]
  multi : Bool
  w : Double
  panel : Double
  row_top : Double
  reach : Double
}

///|
fn bar_laid(told : BarTold) -> BarLaid {
  let sets = told.sets
  let others : Array[Int] = []
  for i in 0..<sets.length() {
    if i != told.cur {
      others.push(i)
    }
  }
  let row_top = bar_row_top(sets.length())
  {
    sets,
    cur: told.cur,
    items: sets[told.cur],
    others,
    multi: sets.length() > 1,
    w: told.width,
    panel: row_top + bar_track,
    row_top,
    reach: row_top - over,
  }
}

///|
/// The top of the bar's glass in its panel with the panel `o` open (its rows' reach `reach` above the track): what is
/// drawn of it and where a finger is taken by it, the same.
fn bar_glass_top(reach : Double, o : Double) -> Double {
  dmax(0.0, over + reach * (1.0 - o))
}

///|
/// The notch as it is at `t`: as its place has it, closed with the panel (its rows across the whole bar). A finger on
/// the bar leaves it as it is, as Comma's bar keeps its circle: the places stay where the finger found them.
fn BarModel::k_at(self : BarModel, t : Double) -> Double {
  self.k.value_at(t) * (1.0 - dclamp(2.0 * self.o.value_at(t), 0.0, 1.0))
}

///|
/// Where the notch as drawn (BarModel::k_now) is going: where its spring and the panel are sent.
fn BarModel::k_end(self : BarModel) -> Double {
  self.k.to * (1.0 - dclamp(2.0 * self.o.to, 0.0, 1.0))
}

///|
/// The bar's glass held by a finger, as the window's tree hands it on (narrow_shell's node over the bar: View::gesture):
/// each event at its own moment (`d.at`), where the panel, the notch and the ball are then by their ways (never where a
/// frame last drew them), what it does told then (bar_retell). `src`, `ws`: the workspace in view. Where the bar is
/// laid out is what it was told (bar_tell: BarLaid), the same the bar is drawn by.
fn bar_finger_at(src : Source, ws : Workspace, d : @view.Drag, how : BarFingerIs) -> Unit {
  let m = bar
  let told = match m.told {
    Some(t) => t
    None => return
  }
  let l = bar_laid(told)
  let t = d.at
  let px = d.x
  let py = d.y
  let o_at = m.o.value_at(t)
  // another place chosen is felt, unless the finger already felt it getting there (a drag let go on it); the place shown
  // tapped again (`again`: a tap, not a slide let go on it), its list back to its top where it is away from it (the bar
  // shows only over a place's root: sfdesk's list_back_to_top)
  let on_tab = fn(place : String, again : Bool) {
    // a bar chosen landing: the ball rides this place as it lands (where it rides is where it stays: nothing tells it
    // again once it has landed)
    match m.swap_at(t) {
      Some(s) if s.key != Some(place) => m.swap = Some({ ..s, key: Some(place) })
      _ => ()
    }
    if Some(place) != told.active {
      let at = "\{l.cur}/\{place}"
      if at != m.felt {
        @ui.haptic(TextHandleMove)
        m.felt = at
      }
      go_place(t, place, l.sets, l.cur)
    } else if again {
      @sfdesk.list_back_to_top() |> ignore
    }
  }
  // another bar chosen (and a place in it, when one was tapped): it is the bar, and the place opens, now; the panel
  // closes like a window over a stack of bars, the chosen one sliding down into the bar's place
  let pick = fn(i : Int, key : String?) {
    if m.swap_at(t) is Some(_) {
      return
    }
    let n = match l.others.search(i) {
      Some(n) => n
      None => return
    }
    let lit : Map[String, Double] = Map([])
    for id, g in m.tints {
      lit[id] = g.at(t).0
    }
    let prev_k_end = m.k_end()
    m.mode.set(false)
    m.o.go(0.0, 200.0, 28.0, at=t)
    m.schedule_bond(prev_k_end, at=t)
    m.swap = Some({
      i,
      n,
      from: dmax(0.2, o_at),
      key,
      sets: l.sets,
      cur: l.cur,
      alpha: rows_alpha(o_at),
      drop: rows_shift(o_at, l.reach),
      lit,
      ends: m.o.end(),
    })
    set_bars(src, ws.id, l.sets, i)
    match key {
      Some(k) => go_place(t, k, l.sets, i)
      None => ()
    }
  }
  let ended = fn() {
    m.holds = false
    m.drag = -1.0
    m.drag_y = -1.0
  }
  // a tap on the bar's places where they are at `t` (the notch open as far as it is then)
  let tap_bar = fn() {
    if l.items.length() > 0 && py >= l.row_top - 4.0 {
      let now = bar_centres(l.w, m.k_at(t), l.items.length())
      let j = nearest(now, l.items.length(), px)
      let slot = bar_item_w(l.w, m.k_at(t), l.items.length())
      if (now[j] - px).abs() <= slot / 2.0 {
        if m.mode.get() {
          m.open_panel(false, at=t)
        }
        on_tab(l.items[j], true)
      }
    }
  }
  // a bar chosen landing lands on its own spring: a finger down meanwhile does not take the ball or the panel (Bar.kt
  // waits); a tap on one of its places is that place's at once, where it is then (src/motion's rule)
  // pressed: the panel open, opening or closing, the finger has it from here
  let pressed = fn() {
    m.felt = "\{l.cur}/\{told.active.unwrap_or("")}"
    m.y0 = py
    m.o0 = o_at
    // (opening: short of the rest its spring declared as it set out, toward open)
    m.holds = l.multi && (m.o0 > 0.02 || (t < m.o.end() && m.o.to > 0.0))
    m.from_open = m.holds
    m.open = m.o.to > 0.5
    if m.holds {
      m.mode.set(true)
    }
  }
  // the finger off the bar (lifted, called off): what its press asked ahead let go of now, or once the place it switches
  // to below has come in (sfbase's place_press_lifted, place_switched)
  if how is (Tapped | Ended) {
    @sfbase.place_press_lifted(t)
  }
  if m.swap_at(t) is Some(_) {
    match how {
      Pressed => m.waits = true
      Tapped => {
        m.waits = false
        tap_bar()
      }
      Held | Dragging => ()
      Ended => m.waits = false
    }
    bar_retell(t)
    return
  }
  // landed with the finger still down: the finger's from here, pressed where it is now (its stroke from there); let go
  // after it landed, nothing
  if m.waits {
    m.waits = false
    match how {
      Held | Dragging => pressed()
      Pressed => ()
      Tapped | Ended => {
        bar_retell(t)
        return
      }
    }
  }
  let open_was = m.open
  // the ball taken by a finger held still on the bar (felt as a long press is)
  let mut took = false
  match how {
    Pressed => {
      pressed()
      // a finger down on a place's tab, the panel shut: what the place opens on asked from now (sfbase's places_ahead)
      if !m.mode.get() && py >= l.row_top - 4.0 && l.items.length() > 0 {
        let cs = bar_centres(l.w, m.k_at(t), l.items.length())
        @sfbase.place_pressed(l.items[imin(l.items.length() - 1, nearest(cs, 4, px))])
      }
    }
    Dragging => {
      if l.multi {
        let raw = m.o0 + (m.y0 - py - (if m.from_open { 0.0 } else { 8.0 })) / l.reach
        if !m.holds && raw > 0.0 {
          m.holds = true
          m.mode.set(true)
        }
        if m.holds {
          let over_bar = l.row_top - py
          if !m.open && over_bar > opens {
            m.open = true
          } else if m.open && over_bar < closes {
            m.open = false
          }
          let snap = if m.open { 1.0 } else { 0.0 }
          let goal = dclamp(snap + lean * (raw - snap), 0.0, 1.1)
          let prev_k_end = m.k_end()
          if m.open {
            m.o.go(goal, 260.0, 17.0, at=t)
          } else {
            m.o.go(goal, 320.0, 26.0, at=t)
          }
          m.schedule_bond(prev_k_end, at=t)
        }
      }
      m.drag = px
      m.drag_y = if l.multi && m.holds && m.open {
        dclamp(py, over + bar_row / 2.0, l.row_top + bar_track / 2.0)
      } else {
        -1.0
      }
    }
    // held still where it went down, on the bar's row: the ball the finger's there, the lens over it as while it
    // slides (iOS's tab bar), going nowhere till the finger moves; let go, as a drag ends
    Held =>
      if !m.holds && py >= l.row_top - 4.0 {
        m.drag = px
        m.drag_y = -1.0
        took = l.items.length() > 0
      }
    Ended => {
      let had = m.holds
      let final_cs = bar_centres(l.w, m.k_at(t), l.items.length())
      // (let go still moving across: the place it was going to, as it carried on (bar_flung); the ball, chasing the
      // finger, goes on there at the speed it had, never turned back short of it)
      let to_px = bar_flung(px, d.vx(), l.w)
      ended()
      if d.kind == Off {
        // called off: the panel where the finger left it, nothing chosen
        if had {
          m.open_panel(m.open, at=t)
        }
      } else if had {
        // let go on a row (the panel open): that bar and that place; else as the finger left it
        let in_rows = py < l.row_top - 4.0 && l.others.length() > 0
        if in_rows && m.o.value_at(t) >= 0.85 {
          let n = dclamp(((py - over) / bar_row).floor(), 0.0, (l.others.length() - 1).to_double()).to_int()
          let set = l.sets[l.others[n]]
          pick(l.others[n], Some(set[nearest(bar_centres(l.w, 0.0, set.length()), set.length(), px)]))
        } else {
          let j = if py >= l.row_top - 4.0 && l.items.length() > 0 {
            imin(l.items.length() - 1, nearest(final_cs, 4, to_px))
          } else {
            -1
          }
          m.open_panel(m.open, at=t)
          if !m.open && j >= 0 {
            on_tab(l.items[j], false)
          }
        }
      } else if l.items.length() > 0 {
        let j = imin(l.items.length() - 1, nearest(final_cs, 4, to_px))
        if m.mode.get() {
          m.open_panel(false, at=t)
        }
        on_tab(l.items[j], false)
      }
    }
    Tapped => {
      ended()
      // a tap: a place on the bar; with the panel open, a row (that bar) or a place in it
      if m.mode.get() && py < l.row_top {
        if o_at > 0.6 && l.others.length() > 0 {
          let shift = (1.0 - dmin(1.0, o_at)) * 14.0 - dmax(0.0, o_at - 1.0) * l.reach
          let n = ((py - over - shift) / bar_row).floor().to_int()
          if n >= 0 && n < l.others.length() {
            let set = l.sets[l.others[n]]
            let cs = bar_centres(l.w, 0.0, set.length())
            let j = nearest(cs, set.length(), px)
            let slot = bar_item_w(l.w, 0.0, set.length())
            pick(l.others[n], if (cs[j] - px).abs() <= slot / 2.0 { Some(set[j]) } else { None })
          }
        }
      } else {
        tap_bar()
      }
    }
  }
  // felt as the finger goes (a switch's ticks): the ball taken by a finger held still, a long press's; the panel
  // snapping open or shut under it, a click; the ball taken to another place (a row's too), a tick, once as it gets
  // there. Let go, nothing more: what it chose was felt already (a tap on another place is felt as it is chosen).
  match how {
    Dragging | Held => {
      let cs = bar_centres(l.w, m.k_at(t), l.items.length())
      let under = match bar_finger(told, cs, m.drag, m.drag_y) {
        Some((_, _, i, key)) => "\{i}/\{key}"
        None => m.felt
      }
      if took {
        @ui.haptic(LongPress)
      } else if m.open != open_was {
        @ui.haptic(ContextClick)
      } else if under != m.felt {
        @ui.haptic(TextHandleMove)
      }
      m.felt = under
    }
    _ => ()
  }
  // (what the finger did told at its moment: the ball, the lens, the places lit set out from then)
  bar_retell(t)
}

///|
/// What a finger on the bar's glass came to (View::gesture's): put down, moved past the slop (and on), held still, let
/// go (or called off) after either, let go where it went down.
priv enum BarFingerIs {
  Pressed
  Dragging
  Held
  Ended
  Tapped
}

///|
/// The bar's glass, a node of the window's tree over the pages (narrow_shell's): where the bar is laid out as it was
/// told (BarLaid: as wide as told, as high as its panel, over the system's navigation bar), pressed while it shows, a
/// finger on it handed to the bar at each event's moment (bar_finger_at), the bar drawn in it (bar_node: what a press
/// there goes to holds what it draws; its notch's key the action's disc). Held still and let go without moving, as a
/// tap: the place under it (the bar's way before: held, the lens; let go, a place as any tap).
fn bar_glass_node(v : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  let told = fn() { bar_told_now.get() }
  // (whether this finger was held: let go after a hold without moving past the slop, a tap; let go past it with no move
  // told, a drag's end)
  let held = Ref(false)
  let finger = fn(how : BarFingerIs) {
    fn(d : @view.Drag) {
      match ws() {
        Some(w) => bar_finger_at(src, w, d, how)
        None => ()
      }
    }
  }
  // the panel open: a finger down anywhere else closes it at that moment, and does nothing else; back closes it too, at
  // the moment it is taken
  v.show(
    fn() {
      bar.mode.get() &&
      (match told() {
        Some(t) => t.shown
        None => false
      })
    },
    fn(m) {
      m
      .over(Is(true))
      .gesture(@ui.touch_slop(), press=fn(d) {
        bar.open_panel(false, at=d.at)
        bar_retell(d.at)
      })
      .takes_back(fn() {
        let at = m.cause_at()
        bar.open_panel(false, at~)
        bar_retell(at)
      })
      |> ignore
    },
  )
  v.box(fn(b) {
    b
    .over(Is(true))
    .padding(By(fn() { (22.0, 0.0, 22.0, 22.0 + nav_foot()) }))
    .presses(By(fn() {
      match told() {
        Some(t) => t.shown
        None => false
      }
    }))
    |> ignore
    b.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    b.box(fn(g) {
      g
      .height(By(fn() {
        match told() {
          Some(t) => Some(bar_laid(t).panel)
          None => Some(0.0)
        }
      }))
      // (a finger taken where the glass is drawn at its moment: under the panel's top as far open as it is then; above it,
      // what is under the bar's)
      .takes(fn(w, h, at) {
        match told() {
          Some(t) => [(0.0, bar_glass_top(bar_laid(t).reach, bar.o.value_at(at)), w, h)]
          None => []
        }
      })
      .gesture(
        @ui.touch_slop(),
        press=fn(d) {
          held.val = false
          (finger(Pressed))(d)
        },
        tap=finger(Tapped),
        hold=(bar_hold_ms, fn(d) {
          held.val = true
          (finger(Held))(d)
        }),
        drag=fn(d) {
          match d.kind {
            Down | Moved => {
              held.val = false
              (finger(Dragging))(d)
            }
            // (held still and let go without moving: a tap, as before)
            Up if held.val => (finger(Tapped))(d)
            _ => (finger(Ended))(d)
          }
        },
      )
      |> ignore
      bar_node(g, src, ws)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A place's top page other than the chats (with the bar under it): Home's top bar over it (the
/// place's name, settings), what it shows the settings' page of it (src/sfapp/settings).
fn place_page(c : @ui.Ctx, src : Source, w : Workspace, place : String) -> Unit {
  // what it shows runs under the top bar, frosted over it (scrolling under it)
  c.box(style=page_whole, fn() {
    // what it shows: the settings' page of the same place (src/sfapp/settings), in place of its own bar
    c.box(style=page_whole, fn() {
      match @settings.route_of(place) {
        Some(r) => {
          // under the top bar, which names it; over the bottom bar
          let top = status_top() + bar_h + 8.0
          let core = settings_core(src, w)
          @settings.page(c, core, @settings.here_of(core, w.id, w.name), r, root=true, top~)
        }
        None => ()
      }
    })
    |> ignore
    c.layer(fn() { place_top_bar(c, place) }) |> ignore
  })
  |> ignore
}

///|
/// A place's top bar at the stack's root: the place's name, the page's actions
/// (`@sf.named_actions`), settings at the right edge; frosted over what runs under it, no line under it.
fn place_top_bar(c : @ui.Ctx, place : String) -> Unit {
  let actions = @sf.named_actions.val
  @sf.named_actions.val = None
  let glass_top = c.box(style=place_top_whole, glass=@sf.glass_bar(), fn() {
    // under the status bar (TopGlassBar: windowInsetsPadding(statusBars), then TopBarHeight)
    c.box(style=place_top_row.then(@ui.style(pt=@sf.room_of(status_top()), min_h=Fixed(top_bar_h()))), fn() {
      // (its words whole: what the page does at its end gives way where the bar has not the room, @sf.head_end)
      c.box(style=place_title_box, keep=true, fn() {
        top_bar_title(c, place_label(place)) |> ignore
      })
      |> ignore
      match actions {
        Some(a) => @sf.head_end(c, a)
        None => ()
      }
      // settings at the right edge, as at Home's
      nav_button(c, "settings", 22.0, key="place-settings", said=tr("android-chat.home.settings"), on_press=fn() {
        @sfbase.history_push()
        app.nav.push(Settings)
      })
    })
    |> ignore
  })
  // over what runs under it: the scroll bar there keeps clear of it
  c.floats_over(glass_top)
}

///|
/// A slide let go while the finger still moves across: the place chosen is where the finger would be this long on at
/// the speed it was let go at (a flick's way projected on, as a list's fling carries its speed), never further than one
/// place's room past where it is let go; let go still, where it is (bar_flung).
let bar_fling_ms : Double = 100.0

///|
/// Where a slide let go at `px` across a bar `w` wide, the finger moving at `vx` (points a ms), chooses its place by
/// (bar_fling_ms on, within one place's room of `px`): `px` itself where it was still.
fn bar_flung(px : Double, vx : Double, w : Double) -> Double {
  let slot = bar_item_w(w, 1.0, 4)
  px + dclamp(vx * bar_fling_ms, -slot, slot)
}

///|
/// A place's top bar (place_top_bar): as wide as the page; its row (16 in from its sides, 10 between its parts), its
/// title's box (34 high, what the page does at its end giving way to it).
// kept across runs: a value (no field of it changes)
let place_top_whole : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let place_top_row : @ui.Style = @ui.css("row w=Full px=S4 gap=S2_5 align=ACenter")

///|
let place_title_h : Double = 34.0

///|
// kept across runs: a value (no field of it changes)
let place_title_box : @ui.Style = @ui.css("row w=Full align=ACenter").then(@ui.style(h=Fixed(place_title_h)))
