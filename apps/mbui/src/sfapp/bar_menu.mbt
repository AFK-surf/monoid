// The bottom bar's last slot and the menu it grows into, as Comma's tab bar has them (Comma Android's TabMenuMorph.kt,
// TabBarGeometry.kt and ShellTabBar.kt, themselves the iOS app's GlassTabBar): the places kept in the prefs' bars,
// taken in their order, the first three each a slot of the bar and the rest the rows of a menu the fourth slot stands
// for (with four places or fewer, each a slot and no menu). One spring drives the glass's height and everything else
// is read off that height (how far it has grown), so what the glass shows always matches its size, and a close during
// the opening turns the same spring round from where it is, at the speed it has; a second spring, struck and never
// sent anywhere, pinches the glass along the bar. Both are ways said once at their cause (@motion.Way: where each is
// at a moment is a function of that moment alone, whatever frames are drawn), where Comma steps them 1/480 s at a time.

// ── measures (TabBarGeometry.kt TabBarMetrics, ShellTabBar.kt's companion) ────────────────────────────────

///|
/// How far a finger that opened the menu moves up off the bar before it picks rows (MENU_REACH).
let menu_reach : Double = 20.0

///|
/// How long a dragging finger rests on the last slot before the menu opens, and how far it may stir meanwhile
/// (MENU_DWELL_MS, DWELL_SLOP).
let menu_dwell_ms : Double = 300.0

///|
let dwell_slop : Double = 8.0

///|
/// How far above the bar a finger still counts as on its last slot (MENU_SLOT_REACH).
let menu_slot_reach : Double = 20.0

///|
/// How far to either side of the menu a finger still picks its rows (ROW_SLACK).
let row_slack : Double = 24.0

///|
/// How far the outgoing and incoming contents blur while the bar turns into the menu and back (MORPH_BLUR: 12 dp, the
/// radius RenderEffect.createBlurEffect takes; the deviation it blurs by, which a content lens takes, is 0.57735 of it
/// and half a pixel, at three pixels a point).
let morph_blur : Double = 12.0 * 0.57735 + 0.5 / 3.0

///|
/// How much larger the whole bar goes under a press (PRESS_GROWTH), and glyphs under the lifted lens on top of that
/// (LENS_ZOOM), the zoom coming in over half a glyph either side of the lens's edge (GLYPH_HALF).
let press_growth : Double = 0.0486

///|
let lens_zoom : Double = 1.15

///|
let glyph_half : Double = 14.0

///|
/// How much shorter the glass is at the peak of its pinch, opening and closing (TabMenuMorph.kt PINCH_OPEN,
/// PINCH_CLOSE).
let pinch_open : Double = 0.20

///|
let pinch_close : Double = 0.18

///|
/// Each row rises from this far below and settles, one after another from the bottom, fading in as it comes
/// (ROW_RISE, ROW_DELAY_MS, ROW_STAGGER_MS, ROW_FADE_MS).
let row_rise : Double = 14.0

///|
let row_delay_ms : Double = 45.0

///|
let row_stagger_ms : Double = 32.0

///|
let row_fade_ms : Double = 160.0

///|
/// The menu's indicator: how fast it follows the finger to a new row and fades in or out (INDICATOR_FOLLOW,
/// INDICATOR_FADE, ms), and by how far into the glass's growth a lens it starts from has turned grey (LENS_TO_GREY).
let indicator_follow_ms : Double = 50.0

///|
let indicator_fade_ms : Double = 80.0

///|
let lens_to_grey : Double = 0.35

///|
/// A lens lifted less than this when the menu opens has not left the selection, and hands nothing over
/// (HANDOFF_LIFT).
let handoff_lift : Double = 0.05

// ── the places: slots and rows ─────────────────────────────────────────────

