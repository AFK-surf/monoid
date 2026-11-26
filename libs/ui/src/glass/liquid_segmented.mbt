// iOS 26/27 Liquid Glass segmented control: outer capsule (`glass_track=true` floating glass capsule, or
// `glass_track=false` non-glass translucent track for embedding inside glass popovers / content layers with zero
// glass-on-glass at rest), concentric sliding thumb driven by DampedDragAnimation (DampedDrag).
// At rest the thumb is an opaque optical pill (zero hidden glass instances); while held/dragged it cross-fades to a
// clear refraction loupe (`blur == 0`, `zoom = 1.22`) rendered in the paint layer via `ground_drawn` (zero relayout).

///|
/// Horizontal growth cap (pt) for wide segments so the lifted lens keeps an even optical lip without overflowing.
let ctrl_seg_max_grow_x : Double = 24.0

///|
/// Finger hold duration (ms) before the lifted clear lens appears on touch inputs (matches bottom bar).
pub let ctrl_seg_hold_ms : Double = 200.0

///|
/// Magnetic lean fraction toward the finger while dragging between discrete segments on touch inputs.
let ctrl_seg_drag_lean : Double = 0.25

///|
/// Visual and optical configuration for `liquid_segmented_thumb_look`.
pub struct SegThumbLook {
  /// `true`: optical white/dark lifted capsule for floating glass tracks.
  /// `false`: compact theme `lifted` capsule for embedded tracks (borderless/shadowless at rest per iOS 27.0).
  glass_track : Bool
  /// Optional velocity-based jelly scale `(sx, sy)` while dragging (defaults to uniform `1.15x` growth).
  jelly : ((@view.View) -> (Double, Double))?
  /// Optional cause-frame active probe so the lens mounts on the exact press frame before spring advances.
  active : (() -> Bool)?
  /// Optional solid fallback colour for the lens glass recipe.
  solid : (() -> Int64)?
  /// Optional outer track height for `glass_track=true` vertical overhang calibration (`th + 13.0`).
  track_h : (() -> Double)?
  /// Horizontal lens overhang in pt while held (default 18.0; `glass_track=true` uses 20.0).
  overhang_x : Double
  /// Vertical lens overhang in pt while held (default 16.0; ignored when `track_h` is set).
  overhang_y : Double
}

///|
/// Default configuration for `liquid_segmented_thumb_look`.
pub fn SegThumbLook::default(
  glass_track? : Bool = false,
  jelly? : (@view.View) -> (Double, Double),
  active? : () -> Bool,
  solid? : () -> Int64,
  track_h? : () -> Double,
  overhang_x? : Double = 18.0,
  overhang_y? : Double = 16.0,
) -> SegThumbLook {
  { glass_track, jelly, active, solid, track_h, overhang_x, overhang_y }
}

