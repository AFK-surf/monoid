// A room opening on what it holds and closing on it as a node of the window's tree (reveal's `middle`, made once): as tall as its share of what it holds is laid out, from the moment what opens or closes it changes, its way
// as long as a move as far as what it holds is tall then (a Move per point of it); what it holds kept in its middle, as
// big as it is open and faded in from half open, about the middle of what it draws, cut at both ends softly; all of
// it, as tall as it is, once it is open; none of it pressed or read out once it is closing or shut.

///|
/// What `make` makes in a room in `parent` that opens as `open` says it is and closes as it says it is not (each from
/// where it is at that moment, its way as long as a Move as far as what it holds is laid out tall then), still as it is
/// made: as tall as its share of what it holds comes to (View::opens: the same layout's, whatever its words or width
/// come to meanwhile), what it holds in its middle (row_held_look: as big as it is open about the middle of what it
/// draws, coming in from half open), cut at its top and foot softly (View::cuts_softly); as tall as what it holds once
/// it is open; nothing tall once it is shut. Taking no press and read out as nothing from the moment it closes. The
/// room's node. `deferred`: what `make` makes is made only as it first opens (what it holds asks for what it shows as it
/// is made: none of it asked while it is shut), kept from then.
pub fn reveal_node(
  parent : @view.View,
  open : () -> Bool,
  make : (@view.View) -> Unit,
  deferred? : Bool = false,
) -> @view.View {
  let way = NodeWay::new(if @signals.untracked(open) { 1.0 } else { 0.0 })
  let made = @signals.signal(!deferred || @signals.untracked(open), same=fn(a, b) { a == b })
  parent.box(fn(room) {
    // (as tall as it is laid out, whatever room it has: what is past its room cut)
    let held = room.box(fn(h) {
      h.shrink(Is(0.0)) |> ignore
      // (open as it is made: made with it, laid out in the same pass as what is round it)
      if made.untracked() {
        make(h)
      } else {
        // (its way this room's: at once)
        h.show(fn() { made.get() }, make, at_once=true)
      }
    })
    let shown = fn() { way.shown(room) }
    room.reacts(open, fn(o) {
      // (how far it goes: what it holds is laid out tall at this moment, the way's length said once, not followed)
      let go = fn() { way.go(room, if o { 1.0 } else { 0.0 }, moved().per_unit(held.laid_size().1)) }
      if o && !made.untracked() {
        // (made as it first opens: its way set off at this moment once what this change makes is made, laid out tall
        // as it is then)
        made.set(true)
        @signals.after_flush(go)
      } else {
        go()
      }
    })
    room
    .opens(By(fn() {
      let k = shown()
      if k >= 1.0 {
        None
      } else {
        Some(if k > 0.0 { k } else { 0.0 })
      }
    }))
    // (shut: no room of its own, nor the gap what holds it leaves before it, as an old view's room shut is not built)
    .laid_nowhere(By(fn() { !open() && shown() <= 0.0 }))
    .clips(By(fn() { shown() < 1.0 }))
    .cuts_softly(By(fn() { shown() < 1.0 }))
    .presses(By(fn() { open() }))
    .hides(By(fn() { !open() }))
    |> ignore
    held
    .scale(By(fn() {
      let k = shown()
      if k < 0.0 {
        0.0
      } else if k > 1.0 {
        1.0
      } else {
        k
      }
    }), about=Drawn)
    .alpha(By(fn() {
      let k = shown()
      if k >= 1.0 {
        1.0
      } else {
        let a = (k - @ui.row_gone_at) / (1.0 - @ui.row_gone_at)
        if a > 0.0 {
          a
        } else {
          0.0
        }
      }
    }))
    |> ignore
  })
}
