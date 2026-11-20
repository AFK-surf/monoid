// Rounded rectangles as data: what a node of the window's tree (View::rects) draws directly as kind 0 instances
// (ui's scene.mbt kind 0) without path banding.

///|
/// A rounded rectangle at (`x`, `y`) `w` by `h` (from the top left of the box it is drawn in), filled in `color`
/// (RRGGBBAA), with corner radii `corners` (top left, top right, bottom right, bottom left).
#derive(Eq, Debug)
pub(all) struct Rect {
  x : Double
  y : Double
  w : Double
  h : Double
  color : Int64
  corners : (Double, Double, Double, Double)
}

///|
/// A rounded rectangle (see `Rect`), square corners by default.
pub fn rect(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  color~ : Int64,
  corners? : (Double, Double, Double, Double) = (0.0, 0.0, 0.0, 0.0),
) -> Rect {
  { x, y, w, h, color, corners }
}

///|
/// Alias for `rect`, matching `shape_of`.
pub fn rect_of(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  color~ : Int64,
  corners? : (Double, Double, Double, Double) = (0.0, 0.0, 0.0, 0.0),
) -> Rect {
  { x, y, w, h, color, corners }
}
