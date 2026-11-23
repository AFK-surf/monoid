// Drawer / Sheet: edge-docked overlay with drag-to-dismiss and multi-snap-point state machine.
// Joins the shared tree `overlay_stack` via `overlay_join` and `overlay_wire_dismiss` (interoperating cleanly with
// Dialog and Popover for Escape, Back, and outside-press layering). `Drawer::handle` binds edge-aware drag gestures
// gated by `can_drag` (scroll handoff guard). Draws nothing and lays out nothing.

///|
/// Which edge of the viewport the drawer is docked to.
#derive(Eq, Debug)
pub(all) enum DrawerEdge {
  Bottom
  Top
  Left
  Right
}

///|
/// Asymptotic rubber-band over-pull displacement when dragging past the maximum snap point.
pub fn drawer_rubber_pull(over : Double, max_pull : Double) -> Double {
  if over <= 0.0 || max_pull <= 0.0 {
    0.0
  } else {
    max_pull * (1.0 - 1.0 / (1.0 + over / (max_pull * 2.0)))
  }
}

///|
/// A headless drawer as its look reads it and attaches its drag handle by (`Drawer::handle`).
pub struct Drawer {
  priv node_ : @view.View
  priv edge_ : DrawerEdge
  priv now : () -> Bool
  priv close_ : () -> Unit
  priv snaps : Array[Double]
  priv active_snap_ : () -> Int
  priv on_snap_ : (Int) -> Unit
  priv dismiss_threshold : Double
  priv velocity_threshold : Double
  priv overpull_max : Double
  priv on_release_ : (Double, Double, Bool) -> Unit
  priv can_drag_ : () -> Bool
  priv drag_offset_ : @signals.Signal[Double]
  priv dragging_ : @signals.Signal[Bool]
  priv last_velocity_ : Ref[Double]
}

///|
/// Whether the drawer is open now (as its caller says).
pub fn Drawer::open(self : Drawer) -> Bool {
  (self.now)()
}

///|
/// The edge this drawer is docked to.
pub fn Drawer::edge(self : Drawer) -> DrawerEdge {
  self.edge_
}

///|
/// The drawer's root node.
pub fn Drawer::node(self : Drawer) -> @view.View {
  self.node_
}

///|
/// Current live drag displacement in points along the dismiss direction (positive toward dismissal, negative toward a
/// larger snap point; `0.0` at rest). Followed where a binding reads it.
pub fn Drawer::drag_offset(self : Drawer) -> Double {
  self.drag_offset_.get()
}

///|
/// Whether the drawer handle is actively being dragged now. Followed.
pub fn Drawer::dragging(self : Drawer) -> Bool {
  self.dragging_.get()
}

///|
/// Most recent release velocity along the dismiss direction in points per second (`0.0` before any release or on cancel).
pub fn Drawer::last_velocity(self : Drawer) -> Double {
  self.last_velocity_.val
}

///|
/// Whether the drawer's own node has visible keyboard focus.
pub fn Drawer::focus_shown(self : Drawer) -> Bool {
  self.node_.focus_shown()
}

///|
/// Active snap-point index, clamped to the valid range of `snap_points`.
pub fn Drawer::snap_index(self : Drawer) -> Int {
  let n = self.snaps.length()
  let idx = (self.active_snap_)()
  if idx < 0 { 0 } else if idx >= n { n - 1 } else { idx }
}

///|
/// Active snap-point fraction (in `(0.0, 1.0]`).
pub fn Drawer::snap_point(self : Drawer) -> Double {
  self.snaps[self.snap_index()]
}

///|
/// Request closing the drawer (`on_close` told once while open).
pub fn Drawer::close(self : Drawer) -> Unit {
  (self.close_)()
}

///|
/// Snap to index `idx` (clamped to `snap_points`), telling `on_snap` if it differs from the current snap index.
pub fn Drawer::snap_to(self : Drawer, idx : Int) -> Unit {
  let n = self.snaps.length()
  let clamped = if idx < 0 { 0 } else if idx >= n { n - 1 } else { idx }
  let cur = @signals.untracked(fn() { self.snap_index() })
  if clamped != cur {
    (self.on_snap_)(clamped)
  }
}

///|
fn drawer_min_max(snaps : Array[Double]) -> (Double, Double) {
  let mut lo = snaps[0]
  let mut hi = snaps[0]
  for s in snaps {
    if s < lo {
      lo = s
    }
    if s > hi {
      hi = s
    }
  }
  (lo, hi)
}

