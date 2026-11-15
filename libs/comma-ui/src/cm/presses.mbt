// How a part of Comma's answers the hand where mbui has no headless component for it yet (a menu's row, a dropdown's
// trigger: presses_node), and what every part's look reads of the hand: lit under a pointer (with a mouse) or while
// held (with a finger), its ring while the keyboard's focus is on it, as react-aria's useHover and useFocusRing give
// Comma's own parts. A button, a toggle, a disclosure, a choice, a radio group and a slider are mbui's headless ones.

///|
/// `v` pressed (`press`, once a press) while `on()`: taking the focus then, and the hand.
pub fn presses_node(v : @view.View, press : () -> Unit, on? : () -> Bool = fn() { true }) -> Unit {
  v.presses(By(on)).focusable(By(on)).on_press(press) |> ignore
  let on_it = fn(d : @view.Drag) { v.finger_target(d.wx, d.wy) }
  v.gesture(
    @ui.touch_slop(),
    tap=fn(d) { if on_it(d) && @signals.untracked(on) { press() } },
    drag=fn(d) { if d.kind == Up && @ui.pointing() is Mouse && on_it(d) && @signals.untracked(on) { press() } },
  )
  |> ignore
}

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
  v.show(fn() { v.focus_shown() }, fn(r) {
    r
    .over(Is(true))
    .margin(Is((-ring_w, -ring_w, -ring_w, -ring_w)))
    .radius(By(fn() { corner() + ring_w }))
    .edge(Is((ring_w, ink)))
    |> ignore
  })
}
