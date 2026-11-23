// Capillary liquid bridge hysteresis primitive for iOS 27 style liquid merge and split.
//
// Two glass bodies follow real capillary physics with strict hysteresis:
// - Separated -> Merged: strictly zero attraction (`merge == 0.0`) while `gap > contact_gap`;
//   only upon physical contact (`gap <= contact_gap`) does the bond flip to merged and bloom
//   `merge` from `0 -> merge_max` on an underdamped liquid spring.
// - Merged -> Separated: stretches a smooth liquid bridge across `0 < gap < break_gap`;
//   once `gap >= break_gap`, the bond irreversibly flips to separated and `merge` decays
//   to `0.0` on a critically damped spring (zero bounce, zero residual spike).
// - After splitting, no magnetic attraction occurs at any positive gap until physical contact
//   (`gap <= contact_gap`) happens again.
//
// All transitions are closed-form Ways, producing bit-identical results at 60/120/24/7 fps.

///|
/// State transition returned by `LiquidBond::update`.
#derive(Eq, Debug)
pub(all) enum BondEvent {
  Steady
  Fused
  Split
}

///|
/// Default liquid bloom spring on contact (`0 -> merge_max`).
// kept across runs: a constant value
pub let liquid_merge_spring : Spec = spring(ratio=0.78, stiffness=520.0, threshold=0.01)

///|
/// Default critically damped snap-off spring on split (`merge -> 0.0`, zero bounce).
// kept across runs: a constant value
pub let liquid_split_spring : Spec = spring(ratio=1.0, stiffness=1200.0, threshold=0.01)

///|
/// Default elastic recoil impulse spring on fuse/split.
// kept across runs: a constant value
pub let liquid_recoil_spring : Spec = spring(ratio=0.42, stiffness=560.0, threshold=0.001)

///|
/// Liquid snap-apart auto-separation glide spring after crossing `break_gap`.
// kept across runs: a constant value
pub let liquid_auto_split_spring : Spec = spring(ratio=0.82, stiffness=380.0, threshold=0.05)

///|
/// Liquid absorption glide spring after physical contact triggers `Fused`.
// kept across runs: a constant value
pub let liquid_auto_fuse_spring : Spec = spring(ratio=0.76, stiffness=420.0, threshold=0.05)

///|
/// Elastic return spring when a bonded liquid bridge is released before `break_gap`.
// kept across runs: a constant value
pub let liquid_snap_back_spring : Spec = spring(ratio=0.72, stiffness=460.0, threshold=0.05)

///|
/// Smooth programmatic split/merge glide spring.
// kept across runs: a constant value
pub let liquid_toggle_spring : Spec = spring(ratio=0.85, stiffness=260.0, threshold=0.05)

///|
/// Capillary liquid bridge hysteresis controller between two liquid glass bodies.
pub struct LiquidBond {
  priv mut bonded : Bool
  priv merge_max : Double
  priv break_gap : Double
  priv contact_gap : Double
  priv merge_spec : Spec
  priv split_spec : Spec
  priv recoil_spec : Spec
  priv merge_way : Way
  priv recoil_way : Way
}

///|
/// Creates a `LiquidBond` starting either `merged` (default `false`) or separated.
/// When `break_gap < 0.0`, it defaults to `merge_max * 0.45`.
pub fn LiquidBond::new(
  merged? : Bool = false,
  merge_max? : Double = 24.0,
  break_gap? : Double = -1.0,
  contact_gap? : Double = 0.0,
  merge_spec? : Spec = liquid_merge_spring,
  split_spec? : Spec = liquid_split_spring,
  recoil_spec? : Spec = liquid_recoil_spring,
) -> LiquidBond {
  let brk = if break_gap < 0.0 { merge_max * 0.45 } else { break_gap }
  {
    bonded: merged,
    merge_max,
    break_gap: brk,
    contact_gap,
    merge_spec,
    split_spec,
    recoil_spec,
    merge_way: Way::new(if merged { merge_max } else { 0.0 }),
    recoil_way: Way::new(0.0),
  }
}

///|
/// Whether the two glass bodies are currently bonded (merged).
pub fn LiquidBond::is_bonded(self : LiquidBond) -> Bool {
  self.bonded
}

///|
/// Maximum smooth-min merge radius when bonded.
pub fn LiquidBond::merge_max(self : LiquidBond) -> Double {
  self.merge_max
}

///|
/// Surface gap threshold at which a bonded liquid bridge snaps apart.
pub fn LiquidBond::break_gap(self : LiquidBond) -> Double {
  self.break_gap
}

///|
/// Surface gap threshold at or below which separated bodies physically contact and fuse.
pub fn LiquidBond::contact_gap(self : LiquidBond) -> Double {
  self.contact_gap
}

///|
/// Advances the hysteresis state for surface gap `gap` at moment `at` (ms).
/// Returns `Fused` on contact, `Split` on snapping past `break_gap`, or `None`.
#callsite(autofill(loc))
pub fn LiquidBond::update(
  self : LiquidBond,
  gap : Double,
  at~ : Double,
  loc~ : SourceLoc,
) -> BondEvent {
  if !self.bonded && gap <= self.contact_gap {
    self.bonded = true
    self.merge_way.go(self.merge_max, self.merge_spec, at~, loc~)
    self.recoil_way.go(0.0, self.recoil_spec, at~, velocity=5.5, loc~)
    Fused
  } else if self.bonded && gap >= self.break_gap {
    self.bonded = false
    self.merge_way.go(0.0, self.split_spec, at~, loc~)
    self.recoil_way.go(0.0, self.recoil_spec, at~, velocity=-6.5, loc~)
    Split
  } else {
    Steady
  }
}

