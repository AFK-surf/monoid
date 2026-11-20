// What the parts of a page's list's block keep of the key it shows (View::scrolls_window's `reused`): a reused block is
// a new block to everything but the allocator (answering.mbt), so what its parts keep of their own (how far a row in
// it is scrolled across, a switch of its own, a moment it waits for) is its key's, never the block's. The framework's,
// not each part's (the coordinator of the migration, 2026-11-17: 「复杂性由框架扛，应用层只写外观」): a row or column
// that scrolls in it (View::scrolls, but one scrolled beside others as one: Scroll::beside) and a switch it keeps by
// its key (View::reused_bool) are kept by the list for the key the block leaves, by where each is in the block (its
// path of places among what holds it), and given what was kept of the key it is taken for (none: as made); what is
// done as it is taken for another key is said by View::on_reused. Kept as the block leaves what shows (put by, or let
// go where too many are) and as it is taken for another key; read as a part is made in it (one made anew for a key
// that comes back) and as it is taken. Nothing of it is read as a frame is laid out or drawn: where a row is scrolled
// is its own Scroll's as ever (Scroll::where_at), and the paths are worked out only as a part is made in it or the
// block changes keys. A key kept so is one that keeps something not as made (scrolled past half a point, a switch not
// at its default), the last `reused_kept_most` of them a list; one back as made keeps nothing.

///|
/// What a block of a page's list taken for another key holds of what its parts keep (View::scrolls_window's
/// `reused`), by the node of each part, let go with it; and what was kept of its key now, by a part's path.
// (`kept_keys`: its tests alone read it)
#warnings("-unused_field")
priv struct ReusedSlot {
  /// the rows and columns that scroll in it (View::scrolls), each its own, by the node it scrolls in
  scrolls : Map[Int, (View, Scroll)]
  /// the switches kept by its key (View::reused_bool), each with its default, by the node that said them, in the order
  /// said
  bools : Map[Int, (View, Array[(@signals.Signal[Bool], Bool)])]
  /// what is done as it is taken for another key (View::on_reused), by the node that said it
  on_reused : Map[Int, (View, Array[() -> Unit])]
  /// how far what scrolls at a path was kept scrolled for its key now, and what a switch there was kept at (none: as
  /// made)
  mut kept_x : (String) -> Double?
  mut kept_bool : (String) -> Bool?
  /// how many keys its list keeps something of (ReusedKept), for a test
  kept_keys : () -> Int
  /// how many times it was taken for another key (ReusedSlot::told_reused): what is drawn in it before and after is
  /// another key's, never one thing stepping (ui's sizes_steady.mbt)
  mut epoch : Int
}

///|
/// How many keys a page's list keeps what its blocks' parts kept of (ReusedKept): those kept last, the one kept longest
/// ago let go past them.
let reused_kept_most : Int = 256

///|
/// What a page's list keeps of its keys' blocks' parts (ReusedSlot), by key: how far each that scrolls was, each switch
/// not at its default, by path; and the keys in the order last kept.
priv struct ReusedKept[K] {
  xs : Map[K, Map[String, Double]]
  bools : Map[K, Map[String, Bool]]
  order : Array[K]
}

///|
fn[K : Hash + Eq] ReusedKept::new() -> ReusedKept[K] {
  { xs: Map([]), bools: Map([]), order: [] }
}

///|
/// What `k`'s block's parts kept: kept, or nothing kept of `k` where none keeps anything not as made.
fn[K : Hash + Eq] ReusedKept::keep(
  self : ReusedKept[K],
  k : K,
  xs : Map[String, Double],
  bools : Map[String, Bool],
) -> Unit {
  let had = self.xs.contains(k)
  if xs.is_empty() && bools.is_empty() {
    if had {
      self.xs.remove(k)
      self.bools.remove(k)
      match self.order.search(k) {
        Some(i) => self.order.remove(i) |> ignore
        None => ()
      }
    }
    return
  }
  self.xs[k] = xs
  self.bools[k] = bools
  // (the last kept last: one kept again goes after the others, those kept longest ago let go first)
  if had {
    match self.order.search(k) {
      Some(i) => self.order.remove(i) |> ignore
      None => ()
    }
  }
  self.order.push(k)
  if !had {
    if self.order.length() > reused_kept_most {
      let first = self.order.remove(0)
      self.xs.remove(first)
      self.bools.remove(first)
    }
  }
}

///|
fn[K : Hash + Eq] ReusedKept::x_of(self : ReusedKept[K], k : K, path : String) -> Double? {
  match self.xs.get(k) {
    Some(m) => m.get(path)
    None => None
  }
}

///|
fn[K : Hash + Eq] ReusedKept::bool_of(self : ReusedKept[K], k : K, path : String) -> Bool? {
  match self.bools.get(k) {
    Some(m) => m.get(path)
    None => None
  }
}

///|
/// How many keys it keeps something of.
fn[K] ReusedKept::length(self : ReusedKept[K]) -> Int {
  self.order.length()
}

