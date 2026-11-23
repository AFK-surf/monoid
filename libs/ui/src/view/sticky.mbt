// A node held at the top of what scrolls it (View::sticky), as CSS's `position: sticky` holds one: laid out where it
// is, drawn no higher than so far under the top of the room the nearest column that scrolls it shows in, and no lower
// than its holder's foot lets it (pushed up by it as that goes on up). Worked out where the walk of the drawn works out
// where each node is (Tree::each_drawn_in_order, Tree::drawn_one), so what is drawn, what a press or the pointer
// finds there and what a test reads of it are the one place; nothing laid out again for it. A page's list's key drawn
// in several slices holds it in its first, pushed up by the foot of its last (sticky_foot_extra).

///|
/// It held so far (`top`: points, as big as what holds it is drawn) under the top of the room the nearest column that
/// scrolls it shows in, as what scrolls it moves, never past its holder's foot (pushed up as that comes up), as that
/// says it now; None, drawn where it is laid out (a narrow page's picture over its name). Placement's.
#callsite(autofill(loc))
pub fn View::sticky(self : View, top : Live[Double?], loc~ : SourceLoc) -> View {
  guard self.live() is Some(_) else { return self }
  let tree = self.tree
  let at = self.at
  let gen = self.gen
  self.bind(loc~, Sticky, top, Place, fn(t) {
    match t {
      Some(off) => tree.stickies[at] = (gen, off)
      None => tree.stickies.remove(at)
    }
  })
  self.owns(fn() {
    match tree.stickies.get(at) {
      Some((g, _)) if g == gen => tree.stickies.remove(at)
      _ => ()
    }
  })
  |> ignore
  self
}

///|
/// How much further than its own foot what holds a node held at a top (View::sticky) in `self` lets it go down: a page's
/// list's first slice of a key, its sticky picture pushed up by the foot of the key's last slice, so far under its own
/// (0: by its own foot alone).
fn View::sticky_foot_extra(self : View, extra : Double) -> Unit {
  guard self.live() is Some(_) else { return }
  let tree = self.tree
  let at = self.at
  let gen = self.gen
  let was = tree.sticky_extra.get(at)
  if extra == 0.0 {
    if was is Some(_) {
      tree.sticky_extra.remove(at)
      tree.place_marked_at(at)
    }
    return
  }
  if was == Some((gen, extra)) {
    return
  }
  if was is None {
    self.owns(fn() {
      match tree.sticky_extra.get(at) {
        Some((g, _)) if g == gen => tree.sticky_extra.remove(at)
        _ => ()
      }
    })
    |> ignore
  }
  tree.sticky_extra[at] = (gen, extra)
  tree.place_marked_at(at)
}

///|
/// Whether node `id` is held at a top (View::sticky, said Some) or holds one that is: what is drawn of it changes as what
/// scrolls it moves, so nothing of it is kept drawn and moved whole (a page's list's row, its list drawn as one).
pub fn Tree::has_sticky_in(self : Tree, id : NodeId) -> Bool {
  if self.stickies.is_empty() {
    return false
  }
  if !self.order_due && self.alive_id(id) && id.at < self.order_of.length() {
    let o = self.order_of[id.at]
    if o >= 0 {
      let end = self.order_end[o]
      let n = self.order_of.length()
      for at, e in self.stickies {
        if at < n {
          let i = self.order_of[at]
          if i >= o && i < end && self.nodes[at].live && self.nodes[at].gen == e.0 {
            return true
          }
        }
      }
      return false
    }
  }
  for at, e in self.stickies {
    let sid : NodeId = { at, gen: e.0 }
    if sid == id || self.holds_in_order(id, sid) {
      return true
    }
  }
  false
}

///|
/// Whether node `id` itself is held at a top (View::sticky, said Some): where it is drawn down what holds it is the
/// hold's (sizes_steady's).
pub fn Tree::is_sticky(self : Tree, id : NodeId) -> Bool {
  match self.stickies.get(id.at) {
    Some((g, _)) => g == id.gen
    None => false
  }
}

///|
/// Whether any node is held at a top now (View::sticky, said Some).
pub fn Tree::sticks_any(self : Tree) -> Bool {
  !self.stickies.is_empty()
}

///|
/// Whether any node held at a top (View::sticky, said Some) is drawn now (in the current walk order, not parked).
pub fn Tree::sticks_drawn(self : Tree) -> Bool {
  if self.stickies.is_empty() {
    return false
  }
  if self.order_due {
    return true
  }
  let n = self.order_of.length()
  for at, e in self.stickies {
    if at < n && self.order_of[at] >= 0 && self.nodes[at].live && self.nodes[at].gen == e.0 {
      return true
    }
  }
  false
}

///|
/// How far down node `n` (at `i` in the order, said held `off` under a top: View::sticky), drawn at `y` as big as `s`,
/// is drawn off where it is laid out: to `off` under the top of the room the nearest column that scrolls it shows in
/// (`wy`, `ws`: where each that holds it is drawn and how big, by its place in the order), never up, never past its
/// holder's foot (and what its row lets past it: sticky_foot_extra), on the host's pixels.
fn Tree::sticky_dy(
  self : Tree,
  i : Int,
  n : Node,
  off : Double,
  y : Double,
  s : Double,
  wy : (Int) -> Double,
  ws : (Int) -> Double,
) -> Double {
  let h = self.order_holder[i]
  guard h >= 0 else { return 0.0 }
  // (the nearest that a column scrolls, drawn off by its offset: its holder the room it shows in; and the first going up
  // that says how far past its foot it lets one go)
  let mut j = h
  let mut extra = 0.0
  let mut told = false
  while j >= 0 {
    let at = self.order[j]
    if !told {
      match self.sticky_extra.get(at) {
        Some((g, e)) if g == self.nodes[at].gen => {
          extra = e
          told = true
        }
        _ => ()
      }
    }
    if self.nodes[at].scroll_off is Some(_) {
      break
    }
    j = self.order_holder[j]
  }
  guard j >= 0 && self.order_holder[j] >= 0 else { return 0.0 }
  let room = self.order_holder[j]
  let top = wy(room) + off * ws(room)
  let held = self.nodes[self.order[h]]
  let foot = wy(h) + (held.lh + extra) * ws(h)
  let most = dmax(0.0, foot - n.lh * s - y)
  let mut dy = dclamp(top - y, 0.0, most)
  let g = self.pixel_grid
  if g > 0.0 {
    dy = (dy * g).round() / g
  }
  dy
}