///|
/// Resets the bond immediately to `merged` (true: `merge_max`, false: `0.0`) with zero recoil.
#callsite(autofill(loc))
pub fn LiquidBond::reset(self : LiquidBond, merged : Bool, loc~ : SourceLoc) -> Unit {
  self.bonded = merged
  self.merge_way.put(if merged { self.merge_max } else { 0.0 }, loc~)
  self.recoil_way.put(0.0, loc~)
}

///|
/// Smooth-min merge radius at moment `t` (ms). Clamps near-zero tail to exact `0.0` when separated.
pub fn LiquidBond::merge_at(self : LiquidBond, t : Double) -> Double {
  let m = self.merge_way.value_at(t)
  if !self.bonded && m < 0.05 {
    0.0
  } else {
    dmax(0.0, m)
  }
}

///|
/// Smooth-min merge radius as drawn on node `n`.
pub fn LiquidBond::merge_on(self : LiquidBond, n : @view.View) -> Double {
  let m = self.merge_way.shown_on(n)
  if !self.bonded && m < 0.05 {
    0.0
  } else {
    dmax(0.0, m)
  }
}

///|
/// Elastic recoil impulse value at moment `t` (ms).
pub fn LiquidBond::recoil_at(self : LiquidBond, t : Double) -> Double {
  self.recoil_way.value_at(t)
}

///|
/// Elastic recoil impulse value as drawn on node `n`.
pub fn LiquidBond::recoil_on(self : LiquidBond, n : @view.View) -> Double {
  self.recoil_way.shown_on(n)
}

///|
/// Moment (ms) when both merge and recoil ways are at rest.
pub fn LiquidBond::end(self : LiquidBond) -> Double {
  dmax(self.merge_way.end(), self.recoil_way.end())
}

///|
/// Finds the earliest moment in `[t0, t1]` where `gap_at(t)` satisfies `>= threshold` (`want_ge=true`)
/// or `<= threshold` (`want_ge=false`), using a 32-step coarse scan followed by 16 bisection iterations
/// (precision < 0.01ms over typical animations). Returns `None` if never crossed in `[t0, t1]`.
pub fn liquid_bond_cross_time(
  t0 : Double,
  t1 : Double,
  gap_at : (Double) -> Double,
  want_ge : Bool,
  threshold : Double,
) -> Double? {
  if t1 < t0 {
    return None
  }
  let hit = fn(g : Double) -> Bool {
    if want_ge {
      g >= threshold
    } else {
      g <= threshold
    }
  }
  if hit(gap_at(t0)) {
    return Some(t0)
  }
  if t1 == t0 {
    return None
  }
  let steps = 32
  let mut prev_t = t0
  for i in 1..<=steps {
    let cur_t = t0 + (t1 - t0) * (i.to_double() / steps.to_double())
    if hit(gap_at(cur_t)) {
      let mut lo = prev_t
      let mut hi = cur_t
      for _ in 0..<16 {
        let mid = (lo + hi) * 0.5
        if hit(gap_at(mid)) {
          hi = mid
        } else {
          lo = mid
        }
      }
      return Some(hi)
    }
    prev_t = cur_t
  }
  None
}

///|
/// Exact 2D surface-to-surface gap between two circles `(ax, ay, ar)` and `(bx, by, br)`.
/// Positive when separated, `0.0` at exact tangency, negative when overlapping.
pub fn circle_gap(
  ax : Double,
  ay : Double,
  ar : Double,
  bx : Double,
  by : Double,
  br : Double,
) -> Double {
  let dx = bx - ax
  let dy = by - ay
  (dx * dx + dy * dy).sqrt() - ar - br
}

///|
/// Horizontal surface gap between a left capsule ending at `a_right` and a right shape starting at `b_left`.
pub fn capsule_gap_x(a_right : Double, b_left : Double) -> Double {
  b_left - a_right
}

///|
/// Exact 2D surface-to-surface gap between two axis-aligned rounded rectangles.
/// Positive when separated, `0.0` at exact contact, negative when overlapping.
pub fn rounded_rect_gap(
  ax : Double,
  ay : Double,
  aw : Double,
  ah : Double,
  ar : Double,
  bx : Double,
  by : Double,
  bw : Double,
  bh : Double,
  br : Double,
) -> Double {
  let ra = dclamp(ar, 0.0, dmin(aw, ah) * 0.5)
  let rb = dclamp(br, 0.0, dmin(bw, bh) * 0.5)
  let a_x0 = ax + ra
  let a_x1 = ax + aw - ra
  let a_y0 = ay + ra
  let a_y1 = ay + ah - ra
  let b_x0 = bx + rb
  let b_x1 = bx + bw - rb
  let b_y0 = by + rb
  let b_y1 = by + bh - rb
  let dx = if b_x0 > a_x1 {
    b_x0 - a_x1
  } else if a_x0 > b_x1 {
    a_x0 - b_x1
  } else {
    0.0
  }
  let dy = if b_y0 > a_y1 {
    b_y0 - a_y1
  } else if a_y0 > b_y1 {
    a_y0 - b_y1
  } else {
    0.0
  }
  if dx > 0.0 || dy > 0.0 {
    (dx * dx + dy * dy).sqrt() - ra - rb
  } else {
    let ox = dmin(a_x1, b_x1) - dmax(a_x0, b_x0)
    let oy = dmin(a_y1, b_y1) - dmax(a_y0, b_y0)
    -dmin(ox, oy) - ra - rb
  }
}
