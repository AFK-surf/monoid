// Where what floats beside what opened it goes (a menu under its button, a submenu beside its item, a combobox's list
// under its field), and how fast a list scrolls by itself as a drag is held near its edge: worked out of numbers alone,
// for a look to place and move what it draws. Nothing here makes a node or says anything of one (headless.mbt): the
// side a menu opened on, which decides the arrow key that closes a submenu, is what `AnchorPlaced::side` gives the
// caller, who gives that to the menu (`close_key`) and its look alike.

///|
/// A side of what opened it that something floating goes on.
#derive(Eq, Debug)
pub(all) enum AnchorSide {
  Below
  Above
  Right
  Left
}

///|
/// The key that goes back toward what opened something floating on `self`'s side (ui's key codes: ← 3, → 4, ↑ 5, ↓ 6):
/// a submenu opened on the right is closed by ←. For a menu's `close_key`.
pub fn AnchorSide::back_key(self : AnchorSide) -> Int {
  match self {
    Below => 5
    Above => 6
    Right => 3
    Left => 4
  }
}

///|
/// Where something floating is asked to go beside what opened it: the side (`Below`, `Above`, `Right`, `Left`), then
/// how it lines up along that side (`Start`: its left or top edge with the opener's; `Center`; `End`: its right or
/// bottom edge with the opener's).
#derive(Eq, Debug)
pub(all) enum Placement {
  BelowStart
  BelowCenter
  BelowEnd
  AboveStart
  AboveCenter
  AboveEnd
  RightStart
  RightCenter
  RightEnd
  LeftStart
  LeftCenter
  LeftEnd
}

///|
/// The side `self` asks for.
pub fn Placement::side(self : Placement) -> AnchorSide {
  match self {
    BelowStart | BelowCenter | BelowEnd => Below
    AboveStart | AboveCenter | AboveEnd => Above
    RightStart | RightCenter | RightEnd => Right
    LeftStart | LeftCenter | LeftEnd => Left
  }
}

///|
/// How far along its side `self` lines up: 0 its start, 0.5 its middle, 1 its end.
fn Placement::along(self : Placement) -> Double {
  match self {
    BelowStart | AboveStart | RightStart | LeftStart => 0.0
    BelowCenter | AboveCenter | RightCenter | LeftCenter => 0.5
    _ => 1.0
  }
}

///|
/// Where something floating goes: its top left (`x`, `y`, the window's points), the side it went on (`side`: the one
/// asked, or the other where `flipped`), and the room it has on that side (`room`: from the gap to the safe area's
/// edge, along the side's axis: as tall as a list under its field may grow, or as wide as a submenu beside its item).
#derive(Eq, Debug)
pub(all) struct AnchorPlaced {
  x : Double
  y : Double
  side : AnchorSide
  flipped : Bool
  room : Double
}

///|
/// `v` within `lo` and `hi`, at `lo` where they cross (what is bigger than the room starts at its start).
fn clamp_in(v : Double, lo : Double, hi : Double) -> Double {
  if hi < lo || v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Something `size` (width, height) floating beside `anchor` (what opened it: x, y, width, height), in a window
/// `view` (width, height) whose safe area is it less `insets` (top, right, bottom, left: the system's bars, a notch,
/// a keyboard), `gap` off it, on the side `placement` asks. It goes on the other side where it does not fit on the one
/// asked and there is more room on the other (flipped); then it is moved along both axes into the safe area, so no part
/// of it is outside where it fits there at all (bigger than the safe area: at its start).
pub fn anchor_place(
  anchor : (Double, Double, Double, Double),
  size : (Double, Double),
  view : (Double, Double),
  placement? : Placement = BelowStart,
  gap? : Double = 0.0,
  insets? : (Double, Double, Double, Double) = (0.0, 0.0, 0.0, 0.0),
) -> AnchorPlaced {
  let (ax, ay, aw, ah) = anchor
  let (pw, ph) = size
  let (vw, vh) = view
  let (it, ir, ib, il) = insets
  let (left, top, right, bottom) = (il, it, vw - ir, vh - ib)
  let max0 = fn(v : Double) { if v > 0.0 { v } else { 0.0 } }
  let below = max0(bottom - (ay + ah) - gap)
  let above = max0(ay - gap - top)
  let after = max0(right - (ax + aw) - gap)
  let before = max0(ax - gap - left)
  let asked = placement.side()
  // (the room on the side asked and on the other, and how much it needs there)
  let (here, there, need, other) = match asked {
    Below => (below, above, ph, Above)
    Above => (above, below, ph, Below)
    Right => (after, before, pw, Left)
    Left => (before, after, pw, Right)
  }
  let flipped = need > here && there > here
  let side = if flipped { other } else { asked }
  let room = if flipped { there } else { here }
  let k = placement.along()
  let (x, y) = match side {
    Below => (ax + (aw - pw) * k, ay + ah + gap)
    Above => (ax + (aw - pw) * k, ay - gap - ph)
    Right => (ax + aw + gap, ay + (ah - ph) * k)
    Left => (ax - gap - pw, ay + (ah - ph) * k)
  }
  {
    x: clamp_in(x, left, right - pw),
    y: clamp_in(y, top, bottom - ph),
    side,
    flipped,
    room,
  }
}

///|
/// How fast a list scrolls by itself while a drag is held at `pos` along its axis, its part that shows from `start` to
/// `end` (the same axis): 0 outside the `zone` at each end (a half of it at most each), and within it toward that end,
/// growing as the square of how far into the zone it is, from 0 at its inner edge (no jump as it is entered) to
/// `max_speed` at the end and past it. Less than 0 toward `start`: what `@view.Scroll::edge_toward` takes (points a ms).
pub fn edge_scroll_speed(pos : Double, start : Double, end : Double, zone~ : Double, max_speed~ : Double) -> Double {
  let span = end - start
  if span <= 0.0 || zone <= 0.0 || max_speed <= 0.0 {
    return 0.0
  }
  let z = if zone * 2.0 > span { span / 2.0 } else { zone }
  let into = fn(d : Double) {
    let f = if d >= z { 1.0 } else { d / z }
    max_speed * f * f
  }
  if pos < start + z {
    -into(start + z - pos)
  } else if pos > end - z {
    into(pos - (end - z))
  } else {
    0.0
  }
}
