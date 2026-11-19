// A loupe's measures (iOS's text loupe, Android's Magnifier): what a finger hides as it drags what needs seeing where it
// is (@ui.finger_reads: a field's caret or the ends of what is picked by their handles, a long press's word slid on)
// shown larger over it, in a capsule of a knob's held glass, loupe_lift over the finger; drawn by an app's library over
// a node of the window's tree that magnifies (View::magnifies). It is the switch's knob's lens and the bar's ball, not one
// of its own: it comes in as the knob held does (lift_spring, larger by knob_lens_grow, fading in), follows the finger
// as the ball does (follow_spring) and is drawn out by its speed as the ball is (speed_stretch); let go, it goes where it
// is.

///|
/// How much larger the loupe shows what is under the finger, its size, how far over the finger its middle is, and how
/// far in from the window's sides it stays; how much larger a knob's lens grows as it comes (a switch's, the loupe's).
pub let loupe_zoom : Double = 1.35

///|
pub let loupe_w : Double = 124.0

///|
pub let loupe_h : Double = 48.0

///|
pub let loupe_lift : Double = 92.0

///|
pub let loupe_side : Double = 8.0

///|
pub let knob_lens_grow : Double = 1.25

///|
/// How a thing a finger moves follows it (the bar's ball: 300, damped as the web's, ZETA 0.635).
// kept across runs: a value (no field of it changes)
pub let follow_spring : @motion.Spec = @motion.lift_spring

///|
/// How much longer a thing a finger moves is drawn toward where it goes, and how much lower, by `v` (its way a frame
/// at 60): the bar's ball's (a frame's way times 1.6, at most 36; a fifth of that off its height, at most 6).
pub fn speed_stretch(v : Double) -> (Double, Double) {
  let longer = dmin(stretch_most, v.abs() * stretch_by)
  (longer, dmin(lower_most, longer * lower_by))
}

///|
let stretch_by : Double = 1.6

///|
let stretch_most : Double = 36.0

///|
let lower_by : Double = 0.2

///|
let lower_most : Double = 6.0
