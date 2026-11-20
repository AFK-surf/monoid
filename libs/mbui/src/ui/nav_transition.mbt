// Declarative route transition protocol for Nav + nav_view: layered push/pop parallax & scrim,
// modal rise depth (scale + scrim), leading-edge separation hairline, root visibility progress
// for gesture-synchronized chrome, and interruptible dual-ended root tab cross-transitions.

///|
/// Declarative transition configuration for `nav_view`.
#derive(Eq)
pub(all) struct NavTransition {
  /// Horizontal parallax factor for the covered page during push/pop (0.28 layered; 1.0 flat 1:1).
  under_parallax : Double
  /// Maximum black scrim opacity over the covered page during push/pop (0.12 layered; 0.0 flat).
  under_dim : Double
  /// Maximum black scrim opacity over the covered page during `Nav::rise` (0.14 layered; 0.0 flat).
  rise_dim : Double
  /// Minimum scale of the covered page during `Nav::rise` (0.975 layered; 1.0 flat).
  rise_under_scale : Double
  /// Draw a subtle leading-edge separation hairline on the foreground page during horizontal slides.
  edge_shadow : Bool
  /// Horizontal travel distance (pt) for dual-ended root tab transitions (`Nav::replace_tab`).
  tab_slide : Double
  /// Duration (ms) for dual-ended root tab transitions (`Nav::replace_tab`).
  tab_ms : Double
}

///|
/// Legacy 1:1 edge-to-edge transition preset (default for `nav_view` for full backward compatibility).
pub fn NavTransition::flat() -> NavTransition {
  {
    under_parallax: 1.0,
    under_dim: 0.0,
    rise_dim: 0.0,
    rise_under_scale: 1.0,
    edge_shadow: false,
    tab_slide: 0.0,
    tab_ms: 0.0,
  }
}

///|
/// Modern layered transition preset: parallax + scrim + rise depth + edge separation + dual-ended tab swap.
pub fn NavTransition::layered() -> NavTransition {
  {
    under_parallax: 0.28,
    under_dim: 0.12,
    rise_dim: 0.14,
    rise_under_scale: 1.0,
    edge_shadow: true,
    tab_slide: 22.0,
    tab_ms: 260.0,
  }
}

///|
/// Black ink (`0x000000AA`) at `alpha` (0..1); 0 when invisible.
fn nav_scrim_ink(alpha : Double) -> Int64 {
  let a = dclamp(alpha, 0.0, 1.0)
  if a <= 0.001 {
    0L
  } else {
    (a * 255.0).round().to_int().to_int64() & 0xFFL
  }
}

///|
/// Whether the stack's slide is still advancing by the clock at `t` (false at rest or held by a finger).
fn[P] Nav::slide_clock_at(self : Nav[P], t : Double) -> Bool {
  (self.mode == 1 || self.mode == 2 || self.mode == 4) && self.t0 >= 0.0 && t < self.t0 + self.dur
}

///|
/// Current moment for a slide-driven property binding on `v`, stopping clock reads once the slide ends.
pub fn[P] Nav::slide_moment(self : Nav[P], v : @view.View) -> Double {
  self.said.get() |> ignore
  self.shown.get() |> ignore
  v.drawn_while(fn(t) { self.slide_clock_at(t) })
}

///|
/// Per-page transition veils painted directly after each page's children in `view_host.mbt`:
/// zero extra tree nodes, zero layout passes, and zero reactive bindings on push/pop/rest.
// kept across runs: cleared by view_forget
let nav_veils : Map[@view.NodeId, (Double, Double, Double, Double, Double) -> (Double, Double, Double, Double, Int64)?] = Map([])

///|
/// Per-page horizontal exposed-strip clip for covered `beside` pages during parallax push/pop (`under_parallax < 1.0`):
/// zero extra tree nodes, zero layout passes, and zero reactive bindings; avoids ~50% GPU overdraw and keeps
/// `words`/`text_runs` free of occluded underlying-page elements.
// kept across runs: cleared by view_forget
let nav_clips : Map[@view.NodeId, (Double, Double, Double) -> (Double, Double, Bool)?] = Map([])

///|
/// Active covered-page clips applied during the current paint pass: `(pv_id, cut_left, cut_right)` where only the
/// side covered by `top` is cut (`(-1.0e9, sx + p * w)` when `way > 0`, `(sx + (1.0 - p) * w, 1.0e9)` when `way < 0`).
// kept across runs: cleared by view_forget
let nav_clips_now : Array[(@view.NodeId, Double, Double)] = []

///|
/// Exposed horizontal strip `(cx0, cx1, from_right)` for covered `beside` page `serial` during horizontal parallax
/// push/pop (`under_parallax < 1.0`, `!top.rise`), or `None` when not clipped.
fn[P] Nav::clip_of(
  self : Nav[P],
  serial : Int,
  transition : NavTransition,
  x : Double,
  w : Double,
  now : Double,
) -> (Double, Double, Bool)? {
  if self.mode == 0 || transition.under_parallax >= 1.0 {
    return None
  }
  let (top, beside) = self.top_beside()
  guard !top.rise && beside is Some(b) && b.serial == serial else { return None }
  let p = dclamp(
    if self.mode == 3 {
      self.p
    } else if self.t0 >= 0.0 {
      self.p_at(now)
    } else {
      self.p
    },
    0.0,
    1.0,
  )
  let way = if (self.from_left)(top.page, top.under) { -1.0 } else { 1.0 }
  let sx = x - way * (p - 1.0) * transition.under_parallax * w
  if way > 0.0 {
    Some((sx, sx + p * w, true))
  } else {
    Some((sx + (1.0 - p) * w, sx + w, false))
  }
}

