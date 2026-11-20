// A column's edge as a node of the window's tree (the way there 4: handle_drag and edge_tip given
// their made-once form beside their old one): what is done with it taken at each event's own moment, whatever frames
// come. A mouse drags it at once; a finger only once held still on it a long press's while (a swipe that passes over
// it is what lies under it's: View::gesture's `held_first`), felt as the hold takes it; dragged, the width it is
// dragged to, from the width it had as it went down, on whole pixels between its least and its most, felt as it gets
// to either end; let go, the width it ends at; pressed and let go
// without moving, a press of it (where it lies over what is beside the column, that one's), the second of two its
// own width again. Its pointer the resizing one, read out as a separator; its tip (edge_tip's: a mouse's, by the
// pointer as it moves along it, edge_tip_ms after it comes onto it, shut by a press till the pointer has left it).

///|
/// An edge in a node of `parent`'s (filling it: what holds it says where and how big): of a column `width()` wide, on
/// its `edge` (the right of a sidebar, the left of a side panel), between `least()` and `most()`; `said` told what is
/// done with it as it is done, at its moment (Dragging, Dropped, Pressed, Twice; `on_beside` said for a press at
/// across (its own terms) that lands where it lies over what is beside the column: that one's, `beside` told of it
/// instead); `held` told as a press of it goes down and as it ends (let go, called off, passed on to what lies under
/// it); its words `label()`, its tip in `tips` on `side`. `pull`: dragged on past its least or its most, how far past
/// told to it, given way to (EdgePull: a string held at both ends, drawn aside by the finger, edge_look_node's line
/// bending so), sprung back as it is let go. The node.
#callsite(autofill(loc))
pub fn edge_node(
  parent : @view.View,
  label : () -> String,
  width : () -> Double,
  least : () -> Double,
  most : () -> Double,
  edge : @ui.Side,
  said : (Resized, Double) -> Unit,
  held : (Bool) -> Unit,
  on_beside? : (Double) -> Bool = fn(_) { false },
  beside? : (Double) -> Unit = fn(_) {  },
  tips? : TipLayer,
  side? : @view.Side = Right,
  pull? : EdgePull,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    v
    .grow(Is(1.0))
    .presses(Is(true))
    .cursor(Is(Some(ResizeX)))
    .says(By(fn() { Some(@view.said(Separator, label=label())) }))
    |> ignore
    match tips {
      Some(t) => tip_node(t, v, label, side~, delay=edge_tip_ms, skip=false, gap=edge_tip_gap, at_pointer=true) |> ignore
      None => ()
    }
    // (where the press went down across the window, and the width then)
    let from = Ref((0.0, 0.0))
    let to = fn(wx : Double) {
      let (x0, w0) = from.val
      let d = if edge is Left { x0 - wx } else { wx - x0 }
      dmax(least(), dmin(most(), (w0 + d).round()))
    }
    // (let go without moving it: a press of it)
    let pressed = fn(d : @view.Drag) {
      held(false)
      // (let go on it, as a press is: what is there for the finger as the tree is then, it and nothing over it)
      if !v.finger_target(d.wx, d.wy) {
        v.twice_forgot()
        return
      }
      if on_beside(d.x) {
        v.twice_forgot()
        beside(d.at)
        return
      }
      // (the second of two presses of it: View::twice)
      said(if v.twice(d) { Twice } else { Pressed }, d.at)
    }
    // (whether this press has moved it: a mouse's held long, not moved, and let go within the slop of where it went
    // down is a press, as a click is, as handle_drag had it; let go past it, with no move told, a drag's end)
    let moved = Ref(false)
    // (dragged to either end (-1 its least, 1 its most), felt as it gets there, once a stay there (TextHandleMove, as
    // handle_drag had it); 0 between)
    let at_end = Ref(0)
    let dragged = fn(wx : Double) -> Double {
      let w = @signals.untracked(fn() { to(wx) })
      let end = if w <= @signals.untracked(least) {
        -1
      } else if w >= @signals.untracked(most) {
        1
      } else {
        0
      }
      if end != 0 && end != at_end.val {
        @ui.haptic(TextHandleMove)
      }
      at_end.val = end
      w
    }
    // (where it went down in the window, as the gesture's slop is reckoned)
    let went = Ref((0.0, 0.0))
    v.gesture(
      @ui.touch_slop(),
      press=fn(d) {
        from.val = (d.wx, @signals.untracked(width))
        moved.val = false
        at_end.val = 0
        went.val = (d.wx, d.wy)
        held(true)
      },
      // (a finger's hold taken: the edge its own from now, felt so (LongPress, as Ctx::drag_on's hold had it); a
      // mouse's needs no hold, nothing felt)
      hold=(@ui.long_press_ms, fn(_) { if @ui.pointing() is Finger { @ui.haptic(LongPress) } }),
      held_first=fn(_) { @ui.pointing() is Finger },
      tap=pressed,
      drag=fn(d) {
        match d.kind {
          Down | Moved => {
            moved.val = true
            said(Dragging(dragged(d.wx)), d.at)
            // (past either end: how far, across the window as the hand went, to the pull)
            // (one that gives nothing between its ends, a column folded, its least its most: never drawn aside)
            if pull is Some(p) {
              let (lo, hi) = (@signals.untracked(least), @signals.untracked(most))
              if hi > lo {
                let (x0, w0) = from.val
                let raw = w0 + (if edge is Left { x0 - d.wx } else { d.wx - x0 })
                let past = raw - dmax(lo, dmin(hi, raw))
                p.drag(if edge is Left { -past } else { past }, d.y, d.h)
              } else {
                p.drag(0.0, d.y, d.h)
              }
            }
          }
          Up if !moved.val &&
            @ui.pointing() is Mouse &&
            (d.wx - went.val.0).abs() <= @ui.touch_slop() &&
            (d.wy - went.val.1).abs() <= @ui.touch_slop() => pressed(d)
          Up => {
            said(Dropped(@signals.untracked(fn() { to(d.wx) })), d.at)
            held(false)
            if pull is Some(p) {
              p.let_go(v)
            }
          }
          Off => {
            held(false)
            if pull is Some(p) {
              p.let_go(v)
            }
          }
        }
      },
    )
    |> ignore
    // (let go: no press of it left held)
    v.owns(fn() { held(false) }) |> ignore
  })
}

