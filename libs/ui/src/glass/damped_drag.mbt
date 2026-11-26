// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/utils/DampedDragAnimation.kt. A value dragged along a
// range and the glass that follows it: the value by a stiff spring (1, 1000), how fast it goes by a soft one (0.5, 300),
// how far it is held (1, 1000) and how large it is drawn across and down (0.6 and 0.7, 250), each a closed-form way of
// mbui's (@motion.NodeWay), set off from the moment of its cause and drawn where it is at the moment it is drawn: no
// frame loop, so a run is the same at any frame rate.
//
// Kotlin's coroutines become moments on the node's timeline: `release` lets go once the value is within 2.5% of its
// range of where it goes (snapshotFlow's filter), at the moment its way says it is (worked out from its way, not
// watched); the speed is the finger's (the value's change over the time between two drags, VelocityTracker's), eased
// by its spring, and eased to nothing at the moment the value comes to rest.

///|
/// The value spring's (DampedDragAnimation's valueAnimationSpec) at `threshold`.
fn value_spring(threshold : Double) -> @motion.Spec {
  @motion.spring(ratio=1.0, stiffness=1000.0, threshold~) // det-ok(motion-spring): DampedDragAnimation.kt valueAnimationSpec, ported 1:1
}

///|
/// The speed's spring (velocityAnimationSpec): soft, at rest within ten times the value's threshold.
fn speed_spring(threshold : Double) -> @motion.Spec {
  @motion.spring(ratio=0.5, stiffness=300.0, threshold=threshold * 10.0) // det-ok(motion-spring): DampedDragAnimation.kt velocityAnimationSpec, ported 1:1
}

///|
/// A value dragged along `lo` … `hi` and the glass that follows it (DampedDragAnimation): bound to the node whose
/// timeline its ways run on (`attach`), then pressed, dragged and let go by its control.
// letting_go_scheduled and stilling_scheduled are read only by whitebox tests.
#warnings("-unused_field")
pub struct DampedDrag {
  priv mut lo : Double
  priv mut hi : Double
  priv threshold : Double
  priv rest_scale : Double
  priv held_scale : Double
  priv value : @motion.NodeWay
  priv speed : @motion.NodeWay
  priv press : @motion.NodeWay
  priv scale_x : @motion.NodeWay
  priv scale_y : @motion.NodeWay
  priv node : Ref[@view.View?]
  priv active_driver : Ref[@view.View?]
  priv gest_owner : Ref[@view.View?]
  priv gest_seq : @signals.Signal[Int]
  priv last : Ref[(Double, Double)?]
  priv letting_go : Ref[(() -> Unit)?]
  priv stilling : Ref[(() -> Unit)?]
  priv last_release : Ref[(Double, Bool)]
  priv mut letting_go_scheduled : Int
  priv mut stilling_scheduled : Int
}

///|
/// At `initial` along `lo` … `hi`, resting within `threshold`, drawn `rest_scale` times as large at rest and
/// `held_scale` held.
pub fn DampedDrag::new(
  initial : Double,
  lo~ : Double,
  hi~ : Double,
  threshold? : Double = 0.001,
  rest_scale? : Double = 1.0,
  held_scale~ : Double,
) -> DampedDrag {
  let v = clamp(initial, lo, hi)
  {
    lo,
    hi,
    threshold,
    rest_scale,
    held_scale,
    value: @motion.NodeWay::new(v),
    speed: @motion.NodeWay::new(0.0),
    press: @motion.NodeWay::new(0.0),
    scale_x: @motion.NodeWay::new(rest_scale),
    scale_y: @motion.NodeWay::new(rest_scale),
    node: Ref(None),
    active_driver: Ref(None),
    gest_owner: Ref(None),
    gest_seq: @signals.signal(0),
    last: Ref(None),
    letting_go: Ref(None),
    stilling: Ref(None),
    last_release: Ref((0.025, false)),
    letting_go_scheduled: 0,
    stilling_scheduled: 0,
  }
}

///|
/// Its ways run on `n`'s timeline from now on (its control's node).
pub fn DampedDrag::attach(self : DampedDrag, n : @view.View) -> Unit {
  let same = match self.node.val {
    Some(cur) => physical_equal(cur, n)
    None => false
  }
  if same {
    return
  }
  let had_release = self.letting_go.val is Some(_)
  self.cancel_release()
  self.cancel_still()
  self.last.val = None
  self.clear_gest_owner()
  self.node.val = Some(n)
  if had_release {
    if n.alive() {
      let (wf, rel) = self.last_release.val
      self.release(within_frac=wf, relative_trip=rel)
    } else {
      self.drop_lens()
    }
  } else if @signals.untracked(fn() { self.pressing() }) {
    self.drop_lens()
  }
}