///|
/// How high the bar's glass is as a menu of `rows` rows (TabBarGeometry.kt menuHeight).
fn bar_menu_h(rows : Int) -> Double {
  if rows <= 0 {
    bar_track
  } else {
    dmax(bar_track, rows.to_double() * @sf.bar_menu_row_h + 2.0 * @sf.bar_menu_pad)
  }
}

///|
/// The row of a menu of `rows` rows `cw` long under (`x`, `y`), `y` from the menu's top, or -1 off the menu: a finger a
/// little to either side still picks (TabBarGeometry.kt rowAt).
fn bar_row_at(x : Double, y : Double, cw : Double, rows : Int) -> Int {
  if rows <= 0 || x < -row_slack || x > cw + row_slack || y < 0.0 || y > bar_menu_h(rows) {
    return -1
  }
  dclamp(((y - @sf.bar_menu_pad) / @sf.bar_menu_row_h).floor(), 0.0, (rows - 1).to_double()).to_int()
}

///|
/// How the two contents cross as the glass grows, by how far it has grown: the tab row leaves over the first 60 % and
/// the rows arrive from 20 %, so the glass is never empty (TabMenuMorph.kt tabsOpacity, rowsOpacity).
fn tabs_opacity(p : Double) -> Double {
  1.0 - bar_smoothstep(0.0, 0.6, p)
}

///|
fn rows_opacity(p : Double) -> Double {
  bar_smoothstep(0.2, 0.9, p)
}

///|
/// How the lens zooms a glyph centred `reach` from the lens's middle: in place, from none to `lens_zoom` as the lens
/// comes over it, over half a glyph either side of the lens's edge, so a glyph the edge crosses is never split in two
/// sizes, and one the lens is not over is not touched (TabBarGeometry.kt lensGlyphZoom).
fn lens_glyph_zoom(reach : Double, lens_w : Double, lift : Double) -> Double {
  let half = lens_w / 2.0
  let under = 1.0 - bar_smoothstep(half - glyph_half, half + glyph_half, reach.abs())
  1.0 + (lens_zoom - 1.0) * lift * under
}

// ── a number easing to where it is sent ─────────────────────────────────────

///|
/// A number easing towards where it is sent, the rest of its way less by 1/e each `tau` ms (ShellTabBar.kt's
/// indicator: `x += (to - x) * (1 - exp(-dt / tau))` each frame, which is this whatever the frames): said once as it is
/// sent, where it is at a moment a function of that moment alone.
priv struct Follow {
  mut from : Double
  mut to : Double
  mut t0 : Double
  tau : Double
}

///|
fn Follow::at(self : Follow, t : Double) -> Double {
  if t <= self.t0 || self.from == self.to {
    self.from
  } else {
    self.to + (self.from - self.to) * @dmath.exp(-(t - self.t0) / self.tau)
  }
}

///|
fn Follow::go(self : Follow, to : Double, at : Double) -> Unit {
  if to == self.to && self.from == self.to {
    return
  }
  self.from = self.at(at)
  self.to = to
  self.t0 = at
}

///|
fn Follow::put(self : Follow, v : Double) -> Unit {
  self.from = v
  self.to = v
  self.t0 = 0.0
}

///|
/// When it is within `eps` of where it goes (the frames' clock, ms; -1: it is).
fn Follow::end(self : Follow, eps : Double) -> Double {
  let d = (self.from - self.to).abs()
  if d <= eps {
    -1.0
  } else {
    self.t0 + self.tau * @dmath.ln(d / eps)
  }
}

// ── the indicator ──────────────────────────────────────────────────────────

///|
/// A rect in the glass's coordinates (along the bar's full length, down from the glass's top), kept either from its
/// top edge, as the rows are, or from its bottom edge, which does not move on screen while the glass grows
/// (ShellTabBar.kt Anchored).
priv struct Anchored {
  l : Double
  r : Double
  /// its top: down from the glass's top, or (from the bottom) up from the glass's bottom
  top : Double
  h : Double
  from_bottom : Bool
}

