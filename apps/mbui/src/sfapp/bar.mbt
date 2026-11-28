// The phone's bottom bar, as Comma's tab bar is drawn (Comma Android's ShellTabBar.kt, the iOS app's GlassTabBar): a
// floating capsule of liquid glass holding the places kept in the prefs' bars, 22 in from the screen's sides and its
// foot (the system's bars are the host's: the view is laid out inside them): the first three each a slot of it and a
// fourth slot standing for the rest (bar_menu.mbt), which opens them as a menu the bar's own glass grows up into; a
// grey selection under the place shown that travels on a spring stretched by its speed and goes where a finger takes
// it, lifting under a finger into a lens of clear glass (the selection and the lens one thing: the lens covers the
// selection whole, what makes it glass coming in with its lift, and flat it is the selection); the page's primary
// action (令, a new chat, on the chats' pages) a glass circle of its own beside the capsule, 10 to its right, the
// capsule giving it room as it comes. Every motion is a number on a spring (or a timed glide), said once at its cause.
// Shown on a place's top page with nothing over it; gone down out of the way (300 ms) under a page pushed, back up
// (380 ms) as it comes back.
//
// The capsule and the circle are neutral optical liquid glass over the pages (@sf.glass_tab_bar: uniform 2.2pt blur,
// quarter-circle bevel refraction, adaptive iOS 27 color transfer and glint, optional touch spot); where glass is drawn solid, their ground. What moves is only drawn so (src/motion's rule): the
// bar going down and coming back, the capsule giving the action room and the action growing and shrinking, its icon
// swapping, the glass growing into the menu are looks over where they are laid out, and what leaves is drawn only.
// (The action shown or not is still called the notch here, `k`, as it stood in one cut into the bar's top before it
// was a circle of its own.)

// ── geometry (dp) ──────────────────────────────────────────────

///|
let bar_track : Double = 50.0

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
let lens_lift_h : Double = 1.24

///|
let lens_lift_aspect : Double = 1.50

///|
let rad : Double = bar_track / 2.0

///|
/// How long a finger held still on the bar takes the ball (its lens over it), as one sliding does.
let bar_hold_ms : Double = 200.0

///|
/// Horizontal and bottom outer margin of the small-screen Liquid Glass bottom tab bar (also used to align
/// bottom-left floating overlays flush with the bar and its scroll-collapsed orb).
let bar_inset_edge : Double = 22.0

///|
/// Distance from the bottom of the window to the top edge of the small-screen Liquid Glass bottom tab bar.
fn bar_top_from_foot() -> Double {
  nav_foot() + bar_inset_edge + bar_track
}

///|
/// What a place's top page keeps clear at its foot for the bar (Places.kt BAR_ROOM: the bar, its 22 from the foot, a
/// little air, and the action standing 32 over it).
let bar_room : Double = bar_track + bar_inset_edge + 16.0 + 32.0

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
  mut x : Double
  mut v : Double
  mut to : Double
  mut tension : Double
  mut friction : Double
  /// at rest within it
  rest : Double
  /// the moment it last set out (the frames' clock, ms)
  mut set_at : Double
  /// what it is, as Tester::moving says it (`bar/k`: the notch, the ball's `bar/ball-x`), beside the bar's glides
  /// (`bar/vis`)
  what : String
}

///|
fn spr(start : Double, tension : Double, friction : Double, what : String, rest? : Double = 0.001) -> Spr {
  { path: None, x: start, v: 0.0, to: start, tension, friction, rest, what, set_at: 0.0 }
}

///|
/// Where it is at `t` and how fast, by the way it is on (none told: where it was put).
fn Spr::at(self : Spr, t : Double) -> (Double, Double) {
  match self.path {
    Some(p) => p.at(t)
    None => (self.x, self.v)
  }
}

