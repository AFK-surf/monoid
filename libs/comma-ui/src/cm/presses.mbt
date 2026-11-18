// What every part's look reads of the hand: lit under a pointer (with a mouse) or while held (with a finger), its ring
// while the keyboard's focus is on it, as react-aria's useHover and useFocusRing give Comma's own parts. How each answers
// the hand is mbui's headless component's: a button, a toggle, a disclosure, a choice, a radio group, a slider, a menu.

///|
/// Whether `v` is lit now (Comma's hover and its press): under the pointer or pressed with a mouse, pressed with a
/// finger; never while not `on()`.
pub fn lit(v : @view.View, on : () -> Bool) -> Bool {
  on() &&
  (match @ui.pointing() {
    Mouse => v.pointed() || v.pressed()
    Finger => v.pressed()
  })
}

///|
/// Comma's focus ring round `v` while the keyboard's focus is on it (focus-visible): `ink`'s 4 px round its edge,
/// `corner` its corner, over what is beside it.
pub fn ring_node(v : @view.View, corner : () -> Double, ink? : Int64 = focus_brand.1) -> Unit {
  ignore(corner)
  v.focus_ring(Is(Some((ring_w, 0.0, ink)))) |> ignore
}
