// A page's list's keys each drawn in several blocks (View::scrolls_window's `slices`): a long message a block a piece
// of it, each a block of the list of its own, made as it comes to show and taken for another's of its make, the key
// alone said to the page. Its blocks by their numbers (SliceIds): a key's slices each one of its own, the key's own
// where it says none (none said: each block its key's own number, nothing looked up), so the list's work, compiled
// once (View::scrolls_window_ids), keeps them as it keeps keys; what is asked of it by key (a block brought, a band,
// what is in sight) said of its slices here. What a key's blocks are as one lent to each (View::list_item_pointed,
// View::list_item_span).

///|
/// A page's list's blocks by their numbers where its keys are drawn in slices (View::scrolls_window's `slices`): the
/// number of each slice of a key's (by the key's number and which slice), the key and slice of each number; how many
/// slices each key had as its keys were last worked out; the blocks that show each key's slices now (what is lent to
/// each). Off (`on` false: no key said in slices) each block is its key's number, and nothing is kept.
priv struct SliceIds {
  mut on : Bool
  sids : Map[(Int, Int), Int]
  kid : Array[Int]
  slice : Array[Int]
  counts : Map[Int, Int]
  // (the keys' numbers last worked out into blocks' and those, so the same keys with the same slices are the same
  // array: what the list's work tells by its keys being the same array is as it was)
  mut last : (Array[Int], Array[Int])?
  /// the blocks made for each key's slices now, by the key's number (each block's as its key is now)
  shown : Map[Int, @signals.Signal[Array[View]]]
}

///|
fn SliceIds::new() -> SliceIds {
  { on: false, sids: Map([]), kid: [], slice: [], counts: Map([]), last: None, shown: Map([]) }
}

///|
/// The number of slice `b` of the key numbered `kid` (`kid` itself where nothing is in slices), given one as it is
/// first asked.
fn SliceIds::sid(self : SliceIds, kid : Int, b : Int) -> Int {
  guard self.on else { return kid }
  let b = if b < 0 { 0 } else { b }
  match self.sids.get((kid, b)) {
    Some(i) => i
    None => {
      let i = self.kid.length()
      self.sids[(kid, b)] = i
      self.kid.push(kid)
      self.slice.push(b)
      i
    }
  }
}

///|
/// The number of the key block `sid` is a slice of.
fn SliceIds::kid_of(self : SliceIds, sid : Int) -> Int {
  if self.on && sid >= 0 && sid < self.kid.length() {
    self.kid[sid]
  } else {
    sid
  }
}

///|
/// Which slice of its key block `sid` is (0 where nothing is in slices).
fn SliceIds::slice_of(self : SliceIds, sid : Int) -> Int {
  if self.on && sid >= 0 && sid < self.slice.length() {
    self.slice[sid]
  } else {
    0
  }
}

///|
/// How many slices the key numbered `kid` was in as its keys were last worked out (1 at least).
fn SliceIds::count_of(self : SliceIds, kid : Int) -> Int {
  self.counts.get(kid).unwrap_or(1)
}

///|
/// The first and the last slice of the key block `sid` is a slice of, by their numbers.
fn SliceIds::ends_of(self : SliceIds, sid : Int) -> (Int, Int) {
  let kid = self.kid_of(sid)
  (self.sid(kid, 0), self.sid(kid, self.count_of(kid) - 1))
}

///|
/// The blocks keys `kids` (by their numbers, in order) are drawn in, each in as many slices as `count` says of it now
/// (read: what follows the list's keys follows each key's slices too); the same array as last time where they come
/// out the same.
fn SliceIds::all(self : SliceIds, kids : Array[Int], count : (Int) -> Int) -> Array[Int] {
  let out : Array[Int] = []
  for kid in kids {
    let n = count(kid)
    let n = if n < 1 { 1 } else { n }
    self.counts[kid] = n
    for b in 0..<n {
      out.push(self.sid(kid, b))
    }
  }
  match self.last {
    Some((_, was)) if was.length() == out.length() => {
      let mut same = true
      for j, i in out {
        if was[j] != i {
          same = false
          break
        }
      }
      if same {
        return was
      }
    }
    _ => ()
  }
  self.last = Some((kids, out))
  out
}