///|
/// Sent to `to` by `tension` and `friction` from the moment `at` (its cause's; none: now), from where it is then, as
/// fast as it goes; nothing new when it goes there so already (told the same again, by any build, whenever).
fn Spr::go(self : Spr, to : Double, tension : Double, friction : Double, at~ : Double) -> Unit {
  let same = tension == self.tension && friction == self.friction
  match self.path {
    Some(p) if same && p.target() == to => return
    _ => ()
  }
  let now = at
  let (x, v) = match self.path {
    Some(p) => p.at(now)
    None => (self.x, self.v)
  }
  let p = match self.path {
    Some(p) if same => p
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
  match self.path {
    Some(p) => p.end()
    None => -1.0
  }
}

///|
/// Where it is at `t` (ms, the frames' clock), by the way it is on (Spr::at): for where it is at the moment a cause
/// tells it anew.
fn Spr::value_at(self : Spr, t : Double) -> Double {
  self.at(t).0
}

///|
/// There at once, at rest.
fn Spr::put(self : Spr, x : Double) -> Unit {
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
  self.x = x
  self.v = 0.0
  self.to = x
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
/// What the bar keeps between frames (BallMotion); its menu's apart (bar_menu.mbt's BarMenu).
priv struct BarModel {
  /// the notch (1 open); the ball held (lift/unlift pair)
  k : Spr
  ball_held_up : @motion.Way
  ball_held_dn : @motion.Way
  mut ball_held_active : Bool
  /// the selection showing again under the lens as it lands (ball_held_dn's moment, a slower spring: quicker out than
  /// back in, as the system bar's selection)
  ball_pill_dn : @motion.Way
  /// the bar shown, the ball shown and its size
  vis : Glide
  ball_alpha : Glide
  ball_scale : Glide
  /// each slot's place drawn ("bar:<place>"): how lit
  tints : Map[String, Glide]
  /// the ball: where across, on iOS 27.0 calibrated springs (zeta 0.85)
  ball_x : Spr
  /// closed-form clear glass droplet lift/unlift pair during cross-tab tap flight (`tap_lens_up - tap_lens_dn`), and
  /// the selection showing again under it (tap_lens_dn's moment)
  tap_lens_up : @motion.Way
  tap_lens_dn : @motion.Way
  tap_pill_dn : @motion.Way
  /// timestamp (ms) when finger hold/drag lens lift started (`-1.0` when not lifted), for `lensHangTime = 220ms`
  mut lift_started_at : Double
  /// closed-form `_UIFlexInteraction` volume-preserving jelly deformation channels (launch, brake, decay, drag, wall)
  flex_launch : @motion.Way
  flex_brake : @motion.Way
  flex_decay : @motion.Way
  flex_drag : @motion.Way
  flex_wall : @motion.Way
  /// scheduled fire timestamps (ms) for delayed launch/brake impulses (`-1.0` none) so interruption never inherits queued v0
  mut flex_launch_fire_at : Double
  mut flex_brake_fire_at : Double
  /// gesture-event drag kinematics for real-time acceleration/deceleration flex (updated only in `bar_finger_did`)
  mut drag_last_x : Double
  mut drag_last_t : Double
  mut drag_speed_ref : Double
  mut drag_last_vx : Double
  /// target tab key armed by a finger tap on a non-active tab, cleared on consumption or any new gesture
  mut tap_pending_key : String
  mut active_was : String
  /// a finger: where it has the ball (-1 none)
  mut drag : Double
  /// first drawn: everything where it goes at once
  mut placed : Bool
  mut width : Double
  /// the slot a finger came down on (-1 while none is down on the bar, or the menu it opened has closed under it), the
  /// slot it is over, and the slot this press last ticked on: the one shown, which needs no tick, until the finger
  /// moves on to another (ShellTabBar.kt pressSlot, hovered, ticked)
  mut press_slot : Int
  mut hovered : Int
  mut ticked : Int
  /// the notch's icon going as another swaps in ("" none), how far the swap is (0 to 1)
  mut icon_was : String
  icon_swap : Glide
  /// capillary liquid bridge merge radius & elastic recoil between capsule and `＋` action circle
  bond_merge : @motion.Way
  bond_recoil : @motion.Way
  mut bond_bonded : Bool
  /// iOS 26 scroll-to-collapse state (0.0 expanded -> 1.0 collapsed into left 56x56 orb)
  mut collapsed : Bool
  collapse : @motion.Way
  /// scroll direction hysteresis tracking for root-page lists
  mut scroll_last_y : Double
  mut scroll_acc : Double
  mut scroll_page_key : String
  /// what it was last told by the app's state (bar_tell, at its cause's moment): told the same again, nothing new
  mut told : BarTold?
}

///|
/// The ball's spring across, calibrated to measured Apple iOS 27.0 UITabBar:
/// cross-tab tap uses `ball_tap_k = 280.0`, `ball_zeta = 0.85` (duration=0.40s, bounce=0.15);
/// finger drag tracking matches measured 26.8pt steady lag at 339pt/s (`2*zeta/wn = 0.0796s`, ratio=1.0).
let ball_zeta : Double = 0.85

///|
let ball_tap_k : Double = 280.0

///|
let ball_drag_k : Double = 631.654682

///|
let ball_drag_damping : Double = 50.265482

///|
/// Minimum droplet hang time (`lensHangTime = 220ms`) matching measured iOS 27.0 `_UILiquidLensView`.
let bar_lens_hang_ms : Double = 220.0

///|
/// Deterministic hyperbolic tangent via `@dmath.exp` (bit-identical across all targets/engines).
fn bar_tanh(x : Double) -> Double {
  if x >= 10.0 {
    1.0
  } else if x <= -10.0 {
    -1.0
  } else {
    let e2 = @dmath.exp(2.0 * x)
    (e2 - 1.0) / (e2 + 1.0)
  }
}

///|
/// Precomputed unit-velocity peak response of `liquid_flex_spring` (`ratio=0.65, stiffness=125.0`):
/// `exp(-z * wn * tp) * sin(wd * tp) / wd` where `tp = atan2(sqrt(1 - z^2), z) / wd`.
let bar_flex_unit_peak : Double = 0.04274538748148292

///|
/// Linear drag acceleration-to-flex impulse gain: a `339 pt/s` start or stop produces `±0.072` jelly amplitude
/// (`sx ≈ 1.062 / 0.936` matching measured native iOS 27.0 slow drag), strictly invariant to touch sample rate.
let bar_drag_flex_gain : Double = (0.072 / 339.0) / bar_flex_unit_peak

///|
/// Exact initial velocity `v0` (units/s) required for `liquid_flex_spring` (`ratio=0.65, k=125.0`) starting from `0`
/// to reach first-peak amplitude `peak`.
fn bar_flex_v0(peak : Double) -> Double {
  peak / bar_flex_unit_peak
}

///|
/// Current `(x, v)` of a possibly-delayed flex impulse `Way`, zeroing `v` before `fire_at` so interrupting before
/// a delayed impulse fires never inherits its queued `v0` as a phantom impulse.
fn bar_flex_state_at(w : @motion.Way, fire_at : Double, at : Double) -> (Double, Double) {
  let (x, v) = w.at(at)
  if at < fire_at {
    (x, 0.0)
  } else {
    (x, v)
  }
}

///|
/// Moves any active residual oscillation on delayed channel `w` into the zero-delay `flex_decay` channel so
/// re-scheduling `w` with a new `delay` never freezes ongoing decay, then schedules the new delayed impulse from `0`.
fn BarModel::schedule_delayed_flex(
  self : BarModel,
  w : @motion.Way,
  old_fire_at : Double,
  delay : Double,
  peak : Double,
  at : Double,
) -> Double {
  let (old_x, old_v) = bar_flex_state_at(w, old_fire_at, at)
  if old_x != 0.0 || old_v != 0.0 {
    let (dx, dv) = self.flex_decay.at(at)
    self.flex_decay.put(dx + old_x)
    self.flex_decay.go(
      0.0,
      @motion.liquid_flex_spring,
      at~,
      velocity=dclamp(dv + old_v, -6.0, 6.0),
    )
  }
  w.put(0.0)
  w.go(0.0, @motion.liquid_flex_spring.delayed(delay), at~, velocity=bar_flex_v0(peak))
  at + delay
}

///|
/// Cancels a pending or active delayed flex channel `w`, folding any live oscillation into `flex_decay` without
/// inheriting queued `v0` if `at < old_fire_at`.
fn BarModel::cancel_delayed_flex(
  self : BarModel,
  w : @motion.Way,
  old_fire_at : Double,
  at : Double,
) -> Double {
  if old_fire_at < 0.0 {
    return -1.0
  }
  let (old_x, old_v) = bar_flex_state_at(w, old_fire_at, at)
  if old_x != 0.0 || old_v != 0.0 {
    let (dx, dv) = self.flex_decay.at(at)
    self.flex_decay.put(dx + old_x)
    self.flex_decay.go(
      0.0,
      @motion.liquid_flex_spring,
      at~,
      velocity=dclamp(dv + old_v, -6.0, 6.0),
    )
  }
  w.put(0.0)
  -1.0
}

///|
fn ball_damping(tension : Double) -> Double {
  2.0 * ball_zeta * tension.sqrt()
}

///|
/// Hyperbolic iOS rubber-band damping for horizontal drag past the first/last tab center.
fn bar_rubber(over : Double, max_over : Double) -> Double {
  if over == 0.0 {
    0.0
  } else {
    let a = over.abs()
    let d = max_over * a / (a + max_over / 0.35)
    if over < 0.0 { -d } else { d }
  }
}

///|
/// Hermite smoothstep in [0, 1] across [e0, e1].
fn bar_smoothstep(e0 : Double, e1 : Double, x : Double) -> Double {
  let t = dclamp((x - e0) / (e1 - e0), 0.0, 1.0)
  t * t * (3.0 - 2.0 * t)
}

///|
/// Finger hold/drag droplet lift intensity at moment `t` (`ball_held_up - ball_held_dn`, clamped to `[0, 1]`).
fn BarModel::ball_held_at(self : BarModel, t : Double) -> Double {
  dclamp(self.ball_held_up.value_at(t) - self.ball_held_dn.value_at(t), 0.0, 1.0)
}

///|
/// Latest end timestamp (ms) of the finger hold/drag droplet lift/unlift pair.
fn BarModel::ball_held_ends_at(self : BarModel) -> Double {
  dmax(self.ball_held_up.ends_at(), self.ball_held_dn.ends_at())
}

///|
/// Cross-tab tap droplet lift intensity at moment `t` (`tap_lens_up - tap_lens_dn`, clamped to `[0, 1]`).
fn BarModel::tap_lens_at(self : BarModel, t : Double) -> Double {
  dclamp(self.tap_lens_up.value_at(t) - self.tap_lens_dn.value_at(t), 0.0, 1.0)
}

///|
/// Latest end timestamp (ms) of the cross-tab tap droplet lift/unlift pair.
fn BarModel::tap_lens_ends_at(self : BarModel) -> Double {
  dmax(self.tap_lens_up.ends_at(), self.tap_lens_dn.ends_at())
}

///|
/// Effective lens intensity at moment `t`: smooth C-infinity probabilistic union of finger hold/drag lens and
/// cross-tab tap flight droplet (no V-shaped kink where the two curves cross).
fn BarModel::held_at(self : BarModel, t : Double) -> Double {
  let a = self.ball_held_at(t)
  let b = self.tap_lens_at(t)
  a + b - a * b
}

///|
/// Combined `_UIFlexInteraction` jelly deformation scalar `u` at moment `t` in `[-0.20, 0.20]`
/// (`u > 0`: horizontal stretch + vertical flatten; `u < 0`: horizontal narrow + vertical bulge).
fn BarModel::flex_at(self : BarModel, t : Double) -> Double {
  let drag_u = bar_tanh(self.flex_drag.value_at(t) / 0.17) * 0.17
  dclamp(
    self.flex_launch.value_at(t) +
    self.flex_brake.value_at(t) +
    self.flex_decay.value_at(t) +
    drag_u +
    self.flex_wall.value_at(t),
    -0.20,
    0.20,
  )
}

///|
/// Latest end timestamp (ms) across all five jelly deformation channels.
fn BarModel::flex_ends_at(self : BarModel) -> Double {
  dmax(
    dmax(dmax(self.flex_launch.ends_at(), self.flex_brake.ends_at()), self.flex_decay.ends_at()),
    dmax(self.flex_drag.ends_at(), self.flex_wall.ends_at()),
  )
}

///|
/// Applies an immediate single-channel jelly impulse of peak `peak` onto `flex_drag` at `at` (C0-continuous).
fn BarModel::pulse_flex_drag(self : BarModel, peak : Double, at : Double) -> Unit {
  let (_, cur_fv) = self.flex_drag.at(at)
  let v0 = dclamp(cur_fv + bar_flex_v0(peak), -6.0, 6.0)
  self.flex_drag.go(0.0, @motion.liquid_flex_spring, at~, velocity=v0)
}

///|
/// The ball at rest within this (points).
let ball_rest_within : Double = 0.01

///|
let bar : BarModel = {
  k: spr(1.0, 300.0, 30.0, "bar/k"),
  ball_held_up: @motion.Way::new(0.0),
  ball_held_dn: @motion.Way::new(0.0),
  ball_held_active: false,
  ball_pill_dn: @motion.Way::new(0.0),
  vis: glide(0.0),
  ball_alpha: glide(1.0),
  ball_scale: glide(1.0),
  tints: {},
  ball_x: spr(0.0, ball_tap_k, ball_damping(ball_tap_k), "bar/ball-x", rest=ball_rest_within),
  tap_lens_up: @motion.Way::new(0.0),
  tap_lens_dn: @motion.Way::new(0.0),
  tap_pill_dn: @motion.Way::new(0.0),
  lift_started_at: -1.0,
  flex_launch: @motion.Way::new(0.0),
  flex_brake: @motion.Way::new(0.0),
  flex_decay: @motion.Way::new(0.0),
  flex_drag: @motion.Way::new(0.0),
  flex_wall: @motion.Way::new(0.0),
  flex_launch_fire_at: -1.0,
  flex_brake_fire_at: -1.0,
  drag_last_x: -1.0,
  drag_last_t: -1.0,
  drag_speed_ref: 0.0,
  drag_last_vx: 0.0,
  tap_pending_key: "",
  active_was: "",
  drag: -1.0,
  placed: false,
  width: 0.0,
  press_slot: -1,
  hovered: -1,
  ticked: -1,
  icon_was: "",
  bond_merge: @motion.Way::new(0.0),
  bond_recoil: @motion.Way::new(0.0),
  bond_bonded: false,
  collapsed: false,
  collapse: @motion.Way::new(0.0),
  scroll_last_y: 0.0,
  scroll_acc: 0.0,
  scroll_page_key: "",
  told: None,
  icon_swap: glide(1.0),
}

///|
/// Whether the bottom bar's menu currently occupies the space directly above its resting track (used by Home's
/// bottom-left floating group pill to step aside cleanly).
fn bar_obstructs_above() -> Bool {
  bar_menu.open.get()
}

///|
/// As at the start (tests).
fn bar_reset() -> Unit {
  let back_glide = fn(g : Glide, to : Double) {
    g.snap(to)
    g.start = 0.0
  }
  bar_menu.reset()
  bar_open_wanted.val = false
  bar_more_reset()
  bar.k.back(1.0, 300.0, 30.0)
  bar.ball_held_up.put(0.0)
  bar.ball_held_dn.put(0.0)
  bar.ball_held_active = false
  bar.ball_pill_dn.put(0.0)
  back_glide(bar.vis, 0.0)
  back_glide(bar.ball_alpha, 1.0)
  back_glide(bar.ball_scale, 1.0)
  bar.tints.clear()
  bar.ball_x.back(0.0, ball_tap_k, ball_damping(ball_tap_k))
  bar.tap_lens_up.put(0.0)
  bar.tap_lens_dn.put(0.0)
  bar.tap_pill_dn.put(0.0)
  bar.lift_started_at = -1.0
  bar.flex_launch.put(0.0)
  bar.flex_brake.put(0.0)
  bar.flex_decay.put(0.0)
  bar.flex_drag.put(0.0)
  bar.flex_wall.put(0.0)
  bar.flex_launch_fire_at = -1.0
  bar.flex_brake_fire_at = -1.0
  bar.drag_last_x = -1.0
  bar.drag_last_t = -1.0
  bar.drag_speed_ref = 0.0
  bar.drag_last_vx = 0.0
  bar.tap_pending_key = ""
  bar.active_was = ""
  bar.drag = -1.0
  bar.placed = false
  bar.width = 0.0
  bar.press_slot = -1
  bar.hovered = -1
  bar.ticked = -1
  bar.icon_was = ""
  back_glide(bar.icon_swap, 1.0)
  bar.bond_merge.put(0.0)
  bar.bond_recoil.put(0.0)
  bar.bond_bonded = false
  bar.collapsed = false
  bar.collapse.put(0.0)
  bar.scroll_last_y = 0.0
  bar.scroll_acc = 0.0
  bar.scroll_page_key = ""
  m_face.val = ""
  bar.told = None
  bar_told_now.set(None)
  bar_laid_told.set(bar_laid_none())
  bar_active_slot_told.set(-1)
  for i in 0..<bar_parts_told.length() {
    bar_parts_told[i] = ""
  }
  bar_said_again()
}

///|
/// When all of the bar is at rest (the frames' clock, ms; before now: it is), as its springs and glides said as they
/// set out. Only for a test's end, before its assert_idle (idle is after all it said has ended); never a point a test
/// waits for midway: there a test asks the end of the one path it looks at, not of the whole bar.
fn BarModel::rest(self : BarModel) -> Double {
  let mut e = -1.0
  for s in [self.k, self.ball_x] {
    e = dmax(e, s.end())
  }
  let gs = [self.vis, self.ball_alpha, self.ball_scale, self.icon_swap]
  for _, g in self.tints {
    gs.push(g)
  }
  for g in gs {
    e = dmax(e, g.end())
  }
  e = dmax(e, dmax(self.ball_held_ends_at(), self.tap_lens_ends_at()))
  e = dmax(e, self.flex_ends_at())
  e = dmax(e, dmax(self.bond_merge.ends_at(), self.bond_recoil.ends_at()))
  e = dmax(e, self.collapse.ends_at())
  e = dmax(e, bar_menu.rest())
  e
}

///|
/// When the bottom bar is at rest (BarModel::rest): for a test of the app over its pages (src/sfreplay), as for this
/// package's own, only at a test's end or where a page is pushed, never a point waited for midway.
pub fn bar_rest() -> Double {
  bar.rest()
}

///|
/// Everything where it is going, at once (the first frame; reduced motion).
fn BarModel::jump(self : BarModel) -> Unit {
  for s in [self.k, self.ball_x] {
    s.put(s.to)
  }
  if self.ball_held_active {
    self.ball_held_up.put(1.0)
    self.ball_held_dn.put(0.0)
  } else {
    self.ball_held_up.put(0.0)
    self.ball_held_dn.put(0.0)
  }
  self.ball_pill_dn.put(0.0)
  self.tap_lens_up.put(0.0)
  self.tap_lens_dn.put(0.0)
  self.tap_pill_dn.put(0.0)
  self.lift_started_at = -1.0
  self.flex_launch.put(0.0)
  self.flex_brake.put(0.0)
  self.flex_decay.put(0.0)
  self.flex_drag.put(0.0)
  self.flex_wall.put(0.0)
  self.flex_launch_fire_at = -1.0
  self.flex_brake_fire_at = -1.0
  self.tap_pending_key = ""
  for g in [self.vis, self.ball_alpha, self.ball_scale, self.icon_swap] {
    g.snap(g.target)
  }
  for _, g in self.tints {
    g.snap(g.target)
  }
  self.bond_merge.put(self.bond_merge.target())
  self.bond_recoil.put(0.0)
  self.collapse.put(self.collapse.target())
}

///|
/// Capillary liquid bridge parameters between the bottom bar capsule and the `＋` action circle.
let bar_bond_merge_max : Double = 30.0

///|
let bar_bond_break_gap : Double = 8.0

///|
/// Visual outer-contour tangency offset (0.75pt external contour on each glass body = 1.5pt total).
let bar_bond_contact_gap : Double = 1.5

///|
/// Fast capillary snap-coalescence duration once the glass contours touch (`gap <= bar_bond_contact_gap`).
let bar_bond_merge_ms : Double = 40.0

///|
/// Schedules the closed-form capillary liquid bridge (`bond_merge` & `bond_recoil`) directly from the physical gap
/// `gap_at(t)` and hysteresis band `[bar_bond_contact_gap, bar_bond_break_gap]`, handling tab switches and the
/// bar's scroll-collapse.
fn BarModel::schedule_bond(self : BarModel, _prev_k_end : Double, at~ : Double) -> Unit {
  let end = dmax(at, dmax(self.k.end(), self.collapse.ends_at()))
  let w = self.width
  let gap_at = fn(t : Double) {
    let k = self.k_at(t)
    let c = self.collapse_at(t)
    let extra = if w > 0.0 && c > 0.0 {
      dmax(0.0, bar_capsule_w(w, k) - bar_track) * c
    } else {
      0.0
    }
    (act_size + act_gap) * k - act_size + extra
  }
  let cur_gap = gap_at(at)
  let cur_merge = self.bond_merge.value_at(at)
  let merge_spec = @motion.tween(bar_bond_merge_ms, ease=Out)
  let bonded_now = if cur_gap <= bar_bond_contact_gap {
    true
  } else if cur_gap >= bar_bond_break_gap {
    false
  } else {
    cur_merge > 1.0
  }
  if bonded_now {
    match @motion.liquid_bond_cross_time(at, end, gap_at, true, bar_bond_break_gap) {
      Some(ts) => {
        self.bond_bonded = false
        let delay = dmax(0.0, ts - at)
        if delay > 0.0 {
          if cur_merge < bar_bond_merge_max * 0.5 {
            self.bond_merge.put(bar_bond_merge_max)
          }
          self.bond_merge.go(0.0, @motion.liquid_split_spring.delayed(delay), at~)
        } else {
          self.bond_merge.go(0.0, @motion.liquid_split_spring, at~)
        }
        self.bond_recoil.put(0.0)
        self.bond_recoil.go(0.0, @motion.liquid_recoil_spring.delayed(delay), at~, velocity=-4.5)
      }
      None => {
        self.bond_bonded = true
        if self.bond_merge.target() < bar_bond_merge_max - 0.1 {
          self.bond_merge.go(bar_bond_merge_max, merge_spec, at~)
          self.bond_recoil.put(0.0)
          self.bond_recoil.go(0.0, @motion.liquid_recoil_spring, at~, velocity=4.0)
        }
      }
    }
  } else {
    match @motion.liquid_bond_cross_time(at, end, gap_at, false, bar_bond_contact_gap) {
      Some(tt) => {
        self.bond_bonded = true
        let delay = dmax(0.0, tt - at)
        self.bond_merge.put(0.0)
        self.bond_merge.go(bar_bond_merge_max, merge_spec.delayed(delay), at~)
        self.bond_recoil.put(0.0)
        self.bond_recoil.go(0.0, @motion.liquid_recoil_spring.delayed(delay), at~, velocity=4.0)
      }
      None => {
        self.bond_bonded = false
        if cur_merge > 0.05 || self.bond_merge.target() > 0.0 {
          self.bond_merge.go(0.0, @motion.liquid_split_spring, at~)
        } else {
          self.bond_merge.put(0.0)
        }
      }
    }
  }
}

///|
/// Notch fraction below which the `＋` circle stays completely absorbed inside the capsule (unrendered, merge = 0) and
/// at which it finishes emerging to its resting position and full size (before physical contact breaks at k = 5/6).
let bar_disc_k_start : Double = 0.05

///|
let bar_disc_k_full : Double = 0.80

///|
/// Capillary liquid bridge merge radius between the capsule and `＋` circle at moment `t` (ms).
/// While the `＋` circle buds out from inside the capsule (`k` in `(0.30, 0.76)`), the smooth-min radius ramps
/// smoothly from a hairline `0.05` (keeping both shapes in one `sd_group` with zero double-glass rim) up to full
/// `bond_merge`, preventing overlapping-shape smooth-min inflation at the panel's bottom-right corner.
fn bar_merge_at(t : Double) -> Double {
  let k = bar.k_at(t)
  if k <= bar_disc_k_start || bar.collapse_at(t) > 0.05 {
    return 0.0
  }
  let m = bar.bond_merge.value_at(t)
  if !bar.bond_bonded && m < 0.05 {
    return 0.0
  }
  let scaled = dmax(0.0, m) * bar_smoothstep(0.30, 0.76, k)
  if k <= bar_disc_k_full {
    dmax(0.05, scaled)
  } else {
    scaled
  }
}

///|
/// Scroll hysteresis thresholds for iOS 26 bottom bar scroll-to-collapse (dp).
let bar_collapse_down_acc : Double = 36.0

///|
let bar_collapse_down_min_y : Double = 48.0

///|
let bar_collapse_up_acc : Double = 24.0

///|
let bar_collapse_top_y : Double = 24.0

///|
/// Effective scroll-to-collapse progress at moment `t` (0.0 expanded -> 1.0 collapsed left orb), suppressed while the
/// bar is its menu or on its way there or back.
fn BarModel::collapse_at(self : BarModel, t : Double) -> Double {
  if bar_menu.busy_at(t) {
    0.0
  } else {
    dclamp(self.collapse.value_at(t), 0.0, 1.0)
  }
}

///|
/// Capsule width on a bar `w` wide with notch `k` and scroll-collapse progress `c`: shrinks smoothly from
/// `bar_capsule_w(w, k)` down to `bar_track` (56pt circular orb anchored at `x = 0`).
fn bar_cur_capsule_w(w : Double, k : Double, c : Double) -> Double {
  let full_w = bar_capsule_w(w, k)
  full_w + (bar_track - full_w) * dclamp(c, 0.0, 1.0)
}

///|
/// Transitions the bottom bar between expanded (`false`) and scroll-collapsed (`true`) at moment `at`.
fn bar_set_collapsed(collapsed : Bool, at : Double) -> Unit {
  let m = bar
  if m.collapsed == collapsed {
    return
  }
  if collapsed {
    if m.drag >= 0.0 || bar_menu.busy_at(at) {
      return
    }
    match m.told {
      Some(t) if t.shown => ()
      _ => return
    }
  }
  m.collapsed = collapsed
  m.scroll_acc = 0.0
  let target = if collapsed { 1.0 } else { 0.0 }
  if @ui.reduced_motion() {
    m.collapse.put(target)
  } else {
    m.collapse.go(target, @motion.snappy_damped, at~)
  }
  let prev_k_end = m.k_end()
  m.schedule_bond(prev_k_end, at~)
  bar_said_again()
}

///|
/// Feeds a root-page list's scroll offset `y` (within `[0, most]`, ignoring rubber-band overscroll) into the
/// scroll-to-collapse hysteresis controller.
fn bar_scroll_note(page_key : String, y : Double, most : Double, at : Double) -> Unit {
  let m = bar
  if most <= 0.0 || y < 0.0 || y > most {
    return
  }
  if page_key != m.scroll_page_key {
    m.scroll_page_key = page_key
    m.scroll_last_y = y
    m.scroll_acc = 0.0
    if y <= bar_collapse_top_y && m.collapsed {
      bar_set_collapsed(false, at)
    }
    return
  }
  let dy = y - m.scroll_last_y
  m.scroll_last_y = y
  if dy.abs() < 0.01 {
    return
  }
  if y <= bar_collapse_top_y {
    m.scroll_acc = 0.0
    if m.collapsed {
      bar_set_collapsed(false, at)
    }
    return
  }
  if dy > 0.0 {
    if m.scroll_acc < 0.0 {
      m.scroll_acc = dy
    } else {
      m.scroll_acc = m.scroll_acc + dy
    }
    if !m.collapsed && y > bar_collapse_down_min_y && m.scroll_acc >= bar_collapse_down_acc {
      bar_set_collapsed(true, at)
    }
  } else {
    if m.scroll_acc > 0.0 {
      m.scroll_acc = dy
    } else {
      m.scroll_acc = m.scroll_acc + dy
    }
    if m.collapsed && -m.scroll_acc >= bar_collapse_up_acc {
      bar_set_collapsed(false, at)
    }
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
  if !told.shown || !bar_disc_takes(t) {
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
/// What the bar is told by the app's state and the window: the workspace in view, whether it shows, the notch's action
/// ("" none: closed), the place shown, the places kept in the prefs' bars in their order (`flat`: the first three each
/// a slot, the rest the menu's rows, bar_menu.mbt), the menu's place the last slot stands for (`more`, "" with no
/// menu), how wide it is laid out (0: not known yet). Compared whole: told the same again, nothing new.
#derive(Eq)
priv struct BarTold {
  ws : String
  shown : Bool
  action : String
  active : String?
  flat : Array[String]
  more : String
  width : Double
}

///|
/// What the bar is told in workspace `ws` with `active` the place on top, `shown` whether it shows (narrow_shell's
/// narrow_bar_shown), in a window `window` wide.
fn bar_told(src : Source, ws : Workspace, active : String?, shown : Bool, window : Double) -> BarTold {
  // (the bar's places as both bars lay them out: sfbase's bar_slots)
  let slots = bar_slots(src, ws.id, active)
  {
    ws: ws.id,
    shown,
    action: bar_action(src, ws, active, bar_place_add(src, ws, active)),
    active,
    flat: slots.flat,
    more: slots.more,
    width: if window > 0.0 { window - 44.0 } else { 0.0 },
  }
}

///|
/// The bar's geometry as `told` has it (bar_tell's): its slots' places (the last the menu's place it stands for, with a
/// menu), the menu's rows' places, how wide, how high its glass's node is (the menu's height: the glass grows up into
/// it) and its track's top in that.
#derive(Eq)
priv struct BarLaid {
  items : Array[String]
  menu : Array[String]
  w : Double
  panel : Double
  row_top : Double
}

///|
fn bar_laid(told : BarTold) -> BarLaid {
  let menu = bar_menu_of(told.flat)
  let panel = bar_menu_h(menu.length())
  let items = if menu.is_empty() {
    told.flat
  } else {
    let slots = told.flat[0:bar_slots_most - 1].to_owned()
    slots.push(told.more)
    slots
  }
  { items, menu, w: told.width, panel, row_top: panel - bar_track }
}

///|
/// The slot that stands for the menu's places (-1 with no menu).
fn BarLaid::more_slot(self : BarLaid) -> Int {
  if self.menu.is_empty() {
    -1
  } else {
    self.items.length() - 1
  }
}

///|
/// The slot of place `place` (a menu's place, the last slot's: -1 none).
fn BarLaid::slot_of(self : BarLaid, place : String?) -> Int {
  match place {
    Some(p) =>
      match self.items.search(p) {
        Some(i) => i
        None => if self.menu.contains(p) { self.more_slot() } else { -1 }
      }
    None => -1
  }
}

///|
/// The notch as it is at `t`: as its place has it. A finger on the bar leaves it as it is, as Comma's bar keeps its
/// circle: the places stay where the finger found them.
fn BarModel::k_at(self : BarModel, t : Double) -> Double {
  self.k.value_at(t)
}

///|
/// Where the notch as drawn (BarModel::k_at) is going.
fn BarModel::k_end(self : BarModel) -> Double {
  self.k.to
}

///|
/// How much of the bar's selection shows at `t`: all of it at rest, none under the lifted lens (it goes as the lens
/// lifts and shows again, slower, as the lens lands: ShellTabBar.kt followLens), and as the tab row has it while the
/// bar is its menu (BarMenu::pill_at).
fn BarModel::pill_alpha_at(self : BarModel, t : Double) -> Double {
  match bar_menu.pill_at(t) {
    Some(a) => a
    None => {
      let a = dclamp(self.ball_held_up.value_at(t) - self.ball_pill_dn.value_at(t), 0.0, 1.0)
      let b = dclamp(self.tap_lens_up.value_at(t) - self.tap_pill_dn.value_at(t), 0.0, 1.0)
      (1.0 - a) * (1.0 - b)
    }
  }
}

///|
/// Whether the bar draws a lens at all (liquid glass: bar_lens_node's), as it was last made: where it does not, no
/// lens is handed to the menu's indicator.
// kept across runs: said again as the bar's lens is made
let bar_lens_on : Ref[Bool] = Ref(true)

///|
/// How far the lens is lifted at `t`, 0 to 1 (none where the bar draws none).
fn BarModel::lift_at(self : BarModel, t : Double) -> Double {
  if bar_lens_on.val {
    dclamp(self.held_at(t), 0.0, 1.0)
  } else {
    0.0
  }
}

///|
/// How much larger the whole bar is drawn at `t` (1: as laid out): `press_growth` more under a lifted lens, let down
/// by itself once the menu takes the lens.
fn BarModel::grown_at(self : BarModel, t : Double) -> Double {
  1.0 + press_growth * bar_menu.press_at(t, self.lift_at(t))
}

///|
/// How much larger slot `i`'s glyph is drawn at `t` on the bar laid out as `l`, on top of the bar's own growth: under
/// the lifted lens `lens_zoom`, in place (lens_glyph_zoom), none outside it; while the bar turns into its menu, what
/// it had as the menu opened for as long as the tab row is still seen (BarMenu::zoom_share_at).
fn BarModel::zoom_at(self : BarModel, l : BarLaid, i : Int, t : Double) -> Double {
  let menu = bar_menu
  if menu.busy_at(t) {
    let held = if i < menu.held_zoom.length() { menu.held_zoom[i] } else { 1.0 }
    return 1.0 + (held - 1.0) * menu.zoom_share_at(t)
  }
  let lift = self.lift_at(t)
  if lift <= 0.0 || l.items.length() == 0 {
    return 1.0
  }
  let a = bar_ball_at(t)
  let (cx, _, sw, _) = bar_ball_frame(a, l)
  lens_glyph_zoom(bar_centres(l.w, a.k, l.items.length())[i] - cx, sw, lift)
}

///|
/// The selection at rest on slot `slot` of the bar laid out as `l` with the notch `k` open, in the bar's track.
fn bar_rest_selection(l : BarLaid, slot : Int, k : Double) -> Anchored {
  let n = l.items.length()
  let a : BallAt = {
    cx: bar_centres(l.w, k, n)[if slot < 0 { 0 } else { slot }],
    sx: 1.0,
    sy: 1.0,
    alpha: 1.0,
    scale: 1.0,
    held: 0.0,
    drag_held: 0.0,
    k,
    collapse: 0.0,
  }
  let (cx, _, sw, sh) = bar_ball_frame(a, l)
  Anchored::on_track(cx - sw / 2.0, (bar_track - sh) / 2.0, cx + sw / 2.0, sh)
}

///|
/// The lens's own ways over at once (the menu's indicator carries it from here, or it is gone): flat, still, on no
/// finger.
fn BarModel::drop_lens(self : BarModel, at : Double) -> Unit {
  self.ball_held_up.put(0.0)
  self.ball_held_dn.put(0.0)
  self.ball_pill_dn.put(0.0)
  self.ball_held_active = false
  self.tap_lens_up.put(0.0)
  self.tap_lens_dn.put(0.0)
  self.tap_pill_dn.put(0.0)
  self.lift_started_at = -1.0
  self.flex_launch_fire_at = self.cancel_delayed_flex(self.flex_launch, self.flex_launch_fire_at, at)
  self.flex_brake_fire_at = self.cancel_delayed_flex(self.flex_brake, self.flex_brake_fire_at, at)
  self.flex_decay.put(0.0)
  self.flex_drag.put(0.0)
  self.flex_wall.put(0.0)
  self.tap_pending_key = ""
  self.drag = -1.0
  self.drag_last_x = -1.0
  self.drag_last_t = -1.0
  self.drag_speed_ref = 0.0
  self.drag_last_vx = 0.0
}

///|
/// The bar grows up into its menu from `t`, its glyphs blurring out as the rows rise (ShellTabBar.kt openMenu). With
/// `tracking` the finger that opened it at `y` down the bar's node is still down and goes on to pick a row. The lens a
/// finger dragged here is what the indicator starts as.
fn BarModel::open_menu(self : BarModel, tracking : Bool, y : Double, t : Double) -> Unit {
  let menu = bar_menu
  let told = match self.told {
    Some(told) => told
    None => return
  }
  let l = bar_laid(told)
  if menu.open.untracked() || l.w <= 0.0 || l.menu.is_empty() {
    return
  }
  if self.collapsed {
    bar_set_collapsed(false, t)
  }
  let k = self.k_at(t)
  let cw = bar_capsule_w(l.w, k)
  // (as it all is at `t`, before the menu is said open)
  let rest = bar_rest_selection(l, l.more_slot(), k)
  let cur = menu.ind_at(t, cw, rest)
  let lift = self.lift_at(t)
  let press = menu.press_at(t, lift)
  let grown = 1.0 + press_growth * press
  let (lcx, _, lsw, lsh) = bar_ball_frame(bar_ball_at(t), l)
  let mid = cw / 2.0
  let lens = Anchored::on_track(
    mid + (lcx - lsw / 2.0 - mid) * grown,
    bar_track / 2.0 - lsh / 2.0 * grown,
    mid + (lcx + lsw / 2.0 - mid) * grown,
    lsh * grown,
  )
  let zooms = [1.0, 1.0, 1.0, 1.0]
  for i in 0..<imin(l.items.length(), zooms.length()) {
    zooms[i] = self.zoom_at(l, i, t)
  }
  menu.rise(t)
  menu.open.set(true)
  menu.tracking = tracking
  menu.in_rows = false
  menu.open_y = if tracking { Some(y) } else { None }
  menu.hovered_row = -1
  menu.cancel_dwell()
  menu.anchor_more = menu.active_row >= 0
  // (the glyphs keep the size the lens gave them for as long as the tab row is still seen fading away)
  menu.held_zoom = zooms
  menu.zoom_held = if zooms.iter().any(fn(z) { z != 1.0 }) { 1.0 } else { 0.0 }
  menu.zoom_close_from = 0.0
  // (the selection stays where it rests, under a lens that has not left it; else the indicator stands in for it)
  menu.pill0 = if !menu.anchor_more && lift <= handoff_lift { 1.0 } else { 0.0 }
  // (the bar lets its press go by itself: the lens no longer carries it)
  menu.press_down.put(press)
  menu.press_down.go(0.0, @motion.tab_press_down_spring, at=t)
  self.drop_lens(t)
  menu.start_indicator(t, cur, tracking, lift, lens, rest)
  @ui.haptic(TextHandleMove)
  menu.morph_open(t)
  menu.told_at = t
  // (what the menu's places open on asked from now: sfbase's places_ahead)
  @sfbase.places_menu_open(l.menu)
}

///|
/// The finger that opened the menu, if it is still down, has nothing more to say once the menu closes: what it does
/// until it lifts neither moves a lens nor chooses a tab (ShellTabBar.kt endMenuPress).
fn BarModel::end_menu_press(self : BarModel) -> Unit {
  let menu = bar_menu
  menu.tracking = false
  menu.open_y = None
  self.press_slot = -1
  menu.cancel_dwell()
}

///|
/// Folds the menu back into the bar from `t`, from wherever the glass has got to (ShellTabBar.kt closeMenu).
fn BarModel::close_menu(self : BarModel, t : Double) -> Unit {
  let menu = bar_menu
  if !menu.open.untracked() {
    return
  }
  let told = match self.told {
    Some(told) => told
    None => return
  }
  let l = bar_laid(told)
  let k = self.k_at(t)
  let cw = bar_capsule_w(l.w, k)
  let rest = bar_rest_selection(l, l.more_slot(), k)
  let cur = menu.ind_at(t, cw, rest)
  let p = menu.progress_at(t)
  // (a tab row already hidden has let the lens's zoom go: one that comes back shows its glyphs at their own size)
  if menu.tabs_shown_at(t) <= 0.001 {
    menu.zoom_held = 0.0
  }
  menu.open.set(false)
  self.end_menu_press()
  // (from here the rows leave together, by how far the glass has folded; one still rising goes on rising)
  menu.rows_closing = true
  menu.close_p = p
  menu.end_indicator(t, cur, rest, cw)
  menu.carry = -1.0
  menu.zoom_close_from = if menu.zoom_held > 0.0 { p } else { 0.0 }
  menu.morph_close(t)
  menu.told_at = t
  @sfbase.places_menu_open([])
}

///|
/// Takes the menu away at once, as when another layer comes over the tabs (ShellTabBar.kt dismissMenu).
fn BarModel::dismiss_menu(self : BarModel, t : Double) -> Unit {
  let menu = bar_menu
  if !menu.open.untracked() && !menu.busy_at(t) {
    return
  }
  menu.open.set(false)
  self.end_menu_press()
  menu.morph_rest()
  menu.rows_closing = true
  menu.leg = None
  menu.carry = -1.0
  menu.zoom_held = 0.0
  menu.press_down.put(0.0)
  menu.told_at = t
  @sfbase.places_menu_open([])
}

///|
/// Row `i` of the open menu picked at `t`: its page shown, the last slot standing for it from now, the menu folding
/// back with its indicator landing on that slot as the bar's selection (ShellTabBar.kt pickRow).
fn BarModel::pick_row(self : BarModel, i : Int, t : Double) -> Unit {
  let menu = bar_menu
  let told = match self.told {
    Some(told) => told
    None => return
  }
  let rows = bar_menu_of(told.flat)
  if i < 0 || i >= rows.length() {
    return
  }
  let place = rows[i]
  menu.picked_row = i
  menu.anchor_more = true
  self.close_menu(t)
  bar_more_shown(told.ws, place)
  if Some(place) != told.active {
    go_place(t, place, [told.flat], 0)
  }
}

///|
/// A finger of the open menu at (`x`, `y`) of the bar's node at `t`: the row under it pointed at, each row it moves on
/// to felt (ShellTabBar.kt trackMenu). The finger that opened the menu is on the tab row, under the bottom row: it
/// picks nothing until it moves up into the menu.
fn BarModel::track_menu(self : BarModel, x : Double, y : Double, t : Double) -> Unit {
  let menu = bar_menu
  match menu.open_y {
    Some(oy) => {
      if oy - y <= menu_reach / 2.0 {
        return
      }
      menu.open_y = None
      menu.open_row = -1
    }
    None => ()
  }
  let cw = match self.told {
    Some(told) => bar_capsule_w(told.width, self.k_at(t))
    None => 0.0
  }
  let row = bar_row_at(x, y, cw, menu.rows)
  if row != menu.hovered_row {
    menu.hovered_row = row
    if row >= 0 {
      menu.in_rows = true
      @ui.haptic(TextHandleMove)
      // a finger on a place's row: what the place opens on asked from now, as on a tab (sfbase's places_ahead)
      match self.told {
        Some(told) => {
          let rows = bar_menu_of(told.flat)
          if row < rows.length() {
            @sfbase.place_pressed(rows[row])
          }
        }
        None => ()
      }
    } else {
      // (off the rows: what the row left asked let go of, as a finger moved off a tab)
      @sfbase.place_press_lifted(t)
    }
  }
  menu.retarget(t)
}

///|
/// The menu's finger let go at (`x`, `y`) at `t`: lifted where it opened the menu, the menu stays open for a tap, its
/// indicator on the page shown, if any; on a row, that row picked; off the menu, the menu closed and nothing chosen
/// (ShellTabBar.kt releaseMenu).
fn BarModel::release_menu(self : BarModel, x : Double, y : Double, t : Double) -> Unit {
  let menu = bar_menu
  menu.tracking = false
  if menu.open_y is Some(_) {
    menu.open_y = None
    menu.open_row = -1
    menu.retarget(t)
    return
  }
  let cw = match self.told {
    Some(told) => bar_capsule_w(told.width, self.k_at(t))
    None => 0.0
  }
  let row = bar_row_at(x, y, cw, menu.rows)
  if row >= 0 {
    self.pick_row(row, t)
  } else {
    self.close_menu(t)
  }
}

///|
/// The bar told `told` at the moment `at` of what changed it (a page put on the stack or taken off, a place come in,
/// what the notch offers, the bars' order, the window), whatever frames are drawn after: its ways set out from then,
/// from where they are then; told the same again, nothing. A frame only reads where they are (bar_node.mbt).
/// (What a finger does on it is told so too, at each event's moment: bar_finger_did.)
fn bar_tell(told : BarTold, at : Double) -> Unit {
  let m = bar
  if m.told == Some(told) {
    return
  }
  let menu = bar_menu
  let prev_told = m.told
  let laid = bar_laid(told)
  // (another menu, or another width: the menu open or on its way is gone at once, as the bar it grew from is another)
  let same_bar = match prev_told {
    Some(p) => bar_menu_of(p.flat) == laid.menu && p.width == told.width && p.ws == told.ws
    None => true
  }
  if !same_bar {
    m.dismiss_menu(at)
  }
  m.told = Some(told)
  bar_told_now.set(Some(told))
  bar_laid_told.set(laid)
  bar_active_slot_told.set(laid.slot_of(told.active))
  menu.rows = laid.menu.length()
  menu.active_row = match told.active {
    Some(a) => laid.menu.search(a).unwrap_or(-1)
    None => -1
  }
  // (the last slot stands for the menu's page shown from now, till another of them is)
  match told.active {
    Some(a) if menu.active_row >= 0 => bar_more_shown(told.ws, a)
    _ => ()
  }
  let shown = told.shown
  let notched = told.action != ""
  // Force expand whenever leaving a root page or switching tabs
  let tab_changed = match prev_told {
    Some(p) => p.active != told.active
    None => false
  }
  if (!shown || tab_changed) && (m.collapsed || m.collapse.target() > 0.0) {
    m.collapsed = false
    m.scroll_acc = 0.0
    m.scroll_page_key = ""
    if @ui.reduced_motion() {
      m.collapse.put(0.0)
    } else {
      m.collapse.go(0.0, @motion.snappy_damped, at~)
    }
  }
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
  // going: the menu folded back, a finger's slide let go
  if !shown {
    m.close_menu(at)
    m.drag = -1.0
    m.press_slot = -1
    m.drag_last_x = -1.0
    m.drag_last_t = -1.0
    m.drag_speed_ref = 0.0
    m.drag_last_vx = 0.0
  }
  // (the page shown another while the bar is its menu: the indicator's and the selection's by where it is now)
  if menu.busy_at(at) {
    menu.anchor_more = menu.active_row >= 0
    menu.retarget(at)
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
  let items = laid.items
  // the ball: to the slot of the place shown, from where it is then, as stiff as the way there is short (a new
  // place's); a new width, or the bar its menu (the selection not seen), there at once. Under a finger, where the
  // finger has it. Not before the width is known.
  let ai = laid.slot_of(told.active)
  let active_key = told.active.unwrap_or("")
  let w = told.width
  let sliding = m.drag >= 0.0
  let prev_x = m.ball_x.value_at(at)
  let mut goal_x = m.ball_x.to
  if w > 0.0 {
    let final_cs = bar_centres(w, m.k_end(), items.length())
    goal_x = if sliding && items.length() > 0 {
      let lo = final_cs[0]
      let hi = final_cs[imin(items.length() - 1, final_cs.length() - 1)]
      if m.drag < lo {
        lo + bar_rubber(m.drag - lo, 12.0)
      } else if m.drag > hi {
        hi + bar_rubber(m.drag - hi, 12.0)
      } else {
        m.drag
      }
    } else {
      final_cs[if ai < 0 { 0 } else { ai }]
    }
    if (m.placed && m.width != w) || menu.busy_at(at) {
      m.ball_x.put(goal_x)
    } else if sliding {
      m.ball_x.go(goal_x, ball_drag_k, ball_drag_damping, at~)
    } else {
      m.ball_x.go(goal_x, ball_tap_k, ball_damping(ball_tap_k), at~)
    }
    m.width = w
  }
  if sliding {
    m.tap_pending_key = ""
    if !m.ball_held_active {
      // C0-continuous takeover if a cross-tab tap droplet is still active
      let cur_h = m.held_at(at)
      let cur_pill = m.pill_alpha_at(at)
      m.ball_held_up.put(cur_h)
      m.ball_held_up.go(1.0, @motion.liquid_lens_lift_spring, at~)
      m.ball_held_dn.put(0.0)
      // (the selection goes on fading from as much of it as shows now)
      m.ball_pill_dn.put(dclamp(cur_h - (1.0 - cur_pill), 0.0, 1.0))
      m.ball_pill_dn.go(0.0, @motion.liquid_lens_lift_spring, at~)
      m.tap_lens_up.put(0.0)
      m.tap_lens_dn.put(0.0)
      m.tap_pill_dn.put(0.0)
      m.flex_launch_fire_at = m.cancel_delayed_flex(m.flex_launch, m.flex_launch_fire_at, at)
      m.flex_brake_fire_at = m.cancel_delayed_flex(m.flex_brake, m.flex_brake_fire_at, at)
      m.lift_started_at = at
      m.ball_held_active = true
      m.pulse_flex_drag(0.045, at)
    }
  } else {
    if active_key != m.active_was {
      let from_tap = m.tap_pending_key != "" && active_key == m.tap_pending_key
      m.tap_pending_key = ""
      m.active_was = active_key
      if from_tap && m.placed && !menu.busy_at(at) {
        let trip = (goal_x - prev_x).abs()
        if trip > 4.0 {
          let hang_ms = dclamp(160.0 + trip * 0.25, 190.0, 240.0)
          let cur_tap = m.tap_lens_at(at)
          let cur_pill = dclamp(m.tap_lens_up.value_at(at) - m.tap_pill_dn.value_at(at), 0.0, 1.0)
          m.tap_lens_up.put(cur_tap)
          m.tap_lens_up.go(1.0, @motion.liquid_lens_lift_spring, at~)
          m.tap_lens_dn.put(0.0)
          m.tap_lens_dn.go(1.0, @motion.liquid_lens_lift_spring.delayed(hang_ms), at~)
          m.tap_pill_dn.put(dclamp(cur_tap - cur_pill, 0.0, 1.0))
          m.tap_pill_dn.go(1.0, @motion.tab_pill_in_spring.delayed(hang_ms), at~)
          let scale = dclamp(trip / 200.0, 0.45, 1.0)
          m.flex_launch_fire_at = m.schedule_delayed_flex(
            m.flex_launch,
            m.flex_launch_fire_at,
            40.0,
            0.16 * scale,
            at,
          )
          let brake_delay = dclamp(190.0 + trip * 0.20, 210.0, 260.0)
          m.flex_brake_fire_at = m.schedule_delayed_flex(
            m.flex_brake,
            m.flex_brake_fire_at,
            brake_delay,
            -0.16 * scale,
            at,
          )
        }
      }
    }
    if m.ball_held_active {
      m.ball_held_active = false
      if w <= 0.0 {
        m.ball_held_up.put(0.0)
        m.ball_held_dn.put(0.0)
        m.ball_pill_dn.put(0.0)
        m.lift_started_at = -1.0
        m.flex_wall.put(0.0)
      } else {
        let elapsed = if m.lift_started_at >= 0.0 {
          dmax(0.0, at - m.lift_started_at)
        } else {
          bar_lens_hang_ms
        }
        let hang_left = dmax(0.0, bar_lens_hang_ms - elapsed)
        let dist = (goal_x - prev_x).abs()
        let land_delay = if dist <= 4.0 {
          hang_left
        } else {
          dmax(hang_left, dclamp(dist / 2.2, 60.0, 180.0))
        }
        // Leave `ball_held_up` running so fast 40-100ms flicks finish lifting to 1.0 before unlifting
        m.ball_held_dn.go(1.0, @motion.liquid_lens_lift_spring.delayed(land_delay), at~)
        m.ball_pill_dn.go(1.0, @motion.tab_pill_in_spring.delayed(land_delay), at~)
        m.lift_started_at = -1.0
        let last_vx = m.drag_last_vx
        if dist > 8.0 || last_vx.abs() > 180.0 {
          let peak = -dclamp((last_vx.abs() / 900.0 + dist / 240.0) * 0.14, 0.05, 0.16)
          let brake_delay = dclamp(dist / 2.8, 30.0, 170.0)
          m.flex_brake_fire_at = m.schedule_delayed_flex(
            m.flex_brake,
            m.flex_brake_fire_at,
            brake_delay,
            peak,
            at,
          )
        } else {
          m.pulse_flex_drag(-0.025, at)
        }
        m.flex_wall.go(0.0, @motion.liquid_wall_flex_out_spring, at~)
      }
    }
  }
  // each slot's place lit as it is the one under the finger, else the one shown (300 ms, CSS's ease); one come anew as
  // it is
  let under = if w > 0.0 && sliding && items.length() > 0 {
    imin(items.length() - 1, nearest(bar_centres(w, m.k_at(at), items.length()), 4, m.drag))
  } else {
    -1
  }
  for i, key in items {
    let id = "bar:" + key
    let lit = if under >= 0 { under == i } else { ai == i }
    let on = if lit { 1.0 } else { 0.0 }
    match m.tints.get(id) {
      Some(g) => g.go(on, tint_ms, Out, at~)
      None => m.tints[id] = glide(on)
    }
  }
  // the ball shown where a slot of the bar is its place's
  let ball_shown = ai >= 0 || m.drag >= 0.0
  m.ball_alpha.go(if ball_shown { 1.0 } else { 0.0 }, ball_fade_ms, Out, at~)
  m.ball_scale.go(if ball_shown { 1.0 } else { 0.6 }, ball_grow_ms, Out, at~)
  // first laid out (its width known), or under reduced motion: everything where it goes, at once
  if w > 0.0 && (!m.placed || @ui.reduced_motion()) {
    m.placed = true
    m.jump()
  }
  // (a picture's menu, asked open before the bar was laid out: whole from here)
  if bar_open_wanted.val && w > 0.0 && shown && !laid.menu.is_empty() {
    bar_open_wanted.val = false
    m.open_menu(false, 0.0, at)
    menu.h.put(menu.full())
    menu.pinch.put(0.0)
    menu.press_down.put(0.0)
    menu.rise_at = -1.0
  }
  // (what reads its ways read again: bar_node)
  bar_said_again()
}

///|
/// Whether the bar's menu is to be open, whole, as the bar is first laid out: what a picture of it open asks
/// (fixture_open's `home-bars`), before there is a bar to open it on.
// kept across runs: said by a fixture, taken as the bar is first told
let bar_open_wanted : Ref[Bool] = Ref(false)

///|
/// The bar told again what it was told last, at the moment `at` of what the finger did on it (bar_finger_did), what
/// goes by where the finger has it set out from then.
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
/// The node the bar's own moments are asked of (a finger's rest on the last slot: bar_glass_node's hand).
// kept across runs: said again as the bar is made; one of a tree let go is no node of the tree that is now
let bar_timer_node : Ref[@view.View?] = Ref(None)

///|
/// What a finger on the bar's glass came to at `t`, at (`px`, `py`) of the bar's node (bar_glass_node's hand, and with
/// the menu open what is under the rest of the window: each event at its own moment, where the notch, the glass and
/// the ball are then by their ways, never where a frame last drew them), what it does told then (bar_retell). `off`:
/// it was called off; `vx`: how fast it went across (points a ms). `src`, `ws`: the workspace in view. Where the bar
/// is laid out is what it was told (bar_tell: BarLaid), the same the bar is drawn by. ShellTabBar.kt's pressBegan,
/// pressMoved, pressEnded and pressCancelled, by View::gesture's words.
fn bar_finger_did(
  src : Source,
  ws : Workspace,
  how : BarFingerIs,
  px : Double,
  py : Double,
  t : Double,
  off : Bool,
  vx : Double,
) -> Unit {
  ignore(src)
  ignore(ws)
  let m = bar
  let menu = bar_menu
  let told = match m.told {
    Some(t) => t
    None => return
  }
  let l = bar_laid(told)
  // Collapsed state: tapping or interacting with the left 56x56 orb expands the bar cleanly without triggering
  // another tab; empty space to its right is already excluded by `bar_glass_node`'s `.takes`.
  if m.collapsed || m.collapse_at(t) > 0.5 {
    if how is (Tapped | Ended) {
      @sfbase.place_press_lifted(t)
    }
    match how {
      Pressed => m.press_slot = -1
      Tapped | Held | Dragging | Ended =>
        if px >= 0.0 && px <= bar_track && py >= l.row_top - 4.0 {
          bar_set_collapsed(false, t)
        }
    }
    return
  }
  // the finger off the bar (lifted, called off): what its press asked ahead let go of now, or once the place it switches
  // to below has come in (sfbase's place_press_lifted, place_switched)
  if how is (Tapped | Ended) {
    @sfbase.place_press_lifted(t)
  }
  // the menu open: every finger is its (the one that opened it, still down, or one come down anywhere since)
  if menu.open.untracked() {
    match how {
      Pressed => {
        menu.tracking = true
        menu.in_rows = false
        menu.open_y = None
        m.track_menu(px, py, t)
      }
      Dragging | Held => if menu.tracking { m.track_menu(px, py, t) }
      Tapped => if menu.tracking { m.release_menu(px, py, t) }
      Ended =>
        if menu.tracking {
          if off {
            m.close_menu(t)
          } else {
            m.release_menu(px, py, t)
          }
        }
    }
    bar_retell(t)
    return
  }
  // (the menu this press opened has closed under it: the press chooses nothing more)
  if m.press_slot < 0 && !(how is Pressed) {
    m.drag = -1.0
    bar_retell(t)
    return
  }
  let n = l.items.length()
  let more = l.more_slot()
  let k_now = m.k_at(t)
  let cs = bar_centres(l.w, k_now, n)
  let slot_w = bar_item_w(l.w, k_now, n)
  let on_bar = py >= l.row_top - 4.0
  let active_slot = l.slot_of(told.active)
  // whether a finger from a tab is on the last slot, or past it beyond the bar's end, and near enough to the bar
  // (ShellTabBar.kt onMenuSlot)
  let on_menu_slot = fn(start : Int, x : Double, y : Double) {
    more >= 0 && start >= 0 && start < more && y > l.row_top - menu_slot_reach && x >= cs[more] - slot_w / 2.0
  }
  // another place chosen is felt once: a finger that moved on to its slot has had its tick there (ShellTabBar.kt
  // choose); the place shown tapped again (`again`: a tap, not a slide let go on it), its list back to its top where it
  // is away from it (the bar shows only over a place's root: sfdesk's list_back_to_top)
  let on_tab = fn(j : Int, again : Bool) {
    let place = l.items[j]
    if Some(place) != told.active {
      if m.ticked != j {
        @ui.haptic(TextHandleMove)
        m.ticked = j
      }
      go_place(t, place, [told.flat], 0)
    } else if again {
      @sfdesk.list_back_to_top() |> ignore
    }
  }
  match how {
    Pressed => {
      m.tap_pending_key = ""
      m.drag_last_x = px
      m.drag_last_t = t
      m.drag_speed_ref = 0.0
      m.drag_last_vx = 0.0
      menu.cancel_dwell()
      if n == 0 || !on_bar {
        m.press_slot = -1
      } else {
        let slot = imin(n - 1, nearest(cs, 4, px))
        // (a press on a tab while the menu is still folding away ends that at once: the bar is the bar under a
        // finger. Before the press is this slot's: ending the menu's press lets go of whatever slot was pressed)
        if slot != more {
          m.dismiss_menu(t)
        }
        m.press_slot = slot
        m.hovered = slot
        // (a finger that lands on a tab ticks nothing: the tab ticks once it is chosen)
        m.ticked = active_slot
        if slot == more {
          // a press on the last slot opens the menu at once, and the same finger can slide up to pick a row
          m.open_menu(true, py, t)
        } else {
          // a finger down on a place's tab: what the place opens on asked from now (sfbase's places_ahead)
          @sfbase.place_pressed(l.items[slot])
        }
      }
    }
    Dragging => {
      m.tap_pending_key = ""
      if n > 0 {
        let final_cs = bar_centres(l.w, m.k_end(), n)
        let lo = final_cs[0]
        let hi = final_cs[imin(n - 1, final_cs.length() - 1)]
        let over_edge = if px < lo {
          lo - px
        } else if px > hi {
          px - hi
        } else {
          0.0
        }
        if m.drag_last_t >= 0.0 && t > m.drag_last_t {
          let dt_s = (t - m.drag_last_t) / 1000.0
          let vx = if dt_s < 0.002 {
            m.drag_last_vx
          } else {
            dclamp((px - m.drag_last_x) / dt_s, -2400.0, 2400.0)
          }
          let spd = vx.abs()
          let v_new = if spd <= 1.0 {
            0.0
          } else {
            let alpha = 1.0 - @dmath.exp(-dt_s / 0.02)
            m.drag_speed_ref + alpha * (spd - m.drag_speed_ref)
          }
          let delta_v = v_new - m.drag_speed_ref
          m.drag_speed_ref = v_new
          let dv_flex = delta_v * bar_drag_flex_gain
          if (over_edge <= 0.0 || dv_flex < 0.0) && dv_flex.abs() > 0.00001 {
            let (_, cur_fv) = m.flex_drag.at(t)
            m.flex_drag.go(
              0.0,
              @motion.liquid_flex_spring,
              at=t,
              velocity=dclamp(cur_fv + dv_flex, -6.0, 6.0),
            )
          }
          m.drag_last_vx = vx
        }
        if over_edge > 0.0 {
          let wall_target = -0.18 * over_edge / (over_edge + 45.0)
          if (wall_target - m.flex_wall.target()).abs() > 0.0005 {
            m.flex_wall.go(wall_target, @motion.liquid_wall_flex_in_spring, at=t)
          }
        } else if m.flex_wall.target() != 0.0 {
          m.flex_wall.go(0.0, @motion.liquid_wall_flex_out_spring, at=t)
        }
        // each slot the finger moves on to ticks, as a detent does
        let under = imin(n - 1, nearest(cs, 4, px))
        if under != m.hovered {
          m.hovered = under
          m.ticked = under
          @ui.haptic(TextHandleMove)
        }
      }
      m.drag_last_x = px
      m.drag_last_t = t
      m.drag = px
      // resting on the last slot a moment opens the menu, and the same finger goes on to pick a row; until then the
      // lens can be dragged back
      if on_menu_slot(m.press_slot, px, py) {
        bar_arm_dwell(px, py, t)
      } else {
        menu.cancel_dwell()
      }
    }
    // held still where it went down, on the bar's row: the ball the finger's there, the lens over it as while it
    // slides (iOS's tab bar), going nowhere till the finger moves; let go, as a drag ends
    Held => {
      m.tap_pending_key = ""
      m.drag_last_x = px
      m.drag_last_t = t
      m.drag_speed_ref = 0.0
      m.drag_last_vx = 0.0
      if on_bar && n > 0 {
        m.drag = px
      }
    }
    Ended => {
      m.tap_pending_key = ""
      menu.cancel_dwell()
      let decayed_vx = if m.drag_last_t >= 0.0 {
        m.drag_last_vx * @dmath.exp(-dmax(0.0, (t - m.drag_last_t) / 1000.0) / 0.08)
      } else {
        0.0
      }
      let vx_s = vx * 1000.0
      let best_vx = if vx_s.abs() > decayed_vx.abs() { vx_s } else { decayed_vx }
      m.drag_last_vx = dclamp(best_vx, -2400.0, 2400.0)
      // (let go still moving across: the place it was going to, as it carried on (bar_flung); the ball, chasing the
      // finger, goes on there at the speed it had, never turned back short of it)
      let to_px = bar_flung(px, vx, l.w)
      let start = m.press_slot
      m.drag = -1.0
      m.press_slot = -1
      if off || n == 0 {
        // called off: nothing chosen, the lens back on the place shown
        ()
      } else if on_menu_slot(start, px, py) {
        // a lens let go on the last slot opens the menu, as a tap there does
        m.open_menu(false, py, t)
      } else {
        let j = imin(n - 1, nearest(cs, 4, to_px))
        if j == more {
          // carried on to the last slot: its menu where the finger was near enough to the bar; past the bar's end but
          // too far above it for the menu, the press chose nothing
          if py > l.row_top - menu_slot_reach && start != more {
            m.open_menu(false, py, t)
          }
        } else {
          on_tab(j, false)
        }
      }
    }
    Tapped => {
      menu.cancel_dwell()
      let start = m.press_slot
      m.drag = -1.0
      m.press_slot = -1
      // a tap: the place of the slot under it, where the slots are at `t` (the notch open as far as it is then)
      if start >= 0 && n > 0 && on_bar {
        let j = nearest(cs, n, px)
        if j != more && (cs[j] - px).abs() <= slot_w / 2.0 {
          if Some(l.items[j]) != told.active {
            m.tap_pending_key = l.items[j]
          }
          on_tab(j, true)
        }
      }
    }
  }
  // (what the finger did told at its moment: the ball, the lens, the places lit set out from then)
  bar_retell(t)
  if how is (Ended | Tapped) {
    m.drag_last_x = -1.0
    m.drag_last_t = -1.0
    m.drag_speed_ref = 0.0
    m.drag_last_vx = 0.0
  }
}

///|
/// A finger resting on the last slot at (`x`, `y`) at `t`: the menu opens once it has held still there
/// `menu_dwell_ms`; stirring further than `dwell_slop` starts the wait again (ShellTabBar.kt armDwell; the rest itself
/// mbui's: @view.Dwell).
fn bar_arm_dwell(x : Double, y : Double, t : Double) -> Unit {
  let node = match bar_timer_node.val {
    Some(n) => n
    None => return
  }
  bar_menu.dwell.at(node, x, y, t, fn(when, _, at_y) {
    if bar.press_slot >= 0 && !bar_menu.open.untracked() {
      bar.open_menu(true, at_y, when)
      bar_retell(when)
    }
  })
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
/// told (BarLaid: as wide as told, as high as its menu, over the system's navigation bar), the bar drawn in it
/// (bar_node: its notch's key the action's disc, its last slot and its menu's rows a key's and a screen reader's, none
/// of them a finger's), and the hand's on that node itself, which holds them all (so what is found on the bar, a place's
/// icon, a row's name, is found where a press there goes): one gesture for the whole bar, pressed while it shows, a
/// finger on it handed to the bar at each event's moment (bar_finger_did). Held still and let go without moving, as a
/// tap: the place under it (the bar's way before: held, the lens; let go, a place as any tap).
fn bar_glass_node(v : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  let told = fn() { bar_told_now.get() }
  // (whether this finger was held: let go after a hold without moving past the slop, a tap; let go past it with no move
  // told, a drag's end)
  let held = Ref(false)
  let did = fn(how : BarFingerIs, d : @view.Drag, x : Double, y : Double) {
    match ws() {
      Some(w) => bar_finger_did(src, w, how, x, y, d.at, d.kind is Off, d.vx())
      None => ()
    }
  }
  // the menu open: a finger down anywhere else is the menu's too (let go on a row it slid onto, that row; else the menu
  // folds back and nothing else is done); back folds it too, at the moment it is taken
  v.show(
    fn() {
      !@sfbase.first_page_waits.get() &&
      bar_menu.open.get() &&
      (match told() {
        Some(t) => t.shown
        None => false
      })
    },
    fn(m) {
      // (where a finger on it is in the bar's node: that node at the window's foot, `bar_inset_edge` in from its sides
      // and over the navigation bar by as much)
      let at_bar = fn(how : BarFingerIs, d : @view.Drag) {
        let panel = match bar.told {
          Some(t) => bar_laid(t).panel
          None => bar_track
        }
        did(how, d, d.x - bar_inset_edge, d.y - (d.h - bar_inset_edge - nav_foot() - panel))
      }
      m
      .over(Is(true))
      .gesture(
        @ui.touch_slop(),
        press=fn(d) { at_bar(Pressed, d) },
        tap=fn(d) { at_bar(Tapped, d) },
        drag=fn(d) {
          match d.kind {
            Down | Moved => at_bar(Dragging, d)
            _ => at_bar(Ended, d)
          }
        },
      )
      .takes_back(fn() {
        let at = m.cause_at()
        bar.close_menu(at)
        bar_retell(at)
      })
      |> ignore
    },
  )
  v.box(fn(b) {
    b
    .over(Is(true))
    .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
    .hides(By(fn() { @sfbase.first_page_waits.get() }))
    .padding(By(fn() { (bar_inset_edge, 0.0, bar_inset_edge, bar_inset_edge + nav_foot()) }))
    .presses(By(fn() {
      !@sfbase.first_page_waits.get() &&
      (match told() {
        Some(t) => t.shown
        None => false
      })
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
      // (a finger taken where the glass is drawn at its moment: the bar's track, up to the glass's top as far as it
      // has grown into the menu then; the action's circle its own where that takes a press; above it, what is under
      // the bar's; while scroll-collapsed, only the shrinking left capsule intercepts so the middle gap passes
      // through to the scrollable list underneath)
      .takes(fn(w, h, at) {
        match told() {
          Some(t) => {
            let c = bar.collapse_at(at)
            let k = bar.k_at(at)
            if c > 0.01 {
              [(0.0, bar_laid(t).row_top, bar_cur_capsule_w(w, k, c), h)]
            } else {
              let right = if bar_disc_takes(at) { bar_capsule_w(w, k) + act_gap / 2.0 } else { w }
              [(0.0, dmax(0.0, h - bar_menu.height_at(at)), right, h)]
            }
          }
          None => []
        }
      })
      .gesture(
        @ui.touch_slop(),
        press=fn(d) {
          held.val = false
          did(Pressed, d, d.x, d.y)
        },
        tap=fn(d) { did(Tapped, d, d.x, d.y) },
        hold=(bar_hold_ms, fn(d) {
          held.val = true
          did(Held, d, d.x, d.y)
        }),
        drag=fn(d) {
          match d.kind {
            Down | Moved => {
              held.val = false
              did(Dragging, d, d.x, d.y)
            }
            // (held still and let go without moving: a tap, as before)
            Up if held.val => did(Tapped, d, d.x, d.y)
            _ => did(Ended, d, d.x, d.y)
          }
        },
      )
      |> ignore
      bar_timer_node.val = Some(g)
      bar_node(g, src, ws)
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether the action's circle takes a press at `at`: drawn whole then, no finger on the bar, its menu shut.
fn bar_disc_takes(at : Double) -> Bool {
  bar.drag < 0.0 && bar.k_at(at) > 0.9 && !bar_menu.open.untracked()
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
