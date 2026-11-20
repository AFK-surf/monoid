// Boundary over-pull rubber-band resistance and drag-to-dismiss gesture helpers.
// Pure closed-form formulas plus a node-bound EdgePull spring state machine.

///|
/// Elastic resistance state for an edge dragged past its min/max limit:
/// pulls with hyperbolic damping (`past / (1 + |past| / limit)`) while dragged, tracks position `along` and `span`
/// along the boundary, and springs back to 0 on release.
pub struct EdgePull {
  priv aside : NodeWay
  priv limit : Double
  priv mut along : Double
  priv mut span : Double
  priv told : @signals.Signal[Int]
}

///|
/// Create an EdgePull at rest with hyperbolic asymptote `limit` (points).
pub fn EdgePull::new(limit? : Double = 6.0) -> EdgePull {
  { aside: NodeWay::new(0.0), limit, along: 0.0, span: 0.0, told: @signals.signal(0) }
}

///|
/// Update the over-pull displacement `past` (raw overshoot in points) at position `along` along a boundary of size
/// `span`. Applies hyperbolic damping so displacement asymptotically approaches `limit` and notifies readers when
/// `along` or `span` changes.
pub fn EdgePull::drag(self : EdgePull, past : Double, along : Double, span : Double) -> Unit {
  let aside = if self.limit > 0.0 {
    past / (1.0 + past.abs() / self.limit)
  } else {
    0.0
  }
  if self.along != along || self.span != span {
    self.along = along
    self.span = span
    self.told.set(self.told.untracked() + 1)
  }
  self.aside.put(aside)
}

///|
/// Release the over-pull and spring back to rest (`0.0`) from `v`'s cause moment.
pub fn EdgePull::let_go(self : EdgePull, v : @view.View, spec? : Spec = tactile_bounce) -> Unit {
  self.aside.go(v, 0.0, spec)
}

///|
/// Whether the edge is currently displaced (target != 0.0), without reading the frame clock.
pub fn EdgePull::taken(self : EdgePull) -> Bool {
  self.aside.target() != 0.0
}

///|
/// Current rendered `(aside, along, span)` on node `v`.
pub fn EdgePull::shown_on(self : EdgePull, v : @view.View) -> (Double, Double, Double) {
  self.told.get() |> ignore
  (self.aside.shown(v), self.along, self.span)
}

///|
/// Map a raw drag `delta` (positive along the dismiss direction) into a visual offset:
/// 1:1 tracking in the dismiss direction, and optional `rubber_band` resistance in the opposite direction.
pub fn dismiss_drag_offset(
  delta : Double,
  dimension : Double,
  resist_opposite? : Bool = true,
  coeff? : Double = 0.55,
) -> Double {
  if delta >= 0.0 {
    delta
  } else if resist_opposite {
    rubber_band(delta, dimension, coeff~)
  } else {
    delta
  }
}

///|
/// Decide whether a drag-to-dismiss gesture at `offset` moving at `velocity_per_s` (positive along the dismiss
/// direction) should dismiss:
/// - A high-speed fling back in the opposite direction (`velocity_per_s <= -velocity_threshold`) always keeps it.
/// - A high-speed fling in the dismiss direction (`velocity_per_s >= velocity_threshold`) always dismisses.
/// - Otherwise dismisses when `offset >= threshold`.
pub fn should_dismiss(
  offset : Double,
  velocity_per_s : Double,
  threshold : Double,
  velocity_threshold? : Double = 500.0,
) -> Bool {
  if velocity_threshold > 0.0 {
    if velocity_per_s <= -velocity_threshold {
      return false
    }
    if velocity_per_s >= velocity_threshold {
      return true
    }
  }
  offset >= threshold
}
