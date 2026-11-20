// Layout ergonomics: common flex composition helpers that prevent intrinsic-size overflow in nested flex containers
// (`View::fill`) and center children along both axes (`View::center`).

///|
/// Fill the remaining space in a flex container while allowing it to shrink below its content's intrinsic size:
/// equivalent to `self.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0)))`.
#callsite(autofill(loc))
pub fn View::fill(self : View, loc~ : SourceLoc) -> View {
  self
  .grow(Is(1.0), loc~)
  .shrink(Is(1.0), loc~)
  .basis(Is(Some(0.0)), loc~)
  .min_width(Is(Some(0.0)), loc~)
  .min_height(Is(Some(0.0)), loc~)
}

///|
/// Center children along both the main and cross axes:
/// equivalent to `self.lies_along(Is(Middle)).lines_up(Is(Some(Middle)))`.
#callsite(autofill(loc))
pub fn View::center(self : View, loc~ : SourceLoc) -> View {
  self.lies_along(Is(Middle), loc~).lines_up(Is(Some(Middle)), loc~)
}

///|
/// Fix exact width and height while preventing flex containers from squashing the node:
/// equivalent to `self.width(Is(Some(w))).height(Is(Some(h))).shrink(Is(0.0))`.
#callsite(autofill(loc))
pub fn View::fixed(self : View, w : Double, h : Double, loc~ : SourceLoc) -> View {
  self.width(Is(Some(w)), loc~).height(Is(Some(h)), loc~).shrink(Is(0.0), loc~)
}

///|
/// Prevent flex containers from shrinking this node below its size:
/// equivalent to `self.shrink(Is(0.0))`.
#callsite(autofill(loc))
pub fn View::rigid(self : View, loc~ : SourceLoc) -> View {
  self.shrink(Is(0.0), loc~)
}

///|
/// Lay out children horizontally in a row:
/// equivalent to `self.row(Is(true))`.
#callsite(autofill(loc))
pub fn View::as_row(self : View, loc~ : SourceLoc) -> View {
  self.row(Is(true), loc~)
}

///|
/// Clip painted descendants to this node's bounds:
/// equivalent to `self.clips(Is(true))`.
#callsite(autofill(loc))
pub fn View::clip(self : View, loc~ : SourceLoc) -> View {
  self.clips(Is(true), loc~)
}

///|
/// Allow this node to give way along a row and stay within its column width:
/// equivalent to `self.cuts(Is(true))`.
#callsite(autofill(loc))
pub fn View::cut(self : View, loc~ : SourceLoc) -> View {
  self.cuts(Is(true), loc~)
}