///|
fn Anchored::of(rect : (Double, Double, Double, Double), from_bottom : Bool, height : Double) -> Anchored {
  let (l, t, r, b) = rect
  { l, r, top: if from_bottom { height - t } else { t }, h: b - t, from_bottom }
}

///|
/// One given in the bar's own track (`y` down from the track's top), kept from the glass's bottom.
fn Anchored::on_track(l : Double, y : Double, r : Double, h : Double) -> Anchored {
  { l, r, top: bar_track - y, h, from_bottom: true }
}

///|
fn Anchored::resolve(self : Anchored, height : Double) -> (Double, Double, Double, Double) {
  let t = if self.from_bottom { height - self.top } else { self.top }
  (self.l, t, self.r, t + self.h)
}

///|
/// The indicator travels from `from` to `to` (the row it points at, when none) as the glass's growth goes from
/// `from_p` to `to_p`: tied to the glass, it starts where it is and turns round with it (ShellTabBar.kt Leg).
priv struct IndLeg {
  from : Anchored
  from_p : Double
  to : IndTo
  to_p : Double
  start_alpha : Double
  /// it began as the lens: clear glass turning grey
  from_glass : Bool
  closing : Bool
  /// closing into the bar's selection, which it becomes where it ends
  into_selection : Bool
}

///|
/// Where a leg of the indicator's ends: on the row it points at, wherever that is then; where it stood as the leg
/// began; or on the bar's selection at rest on the last slot, where the bar has that slot then (the notch may open or
/// close under it as the page picked comes in).
priv enum IndTo {
  Row
  Stays(Anchored)
  Selection
}

///|
/// The indicator at a moment: where (the glass's coordinates), how much of it shows, how grey it has turned and how
/// clear the lens it began as still is.
priv struct IndAt {
  l : Double
  t : Double
  r : Double
  b : Double
  alpha : Double
  grey : Double
  clear : Double
}

///|
// kept across runs: a value (no field of it changes)
let ind_none : IndAt = { l: 0.0, t: 0.0, r: 0.0, b: 0.0, alpha: 0.0, grey: 1.0, clear: 0.0 }

// ── the menu ───────────────────────────────────────────────────────────────

///|
/// The bar's glass on its way to the menu and back, and what goes with it (TabMenuMorph.kt, ShellTabBar.kt's menu).
priv struct BarMenu {
  /// the menu open (or opening): its rows the keyboard's and a screen reader's, a finger anywhere its
  open : @signals.Signal[Bool]
  /// the glass's height (points): the bar's at rest, the menu's when open
  h : @motion.Way
  /// how much shorter along the bar the glass is, as a share of the bar's length
  pinch : @motion.Way
  /// how many rows the menu has, and which the place shown is (-1 none of them), as the bar was last told
  mut rows : Int
  mut active_row : Int
  /// the finger that opened the menu, or came down on it, is still down and picks a row by where it is
  mut tracking : Bool
  /// where down the finger was when it opened the menu: rows answer only once it has moved up off it
  mut open_y : Double?
  /// a finger has picked through the rows during this press: off the menu it points at nothing
  mut in_rows : Bool
  mut hovered_row : Int
  /// the row under a finger that dragged the lens to the last slot and has not moved into the menu yet
  mut open_row : Int
  mut picked_row : Int
  /// whether the page shown as the menu opened, or picked in it, is one of the menu's
  mut anchor_more : Bool
  /// the rows rising since this moment (-1: never), each from the offset and the opacity it had then
  mut rise_at : Double
  mut rows_dy0 : Array[Double]
  mut rows_a0 : Array[Double]
  /// from here the rows leave together, by how far the glass has folded of what it had grown as the close began
  mut rows_closing : Bool
  mut close_p : Double
  /// how much of the bar's selection showed as the menu opened: opening never brings it back
  mut pill0 : Double
  mut leg : IndLeg?
  /// the row the indicator points at (rows down from the top, eased towards a new row as the finger moves), once one
  /// was pointed at; how much of it shows
  mut has_target : Bool
  target : Follow
  shown : Follow
  /// the lens the indicator began as goes with it, as much a glass as it was then (-1: none carried)
  mut carry : Double
  /// the zoom each glyph had under the lens that opened the menu, and how much of it the glyphs still hold; how far
  /// the glass had grown when a close began while they still held it
  mut held_zoom : Array[Double]
  mut zoom_held : Double
  mut zoom_close_from : Double
  /// the bar letting its press go by itself once the lens that carried it is taken away
  press_down : @motion.Way
  /// a finger resting on the last slot, waited for (`menu_dwell_ms` within `dwell_slop`)
  dwell : @view.Dwell
  /// when it was last told to open, close or point elsewhere (what reads it read again: bar_part_told)
  mut told_at : Double
}