///|
/// Attach `self` to `n` only when it does not already have a live host view.
fn DampedDrag::attach_if_needed(self : DampedDrag, n : @view.View) -> Unit {
  match self.node.val {
    Some(cur) if cur.alive() => ()
    _ => self.attach(n)
  }
}

///|
/// Claim active gesture ownership for `owner` so unrelated hosts sharing this drag never cancel its lens.
pub fn DampedDrag::claim_gesture(self : DampedDrag, owner : @view.View) -> Unit {
  self.active_driver.val = Some(owner)
  self.gest_owner.val = Some(owner)
}

///|
/// Whether `owner` is the current gesture owner (by reference identity).
pub fn DampedDrag::gesture_owned_by(self : DampedDrag, owner : @view.View) -> Bool {
  match self.gest_owner.val {
    Some(cur) => physical_equal(cur, owner)
    None => false
  }
}

///|
/// Whether `owner` owns this drag's lens display (active gesture owner, or attached host when no gesture claimed).
fn DampedDrag::lens_owned_by(self : DampedDrag, owner : @view.View) -> Bool {
  match self.gest_owner.val {
    Some(cur) => physical_equal(cur, owner)
    None => self.same_host(Some(owner))
  }
}

///|
/// Whether another live host view currently owns an active gesture on this drag (including lens-less modes).
fn DampedDrag::gesture_active_elsewhere(self : DampedDrag, owner : @view.View) -> Bool {
  match self.gest_owner.val {
    Some(cur) => !physical_equal(cur, owner) && cur.alive()
    None => false
  }
}

///|
/// Clear gesture ownership and notify any sibling hosts waiting for gesture release.
fn DampedDrag::clear_gest_owner(self : DampedDrag) -> Unit {
  if self.gest_owner.val is Some(_) {
    self.gest_owner.val = None
    self.gest_seq.set(self.gest_seq.untracked() + 1)
  }
}

///|
/// Reactive generation counter bumped whenever gesture ownership or host attachment is released.
fn DampedDrag::gesture_gen(self : DampedDrag) -> Int {
  self.gest_seq.get()
}

///|
/// Claim active control driver ownership for `owner` (distinct from timeline-anchor `node`).
fn DampedDrag::claim_driver(self : DampedDrag, owner : @view.View) -> Unit {
  self.active_driver.val = Some(owner)
}

///|
/// Whether another live control host view is currently driving this drag.
fn DampedDrag::has_other_host(self : DampedDrag, owner : @view.View) -> Bool {
  match self.active_driver.val {
    Some(cur) => !physical_equal(cur, owner) && cur.alive()
    None => false
  }
}

///|
/// Explicitly relinquish driver ownership, host attachment, and gesture ownership for `owner`
/// (e.g. when hidden or unmounted), waking sibling hosts waiting to replay a deferred sync.
fn DampedDrag::relinquish_host(self : DampedDrag, owner : @view.View) -> Unit {
  let mut changed = false
  match self.active_driver.val {
    Some(cur) if physical_equal(cur, owner) => {
      self.active_driver.val = None
      changed = true
    }
    _ => ()
  }
  if self.same_host(Some(owner)) {
    self.node.val = None
    changed = true
  }
  if self.gesture_owned_by(owner) {
    self.gest_owner.val = None
    changed = true
  }
  if changed {
    self.gest_seq.set(self.gest_seq.untracked() + 1)
  }
}

///|
/// Release gesture ownership for `owner` when no lens press or deferred release remains active.
fn DampedDrag::end_gesture(self : DampedDrag, owner : @view.View) -> Unit {
  if self.gesture_owned_by(owner) && !@signals.untracked(fn() { self.pressing() }) && !self.has_pending_release() {
    self.clear_gest_owner()
  }
}

///|
/// Whether a deferred `letting_go` lens-release timer is currently scheduled.
pub fn DampedDrag::has_pending_release(self : DampedDrag) -> Bool {
  self.letting_go.val is Some(_)
}

///|
/// The host view whose timeline this drag is currently attached to, if any.
pub fn DampedDrag::host_node(self : DampedDrag) -> @view.View? {
  self.node.val
}

///|
/// Whether this drag is still attached to the exact same host view `other` (by reference identity).
pub fn DampedDrag::same_host(self : DampedDrag, other : @view.View?) -> Bool {
  match (self.node.val, other) {
    (Some(a), Some(b)) => physical_equal(a, b)
    (None, None) => true
    _ => false
  }
}