///|
fn drawer_nearest_snap(snaps : Array[Double], target : Double) -> Int {
  let mut best_i = 0
  let mut best_d = (snaps[0] - target).abs()
  for i in 1..<snaps.length() {
    let d = (snaps[i] - target).abs()
    if d < best_d {
      best_d = d
      best_i = i
    }
  }
  best_i
}

///|
fn drawer_step_lower(snaps : Array[Double], cur_val : Double) -> Int? {
  let mut best : Int? = None
  let mut best_val = -1.0
  for i, s in snaps {
    if s < cur_val && (best is None || s > best_val) {
      best = Some(i)
      best_val = s
    }
  }
  best
}

///|
fn drawer_step_higher(snaps : Array[Double], cur_val : Double) -> Int? {
  let mut best : Int? = None
  let mut best_val = 1.0e9
  for i, s in snaps {
    if s > cur_val && (best is None || s < best_val) {
      best = Some(i)
      best_val = s
    }
  }
  best
}

///|
/// Bind edge-aware drag-to-dismiss and snap-point gesture handling to `v`.
/// Respects `can_drag()` on press down so an inner scrollable list not yet at its scroll edge is not hijacked.
/// `extent_by`: optional dynamic reference extent (points), taking precedence over static `extent`; defaults to `d.h`
/// (Top/Bottom) or `d.w` (Left/Right). `slop`: when `> 0.0`, uses `View::gesture(slop, ...)` so taps on inner buttons
/// are not swallowed.
pub fn Drawer::handle(
  self : Drawer,
  v : @view.View,
  extent? : Double,
  extent_by? : () -> Double,
  slop? : Double = 0.0,
) -> Unit {
  let start_wx = Ref(0.0)
  let start_wy = Ref(0.0)
  let active = Ref(false)
  let dismiss_delta = fn(d : @view.Drag) -> Double {
    match self.edge_ {
      Bottom => d.wy - start_wy.val
      Top => start_wy.val - d.wy
      Right => d.wx - start_wx.val
      Left => start_wx.val - d.wx
    }
  }
  let dismiss_vel_ps = fn(d : @view.Drag) -> Double {
    match self.edge_ {
      Bottom => d.vy() * 1000.0
      Top => -d.vy() * 1000.0
      Right => d.vx() * 1000.0
      Left => -d.vx() * 1000.0
    }
  }
  let ref_extent = fn(d : @view.Drag) -> Double {
    let raw = match extent_by {
      Some(f) => @signals.untracked(f)
      None =>
        match extent {
          Some(e) => e
          None =>
            match self.edge_ {
              Bottom | Top => d.h
              Left | Right => d.w
            }
        }
    }
    if raw > 0.0 { raw } else { 1.0 }
  }
  let clamp_delta = fn(delta : Double, cur_val : Double) -> Double {
    let (_, max_snap) = drawer_min_max(self.snaps)
    if delta < 0.0 && cur_val >= max_snap {
      if self.overpull_max > 0.0 {
        -drawer_rubber_pull(-delta, self.overpull_max)
      } else {
        0.0
      }
    } else {
      delta
    }
  }
  let on_drag_event = fn(d : @view.Drag, use_press_origin : Bool) {
    if !@signals.untracked(self.now) {
      if active.val {
        active.val = false
        self.dragging_.set(false)
        self.drag_offset_.set(0.0)
      }
      return
    }
    match d.kind {
      Down =>
        if @signals.untracked(self.can_drag_) {
          if !use_press_origin {
            start_wx.val = d.wx
            start_wy.val = d.wy
          }
          active.val = true
          self.dragging_.set(true)
          if use_press_origin {
            let delta = dismiss_delta(d)
            let cur_val = @signals.untracked(fn() { self.snap_point() })
            self.drag_offset_.set(clamp_delta(delta, cur_val))
          } else {
            self.drag_offset_.set(0.0)
          }
        } else {
          active.val = false
        }
      Moved => {
        if !active.val {
          return
        }
        let delta = dismiss_delta(d)
        let cur_val = @signals.untracked(fn() { self.snap_point() })
        self.drag_offset_.set(clamp_delta(delta, cur_val))
      }
      Up => {
        if !active.val {
          return
        }
        active.val = false
        self.dragging_.set(false)
        let delta = dismiss_delta(d)
        let vel = dismiss_vel_ps(d)
        let ext = ref_extent(d)
        let cur_idx = @signals.untracked(fn() { self.snap_index() })
        let cur_val = self.snaps[cur_idx]
        let full_ext = if cur_val > 0.0 { ext / cur_val } else { ext }
        let projected = cur_val - delta / full_ext
        let (min_snap, _) = drawer_min_max(self.snaps)
        let dismiss_floor = min_snap * (1.0 - self.dismiss_threshold)
        let release_offset = clamp_delta(delta, cur_val)
        let mut will_close = false
        let mut next_snap : Int? = None
        if vel >= self.velocity_threshold {
          if projected <= dismiss_floor {
            will_close = true
          } else {
            match drawer_step_lower(self.snaps, cur_val) {
              Some(lower_idx) => next_snap = Some(lower_idx)
              None => will_close = true
            }
          }
        } else if vel <= -self.velocity_threshold {
          // Reverse fling toward expand direction never dismisses even if projected <= dismiss_floor.
          if drawer_step_higher(self.snaps, cur_val) is Some(higher_idx) {
            next_snap = Some(higher_idx)
          }
        } else if projected <= dismiss_floor {
          will_close = true
        } else {
          next_snap = Some(drawer_nearest_snap(self.snaps, projected))
        }
        self.last_velocity_.val = vel
        (self.on_release_)(release_offset, vel, will_close)
        self.drag_offset_.set(0.0)
        if will_close {
          self.close()
        } else if next_snap is Some(idx) {
          self.snap_to(idx)
        }
      }
      Off => {
        if active.val {
          active.val = false
          self.dragging_.set(false)
          let release_offset = self.drag_offset_.untracked()
          self.last_velocity_.val = 0.0
          (self.on_release_)(release_offset, 0.0, false)
          self.drag_offset_.set(0.0)
        }
      }
    }
  }
  v.presses(By(self.now)) |> ignore
  if slop > 0.0 {
    v
    .gesture(
      slop,
      press=fn(d) {
        start_wx.val = d.wx
        start_wy.val = d.wy
        active.val = false
      },
      drag=fn(d) { on_drag_event(d, true) },
    )
    |> ignore
  } else {
    v.on_drag(fn(d) { on_drag_event(d, false) }) |> ignore
  }
}