///|
/// Active horizontal `(cut_left, cut_right)` clip for node `id` if it lives inside a covered `beside` page this frame.
fn nav_clip_for_node(tree : @view.Tree, id : @view.NodeId) -> (Double, Double)? {
  if nav_clips_now.is_empty() {
    return None
  }
  for e in nav_clips_now {
    if tree.holds(e.0, id) {
      return Some((e.1, e.2))
    }
  }
  None
}

///|
/// Paint-time veil (covered-page scrim or foreground 1px leading/top hairline) for page `serial` at `now`.
fn[P] Nav::veil_of(
  self : Nav[P],
  serial : Int,
  transition : NavTransition,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  now : Double,
) -> (Double, Double, Double, Double, Int64)? {
  if self.mode == 0 {
    return None
  }
  let p = if self.mode == 3 {
    self.p
  } else if self.t0 >= 0.0 {
    self.p_at(now)
  } else {
    self.p
  }
  let cover = 1.0 - dclamp(p, 0.0, 1.0)
  let (top, beside) = self.top_beside()
  if beside is Some(b) && b.serial == serial {
    let dim = if top.rise { transition.rise_dim } else { transition.under_dim }
    let ink = nav_scrim_ink(dim * cover)
    if ink != 0L {
      return Some((x, y, w, h, ink))
    }
  }
  if transition.edge_shadow && top.serial == serial {
    let ink = nav_scrim_ink(0.08 * cover)
    if ink != 0L {
      if top.rise {
        return Some((x, y, w, 1.0, ink))
      } else if (self.from_left)(top.page, top.under) {
        return Some((x + w - 1.0, y, 1.0, h, ink))
      } else {
        return Some((x, y, 1.0, h, ink))
      }
    }
  }
  None
}

///|
/// Current moment for a tab-swap property binding on `v`, stopping clock reads once the tab swap ends.
pub fn[P] Nav::tab_moment(self : Nav[P], v : @view.View) -> Double {
  self.swap_said.get() |> ignore
  v.drawn_while(fn(t) { self.swap_t0 >= 0.0 && self.swap_dur > 0.0 && t < self.swap_t0 + self.swap_dur })
}

///|
/// Current normalized slide offset `p` (0 in place .. 1 fully off) at `now`, subscribing to `finger` in mode 3.
fn[P] Nav::live_p(self : Nav[P], now : () -> Double) -> Double {
  if self.mode == 3 {
    self.finger.get() |> ignore
    self.p
  } else if self.t0 >= 0.0 {
    self.p_at(now())
  } else {
    self.p
  }
}

///|
/// Whether the stack is currently in an interactive back gesture (`mode == 3`) or cancelling one (`mode == 4`).
pub fn[P] Nav::in_gesture(self : Nav[P]) -> Bool {
  self.gesture_said.get() |> ignore
  self.mode == 3 || self.mode == 4
}

///|
/// How visible the root page is at `now` (`1.0` at rest on top; `0.0` deeply covered; `p` in `0.0..1.0` while an
/// adjacent page pushes over, pops off, rises over, or is dragged back from the root).
pub fn[P] Nav::root_progress(self : Nav[P], now : () -> Double) -> Double {
  self.said.get() |> ignore
  self.shown.get() |> ignore
  let root = self.pages[0].serial
  let (top, beside) = self.top_beside()
  if top.serial == root {
    1.0
  } else if beside is Some(b) && b.serial == root {
    dclamp(self.live_p(now), 0.0, 1.0)
  } else {
    0.0
  }
}

///|
/// Covered-page scale during `Nav::rise` (`1.0` when not rising or not the covered page).
fn[P] Nav::rise_scale_of(self : Nav[P], serial : Int, now : () -> Double, rise_under_scale : Double) -> Double {
  self.said.get() |> ignore
  self.shown.get() |> ignore
  if self.mode == 0 || rise_under_scale == 1.0 {
    return 1.0
  }
  let (top, beside) = self.top_beside()
  if top.rise && beside is Some(b) && b.serial == serial {
    let cover = 1.0 - dclamp(self.live_p(now), 0.0, 1.0)
    1.0 - (1.0 - rise_under_scale) * cover
  } else {
    1.0
  }
}

///|
/// Whether `page` is currently a root place of the stack (active root, outgoing tab swap, or shelved root).
pub fn[P : Eq] Nav::is_root_place(self : Nav[P], page : P) -> Bool {
  (self.pages.length() > 0 && self.pages[0].page == page) ||
  (self.swap_out is Some(e) && e.page == page) ||
  self.shelf.iter().any(fn(e) { e.page == page })
}