///|
/// An edge dragged on past its least or its most (edge_node's `pull`), as its look draws it (edge_look_node's `pull`):
/// how far aside the hand has drawn its line (across the window, given way to: never past edge_pull_most however far
/// the hand goes), at what height along it, and how tall the edge was as the drag went down (its Drag's, nothing read
/// of its layout); let go, back to its rest on tactile_bounce from where it was. At rest, none.
pub struct EdgePull {
  priv inner : @motion.EdgePull
}

///|
/// An edge's pull at rest.
pub fn EdgePull::new() -> EdgePull {
  { inner: @motion.EdgePull::new(limit=edge_pull_most) }
}

///|
/// Drawn aside `past` across the window (past its end, as far as the hand went) at `y` along an edge `h` tall: given
/// way to, there at once (in the hand).
fn EdgePull::drag(self : EdgePull, past : Double, y : Double, h : Double) -> Unit {
  self.inner.drag(past, y, h)
}

///|
/// Let go: back to rest from where it is (tactile_bounce, a little past it), from `v`'s cause's moment.
fn EdgePull::let_go(self : EdgePull, v : @view.View) -> Unit {
  self.inner.let_go(v)
}

///|
/// Whether it is drawn aside now or has been told to be (in the hand past its end): read by no clock.
fn EdgePull::taken(self : EdgePull) -> Bool {
  self.inner.taken()
}

///|
/// How far aside its line is drawn as `n` is drawn, at what height along it, and how tall the edge was: (aside, y, h).
pub fn EdgePull::shown_on(self : EdgePull, n : @view.View) -> (Double, Double, Double) {
  self.inner.shown_on(n)
}

///|
/// How far aside an edge's line is ever drawn (points): past it the hand going on gives nothing more.
let edge_pull_most : Double = 6.0