///|
/// A headless drawer / sheet in `parent`, called `label`, open while `open` says so; `on_close` told on Escape, Back,
/// outside press, or drag-to-dismiss. Shares the tree's `overlay_stack` with `dialog` and `popover`.
/// `edge`: docked viewport edge (`Bottom`, `Top`, `Left`, `Right`).
/// `snap_points`: normalized open fractions (default `[1.0]`); `active_snap` / `on_snap` control the active snap index.
/// `can_drag`: scroll-handoff guard consulted on handle press down.
#callsite(autofill(loc))
pub fn drawer(
  parent : @view.View,
  label : () -> String,
  open : () -> Bool,
  on_close : () -> Unit,
  look : (@view.View, Drawer) -> Unit,
  edge? : DrawerEdge = Bottom,
  modal? : Bool = true,
  snap_points? : Array[Double] = [1.0],
  active_snap? : () -> Int = fn() { 0 },
  on_snap? : (Int) -> Unit = fn(_) {  },
  close_on_escape? : Bool = true,
  close_on_outside? : Bool = true,
  dismiss_threshold? : Double = 0.35,
  velocity_threshold? : Double = 500.0,
  overpull_max? : Double = 0.0,
  on_release? : (Double, Double, Bool) -> Unit = fn(_, _, _) {  },
  can_drag? : () -> Bool = fn() { true },
  return_focus? : @view.View,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let snaps = if snap_points.is_empty() { [1.0] } else { snap_points.copy() }
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let close = fn() {
      if @signals.untracked(open) {
        on_close()
      }
    }
    let (stack, entry) = overlay_join(v, fn(_) { close() }, fn() { !open() }, close_on_escape, close_on_outside, None, modal~)
    let state : Drawer = {
      node_: v,
      edge_: edge,
      now: open,
      close_: close,
      snaps,
      active_snap_: active_snap,
      on_snap_: on_snap,
      dismiss_threshold,
      velocity_threshold,
      overpull_max,
      on_release_: on_release,
      can_drag_: can_drag,
      drag_offset_: @signals.signal(0.0),
      dragging_: @signals.signal(false),
      last_velocity_: Ref(0.0),
    }
    // Default ground drag absorber before `look` runs, so `look` may attach `Drawer::handle` directly to `v` if desired.
    v.on_drag(fn(_) {  }) |> ignore
    look(v, state)
    v.focus_opens_first() |> ignore
    if return_focus is Some(r) {
      v.opened_by(ByNode(r.id())) |> ignore
    }
    if modal {
      v.modal(By(open)) |> ignore
    }
    v
    .says(By(fn() { Some(@view.said(Dialog, label=label())) }))
    .hides(By(fn() { !open() }))
    .presses(By(open))
    .focusable(By(open), keys=0, tab=false)
    |> ignore
    overlay_wire_dismiss(v, stack, entry)
  })
}