///|
// kept across runs: put back by bar_reset
let bar_menu : BarMenu = {
  open: @signals.signal(false, same=fn(a, b) { a == b }),
  h: @motion.Way::new(bar_track),
  pinch: @motion.Way::new(0.0),
  rows: 0,
  active_row: -1,
  tracking: false,
  open_y: None,
  in_rows: false,
  hovered_row: -1,
  open_row: -1,
  picked_row: -1,
  anchor_more: false,
  rise_at: -1.0,
  rows_dy0: [],
  rows_a0: [],
  rows_closing: true,
  close_p: 1.0,
  pill0: 1.0,
  leg: None,
  has_target: false,
  target: { from: 0.0, to: 0.0, t0: 0.0, tau: indicator_follow_ms },
  shown: { from: 0.0, to: 0.0, t0: 0.0, tau: indicator_fade_ms },
  carry: -1.0,
  held_zoom: [1.0, 1.0, 1.0, 1.0],
  zoom_held: 0.0,
  zoom_close_from: 0.0,
  press_down: @motion.Way::new(0.0),
  dwell: @view.Dwell::new(menu_dwell_ms, dwell_slop),
  told_at: 0.0,
}

///|
/// As at the start (tests).
fn BarMenu::reset(self : BarMenu) -> Unit {
  self.dwell.off()
  self.open.set(false)
  self.h.put(bar_track)
  self.pinch.put(0.0)
  self.rows = 0
  self.active_row = -1
  self.tracking = false
  self.open_y = None
  self.in_rows = false
  self.hovered_row = -1
  self.open_row = -1
  self.picked_row = -1
  self.anchor_more = false
  self.rise_at = -1.0
  self.rows_dy0 = []
  self.rows_a0 = []
  self.rows_closing = true
  self.close_p = 1.0
  self.pill0 = 1.0
  self.leg = None
  self.has_target = false
  self.target.put(0.0)
  self.shown.put(0.0)
  self.carry = -1.0
  self.held_zoom = [1.0, 1.0, 1.0, 1.0]
  self.zoom_held = 0.0
  self.zoom_close_from = 0.0
  self.press_down.put(0.0)
  self.told_at = 0.0
}

///|
/// The glass's height at `t`.
fn BarMenu::height_at(self : BarMenu, t : Double) -> Double {
  self.h.value_at(t)
}

///|
/// The glass's length along the bar at `t` as a share of the bar's (TabMenuMorph.kt majorScale).
fn BarMenu::major_at(self : BarMenu, t : Double) -> Double {
  1.0 - dmax(0.0, self.pinch.value_at(t))
}

///|
/// How high the menu is.
fn BarMenu::full(self : BarMenu) -> Double {
  bar_menu_h(self.rows)
}

///|
/// How far the glass has grown from the bar to the menu at `t`, 0 to 1 (TabMenuMorph.kt progress).
fn BarMenu::progress_at(self : BarMenu, t : Double) -> Double {
  let span = self.full() - bar_track
  if span > 0.0 {
    dclamp((self.height_at(t) - bar_track) / span, 0.0, 1.0)
  } else {
    0.0
  }
}