///|
/// Node `v` the block of a page's list that is taken for other keys (View::scrolls_window's `reused`), what its parts
/// kept of its key now read through `x`, `b`: what they keep known by it from now, let go with it.
fn Tree::reused_made(
  self : Tree,
  v : View,
  x : (String) -> Double?,
  b : (String) -> Bool?,
  kept_keys : () -> Int,
) -> Unit {
  let rs : ReusedSlot = {
    scrolls: Map([]),
    bools: Map([]),
    on_reused: Map([]),
    kept_x: x,
    kept_bool: b,
    kept_keys,
    epoch: 0,
  }
  let at = v.at
  self.reused_slots[at] = rs
  v.owns(fn() {
    if self.reused_slots.get(at) is Some(r) && physical_equal(r, rs) {
      self.reused_slots.remove(at)
    }
  })
  |> ignore
}

///|
/// The block of a page's list taken for other keys that node `at` is in, nearest it (itself, or what holds it), and what
/// it holds of what its parts keep: none where it is in none.
fn Tree::reused_root(self : Tree, at : Int) -> (Int, ReusedSlot)? {
  guard self.reused_slots.length() > 0 else { return None }
  let mut i = at
  while i >= 0 && i < self.nodes.length() {
    match self.reused_slots.get(i) {
      Some(rs) => return Some((i, rs))
      None => ()
    }
    i = self.nodes[i].parent
  }
  None
}

///|
/// How many times the block of a page's list taken for other keys that node `at` is in, nearest it (itself, or what
/// holds it), was taken for another key (View::scrolls_window's `reused`): none where it is in none, or is let go of.
/// What is drawn of it with another count shows another key: judged anew, never as one thing stepping (ui's
/// sizes_steady.mbt).
pub fn Tree::reused_epoch_of(self : Tree, at : Int) -> Int? {
  guard at >= 0 && at < self.nodes.length() && self.nodes[at].live else { return None }
  self.reused_root(at).map(fn(r) { r.1.epoch })
}

///|
/// Where node `at` is in node `root` (one that holds it): its place among what holds it, and that one's, out to `root`
/// ("0/2/1"; "" for `root` itself): the same for a part made the same way in any block of its make, whichever key it
/// shows. Walked only as a part is made in a block or the block changes keys, never as a frame is laid out or drawn.
fn Tree::reused_path(self : Tree, root : Int, at : Int) -> String {
  let steps : Array[Int] = []
  let mut i = at
  while i != root && i >= 0 && i < self.nodes.length() {
    let p = self.nodes[i].parent
    guard p >= 0 else { break }
    steps.push(self.nodes[p].kids.search(i).unwrap_or(-1))
    i = p
  }
  let b = StringBuilder()
  for j = steps.length() - 1; j >= 0; j = j - 1 {
    b.write_string(steps[j].to_string())
    if j > 0 {
      b.write_char('/')
    }
  }
  b.to_string()
}

///|
/// What its parts keep now, by path, as the block it is of (node `root`) leaves the key it shows (put by, let go, or
/// taken for another): how far each that scrolls is (stopped there: nothing goes on by itself in a block out of sight),
/// those scrolled past half a point; each switch not at its default.
fn ReusedSlot::taken(self : ReusedSlot, tree : Tree, root : Int) -> (Map[String, Double], Map[String, Bool]) {
  let xs : Map[String, Double] = Map([])
  let bools : Map[String, Bool] = Map([])
  for e in self.scrolls.to_array() {
    let (at, (v, s)) = e
    guard v.alive() else { continue }
    let x = s.rebind_take()
    if x > 0.5 {
      xs[tree.reused_path(root, at)] = x
    }
  }
  for e in self.bools.to_array() {
    let (at, (v, sigs)) = e
    guard v.alive() else { continue }
    let path = tree.reused_path(root, at)
    for i, sb in sigs {
      let now = sb.0.untracked()
      if now != sb.1 {
        bools[path + "#" + i.to_string()] = now
      }
    }
  }
  (xs, bools)
}

///|
/// Taken for another key: what is done so (View::on_reused), each of what lives of it.
fn ReusedSlot::told_reused(self : ReusedSlot) -> Unit {
  self.epoch = self.epoch + 1
  for e in self.on_reused.to_array() {
    let (_, (v, fs)) = e
    guard v.alive() else { continue }
    for f in fs.copy() {
      f()
    }
  }
}

///|
/// Taken for another key: each switch of its parts at what was kept of that key (none: its default), where it is in the
/// block (node `root`) as it is now.
fn ReusedSlot::put_bools(self : ReusedSlot, tree : Tree, root : Int) -> Unit {
  for e in self.bools.to_array() {
    let (at, (v, sigs)) = e
    guard v.alive() else { continue }
    let path = tree.reused_path(root, at)
    for i, sb in sigs {
      sb.0.set((self.kept_bool)(path + "#" + i.to_string()).unwrap_or(sb.1))
    }
  }
}