///|
/// Shared resting-capsule and held-refraction-lens drawing primitive for segmented controls and pill tabs.
/// Mounts the resting opaque pill immediately in `parent` (behind labels, zero glass at rest) and returns a
/// closure that mounts the lazy clear liquid glass lens (`kind == 6`, `blur == 0`, `droplet_role = 3`)
/// above labels after the caller populates its items. Both layers animate solely via paint-layer `ground_drawn`
/// (`laid == 0`) and degrade cleanly under `glass_solid()`.
#callsite(autofill(loc))
pub fn liquid_segmented_thumb_look(
  parent : @view.View,
  rect : (@view.View) -> (Double, Double, Double, Double)?,
  pressed : (@view.View) -> Double,
  look? : SegThumbLook = SegThumbLook::default(),
  loc~ : SourceLoc,
) -> () -> Unit {
  let no_lens = fn(v : @view.View) { v.glass_solid() }
  let lens_of = fn(v : @view.View) {
    if no_lens(v) {
      0.0
    } else {
      clamp(pressed(v), 0.0, 1.0)
    }
  }
  // Resting solid capsule (behind labels, zero hidden glass at rest, zero relayout via ground_drawn).
  parent.box(made_for=loc, fn(pill) {
    pill
    .over(Is(true))
    .points(Is(false))
    .offset(Is((0.0, 0.0)))
    .width(Is(Some(0.0)))
    .height(Is(Some(0.0)))
    .radius(Is(0.0))
    .alpha(By(fn() { 1.0 - lm_smoothstep(0.15, 0.75, lens_of(pill)) }))
    .ground_drawn(By(fn() {
      match rect(pill) {
        Some((rx, ry, rw, rh)) if rw > 0.0 && rh > 0.0 => {
          let p = lens_of(pill)
          let (pw, ph) = if p > 0.001 {
            let k = p * 0.25
            match look.track_h {
              Some(th_fn) => (rw + look.overhang_x * k, lerp(rh, th_fn() + 13.0, k))
              None => (rw + look.overhang_x * k, rh + look.overhang_y * k)
            }
          } else {
            (rw, rh)
          }
          let r = ph / 2.0
          { dx: rx + (rw - pw) / 2.0, dy: ry + (rh - ph) / 2.0, dw: pw, dh: ph, corners: Some((r, r, r, r)) }
        }
        _ => @view.ground_as_laid
      }
    }))
    |> ignore
    // Native iOS 27.0 resting segmented pill: clean opaque fill with zero border and zero shadow
    // in both Light and Dark modes (no grey outline or dark halo ring inside the track).
    if look.glass_track {
      pill.ground(By(ctrl_seg_thumb_idle)) |> ignore
    } else {
      pill.ground(By(fn() { @ui.tree_theme().lifted })) |> ignore
    }
  })
  |> ignore
  // Lazy-mounted clear liquid glass refraction lens (mounted by caller AFTER labels for iOS 26/27 Z-order).
  let mounted : @signals.Signal[Bool] = @signals.signal(false)
  let active_fn = match look.active {
    Some(f) => f
    None => fn() { false }
  }
  fn() {
    parent.reacts(fn() { !no_lens(parent) && (pressed(parent) > 0.001 || active_fn()) }, fn(on) {
      if on && !mounted.untracked() {
        mounted.set(true)
      }
    })
    parent.show(fn() { mounted.get() }, at_once=true, fn(gl) {
      gl.made_for(loc) |> ignore
      let full = fn() { lens_of(gl) }
      gl
      .over(Is(true))
      .points(Is(false))
      .offset(Is((0.0, 0.0)))
      .width(Is(Some(0.0)))
      .height(Is(Some(0.0)))
      .radius(Is(1.0e6))
      .shadow(By(fn() {
        let p = full()
        if p > 0.001 {
          seg_lens_shadow(p)
        } else {
          shadow_none
        }
      }))
      .shadow_outside(Is(true))
      .glass(By(fn() {
        let p = full()
        if p > 0.001 {
          let sol = match look.solid {
            Some(f) => f()
            None => clear
          }
          if look.glass_track || sol != clear {
            Some(ctrl_segmented_lens_glass(p, solid=sol))
          } else {
            Some(ctrl_segmented_compact_lens_glass(p))
          }
        } else {
          None
        }
      }))
      .alpha(By(fn() { lm_smoothstep(0.05, 0.65, full()) }))
      .ground_drawn(By(fn() {
        match rect(gl) {
          Some((rx, ry, rw, rh)) if rw > 0.0 && rh > 0.0 => {
            let p = full()
            let (vel_sx, vel_sy) = match look.jelly {
              Some(jf) => {
                let (sx, sy) = jf(gl)
                let ps = lerp(1.0, ctrl_seg_held_scale, p)
                if ps > 0.001 { (sx / ps, sy / ps) } else { (1.0, 1.0) }
              }
              None => (1.0, 1.0)
            }
            let (lw, lh) = match look.track_h {
              Some(th_fn) => {
                let th = th_fn()
                let base_grow_x = lerp(0.0, look.overhang_x, p)
                let grow_x = dmin(base_grow_x + rw * (vel_sx - 1.0), ctrl_seg_max_grow_x)
                let base_lh = lerp(rh, th + 13.0, p)
                (dmax(0.0, rw + grow_x), dmax(0.0, base_lh * vel_sy))
              }
              None => {
                let base_grow_x = look.overhang_x * p
                let grow_x = dmin(base_grow_x + rw * (vel_sx - 1.0), ctrl_seg_max_grow_x)
                (dmax(0.0, rw + grow_x), dmax(0.0, (rh + look.overhang_y * p) * vel_sy))
              }
            }
            {
              dx: rx + (rw - lw) / 2.0,
              dy: ry + (rh - lh) / 2.0,
              dw: lw,
              dh: lh,
              corners: Some((lh / 2.0, lh / 2.0, lh / 2.0, lh / 2.0)),
            }
          }
          _ => @view.ground_as_laid
        }
      }))
      |> ignore
    })
  }
}

