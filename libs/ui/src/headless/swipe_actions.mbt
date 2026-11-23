// Swipe actions: horizontal swipe-to-reveal gesture state machine for list rows.
// Distinguishes horizontal swipes from vertical list scrolling via axis locking past `slop`, applies rubber-band
// resistance past the revealed action width, and snaps open or closed on release based on displacement ratio or
// horizontal fling velocity (points/sec). Draws nothing and lays out nothing.

///|
/// Which side's swipe actions are revealed (`Left` when dragged right, `Right` when dragged left).
#derive(Eq, Debug)
pub(all) enum SwipeSide {
  Left
  Right
}

///|
/// Headless swipe-actions controller bound to a row node via `SwipeActions::bind`.
pub struct SwipeActions {
  priv left_width : Double
  priv right_width : Double
  priv threshold : Double
  priv velocity_threshold : Double
  priv slop : Double
  priv disabled_ : () -> Bool
  priv on_open_ : (SwipeSide?) -> Unit
  priv offset_ : @signals.Signal[Double]
  priv open_side_ : @signals.Signal[SwipeSide?]
  priv dragging_ : @signals.Signal[Bool]
}

///|
/// Create a `SwipeActions` controller.
/// `left_width` / `right_width`: revealed widths (points) for left and right action trays.
/// `threshold`: fraction of tray width required to snap open on a slow release (default `0.4`).
/// `velocity_threshold`: horizontal release velocity (points/second) that triggers a flick open/close (default `400.0`).
/// `slop`: movement (points) before locking onto the horizontal or vertical axis (default `6.0`).
pub fn SwipeActions::new(
  left_width? : Double = 0.0,
  right_width? : Double = 0.0,
  threshold? : Double = 0.4,
  velocity_threshold? : Double = 400.0,
  slop? : Double = 6.0,
  disabled? : () -> Bool = fn() { false },
  on_open? : (SwipeSide?) -> Unit = fn(_) {  },
) -> SwipeActions {
  {
    left_width: if left_width > 0.0 { left_width } else { 0.0 },
    right_width: if right_width > 0.0 { right_width } else { 0.0 },
    threshold,
    velocity_threshold,
    slop: if slop > 0.0 { slop } else { 0.0 },
    disabled_: disabled,
    on_open_: on_open,
    offset_: @signals.signal(0.0),
    open_side_: @signals.signal(None),
    dragging_: @signals.signal(false),
  }
}

///|
/// Current horizontal offset in points: positive exposes left actions, negative exposes right actions. Followed.
pub fn SwipeActions::offset(self : SwipeActions) -> Double {
  self.offset_.get()
}

///|
/// Currently snapped-open side, or `None` when closed. Followed.
pub fn SwipeActions::open_side(self : SwipeActions) -> SwipeSide? {
  self.open_side_.get()
}

///|
/// Whether the user is actively dragging horizontally right now. Followed.
pub fn SwipeActions::dragging(self : SwipeActions) -> Bool {
  self.dragging_.get()
}

///|
fn SwipeActions::set_snapped(self : SwipeActions, side : SwipeSide?) -> Unit {
  let target = match side {
    Some(Left) => self.left_width
    Some(Right) => -self.right_width
    None => 0.0
  }
  self.offset_.set(target)
  let prev = self.open_side_.untracked()
  if prev != side {
    self.open_side_.set(side)
    (self.on_open_)(side)
  }
}

///|
/// Programmatically open `side` (no-op when that side has zero width or the control is disabled).
pub fn SwipeActions::open(self : SwipeActions, side : SwipeSide) -> Unit {
  if @signals.untracked(self.disabled_) {
    return
  }
  match side {
    Left if self.left_width > 0.0 => self.set_snapped(Some(Left))
    Right if self.right_width > 0.0 => self.set_snapped(Some(Right))
    _ => ()
  }
}

///|
/// Programmatically close any open action tray back to offset `0.0`.
pub fn SwipeActions::close(self : SwipeActions) -> Unit {
  self.set_snapped(None)
}

///|
fn swipe_rubber_band(over : Double) -> Double {
  if over <= 0.0 {
    0.0
  } else {
    over * 0.35 / (1.0 + over / 120.0)
  }
}

///|
fn SwipeActions::apply_offset(self : SwipeActions, raw : Double) -> Double {
  if raw > self.left_width {
    if self.left_width > 0.0 {
      self.left_width + swipe_rubber_band(raw - self.left_width)
    } else {
      0.0
    }
  } else if raw < -self.right_width {
    if self.right_width > 0.0 {
      -(self.right_width + swipe_rubber_band(-raw - self.right_width))
    } else {
      0.0
    }
  } else {
    raw
  }
}

///|
/// Attach horizontal swipe gesture handling (`on_drag`) to `v`.
/// Locks horizontally only when `|dx| > |dy|` past `slop`, leaving vertical gestures free for list scrolling.
pub fn SwipeActions::bind(self : SwipeActions, v : @view.View) -> Unit {
  let able = fn() { !(self.disabled_)() }
  let start_wx = Ref(0.0)
  let start_wy = Ref(0.0)
  let start_offset = Ref(0.0)
  // 0 = undecided, 1 = locked horizontal, -1 = locked vertical (ignored)
  let axis = Ref(0)
  v
  .presses(By(able))
  .on_drag(fn(d) {
    if (self.disabled_)() || (self.left_width <= 0.0 && self.right_width <= 0.0) {
      if axis.val == 1 {
        axis.val = 0
        self.dragging_.set(false)
        self.set_snapped(self.open_side_.untracked())
      }
      return
    }
    match d.kind {
      Down => {
        start_wx.val = d.wx
        start_wy.val = d.wy
        start_offset.val = self.offset_.untracked()
        axis.val = 0
      }
      Moved => {
        let dx = d.wx - start_wx.val
        let dy = d.wy - start_wy.val
        if axis.val == 0 {
          let ax = dx.abs()
          let ay = dy.abs()
          if ax >= self.slop || ay >= self.slop {
            if ax > ay {
              axis.val = 1
              self.dragging_.set(true)
            } else {
              axis.val = -1
            }
          }
        }
        if axis.val == 1 {
          self.offset_.set(self.apply_offset(start_offset.val + dx))
        }
      }
      Up => {
        if axis.val == 1 {
          self.dragging_.set(false)
          let cur = self.offset_.untracked()
          let vx_ps = d.vx() * 1000.0
          let target : SwipeSide? = if vx_ps >= self.velocity_threshold {
            if start_offset.val < 0.0 && cur <= 0.0 {
              None
            } else if self.left_width > 0.0 {
              Some(Left)
            } else {
              None
            }
          } else if vx_ps <= -self.velocity_threshold {
            if start_offset.val > 0.0 && cur >= 0.0 {
              None
            } else if self.right_width > 0.0 {
              Some(Right)
            } else {
              None
            }
          } else if self.left_width > 0.0 && cur >= self.left_width * self.threshold {
            Some(Left)
          } else if self.right_width > 0.0 && cur <= -(self.right_width * self.threshold) {
            Some(Right)
          } else {
            None
          }
          self.set_snapped(target)
        }
        axis.val = 0
      }
      Off => {
        if axis.val == 1 {
          self.dragging_.set(false)
          self.set_snapped(self.open_side_.untracked())
        }
        axis.val = 0
      }
    }
  })
  |> ignore
}
