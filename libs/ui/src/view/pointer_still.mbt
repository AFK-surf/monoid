// A pointer-dependent layout can have no fixed point: showing something under
// the pointer can move it out from under it, and hiding it move it back. Once
// Tree::laid_out has tried enough passes, remember the pointer's observations
// and their geometry so unrelated layouts do not restart that cycle. A moved
// pointer, changed geometry or changed observation is tried again.

///|
#derive(Eq)
priv struct PointerStill {
  pass : Int32
  within : Array[(PointerBox, Bool?, Bool?, Int32?, Int32?)]
  bars : Array[
    (PointerBox, (Double, Double, Double, Double), Double, Bool, Bool, Bool),
  ]
}

///|
#derive(Eq)
priv struct PointerBox {
  at : Int32
  gen : Int32
  placed : (Double, Double, Double)
  width : Double
  height : Double
}

///|
fn Tree::pointer_box(self : Tree, at : Int32) -> PointerBox {
  let n = self.nodes[at]
  { at, gen: n.gen, placed: self.placed(at), width: n.lw, height: n.lh, }
}

///|
fn Tree::pointer_observations(self : Tree) -> PointerStill {
  let within = []
  for (at, gen) in self.withins_at {
    if at < 0 || at >= self.nodes.length() {
      continue
    }
    let n = self.nodes[at]
    if !n.live || n.gen != gen {
      continue
    }
    let (inside, last_inside) = match n.within_cell {
      Some(cell) => (Some(self.within(at)), Some(cell.untracked()))
      None => (None, None)
    }
    let (piece, last_piece) = match n.piece_cell {
      Some((cell, f)) => (Some(self.piece_in(at, f)), Some(cell.untracked()))
      None => (None, None)
    }
    within.push((self.pointer_box(at), inside, last_inside, piece, last_piece))
  }
  let bars = []
  let bar_at = if self.bar_cols.is_empty() { None } else { self.bar_near_at() }
  for (at, gen) in self.bar_cols {
    if at < 0 || at >= self.nodes.length() {
      continue
    }
    let n = self.nodes[at]
    if !n.live || n.gen != gen {
      continue
    }
    guard n.bar_near_cell is Some(cell) else { continue }
    bars.push(
      (
        self.pointer_box(at),
        self.input_bounds({ at, gen, }),
        n.bar_near,
        n.bar_across,
        cell.untracked(),
        bar_at == Some(at),
      ),
    )
  }
  { pass: self.pointer_pass, within, bars, }
}

///|
/// Keep a few states, not bindings or callbacks, so a long chain with changing
/// geometry can finish while an oscillation stops without holding a frame.
fn Tree::pointer_cycle_seen(
  self : Tree,
  passes : Int32,
  seen : Array[PointerStill],
) -> Bool {
  if passes < pointer_passes_check {
    return false
  }
  let now = self.pointer_observations()
  if passes >= pointer_passes_most || seen.iter().any(fn(old) { old == now }) {
    // Only hold the observers that changed in the loop. Other observers must
    // keep working while these wait for their own geometry or inputs to change.
    let within = []
    for i, w in now.within {
      if seen.iter().any(fn(old) { old.within.get(i) != Some(w) }) {
        within.push(w)
      }
    }
    let bars = []
    for i, b in now.bars {
      if seen.iter().any(fn(old) { old.bars.get(i) != Some(b) }) {
        bars.push(b)
      }
    }
    self.pointer_still = if within.is_empty() && bars.is_empty() {
      Some(now)
    } else {
      Some({ pass: now.pass, within, bars, })
    }
    true
  } else {
    if seen.length() < 16 {
      seen.push(now)
    }
    false
  }
}

///|
fn Tree::pointer_still_holds(self : Tree) -> Bool {
  match self.pointer_still {
    None => false
    Some(was) => {
      let now = self.pointer_observations()
      // The stopped observations remain in their original order even when
      // unrelated nodes are added or removed.
      let mut within = 0
      for w in now.within {
        if within < was.within.length() && w == was.within[within] {
          within += 1
        }
      }
      let mut bars = 0
      for b in now.bars {
        if bars < was.bars.length() && b == was.bars[bars] {
          bars += 1
        }
      }
      if within == was.within.length() && bars == was.bars.length() {
        true
      } else {
        self.pointer_still = None
        false
      }
    }
  }
}

///|
fn Tree::pointer_within_still(self : Tree, at : Int32, gen : Int32) -> Bool {
  match self.pointer_still {
    None => false
    Some(was) => was.within.iter().any(fn(w) { w.0.at == at && w.0.gen == gen })
  }
}

///|
fn Tree::pointer_bar_still(self : Tree, at : Int32, gen : Int32) -> Bool {
  match self.pointer_still {
    None => false
    Some(was) => was.bars.iter().any(fn(b) { b.0.at == at && b.0.gen == gen })
  }
}

///|
/// A binding marked by the pointer may also read other inputs. A change to
/// one of them can remove the feedback even when the box stays where it was.
fn Tree::pointer_binding_changed(self : Tree, b : Bound) -> Unit {
  if self.pointer_still is Some(was) && b.pointer_pass == was.pass {
    self.pointer_still = None
    self.pointer_again = true
  }
  if self.withins_passing {
    b.pointer_pass = self.pointer_pass
  }
}
