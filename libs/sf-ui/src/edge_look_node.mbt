// How a column's edge looks as a node of the window's tree (edge_look's, its made-once form): its bar and its line in
// its middle, each moving between what it shows as its state changes, from the moment of what changed it (a pointer come
// onto it, a press of it, its end), each on its own way (@motion.NodeWay), from where the one before had it then; drawn
// where it is at the moment it is drawn while it goes, where it went once it is there. Made as its state is then, still.

///|
/// A column's edge's look in a node of `parent`'s (as tall as it, `handle_w` across, its middle that of `parent`), as
/// edge_look draws it: its bar while `over()` its column, longer while `on()` it (pointed at, in hand), in the field's
/// edge grey while `active()` (pressed, dragged), else the strong line's grey; its line while on it (unless `line()` says
/// no, as that changes: a sidebar folded) or active. Its bar's height and showing move over edge_bar_ms, its grey over edge_ink_ms, its line over
/// edge_line_ms, each eased out, from the moment its state changed. `pull`: dragged past its end (edge_node's `pull`),
/// its line a string drawn aside where the hand is (@paint.tension_line), its bar aside with it; at rest, as ever.
/// Taking nothing. The node.
#callsite(autofill(loc))
pub fn edge_look_node(
  parent : @view.View,
  over : () -> Bool,
  on : () -> Bool,
  active : () -> Bool,
  line? : () -> Bool = fn() { true },
  pull? : EdgePull,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    let theme = fn() { @ui.tree_theme() }
    // (how far aside its line is drawn, where along it and how tall it was: none at rest, nor without a pull)
    let pulled = fn() -> (Double, Double, Double) {
      match pull {
        Some(p) => p.shown_on(v)
        None => (0.0, 0.0, 0.0)
      }
    }
    // (drawn aside only where its line shows: a folded sidebar's has none to bend)
    let bent = fn() { line() && pulled().0.abs() >= 0.05 }
    // (its bar's node, drawn aside with its line once it is pulled)
    let bar : Ref[@view.View?] = Ref(None)
    let state = fn() { edge_state(over(), on(), active(), line()) }
    let now = @signals.untracked(state)
    // (each as the state is as it is made: still)
    let shows = @motion.NodeWay::new(if (now & 1) != 0 { 1.0 } else { 0.0 })
    let long = @motion.NodeWay::new(if (now & 2) != 0 { 1.0 } else { 0.0 })
    let ink = @motion.NodeWay::new(if (now & 4) != 0 { 1.0 } else { 0.0 })
    let lit = @motion.NodeWay::new(if (now & 8) != 0 { 1.0 } else { 0.0 })
    v.reacts(state, fn(s) {
      shows.go_ms(v, if (s & 1) != 0 { 1.0 } else { 0.0 }, edge_bar_ms)
      long.go_ms(v, if (s & 2) != 0 { 1.0 } else { 0.0 }, edge_bar_ms)
      ink.go_ms(v, if (s & 4) != 0 { 1.0 } else { 0.0 }, edge_ink_ms)
      lit.go_ms(v, if (s & 8) != 0 { 1.0 } else { 0.0 }, edge_line_ms)
    })
    v.width(Is(Some(handle_w))).grow(Is(1.0)).presses(Is(false)) |> ignore
    // its line, over all of it but S2 at each end, its grey whole at its middle, clear toward its ends
    v.box(fn(l) {
      let side = (handle_w - @ui.Space::px(SPx)) / 2.0
      l.over(Is(true)).padding(Is((side, @ui.Space::px(S2), side, @ui.Space::px(S2)))) |> ignore
      l.box(fn(h) {
        h
        .grow(Is(1.0))
        .alpha(By(fn() { if bent() { 0.0 } else { lit.shown(v) } }))
        |> ignore
        for i in 0..<edge_line_steps {
          let y = (i.to_double() + 0.5) / edge_line_steps.to_double()
          let a = if y <= 0.1 || y >= 0.9 { 0.0 } else if y < 0.5 { (y - 0.1) / 0.4 } else { (0.9 - y) / 0.4 }
          h.box(fn(s) {
            s.grow(Is(1.0)).alpha(Is(a)).ground(By(fn() { theme().color(FieldHover) })) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    // its bar, in its middle (as much room above as below it, its sides as far in)
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    let side = (handle_w - edge_bar_w) / 2.0
    v.box(fn(p) {
      p.padding(Is((side, 0.0, side, 0.0))) |> ignore
      p.box(fn(b) {
      b
      .width(Is(Some(edge_bar_w)))
      .height(By(fn() {
        let (s6, s12) = (@ui.Space::px(S6), @ui.Space::px(S12))
        Some(s6 + (s12 - s6) * long.shown(v))
      }))
      .radius(Is(edge_bar_w / 2.0))
      .alpha(By(fn() { shows.shown(v) }))
      .ground(By(fn() { mix(theme().color(FieldHover), ink.shown(v), theme().color(Border)) }))
      .drawn_as(Is("/icon/edge-bar/"))
      |> ignore
      bar.val = Some(b)
      })
      |> ignore
    })
    |> ignore
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    // its line drawn aside, and its bar with it, bound as it is first drawn aside: an edge never pulled binds nothing
    // for it (a page's edges opened bind none). The line a string held at its ends (S2 in from each), drawn aside at the
    // hand's height, in pieces its grey thinning toward its ends as the straight line's does; nothing drawn at rest
    match pull {
      Some(p) => {
        let bound = Ref(false)
        v.reacts(fn() { p.taken() }, at_start=false, fn(taken) {
          if !taken || bound.val {
            return
          }
          bound.val = true
          v.lines(By(fn() { bend_lines(pulled(), bent(), lit.shown(v), theme().color(FieldHover)) })) |> ignore
          match bar.val {
            Some(b) => b.offset(By(fn() { (if bent() { pulled().0 } else { 0.0 }, 0.0) })) |> ignore
            None => ()
          }
        })
      }
      None => ()
    }
  })
}

///|
/// An edge's line drawn aside (`pulled`: how far, at what height, how tall it was), in pieces its grey (`ink`, as lit
/// as `shown`) thinning toward its ends: none while it is not `bent`.
fn bend_lines(
  pulled : (Double, Double, Double),
  bent : Bool,
  shown : Double,
  ink : Int64,
) -> Array[@paint.Line] {
  let (aside, y, h) = pulled
  if !bent || h <= 0.0 {
    return []
  }
  let s2 = @ui.Space::px(S2)
  let span = dmax(0.0, h - 2.0 * s2)
  let pts = @paint.tension_line(span, handle_w / 2.0, aside, y - s2).map(fn(p) { (p.0, p.1 + s2) })
  let out = []
  for i in 0..<edge_bend_pieces {
    let a = (i.to_double() + 0.5) / edge_bend_pieces.to_double()
    let k = if a <= 0.1 || a >= 0.9 { 0.0 } else if a < 0.5 { (a - 0.1) / 0.4 } else { (0.9 - a) / 0.4 }
    if k > 0.0 {
      out.push(
        @paint.subline(
          pts,
          from=i.to_double() / edge_bend_pieces.to_double(),
          upto=(i + 1).to_double() / edge_bend_pieces.to_double(),
          width=@ui.Space::px(SPx),
          color=alpha(ink, k * shown),
        ),
      )
    }
  }
  out
}

///|
/// Whether an edge's bar shows over its column as the hand has it now (edge_look's `over` where its column is not
/// lit by a pointer of its own: shown always to touch, which points at nothing; to a mouse, only as it is on the edge).
pub fn edge_over() -> Bool {
  @ui.pointing() is Finger
}

///|
/// In how many pieces an edge's line drawn aside is drawn, its grey thinning toward its ends as edge_line_steps'.
let edge_bend_pieces : Int = 20
