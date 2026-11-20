// The spinner, or how far what it waits on has come once that is known (progress_spinner's), as a node of the window's
// tree: the same ring; not known, the spinner's quarter turning by the clock as it is drawn (spinner_node's); known,
// the accent from its top as far round as it has come, drawn to a part told anew over @motion.progress_ms on the ease-out
// from where it is drawn then (the first part known there at once, as the old one's anim is made at it).

///|
/// The spinner, or how far what it waits on has come (`coming`, 0 to 1, as it changes; None: not known) in `parent`:
/// `size` across, its line `stroke` wide, in the theme's colours as they change. The node.
#callsite(autofill(loc))
pub fn progress_spinner_node(
  parent : @view.View,
  coming : () -> Double?,
  size? : Double = 14.0,
  stroke? : Double = spin_stroke,
  loc~ : SourceLoc,
) -> @view.View {
  // (its points worked out once, SpinRing's: only the part come and the colours change as it lives)
  let ring = SpinRing::new(size, stroke)
  let round = ring.round()
  let quarter = ring.turning(0.25)
  // (how far it has come, drawn: the first part told there at once, each after from where it is drawn)
  let first = @signals.untracked(coming)
  let at = @motion.NodeWay::new(first.map(spin_part).unwrap_or(0.0))
  let told = Ref(first is Some(_))
  parent.box(made_for=loc, fn(v) {
    v
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .lines(By(fn() {
      let p = theme().p
      match coming() {
        None => [@ui.line(round, width=stroke, color=p.line_strong), @ui.line(quarter, width=stroke, color=p.accent)]
        Some(_) => ring.come_lines(round, at.shown(v), p)
      }
    }))
    // (turning only while not known, about the middle of its ring, as spinner_node's)
    .turn(By(fn() { if coming() is None { v.cycle(spinner_turn_ms) * 2.0 * spin_pi } else { 0.0 } }), drawn=true)
    |> ignore
    v.reacts(coming, fn(c) {
      match c {
        Some(k) =>
          if told.val {
            at.go_ms(v, spin_part(k), @motion.progress_ms, ease=Out)
          } else {
            told.val = true
            at.put(spin_part(k))
          }
        None => ()
      }
    })
  })
}