///|
/// When both of the glass's springs are at rest (the frames' clock, ms; -1: they are).
fn BarMenu::morph_ends(self : BarMenu) -> Double {
  dmax(self.h.ends_at(), self.pinch.ends_at())
}

///|
/// Whether the bar is the menu or on its way there or back at `t` (ShellTabBar.kt `menuOpen || morph.running`).
fn BarMenu::busy_at(self : BarMenu, t : Double) -> Bool {
  self.open.untracked() || t < self.morph_ends()
}

///|
/// How much of the tab row shows at `t`: 1 at rest, 0 while the bar is the menu.
fn BarMenu::tabs_shown_at(self : BarMenu, t : Double) -> Double {
  if self.busy_at(t) {
    tabs_opacity(self.progress_at(t))
  } else {
    1.0
  }
}

///|
/// How much of the bar's own selection shows at `t` while the bar is the menu or on its way (None at rest, the
/// lens's to say): it belongs to the tab row, shows as the row does, and opening never brings it back; none of it
/// where the indicator stands in for it (the page shown one of the menu's).
fn BarMenu::pill_at(self : BarMenu, t : Double) -> Double? {
  if !self.busy_at(t) {
    return None
  }
  let shown = self.tabs_shown_at(t)
  Some(
    if self.anchor_more {
      0.0
    } else if self.open.untracked() {
      dmin(self.pill0, shown)
    } else {
      shown
    },
  )
}

///|
/// How much of the zoom the glyphs had under the lens that opened the menu they still hold at `t`: all of it while the
/// tab row is still seen fading away with the lens, none once the row is hidden; a close that comes before that lets
/// it go with the glass's way back to the bar (ShellTabBar.kt holdZoom).
fn BarMenu::zoom_share_at(self : BarMenu, t : Double) -> Double {
  if self.zoom_held <= 0.0 || !self.busy_at(t) || self.tabs_shown_at(t) <= 0.001 {
    0.0
  } else if !self.open.untracked() && self.zoom_close_from > 0.0 {
    self.zoom_held * dclamp(self.progress_at(t) / self.zoom_close_from, 0.0, 1.0)
  } else {
    self.zoom_held
  }
}

///|
/// How far the pressed bar has grown at `t` beyond what its lens lifts it (`lift`), 0 to 1: the lens's lift while it
/// is up, let down by itself once the lens is taken away.
fn BarMenu::press_at(self : BarMenu, t : Double, lift : Double) -> Double {
  dclamp(dmax(lift, self.press_down.value_at(t)), 0.0, 1.0)
}

///|
/// The glass struck and sent to the menu's height from `t` (TabMenuMorph.kt open): a strike on a spring at rest peaks
/// at its speed over (omega e), this one at `pinch_open` of the bar.
fn BarMenu::morph_open(self : BarMenu, t : Double) -> Unit {
  let omega = 2.0 * 3.141592653589793 / 0.50
  self.pinch.go(0.0, @motion.tab_menu_pinch_open_spring, at=t, velocity=pinch_open * omega * 2.718281828459045)
  self.h.go(self.full(), @motion.tab_menu_open_spring, at=t)
}

///|
/// The glass struck and sent back to the bar's height from `t` (TabMenuMorph.kt close): one still drawn in from its
/// opening is not struck twice as hard.
fn BarMenu::morph_close(self : BarMenu, t : Double) -> Unit {
  let omega = 2.0 * 3.141592653589793 / 0.36
  let (x, v) = self.pinch.at(t)
  let headroom = dmax(0.0, 1.0 - x / pinch_close)
  self.pinch.go(
    0.0,
    @motion.tab_menu_pinch_close_spring,
    at=t,
    velocity=dmax(v, pinch_close * omega * 2.718281828459045 * headroom),
  )
  self.h.go(bar_track, @motion.tab_menu_close_spring, at=t)
}

