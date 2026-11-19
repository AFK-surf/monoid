// What a page's list has in sight, told to handlers (ListPlace::on_sight, ListPlace::sight_now): for what keeps
// accounts and tells the core of them (what is read, the way back to its foot, a table of contents following), never
// for what is made or bound (its result is no layout's: detlint's layout-told, by name). Counted by its keys' blocks
// as they come to rest (each as tall as it is counted, not as a way has it on its way), the scroll where it rests (at
// its foot where it follows it, where a wheel's notch eases to, where it is as a fling goes): what is told at a cause is
// where that cause leaves it, not a frame on its way there. Told at the moments what is under a still pointer is found
// again (Tree::hand_at_end's): the change of an input or of data, as it is told whole, one at its moment
// (View::at_moment), a glide's or a way's end, the window given another size, its first layout; never on a frame as a
// glide or a way goes; only as it differs from what was told last; and once the layout that does what its place asked
// (ListPlace::bring, centre, to_end) is done. It is read off the blocks as they are counted (one not measured yet as
// `est`, told again with its height at its way's end) and the scroll: telling lays out and measures nothing. A list
// none listens to (no ListPlace::on_sight) has nothing of it worked out or owed, at any moment. A key coming by data
// on its way in is not seen whole, nor the list at its foot with all of it there whole, till that key is drawn whole:
// at its way's end, told then once (its way's end a moment the hand is found again at); where it comes at once (an
// answer's, an at_once list's, motion reduced), in the change (the coordinator of the migration, 2026-11-14: a chat
// told a message read before its words showed). Where the list is (`at_foot`, `from_foot`) is as it lays out.

///|
/// What a page's list (View::scrolls_window) has in sight, counted by its keys' blocks (its head and its foot never
/// the first or the last): `first` the first key that shows under what covers its top (Scroll::top_covered: the bar it
/// runs under; none, its own top) and `into` how far that edge is down its block's top (less than 0 where its head
/// shows under it: as much as the head shows, a table of contents telling that from its first key at the top), `last`
/// the last that shows, `whole` the last wholly in what shows (its top no higher than the edge under what covers its
/// top, its foot over the foot's top, where it has them; none where none is) and drawn whole (before the first in
/// sight still on its way in), `from_top` how far it is scrolled from its top, `from_foot` how far it is scrolled from
/// its foot, `shows` how tall what shows is,
/// `at_foot` whether it is at its foot (where the list is, as it lays out: what follows it, a way back to it),
/// `foot_whole` whether it is at its foot with none from the first in sight on still on its way in (its end seen);
/// `tall` how tall `first`'s block is as it is counted (how far down it `into` is, as a share: a reader's place in a
/// block of its text).
///
/// `slice`: which of `first`'s slices it is (View::scrolls_window's `slices`; 0 where it is drawn in one), `into` and
/// `tall` that slice's; `last_slice` which of `last`'s; `whole_slice` which of `whole`'s (a key seen whole only where
/// that is its last).
#derive(Eq, Debug)
pub(all) struct Sight[K] {
  first : K
  slice : Int
  into : Double
  tall : Double
  last : K
  last_slice : Int
  whole : K?
  whole_slice : Int
  from_top : Double
  from_foot : Double
  shows : Double
  at_foot : Bool
  foot_whole : Bool
}

///|
/// `f` told what the list has in sight as that changes (the file's head): at an input, at the end of a glide or a way
/// that moved what shows, at a change of data, its first layout; never as a frame is drawn on a way; never twice the
/// same in a row. For a handler's accounts, never for what is made.
pub fn[K] ListPlace::on_sight(self : ListPlace[K], f : (Sight[K]) -> Unit) -> Unit {
  let ids = self.ids
  let sl = self.slices
  self.at.sight_fns.push(fn(s) { f(s.keyed(ids, sl)) })
  // (its list told it from now: none listening, nothing of it is worked out or owed)
  (self.at.sight_listened)()
}

///|
/// What its list worked out that nothing follows (its blocks' places, its keys, read untracked as it was laid out and
/// told what is in sight) let go of what that read: for what reads the list one last time as its page is left, so it
/// holds nothing of it after (as its page is put by at rest, View::on_rest does it).
pub fn[K] ListPlace::rest_unwatched(self : ListPlace[K]) -> Unit {
  (self.at.rest_unwatched)()
}

///|
/// Its list put by at rest, as what holds it is (a page kept as it is left, its View::on_rest): what it has in sight
/// told once more where that is owed, what still goes stopped where it is, then told nothing while it rests and what it
/// worked out let go of (ListPlace::rest_unwatched). A list nothing puts so is as it ever was.
pub fn[K] ListPlace::rest(self : ListPlace[K]) -> Unit {
  (self.at.rest_at)()
}

///|
/// Its list woken from rest (ListPlace::rest): told what it has in sight again.
pub fn[K] ListPlace::wake(self : ListPlace[K]) -> Unit {
  (self.at.wake_at)()
}

///|
/// What was last told of what the list has in sight (ListPlace::on_sight), for a handler to read; where none is told
/// it, what it has in sight as it is counted now; none before its first layout.
pub fn[K] ListPlace::sight_now(self : ListPlace[K]) -> Sight[K]? {
  let now = if self.at.sight_fns.is_empty() { (self.at.sight_of)() } else { self.at.sight }
  now.map(fn(s) { s.keyed(self.ids, self.slices) })
}