///|
/// Immediately drop any held or pending lens without scheduling any timer (used on `glass_solid`
/// fallback or dead-host recovery).
pub fn DampedDrag::drop_lens(self : DampedDrag) -> Unit {
  self.cancel_release()
  self.clear_gest_owner()
  self.press.put(0.0)
  self.scale_x.put(self.rest_scale)
  self.scale_y.put(self.rest_scale)
}

///|
/// Update the drag bounds (for controls whose item count may change dynamically).
pub fn DampedDrag::set_bounds(self : DampedDrag, lo~ : Double, hi~ : Double) -> Unit {
  self.lo = lo
  self.hi = hi
}

///|
fn DampedDrag::at(self : DampedDrag) -> @view.View {
  match self.node.val {
    Some(n) => n
    None => @halt.saying("sf/glass: a DampedDrag moved before it was attached to its node")
  }
}

///|
/// Where its value is as `n` is drawn.
pub fn DampedDrag::value(self : DampedDrag, n : @view.View) -> Double {
  self.value.shown(n)
}

///|
/// How far along its range its value is as `n` is drawn (0 at `lo`, 1 at `hi`).
pub fn DampedDrag::progress(self : DampedDrag, n : @view.View) -> Double {
  let span = self.hi - self.lo
  if span <= 0.0 {
    0.0
  } else {
    (self.value.shown(n) - self.lo) / span
  }
}

///|
/// Where its value goes (targetValue), followed.
pub fn DampedDrag::target(self : DampedDrag) -> Double {
  self.value.target()
}

///|
/// How far it is held as `n` is drawn (pressProgress: 0 at rest, 1 held).
pub fn DampedDrag::pressed(self : DampedDrag, n : @view.View) -> Double {
  self.press.shown(n)
}

///|
/// Whether the lens press target is currently raised (true on the cause frame of `press` / `animate_to`).
pub fn DampedDrag::pressing(self : DampedDrag) -> Bool {
  self.press.target() > 0.001
}

///|
/// How fast its value goes as `n` is drawn, in its ranges a second (velocity).
pub fn DampedDrag::velocity(self : DampedDrag, n : @view.View) -> Double {
  self.speed.shown(n)
}

///|
/// How large its glass is drawn across and down as `n` is drawn, squeezed symmetrically by how fast it goes
/// regardless of direction: `v = |speed / per|`, across `scaleX / (1 - clamp(v × 0.75, 0, 0.2))`, down
/// `scaleY × (1 - clamp(v × 0.25, 0, 0.2))`.
pub fn DampedDrag::jelly(self : DampedDrag, n : @view.View, per : Double) -> (Double, Double) {
  let v = (self.speed.shown(n) / per).abs()
  let sx = self.scale_x.shown(n) / (1.0 - clamp(v * 0.75, 0.0, 0.2))
  let sy = self.scale_y.shown(n) * (1.0 - clamp(v * 0.25, 0.0, 0.2))
  (sx, sy)
}

///|
/// Held (press): its glass comes up and grows, its speed reset and tracked anew.
pub fn DampedDrag::press(self : DampedDrag) -> Unit {
  let n = self.at()
  self.cancel_release()
  self.cancel_still()
  self.last.val = None
  self.speed.go(n, 0.0, speed_spring(self.threshold))
  self.press.go(n, 1.0, @motion.backdrop_press_spring)
  self.scale_x.go(n, self.held_scale, @motion.backdrop_scale_x_spring)
  self.scale_y.go(n, self.held_scale, @motion.backdrop_scale_y_spring)
}

///|
fn DampedDrag::cancel_release(self : DampedDrag) -> Unit {
  match self.letting_go.val {
    Some(f) => {
      self.letting_go.val = None
      f()
    }
    None => ()
  }
}

///|
fn DampedDrag::cancel_still(self : DampedDrag) -> Unit {
  match self.stilling.val {
    Some(f) => {
      self.stilling.val = None
      f()
    }
    None => ()
  }
}

///|
/// Let go (release): its glass goes down and back to its size once its value is within `within_frac` of its range
/// (or of the remaining trip when `relative_trip=true`) of where it goes, at once where it is already. Early-exits
/// with 0 timers when no lens is raised.
pub fn DampedDrag::release(
  self : DampedDrag,
  within_frac? : Double = 0.025,
  relative_trip? : Bool = false,
) -> Unit {
  let n = self.at()
  self.cancel_release()
  let now = n.cause_at()
  if !self.pressing() && self.press.value_at(now) <= 0.001 {
    self.clear_gest_owner()
    return
  }
  self.last_release.val = (within_frac, relative_trip)
  let aim = self.value.target()
  let down = fn() {
    self.clear_gest_owner()
    self.press.go(n, 0.0, @motion.backdrop_press_spring)
    self.scale_x.go(n, self.rest_scale, @motion.backdrop_scale_x_spring)
    self.scale_y.go(n, self.rest_scale, @motion.backdrop_scale_y_spring)
  }
  let within = if relative_trip {
    let dist = (aim - self.value.value_at(now)).abs()
    if dist <= self.threshold {
      down()
      return
    }
    dist * within_frac
  } else {
    (self.hi - self.lo) * within_frac
  }
  let near = fn(t : Double) { (self.value.value_at(t) - aim).abs() < within }
  if near(now) || !self.value.goes_at(now) {
    down()
    return
  }
  // (the first whole millisecond its way is near, read off the way itself: it ends near, at the latest)
  let end = self.value.end()
  let mut t = now
  while t < end && !near(t) {
    t += 1.0
  }
  self.letting_go_scheduled += 1
  let stop = n.at_moment(t, fn() {
    self.letting_go.val = None
    down()
  })
  self.letting_go.val = Some(stop)
}