///|
/// The glass the bar's again at once, nothing moving (TabMenuMorph.kt rest).
fn BarMenu::morph_rest(self : BarMenu) -> Unit {
  self.h.put(bar_track)
  self.pinch.put(0.0)
}

// ── the rows ───────────────────────────────────────────────────────────────

///|
/// Row `i`'s own offset down and opacity at `t` as it rises (ShellTabBar.kt riseRows): each drops `row_rise` and
/// springs back up in turn, from the row nearest the bar to the top, fading in over `row_fade_ms` as it comes; from
/// where it was as the menu opened, where a close was turned round.
fn BarMenu::row_at(self : BarMenu, i : Int, t : Double) -> (Double, Double) {
  if self.rise_at < 0.0 || i >= self.rows_dy0.length() {
    return (0.0, 1.0)
  }
  let start = self.rise_at + row_delay_ms + row_stagger_ms * (self.rows - 1 - i).to_double()
  let dy0 = self.rows_dy0[i]
  let a0 = self.rows_a0[i]
  if t <= start {
    return (dy0, a0)
  }
  let spec = @motion.tab_menu_row_spring
  let dy = spec.value_at(t - start, spec.duration(dy0, 0.0, 0.0), dy0, 0.0, 0.0).0
  let fade = (@motion.ease_out)(dclamp((t - start) / row_fade_ms, 0.0, 1.0))
  (dy, a0 + (1.0 - a0) * fade)
}

///|
/// When every row has risen (the frames' clock, ms; -1: none rises).
fn BarMenu::rows_end(self : BarMenu) -> Double {
  if self.rise_at < 0.0 {
    return -1.0
  }
  let spec = @motion.tab_menu_row_spring
  self.rise_at +
  row_delay_ms +
  row_stagger_ms * dmax(0.0, (self.rows - 1).to_double()) +
  dmax(row_fade_ms, spec.duration(row_rise, 0.0, 0.0).ceil())
}

///|
/// How much of the rows together shows at `t`: all while the menu opens (each row its own), and from a close on by
/// how far the glass has folded back (ShellTabBar.kt applyGlass: rowsOpacity of the glass's growth; of what it had
/// grown as the close began, so a close that turns an opening round starts from what showed).
fn BarMenu::rows_shown_at(self : BarMenu, t : Double) -> Double {
  if !self.rows_closing {
    1.0
  } else if !self.busy_at(t) || self.close_p <= 0.0 {
    0.0
  } else {
    rows_opacity(dclamp(self.progress_at(t) / self.close_p, 0.0, 1.0))
  }
}

///|
/// The rows set rising from `t`, each from where it is then.
fn BarMenu::rise(self : BarMenu, t : Double) -> Unit {
  let shown = self.rows_shown_at(t)
  let dy0 : Array[Double] = []
  let a0 : Array[Double] = []
  for i in 0..<self.rows {
    let (dy, a) = self.row_at(i, t)
    let was = shown * a
    // (one not seen starts its rise from below; one still seen goes on from where it is)
    if was <= 0.001 {
      dy0.push(row_rise)
      a0.push(0.0)
    } else {
      dy0.push(dy)
      a0.push(was)
    }
  }
  self.rows_dy0 = dy0
  self.rows_a0 = a0
  self.rise_at = t
  self.rows_closing = false
}

// ── the indicator ──────────────────────────────────────────────────────────

///|
/// The row the indicator points at, or -1 (ShellTabBar.kt indicatorRow).
fn BarMenu::indicator_row(self : BarMenu) -> Int {
  if !self.open.untracked() {
    -1
  } else if self.tracking && self.in_rows {
    self.hovered_row
  } else if self.hovered_row >= 0 {
    self.hovered_row
  } else if self.open_row >= 0 {
    self.open_row
  } else {
    self.active_row
  }
}