///|
/// Whether `serial` is the outgoing root page of an active `Nav::replace_tab` transition.
pub fn[P] Nav::is_swapping_out(self : Nav[P], serial : Int) -> Bool {
  self.swap_said.get() |> ignore
  self.swap_out is Some(e) && e.serial == serial
}

///|
/// Whether `serial` is the incoming root page while an outgoing root page is still fading out.
pub fn[P] Nav::is_swapping_in(self : Nav[P], serial : Int) -> Bool {
  self.swap_said.get() |> ignore
  self.swap_out is Some(_) && self.pages.length() == 1 && self.pages[0].serial == serial
}

///|
/// End timestamp (ms) of the current root tab transition, or `-1.0` when none is running.
pub fn[P] Nav::tab_ends_at(self : Nav[P]) -> Double {
  self.swap_said.get() |> ignore
  if self.swap_t0 >= 0.0 && self.swap_dur > 0.0 {
    self.swap_t0 + self.swap_dur
  } else {
    -1.0
  }
}

///|
/// Closed-form `(dx, alpha)` for a root page's body during `Nav::replace_tab` using critically damped `Ease::Move`
/// handoff with zero dead valley and `max(min(out_alpha, in_alpha)) = 0.052 < 0.12` (zero `words_over` at any FPS):
/// - outgoing page exits over `0..27%` (`~70ms` at `260ms`): slides `0 -> -way * (slide * 0.5)` and fades `1 -> 0` (`Ease::Move`);
/// - incoming page enters over `12.5%..100%` (`~32.5..260ms`): slides `way * slide -> 0` and fades `0 -> 1` (`Ease::Move`).
pub fn[P] Nav::tab_body_motion(
  self : Nav[P],
  serial : Int,
  now : () -> Double,
  slide? : Double = 22.0,
) -> (Double, Double) {
  self.swap_said.get() |> ignore
  if self.swap_t0 < 0.0 || self.swap_dur <= 0.0 {
    return (0.0, 1.0)
  }
  let is_out = self.swap_out is Some(e) && e.serial == serial
  let is_in = self.swap_in_serial == serial && self.pages.length() == 1 && self.pages[0].serial == serial
  if !is_out && !is_in {
    return (0.0, 1.0)
  }
  let gone = @flex.time_gone(now(), self.swap_t0)
  if gone >= self.swap_dur {
    return if is_out { (-self.swap_way.to_double() * (slide * 0.5), 0.0) } else { (0.0, 1.0) }
  }
  let t = dmax(0.0, gone)
  let frac = dclamp(t / self.swap_dur, 0.0, 1.0)
  let out_end = 0.27
  let in_start = 0.125
  let way = self.swap_way.to_double()
  if is_out {
    let out_p = dmin(1.0, frac / out_end)
    let prog = Ease::Move.at(out_p)
    (-way * (slide * 0.5) * prog, 1.0 - prog)
  } else {
    let in_p = dclamp((frac - in_start) / (1.0 - in_start), 0.0, 1.0)
    let prog = Ease::Move.at(in_p)
    (way * slide * (1.0 - prog), prog)
  }
}

///|
/// Closed-form opacity for a decoupled root top bar's title and page-specific actions during `Nav::replace_tab`
/// (soft cross-fade in over `ms`, default `180ms Ease::Move`, matching the body spring cadence with zero drift).
pub fn[P] Nav::tab_title_alpha(
  self : Nav[P],
  serial : Int,
  now : () -> Double,
  ms? : Double = 180.0,
) -> Double {
  self.swap_said.get() |> ignore
  if self.swap_out is Some(e) && e.serial == serial {
    return 0.0
  }
  if self.swap_t0 < 0.0 || self.swap_dur <= 0.0 || ms <= 0.0 {
    return 1.0
  }
  if self.swap_in_serial != serial || self.pages.length() != 1 || self.pages[0].serial != serial {
    return 1.0
  }
  let gone = @flex.time_gone(now(), self.swap_t0)
  if gone >= ms {
    1.0
  } else {
    Ease::Move.at(dclamp(dmax(0.0, gone) / ms, 0.0, 1.0))
  }
}

///|
/// Current tab swap state for `serial`: `(active, is_outgoing, progress)` at `now`.
pub fn[P] Nav::swap_state(self : Nav[P], serial : Int, now : () -> Double) -> (Bool, Bool, Double) {
  self.swap_said.get() |> ignore
  if self.swap_t0 < 0.0 || self.swap_dur <= 0.0 {
    return (false, false, 1.0)
  }
  let is_out = self.swap_out is Some(e) && e.serial == serial
  let is_in = self.swap_in_serial == serial && self.pages.length() == 1 && self.pages[0].serial == serial
  if !is_out && !is_in {
    return (false, false, 1.0)
  }
  let gone = @flex.time_gone(now(), self.swap_t0)
  if gone >= self.swap_dur {
    (false, is_out, 1.0)
  } else {
    (true, is_out, dclamp(dmax(0.0, gone) / self.swap_dur, 0.0, 1.0))
  }
}
