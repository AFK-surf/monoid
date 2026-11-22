// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/utils/InteractiveHighlight.kt. Where a finger is on a
// piece of glass and how far it is pressed: its press by a soft spring (0.5, 300), the finger's way from where it went
// down snapped to it as it drags and sent back by the same spring as it lets go. What it lights is mbui's liquid
// glass spot (`Glass::liquid` `spot`), and what it stretches is the glass's size and place (`stretch`).

///|
/// The finger's spring: `ratio=0.5` for position bounce, `ratio=1.0` for critically damped press glow.
fn highlight_spring(threshold : Double, ratio? : Double = 0.5) -> @motion.Spec {
  @motion.spring(ratio~, stiffness=300.0, threshold~) // det-ok(motion-spring): InteractiveHighlight.kt (0.5 pos, 1.0 critically damped press)
}

///|
/// Critically damped press spring: decays monotonically to 0 without bouncing back.
fn press_spring(threshold : Double) -> @motion.Spec {
  highlight_spring(threshold, ratio=1.0)
}

///|
/// A finger's light on a piece of glass (InteractiveHighlight): bound to the glass's node (`attach`), told where a
/// finger goes down, moves and lets go (`down`, `moved`, `up`).
pub struct InteractiveHighlight {
  priv press : @motion.NodeWay
  priv dx : @motion.NodeWay
  priv dy : @motion.NodeWay
  priv start : @signals.Signal[(Double, Double)]
  priv size : @signals.Signal[(Double, Double)]
  priv node : Ref[@view.View?]
}

///|
/// Not pressed.
pub fn InteractiveHighlight::new() -> InteractiveHighlight {
  {
    press: @motion.NodeWay::new(0.0),
    dx: @motion.NodeWay::new(0.0),
    dy: @motion.NodeWay::new(0.0),
    start: @signals.signal((0.0, 0.0)),
    size: @signals.signal((0.0, 0.0)),
    node: Ref(None),
  }
}

///|
/// Its ways run on `n`'s timeline from now on.
pub fn InteractiveHighlight::attach(self : InteractiveHighlight, n : @view.View) -> Unit {
  self.node.val = Some(n)
}

///|
fn InteractiveHighlight::at(self : InteractiveHighlight) -> @view.View {
  match self.node.val {
    Some(n) => n
    None => @halt.saying("sf/glass: an InteractiveHighlight pressed before it was attached to its node")
  }
}

///|
/// A finger down at (`x`, `y`) of a glass `w` × `h` (onDragStart): its press comes up, its way starts there.
pub fn InteractiveHighlight::down(
  self : InteractiveHighlight,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
) -> Unit {
  let n = self.at()
  self.start.set((x, y))
  self.size.set((w, h))
  self.dx.put(0.0)
  self.dy.put(0.0)
  self.press.go(n, 1.0, press_spring(0.001))
}

///|
/// The finger moved to (`x`, `y`) of the glass (positionAnimation.snapTo): its way there at once.
pub fn InteractiveHighlight::moved(self : InteractiveHighlight, x : Double, y : Double) -> Unit {
  let (sx, sy) = self.start.untracked()
  self.dx.put(x - sx)
  self.dy.put(y - sy)
}

///|
/// The finger let go or called off (onDragEnd, onDragCancel): its press goes down, its way back to where it went down.
pub fn InteractiveHighlight::up(self : InteractiveHighlight) -> Unit {
  let n = self.at()
  self.press.go(n, 0.0, press_spring(0.001))
  self.dx.go(n, 0.0, highlight_spring(0.5))
  self.dy.go(n, 0.0, highlight_spring(0.5))
}

///|
/// How far it is pressed as `n` is drawn (pressProgress).
pub fn InteractiveHighlight::pressed(self : InteractiveHighlight, n : @view.View) -> Double {
  self.press.shown(n)
}

///|
/// How far the finger is from where it went down as `n` is drawn (offset).
pub fn InteractiveHighlight::offset(self : InteractiveHighlight, n : @view.View) -> (Double, Double) {
  (self.dx.shown(n), self.dy.shown(n))
}

///|
/// Where its light is on a glass `w` × `h` as `n` is drawn: where the finger is, held within the glass (the shader's
/// `position`, fastCoerceIn).
pub fn InteractiveHighlight::spot(
  self : InteractiveHighlight,
  n : @view.View,
  w : Double,
  h : Double,
) -> (Double, Double) {
  let (sx, sy) = self.start.get()
  let (ox, oy) = self.offset(n)
  (clamp(sx + ox, 0.0, w), clamp(sy + oy, 0.0, h))
}

///|
/// How the glass is drawn as `n` is drawn, pressed and dragged (LiquidButton's layerBlock): moved by the finger's way
/// eased by tanh (`min · tanh(0.05 · d / min)`, `min` its shorter side), grown by 4 points down its height as it is
/// pressed, and stretched along the finger's way by up to 4 more (its share of the longer side, times its sides'
/// ratio, at most 1). Its size the one the finger found it at as it went down. (dx, dy, scale_x, scale_y).
pub fn InteractiveHighlight::stretch(self : InteractiveHighlight, n : @view.View) -> (Double, Double, Double, Double) {
  let (w, h) = self.size.get()
  let p = self.press.shown(n)
  if w <= 0.0 || h <= 0.0 {
    return (0.0, 0.0, 1.0, 1.0)
  }
  let (ox, oy) = self.offset(n)
  let least = if w < h { w } else { h }
  let most = if w < h { h } else { w }
  let scale = lerp(1.0, 1.0 + 4.0 / h, p)
  let tx = least * tanh(0.05 * ox / least)
  let ty = least * tanh(0.05 * oy / least)
  let drag_scale = 4.0 / h
  let angle = @dmath.atan2(oy, ox)
  let sx = scale + drag_scale * (@dmath.cos(angle) * ox / most).abs() * clamp(w / h, 0.0, 1.0)
  let sy = scale + drag_scale * (@dmath.sin(angle) * oy / most).abs() * clamp(h / w, 0.0, 1.0)
  (tx, ty, sx, sy)
}

///|
fn tanh(x : Double) -> Double {
  let e = @dmath.exp(2.0 * x)
  (e - 1.0) / (e + 1.0)
}
