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