///|
/// What the list has in sight at this moment as it is counted (Sight's), even while a fling glides or a notch eases on
/// (`on_sight` and `sight_now` tell where that leaves it, at its end): for what records where the reader left the list
/// as they leave it mid-glide, never for what is made or bound. None before its first layout or once it is let go.
pub fn[K] ListPlace::sight_live(self : ListPlace[K]) -> Sight[K]? {
  (self.at.sight_of)().map(fn(s) { s.keyed(self.ids, self.slices) })
}

///|
/// How far block `to`'s top lies under block `from`'s as the list counts its blocks now (measured, or `est` where not
/// yet): read off what is counted, nothing laid out or measured. None where either is not among its keys, or the list is
/// not made; `measured`: none as well where a block from `from` down to `to` is not measured yet (how far is then not
/// known, only guessed). `from_slice`, `to_slice`: which slice of each key (View::scrolls_window's `slices`), its first
/// where it says none.
pub fn[K : Hash + Eq] ListPlace::span_between(
  self : ListPlace[K],
  from : K,
  to : K,
  from_slice? : Int = 0,
  to_slice? : Int = 0,
  measured? : Bool = false,
) -> Double? {
  // (looked up, not numbered: a key never among them gets no number for it)
  match (self.ids.ids.get(from), self.ids.ids.get(to)) {
    (Some(a), Some(b)) => (self.at.span_of)(self.slices.sid(a, from_slice), self.slices.sid(b, to_slice), measured)
    _ => None
  }
}

///|
/// What is in sight of the blocks by their numbers, as of the keys (ListKeys; their slices by SliceIds).
fn[K] Sight::keyed(self : Sight[Int], ids : ListKeys[K], sl : SliceIds) -> Sight[K] {
  {
    first: ids.key(sl.kid_of(self.first)),
    slice: sl.slice_of(self.first),
    into: self.into,
    tall: self.tall,
    last: ids.key(sl.kid_of(self.last)),
    last_slice: sl.slice_of(self.last),
    whole: self.whole.map(fn(i) { ids.key(sl.kid_of(i)) }),
    whole_slice: self.whole.map_or(0, fn(i) { sl.slice_of(i) }),
    from_top: self.from_top,
    from_foot: self.from_foot,
    shows: self.shows,
    at_foot: self.at_foot,
    foot_whole: self.foot_whole,
  }
}

///|
/// What the list has in sight now told to what is told it, where it differs from what was told last (one key one
/// number: the same in sight is the same numbers).
fn PlaceAt::sight_tell(self : PlaceAt) -> Unit {
  guard (self.sight_of)() is Some(now) else { return }
  if self.sight == Some(now) {
    return
  }
  self.sight = Some(now)
  for f in self.sight_fns {
    f(now)
  }
}

///|
/// What blocks `all` (as they are counted) have in sight in scroll `s` at moment `t`, the foot's room `foot` under them
/// and the room kept under the last block `room` over that (View::scrolls_window's foot_room: at its foot is at that
/// room's foot), the blocks at `coming` (by where each is among them) on their way in (Sight's); none where none is or
/// nothing shows yet.
fn[K] sight_counted(
  all : Places[K],
  s : Scroll,
  t : Double,
  foot : Double,
  room : Double,
  coming : Array[Int],
) -> Sight[K]? {
  let n = all.length()
  guard n > 0 && s.seen.get() is Some((_, vh)) && vh > 0.0 else { return None }
  let most = dmax(0.0, all.foot() + room + foot + s.tuck_room.get() - vh)
  // (where it rests: at its foot where it follows it; where a notch eases to; else where it is now)
  let x = if s.x.get() == @double.infinity {
    most
  } else {
    match s.notch.get() {
      Some(nt) if s.fling.get() is None && s.edge.get() is None => nt.x0 + nt.total
      _ => s.where_at(t)
    }
  }
  let x = dclamp(x, dmin(s.top_now(), most), most)
  let below = x + vh
  // (the first with something showing under what covers its top (Scroll::top_covered: the bar it runs under), how far
  // down it that edge is)
  let under = x + s.top_covered()
  let i = all.first_past(under).min(n - 1)
  let j = (all.first_past(below - 1.0e-6).min(n - 1)).max(i)
  // (wholly in what shows: its foot no lower than the foot's top, its top no higher than the edge under what covers its
  // top)
  // (and drawn whole: before the first from the first in sight on still on its way in)
  let mut c = n
  for q in coming {
    if q >= i && q < c {
      c = q
    }
  }
  let k = (all.first_past(below - foot + 1.0e-6) - 1).min(c - 1)
  let whole = if k >= 0 && k >= i && all.top(k) >= under - 1.0e-6 { Some(all.key(k)) } else { None }
  Some({
    first: all.key(i),
    slice: 0,
    into: under - all.top(i),
    tall: all.h(i),
    last: all.key(j),
    last_slice: 0,
    whole,
    whole_slice: 0,
    from_top: x,
    from_foot: most - x,
    shows: vh,
    at_foot: most - x <= 1.0e-6,
    foot_whole: most - x <= 1.0e-6 && c == n,
  })
}