///|
/// Its value sent towards `v` (updateValue, held within its range): followed by its spring, and its speed by the
/// change since the last such over the time between them.
pub fn DampedDrag::update_value(self : DampedDrag, v : Double, spec? : @motion.Spec) -> Unit {
  let n = self.at()
  let to = clamp(v, self.lo, self.hi)
  let now = n.cause_at()
  let span = self.hi - self.lo
  match self.last.val {
    Some((was, at)) if now > at && span > 0.0 => {
      let fast = (to - was) / ((now - at) / 1000.0) / span
      self.speed.go(n, fast, speed_spring(self.threshold))
    }
    _ => ()
  }
  self.last.val = Some((to, now))
  let sp = match spec {
    Some(s) => s
    None => value_spring(self.threshold)
  }
  self.value.go(n, to, sp)
  self.still_at_rest(n)
}

///|
/// Its speed eased to nothing at the moment its value comes to rest (VelocityTracker reading a still value).
fn DampedDrag::still_at_rest(self : DampedDrag, n : @view.View) -> Unit {
  self.cancel_still()
  let end = self.value.end()
  self.stilling_scheduled += 1
  self.stilling.val = Some(
    n.at_moment(end, fn() {
      self.stilling.val = None
      self.last.val = None
      self.speed.go(n, 0.0, speed_spring(self.threshold))
    }),
  )
}

///|
/// Settle smoothly to `v`, easing velocity to 0 and releasing any held lens without raising it.
pub fn DampedDrag::settle_to(
  self : DampedDrag,
  v : Double,
  spec? : @motion.Spec,
  within_frac? : Double = 0.025,
  relative_trip? : Bool = false,
) -> Unit {
  let n = self.at()
  self.cancel_still()
  self.last.val = None
  let to = clamp(v, self.lo, self.hi)
  let sp = match spec {
    Some(s) => s
    None => value_spring(self.threshold)
  }
  self.value.go(n, to, sp)
  self.speed.go(n, 0.0, speed_spring(self.threshold))
  self.release(within_frac~, relative_trip~)
}

///|
/// Sent to `v` as by a hand that pressed it there and let go (animateToValue): held, its value sent there, its speed
/// eased to nothing, let go.
pub fn DampedDrag::animate_to(
  self : DampedDrag,
  v : Double,
  within_frac? : Double = 0.025,
  relative_trip? : Bool = false,
) -> Unit {
  self.press()
  self.settle_to(v, within_frac~, relative_trip~)
}

///|
/// Sent smoothly to `v` without pressing or scaling (external/programmatic selection change):
/// only its value slides to `v` on the value spring while `press` and `scale` stay at rest.
/// If a deferred lens release is already pending and the target changes, reschedules it using `last_release`.
pub fn DampedDrag::slide_to(self : DampedDrag, v : Double, spec? : @motion.Spec) -> Unit {
  let n = self.at()
  let had_release = self.letting_go.val is Some(_)
  let prev_target = self.value.target()
  self.cancel_still()
  self.last.val = None
  let to = clamp(v, self.lo, self.hi)
  let sp = match spec {
    Some(s) => s
    None => value_spring(self.threshold)
  }
  self.value.go(n, to, sp)
  self.speed.go(n, 0.0, speed_spring(self.threshold))
  if had_release && (to - prev_target).abs() > 0.0 {
    let (wf, rel) = self.last_release.val
    self.release(within_frac=wf, relative_trip=rel)
  }
}

///|
/// Gesture cancelled: slide smoothly back to `v`, ease velocity to 0, and release any held lens.
pub fn DampedDrag::cancel_to(
  self : DampedDrag,
  v : Double,
  spec? : @motion.Spec,
  within_frac? : Double = 0.025,
  relative_trip? : Bool = false,
) -> Unit {
  self.settle_to(v, spec?, within_frac~, relative_trip~)
}