///|
/// Row `r` (rows down from the top, between rows as the indicator eases) as it stands once the menu is open, in the
/// glass's coordinates at `height`, the bar `cw` long (ShellTabBar.kt rowFromBottom).
fn BarMenu::row_rect(self : BarMenu, r : Double, height : Double, cw : Double) -> (Double, Double, Double, Double) {
  let top = height - self.full() + @sf.bar_menu_pad + r * @sf.bar_menu_row_h
  (@sf.bar_menu_pad, top, cw - @sf.bar_menu_pad, top + @sf.bar_menu_row_h)
}

///|
/// The indicator at `t`, the bar `cw` long, its selection at rest on the last slot `rest` then (ShellTabBar.kt
/// updateIndicator, as a function of the moment).
fn BarMenu::ind_at(self : BarMenu, t : Double, cw : Double, rest : Anchored) -> IndAt {
  let closing = match self.leg {
    Some(leg) => leg.closing
    None => false
  }
  if !self.busy_at(t) || (!self.open.untracked() && !closing) {
    return ind_none
  }
  let height = self.height_at(t)
  let p = self.progress_at(t)
  let target = if self.has_target { Some(self.row_rect(self.target.at(t), height, cw)) } else { None }
  match self.leg {
    Some(leg) => {
      let span = leg.to_p - leg.from_p
      let u = if span == 0.0 { 1.0 } else { dclamp((p - leg.from_p) / span, 0.0, 1.0) }
      let (l0, t0, r0, b0) = leg.from.resolve(height)
      let (l1, t1, r1, b1) = match leg.to {
        Stays(to) => to.resolve(height)
        Selection => rest.resolve(height)
        Row => target.unwrap_or((l0, t0, r0, b0))
      }
      let mut grey = 1.0
      let mut clear = 0.0
      let alpha = if leg.closing {
        // (into the selection it comes up whole before it lands, so the bar's own takes over unseen)
        if leg.into_selection {
          leg.start_alpha + (1.0 - leg.start_alpha) * bar_smoothstep(0.0, 0.45, u)
        } else {
          leg.start_alpha * dmin(1.0, (1.0 - u) * 1.5)
        }
      } else {
        if leg.from_glass {
          grey = bar_smoothstep(0.0, lens_to_grey, u)
          clear = 1.0 - grey
        }
        leg.start_alpha + (self.shown.at(t) - leg.start_alpha) * u
      }
      {
        l: l0 + (l1 - l0) * u,
        t: t0 + (t1 - t0) * u,
        r: r0 + (r1 - r0) * u,
        b: b0 + (b1 - b0) * u,
        alpha: dclamp(alpha, 0.0, 1.0),
        grey,
        clear,
      }
    }
    None =>
      match target {
        Some((l, top, r, b)) =>
          { l, t: top, r, b, alpha: dclamp(self.shown.at(t) * rows_opacity(p), 0.0, 1.0), grey: 1.0, clear: 0.0 }
        None => ind_none
      }
  }
}

///|
/// What the indicator points at told anew at `t` (a finger moved to another row, off the rows, or the page shown
/// another): it eases there from where it is, and fades in or out; the first row pointed at, there at once.
fn BarMenu::retarget(self : BarMenu, t : Double) -> Unit {
  let row = self.indicator_row()
  if row >= 0 {
    if self.has_target {
      self.target.go(row.to_double(), t)
    } else {
      self.has_target = true
      self.target.put(row.to_double())
    }
  }
  self.shown.go(if row < 0 { 0.0 } else { 1.0 }, t)
  self.told_at = t
}

