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
/// Whether node `id` is held at a top (View::sticky, said Some) or is a currently displaced section heading
/// (View::sticky_section with `dy != 0`), or holds one that is: what is drawn of it changes as what scrolls it moves,
/// so nothing of it is kept drawn and moved whole (a page's list's row, its list drawn as one). When all section
/// headings have `dy == 0` (flat mode or top of list), returns false so the kept-drawn fast path stays active.
pub fn Tree::has_sticky_in(self : Tree, id : NodeId) -> Bool {
  if self.stickies.is_empty() && self.section_stickies.is_empty() {
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
      for at, g in self.section_stickies {
        if at < n {
          let i = self.order_of[at]
          if i >= o && i < end && self.nodes[at].live && self.nodes[at].gen == g && self.section_sticky_dy(at) != 0.0 {
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
  for at, g in self.section_stickies {
    let sid : NodeId = { at, gen: g }
    if (sid == id || self.holds_in_order(id, sid)) && self.section_sticky_dy(at) != 0.0 {
      return true
    }
  }
  false
}

///|
/// Whether node `id` itself is held at a top (View::sticky, said Some) or is a currently displaced section sticky node
/// (View::sticky_section with `dy != 0`): where it is drawn down what holds it is the hold's (sizes_steady's).
pub fn Tree::is_sticky(self : Tree, id : NodeId) -> Bool {
  match self.stickies.get(id.at) {
    Some((g, _)) if g == id.gen => return true
    _ => ()
  }
  match self.section_stickies.get(id.at) {
    Some(g) => g == id.gen && self.section_sticky_dy(id.at) != 0.0
    None => false
  }
}

///|
/// Whether any node is held at a top now (View::sticky, said Some) or registered as a section sticky node.
pub fn Tree::sticks_any(self : Tree) -> Bool {
  !self.stickies.is_empty() || !self.section_stickies.is_empty()
}

///|
/// Whether any node held at a top (View::sticky, said Some) or any currently displaced section heading is drawn now
/// (in the current walk order, not parked).
pub fn Tree::sticks_drawn(self : Tree) -> Bool {
  if self.stickies.is_empty() && self.section_stickies.is_empty() {
    return false
  }
  if self.order_due {
    return !self.stickies.is_empty() || !self.section_lists.is_empty()
  }
  let n = self.order_of.length()
  for at, e in self.stickies {
    if at < n && self.order_of[at] >= 0 && self.nodes[at].live && self.nodes[at].gen == e.0 {
      return true
    }
  }
  for at, g in self.section_stickies {
    if at < n &&
      self.order_of[at] >= 0 &&
      self.nodes[at].live &&
      self.nodes[at].gen == g &&
      self.section_sticky_dy(at) != 0.0 {
      return true
    }
  }
  false
}

///|
/// Resolve the enclosing section slot `(slot_at, held_at, key)` for node `at` (walking up parents until a registered
/// `section_slots` entry is found), or None if `at` is not inside an active section heading slot.
fn Tree::section_slot_of(self : Tree, at : Int, stop_at_scroll? : Bool = true) -> (Int, Int, Int)? {
  guard !self.section_slots.is_empty() else { return None }
  let mut i = at
  while i >= 0 && i < self.nodes.length() {
    let n = self.nodes[i]
    if !n.live {
      return None
    }
    match self.section_slots.get(i) {
      Some((gen, held_at, key)) if gen == n.gen => return Some((i, held_at, key))
      _ => ()
    }
    if stop_at_scroll && n.scroll_off is Some(_) {
      return None
    }
    i = n.parent
  }
  None
}

///|
/// Vertical stacking displacement `dy` (in list-local points) for a `View::sticky_section` node `at`.
fn Tree::section_sticky_dy(self : Tree, at : Int) -> Double {
  match self.section_slot_of(at) {
    Some((_, held_at, key)) =>
      match self.section_lists.get(held_at) {
        Some(hooks) => (hooks.dy_of)(key, 0.0)
        None => 0.0
      }
    None => 0.0
  }
}

///|
/// Available-viewport clip rect `(x0, y0, x1, y1)` in window coordinates `[top_edge, vh - bottom_edge]` for any
/// registered section heading slot or descendant inside one (including nested scrollable children and `Flow` headings
/// extending into the `top_edge` inset), or None outside a section heading slot.
pub fn Tree::section_clip_of(self : Tree, id : NodeId) -> (Double, Double, Double, Double)? {
  guard !self.section_slots.is_empty() && self.alive_id(id) else { return None }
  match self.section_slot_of(id.at, stop_at_scroll=false) {
    Some((_, held_at, _)) =>
      match self.section_lists.get(held_at) {
        Some(hooks) => (hooks.clip_of)()
        None => None
      }
    None => None
  }
}

///|
/// Whether node `id` itself is a registered section-heading slot (the foreground-pass root for a section heading).
pub fn Tree::is_section_slot_id(self : Tree, id : NodeId) -> Bool {
  match self.section_slots.get(id.at) {
    Some((gen, _, _)) => gen == id.gen
    None => false
  }
}

///|
/// Unified sticky vertical offset resolver shared by all draw, hit, projection, clip, and incremental a11y walks
/// (`each_drawn_in_order`, `drawn_one`, `projected`, `visible_in`, `shared.mbt`, and `said_pass`).
fn Tree::sticky_offset_for(
  self : Tree,
  at : Int,
  n : Node,
  y : Double,
  s : Double,
  room_y : Double,
  room_s : Double,
  held_y : Double,
  held_s : Double,
  held_lh : Double,
  extra : Double,
  with_drawn_off? : Bool = false,
) -> Double {
  if !self.stickies.is_empty() {
    match self.stickies.get(at) {
      Some((g, off)) if g == n.gen => {
        let most = dmax(0.0, held_y + (held_lh + extra) * held_s - n.lh * s - y)
        let mut dy = dclamp(room_y + off * room_s - y, 0.0, most)
        let grid = self.pixel_grid
        if grid > 0.0 {
          dy = (dy * grid).round() / grid
        }
        return dy
      }
      _ => ()
    }
  }
  if !self.section_stickies.is_empty() {
    match self.section_stickies.get(at) {
      Some(g) if g == n.gen =>
        match self.section_slot_of(at) {
          Some((slot_at, held_at, key)) =>
            match self.section_lists.get(held_at) {
              Some(hooks) => {
                let oy = if with_drawn_off {
                  let sn = self.nodes[slot_at]
                  let raw_oy = sn.look.drawn_off.1
                  let grid = self.pixel_grid
                  if grid > 0.0 && !sn.look.drawn_exact && raw_oy != 0.0 {
                    (raw_oy * grid).round() / grid
                  } else {
                    raw_oy
                  }
                } else {
                  0.0
                }
                let eff_dy = (hooks.dy_of)(key, oy)
                if eff_dy != 0.0 {
                  return eff_dy * room_s
                }
              }
              None => ()
            }
          None => ()
        }
      _ => ()
    }
  }
  0.0
}

///|
/// How far down node `n` (at `i` in the order) is drawn off where it is laid out by `View::sticky` or
/// `View::sticky_section`, using the unified `Tree::sticky_offset_for` resolver.
fn Tree::sticky_dy_at(
  self : Tree,
  i : Int,
  at : Int,
  n : Node,
  y : Double,
  s : Double,
  wy : (Int) -> Double,
  ws : (Int) -> Double,
) -> Double {
  if !self.stickies.is_empty() && self.stickies.contains(at) {
    let h = self.order_holder[i]
    guard h >= 0 else { return 0.0 }
    let mut j = h
    let mut extra = 0.0
    let mut told = false
    while j >= 0 {
      let jat = self.order[j]
      if !told {
        match self.sticky_extra.get(jat) {
          Some((g, e)) if g == self.nodes[jat].gen => {
            extra = e
            told = true
          }
          _ => ()
        }
      }
      if self.nodes[jat].scroll_off is Some(_) {
        break
      }
      j = self.order_holder[j]
    }
    guard j >= 0 && self.order_holder[j] >= 0 else { return 0.0 }
    let room = self.order_holder[j]
    let held = self.nodes[self.order[h]]
    return self.sticky_offset_for(at, n, y, s, wy(room), ws(room), wy(h), ws(h), held.lh, extra, with_drawn_off=true)
  }
  if !self.section_stickies.is_empty() && self.section_stickies.contains(at) {
    let room_s = match self.section_slot_of(at) {
      Some((_, held_at, _)) if held_at >= 0 && held_at < self.order_of.length() && self.order_of[held_at] >= 0 =>
        ws(self.order_of[held_at])
      _ => s
    }
    return self.sticky_offset_for(at, n, y, s, 0.0, room_s, 0.0, room_s, 0.0, 0.0, with_drawn_off=true)
  }
  0.0
}
