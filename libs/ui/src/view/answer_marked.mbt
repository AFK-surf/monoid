// What an answer changed at once (answering.mbt), marked where it changed: a structure's part made or let go as an
// answer told it (View::comes, at once), a property set again by a binding whose read an answer wrote (Tree::queued's
// `answered`). What judges how what moves goes from frame to frame (ui's sizes_steady.mbt) reads them for the frame
// that shows them: a step there, in the column of what was marked, while nothing in that column was on its way, is the
// answer's change done at once, as it must be done, no jolt (the coordinator of the migration, 2026-11-14). A step in
// a column with a way going is said as ever.

///|
/// Node `at` changed at once as an answer told it, at the moment of the change it is done in.
fn Tree::answer_mark(self : Tree, at : Int) -> Unit {
  guard at >= 0 && at < self.nodes.length() else { return }
  // (none read for long: the oldest half let go of, so what is kept stays small)
  if self.answer_marks.length() >= 4096 {
    let keep = self.answer_marks[2048:].to_owned()
    self.answer_marks.clear()
    self.answer_marks.push_iter(keep.iter())
  }
  self.answer_marks.push((at, self.cause_now()))
}

///|
/// The nodes an answer changed at once at a moment from `from` to `to` (Tree::answer_mark), each once, still in the
/// tree, none let go of: for a judge of the frame that reads them beside the one that takes them (ui's rows_steady.mbt
/// reads them, its sizes_steady.mbt then takes them with Tree::answered_between: taken by the first, the second found
/// none and an answer's first value done at once was said a jolt).
pub fn Tree::answered_in(self : Tree, from : Double, to : Double) -> Array[Int] {
  let out : Array[Int] = []
  for m in self.answer_marks {
    if m.1 >= from && m.1 <= to && m.0 < self.nodes.length() && self.nodes[m.0].live && !out.contains(m.0) {
      out.push(m.0)
    }
  }
  out
}

///|
/// The nodes an answer changed at once at a moment from `from` to `to` (Tree::answer_mark), each once, still in the
/// tree; each read so let go of, and those before `from` (a frame judged at `from` read what was marked by then: what is
/// left marked at `from` was told after it, between frames at that one moment).
pub fn Tree::answered_between(self : Tree, from : Double, to : Double) -> Array[Int] {
  let out : Array[Int] = []
  let keep : Array[(Int, Double)] = []
  for m in self.answer_marks {
    if m.1 > to {
      keep.push(m)
    } else if m.1 >= from && m.0 < self.nodes.length() && self.nodes[m.0].live && !out.contains(m.0) {
      out.push(m.0)
    }
  }
  self.answer_marks.clear()
  self.answer_marks.push_iter(keep.iter())
  out
}

///|
/// The nodes an answer changed at once at a moment from `from` to `to`, each once, still in the tree, as
/// Tree::answered_between finds them but none let go of: for a judge that reads them on a frame before the one that
/// takes them (ui's rows_steady.mbt, whose page's lists are judged on the frame ahead of sizes_steady.mbt, which takes
/// them: read so there, they were gone for it, and each answer's step at once was said a jolt).
pub fn Tree::answered_seen(self : Tree, from : Double, to : Double) -> Array[Int] {
  let out : Array[Int] = []
  for m in self.answer_marks {
    if m.1 >= from && m.1 <= to && m.0 < self.nodes.length() && self.nodes[m.0].live && !out.contains(m.0) {
      out.push(m.0)
    }
  }
  out
}

///|
/// Whether node `at` is on a way at `t` not yet at its end: its own way in or out, or a move it is drawn by (View::comes,
/// View::moved_by), or one of what holds it, or a way in or out of what is beside it or beside what holds it, or of
/// anything in those, in that column, carrying it along. What a step of it then is: one in the middle of a way, said as ever where an answer
/// changed what it is in (the coordinator of the migration, 2026-11-14: what goes beside it its own way, a control's
/// thumb, a fade, carries it nowhere, and an answer's step done at once before is no way). `within`: the column the
/// answer's change is judged in (what scrolls round it, the page it is on): looked at up to it and no further, its own
/// way the last that counts; what holds that column moving it whole (a stack's page sliding in) moves no step inside it.
pub fn Tree::on_way_at(self : Tree, at : Int, t : Double, within? : Int = -1) -> Bool {
  let going = fn(q : Int) {
    let n = self.nodes[q]
    let e = n.flex.style.come_ends
    e == e && e > t
  }
  let mut q = at
  let mut steps = 0
  while q >= 0 && q < self.nodes.length() && steps < 256 {
    steps = steps + 1
    let n = self.nodes[q]
    if going(q) {
      return true
    }
    match n.moved_ends {
      Some(ends) if ends(n.flex.width, n.flex.height) > t => return true
      _ => ()
    }
    match self.carried_ends(q) {
      Some(ends) if @signals.untracked(ends) > t => return true
      _ => ()
    }
    if n.lift is Some(_) && self.flights.iter().any(fn(f) { f.node.at == q && f.start + f.dur > t }) {
      return true
    }
    if q == within {
      return false
    }
    let mut p = n.parent
    if !n.slot && n.flex.style.position == @flex.PositionType::Absolute {
      // (laid over what holds it (View::over): placed by the box it is in, past the slots between, never pushed by what
      // flows beside it or beside them; what moves that box carries it)
      while p >= 0 && p < self.nodes.length() && self.nodes[p].slot {
        if p == within {
          break
        }
        p = self.nodes[p].parent
      }
    } else if p >= 0 && p < self.nodes.length() {
      for k in self.nodes[p].kids {
        if k != q && k >= 0 && k < self.nodes.length() && self.comes_end_flow(k) > t {
          return true
        }
      }
    }
    q = p
  }
  false
}

///|
/// When the last way in or out of node `at`, or of anything in it, in the flow of what holds it, is over (-1 none): what
/// is laid over what holds it (View::over) takes no room in that flow, so its way carries nothing beside it.
fn Tree::comes_end_flow(self : Tree, at : Int) -> Double {
  let n = self.nodes[at]
  if !n.slot && n.flex.style.position == @flex.PositionType::Absolute {
    return -1.0
  }
  let e = n.flex.style.come_ends
  let mut end = if e == e { e } else { -1.0 }
  for k in n.kids {
    let r = self.comes_end_flow(k)
    if r > end {
      end = r
    }
  }
  end
}

///|
/// Node `self` carried, with what it holds, by a way over at `ends` (-1 at rest): what was said of it before put by
/// this, let go of with the node.
fn View::carried_by(self : View, ends : () -> Double) -> Unit {
  guard self.live() is Some(n) else { return }
  let m = self.tree.carried
  let gen = n.gen
  let said = match m.get(self.at) {
    Some((g, _)) => g == gen
    None => false
  }
  m[self.at] = (gen, ends)
  guard !said else { return }
  let at = self.at
  self.owns(fn() {
    match m.get(at) {
      Some((g, _)) if g == gen => m.remove(at)
      _ => ()
    }
  })
  |> ignore
}

///|
/// When the way carrying node `at` as it is now is over (Tree::on_way_at): none where none was said of this making of it.
fn Tree::carried_ends(self : Tree, at : Int) -> (() -> Double)? {
  match self.carried.get(at) {
    Some((g, ends)) if at < self.nodes.length() && self.nodes[at].gen == g => Some(ends)
    _ => None
  }
}