///|
/// Where the indicator starts as the menu opens at `t`: the lifted lens (`lens`: where it is in the bar's track, lifted
/// `lift`), the bar's selection on the last slot (`rest`, in the track), or what it showed when a close is turned
/// round (ShellTabBar.kt startIndicator). `cur`: the indicator as it was at `t`, before the menu was said open.
fn BarMenu::start_indicator(
  self : BarMenu,
  t : Double,
  cur : IndAt,
  tracking : Bool,
  lift : Double,
  lens : Anchored,
  rest : Anchored,
) -> Unit {
  let height = self.height_at(t)
  let p = self.progress_at(t)
  self.picked_row = -1
  // (a finger that dragged the lens to the last slot points at the row nearest it until it moves)
  self.open_row = if tracking && lift > handoff_lift {
    if self.active_row >= 0 { self.active_row } else { self.rows - 1 }
  } else {
    -1
  }
  self.has_target = false
  self.carry = -1.0
  self.leg = if cur.alpha > 0.01 && self.leg is Some(_) {
    Some({
      from: Anchored::of((cur.l, cur.t, cur.r, cur.b), true, height),
      from_p: p,
      to: Row,
      to_p: 1.0,
      start_alpha: cur.alpha,
      from_glass: false,
      closing: false,
      into_selection: false,
    })
  } else if lift > handoff_lift {
    self.carry = dclamp(lift, 0.0, 1.0)
    Some({
      from: lens,
      from_p: p,
      to: Row,
      to_p: 1.0,
      start_alpha: 1.0,
      from_glass: true,
      closing: false,
      into_selection: false,
    })
  } else if self.anchor_more {
    Some({
      from: rest,
      from_p: p,
      to: Row,
      to_p: 1.0,
      start_alpha: 1.0,
      from_glass: false,
      closing: false,
      into_selection: false,
    })
  } else {
    None
  }
  self.shown.put(if self.leg is None { 0.0 } else { 1.0 })
  self.retarget(t)
}

///|
/// As the menu closes at `t` the indicator stays on its row and fades with it, or folds back into the bar's selection
/// on the last slot when the page shown is in the menu (ShellTabBar.kt endIndicator). `cur`: the indicator as it was
/// at `t`, before the menu was said closed; `rest`: the selection at rest on the last slot then; `cw`: how long the
/// bar is.
fn BarMenu::end_indicator(self : BarMenu, t : Double, cur : IndAt, rest : Anchored, cw : Double) -> Unit {
  let height = self.height_at(t)
  let p = self.progress_at(t)
  self.told_at = t
  if p <= 0.01 {
    self.leg = None
    self.carry = -1.0
    return
  }
  if self.anchor_more {
    let row = if self.picked_row >= 0 {
      self.picked_row
    } else if self.hovered_row >= 0 {
      self.hovered_row
    } else {
      self.active_row
    }
    let (from, start_alpha) = if cur.alpha > 0.05 {
      (Anchored::of((cur.l, cur.t, cur.r, cur.b), true, height), cur.alpha)
    } else if row >= 0 {
      (Anchored::of(self.row_rect(row.to_double(), height, cw), true, height), 0.0)
    } else {
      (rest, 0.0)
    }
    self.leg = Some({
      from,
      from_p: p,
      to: Selection,
      to_p: 0.0,
      start_alpha,
      from_glass: false,
      closing: true,
      into_selection: true,
    })
    return
  }
  if cur.alpha <= 0.01 {
    self.leg = None
    self.carry = -1.0
    return
  }
  let current = Anchored::of((cur.l, cur.t, cur.r, cur.b), false, height)
  self.leg = Some({
    from: current,
    from_p: p,
    to: Stays(current),
    to_p: 0.0,
    start_alpha: cur.alpha,
    from_glass: false,
    closing: true,
    into_selection: false,
  })
}

///|
/// When all of the menu is at rest (the frames' clock, ms; before now, or -1: it is): its glass, its rows, its
/// indicator's easing, the bar's press let go.
fn BarMenu::rest(self : BarMenu) -> Double {
  let mut e = dmax(self.morph_ends(), self.press_down.ends_at())
  if self.open.untracked() {
    e = dmax(e, self.rows_end())
    e = dmax(e, dmax(self.target.end(0.002), self.shown.end(0.004)))
  }
  e
}

///|
/// The wait of a finger resting on the last slot called off (ShellTabBar.kt cancelDwell).
fn BarMenu::cancel_dwell(self : BarMenu) -> Unit {
  self.dwell.off()
}