///|
/// Taken for another key, what it holds settled for it: each that scrolls in it put where it was kept for that key (none:
/// its start), at once, no scroll of the hand's.
fn ReusedSlot::put_scrolls(self : ReusedSlot, tree : Tree, root : Int) -> Unit {
  for e in self.scrolls.to_array() {
    let (at, (v, s)) = e
    guard v.alive() else { continue }
    s.rebind_put((self.kept_x)(tree.reused_path(root, at)).unwrap_or(0.0))
  }
}

///|
/// What scrolls in node `v` (View::scrolls), one of a block taken for other keys: known by it, put where it was kept for
/// the key it shows now where it was (a block made anew for a key that comes back; what shows in it made again for
/// another switch of the key's).
fn Tree::reused_scroll(self : Tree, v : View, s : Scroll) -> Unit {
  guard !s.shared && self.reused_root(v.at) is Some((root, rs)) else { return }
  let at = v.at
  let gen = v.gen
  rs.scrolls[at] = (v, s)
  v.owns(fn() {
    if rs.scrolls.get(at) is Some((w, _)) && w.gen == gen {
      rs.scrolls.remove(at)
    }
  })
  |> ignore
  match (rs.kept_x)(self.reused_path(root, at)) {
    Some(x) => s.rebind_put(x)
    None => ()
  }
}

///|
/// A switch of its own (a code block wrapped, a part opened), `default` as made: in a block of a page's list taken for
/// other keys (View::scrolls_window's `reused`), the key's it shows, never the block's: kept for that key as the block
/// leaves it, at what was kept of the key it is taken for (none: `default`) as it is, at once. Elsewhere simply a
/// signal. Said as the node is made, each in the same order.
pub fn View::reused_bool(self : View, default? : Bool = false) -> @signals.Signal[Bool] {
  let tree = self.tree
  guard self.alive() && tree.reused_root(self.at) is Some((root, rs)) else {
    return @signals.signal(default)
  }
  let at = self.at
  let gen = self.gen
  let mine = match rs.bools.get(at) {
    Some((w, xs)) if w.gen == gen => xs
    _ => {
      let xs = []
      rs.bools[at] = (self, xs)
      self.owns(fn() {
        if rs.bools.get(at) is Some((w, _)) && w.gen == gen {
          rs.bools.remove(at)
        }
      })
      |> ignore
      xs
    }
  }
  let path = tree.reused_path(root, at) + "#" + mine.length().to_string()
  let sig = @signals.signal((rs.kept_bool)(path).unwrap_or(default))
  mine.push((sig, default))
  sig
}

///|
/// `f` done as the block of a page's list it is in is taken for another key (View::scrolls_window's `reused`), before
/// what it holds is that key's: what it was doing for the one before called off (a moment waited for, a note shown for a
/// while). Not as it is taken for the key it showed, nor in a node of no such block.
pub fn View::on_reused(self : View, f : () -> Unit) -> Unit {
  let tree = self.tree
  guard self.alive() && tree.reused_root(self.at) is Some((_, rs)) else { return }
  let at = self.at
  let gen = self.gen
  match rs.on_reused.get(at) {
    Some((w, fs)) if w.gen == gen => fs.push(f)
    _ => {
      rs.on_reused[at] = (self, [f])
      self.owns(fn() {
        if rs.on_reused.get(at) is Some((w, _)) && w.gen == gen {
          rs.on_reused.remove(at)
        }
      })
      |> ignore
    }
  }
}

///|
/// What it does by itself, and the hand on it, stopped where they are, nothing told as scrolled (its bar).
fn Scroll::rebind_still(self : Scroll) -> Unit {
  (self.settle_off.val)()
  self.settle_off.val = fn() {  }
  self.edge.set(None)
  self.notch.set(None)
  self.fling.set(None)
  self.past.set(None)
  self.hand_on.set(false)
  self.claimed = false
  self.hand_v = 0.0
}

///|
/// As the block of a page's list it is in leaves the key it shows (ReusedSlot::taken): where it is at the logic's
/// moment, stopped there, quietly.
fn Scroll::rebind_take(self : Scroll) -> Double {
  let t = match self.host {
    Some(v) if v.alive() => v.tree.logic_said()
    _ => 0.0
  }
  let x = @signals.untracked(fn() { self.where_at(t) })
  self.rebind_still()
  self.x.set(x)
  x
}

///|
/// As the block of a page's list it is in is taken for a key (ReusedSlot::put_scrolls, Tree::reused_scroll): put at
/// `to`, at once, quietly (the Tester's judges told it was put: Tree::scroll_put_at); where it is there already and on
/// nothing by itself, nothing.
fn Scroll::rebind_put(self : Scroll, to : Double) -> Unit {
  let to = dmax(to, 0.0)
  if self.x.untracked() == to &&
    self.fling.untracked() is None &&
    self.edge.untracked() is None &&
    self.notch.untracked() is None &&
    self.past.untracked() is None &&
    !self.hand_on.untracked() {
    return
  }
  match self.host {
    Some(v) if v.alive() => self.put_at = v.tree.logic_said()
    _ => ()
  }
  self.rebind_still()
  self.x.set(to)
  self.tuck_met(to)
  self.offset_said()
}
