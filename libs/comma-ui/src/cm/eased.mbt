// A number a part's look moves between as its state changes (how lit it is under the hand, how far a knob has gone):
// over mbui's shared `@motion.Eased`, on Comma's cubic-bezier curves.

///|
/// One number a look moves, over `@motion.Eased`.
struct Eased {
  inner : @motion.Eased
}

///|
/// At `v`, still.
pub fn Eased::new(v : Double) -> Eased {
  { inner: @motion.Eased::new(v) }
}

///|
/// Off to `to` over `ms` on Comma's curve `ease` (tokens_made's `ease_*`), `delay` ms after `n`'s cause's moment, from
/// where it is then; its end a moment of `n`'s.
pub fn Eased::go(
  self : Eased,
  n : @view.View,
  to : Double,
  ms : Double,
  ease : (Double, Double, Double, Double),
  delay? : Double = 0.0,
) -> Unit {
  self.inner.go_by(n, to, @motion.tween_to(duration=ms, ease=curve(ease), delay~))
}

///|
/// Where it is as `n` is drawn: at the moment it is drawn at while it goes, where it went once it is there.
pub fn Eased::shown(self : Eased, n : @view.View) -> Double {
  self.inner.shown(n)
}

///|
/// A look that moves with what `on` says, 1 while it holds and 0 while not, over `ms` on `ease` from the moment it
/// changed: made in `n`, let go with it.
pub fn eased_by(n : @view.View, on : () -> Bool, ms : Double, ease : (Double, Double, Double, Double)) -> Eased {
  { inner: @motion.eased_on(n, on, @motion.tween_to(duration=ms, ease=curve(ease))) }
}