///|
/// What a page's list's block lends of the key it shows as one, its slices all (View::scrolls_window's `slices`):
/// whether the pointer is on any of them (`pointed`), the stretch down the window they take together (`span`).
priv struct ListItemLent {
  pointed : () -> Bool
  span : () -> (Double, Double)?
}

///|
// kept across runs: what each block of a page's list in slices lends (View::lends), let go with it
let list_item_lent : Lent[ListItemLent] = Lent::new()

///|
/// The blocks that show slices of the key numbered `kid` now, made as they are asked.
fn SliceIds::shown_of(self : SliceIds, kid : Int) -> @signals.Signal[Array[View]] {
  match self.shown.get(kid) {
    Some(s) => s
    None => {
      // (handles: no two the same)
      let s = @signals.signal_by([], same=fn(_, _) { false })
      self.shown[kid] = s
      s
    }
  }
}

///|
/// Block `v` of a page's list in slices (`at`: its list's place, what counts its blocks), showing block `sid` as it is
/// now (`taken`: one put by and taken for another key's, that one's from then): where its key is in more than one slice
/// as it is made, lent what its key's blocks are as one (ListItemLent), among those of its key's from now (of another's
/// as it is taken for that one's), none as it is let go. A key in one slice lends nothing (View::list_item_pointed is
/// then the block's own), so the many blocks of keys drawn whole bind nothing more. The block.
fn SliceIds::lent_to(self : SliceIds, v : View, at : PlaceAt, sid : () -> Int, taken? : Bool = false) -> View {
  guard self.count_of(self.kid_of(@signals.untracked(sid))) > 1 else { return v }
  let of_now = fn() { self.kid_of(sid()) }
  let put = fn(kid : Int) {
    let s = self.shown_of(kid)
    s.set(@signals.untracked(fn() { s.get() }) + [v])
  }
  let take = fn(kid : Int) {
    match self.shown.get(kid) {
      Some(s) => {
        let now = @signals.untracked(fn() { s.get() }).filter(fn(o) { !o.same(v) })
        if now.is_empty() {
          self.shown.remove(kid)
        }
        s.set(now)
      }
      None => ()
    }
  }
  let of = Ref(@signals.untracked(of_now))
  put(of.val)
  // (one taken for another key: among that one's from then; one made for its key keeps it)
  if taken {
    v.reacts(of_now, fn(kid) {
      take(of.val)
      of.val = kid
      put(kid)
    }, at_start=false)
  }
  v.owns(fn() { take(of.val) }) |> ignore
  let tree = v.tree
  v.lends(list_item_lent, {
    pointed: fn() {
      let arr = self.shown_of(of_now()).get()
      for i = 0; i < arr.length(); i = i + 1 {
        if arr[i].alive() && arr[i].pointed_in() {
          return true
        }
      }
      false
    },
    span: fn() {
      @signals.untracked(fn() {
        let i = sid()
        let (first, last) = self.ends_of(i)
        guard tree.drawn_one(v.id()) is Some((_, _, y, _, s, _, _, _)) else { return None }
        match ((at.span_of)(first, i, false), (at.span_of)(i, last, false), (at.tall_of)(last)) {
          (Some(up), Some(down), Some(h)) => Some((y - up * s, y + (down + h) * s))
          _ => None
        }
      })
    },
  })
}

///|
/// Whether the pointer is on any block of the key of the page's list's block `self` is in, where its list draws its keys
/// in slices (View::scrolls_window's `slices`: a long message a block a piece, its ⋯ shown while the pointer is on any
/// piece of it): as that changes. Else, whether it is on `self` (View::pointed_in).
pub fn View::list_item_pointed(self : View) -> Bool {
  match self.lent(list_item_lent) {
    Some(it) => (it.pointed)()
    None => self.pointed_in()
  }
}

///|
/// The stretch down the window (top, foot) the key of the page's list's block `self` is in takes, all its slices
/// (View::scrolls_window's `slices`), where it is drawn now and they are counted: for what reads across all of them as
/// one, as it is painted (View::spatial_reveal's `span`). None outside such a list, or where they are not counted yet.
pub fn View::list_item_span(self : View) -> (Double, Double)? {
  match self.lent(list_item_lent) {
    Some(it) => (it.span)()
    None => None
  }
}
