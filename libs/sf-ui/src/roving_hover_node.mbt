// A row of tools' hover ground as one (RovingHover: a bar's tools side by side, a menu's items): where the hand goes
// from one to the next, the ground the one it left lit goes from where that is drawn to the next on a cover's spring,
// as fast as it went, as wide and tall as each it goes to, as the chosen thumb of a segmented control goes (seg_node's
// cover); coming from none lit, faded in where it is; the hand gone off all of them, faded out where it was. Each
// tool's ground a node of its own under what it shows (roving_hover_node), handed on among them (@motion.Handoff), so a
// tool made or let go takes its ground with it; set going at each cause's moment (the hand on it, the keyboard's focus
// shown on it, a finger pressing it), from where the one before had it then. A finger's press lights the one it is on
// at once, there, and puts it out at once as it is let go (pressed, never pointed at: nothing to go from). What holds a
// row lends it to the tools it holds (`rove_lent`), which take it as theirs where none is given them.

///|
/// The tools sharing one hover ground (roving_hover_node): their grounds handed on among them, the next lit taking it
/// over from the one lit last while some of it is seen.
pub struct RovingHover {
  priv hands : @motion.Handoff
}

///|
/// No tool lit yet.
pub fn RovingHover::new() -> RovingHover {
  { hands: @motion.Handoff::new() }
}

///|
/// What a row lends the tools it holds (View::lends): their shared hover ground (tool_node's, where none is given it).
pub let rove_lent : @view.Lent[RovingHover] = @view.Lent::new()

///|
/// How a tool's ground comes in from none lit (eased out) and goes as the hand leaves all of them (eased to leave):
/// kit's tip_in and pop_out lengths, a control answering the hand.
let rove_in_ms : Double = 120.0

///|
let rove_out_ms : Double = 150.0

///|
/// `c`'s colour, `seen` of it seen (0 none: no ground).
fn rove_ink(c : Int64, seen : Double) -> Int64 {
  if seen <= 0.0 || c == 0L {
    return 0L
  }
  let a = (c & 0xFFL).to_double() * (if seen > 1.0 { 1.0 } else { seen })
  (c & 0xFFFFFF00L) | a.round().to_int64()
}

///|
/// The hover ground of tool `item`, one of those `rove` makes one of, as a node in it under all else it holds (made in
/// it before what it shows), as big as it, `radius` round: lit while `lit` says (the hand on it, its focus shown), in
/// `color` as that changes; going from the one lit before it as the hand comes to it from that one, as the file's head
/// says. `finger`: whether the hand of the moment is a finger (lit and put out at once, there). The ground's node.
#callsite(autofill(loc))
pub fn roving_hover_node(
  rove : RovingHover,
  item : @view.View,
  lit : () -> Bool,
  color : () -> Int64,
  radius : @view.Live[Double],
  finger : () -> Bool,
  loc~ : SourceLoc,
) -> @view.View {
  // (how much of it is seen, 0 to 1; put out at once as another takes it over)
  let seen = @motion.Way::new(0.0)
  let part = rove.hands.part(fn(at) { seen.value_at(at) }, gave=fn() { seen.put(0.0) })
  let cover = item.box(made_for=loc, fn(c) {
    c
    .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), Some(0.0)))
    .radius(radius)
    .ground(By(fn() { rove_ink(color(), seen.shown_on(c)) }))
    |> ignore
    part.draws(c)
  })
  // (lit by a finger's press: put out at once as it goes)
  let by_finger = Ref(false)
  item.reacts(lit, fn(on) {
    let at = item.cause_at()
    if on {
      if finger() {
        // (a finger's: there at once, from nowhere)
        by_finger.val = true
        part.came(at, @motion.snappy_damped, takes=false) |> ignore
        seen.put(1.0)
        return
      }
      by_finger.val = false
      match part.came(at, @motion.snappy_damped) {
        // (from where the one before is drawn, as fast as it goes there, as much of it seen)
        Some(s) => {
          seen.put(s)
          seen.go(1.0, @motion.tween(rove_in_ms, ease=Out), at~)
        }
        // (none lit a moment ago, or this one fading out: faded in where it is, from as much as is seen)
        None => seen.go(1.0, @motion.tween(rove_in_ms, ease=Out), at~)
      }
    } else if part.is_last() && !by_finger.val {
      // (the one lit last: faded out where it is, its way going on, for the next to take over from)
      part.left(at)
      seen.go(0.0, @motion.tween(rove_out_ms, ease=Leave), at~)
      by_finger.val = false
    } else {
      // (taken over by another, or a finger's: out at once)
      part.left(at)
      seen.put(0.0)
      part.still()
      by_finger.val = false
    }
  })
  // (let go: nothing of it to take over from)
  item.owns(fn() { part.gone() }) |> ignore
  cover
}
