// What comes and goes with the structure that makes it (View::show and View::pick with `leave`, a dialog's layer): in
// from the moment it is made (or once what it waits for is there: `gate`), out from the moment that structure lets it go,
// back in from where it is if it is shown again on its way out. One call says all of it: the way, the watch of
// View::leaving that turns it, and, where the way carries what it holds somewhere (a scale, a slide), that it does
// (View::carries_until, read by Tree::on_way_at); a fade carries nothing, so says none. What every such part wrote by
// hand (a NodeWay, a watch of leaving, a carries_until said or forgotten) is this.

///|
/// How far in node `v` is, 0 to 1 as it is drawn: in as `enter` says from where it is (`from` as it is made), out to 0
/// as `exit` says (else `enter`) from the moment `v` (or what holds it) begins to leave. `gate`: what holds its coming in
/// till what it reads is there (an open gate's), handed the way's start; `stop_gate`: what lets go of that wait as it
/// leaves. `carries`: its way carries `v` and what it holds (a scale, a slide), said so for what judges a step inside it.
pub fn presence_in(
  v : @view.View,
  enter : Spec,
  exit? : Spec,
  from? : Double = 0.0,
  carries? : Bool = false,
  gate? : (() -> Unit) -> Unit,
  stop_gate? : () -> Unit = fn() {  },
) -> () -> Double {
  let way = NodeWay::new(from)
  let come = fn() { way.go(v, 1.0, enter) }
  v.reacts(fn() { v.leaving() }, fn(going) {
    if going {
      stop_gate()
      way.go(v, 0.0, exit.unwrap_or(enter))
    } else {
      match gate {
        Some(g) => g(come)
        None => come()
      }
    }
  })
  if carries {
    v.carries_until(fn() { way.ends_at() }) |> ignore
  }
  fn() { way.shown(v) }
}

///|
/// Node `v`'s look as it comes and goes (presence_in's way): in as `enter` says, out as `exit` does (else `enter` played
/// back), each Trans's own spec; said to carry what it holds where either moves or scales it.
pub fn presence_look(
  v : @view.View,
  enter : Trans,
  exit? : Trans,
  gate? : (() -> Unit) -> Unit,
  stop_gate? : () -> Unit = fn() {  },
) -> () -> @ui.Look {
  let moves = fn(t : Trans) { t.scale != 1.0 || t.dx != 0.0 || t.dy != 0.0 }
  let carries = moves(enter) ||
    (match exit {
      Some(o) => moves(o)
      None => false
    })
  let shown = presence_in(v, enter.spec, exit?=exit.map(fn(o) { o.spec }), carries~, gate?, stop_gate~)
  fn() {
    let p = shown()
    match exit {
      Some(o) if v.leaving() => o.at(p, p)
      _ => enter.at(p, p)
    }
  }
}