///|
/// A Liquid Glass segmented control in `parent`, displaying `labels` with `selected` active
/// and calling `on_select` when changed by tap, continuous drag, or keyboard arrows/Home/End.
/// Set `glass_track=false` when embedded inside a glass popover or content layer to guarantee zero glass-on-glass at rest.
#callsite(autofill(loc))
pub fn liquid_segmented_node(
  parent : @view.View,
  labels : () -> Array[String],
  selected : () -> Int,
  on_select : (Int) -> Unit,
  width? : Double,
  height? : Double = 32.0,
  drag? : DampedDrag,
  glass_track? : Bool = true,
  pad? : Double = ctrl_seg_pad,
  gap? : Double = 0.0,
  widths? : () -> Array[Double],
  height_by? : () -> Double,
  text_size? : () -> Double,
  kind? : @headless.GroupKind = Tab,
  said? : String = "Segmented Control",
  shown? : () -> Bool = fn() { true },
  in_node? : Bool = false,
  render_item? : (@view.View, Int, () -> Bool) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let total_h = match height_by {
    Some(f) => f
    None => fn() { height }
  }
  let inner_h = fn() { dmax(0.0, total_h() - 2.0 * pad) }
  let init_count = @signals.untracked(labels).length()
  let last_init = if init_count > 1 { (init_count - 1).to_double() } else { 0.0 }
  let first = @signals.untracked(selected).to_double()
  let dd = match drag {
    Some(d) => d
    None =>
      DampedDrag::new(
        first,
        lo=0.0,
        hi=last_init,
        held_scale=ctrl_seg_held_scale,
      )
  }
  let current = Ref(@signals.untracked(selected))
  let strip_origin_x = Ref(0.0)
  let felt : Ref[Int?] = Ref(None)
  let finger_previewing = Ref(false)
  let press_was_finger = Ref(false)
  let pressing_here = Ref(false)
  let drag_active = Ref(false)
  let axis_locked : Ref[Bool?] = Ref(None)
  let press_idx : Ref[Int?] = Ref(None)
  let press_on_selected = Ref(false)
  let press_labels : Ref[Array[String]] = Ref([])
  @headless.radio_group(
    made_for=loc,
    parent,
    fn() { said },
    selected,
    on_select,
    kind~,
    axis=Horizontal,
    shown~,
    in_node~,
    fn(g, rg) {
      let count_fn = fn() {
        let n = labels().length()
        if n > 0 { n } else { 1 }
      }
      let last_fn = fn() {
        let n = count_fn()
        if n > 1 { (n - 1).to_double() } else { 0.0 }
      }
      let g_no_lens = fn() { g.glass_solid() }
      let clear_press_state = fn() {
        felt.val = None
        pressing_here.val = false
        finger_previewing.val = false
        drag_active.val = false
        axis_locked.val = None
        press_idx.val = None
        press_on_selected.val = false
        press_labels.val = []
      }
      let labels_unchanged = fn() -> Bool {
        let cur = @signals.untracked(labels)
        let snap = press_labels.val
        if cur.length() != snap.length() {
          return false
        }
        for i in 0..<cur.length() {
          if cur[i] != snap[i] {
            return false
          }
        }
        true
      }
      let deferred_sync = Ref(0)
      let was_shown = Ref(@signals.untracked(shown))
      let can_drive_dd = fn() {
        @signals.untracked(shown) && !dd.gesture_active_elsewhere(g) && !dd.has_other_host(g)
      }
      let sync_dd = fn(animate : Bool) {
        deferred_sync.val = 0
        was_shown.val = true
        let sel = @signals.untracked(selected)
        current.val = sel
        dd.claim_driver(g)
        dd.attach_if_needed(g)
        dd.set_bounds(lo=0.0, hi=last_fn())
        if animate {
          dd.slide_to(sel.to_double(), spec=@motion.snappy_damped)
        } else {
          dd.drop_lens()
          dd.value.put(sel.to_double())
        }
      }
      if can_drive_dd() {
        deferred_sync.val = 0
        dd.claim_driver(g)
        dd.attach_if_needed(g)
        dd.set_bounds(lo=0.0, hi=last_init)
        if @signals.untracked(fn() { (dd.target() - first).abs() > 0.001 && !dd.pressing() }) {
          dd.slide_to(first, spec=@motion.snappy_damped)
        }
      } else {
        deferred_sync.val = if @signals.untracked(shown) { 1 } else { 2 }
      }
      g.reacts(at_start=false, shown, fn(s) {
        if s {
          if can_drive_dd() {
            sync_dd(false)
          } else {
            deferred_sync.val = 2
          }
        } else {
          was_shown.val = false
          deferred_sync.val = 0
          let was_active = pressing_here.val || finger_previewing.val || drag_active.val || (dd.gesture_owned_by(g) && (dd.pressing() || dd.has_pending_release()))
          clear_press_state()
          if was_active {
            let committed = @signals.untracked(selected)
            current.val = committed
            dd.drop_lens()
            dd.value.put(committed.to_double())
            dd.relinquish_host(g)
          } else {
            if dd.gesture_owned_by(g) && !g_no_lens() && (dd.pressing() || dd.has_pending_release()) {
              dd.drop_lens()
            }
            dd.relinquish_host(g)
          }
        }
      })
      g.reacts(at_start=false, fn() { labels().length() }, fn(n) {
        if can_drive_dd() {
          if deferred_sync.val > 0 || !was_shown.val {
            sync_dd(deferred_sync.val == 1 && was_shown.val)
          } else {
            dd.claim_driver(g)
            dd.attach_if_needed(g)
            dd.set_bounds(lo=0.0, hi=if n > 1 { (n - 1).to_double() } else { 0.0 })
          }
        } else if !@signals.untracked(shown) {
          deferred_sync.val = 2
        } else if deferred_sync.val == 0 {
          deferred_sync.val = 1
        }
      })
      g
      .height(By(fn() { Some(total_h()) }))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .padding(Is((pad, 0.0, pad, 0.0)))
      .radius(By(fn() { total_h() / 2.0 }))
      |> ignore
      if glass_track {
        g
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .glass(By(fn() { Some(ctrl_segmented_track_glass()) }))
        .edge(By(fn() { if g.glass_solid() { liquid_solid_edge() } else { (0.0, clear) } }))
        |> ignore
      } else {
        g.ground(By(ctrl_seg_embedded_track_ink)) |> ignore
      }
      match width {
        Some(w) => g.width(Is(Some(w))).max_width(Is(Some(w)), within=true) |> ignore
        None => ()
      }
      // (chosen by what is not the thumb: the keys, its caller; the thumb only slides there, unpressed and unmagnified)
      g.reacts(at_start=false, selected, fn(i) {
        if i != current.val {
          current.val = i
          if can_drive_dd() {
            if deferred_sync.val == 2 || !was_shown.val {
              sync_dd(false)
            } else {
              deferred_sync.val = 0
              dd.claim_driver(g)
              dd.attach_if_needed(g)
              dd.set_bounds(lo=0.0, hi=last_fn())
              dd.slide_to(i.to_double(), spec=@motion.snappy_damped)
            }
          } else if !@signals.untracked(shown) {
            deferred_sync.val = 2
          } else if deferred_sync.val == 0 {
            deferred_sync.val = 1
          }
        }
      })
      g.reacts(at_start=false, fn() { dd.gesture_gen() }, fn(_) {
        if deferred_sync.val > 0 && can_drive_dd() {
          sync_dd(deferred_sync.val == 1 && was_shown.val)
        }
      })
      g.owns(fn() {
        let was_active = pressing_here.val || finger_previewing.val || drag_active.val || (dd.gesture_owned_by(g) && (dd.pressing() || dd.has_pending_release()))
        clear_press_state()
        if was_active {
          let committed = @signals.untracked(selected)
          current.val = committed
          dd.set_bounds(lo=0.0, hi=last_fn())
          dd.drop_lens()
          if !dd.same_host(Some(g)) {
            dd.slide_to(committed.to_double(), spec=@motion.snappy_damped)
          }
        }
        dd.relinquish_host(g)
      })
      |> ignore
      let build_body = fn(host : @view.View, x_offset : Double, room_w : () -> Double) {
        let w_of = fn(k : Int) -> Double {
          match widths {
            Some(ws_fn) => ws_fn().get(k).unwrap_or(0.0)
            None => {
              let n = count_fn()
              dmax(0.0, (room_w() - gap * (n - 1).to_double()) / n.to_double())
            }
          }
        }
        let x_of = fn(k : Int) -> Double {
          let mut x = 0.0
          for i in 0..<k {
            x = x + w_of(i) + gap
          }
          x
        }
        // Interpolate (x, w) continuously along segment index `p`, supporting both equal and unequal widths.
        let rect_at = fn(p : Double) -> (Double, Double) {
          let n = count_fn()
          if n <= 1 {
            return (0.0, w_of(0))
          }
          let i = p.floor().to_int()
          let a = if i < 0 { 0 } else if i > n - 2 { n - 2 } else { i }
          // The spring can cross an end segment. Keep the thumb centered on that segment while it settles.
          let f = clamp(p - a.to_double(), 0.0, 1.0)
          let x0 = x_of(a)
          let x1 = x_of(a + 1)
          let w0 = w_of(a)
          let w1 = w_of(a + 1)
          (x0 + (x1 - x0) * f, dmax(0.0, w0 + (w1 - w0) * f))
        }
        // Map a strip-local x coordinate to continuous segment index [0, n - 1] via adjacent segment centers.
        let index_at = fn(lx : Double) -> Double {
          let n = count_fn()
          if n <= 1 {
            return 0.0
          }
          let mut from = x_of(0) + w_of(0) / 2.0
          if lx <= from {
            return 0.0
          }
          for k in 1..<n {
            let to = x_of(k) + w_of(k) / 2.0
            if lx < to && to > from {
              return (k - 1).to_double() + clamp((lx - from) / (to - from), 0.0, 1.0)
            }
            from = to
          }
          (n - 1).to_double()
        }
        let no_lens = fn() { host.glass_solid() }
        let thumb_rect = fn(v : @view.View) -> (Double, Double, Double, Double)? {
          let (rx, rw) = rect_at(dd.value(v))
          let ih = inner_h()
          if rw <= 0.0 || ih <= 0.0 {
            None
          } else {
            Some((x_offset + rx, (total_h() - ih) / 2.0, rw, ih))
          }
        }
        let mount_lens = liquid_segmented_thumb_look(
          host,
          thumb_rect,
          fn(v) {
            let p = dd.pressed(v)
            if dd.lens_owned_by(g) { p } else { 0.0 }
          },
          look=SegThumbLook::default(
            glass_track~,
            jelly=fn(v) { dd.jelly(v, 10.0) },
            active=fn() {
              let pr = dd.pressing()
              pr && dd.lens_owned_by(g)
            },
            track_h?=if glass_track { Some(total_h) } else { None },
            overhang_x=if glass_track { 20.0 } else { 12.0 },
            overhang_y=if glass_track { 16.0 } else { 8.0 },
          ),
          loc~,
        )
        let tap_commit = fn(sel : Int) {
          let dd_host_before = dd.host_node()
          let prev = @signals.untracked(selected)
          if sel != prev {
            on_select(sel)
          }
          if !host.alive() || !@signals.untracked(shown) || !dd.same_host(dd_host_before) {
            if !host.alive() || !@signals.untracked(shown) {
              if dd.gesture_owned_by(g) && !no_lens() && (dd.pressing() || dd.has_pending_release()) {
                dd.drop_lens()
              }
              dd.relinquish_host(g)
            }
            return
          }
          let settled = @signals.untracked(selected)
          current.val = settled
          dd.attach_if_needed(g)
          dd.set_bounds(lo=0.0, hi=last_fn())
          if no_lens() && (dd.pressing() || dd.has_pending_release()) {
            dd.drop_lens()
          }
          dd.end_gesture(g)
          dd.slide_to(settled.to_double(), spec=@motion.snappy_damped)
        }
        let drag_commit = fn(sel : Int, spec : @motion.Spec?) {
          let dd_host_before = dd.host_node()
          let prev = @signals.untracked(selected)
          if sel != prev {
            on_select(sel)
          }
          if !host.alive() || !@signals.untracked(shown) || !dd.same_host(dd_host_before) {
            if !host.alive() || !@signals.untracked(shown) {
              if dd.gesture_owned_by(g) && !no_lens() && (dd.pressing() || dd.has_pending_release()) {
                dd.drop_lens()
              }
              dd.relinquish_host(g)
            }
            return
          }
          let settled = @signals.untracked(selected)
          current.val = settled
          dd.attach_if_needed(g)
          dd.set_bounds(lo=0.0, hi=last_fn())
          if no_lens() {
            dd.drop_lens()
            dd.end_gesture(g)
            dd.slide_to(settled.to_double(), spec?)
          } else {
            dd.claim_gesture(g)
            dd.settle_to(settled.to_double(), spec?, within_frac=0.18, relative_trip=true)
          }
        }
        let cancel_drag_opts = fn(keep_vertical_lock : Bool) {
          let was_active = pressing_here.val || finger_previewing.val || drag_active.val || (dd.gesture_owned_by(g) && (dd.pressing() || dd.has_pending_release()))
          felt.val = None
          finger_previewing.val = false
          drag_active.val = false
          if !keep_vertical_lock {
            pressing_here.val = false
            axis_locked.val = None
            press_idx.val = None
            press_on_selected.val = false
            press_labels.val = []
          }
          if was_active {
            let orig = @signals.untracked(selected)
            current.val = orig
            dd.attach_if_needed(g)
            dd.set_bounds(lo=0.0, hi=last_fn())
            if no_lens() {
              dd.drop_lens()
              dd.slide_to(orig.to_double(), spec=@motion.snappy_damped)
            } else {
              dd.settle_to(orig.to_double(), spec=@motion.snappy_damped, within_frac=0.18, relative_trip=true)
            }
          }
          if !keep_vertical_lock {
            dd.end_gesture(g)
          }
        }
        let cancel_drag = fn() { cancel_drag_opts(false) }
        let finger_preview = fn(k : Int, event : @view.Drag?) -> Int? {
          let last = last_fn()
          dd.attach_if_needed(g)
          dd.set_bounds(lo=0.0, hi=last)
          match event {
            Some(d) => {
              let p = index_at(x_of(k) + d.x)
              let nearest = clamp((p + 0.5).floor(), 0.0, last).to_int()
              let prev_felt = felt.val.unwrap_or(@signals.untracked(selected))
              let steps = (nearest - prev_felt).abs()
              for _ in 0..<steps {
                @ui.haptic(TextHandleMove)
              }
              felt.val = Some(nearest)
              let target = nearest.to_double()
              let leaned = target + (p - target) * ctrl_seg_drag_lean
              if !finger_previewing.val {
                finger_previewing.val = true
                if !no_lens() {
                  dd.press()
                }
              }
              if no_lens() {
                dd.slide_to(leaned, spec=@motion.tactile_bounce)
              } else {
                dd.update_value(leaned, spec=@motion.tactile_bounce)
              }
              Some(nearest)
            }
            None => {
              cancel_drag_opts(true)
              None
            }
          }
        }
        let finger_commit = fn(sel : Int) {
          let prev = @signals.untracked(selected)
          if felt.val != Some(sel) && sel != prev {
            @ui.haptic(TextHandleMove)
          }
          let was_previewing = finger_previewing.val
          clear_press_state()
          let commit_spec = if was_previewing { @motion.tactile_bounce } else { @motion.snappy_damped }
          drag_commit(sel, Some(commit_spec))
        }
        host
        .row(Is(true))
        .gap(Is(gap))
        .height(By(fn() { Some(total_h()) }))
        .lines_up(Is(Some(Middle)))
        |> ignore
        host.each(
          fn() {
            let ls = labels()
            let out : Array[(Int, String)] = []
            for i, s in ls {
              out.push((i, s))
            }
            out
          },
          fn(p) { p.0 },
          fn(slot, item_sig) {
            let idx = @signals.untracked(fn() { item_sig.get().0 })
            let idx_f = idx.to_double()
            rg.item(
              made_for=loc,
              slot,
              fn() { item_sig.get().0 },
              fn() { item_sig.get().1 },
              in_node=true,
              fn(seg, it) {
                let across = fn(d : @view.Drag) { (d.x - d.ox).abs() > (d.y - d.oy).abs() }
                let on_it = fn(d : @view.Drag) { seg.finger_target(d.wx, d.wy) }
                if widths is Some(_) {
                  seg.width(By(fn() { Some(w_of(idx)) })) |> ignore
                } else {
                  seg
                  .grow(Is(1.0))
                  .basis(Is(Some(0.0)))
                  .padding(By(fn() {
                    let sw = w_of(idx)
                    let px = if sw > 0.0 && sw < 86.0 { 4.0 } else { ctrl_seg_px }
                    (px, 0.0, px, 0.0)
                  }))
                  |> ignore
                }
                seg
                .height(By(fn() { Some(if glass_track { total_h() } else { inner_h() }) }))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                |> ignore
                match render_item {
                  Some(draw_item) => draw_item(seg, idx, fn() { it.chosen() })
                  None =>
                    seg.box(fn(w) {
                      w
                      .words(By(fn() { item_sig.get().1 }))
                      .words_look(By(fn() {
                        let sz = match text_size {
                          Some(f) => f()
                          None => ctrl_type_seg
                        }
                        if glass_track {
                          words_at(sz, weight=if it.chosen() { 600 } else { weight_medium })
                        } else {
                          {
                            size: sz,
                            weight: if it.chosen() { 600 } else { 500 },
                            line: -@ui.tree_theme().text_line,
                            wrap: false,
                            tracking: @view.letters_own,
                            balance: false,
                            max_lines: 0,
                          }
                        }
                      }))
                      .ink(By(fn() {
                        let lit = clamp(1.0 - (dd.value(w) - idx_f).abs(), 0.0, 1.0)
                        let (off_c, on_c) = if glass_track {
                          (ctrl_seg_inactive_ink(), colors().content)
                        } else {
                          (colors().content, colors().content)
                        }
                        if !glass_track && it.hovered() && lit < 0.5 {
                          on_c
                        } else {
                          lerp_color(off_c, on_c, lit)
                        }
                      }))
                      |> ignore
                    })
                    |> ignore
                }
                // Gesture target directly on the item (no nested pressable box, keeping 36pt press_room intact).
                // Intentional mouse vs touch asymmetry: mouse press on an unselected segment never grabs the thumb or
                // lifts a lens; mouse drag/hold only activates on the already-selected segment.
                seg.gesture(
                  @ui.touch_slop(),
                  press=fn(d) {
                    if !dd.same_host(Some(g)) {
                      dd.attach(g)
                    }
                    dd.set_bounds(lo=0.0, hi=last_fn())
                    dd.claim_gesture(g)
                    pressing_here.val = true
                    press_was_finger.val = @ui.pointing() is Finger
                    drag_active.val = false
                    axis_locked.val = None
                    press_idx.val = Some(idx)
                    press_on_selected.val = idx == @signals.untracked(selected)
                    press_labels.val = @signals.untracked(labels).copy()
                    strip_origin_x.val = d.wx - (x_of(idx) + d.x)
                  },
                  tap=fn(d) {
                    if press_was_finger.val {
                      if !labels_unchanged() {
                        cancel_drag()
                      } else if on_it(d) {
                        if !finger_previewing.val && idx != @signals.untracked(selected) {
                          clear_press_state()
                          tap_commit(idx)
                        } else {
                          finger_commit(idx)
                        }
                      } else {
                        cancel_drag()
                      }
                    } else {
                      let was_drag = drag_active.val
                      let unchanged = labels_unchanged()
                      let still_on = on_it(d)
                      if !unchanged || !still_on {
                        cancel_drag()
                      } else {
                        clear_press_state()
                        if was_drag {
                          drag_commit(idx, None)
                        } else {
                          tap_commit(idx)
                        }
                      }
                    }
                  },
                  hold=(ctrl_seg_hold_ms, fn(d) {
                    if !labels_unchanged() {
                      cancel_drag()
                      return
                    }
                    if press_was_finger.val {
                      finger_preview(idx, Some(d)) |> ignore
                    } else if press_on_selected.val {
                      drag_active.val = true
                      if !no_lens() && !dd.pressing() {
                        dd.press()
                      }
                    }
                  }),
                  hold_yields=true,
                  drag=fn(d) {
                    let last = last_fn()
                    dd.attach_if_needed(g)
                    dd.set_bounds(lo=0.0, hi=last)
                    if press_was_finger.val {
                      match d.kind {
                        Down | Moved => {
                          if !labels_unchanged() {
                            cancel_drag()
                            return
                          }
                          if d.kind == Down {
                            axis_locked.val = Some(across(d))
                          }
                          if axis_locked.val == Some(true) {
                            finger_preview(idx, Some(d)) |> ignore
                          } else {
                            finger_preview(idx, None) |> ignore
                          }
                        }
                        Up => {
                          let hold_still = finger_previewing.val &&
                            axis_locked.val is None &&
                            (d.x - d.ox).abs() <= @ui.touch_slop() &&
                            (d.y - d.oy).abs() <= @ui.touch_slop()
                          if !labels_unchanged() ||
                            axis_locked.val == Some(false) ||
                            (!hold_still && !axis_locked.val.unwrap_or(across(d))) {
                            cancel_drag()
                          } else {
                            match finger_preview(idx, Some(d)) {
                              Some(sel) => finger_commit(sel)
                              None => cancel_drag()
                            }
                          }
                        }
                        Off => cancel_drag()
                      }
                    } else {
                      let started_on_selected = press_on_selected.val
                      if !started_on_selected {
                        match d.kind {
                          Down | Moved => ()
                          Up =>
                            if !drag_active.val && on_it(d) && labels_unchanged() {
                              clear_press_state()
                              tap_commit(idx)
                            } else {
                              cancel_drag()
                            }
                          Off => cancel_drag()
                        }
                      } else {
                        match d.kind {
                          Down => {
                            if !labels_unchanged() {
                              cancel_drag()
                              return
                            }
                            let is_h = across(d)
                            axis_locked.val = Some(is_h)
                            if is_h {
                              drag_active.val = true
                              if !no_lens() && !dd.pressing() {
                                dd.press()
                              }
                              let p = index_at(d.wx - strip_origin_x.val)
                              if no_lens() {
                                dd.slide_to(p)
                              } else {
                                dd.update_value(p)
                              }
                            } else {
                              cancel_drag_opts(true)
                            }
                          }
                          Moved => {
                            if !labels_unchanged() {
                              cancel_drag()
                              return
                            }
                            if axis_locked.val == Some(true) {
                              let p = index_at(d.wx - strip_origin_x.val)
                              if no_lens() {
                                dd.slide_to(p)
                              } else {
                                dd.update_value(p)
                              }
                            }
                          }
                          Up => {
                            if !labels_unchanged() || axis_locked.val == Some(false) {
                              cancel_drag()
                            } else if axis_locked.val.unwrap_or(across(d)) {
                              let p = index_at(d.wx - strip_origin_x.val)
                              let i = clamp(p.round(), 0.0, last).to_int()
                              clear_press_state()
                              drag_commit(i, None)
                            } else {
                              cancel_drag()
                            }
                          }
                          Off => cancel_drag()
                        }
                      }
                    }
                  },
                )
                |> ignore
                seg
                .radius(By(fn() { inner_h() / 2.0 }))
                .edge(By(fn() {
                  if it.focus_shown() {
                    (ctrl_focus_w, if glass_track { colors().accent } else { @ui.tree_theme().focus })
                  } else {
                    (0.0, clear)
                  }
                }))
                |> ignore
              },
            )
            |> ignore
          },
          at_once=true,
        )
        // Mount the clear refraction loupe above labels for both `glass_track=true` and `glass_track=false`
        // so dragging magnifies and refracts the segment labels underneath (iOS 26/27 optical Z-order).
        mount_lens()
      }
      if widths is Some(_) {
        build_body(g, pad, fn() { 0.0 })
      } else {
        g.by_room(fn(inner, room) { build_body(inner, 0.0, fn() { room.width() }) }) |> ignore
      }
    },
  )
}
