// A column that scrolls (View::scrolls) holding blocks by their keys, each made only while it shows. Where it is
// scrolled to is an anchor: the first block at the top of what shows that holds it, and how far down that block's top
// the top of what shows is. As the column is laid out, in that one layout (its fill, run by View::scrolls as flex
// gives it its room), the scroll's move since is carried to the anchor, what meets where it shows is made and measured
// at the column's width (one never measured counted `est` till then), and the scroll is put back from the anchor: what
// comes, goes or is measured anew over what shows moves none of it, and nothing laid out is told afterwards to make
// things by. Moved by the hand, the wheel or a fling, the anchor is the first block seen before that still shows: one
// come in over it measured otherwise than it was counted grows up from it, what was seen staying where the move put it.
// Scrolled so that a block comes to show, the column is marked laid out again; so that one made no more shows, it is
// put by at once, nothing laid out: what is made is what shows. What shows is worked out going out from the blocks
// whose place is sure (the anchor; what was seen and still shows), up and down, one never measured as far as it goes
// that way till it is measured: a block made and still in sight is never let go for one come in over it (worked out
// from the top down by where the blocks were counted, one never measured come in at the top was all that showed till it
// was measured, every block under it let go and made again, the anchor with them: what was read jumped as far as the
// block was taller than counted, and a list opened at its foot made and let go its blocks several times over), nor for
// one come at its foot: what showed as the column began to be laid out stays made while what shows is measured, and
// what shows no more is let go once, as the last of that measuring finds what shows (a key appended at its foot, never
// measured, was all that showed for a pass: every block in sight let go and made again, its words drawn anew, for one
// row come).

///|
/// A page's list's blocks as they are counted (View::scrolls_window's `laid`): their keys, each one's height as it is
/// laid out (on its host's pixels where it sets a page's list's rows on them) and whether it was laid out, and the sums
/// of those heights two by two up a tree. Each sum is its two parts' as they are now, added anew whenever one of them
/// changes, none ever added to or taken from: where a block's top is (the sum of all over it, taken down the tree in
/// one order of adding) is a function of the heights as they are now and of how many there are, whatever order they
/// were measured in; on a host's pixels put on the grid's own number for the pixel it comes to, as flex puts each row's
/// top (layout_flex's rows_grid). A height told changes its leaf and the sums over it, as many as the tree is deep;
/// a top is that many additions: what is counted of 1,500 keys as one is measured no more than of 30, but for a few.
priv struct Column[K] {
  mut keys : Array[K]
  hs : Array[Double]
  knowns : Array[Bool]
  /// the tree, `cap` leaves (the heights, then 0) from `cap` on, each sum over them at half its index, the whole at 1
  mut sums : Array[Double]
  /// each top as it was last read and the count of changes it was read at (`told`): read again only once a height is
  /// told or all of it filled again since, never added up anew for each reading of it
  tops : Array[Double]
  tops_at : Array[Int]
  mut told : Int
  mut cap : Int
  mut grid : Double
  /// the leaves put since it was filled again (Column::refill) that the sums over them are to be added anew for, from
  /// and up to (Column::summed)
  mut from : Int
  mut upto : Int
  /// how many times it was filled again (Column::refill): its keys as they were while this is the same
  mut refills : Int
  /// where its first block's top is: under the list's head, as tall as that is laid out (View::scrolls_window's
  /// `head`), each top and its foot that much further down, what is found by where it is (first_past) found so
  mut start : Double
}

///|
fn[K] Column::new() -> Column[K] {
  {
    keys: [],
    hs: [],
    knowns: [],
    sums: [0.0, 0.0],
    tops: [],
    tops_at: [],
    told: 0,
    cap: 1,
    grid: 0.0,
    from: 0,
    upto: 0,
    refills: 0,
    start: 0.0,
  }
}

///|
/// Its first block's top put at `h` (the head's height, as it is laid out): every top read anew.
fn[K] Column::start_at(self : Column[K], h : Double) -> Unit {
  if h != self.start {
    self.start = h
    self.told = self.told + 1
  }
}

///|
fn[K] Column::length(self : Column[K]) -> Int {
  self.keys.length()
}

///|
/// Filled again for `keys` on the grid of `g` pixels a point, kept as it is up to the first place whose key is not the
/// key it held there (`whole`: from the first): that place, from which each block's height is to be put
/// (Column::put), the sums over them then added anew (Column::summed). Its shape is a function of how many blocks it
/// holds alone (a block at place i in the same leaf whatever came before), so what is kept is what a filling of all of
/// it would have come to: a key appended puts one leaf and adds the sums over it, as a height told does; a key put in
/// before the first, all of it. Whether the heights of those kept changed is told by Column::set, as ever. What it keeps
/// is written where it is, grown or cut to as many: nothing made again for each key.
fn[K : Eq] Column::refill(self : Column[K], keys : Array[K], g : Double, whole? : Bool = false) -> Int {
  let n = keys.length()
  let was = self.keys.length()
  let mut cap = 1
  while cap < n {
    cap = cap * 2
  }
  // (the first place whose key is another: compared key by key, never by the arrays' being one)
  let mut p = 0
  let same_shape = g == self.grid && cap == self.cap && self.sums.length() == 2 * cap
  if same_shape && !whole {
    let m = if n < was { n } else { was }
    while p < m && keys[p] == self.keys[p] {
      p = p + 1
    }
  }
  self.keys = keys
  self.refills = self.refills + 1
  self.grid = g
  // (every top kept read again: none of them read at this count)
  self.told = self.told + 1
  if self.hs.length() > n {
    self.hs.truncate(n)
    self.knowns.truncate(n)
  }
  while self.hs.length() < n {
    self.hs.push(0.0)
    self.knowns.push(false)
  }
  while self.tops.length() < n {
    self.tops.push(0.0)
    self.tops_at.push(-1)
  }
  self.cap = cap
  if same_shape {
    // (the leaves it held past as many as it holds now: none)
    for i in n..<(if was < cap { was } else { cap }) {
      self.sums[cap + i] = 0.0
    }
  } else {
    self.sums = Array::make(2 * cap, 0.0)
  }
  self.from = p
  self.upto = if was > n && same_shape { (if was < cap { was } else { cap }) } else { n }
  p
}

///|
/// Block `i`'s height as laid out on the grid and whether it was laid out, as it is filled again (Column::refill).
fn[K] Column::put(self : Column[K], i : Int, h : Double, known : Bool) -> Unit {
  self.hs[i] = h
  self.knowns[i] = known
  self.sums[self.cap + i] = h
}

///|
/// The sums over the leaves put since it was filled again (Column::put) added anew, each its two parts' as they are
/// now, from the leaves up: those over the leaves from where it was kept, no others.
fn[K] Column::summed(self : Column[K]) -> Unit {
  guard self.from < self.upto else { return }
  let sums = self.sums
  let mut lo = (self.cap + self.from) / 2
  let mut hi = (self.cap + self.upto - 1) / 2
  while lo >= 1 {
    for q in lo..=hi {
      sums[q] = sums[2 * q] + sums[2 * q + 1]
    }
    lo = lo / 2
    hi = hi / 2
  }
  self.from = 0
  self.upto = 0
}

///|
/// Whether keys `now` are other than `was`: as many no more, or one of them another, from `from` on (where
/// Column::refill found the first that is: those before it the same).
fn[K : Eq] keys_other(was : Array[K], now : Array[K], from : Int) -> Bool {
  if was.length() != now.length() {
    return true
  }
  for i in from..<now.length() {
    if now[i] != was[i] {
      return true
    }
  }
  false
}

///|
/// Block `i`'s height told: `h` as laid out on the grid, whether it was laid out; the sums over it added anew.
fn[K] Column::set(self : Column[K], i : Int, h : Double, known : Bool) -> Unit {
  self.told = self.told + 1
  self.hs[i] = h
  self.knowns[i] = known
  let mut p = self.cap + i
  self.sums[p] = h
  p = p / 2
  while p >= 1 {
    self.sums[p] = self.sums[2 * p] + self.sums[2 * p + 1]
    p = p / 2
  }
}

///|
/// Where block `i`'s top is: the sums of all over it, taken from the root down to it (the one order of adding for it),
/// on the grid's own number for its pixel where there is one.
fn[K] Column::top(self : Column[K], i : Int) -> Double {
  if self.tops_at[i] == self.told {
    return self.tops[i]
  }
  // (the sums over it, as Column::top_summed takes them: written here again, not called, a top being read so often)
  let mut acc = 0.0
  let mut node = 1
  let mut lo = 0
  let mut hi = self.cap
  while node < self.cap {
    let mid = (lo + hi) / 2
    if i < mid {
      node = 2 * node
      hi = mid
    } else {
      acc = acc + self.sums[2 * node]
      node = 2 * node + 1
      lo = mid
    }
  }
  let g = self.grid
  let t = self.start + (if g > 0.0 { (acc * g + 0.5).floor() / g } else { acc })
  self.tops[i] = t
  self.tops_at[i] = self.told
  t
}

///|
/// The sums of all over block `i`, taken from the root down to it (Column::top's, not yet on the grid).
fn[K] Column::top_summed(self : Column[K], i : Int) -> Double {
  let mut acc = 0.0
  let mut node = 1
  let mut lo = 0
  let mut hi = self.cap
  while node < self.cap {
    let mid = (lo + hi) / 2
    if i < mid {
      node = 2 * node
      hi = mid
    } else {
      acc = acc + self.sums[2 * node]
      node = 2 * node + 1
      lo = mid
    }
  }
  self.start + acc
}

///|
/// Block `i`'s key, height as laid out, and whether it was laid out.
fn[K] Column::key(self : Column[K], i : Int) -> K {
  self.keys[i]
}

///|
fn[K] Column::h(self : Column[K], i : Int) -> Double {
  self.hs[i]
}

///|
fn[K] Column::known(self : Column[K], i : Int) -> Bool {
  self.knowns[i]
}

///|
/// The first block whose foot is past `y`, as they go down (each foot no higher than the next one's); as many as there
/// are where none is. Its foot is where the next one's top is (the last one's, where all of them end), so it is found
/// going down the sums once, as Column::top goes down them for one top: at each sum, the top of the first block of its
/// right half (all over it, added in the same order, on the grid's number for its pixel) past `y` or not.
fn[K] Column::first_past(self : Column[K], y : Double) -> Int {
  let y = y - self.start
  let n = self.keys.length()
  let g = self.grid
  let on_grid = fn(t : Double) { if g > 0.0 { (t * g + 0.5).floor() / g } else { t } }
  if n == 0 || on_grid(self.sums[1]) <= y {
    return n
  }
  let mut acc = 0.0
  let mut node = 1
  let mut lo = 0
  let mut hi = self.cap
  while node < self.cap {
    let mid = (lo + hi) / 2
    let right = acc + self.sums[2 * node]
    if on_grid(right) > y {
      node = 2 * node
      hi = mid
    } else {
      acc = right
      node = 2 * node + 1
      lo = mid
    }
  }
  if lo < n { lo } else { n }
}

///|
/// A page's list's blocks where they are at a moment while some of them make their way in or out (View::scrolls_window):
/// the column as it is counted (Column: how it all ends), each top less what the ways over it have still to open (more,
/// where one closes), each block on its way as tall as its way has it then, all on the grid as flex lays them there.
/// What reads where a block is (what shows, the anchor, its foot, a block brought to its top) reads it here, the one
/// reading of it; with none on its way, the column as it is counted, to the bit.
priv struct Places[K] {
  col : Column[K]
  /// from which block on each way moves the tops, and how much less than counted it has them there
  froms : Array[Int]
  lefts : Array[Double]
  /// the blocks on their way in, each as tall as its way has it then
  own_at : Array[Int]
  own_h : Array[Double]
}

///|
/// What a list's places hold where none is on its way: shared, never added to.
let places_none_at : Array[Int] = []

///|
let places_none_h : Array[Double] = []

///|
/// How many of a page's list's last keys a change of its keys looks back over for the last that stays (the floor's,
/// list_sent_up_test): more taken at its foot at once than that, nothing held.
let floor_tail : Int = 8

///|
/// The column as it is counted: where its blocks are with none on its way, or once all of them are there.
fn[K] Places::counted(col : Column[K]) -> Places[K] {
  { col, froms: places_none_at, lefts: places_none_h, own_at: places_none_at, own_h: places_none_h }
}

///|
fn[K] Places::length(self : Places[K]) -> Int {
  self.col.length()
}

///|
fn[K] Places::key(self : Places[K], i : Int) -> K {
  self.col.key(i)
}

///|
fn[K] Places::known(self : Places[K], i : Int) -> Bool {
  self.col.known(i)
}

///|
/// Block `i`'s height: as its way has it, where it is on its way in; else as it is counted.
fn[K] Places::h(self : Places[K], i : Int) -> Double {
  for j, at in self.own_at {
    if at == i {
      return self.own_h[j]
    }
  }
  self.col.h(i)
}

///|
/// How much less than counted the ways over block `i` (or at it, one closing over it) have its top.
fn[K] Places::left_over(self : Places[K], i : Int) -> Double {
  let mut l = 0.0
  for j, f in self.froms {
    if f <= i {
      l = l + self.lefts[j]
    }
  }
  l
}

///|
/// Where block `i`'s top is: as it is counted, less what the ways over it have still to open, on the grid's own number
/// for its pixel where there is one, as flex puts a row's top.
fn[K] Places::top(self : Places[K], i : Int) -> Double {
  if self.froms.is_empty() {
    return self.col.top(i)
  }
  let l = self.left_over(i)
  if l == 0.0 {
    return self.col.top(i)
  }
  let t = self.col.top_summed(i) - l
  let g = self.col.grid
  if g > 0.0 {
    (t * g + 0.5).floor() / g
  } else {
    t
  }
}

///|
/// Where its blocks end, what is on its way at its foot with them.
fn[K] Places::foot(self : Places[K]) -> Double {
  let n = self.col.length()
  if self.froms.is_empty() {
    return if n == 0 { self.col.start } else { self.col.top(n - 1) + self.col.h(n - 1) }
  }
  let t = self.col.start + self.col.sums[1] - self.left_over(n)
  let g = self.col.grid
  if g > 0.0 {
    (t * g + 0.5).floor() / g
  } else {
    t
  }
}

///|
/// The first block whose foot is past `y`, as they go down; as many as there are where none is (Column::first_past).
fn[K] Places::first_past(self : Places[K], y : Double) -> Int {
  if self.froms.is_empty() {
    return self.col.first_past(y)
  }
  let mut lo = 0
  let mut hi = self.col.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.top(mid) + self.h(mid) > y {
      hi = mid
    } else {
      lo = mid + 1
    }
  }
  lo
}

///|
/// A ground a page's list draws under its blocks (View::scrolls_window's `bands`), one whole: from the top of block
/// `from` (`top` further down) to the foot of block `upto` (`foot` further down), its look its page's. What lights a
/// thing the list holds in several blocks (a long message a block a piece) is drawn once, never a piece of it by each
/// block: those, each placed on the host's pixels as its top is, meet only where their heights are on them too.
#derive(Eq)
pub(all) struct ListBand[K] {
  from : K
  upto : K
  top : Double
  foot : Double
}

///|
/// A page's list (`s`: Scroll::list, what it holds above moved with it as it grows: Scroll::grew_above) scrolling up and
/// down in it (View::scrolls, `slop` and `bar` as there) holding the
/// blocks `keys` names, in their order, one under another from its top, nothing else: each made by `make` in a node of
/// its own as it comes to show (its room, from the column's top to its foot, met by any of it), let go as it no more
/// does, as tall in the column meanwhile as it was last measured (`est` where it never was). What shows is made and
/// measured as the column is laid out, in that layout (its fill, below: made by what was measured, measured in turn,
/// none of it told after the layout). How tall each that does not show was is forgotten as the column is given another
/// width or all words are measured anew. `top_covered`: how tall what lies over its top is (View::scrolls'; its head is
/// none of it). `bar_clear`: the bar's ends kept clear (View::scrolls'). `head`: a place the
/// list holds over its keys' blocks in what scrolls, the page building into it (a chat's bar's room): never the anchor
/// nor a stand-in for it (what is read is held by the keys' blocks alone), its height, as the fill measures it in the
/// layout, where its keys start (Column's `start`: what shows by where they are, a block brought, near_top, all count
/// from there); grown or shrunk where what shows starts in it or at its very top, that stays where it is, else what is
/// read stays. `foot`: a place pinned at the foot of what shows, drawn over what scrolls (what scrolls shows behind
/// it, what is pressed on it its own), as wide as the list, the page building into it; as tall as it is laid out, the
/// fill measuring it, the room kept under the last block (nothing of the blocks: never made or let go as the column
/// scrolls), laid out as it changes wherever the column is. `holds`: whether a block holds what shows where it is as
/// what is over it changes (none that does not: the first after it that does; a head that stands over what comes in
/// under it, which goes on down with what shows). `follows`: while it says so, a column at its foot (made there, or
/// scrolled back to it) is kept there as what it holds grows, till it is moved off it (a chat's newest end).
/// `from_end`: its blocks, where they come short of what shows, at its foot, the room left over them (an old view's
/// list's `from_end`: a short chat's few messages at the foot, over the composer), what comes after them pushing up what
/// is over it; laid out so by its column alone, at least as tall as what shows, its blocks at its end, in the same
/// layout whether they come short of it, just fill it or go past it. A switch of its own, not what `follows` says
/// (the coordinator of the migration, 2026-11-12): `follows` is read again at every moment and may stop (an agent's
/// history stops following once an entry is gone to), and a short list would then be laid out anew from its top; and
/// tied to it, the two lists that follow their foot already (a job's output, that history) would come to sit at it,
/// which nobody decided. `place`:
/// what asks it to show a block or its foot at a cause (ListPlace: a block brought to the middle or to its top, back
/// to its foot, its foot followed no further than a block), done as it is next laid out; held there as what is over it
/// is laid out, till the column is moved otherwise (the hand, the wheel). `near_foot`: (screens,
/// wanting, ask): `ask` done as it is scrolled to within so many of its heights of its foot while `wanting()` holds, as
/// that comes to be, and again as its keys change while it is (a page more asked of what has more): how far its foot is
/// is its own, nothing laid out read by what asks. `near_top`: the same of its top (the page before asked of what has
/// more before it), how far that is by its anchor and its blocks' tops as its keys are now; at its foot however far
/// that comes to be (`follows`), only once all it holds shows (room left over it to fill): its newest is what is read
/// there, the page before wanted as the reader heads up. `reused`: of a block
/// whose key it gives a kind, what shows is made by `make_reused` with its key as it is now, and as it no more shows put
/// by, not let go: left in its slot out of sight, what it binds following nothing meanwhile (View::rests), so its going
/// draws nothing again; the next of its kind to come to show takes it (moved into that one's slot: View::park,
/// View::take_in), its key that one's then (what it binds read again for it, what changed set again): a list's rows of one make, as a RecyclerView's views, not made and let go each as
/// the list is scrolled.
///
/// What comes or goes because its keys changed (data, not a scroll) makes its way in or closes it down its column as
/// what an each makes or lets go does (View::comes: the column's one way at that moment, ComeGroup, from the change's
/// moment), its block measured in the layout that change asks for before its way is planned, so its way's end is known
/// from its start: at its foot what is over it goes up with it (where it is scrolled is how far what it holds reaches,
/// as it is laid out); scrolled off its foot, what is read stays where it is and what is under it moves. So only where it
/// is seen: a key put in over what is read, or out of sight, or one gone that showed not, is there or gone at once, as
/// is all of its first making, all of it with motion reduced, and what comes to show as it is scrolled. `comes`: asked
/// of a key that comes as it first appears among them (once, then, untracked): whether it comes (a message said just
/// now), else it is simply there (one caught up); one change may hold both. `goes`: asked of a key that showed as it
/// goes (once, then, untracked; a key no longer among them, so not one its data has still): whether it closes its way,
/// else it is simply gone. A list that says neither (`fn(_) { false }` both) is as it was before any came along its
/// way. `at_once`: its keys there and gone at once whatever `comes` and `goes` say, and what its blocks hold going its
/// own way down each block, as a column's, joined to nothing of the list's (below): a list as it was before either
/// (the lists the app ships, till each is switched on with before and after shown: detlint's list-comes-off).
/// What a block holds that comes or goes down a column in it (a show, a pick, an each) makes its way in the list's one
/// way, the group of its held column (Tree::come_group_join): a row come or gone at that moment, another block's
/// inside, all of it one way. So too what changes in a box of a said height in a block, which moves nothing of the
/// list: known and taken. Its counts are how it all ends; where a
/// block is while a way goes is read through Places alone, at the moment it is read (as it is laid out, where flex has
/// each way then), and what shows is made from where it showed as the way set out to where it ends, those that show
/// no more at its end let go then. `comes_way`: asked of a key that comes by data as it sets out (once, untracked): how
/// its way goes, that long (ms) on that curve (0 … 1 of the time to 0 … 1 of the way), where the page says it (one's own
/// words sent, their bubble flying in from the field on a flight's rise), else a Move. Said, the list's one way of that
/// moment goes so, all of it (what is over the key, what gives its room back under it), not a Move: one motion, the
/// key's (flex's ComeGroup `spec`; the coordinator of the migration, 2026-11-14). `foot_clear`: how tall the top of its
/// foot is that hides nothing of what shows (room it keeps under its last block the rows show through): what is pinned
/// over its foot and hides (Scroll::foot_hides_now, what a thing flying from the list is seen clear of) is the rest of it.
/// `reorders`: asked of a key that stays
/// among them as it moves among those that stay by data (once, then, untracked: the fewest that moved, the rest kept in
/// their order, in_order_most's): whether it closes its way where it was and opens it where it is now, in the column's
/// one way, as what comes and goes does (View::each_by's `splits`; the user, 2026-10-31: 「原地缩下去再从目标点挤出来更合
/// 理」), so only where it is seen as ever (not at once, nor an answer's, nor with motion reduced, nor as it is first
/// laid out); else it is simply where it is now (none: every list till it says so). Never what the layout comes to
/// otherwise (a width, the words' size): a key moved is a change of its keys alone. `bands`: grounds drawn under its
/// blocks, each from one block's top to another's foot as they are placed (ListBand), and what makes each one's look
/// in the node drawing it (its ground, the ways it is lit by, by its band as it is now): what is lit across several
/// blocks drawn once.
pub fn[K : Hash + Eq] View::scrolls_window(
  self : View,
  s : Scroll,
  keys : () -> Array[K],
  make : (View, K) -> Unit,
  est? : Double = 80.0,
  slop? : Double,
  bar? : ScrollBar,
  top_covered? : () -> Double = fn() { 0.0 },
  bar_clear? : () -> (Double, Double),
  holds? : (K) -> Bool = fn(_) { true },
  follows? : () -> Bool = fn() { false },
  from_end? : Bool = false,
  comes? : (K) -> Bool = fn(_) { true },
  goes? : (K) -> Bool = fn(_) { true },
  leaves_room? : (K) -> Bool = fn(_) { false },
  comes_whole? : (K) -> Bool = fn(_) { false },
  comes_way? : (K) -> (Double, (Double) -> Double)? = fn(_) { None },
  reorders? : (K) -> Bool = fn(_) { false },
  at_once? : Bool = false,
  flips? : Bool = false,
  place? : ListPlace[K],
  near_foot? : (Double, () -> Bool, () -> Unit),
  near_top? : (Double, () -> Bool, () -> Unit),
  reused? : (K) -> Int?,
  make_reused? : (View, () -> K) -> Unit,
  head? : (View) -> Unit,
  foot? : (View) -> Unit,
  foot_clear? : () -> Double = fn() { 0.0 },
  bands? : (() -> Array[ListBand[K]], (View, () -> ListBand[K]) -> Unit),
) -> View {
  guard self.live() is Some(_) else { return self }
  // (what asks it to show a block or its foot: the page's, else its own, which End asks its foot of at once,
  // scroll_keys.mbt; its keys' numbers its own, so a key asked of it before it is among the keys is the same one)
  let place = place.unwrap_or(ListPlace::new())
  let ids = place.ids
  let k = fn(i : Int) { ids.key(i) }
  let band_ids = fn(b : ListBand[K]) -> ListBand[Int] {
    { from: ids.id(b.from), upto: ids.id(b.upto), top: b.top, foot: b.foot }
  }
  let band_keys = fn(b : ListBand[Int]) -> ListBand[K] {
    { from: k(b.from), upto: k(b.upto), top: b.top, foot: b.foot }
  }
  self.scrolls_window_ids(
    s,
    fn() { ids.all(keys()) },
    fn(v, i) { make(v, k(i)) },
    est~,
    slop?=slop,
    bar?=bar,
    top_covered~,
    bar_clear?=bar_clear,
    holds=fn(i) { holds(k(i)) },
    follows~,
    from_end~,
    comes=fn(i) { comes(k(i)) },
    goes=fn(i) { goes(k(i)) },
    leaves_room=fn(i) { leaves_room(k(i)) },
    comes_whole=fn(i) { comes_whole(k(i)) },
    comes_way=fn(i) { comes_way(k(i)) },
    reorders=fn(i) { reorders(k(i)) },
    at_once~,
    flips~,
    place=place.at,
    near_foot?=near_foot,
    near_top?=near_top,
    reused?=reused.map(fn(f) { fn(i) { f(k(i)) } }),
    make_reused?=make_reused.map(fn(f) { fn(v, i : () -> Int) { f(v, fn() { k(i()) }) } }),
    head?=head,
    foot?=foot,
    foot_clear~,
    bands?=bands.map(fn(b) {
      let (all, look) = b
      (fn() { all().map(band_ids) }, fn(v, band : () -> ListBand[Int]) { look(v, fn() { band_keys(band()) }) })
    }),
  )
}

///|
/// View::scrolls_window whose blocks are taken again as they leave what shows (its `reused`), said by one make:
/// `make` makes a block in its node with what says its key as it is now, the one key it is made for or, taken for
/// another, that one's from then (its parts read it through `key()` where they are bound, a press as it runs: what reads
/// it untracked as it is made keeps the key it was first made for, all but which make it is, its `shape`, which never
/// changes for a block). Every block is of
/// one kind (`shape`: what it gives a key, `0` for all of them), taken only by a block of its kind; a key `reuses` says
/// not (a head, words for none: what is made once) is made by `make` as well, given its key alone, and let go as it no
/// more shows. So a list's rows are the same make put by and taken, never made and let go as the list is scrolled, and
/// a page writes no second make for it. The rest is View::scrolls_window's. Over View::scrolls_window_ids as that is,
/// so compiled once whatever its keys.
pub fn[K : Hash + Eq] View::scrolls_reused(
  self : View,
  s : Scroll,
  keys : () -> Array[K],
  make : (View, () -> K) -> Unit,
  shape? : (K) -> Int = fn(_) { 0 },
  reuses? : (K) -> Bool = fn(_) { true },
  est? : Double = 80.0,
  slop? : Double,
  bar? : ScrollBar,
  top_covered? : () -> Double = fn() { 0.0 },
  bar_clear? : () -> (Double, Double),
  holds? : (K) -> Bool = fn(_) { true },
  follows? : () -> Bool = fn() { false },
  from_end? : Bool = false,
  comes? : (K) -> Bool = fn(_) { true },
  goes? : (K) -> Bool = fn(_) { true },
  leaves_room? : (K) -> Bool = fn(_) { false },
  comes_whole? : (K) -> Bool = fn(_) { false },
  comes_way? : (K) -> (Double, (Double) -> Double)? = fn(_) { None },
  reorders? : (K) -> Bool = fn(_) { false },
  at_once? : Bool = false,
  flips? : Bool = false,
  place? : ListPlace[K],
  near_foot? : (Double, () -> Bool, () -> Unit),
  near_top? : (Double, () -> Bool, () -> Unit),
  head? : (View) -> Unit,
  foot? : (View) -> Unit,
  foot_clear? : () -> Double = fn() { 0.0 },
  bands? : (() -> Array[ListBand[K]], (View, () -> ListBand[K]) -> Unit),
) -> View {
  guard self.live() is Some(_) else { return self }
  let place = place.unwrap_or(ListPlace::new())
  let ids = place.ids
  let k = fn(i : Int) { ids.key(i) }
  let band_ids = fn(b : ListBand[K]) -> ListBand[Int] {
    { from: ids.id(b.from), upto: ids.id(b.upto), top: b.top, foot: b.foot }
  }
  let band_keys = fn(b : ListBand[Int]) -> ListBand[K] {
    { from: k(b.from), upto: k(b.upto), top: b.top, foot: b.foot }
  }
  self.scrolls_window_ids(
    s,
    fn() { ids.all(keys()) },
    // (a key made once, not taken: its key alone)
    fn(v, i) {
      let key = k(i)
      make(v, fn() { key })
    },
    est~,
    slop?=slop,
    bar?=bar,
    top_covered~,
    bar_clear?=bar_clear,
    holds=fn(i) { holds(k(i)) },
    follows~,
    from_end~,
    comes=fn(i) { comes(k(i)) },
    goes=fn(i) { goes(k(i)) },
    leaves_room=fn(i) { leaves_room(k(i)) },
    comes_whole=fn(i) { comes_whole(k(i)) },
    comes_way=fn(i) { comes_way(k(i)) },
    reorders=fn(i) { reorders(k(i)) },
    at_once~,
    flips~,
    place=place.at,
    near_foot?=near_foot,
    near_top?=near_top,
    reused=fn(i) {
      let key = k(i)
      if reuses(key) {
        Some(shape(key))
      } else {
        None
      }
    },
    make_reused=fn(v, i) { make(v, fn() { k(i()) }) },
    head?=head,
    foot?=foot,
    foot_clear~,
    bands?=bands.map(fn(b) {
      let (all, look) = b
      (fn() { all().map(band_ids) }, fn(v, band : () -> ListBand[Int]) { look(v, fn() { band_keys(band()) }) })
    }),
  )
}

///|
/// View::scrolls_window's work, of its keys by their numbers (ListKeys): compiled once, not once for every type of key
/// a page's list holds (11 of it were 26 MB of a program's C).
fn View::scrolls_window_ids(
  self : View,
  s : Scroll,
  keys : () -> Array[Int],
  make : (View, Int) -> Unit,
  est~ : Double,
  slop? : Double,
  bar? : ScrollBar,
  top_covered~ : () -> Double,
  bar_clear? : () -> (Double, Double),
  holds~ : (Int) -> Bool,
  follows~ : () -> Bool,
  from_end~ : Bool,
  comes~ : (Int) -> Bool,
  goes~ : (Int) -> Bool,
  leaves_room~ : (Int) -> Bool,
  comes_whole~ : (Int) -> Bool,
  comes_way~ : (Int) -> (Double, (Double) -> Double)?,
  reorders~ : (Int) -> Bool,
  at_once~ : Bool,
  flips~ : Bool,
  place~ : PlaceAt,
  near_foot? : (Double, () -> Bool, () -> Unit),
  near_top? : (Double, () -> Bool, () -> Unit),
  reused? : (Int) -> Int?,
  make_reused? : (View, () -> Int) -> Unit,
  head? : (View) -> Unit,
  foot? : (View) -> Unit,
  foot_clear~ : () -> Double,
  bands? : (() -> Array[ListBand[Int]], (View, () -> ListBand[Int]) -> Unit),
) -> View {
  guard self.live() is Some(_) else { return self }
  // (its head and its foot, once made, and how tall the foot is as its fill last measured it: the room kept under its
  // last block)
  let head_v : Ref[View?] = Ref(None)
  // (how tall the head is laid out: what the page builds in it measured, on its host's pixels where it sets a page's
  // list's rows on them (rows_slot_on, as a block's slot is), the one reading of where its keys start: so every top,
  // the foot and first_past, each counting from it and on the grid by it, round alike, and the first row's top meets
  // the head's foot)
  let head_tall : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
  let foot_v : Ref[View?] = Ref(None)
  let foot_h : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
  let room_under = fn() { foot_h.get() }
  // (what asks it to show a block or its foot: the page's, else its own, which End asks its foot of at once,
  // scroll_keys.mbt)
  let place = Some(place)
  // (its keys worked out once as what they read changes, not again as a block's height is told: what reads them, the
  // blocks' tops and the blocks made, reads these)
  // (a key its page says goes leaving its room (`leaves_room`, asked once as it goes), the last among them as it goes
  // and the list at its foot: kept among the keys it lays out while what it showed fades out where it is, its slot as
  // tall as it is, its way in going on to its end (`fading`: the key, the moment it went); then let go at once, the
  // room under the last block taking its height in that change (foot_room). One that comes at its foot meanwhile ends
  // it at once, in its place from then, the key let go at once with its room left (`gone_quiet`: whether that room is
  // counted already), never both seen; the key back, its fade undone. `fade_go`, `fade_undo`: what sets its fade on
  // its block, or takes it off, once the change is told)
  // (what is sent takes it up only (list_sent_up_test): at its foot, a key come at its foot by a change, the stretch
  // from the top of the last key there before that stays to the column's end never shorter than it was at that change's
  // moment while that change's ways go, the room under the last block what keeps it so, never less than none; then the
  // room as it came to, going as it is scrolled off. What it counts as given back: the room there, the pinned foot's
  // shrink, a part closing in that key or under it, a key said to leave its room; what changes over that key's top is
  // not its (it moves that key as ever). Never a key its page lets go, not said to leave its room, gone at or under that
  // key (making its way, or at once: `goes` false, an `at_once` list): such a change is as ever, whole, not armed by it
  // and ending one armed (what is over it comes back with it, list_rows_come_test's, list_blocks_way_test's). Where no
  // key stays, nothing is held.
  // `floor`: that key and how long the stretch was then, armed; `laid_whole`, `laid_last`: how tall the column was as
  // its fill last left it and where its blocks were then; `laid_stretch`: the stretch held as that fill left it;
  // `floor_arm`: armed by the change that brings such a key, again from the column as it shows by a second while armed;
  // `floor_end`: ended, by such a change or by the hand taking it off its foot. A key said to leave its room going while
  // armed raises it to the stretch as it shows (its room counted). What is pressed and held holds the room itself
  // meanwhile, the floor armed under it as it was)
  let floor : Ref[(Int, Double)?] = Ref(None)
  let laid_whole = Ref(0.0)
  let laid_last : Ref[Places[Int]?] = Ref(None)
  let laid_stretch = Ref(0.0)
  let floor_arm : Ref[(Int, Double) -> Unit] = Ref(fn(_, _) {  })
  let floor_end : Ref[() -> Unit] = Ref(fn() {  })
  // (a key come at its end as one move (list_send_one_move_test): in the change by which a key comes at the end (by
  // data), it sets out from as tall as all that change gives back under the top of the last key that stays (L): the
  // floor's stretch, as the last fill before the change left it, less L as it is laid out in that change (what of it a
  // row closes at once there, `show(at_once=true)`, is given back so) and the foot as it shows; never taller than
  // itself, and only ever raised from where it set out (the room alone, take_room's), so where nothing is given back it
  // is as ever. Not where a key the page lets go is gone at or under L (that change is as ever). Two or more come
  // there in one change take what it gives back in their order, each up to its own height, and stay the one way they
  // were said in. Keys that stay under those come are no matter: the stretch is from L's top to the column's end all the
  // same, what stays under them as tall as it is (the coordinator of the migration, 2026-11-14). `one_move_key`: L, the
  // keys come after it, those that stay under them, the change's moment, till the fill that measures them;
  // `came_row`: their rows, noted only while they are named)
  let one_move_key : Ref[(Int, Array[Int], Array[Int], Double)?] = Ref(None)
  // (a bridge while an old view is hosted in its foot (the chat's composer, laid out only as the old frame is built):
  // the builds of the old views begun as `one_move_key` was armed, and whether what waited for one done is let go;
  // a set-out is worked out from what that change gives back only once an old view under its foot is built since
  // its cause, at the cause's moment still, never from that foot's size before it: one motion, the composer's closing
  // the list's rise. It goes once no old view is hosted in a list's foot (the composer made as nodes; the
  // coordinator of the migration, 2026-11-14))
  let one_move_builds = Ref(0)
  let one_move_free = Ref(false)
  // (and the stretch as the fill at the cause left it, the floor's then: what that change gives back is counted
  // against it, never against the stretch a later fill holds, which counts the key's own way since)
  let one_move_e0 : Ref[Double?] = Ref(None)
  let came_row : Map[Int, View] = Map([])
  let floor_raise = fn() {
    if floor.val is Some((k, e)) {
      floor.val = Some((k, dmax(e, laid_stretch.val)))
    }
  }
  let fading : Ref[(Int, Double)?] = Ref(None)
  let fade_rev : @signals.Signal[Int] = @signals.signal(0)
  let fade_go : Ref[(Int) -> Unit] = Ref(fn(_) {  })
  let fade_undo : Ref[(Int) -> Unit] = Ref(fn(_) {  })
  let gone_quiet : Map[Int, Bool] = Map([])
  let page_was : Ref[Array[Int]] = Ref([])
  let keyed = @signals.computed(fn(_) {
    fade_rev.get() |> ignore
    let ks = keys()
    let was = page_was.val
    page_was.val = ks
    guard !physical_equal(ks, was) || fading.val is Some(_) else { return ks }
    // (one come at its foot: not among them before; asked only of one fading or gone leaving its room)
    let came_at_foot = fn() {
      ks.length() > 0 && !physical_equal(ks, was) && !was.contains(ks[ks.length() - 1])
    }
    match fading.val {
      Some((k, _)) if ks.contains(k) => {
        fading.val = None
        @signals.after_flush(fn() { (fade_undo.val)(k) })
      }
      Some((k, _)) if came_at_foot() => {
        fading.val = None
        gone_quiet[k] = false
      }
      _ => ()
    }
    // (the last gone, said to leave its room, at its foot, as laid out once: fading, or gone at once where one came in
    // its place)
    if fading.val is None && !at_once && !flips && was.length() > 0 && !physical_equal(ks, was) {
      let k = was[was.length() - 1]
      if @signals.untracked(fn() { s.seen.get() is Some(_) && s.at_foot() && leaves_room(k) }) && !ks.contains(k) {
        // (one come in its place, or motion reduced: gone at once, its room left)
        if came_at_foot() || @signals.untracked(self.tree.motion_reduced) {
          gone_quiet[k] = false
        } else {
          fading.val = Some((k, self.tree.cause_now()))
          @signals.after_flush(fn() { (fade_go.val)(k) })
        }
      }
    }
    match fading.val {
      Some((k, _)) => {
        let all = ks.copy()
        all.push(k)
        all
      }
      None => ks
    }
  })
  let keys = fn() { keyed.get() }
  // (how tall each was laid out while it showed, by its key, told as each is laid out (`told` counting each change of
  // it); forgotten as the column is laid out at another width, or as all words are measured anew (the system's size of
  // words, how the theme shapes them: Tree::words_again))
  let heights : Map[Int, Double] = Map([])
  // (those whose height changed or was forgotten since their tops were last worked out: those alone looked up again
  // then, not every key hashed each time one is told)
  let heights_changed : Array[Int] = []
  let told : @signals.Signal[Int] = @signals.signal(0)
  let tell = fn() { told.set(told.untracked() + 1) }
  // (the same, each block's own, by its key, while it is made: what its height reads, not all of them read again as
  // one is told, n for each told)
  let tall : Map[Int, @signals.Signal[Double?]] = Map([])
  // (those that show now: laid out again as they are, each told anew where it comes out otherwise; the rest forgotten)
  let showing : Map[Int, Bool] = Map([])
  // (the blocks made, each with its key as it is now: what is measured as the column is laid out)
  let blocks : Array[(View, () -> Int)] = []
  // (key `k` shows no more, the block at `at` that showed it let go or put by: unless another shows it (a key moved
  // among them, its row split: the one closing where it was let go as the one opening where it is now shows it))
  let unshow = fn(k : Int, at : Int) {
    if !blocks.iter().any(fn(b) { b.0.at != at && b.0.alive() && @signals.untracked(b.1) == k }) {
      showing.remove(k)
    }
  }
  // (where what is read in each block starts, as its page marks it (View::read_from): the node, by the block's own
  // node, let go with it; none in a block that marks none, a list none of whose blocks marks one held as ever)
  let marks : Map[Int, View] = Map([])
  s.read_from_said = fn(v) {
    let mut i = v.at
    while i >= 0 && i != self.at {
      for b in blocks {
        if b.0.at == i && b.0.alive() {
          let block_at = i
          let mark_at = v.at
          marks[block_at] = v
          v.owns(fn() {
            if marks.get(block_at) is Some(m) && m.at == mark_at {
              marks.remove(block_at)
            }
          })
          |> ignore
          return
        }
      }
      i = self.tree.nodes[i].parent
    }
  }
  // (what each block holds of what a go-to brings, as its page marks it (View::sought): each node saying so and its
  // piece, in the order they were made, by the block's own node, each let go with its node)
  let sought : Map[Int, Array[(View, () -> ((Double, Double) -> (Double, Double, Double, Double)?)?)]] = Map([])
  s.sought_said = fn(v, piece) {
    let mut i = v.at
    while i >= 0 && i != self.at {
      for b in blocks {
        if b.0.at == i && b.0.alive() {
          let block_at = i
          let mark_at = v.at
          match sought.get(block_at) {
            Some(xs) => xs.push((v, piece))
            None => sought[block_at] = [(v, piece)]
          }
          v.owns(fn() {
            match sought.get(block_at) {
              Some(xs) => {
                let left = xs.filter(fn(x) { x.0.at != mark_at })
                if left.is_empty() {
                  sought.remove(block_at)
                } else {
                  sought[block_at] = left
                }
              }
              None => ()
            }
          })
          |> ignore
          return
        }
      }
      i = self.tree.nodes[i].parent
    }
  }
  // (those of a kind another may take put by as they no more show (`reused`), each with what says its key now, what
  // wakes what it binds (View::rests) and the slot it is still in, none once that slot left what has slots or had its
  // measured height forgotten and it was taken out of it, held by no node (View::park): so many at most of each, the
  // rest let go; all let go with the list)
  let spare : Map[Int, Array[(View, @signals.Signal[Int], () -> Unit, View?)]] = Map([])
  // (what the parts of those blocks keep of each key, kept by it as a block leaves it and given back as a block is
  // taken for it or made anew for it: reused_state.mbt)
  let kept : ReusedKept[Int] = ReusedKept::new()
  let kept_keys = fn() { kept.length() }
  // (block `v` leaving key `k` (put by, let go, or taken for another): what its parts keep now kept by `k`)
  let keep_from = fn(v : View, k : Int) {
    guard v.alive() && self.tree.reused_slots.get(v.at) is Some(rs) else { return }
    let (xs, bools) = rs.taken(self.tree, v.at)
    kept.keep(k, xs, bools)
  }
  // (block `v` taken for another key, `was` the one it leaves, `k` the one it comes to (View::scrolls_window's
  // `reused`): what its parts kept of `was` kept, what they kept of `k` given back, each at once (answering.mbt), as
  // were it made anew for `k`; `wake` waking what it binds, `key` saying its key)
  let taken_for = fn(v : View, was : Int, k : Int, wake : () -> Unit, key : @signals.Signal[Int]) {
    guard was != k && v.alive() && self.tree.reused_slots.get(v.at) is Some(rs) else {
      answering(within=v, fn() {
        wake()
        key.set(k)
      })
      return
    }
    // (what its parts kept of `was` kept as it left `was`, put by: nothing of it changes out of sight; kept again here it
    // would bring back a key let go of since, past those kept last)
    rs.kept_x = fn(path) { kept.x_of(k, path) }
    rs.kept_bool = fn(path) { kept.bool_of(k, path) }
    answering(within=v, fn() {
      rs.told_reused()
      wake()
      key.set(k)
    })
    // (its switches then, what they make or let go settled at once as well, where each is in the block as it is now)
    answering(within=v, fn() { rs.put_bools(self.tree, v.at) })
    rs.put_scrolls(self.tree, v.at)
  }
  let spare_let_go = fn() {
    for _, all in spare {
      for b in all {
        b.0.let_go()
      }
      all.clear()
    }
  }
  // (how wide what it holds is given to be, as it is laid out: View::scrolls' fill)
  let room_w : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })
  self.reacts(fn() { (room_w.get(), self.words_redone()) }, fn(_) {
    let gone = heights.keys().filter(fn(k) { !showing.contains(k) }).collect()
    if gone.length() > 0 {
      for k in gone {
        heights.remove(k)
        heights_changed.push(k)
        if tall.get(k) is Some(c) {
          c.set(None)
        }
      }
      // (a block put by in a slot whose height is forgotten: taken out of it so a taller block cannot overflow est)
      for _, those in spare {
        for i, sp in those {
          match sp {
            (v, key, wake, Some(was_in)) => {
              let k = key.untracked()
              if !showing.contains(k) && !heights.contains(k) && v.alive() {
                was_in.park(v, rest=false) |> ignore
                those[i] = (v, key, wake, None)
              }
            }
            _ => ()
          }
        }
      }
      tell()
    }
  })
  // (each block's top in the column and its height, in order: as tall as it was measured, else est)
  // (the keys they were worked out for and where each is among them; what they come to, counted (Column): made again as
  // the keys change, else only those whose height changed since told it)
  let laid_keys : Ref[Array[Int]] = Ref([])
  let laid_at : Map[Int, Int] = Map([])
  // (each key's number, given as it is first asked (words picked in its row: View::row_place), kept while the list
  // lives: what its row is known by, whichever node it is made in (Tree's rows_named); a key come back the same row)
  let row_numbers : Map[Int, Int] = Map([])
  let row_numbered = Ref(0)
  let number_of = fn(k : Int) {
    match row_numbers.get(k) {
      Some(n) => n
      None => {
        row_numbered.val = row_numbered.val + 1
        row_numbers[k] = row_numbered.val
        row_numbered.val
      }
    }
  }
  let height_of = fn(k : Int) {
    match heights.get(k) {
      Some(h) => (h, true)
      None => (est, false)
    }
  }
  let column : Column[Int] = Column::new()
  // (where its first block's top is now, under its head: for what judges its rows, lists_seen.mbt)
  s.keys_start = fn() { column.start }
  // (the anchor taken again where the column is scrolled to now, by its blocks as they are counted before its keys
  // change: anchor_again, below)
  let anchor_again : Ref[(Column[Int]) -> Unit] = Ref(fn(_) {  })
  // (each that shows, where it is among them, and how far under the top of what shows its top is, by its blocks as they
  // are counted before its keys change: seen_before, below)
  let seen_before : Ref[(Column[Int]) -> Array[(Int, Int, Double)]] = Ref(fn(_) { [] })
  // (the keys come among them by the last change of its keys (not moved among them) that its page says come, and those
  // gone that showed then that it says go, each as far under the top of what showed as it was and the key it stood
  // over (none: at their foot): what of them comes or goes making its way, way_of below; told the fill, forgotten)
  // (each its own map, made anew where it held any: one let go of, not cleared, so what a first making of 1,500 grew
  // is not walked again at every fill)
  let came_by_data : Ref[Map[Int, Bool]] = Ref(Map([]))
  // (`flips`: the keys come by data its page says come, since its way was last worked out: only a change that brings one
  // sets a way out, the rest (caught up, an answer's) there at once as they are)
  let flip_came : Map[Int, Bool] = Map([])
  // (a way made anew at each change, none like another: each said is told, none compared)
  let flip_way : @signals.Signal[@flex.FlipWay?] = @signals.signal_by(None, same=fn(_, _) { false })
  // (`flips`: how far what each change set out has gone, by the change's moment, as long as it goes: its end, and its
  // share gone at each moment, 0 at the change, 1 at that end. What was set out at a change (a pick leaving in a block:
  // Tree's flip_gone) goes on its own way to its end, never on the way of a later change that set out another, nor set
  // out again by it; told as flip_way is)
  let flip_ways : Map[Double, (Double, (Double) -> Double)] = Map([])
  let flip_gone_said = fn(at : Double, ends : Double, gone : (Double) -> Double) {
    let over = flip_ways.iter().filter(fn(e) { e.0 != at && e.1.0 <= at }).map(fn(e) { e.0 }).to_array()
    for t in over {
      flip_ways.remove(t)
    }
    flip_ways[at] = (ends, gone)
  }
  // (the way the change at `at` set out, `w`: the list's, and that change's own, from what of it is left at `at` (one
  // set out before it, a flight's still going, gone on as that change's from none of it gone); never over sooner than
  // the least of a Move's time from `at`, as a change that moves nothing goes (below): one come at the tail of a way
  // nearly over (刚刚 as the words sent land) not drawn whole within a frame or two of none of it)
  let flip_way_said = fn(at : Double, w : @flex.FlipWay) {
    let k0 = w.left(at).0
    let least = @flex.move_least_ms
    flip_gone_said(at, dmax(w.ends(), at + least), fn(t) {
      let on_way = if k0 <= 1.0e-6 { 1.0 } else { 1.0 - w.left(t).0 / k0 }
      let u = dmax(0.0, dmin(1.0, (t - at) / least))
      let least_way = 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u)
      dmax(0.0, dmin(1.0, dmin(on_way, least_way)))
    })
    flip_way.set(Some(w))
  }
  // (`flips`: what each block made at rest binds to its way, bound once a way first sets out, all of them then, by the
  // list's one watch of it, not one of each block's: by the order they were made, each let go with its block)
  let flip_unbound : Map[Int, () -> Unit] = Map([])
  let flip_unbound_next = Ref(0)
  if flips {
    self.reacts(fn() { flip_way.get() is Some(_) }, fn(going) {
      if going && !flip_unbound.is_empty() {
        let all = flip_unbound.copy()
        flip_unbound.clear()
        for _, bind in all {
          bind()
        }
      }
    })
  }
  let flip_items : Map[Int, @flex.FlipItem] = Map([])
  let flip_new : Map[Int, Bool] = Map([])
  let gone_from : Ref[Map[Int, (Double, Int?)]] = Ref(Map([]))
  // (the keys that stay moved among them by the last change of its keys that its page says reorder (`reorders`): each
  // in came_by_data too, and where it showed in gone_from, its row split as the each takes the change (each_by's
  // `splits`, each asked once), till the fill that lays it out forgets them)
  let moved_now : Ref[Map[Int, Bool]] = Ref(Map([]))
  // (the anchor, where it is one of those moved, put on the first of its stand-ins that did not move: anchor_moved,
  // below)
  let anchor_moved : Ref[(Map[Int, Bool]) -> Unit] = Ref(fn(_) {  })
  let laid_grid = Ref(-1.0)
  // (how many times they were worked out: what shows by them worked out again each time)
  let laid_rev = Ref(0)
  let laid = @signals.computed_by(fn(_) {
    laid_rev.val = laid_rev.val + 1
    told.get() |> ignore
    let ks = keys()
    // (as tall as each is laid out in the column: on its host's pixels where it sets a page's list's rows on them,
    // Tree::rows_slot)
    let g = self.tree.rows_grid_now()
    if physical_equal(ks, laid_keys.val) && g == laid_grid.val && column.length() == ks.length() {
      for k in heights_changed {
        match laid_at.get(k) {
          Some(i) => {
            let (h, known) = height_of(k)
            column.set(i, rows_slot_on(h, g), known)
          }
          None => ()
        }
      }
    } else {
      // (where what shows is held from, taken first by the blocks as they were counted till now: what comes in is put
      // in round it)
      (anchor_again.val)(column)
      // (where each that showed was as it was read till now, against the top of what showed, and where it was among
      // them: what of them goes closes its way only where it showed, under what was read)
      let showed_at = if at_once { [] } else { (seen_before.val)(column) }
      laid_keys.val = ks
      // (kept as it was up to the first key that is another: from there its keys found and their heights put again; the
      // heights told of those kept told as ever)
      let was = column.keys
      // (where the last keys there before were as its fill last left them (a few, from its end): what the floor holds from)
      let tail_tops : Array[(Int, Double)] = []
      match laid_last.val {
        Some(lp) if physical_equal(lp.col, column) && lp.length() == was.length() => {
          let mut j = was.length() - 1
          while j >= 0 && was.length() - j <= floor_tail {
            tail_tops.push((j, lp.top(j)))
            j = j - 1
          }
        }
        _ => ()
      }
      let p = column.refill(ks, g)
      // (its keys changed by data, one of them another or as many no more: what its bar's thumb shows changes with them,
      // in the frame that takes them; the same keys given again as another array are no change)
      if keys_other(was, ks, p) {
        s.keys_changed()
      }
      let laid_once = @signals.untracked(fn() { s.seen.get() is Some(_) })
      if came_by_data.val.length() > 0 {
        came_by_data.val = Map([])
      }
      for i in p..<ks.length() {
        let k = ks[i]
        // (come by this change: not among them before (one moved among them still is, at where it was); its page asked
        // once, now, whether it comes. Not before it was first laid out: what it is made with is there at once)
        if laid_once && !at_once && !laid_at.contains(k) && @signals.untracked(fn() { comes(k) }) {
          if !flips {
            came_by_data.val[k] = true
          } else if !answering_now() {
            flip_came[k] = true
          }
        }
        laid_at[k] = i
        let (h, known) = height_of(k)
        column.put(i, rows_slot_on(h, g), known)
      }
      // (those that were from there on and are no more where they were: gone, unless put again elsewhere just now)
      for i in p..<was.length() {
        let k = was[i]
        if laid_at.get(k) == Some(i) && !(i < ks.length() && ks[i] == k) {
          laid_at.remove(k)
        }
      }
      column.summed()
      // (those that stay and moved among them, the fewest (the rest kept in their order), its page saying they reorder:
      // come by this change where they are, gone where they were, each its row split, as it is seen)
      if moved_now.val.length() > 0 {
        moved_now.val = Map([])
      }
      if laid_once &&
        !at_once &&
        p < was.length() &&
        p < ks.length() &&
        !answering_now() &&
        !self.tree.answer_holds(self.at) &&
        !@signals.untracked(self.tree.motion_reduced) {
        let was_index : Map[Int, Int] = Map([])
        for j in p..<was.length() {
          was_index[was[j]] = j
        }
        let stay : Array[Int] = []
        let stay_was : Array[Int] = []
        for i in p..<ks.length() {
          match was_index.get(ks[i]) {
            Some(j) => {
              stay.push(ks[i])
              stay_was.push(j)
            }
            None => ()
          }
        }
        let kept = in_order_most(stay_was)
        for n, k in stay {
          if !kept[n] && @signals.untracked(fn() { reorders(k) }) {
            moved_now.val[k] = true
            came_by_data.val[k] = true
          }
        }
        if moved_now.val.length() > 0 {
          (anchor_moved.val)(moved_now.val)
        }
      }
      // (those that showed and are gone, each over the first after it still among them (none: at their foot), as far
      // under the top of what showed as it was; those moved, over the first after it that stays where it was)
      if gone_from.val.length() > 0 {
        gone_from.val = Map([])
      }
      for e in showed_at {
        let (k, j, off) = e
        guard moved_now.val.contains(k) else { continue }
        let mut b = j + 1
        while b < was.length() && (!laid_at.contains(was[b]) || moved_now.val.contains(was[b])) {
          b = b + 1
        }
        gone_from.val[k] = (off, if b < was.length() { Some(was[b]) } else { None })
      }
      for e in showed_at {
        let (k, j, off) = e
        guard !at_once &&
          !laid_at.contains(k) &&
          !gone_quiet.contains(k) &&
          @signals.untracked(fn() { goes(k) }) else {
          continue
        }
        let mut b = j + 1
        while b < was.length() && !laid_at.contains(was[b]) {
          b = b + 1
        }
        gone_from.val[k] = (off, if b < was.length() { Some(was[b]) } else { None })
      }
      // (one come at its foot by this change, seen, at its foot: the stretch from the last key there before that stays held
      // as long as it was; not where a key its page lets go, not said to leave its room, is gone at or under that one,
      // which ends one armed)
      // (one come at its end by this change: noted for the fill that measures it)
      came_row.clear()
      one_move_key.val = None
      // (a key come before keys that stay under it is at the foot for the one reading (the coordinator of the
      // migration, 2026-11-14): the last run of keys come by this change, every key after it among them before and
      // staying, as many as floor_tail at most; L the last that stays before that run, walked back in `was` past the
      // staying keys under it and those gone, none of those gone a key the page lets go unmarked (`let_go`): the run's
      // bounds in `ks`, L's place in `was`, whether one is let go. Keys come elsewhere in the change are as ever)
      let came_at_foot : (Int, Int, Int, Bool)? = if ks.length() > 0 {
        let mut e = ks.length()
        while e > 0 && ks.length() - e < floor_tail && !came_by_data.val.contains(ks[e - 1]) {
          e = e - 1
        }
        if e > 0 && came_by_data.val.contains(ks[e - 1]) {
          let mut c = e - 1
          while c > 0 && came_by_data.val.contains(ks[c - 1]) {
            c = c - 1
          }
          let mut j = was.length() - 1
          let mut t = ks.length() - 1
          let mut let_go = false
          let mut ok = true
          while j >= 0 {
            let k = was[j]
            if !laid_at.contains(k) {
              if !@signals.untracked(fn() { leaves_room(k) }) {
                let_go = true
              }
              j = j - 1
            } else if t >= e {
              // (the staying keys under the run, in their order)
              if k == ks[t] {
                t = t - 1
                j = j - 1
              } else {
                ok = false
                break
              }
            } else {
              break
            }
          }
          if ok && t < e && j >= 0 {
            Some((c, e, j, let_go))
          } else {
            None
          }
        } else {
          None
        }
      } else {
        None
      }
      match came_at_foot {
        Some((c, e, j, false)) => {
          // (the keys come after L, in their order, and those that stay under them)
          one_move_key.val = Some((was[j], ks[c:e].to_owned(), ks[e:].to_owned(), self.tree.cause_now()))
          one_move_builds.val = self.tree.old_builds_begun
          one_move_free.val = false
          one_move_e0.val = None
        }
        _ => ()
      }
      if @signals.untracked(fn() { s.at_foot() }) {
        let mut j = was.length() - 1
        let mut let_go = false
        while j >= 0 && !laid_at.contains(was[j]) {
          if !@signals.untracked(fn() { leaves_room(was[j]) }) {
            let_go = true
          }
          j = j - 1
        }
        // (an unmarked key gone at the foot ends it, as ever; one gone under L, among the keys that stay under the run,
        // too)
        match came_at_foot {
          _ if let_go => (floor_end.val)()
          Some((_, _, _, true)) => (floor_end.val)()
          Some((_, _, l, false)) =>
            match tail_tops.search_by(fn(t) { t.0 == l }) {
              Some(i) => (floor_arm.val)(was[l], laid_whole.val - tail_tops[i].1)
              None => ()
            }
          None => ()
        }
      }
      for k in heights_changed {
        match laid_at.get(k) {
          Some(i) if i < p => {
            let (h, known) = height_of(k)
            column.set(i, rows_slot_on(h, g), known)
          }
          _ => ()
        }
      }
    }
    laid_grid.val = g
    heights_changed.clear()
    column
  }, same=fn(_, _) { false })
  // (the rows made or let go by a change of its keys that make their way in or out (View::scrolls_window's way_of),
  // each with its key and, going, the key it stands over among them (none: at their foot), till the end its way
  // declares (ways_due, below); and what ends that wait)
  let ways : Array[(View, Int, Int?)] = []
  let ways_off : Ref[() -> Unit] = Ref(fn() {  })
  // (the blocks of keys said to come whole (`comes_whole`) on their way at its foot, by their nodes: drawn as at rest,
  // not cut to their room, over the rest of the list (Tree::raise_in_list, the paint's), every one on its way, in the
  // list's order (the coordinator of the migration, 2026-11-14: two sent close together, the first still goes); none
  // once their ways end)
  let whole_rows : Array[View] = []
  let whole_raised = fn() {
    let alive = whole_rows.filter(fn(r) { r.alive() && ways.iter().any(fn(w) { w.0.at == r.at && w.0.id() == r.id() }) })
    whole_rows.clear()
    whole_rows.append(alive)
    self.tree.raise_in_list(self.at, whole_rows.map(fn(r) { r.id() }))
  }
  // Where its blocks are now (Places): as they are counted, less what the ways over each have still to open, at the
  // moment each way is laid out at as the column is laid out (its room's, the one flex lays it out at), else at the
  // logic's moment (an input, a change). With none on its way, the column as it is counted.
  // (the column as counted, made once: what is read where none is on its way, nothing made for each reading)
  let plain = Places::counted(column)
  let counted = fn(all : Column[Int]) { if physical_equal(all, column) { plain } else { Places::counted(all) } }
  let places = fn(all : Column[Int]) -> Places[Int] {
    if ways.is_empty() {
      return counted(all)
    }
    // (those let go: no more; one past its end is where it ends, its way's own at any moment after it)
    let live = ways.filter(fn(w) { w.0.live() is Some(_) })
    if live.length() != ways.length() {
      ways.clear()
      ways.append(live)
      if ways.is_empty() {
        return counted(all)
      }
    }
    let n = all.length()
    let g = all.grid
    let laying = self.tree.rooming == self.at
    let t = self.tree.logic_said()
    let froms = []
    let lefts = []
    let own_at = []
    let own_h = []
    for w in ways {
      guard w.0.live() is Some(m) else { continue }
      let st = m.flex.style
      let at = if laying && st.come_now == st.come_now { st.come_now } else { t }
      if st.come_to >= 1.0 {
        // (coming: as tall as its way has it, those under it as much higher than counted as it has still to open)
        match laid_at.get(w.1) {
          Some(i) if i < n => {
            let h = all.h(i)
            let now = rows_way_on(st, @flex.come_tall_at(st, h, at), st.come_to * h, at, g)
            froms.push(i + 1)
            lefts.push(h - now)
            own_at.push(i)
            own_h.push(now)
          }
          _ => ()
        }
      } else {
        // (going: those from the one it stood over on as much lower than counted as it is still tall)
        let i = match w.2 {
          Some(b) =>
            match laid_at.get(b) {
              Some(i) if i < n => i
              _ => n
            }
          None => n
        }
        froms.push(i)
        lefts.push(-rows_way_on(st, @flex.come_tall_at(st, 0.0, at), 0.0, at, g))
      }
    }
    { col: all, froms, lefts, own_at, own_h }
  }
  // (where it is scrolled to, as what it holds is drawn now)
  let at = fn() { s.drawn(self.tree) }
  // (made at its foot where it follows it: Scroll::to_foot, there however far that comes to be)
  if @signals.untracked(follows) {
    s.to_foot()
  }
  // Where it is scrolled to is kept as an anchor, the column's: the block at the top of what shows (the first that holds
  // what shows) and how far down its top that is. The hand, the wheel and a fling move the scroll by points, as ever;
  // as the column is laid out (its fill, below) that move is carried to the anchor, the blocks that show made and
  // measured from it, and where the scroll is put back from the anchor: what came, went or was measured anew over what
  // shows moves none of it. Nothing of this is told after the layout.
  let anchor : Ref[(Int, Double)?] = Ref(None)
  // (the others that showed as the anchor was last put and hold what shows, each with how far down its top the top of
  // what showed was: the anchor's stand-ins, in order, once it is no more among the keys (the row a filter leaves out;
  // an item become another), what shows held by the next of them where it was)
  let anchor_else : Array[(Int, Double)] = []
  // (where what is read in the anchor starts in its block, as it was last put, where its block marks it
  // (View::read_from): held by that start, read anew in each fill; none, held by its top. Each stand-in's the same,
  // in their order, read for the few marked next under the anchor alone)
  let anchor_start : Ref[Double?] = Ref(None)
  // (whether the anchor next put keeps the one held by its start while that start is in sight: not where the hand
  // moved it or it was asked somewhere since)
  let read_keeps = Ref(false)
  let anchor_else_start : Array[Double?] = []
  // (how many blocks it had, and its last, as it was said held where it is at its foot (Scroll::holds_here): blocks
  // come or gone since, with it still at its foot, and it follows its foot again)
  let held_with : Ref[(Int, Int?)] = Ref((0, None))
  s.held_said = fn() {
    let ks = @signals.untracked(keys)
    held_with.val = (ks.length(), ks.last())
  }
  // (held where it is at its foot while a field in one of its rows has the focus (Tree::row_focus_holds; the
  // coordinator of the migration's ruling, 2026-11-13), as by Scroll::holds_here, but not let go by blocks coming:
  // let go by the focus leaving its rows, which moves nothing (still at its foot, it follows it from the next block on;
  // put off it by what came under meanwhile, it is off it as one read up), or by the hand bringing it to its foot, or
  // the page asking its end (`row_let`: the focus's coming into a row it was so let go of, held again only as the focus
  // next comes into one). `row_hand_moved`: the hand moved it while so held: brought back to its foot, let go; brought
  // back to it otherwise (what came under it taken away again, the room grown), put at its foot and held from there.
  // Its pinned foot grown is counted as what it holds grown under it, held so too: known, not tested)
  let row_let = Ref(-1)
  let row_hand_moved = Ref(false)
  // (how tall what it shows was as it was last laid out: the room it shows in changed since (a keyboard's), what shows
  // held from the foot of that room where a field in a row holds it at its foot, at its foot still, Tree::holds_now's)
  let row_vh = Ref(0.0)
  let row_let_go = fn(hand : Bool) {
    if row_hand_moved.val || hand {
      row_hand_moved.val = false
      if self.tree.row_focus_holds(self.id()) is Some(n) {
        row_let.val = n
      }
    }
  }
  // (room kept under its foot for what was pressed to stay where it was as what is round it shrinks (press_stays.mbt):
  // as much as that asks while it is held, then no more than still shows of it, going as it is scrolled off)
  // (the room kept under the last block: what was pressed staying where it was as what is round it shrinks
  // (press_stays.mbt), as much as that asks while it is held; a key that went leaving its room, as tall as it was
  // (`leaves_room`). Taken first by a block come at its foot, which sets out from as tall as it is (each_by's
  // `from_of`); no more than still shows of it, going as it is scrolled off. At its foot is at its foot)
  let foot_room : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
  // (the blocks come at its foot that took the room, each with the row it is made in and how tall it set out from:
  // measured shorter than that in the fill that makes it, from as tall as it is, the rest of the room left, in that
  // layout)
  let took_room : Map[Int, (View, Double)] = Map([])
  // (how far down its blocks and the room under them but that go, as they are counted now)
  let blocks_foot = fn(all : Places[Int]) {
    all.foot() + room_under() + @signals.untracked(fn() { s.tuck_room.get() })
  }
  // (where the scroll was as the anchor was last put: what it moved by since, carried to the anchor)
  let anchor_x : Ref[Double?] = Ref(None)
  // (an ask put back by the last fill as it was cut short by its foot still going down (the fill's end): not at its
  // foot meanwhile, nothing following it; and the ask so put back, which the hand lets go of)
  let ask_cut = Ref(false)
  let ask_cut_was : Ref[ListAsk[Int]?] = Ref(None)
  // (its pinned foot holding an old view not built yet since the foot was made (the chat's composer, while it is one):
  // as tall as nothing till then, so where all of it ends is not known: a block asked to be brought is not put by it,
  // the ask kept for the fill after that view is built (or the frame about to be painted, whichever is first), never
  // taken for good where the list ends short of where it will (the fill's `cut`); a bridge while old views are hosted in
  // a list's foot, as one_move_builds is)
  let foot_unbuilt = Ref(false)
  // (and while its old view, as tall as what it holds, is not laid out by the old frame yet, whatever frame was painted
  // since (a page made while it waits to be drawn: its old view built by no frame then, as tall as nothing still):
  // where it ends is not known either, no ask taken for good by it)
  let foot_waiting = fn() {
    foot_unbuilt.val ||
    (match foot_v.val {
      Some(fv) => fv.alive() && self.tree.holds_unlaid_hosted(fv.at)
      None => false
    })
  }
  // (the column marked laid out again: not while it is laid out, its fill going on to what that changed itself)
  let laid_again = fn() {
    if self.tree.rooming != self.at {
      self.tree.layout_marked_at(self.at)
    }
  }
  // (what is made, as its fill left it: the top of the first, where it ends, the top of the last and where it ends; the
  // first's top none (-∞) where none is over it, the last's end none (∞) where none is under it)
  let made : @signals.Signal[(Double, Double, Double, Double)] = @signals.signal(
    (@double.neg_infinity, @double.infinity, @double.neg_infinity, @double.infinity),
    same=fn(a, b) { a == b },
  )
  let made_rev = Ref(0)
  // (the anchor among the blocks as they are counted now, or the first of its stand-ins that is: where it is among them
  // and how far down its top the top of what shows was; none put yet, or none of them left, none)
  let held_at = fn(all : Places[Int]) -> (Int, Double)? {
    guard anchor.val is Some((k, off)) else { return None }
    if laid_at.get(k) is Some(i) && i < all.length() {
      return Some((i, off))
    }
    for o in anchor_else {
      if laid_at.get(o.0) is Some(i) && i < all.length() {
        return Some((i, o.1))
      }
    }
    None
  }
  // (where what is read in the anchor, or the stand-in held_at found, started in its block as it was put: none where
  // it is held by its top)
  let held_start = fn(all : Places[Int]) -> Double? {
    guard anchor.val is Some((k, _)) else { return None }
    if laid_at.get(k) is Some(i) && i < all.length() {
      return anchor_start.val
    }
    for j, o in anchor_else {
      if laid_at.get(o.0) is Some(i) && i < all.length() {
        return anchor_else_start.get(j).unwrap_or(None)
      }
    }
    None
  }
  // (how far under its top what is read in the block of the `i`th key starts, where its block is made and marks it, as
  // the list is laid out now at the width it is laid out at: Tree::start_in)
  let start_of = fn(all : Places[Int], i : Int) -> Double? {
    guard !marks.is_empty() && i >= 0 && i < all.length() else { return None }
    guard room_w.untracked() is Some(w) else { return None }
    let k = all.key(i)
    for b in blocks {
      if b.0.alive() && @signals.untracked(b.1) == k {
        return match marks.get(b.0.at) {
          Some(m) if m.alive() =>
            self.tree.start_in(m.at, b.0.at, w, self.tree.rooming == self.at, self.tree.logic_said())
          _ => None
        }
      }
    }
    None
  }
  // (where what a go-to brings lies under the top of the block of the `i`th key, as the list is laid out now at the
  // width it is laid out at, the first of the block's nodes that holds some of it: its top and foot, Tree::sought_in)
  let sought_of = fn(all : Places[Int], i : Int) -> (Double, Double)? {
    guard !sought.is_empty() && i >= 0 && i < all.length() else { return None }
    guard room_w.untracked() is Some(w) else { return None }
    let k = all.key(i)
    for b in blocks {
      if b.0.alive() && @signals.untracked(b.1) == k {
        guard sought.get(b.0.at) is Some(xs) else { return None }
        for x in xs {
          guard x.0.alive() else { continue }
          match @signals.untracked(x.1) {
            Some(piece) =>
              match
                self.tree.sought_in(x.0.at, b.0.at, w, self.tree.rooming == self.at, self.tree.logic_said(), piece) {
                Some(at) => return Some(at)
                None => ()
              }
            None => ()
          }
        }
        return None
      }
    }
    None
  }
  // (how far under its top what is read in the block of the `i`th key started as the list was last laid out, where
  // that block was laid out and marks it: Tree::start_laid)
  let start_laid_of = fn(all : Places[Int], i : Int) -> Double? {
    guard !marks.is_empty() && i >= 0 && i < all.length() else { return None }
    let k = all.key(i)
    guard showing.contains(k) else { return None }
    for b in blocks {
      if b.0.alive() && @signals.untracked(b.1) == k {
        return match marks.get(b.0.at) {
          Some(m) if m.alive() => self.tree.start_laid(m.at, b.0.at)
          _ => None
        }
      }
    }
    None
  }
  // (the first key whose marked start is at or under what covers its top and over its pinned foot's top, the top of
  // what shows at `top`, `vh` of it showing: where it is among the blocks and how far under its top that start is; none
  // where no key's start shows)
  let read_anchor = fn(all : Places[Int], top : Double, vh : Double) -> (Int, Double)? {
    guard !marks.is_empty() && all.length() > 0 else { return None }
    let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
    let edge = top + cover
    let foot = top + vh - under
    let in_sight = fn(j : Int) -> Double? {
      guard all.known(j) && holds(all.key(j)) else { return None }
      match start_of(all, j) {
        Some(sj) if all.top(j) + sj >= edge - 0.001 && all.top(j) + sj < foot => Some(sj)
        _ => None
      }
    }
    // (the one held till now, its start still in sight: kept, whatever came into sight over it as what is over it
    // closed or came, the reader's eyes on it; taken anew once the hand moves the list, as `keep` is false)
    match (anchor.val, anchor_start.val) {
      (Some((k, _)), Some(_)) if read_keeps.val =>
        match laid_at.get(k) {
          Some(j) if j < all.length() =>
            match in_sight(j) {
              Some(sj) => return Some((j, sj))
              None => ()
            }
          _ => ()
        }
      _ => ()
    }
    let mut j = all.first_past(edge).min(all.length() - 1)
    while j < all.length() && all.top(j) < foot {
      match in_sight(j) {
        Some(sj) => return Some((j, sj))
        None => ()
      }
      j = j + 1
    }
    None
  }
  // (where the top of what shows is by where the blocks are counted now: the anchor's, moved as the scroll was since it
  // was put; none yet, where the scroll is. What came in or went over what shows since has moved the blocks' tops, not
  // yet the scroll (its fill puts it): by the scroll alone, what shows would be read off other blocks.)
  let top_now = fn(all : Places[Int], x : Double) {
    match (held_at(all), anchor_x.val) {
      (Some((i, off)), Some(was)) => all.top(i) + off + (x - was)
      _ => x
    }
  }
  // (where the top of what shows is with the column at its foot, showing `vh` of it: by its blocks as they are counted
  // now and its foot's room, followed)
  let foot_top = fn(all : Places[Int], vh : Double) {
    dmax(0.0, all.foot() + room_under() + s.tuck_room.get() + foot_room.get() - vh)
  }
  // (a press in one of its blocks, press_stays.mbt: that block held so that what was pressed stays where it was: its
  // key, how far under the top of what shows its top was, what lies over what was pressed in it (each node before it
  // or before what holds it, down a column, in the block) and how tall that was then; none once the hand moves it or
  // all the press set off has ended)
  let pin : Ref[(Int, Double, Array[View], Double)?] = Ref(None)
  // (what was pressed: let go, or what was over it, held no more)
  let pin_node : Ref[View?] = Ref(None)
  // (what holds what was pressed, up to its block, each with where what lies over it starts among `over` and how tall
  // what lies over what was pressed under it was then: what was pressed let go by what it was in (a pick's branch made
  // anew as the press shuts or opens it), held by the nearest of them still there, by what lies over that, as tall as
  // that was then)
  let pin_up : Ref[Array[(View, Int, Double)]] = Ref([])
  let pin_less = Ref(0.0)
  // (where it was held at the foot of the room kept under its blocks once what was pressed held it no more (its fill's
  // `top` and keys then): followed again once keys come at its foot have taken that room, unless the hand moved it from
  // there or another row was pressed)
  let room_held : Ref[(Double, Int, Int?)?] = Ref(None)
  let unpin : Ref[() -> Unit] = Ref(fn() {  })
  let pin_ends = Ref(false)
  // (where it was scrolled to as it was pressed: moved from there by the hand, held no more; and how many blocks it had,
  // and its last, then: blocks come or gone since at its foot, where it follows it, followed again)
  let pin_x = Ref(0.0)
  let pin_with : Ref[(Int, Int?)] = Ref((0, None))
  let pin_foot = Ref(false)
  // (the node its blocks are held in, once made: what they hold set coming or going kept by it, Tree's list_inner)
  let held_node = Ref(-1)
  // (how tall what lies over what was pressed is, each measured now as wide as it was last laid out; where what it is
  // or holds through its slots (a show's, a pick's, an each's) is on its way in or out, as tall as its way has it at
  // the moment it is read, as Places reads a block on its way: measured whole, a way's opening would be counted all at
  // once as it sets out)
  let over_h = fn(over : Array[View]) {
    let tree = self.tree
    let laying = tree.rooming == self.at
    let t = tree.logic_said()
    let mut h = 0.0
    for o in over {
      guard o.alive() && tree.nodes[o.at].flex.style.display != @flex.Display::DisplayNone else { continue }
      let items = if tree.nodes[o.at].slot { tree.column_items(o.at) } else { [o.at] }
      let on_way = items.iter().any(fn(k) {
        let st = tree.nodes[k].flex.style
        tree.nodes[k].live && st.come_at == st.come_at && st.come_to == st.come_to
      })
      if !on_way {
        h = h + @flex.measured_height(tree.nodes[o.at].flex, tree.nodes[o.at].flex.width)
        continue
      }
      // (one made since it was last laid out: as wide as what holds it was)
      let wide = if tree.nodes[o.at].flex.width > 0.0 {
        tree.nodes[o.at].flex.width
      } else {
        tree.nodes[tree.nodes[o.at].parent].flex.width
      }
      for k in items {
        let m = tree.nodes[k]
        guard m.live && m.flex.style.display != @flex.Display::DisplayNone else { continue }
        let st = m.flex.style
        // (how tall it comes to whole: what its way went to as it was last laid out, coming; measured, it is as tall as
        // its way had it then, never laid out yet as tall as it comes to)
        let whole = if st.come_goal == st.come_goal && st.come_to > 0.0 {
          st.come_goal / st.come_to
        } else {
          @flex.measured_height(m.flex, if m.flex.width > 0.0 { m.flex.width } else { wide })
        }
        let at = if laying && st.come_now == st.come_now { st.come_now } else { t }
        h = h + @flex.come_tall_at(st, whole, at)
      }
    }
    h
  }
  // (when all a change at `cause` set off ends: the latest end any of what was set coming (or going too, where not
  // `coming`) in it at that moment declares (its keys' ways, what its blocks hold: Tree's list_inner, a way turned back
  // too), said once the change is told whole and its column's group with it; where none declares one, as long as a
  // Move takes at most)
  let set_off_end = fn(cause : Double, coming : Bool) -> Double {
    let mut end = @double.neg_infinity
    let set_off = ways.map(fn(w) { w.0 })
    set_off.append(self.tree.list_inner_at(held_node.val, cause))
    for w in set_off {
      match w.live() {
        Some(n) if (n.coming || !coming) &&
          n.flex.style.come_at == cause &&
          n.flex.style.come_ends == n.flex.style.come_ends => end = dmax(end, n.flex.style.come_ends)
        // (on a way its page said, its end not laid out yet: that way's length from the cause, scrolls_window's
        // `comes_way`, longer than a Move may be)
        Some(n) if n.coming && n.flex.style.come_at == cause && n.flex.style.come_spec is Some((ms, _)) =>
          end = dmax(end, cause + ms)
        _ => ()
      }
    }
    if end > cause {
      end
    } else {
      cause + @flex.move_most_ms
    }
  }
  s.pressed_said = fn(v) {
    // (the block it is in, made here, and what lies over it there: none, nothing held)
    let over : Array[View] = []
    let up_at : Array[(View, Int)] = []
    let mut found : Int? = None
    let mut i = v.at
    while i >= 0 && i != self.at && found is None {
      up_at.push((self.tree.handle(i), over.length()))
      for b in blocks {
        if b.0.at == i && b.0.alive() {
          found = Some(@signals.untracked(b.1))
        }
      }
      let up = self.tree.nodes[i].parent
      if found is None && up >= 0 && self.tree.nodes[up].flex.style.direction is Column {
        for c in self.tree.nodes[up].kids {
          if c == i {
            break
          }
          over.push(self.tree.handle(c))
        }
      }
      i = up
    }
    guard found is Some(k) else { return fn() {  } }
    let all = places(laid.untracked())
    guard laid_at.get(k) is Some(j) && j < all.length() else { return fn() {  } }
    // (where the top of what shows is: at its foot, followed there, where that is)
    let shown_top = if s.at_foot() {
      foot_top(all, match s.seen.untracked() {
        Some((_, vh)) => vh
        None => 0.0
      })
    } else {
      top_now(all, @signals.untracked(at))
    }
    let below = all.top(j) - shown_top
    let each_h = over.map(fn(o) { over_h([o]) })
    let was = each_h.fold(init=0.0, fn(a, h) { a + h })
    let up = up_at.map(fn(u) {
      let mut under = 0.0
      for n in 0..<u.1 {
        under = under + each_h[n]
      }
      (u.0, u.1, under)
    })
    let x_then = @signals.untracked(at)
    let foot_then = s.at_foot() && @signals.untracked(follows)
    fn() {
      (unpin.val)()
      room_held.val = None
      pin.val = Some((k, below, over, was))
      pin_node.val = Some(v)
      pin_up.val = up
      pin_less.val = 0.0
      pin_x.val = x_then
      let ks = @signals.untracked(keys)
      pin_with.val = (ks.length(), ks.last())
      pin_foot.val = foot_then
      // (all it set off ended: held so once more, in the layout of that moment, then no more. Its end the latest any
      // of what was set coming or going in it at the press's moment declares (a row's way, what a block holds; a
      // group turned back too), said once the change is told whole and its column's group with it, a wait inside a
      // wait as the ways' own; where none declares one, as long as a Move takes at most)
      pin_ends.val = false
      unpin.val = fn() {  }
      let cause = self.tree.cause_now()
      let mine = pin.val
      @signals.after_flush(fn() {
        @signals.after_flush(fn() {
          guard physical_equal(pin.val, mine) else { return }
          let end = set_off_end(cause, true)
          unpin.val = self.at_moment(end, fn() {
            pin_ends.val = true
            laid_again()
          })
        })
      })
    }
  }
  // (the floor armed by a change: from how tall the column is as its fill last left it (as tall as it shows, a floor
  // armed before counted in it), till all that change set off ends, coming or going; one armed again by another change
  // meanwhile goes on from there. Not while what is pressed holds it)
  let floor_off : Ref[() -> Unit] = Ref(fn() {  })
  let floor_n = Ref(0)
  floor_arm.val = fn(k, stretch) {
    guard !(pin.val is Some(_)) else { return }
    (floor_off.val)()
    floor_off.val = fn() {  }
    floor.val = Some((k, stretch))
    floor_n.val = floor_n.val + 1
    let mine = floor_n.val
    let cause = self.tree.cause_now()
    @signals.after_flush(fn() {
      @signals.after_flush(fn() {
        guard floor_n.val == mine && floor.val is Some(_) else { return }
        floor_off.val = self.at_moment(set_off_end(cause, false), fn() {
          if floor_n.val == mine {
            floor.val = None
          }
        })
      })
    })
  }
  floor_end.val = fn() {
    floor.val = None
    (floor_off.val)()
    floor_off.val = fn() {  }
  }
  self.owns(fn() { (floor_off.val)() }) |> ignore
  // (following its foot, scrolled back to it by the hand or the wheel, at rest there: at its foot again, kept there
  // however far that comes to be as what it holds grows, till it is moved off it; told as that comes to be so, not each
  // time the column is scrolled. By its own blocks and its anchor, as its near_foot is: by how far the scroll could
  // go as last laid out, a column moved in its fill for what came in or grew over what shows (Scroll::grew_above)
  // further than that was read at its foot before that layout said how far it goes now, and taken there: what was
  // read 100 off its foot gone as a block 150 taller than counted came in at its top.)
  // (held by a block's top a standing limit says, binding as last laid out (ListPlace::follow_from): off its foot then to
  // every rule of it, however near the foot it lies)
  let capped = @signals.signal(false, same=fn(a, b) { a == b })
  // (held so still: where its fill held it, not moved since by the hand, a fling or an ask; moved, the reader took it,
  // and it is held no more, whether a fill has run since or not)
  let capped_now = fn() {
    capped.get() &&
    (match anchor_x.val {
      Some(was) => (at() - was).abs() <= 0.000001
      None => true
    })
  }
  let at_most = @signals.computed(fn(_) {
    guard !capped_now() else { return false }
    guard s.seen.get() is Some((_, vh)) else { return false }
    let all = places(laid.get())
    top_now(all, at()) >= foot_top(all, vh) - 0.5 && s.rest_now() is None && s.glides_till() is None
  }, same=fn(a, b) { a == b })
  // (at its foot as Scroll::at_foot_now tells it, told only as that changes: following it there, however far that comes
  // to be; else where the top of what shows is by its anchor, as its blocks are counted now, within half a point of
  // where it would be at its foot. By its own blocks, so in the same layout as one measured anew or grown there, as
  // its near_foot is; not by how far the scroll went as last laid out, which a block come or grown has not reached yet)
  // (scoped: read once outside any reader (Scroll::at_foot_now, untracked), it lets go of what it read again, so that
  // what it reads (its blocks, its keys) is followed by nothing once nothing else follows it: a plain one kept on
  // them for good, the keys' topic with them, past the list's going)
  let at_foot_now = @signals.computed_scoped(fn(_) {
    if capped_now() {
      return false
    }
    if s.x.get() == @double.infinity {
      return true
    }
    guard s.seen.get() is Some((_, vh)) else { return false }
    let all = places(laid.get())
    top_now(all, at()) >= foot_top(all, vh) - 0.5
  }, same=fn(a, b) { a == b })
  s.at_foot_said = Some(fn() { at_foot_now.get() })
  // (what its foot covers of what shows, for what is brought into sight: the room it keeps under its last block; and of
  // that its top that hides nothing, the rows showing through it (`foot_clear`: a chat's room under its last message
  // over the composer, which alone hides them), for what flies from a thing in it or back: Scroll::foot_hides_now)
  s.foot_covered = fn() { foot_h.get() }
  s.foot_clear = foot_clear
  // (the glide back to its foot it is on (ListPlace::to_end), while it is: gone on toward where its foot is as that
  // moves, in its fill; none once another way is in its place (the hand, the wheel, another ask) or it is at rest)
  let end_glide : Ref[Notch?] = Ref(None)
  // (whether one is said, told as that changes: what reads whether it glides there (follows_now) told it)
  let end_glide_said = @signals.signal(false, same=fn(a, b) { a == b })
  let end_glide_set = fn(g : Notch?) {
    end_glide.val = g
    end_glide_said.set(g is Some(_))
  }
  // (following its foot, as a page asks what comes at it to be followed by (Scroll::follows_now): at it; held by a
  // standing limit the reader has not moved it off (ListPlace::follow_from); or on its glide back to it, not stopped
  // by another way, or come to its end, till the fill after takes where it landed (the old view's list's `at_end ||
  // gliding || following_row`). Its notch let go of as it is stopped (the hand, the wheel: Scroll::stopped) as it is
  // as it lands, the two told apart by how it was let go of (Scroll's notch_landed), as the fill tells them
  // (glide_landed). Scoped as at_foot_now is)
  let follows_now = @signals.computed_scoped(fn(_) {
    at_foot_now.get() ||
    capped_now() ||
    (end_glide_said.get() &&
    (match (end_glide.val, s.notch.get()) {
      (Some(g), Some(n)) => physical_equal(g, n)
      (Some(_), None) => s.is_notch_landed()
      _ => false
    }))
  }, same=fn(a, b) { a == b })
  s.set_follows_said(Some(fn() { follows_now.get() }))
  // (on its glide back to its foot, not stopped by another way: Scroll::glides_to_foot. Scoped as at_foot_now is)
  let glides_foot = @signals.computed_scoped(fn(_) {
    end_glide_said.get() &&
    (match (end_glide.val, s.notch.get()) {
      (Some(g), Some(n)) => physical_equal(g, n)
      _ => false
    })
  }, same=fn(a, b) { a == b })
  s.set_glides_foot_said(Some(fn() { glides_foot.get() }))
  // (come to its foot by that glide since its last fill: what the next fill finds the scroll moved by since then is
  // the glide's, not the hand's, and lets go of nothing the hand would (a limit said at its foot from then stands))
  let glided_foot = Ref(false)
  let jumped_at = Ref(-1.0)
  self.reacts(fn() { at_most.get() }, fn(foot) {
    if foot && @signals.untracked(follows) && !s.at_foot() && !ask_cut.val {
      // (back at its foot, having left it: followed again, whatever held it where it was, Scroll::holds_here, a
      // field in a row)
      s.held = false
      // (brought here by its glide back to its foot: still on it, or gone because it ran out, the moment at or past
      // where it ends (its notch kept as it was last said or gone on); gone before then, stopped: the hand's, the wheel's)
      let glided = match (end_glide.val, s.notch.untracked()) {
        (Some(g), Some(n)) => physical_equal(g, n)
        (Some(g), None) => self.tree.logic_said() >= g.t0 + g.end - 0.001
        _ => false
      }
      // (the hand's: the scroll moved off where its last fill put it, before a fill has seen it)
      let hand = !glided && anchor_x.val is Some(was) && (@signals.untracked(at) - was).abs() > 0.000001
      row_let_go(hand)
      // (and a limit its foot was followed by let go of: the reader took the list to its foot, as a fill that sees the
      // hand's move lets it go. Brought there by a move that made no fill run (no slot found again: a key held less
      // than half a screen off its foot), it stood, and the next key come took the list back up to it)
      if hand {
        match place {
          Some(p) => p.from = None
          None => ()
        }
      }
      s.to_foot()
      glided_foot.val = glided
    }
  })
  match near_foot {
    Some((screens, wanting, ask)) => {
      // (how far its foot is by its own blocks' tops as its keys are now, those not laid out yet as tall as `est`: not
      // the room last laid out, which a page more come in has not reached yet, so that it is not asked again for it
      // before it is laid out, nor at once again, page after page, by a source that answers as it is asked)
      let near = @signals.computed(fn(_) {
        guard s.seen.get() is Some((_, vh)) && vh > 0.0 else { return false }
        let foot = counted(laid.get()).foot()
        foot + room_under() + s.tuck_room.get() + foot_room.get() - vh - at() < screens * vh
      }, same=fn(a, b) { a == b })
      self.reacts(fn() { (near.get() && wanting(), keys().length()) }, fn(now) {
        if now.0 {
          ask()
        }
      })
    }
    None => ()
  }
  match near_top {
    Some((screens, wanting, ask)) => {
      // (how far its top is by its anchor as its keys are now, those over it not laid out yet as tall as `est`: not
      // by the scroll, which a page come in over what shows has not moved yet, so that it is not asked again for that
      // page before it is laid out)
      // (at its foot however far that comes to be: only where nothing is over what shows, by its blocks (the scroll
      // says nothing of how far down its foot is before it is laid out there, and the room it is first laid out in may
      // be taller than the one it gets: a panel whose head is measured a frame later))
      let near = @signals.computed(fn(_) {
        guard s.seen.get() is Some((_, vh)) && vh > 0.0 else { return false }
        let all = counted(laid.get())
        let x = at()
        // (by where its keys start, under its head: how far what shows is from them)
        if s.at_foot() {
          foot_top(all, vh) <= all.col.start
        } else {
          top_now(all, x) - all.col.start < screens * vh
        }
      }, same=fn(a, b) { a == b })
      self.reacts(fn() { (near.get() && wanting(), keys().length()) }, fn(now) {
        if now.0 {
          ask()
        }
      })
    }
    None => ()
  }
  // (the first from `i` on that holds what shows: none of them, the `i`th)
  let holding = fn(all : Places[Int], i : Int) {
    let mut j = i
    while j < all.length() && !holds(all.key(j)) {
      j = j + 1
    }
    if j < all.length() {
      j
    } else {
      i
    }
  }
  // (whether each shows, by its key: told only to those that come to show or stop, not each block reading the window,
  // all of them run again each time the column is scrolled)
  let shown : Map[Int, @signals.Signal[Bool]] = Map([])
  // (a block's own as it is made in what shows it (`v`), `key` its key as it is now: as tall as what it holds,
  // whatever its slot is counted as till that is told; how tall it is told as it is laid out, kept by its key, told
  // again as it is another's)
  let block = fn(v : View, key : () -> Int, made : (View) -> Unit) {
    v.shrink(Is(0.0)) |> ignore
    let k = @signals.untracked(key)
    showing[k] = true
    v.owns(fn() { unshow(@signals.untracked(key), v.at) }) |> ignore
    // (measured as it is laid out, in that layout: the column's fill, below)
    blocks.push((v, key))
    // (known by its key as the row it is made for, read as its key is: taken for another key, that one's row from then;
    // where a word in it is placed, View::row_place stops at it)
    self.tree.nodes[v.at].each_row = true
    let named = (
      self.id(),
      fn() { number_of(key()) },
      fn() { laid_at.get(@signals.untracked(key)).unwrap_or(-1) },
    )
    self.tree.rows_named[v.at] = named
    let v_at = v.at
    v.owns(fn() {
      if self.tree.rows_named.get(v_at) is Some(r) && physical_equal(r.2, named.2) {
        self.tree.rows_named.remove(v_at)
      }
    })
    |> ignore
    made(v)
  }
  // (how tall what it holds comes to with its blocks where `all` has them, and its foot's room, untracked)
  let whole_of = fn(all : Places[Int]) {
    @signals.untracked(fn() { all.foot() + room_under() + s.tuck_room.get() + foot_room.get() })
  }
  // (how tall what it holds comes to: its blocks where they are now, on its host's pixels, and its foot's room)
  let whole_now = fn() {
    @signals.untracked(fn() { whole_of(places(laid.get())) })
  }
  let way_steady_fn : Ref[() -> (Double, Bool, Array[(String, NodeId, Bool, Bool)])] = Ref(fn() { (-1.0, false, []) })
  // (what is asked of it at a cause: done as the column is laid out again, or at once where it glides there)
  match place {
    Some(p) => {
      s.to_foot = fn(_) {
        p.from = None
        p.asked = Some(ToEnd)
        laid_again()
        true
      }
      p.laid_again = laid_again
      // (what a test reads of it and asks of it, as of an old view's list: Tree::lists_seen)
      let asked_tree = self.tree
      let asked_at = self.at
      asked_tree.lists_asked[asked_at] = {
        scroll: s,
        count: fn() { @signals.untracked(keys).length() },
        bring: fn(i, glide) {
          let ks = @signals.untracked(keys)
          if i >= 0 && i < ks.length() {
            p.bring(ks[i], glide~)
          }
        },
        to_end: fn() { p.to_end(glide=false) },
        way_steady: fn() { (way_steady_fn.val)() },
      }
      self.owns(fn() { asked_tree.lists_asked.remove(asked_at) }) |> ignore
      // (what it has in sight, counted by its keys' blocks as they come to rest: their heights as counted, not as a way
      // has them, the scroll where it rests (at its foot where it follows it, where a notch eases to; where it is as a
      // fling goes), and told to the place's handlers at the hand's moments (Tree::sights_now), as that differs)
      p.sight_of = fn() {
        @signals.untracked(fn() {
          let all = Places::counted(laid.get())
          let t = self.tree.logic_said()
          // (the keys on their way in, not at its end then: not drawn whole till it, list_sight.mbt)
          let coming = ways.filter_map(fn(w) {
            guard w.0.live() is Some(m) && m.coming && m.flex.style.come_to >= 1.0 && laid_at.get(w.1) is Some(q) else {
              return None
            }
            let st = m.flex.style
            let ends = if st.come_ends == st.come_ends { st.come_ends } else { st.come_at + @flex.move_most_ms }
            if ends > t { Some(q) } else { None }
          })
          // (`flips`: those come by its way, till it ends, and those come by a change not set out yet)
          for k, _ in flip_came {
            if laid_at.get(k) is Some(q) {
              coming.push(q)
            }
          }
          match flip_way.untracked() {
            Some(w) if w.ends() > t =>
              for k, _ in flip_new {
                if laid_at.get(k) is Some(q) {
                  coming.push(q)
                }
              }
            _ => ()
          }
          match sight_counted(all, s, t, room_under(), foot_room.get(), coming) {
            // (a key gone leaving its room, kept among its blocks while it fades: never told, the one over it in its
            // place, its height still counted where the foot is)
            Some(sg) if fading.val is Some((k, _)) && all.length() >= 2 => {
              let over = all.key(all.length() - 2)
              Some({
                ..sg,
                first: if sg.first == k { over } else { sg.first },
                last: if sg.last == k { over } else { sg.last },
                whole: if sg.whole == Some(k) { Some(over) } else { sg.whole },
              })
            }
            other => other
          }
        })
      }
      // (told it only once something listens (ListPlace::on_sight): till then nothing of it is worked out or owed)
      let sight_tree = self.tree
      let sight_at = self.at
      let listened = Ref(false)
      p.sight_listened = fn() {
        guard !listened.val && self.alive() else { return }
        listened.val = true
        sight_tree.sight_tellers[sight_at] = fn() { p.sight_tell() }
        sight_tree.sight_owe(sight_tree.logic_said())
      }
      self.owns(fn() {
        sight_tree.sight_tellers.remove(sight_at)
        p.sight_listened = fn() {  }
      })
      |> ignore
      if !p.sight_fns.is_empty() {
        (p.sight_listened)()
      }
      p.glide = fn(ask) {
        // (its pinned foot not laid out as tall as it is yet: where all of it ends not known, nothing to glide to; the
        // fill takes the ask, keeping it till it is: foot_unbuilt)
        if foot_waiting() {
          match ask {
            ToEnd => ()
            _ => return false
          }
        }
        let all = places(laid.untracked())
        let vh = match s.seen.untracked() {
          Some((_, vh)) => vh
          None => 0.0
        }
        let most = dmax(0.0, whole_now() - vh)
        // (no further up than the hand takes it: what is tucked over its top kept out of sight, Scroll::top_now)
        let top = dmin(@signals.untracked(fn() { s.top_now() }), most)
        let to = match ask {
          // (its offset from under what covers its top, as the fill's)
          // (what it holds of a go-to's (`sought`) low in what shows with its top there: its middle at the middle of
          // that instead, as the fill puts it, where it is laid out now)
          Bring(k, off, sought) =>
            match laid_at.get(k) {
              Some(i) if i < all.length() => {
                let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
                let to = all.top(i) + off - cover
                match (sought, sought_of(all, i)) {
                  (true, Some((y0, y1))) if (y0 + y1) / 2.0 - off + cover > cover + 0.8 * (vh - under - cover) =>
                    Some(to + (y0 + y1) / 2.0 - off - (cover + vh - under) / 2.0 + cover)
                  _ => Some(to)
                }
              }
              _ => None
            }
          ToEnd => Some(most)
          Centre(_) | BringSought(_, _) => None
        }
        match to {
          // (far from there, more than two of its heights: there at once, as an old view's list's glide far)
          Some(to) if (to - @signals.untracked(at)).abs() <= glide_most * vh => {
            s.held = false
            pin.val = None
            (unpin.val)()
            match (ask, end_glide.val, s.notch.untracked()) {
              // (back to its foot again while it glides there: on from where it is, as fast as it goes)
              (ToEnd, Some(g), Some(n)) if physical_equal(g, n) =>
                s.glide_on(self, self.cause_at(), dclamp(to, top, most), most)
              _ => s.glide_to(self, self.cause_at(), dclamp(to, top, most))
            }
            end_glide_set(
              match ask {
                ToEnd => s.notch.untracked()
                _ => None
              },
            )
            true
          }
          _ => false
        }
      }
      // (how far one block's top lies under another's as they are counted now: read off them, nothing laid out)
      p.span_of = fn(a, b, measured) {
        let all = counted(laid.untracked())
        match (laid_at.get(a), laid_at.get(b)) {
          (Some(i), Some(j)) if i < all.length() && j < all.length() => {
            // (`measured`: every block between them measured, else not known)
            if measured {
              for q in (if i < j { i } else { j })..<(if i < j { j } else { i }) {
                if !all.known(q) {
                  return None
                }
              }
            }
            Some(all.top(j) - all.top(i))
          }
          _ => None
        }
      }
      // (span_of kept past the list as sight_of is: what reads where the reader left it as the page is let go reads both
      // as they were last counted)
      self.owns(fn() {
        p.laid_again = fn() {  }
        p.glide = fn(_) { false }
      })
      |> ignore
    }
    None => ()
  }
  // (which show, as the fill last left them)
  let shown_now : Array[Int] = []
  // (told only to those that come or go, each found among the others by looking: what shows is a screen of them, and
  // those that stay were told as they came, or made so: `shown`'s cell made by `shown_now`)
  let show_only = fn(now : Array[Int]) {
    guard now != shown_now else { return }
    for k in shown_now {
      if !now.contains(k) && shown.get(k) is Some(c) {
        c.set(false)
      }
    }
    for k in now {
      if !shown_now.contains(k) && shown.get(k) is Some(c) {
        c.set(true)
      }
    }
    shown_now.clear()
    shown_now.append(now)
  }
  // (those that show as they were measured, or as they were counted and came out so: what was seen as it is, which
  // holds where the column is as it is moved, before one come in over it measured otherwise)
  let seen_rows : Map[Int, Bool] = Map([])
  // (the anchor put where the top of what shows is `top`, `vh` of it showing, the scroll at `x` then, by the blocks as
  // they are counted now: the first that holds what shows, how far down its top the top of what shows is; what is
  // measured anew over it from now on moving none of what shows. One never measured holds nothing sure, the top of what
  // shows somewhere in a height it is only counted: the first measured that shows under it holds it instead, from over
  // its top. Held by one counted 48 and measured 218 in the next fill, what showed under it went down the 170 more with
  // it, and that fill, going out from it alone, let go of every block in sight to make them again. Those that show its
  // stand-ins.)
  let anchor_put = fn(all : Places[Int], top : Double, vh : Double, x : Double) {
    let read = read_anchor(all, top, vh)
    anchor_start.val = read.map(fn(r) { r.1 })
    anchor.val = if read is Some((j, _)) {
      Some((all.key(j), top - all.top(j)))
    } else if all.length() > 0 {
      let first = holding(all, all.first_past(top).min(all.length() - 1))
      let mut j = first
      while j < all.length() && all.top(j) < top + vh && !(all.known(j) && holds(all.key(j))) {
        j = j + 1
      }
      let j = if j < all.length() && all.top(j) < top + vh { j } else { first }
      Some((all.key(j), top - all.top(j)))
    } else {
      None
    }
    anchor_x.val = Some(x)
    anchor_else.clear()
    anchor_else_start.clear()
    // (held by a marked start: the stand-ins' starts read for the next few marked under it, in sight)
    let mut starts_left = if read is Some(_) { 3 } else { 0 }
    let after = match read {
      Some((j, _)) => j
      None => all.length()
    }
    for k in shown_now {
      if holds(k) && laid_at.get(k) is Some(i) && i < all.length() {
        anchor_else.push((k, top - all.top(i)))
        let st = if starts_left > 0 && i > after && all.top(i) < top + vh {
          let got = start_of(all, i)
          if got is Some(_) {
            starts_left = starts_left - 1
          }
          got
        } else {
          None
        }
        anchor_else_start.push(st)
      }
    }
  }
  // (the anchor one of the keys that moved among them: what shows held by the first of its stand-ins that stayed, where it
  // showed, not by one gone elsewhere taking what shows with it)
  anchor_moved.val = fn(moved) {
    guard !s.at_foot() else { return }
    guard anchor.val is Some((a, _)) && moved.contains(a) else { return }
    for j, o in anchor_else {
      if laid_at.contains(o.0) && !moved.contains(o.0) {
        anchor.val = Some(o)
        anchor_start.val = anchor_else_start.get(j).unwrap_or(None)
        return
      }
    }
  }
  // Moved by the hand, the wheel, a fling or Scroll::put since its fill last put the anchor, with nothing laid out
  // since (scrolled so that only blocks counted as they are come to show, its fill does not run: what shows is shown
  // by the scroll alone, past_made below), the anchor is still the one put then, perhaps far out of sight (its foot's
  // last, the column scrolled up off its foot), the move carried as how far the scroll went since (top_now). A key come
  // in between it and what shows was counted over it, and what was read moved by as much (one put in under the top of
  // what shows, over the foot it was opened at: the column 40 further down, what was read 40 up, 2026-11-12). So as its
  // keys change, the anchor is put first where the column is now, by its blocks as they were counted till then: what
  // comes in is put in round what is read.
  anchor_again.val = fn(col) {
    let all = places(col)
    guard !s.at_foot() && anchor_x.val is Some(was) && held_at(all) is Some(_) else { return }
    let x = @signals.untracked(at)
    guard (x - was).abs() > 0.000001 else { return }
    // (moved off where a limit held it: the reader took it, the limit let go of, before the anchor is put where it is
    // now and the move is no longer seen)
    // (not by its glide back to its foot, which ends where the limit holds it)
    let gliding_foot = match (end_glide.val, s.notch.untracked()) {
      (Some(g), Some(n)) => physical_equal(g, n)
      _ => false
    }
    if capped.untracked() && !gliding_foot {
      match place {
        Some(p) => p.from = None
        None => ()
      }
      capped.set(false)
    }
    let vh = match s.seen.untracked() {
      Some((_, vh)) => vh
      None => 0.0
    }
    anchor_put(all, top_now(all, x), vh, x)
  }
  // (the keys that have slots, in order: those that meet where it shows and `slots_margin` of its heights over and
  // under it, found again only as what shows comes within `slots_near` of their ends or is more than `slots_far` from
  // them (a wheel going back and forth over where they end makes and lets go nothing), and as the keys change among
  // them; the rest have no node, the column holding a spacer over them and one under, as tall as they are counted)
  let slot_keys : @signals.Signal[Array[Int]] = @signals.signal([], same=fn(a, b) { physical_equal(a, b) })
  // (where the slots' first key was found, in which column and at how many of its fillings: while it is filled no
  // more, the slots are where they were found and what covers what shows is told by places alone, no key looked up)
  let slots_found : Ref[(Column[Int], Int, Int)?] = Ref(None)
  // (what the window last found shows, and the places it found it from and to: window)
  let window_found : Ref[(Array[Int], Int, Int)] = Ref(([], 0, -1))
  // (whether the window last found stopped short of what shows at one never measured: window)
  let window_short = Ref(false)
  // (the slots that hold `need` (what shows) and as much round it as where the column shows from `top`, `vh` tall,
  // asks; a block put by in a slot that leaves them taken out of it first, held by no node (View::park), kept)
  // (a block that shows a key whose slot leaves the slots, `ks` those kept: let go with its slot (what it holds before
  // it), never through its leaving what shows (its keys changed: what is filtered out), what its parts keep kept by its
  // key first, while it lives: reused_state.mbt)
  let keep_leaving = fn(ks : Array[Int]) {
    for bl in blocks {
      let bk = @signals.untracked(bl.1)
      if bl.0.alive() && showing.contains(bk) && !ks.contains(bk) {
        keep_from(bl.0, bk)
      }
    }
  }
  let slots_cover = fn(all : Places[Int], need : Array[Int], top : Double, vh : Double) {
    let n = all.length()
    if n == 0 {
      slots_found.val = None
      if slot_keys.untracked().length() > 0 {
        keep_leaving([])
        slot_keys.set([])
      }
      return
    }
    // (where what shows is: by the places the window found it at, where it is what the window found; else by its keys)
    let mut lo = n
    let mut hi = -1
    let (wnow, wlo, whi) = window_found.val
    if physical_equal(wnow, need) {
      if wlo <= whi {
        lo = wlo
        hi = whi.min(n - 1)
      }
    } else {
      for k in need {
        match laid_at.get(k) {
          Some(i) if i < n => {
            lo = lo.min(i)
            hi = hi.max(i)
          }
          _ => ()
        }
      }
    }
    let cur = slot_keys.untracked()
    let holds = fn(i : Int) {
      let j = i + cur.length() - 1
      i <= lo &&
      hi <= j &&
      (vh <= 0.0 ||
      (
        (i == 0 || all.top(i) <= top - slots_near * vh) &&
        (j == n - 1 || all.top(j) + all.h(j) >= top + vh + slots_near * vh) &&
        (i == lo || all.top(i) + all.h(i) >= top - slots_far * vh) &&
        (j == hi || all.top(j) <= top + vh + slots_far * vh)
      ))
    }
    // (the column filled no more since the slots were found: where they are, its places alone)
    let found_at = match slots_found.val {
      Some((col, at, i)) if physical_equal(col, all.col) && at == all.col.refills && i + cur.length() <= n => Some(i)
      _ => None
    }
    let covered = match found_at {
      Some(i) => cur.length() > 0 && holds(i)
      None =>
        match cur.get(0) {
          Some(a) =>
            match laid_at.get(a) {
              Some(i) if i + cur.length() <= n => {
                let mut same = true
                for t in 0..<cur.length() {
                  if all.key(i + t) != cur[t] {
                    same = false
                    break
                  }
                }
                if same {
                  slots_found.val = Some((all.col, all.col.refills, i))
                }
                same && holds(i)
              }
              _ => false
            }
          None => false
        }
    }
    if covered {
      return
    }
    let (a, b) = if vh > 0.0 {
      (
        all.first_past(top - slots_margin * vh).min(n - 1),
        all.first_past(top + vh + slots_margin * vh).min(n - 1),
      )
    } else if hi >= 0 {
      (lo, hi)
    } else {
      (0, -1)
    }
    let a = if hi >= 0 { a.min(lo) } else { a }
    let b = if hi >= 0 { b.max(hi) } else { b }
    // (found again as its keys changed (the column filled again since they were found): an end of the slots that still
    // holds as it is kept where it was, so a key come or gone costs its own slot alone, not those at an end found anew
    // a screen round what shows; each end as `covered` holds it. Found again as it was scrolled, both ends found anew
    // round what shows, as narrow as the margin)
    let (a, b) = match (cur.get(0), cur.last()) {
      (Some(f), Some(l)) if vh > 0.0 && hi >= 0 && found_at is None =>
        match (laid_at.get(f), laid_at.get(l)) {
          (Some(i), Some(j)) if i <= j && j < n => {
            let top_holds = i <= lo &&
              (i == 0 || all.top(i) <= top - slots_near * vh) &&
              (i == lo || all.top(i) + all.h(i) >= top - slots_far * vh)
            let foot_holds = hi <= j &&
              (j == n - 1 || all.top(j) + all.h(j) >= top + vh + slots_near * vh) &&
              (j == hi || all.top(j) <= top + vh + slots_far * vh)
            (if top_holds { i } else { a }, if foot_holds { j } else { b })
          }
          _ => (a, b)
        }
      _ => (a, b)
    }
    // (a block put by in a slot that leaves them: taken out of it, held by no node, as it is let go)
    for _, those in spare {
      for i, sp in those {
        match sp {
          (v, key, wake, Some(was_in)) => {
            // (its key still among the keys and out of those kept: parked; gone from the list, let go with its slot,
            // as were every slot kept)
            let at = laid_at.get(key.untracked())
            if at is Some(j) && (j < a || j > b) && v.alive() {
              was_in.park(v, rest=false) |> ignore
              those[i] = (v, key, wake, None)
            }
          }
          _ => ()
        }
      }
    }
    let ks = []
    for i in a..=b {
      ks.push(all.key(i))
    }
    keep_leaving(ks)
    slots_found.val = if a <= b { Some((all.col, all.col.refills, a)) } else { None }
    slot_keys.set(ks)
  }
  seen_before.val = fn(col) {
    @signals.untracked(fn() {
      let out = []
      guard s.seen.get() is Some((_, vh)) && vh > 0.0 && !shown_now.is_empty() else { return out }
      let all = places(col)
      let top = if s.at_foot() { foot_top(all, vh) } else { top_now(all, at()) }
      for k in shown_now {
        if laid_at.get(k) is Some(i) && i < all.length() {
          out.push((k, i, all.top(i) - top))
        }
      }
      out
    })
  }
  // Rows kept for the far end of a way do not cover a gap between them and what shows now.
  let made_now = fn(all : Places[Int], visible : Array[Int]) {
    made_rev.val = laid_rev.val
    guard visible.get(0) is Some(k) && laid_at.get(k) is Some(i) else {
      made.set((@double.neg_infinity, @double.infinity, @double.neg_infinity, @double.infinity))
      return
    }
    let mut j = i
    for k in visible[1:] {
      guard laid_at.get(k) == Some(j + 1) else { break }
      j += 1
    }
    made.set((
      if i == 0 { @double.neg_infinity } else { all.top(i) },
      all.top(i) + all.h(i),
      all.top(j),
      if j == all.length() - 1 { @double.infinity } else { all.top(j) + all.h(j) },
    ))
  }
  // (which show where the column shows from `top`, `vh` tall, by where they are counted: going out from those whose
  // place is sure, `lo` to `hi` (what was seen and still shows, or the one the column is held by), up and down
  // while one meets where it shows. One never measured is as far as it goes that way till it is measured: where those
  // past it start is known only then; what is sure stays made whatever comes in over it or under it. `up_first`: the
  // first of them is sure by its top (those over it sure too, measured or not); else by its foot. None sure (`lo`
  // past `hi`): from the first that meets it down, as far as the first never measured. Whether it stopped so short of
  // what shows, one past the one never measured it stopped at meeting where it shows as they are counted:
  // `window_short`.)
  let window = fn(all : Places[Int], top : Double, vh : Double, lo : Int, hi : Int, up_first : Bool) -> Array[Int] {
    let now = []
    window_short.val = false
    // (whether `i` meets where it shows, as it is counted)
    let meets = fn(i : Int) { i >= 0 && i < all.length() && all.top(i) + all.h(i) > top && all.top(i) < top + vh }
    // (showing none of it, a page under another: none made, the one it is held by neither, what it reads let go)
    if vh <= 0.0 {
      window_found.val = (now, 0, -1)
      return now
    }
    if lo > hi {
      let first = all.first_past(top)
      let mut i = first
      let mut last = first - 1
      while i < all.length() && all.top(i) < top + vh {
        now.push(all.key(i))
        last = i
        if !all.known(i) {
          window_short.val = meets(i + 1)
          break
        }
        i = i + 1
      }
      window_found.val = (now, first, last)
      return now
    }
    let mut a = lo
    if all.known(lo) || up_first {
      let mut i = lo - 1
      while i >= 0 && all.top(i) + all.h(i) > top {
        a = i
        if !all.known(i) {
          window_short.val = meets(i - 1)
          break
        }
        i = i - 1
      }
    } else {
      window_short.val = meets(lo - 1)
    }
    let mut b = hi
    if all.known(hi) {
      let mut i = hi + 1
      while i < all.length() && all.top(i) < top + vh {
        b = i
        if !all.known(i) {
          window_short.val = window_short.val || meets(i + 1)
          break
        }
        i = i + 1
      }
    } else {
      window_short.val = window_short.val || meets(hi + 1)
    }
    for i in a..=b {
      now.push(all.key(i))
    }
    // (past one never measured, come in among those that show: those made under it that meet where it shows as they
    // are counted kept made, not let go to be made again once it is measured; where they are is worked out then, and
    // they go only if it puts them out of sight)
    let mut last = b
    if !all.known(b) {
      let mut i = b + 1
      while i < all.length() && all.top(i) < top + vh {
        if showing.contains(all.key(i)) {
          now.push(all.key(i))
          last = i
        }
        i = i + 1
      }
    }
    window_found.val = (now, a, last)
    now
  }
  // (whether what came among its keys by data or went since its fill last ran, said to come, may make its way: told so
  // as the change goes on (View::each's way_of), its fill then showing what shows from where that way sets out)
  let way_may = fn() { gone_from.val.length() > 0 || came_by_data.val.length() > 0 }
  // (while a block is on its way: those that show where all of it ends, from `top_end`, with those that show `now`, in
  // their order: what shows from where the way set out to where it ends kept made till it ends, let go then)
  let with_end = fn(all : Places[Int], now : Array[Int], top_end : Double, vh : Double) -> Array[Int] {
    guard !ways.is_empty() else { return now }
    let more = window(counted(all.col), top_end, vh, all.length(), -1, true).filter(fn(k) { !now.contains(k) })
    guard more.length() > 0 else { return now }
    let both = now.copy()
    both.append(more)
    both.sort_by_key(fn(k) { laid_at.get(k).unwrap_or(-1) })
    both
  }
  // Scrolled so that one more meets where it shows, or the first or the last made no more does, or the blocks counted
  // otherwise (come, gone, moved or measured anew), what meets it is shown at once by where the blocks are counted, the
  // rest put by: nothing laid out but the slot of each that comes, alone
  // (the slot as tall as it is counted, shown or not). Where that comes out another height than it is counted, the
  // column is laid out (Tree::alone_asks), and its fill measures it there. What is made is what shows, no more. Told
  // only as a row meets or leaves what shows, or while the viewport still extends beyond the window.
  let window_top = fn(all : Places[Int], x : Double, vh : Double) {
    if s.at_foot() { foot_top(all, vh) } else { top_now(all, x) }
  }
  let past_made_at = fn(x : Double, vh : Double, bounds : (Double, Double, Double, Double)) {
    let (lo, first_end, last_top, hi) = bounds
    x < lo || x + vh > hi || x >= first_end || x + vh <= last_top
  }
  let past_made = @signals.computed(fn(_) {
    guard s.seen.get() is Some((_, vh)) && vh > 0.0 else { return None }
    let x = at()
    let bounds = made.get()
    let all = laid.get()
    let top = @signals.untracked(fn() { window_top(places(all), x, vh) })
    if past_made_at(top, vh, bounds) { Some(top) } else { None }
  })
  let row_ready = fn(k) { showing.contains(k) && heights.contains(k) }
  let coverage_due = Ref(false)
  // The fill normally measures its way out to both edges in one pass. Bound retries if it cannot make progress.
  let coverage_passes = Ref(0)
  let check_coverage = fn() {
    guard self.alive() && !coverage_due.val else { return }
    coverage_due.val = true
    @signals.after_flush(fn() {
      guard self.alive() else { return }
      self.tree.once_laid_out(fn() {
        coverage_due.val = false
        guard self.alive() else { return }
        guard s.seen.untracked() is Some((_, vh)) && vh > 0.0 else {
          coverage_passes.val = 0
          return
        }
        let all = places(laid.untracked())
        let x = window_top(all, @signals.untracked(at), vh)
        if coverage_passes.val < 4 &&
          (made_rev.val != laid_rev.val ||
          past_made_at(x, vh, made.untracked()) ||
          shown_now.iter().any(fn(k) { !row_ready(k) })) {
          coverage_passes.val += 1
          laid_again()
        } else {
          coverage_passes.val = 0
        }
      })
    })
  }
  self.reacts(fn() {
    laid.get() |> ignore
    (past_made.get(), laid_rev.val)
  }, fn(now) {
    let (out, _) = now
    guard s.seen.untracked() is Some((_, vh)) && vh > 0.0 else { return }
    // A reach measurement can tell a new offset in its final round. Settle it after leaving the room.
    if self.tree.rooming == self.at {
      if out is Some(_) || made_rev.val != laid_rev.val {
        check_coverage()
      }
      return
    }
    // (put at its foot: where that is the column's layout says, its fill making what shows there)
    if s.at_foot() {
      // (and where the keys changed under its slots (one come at its end, put in or taken among them): its slots
      // brought up to them now, as the change is taken, by where what shows is at its foot, before the column is laid
      // out, so that one layout lays out what comes and its fill measures it there; else a key come among what shows had
      // no slot, none drawn)
      let all = places(laid.untracked())
      let stale = match slots_found.val {
        Some((col, at, _)) => !physical_equal(col, all.col) || at != all.col.refills
        // (none found: slots there for no keys, or keys there with no slots, the first come to a list that had none)
        None => slot_keys.untracked().length() > 0 || all.length() > 0
      }
      let changed = if stale {
        let top = foot_top(all, vh)
        let visible = window(all, top, vh, all.length(), -1, true)
        slots_cover(all, visible, top, vh)
        visible != shown_now
      } else {
        false
      }
      if changed || out is Some(_) {
        laid_again()
      }
      return
    }
    let all = places(laid.untracked())
    // (its keys changed by data with what may make its way among them (way_of, told as the change goes on): what is
    // made let go of none yet, its fill, laid out in the change, showing what shows from where that way sets out)
    if way_may() {
      // (its slots brought up to its keys in this pass all the same, round what shows by where it is counted now and
      // what showed, so a key come there has the slot its way is made on)
      let x = top_now(all, @signals.untracked(at))
      let keep = window(all, x, vh, all.length(), -1, true).copy()
      for k in shown_now {
        if laid_at.contains(k) && !keep.contains(k) {
          keep.push(k)
        }
      }
      slots_cover(all, keep, x, vh)
      laid_again()
      return
    }
    let x = top_now(all, @signals.untracked(at))
    // (what was seen and still meets where it shows is sure where it is: kept, what comes in going out from it)
    let mut lo = all.length()
    let mut hi = -1
    for k in shown_now {
      guard seen_rows.contains(k) && laid_at.get(k) is Some(i) && i < all.length() else { continue }
      if all.top(i) + all.h(i) > x && all.top(i) < x + vh {
        lo = lo.min(i)
        hi = hi.max(i)
      }
    }
    let visible = window(all, x, vh, lo, hi, true)
    let now = with_end(all, visible, top_now(counted(all.col), @signals.untracked(at)), vh)
    show_only(now)
    slots_cover(all, now, x, vh)
    made_now(all, visible)
    // A window cut short at an unmeasured row needs a fill even if its slot was already there.
    if past_made.untracked() is Some(_) {
      laid_again()
    } else if shown_now.iter().any(fn(k) { !showing.contains(k) }) {
      check_coverage()
    }
    // (those come in not seen yet: seen as they are laid out, Tree::alone_asks)
    let still = seen_rows.keys().filter(fn(k) { !now.contains(k) }).collect()
    for k in still {
      seen_rows.remove(k)
    }
  })
  // Its fill, as the column is laid out (View::scrolls' fill), in that layout: given how wide it is and how tall it
  // shows, the scroll's move since carried to the anchor (or the block `centres` names brought to the middle, or its
  // foot where it follows it there), what meets where it shows made (each by its key, in its slot) and measured at that
  // width, its height counted, the anchor kept where it was as what is over it comes out otherwise, again till what
  // shows is all measured and none of it comes out otherwise; then the scroll put where the anchor says.
  let last_h : Ref[(Double?, Double)?] = Ref(None)
  s.fill = fn(w, h, performing) {
    // (how tall it shows as last told, where this fill is told none: one again in the same layout)
    let h = match h {
      Some(_) => {
        last_h.val = h
        h
      }
      None => last_h.val
    }
    match w {
      Some(w) =>
        if performing {
          room_w.set(Some(w))
        }
      None => ()
    }
    let shows = fn() {
      match h {
        Some((Some(exact), _)) => Some(exact)
        Some((None, most)) => Some(dmin(whole_now(), most))
        None => None
      }
    }
    // (blocks made and measured as it is laid out, at the width it is laid out at: not for a room it is only measured
    // in first, which would count them at another)
    guard performing && room_w.untracked() is Some(w) else {
      self.tree.room_bindings_run()
      return
    }
    let x = @signals.untracked(at)
    // (on its glide back to its foot (ListPlace::to_end), or come to the end of it, not stopped by another way: what it
    // moved by since is the glide's, not the reader's, and a limit said meanwhile stands, the glide ending where it
    // holds it (glide_limit), held there as it lands)
    let (on_end_glide, glide_landed) = match (end_glide.val, s.notch.untracked()) {
      (Some(g), Some(n)) if physical_equal(g, n) => (true, false)
      (Some(_), None) => (false, s.is_notch_landed())
      _ => (false, false)
    }
    // (a limit said anew where the one before held it, not moved by the reader since: following its foot still, back at
    // it first, the new one holding it from there: ListPlace::follow_from)
    let refollow = match place {
      Some(p) if p.from_new => {
        p.from_new = false
        @signals.untracked(capped_now)
      }
      _ => false
    }
    if refollow {
      s.to_foot()
    }
    // (held where it is at its foot (Scroll::holds_here): not following it, the anchor it had holding what shows; blocks
    // come or gone since, nothing having opened: followed again)
    if s.held && s.at_foot() {
      let ks = @signals.untracked(keys)
      if held_with.val != (ks.length(), ks.last()) {
        s.held = false
      }
    }
    let row = self.tree.row_focus_holds(self.id())
    let row_holds = row is Some(n) && n != row_let.val
    if !row_holds {
      row_hand_moved.val = false
    }
    let mut held = (s.held || row_holds) && s.at_foot()
    let mut follows_foot = @signals.untracked(follows) && s.at_foot() && !held
    // (the anchor as the scroll moved it since; none yet, where the scroll is)
    let start = {
      let all = places(laid.untracked())
      let fresh = fn() {
        let i = all.first_past(x)
        if i < all.length() {
          (i, x - all.top(i))
        } else {
          (all.length() - 1, 0.0)
        }
      }
      match (held_at(all), anchor_x.val) {
        // (held at its foot: where it was put, the scroll saying nothing of a move)
        (Some((i, off)), Some(_)) if held => (i, off)
        (Some((i, off)), Some(was)) => (i, off + (x - was))
        _ => fresh()
      }
    }
    let mut ai = start.0
    let mut aoff = start.1
    // (held by where what is read in it starts (View::read_from): that start as it was put, read anew as each pass of
    // this fill lays it out, the anchor moved with it; none where it is held by its top, or taken again below)
    let mut s0 = if anchor_x.val is Some(_) { held_start(places(laid.untracked())) } else { None }
    let mut read_moved = false
    let glided = glided_foot.val
    glided_foot.val = false
    // (moved by the hand, the wheel or a fling since: the anchor taken again where it is now, by what is counted now,
    // before what comes to show is measured; not moved, the one it had, whatever came or went over it)
    match anchor_x.val {
      Some(was) if !held && !glided && !refollow && (x - was).abs() > 0.000001 => {
        // (moved by the hand: held where it was no more, nor by what was pressed; held by a field in a row, let go
        // of as the hand brings it back to its foot; an ask this list put back as it was cut short by its foot still
        // going down let go of, the list where the hand put it: not one its page gave anew)
        s.held = false
        // (a limit its foot was followed by let go of: the reader took the list, to its foot or not; not the glide back
        // to its foot, which ends where the limit holds it)
        match place {
          Some(p) if !on_end_glide && !glide_landed => p.from = None
          _ => ()
        }
        match (place, ask_cut_was.val) {
          (Some(p), Some(was)) if ask_cut.val && p.asked is Some(a) && physical_equal(a, was) => {
            p.asked = None
            ask_cut.val = false
            ask_cut_was.val = None
          }
          _ => ()
        }
        if row_holds {
          row_hand_moved.val = true
        }
        if (x - pin_x.val).abs() > 0.000001 {
          pin.val = None
          (unpin.val)()
        }
        // (taken off its foot: the column held no more, the room as it is, going as it is scrolled off)
        if floor.val is Some(_) && !s.at_foot() {
          (floor_end.val)()
        }
        let all = places(laid.untracked())
        s0 = None
        read_moved = true
        if all.length() > 0 {
          let i = ai.min(all.length() - 1).max(0)
          let at_now = all.top(i) + aoff
          let j = holding(all, all.first_past(at_now).min(all.length() - 1))
          // (what was seen and still shows holding it, before one come to show: what comes in over it measured
          // otherwise than it was counted moves what was seen none, the column moved with it instead)
          let vh = match shows() {
            Some(vh) => vh
            None => 0.0
          }
          let mut seen = j
          while seen < all.length() &&
                all.top(seen) < at_now + vh &&
                !(seen_rows.contains(all.key(seen)) && holds(all.key(seen))) {
            seen = seen + 1
          }
          let j = if seen < all.length() && all.top(seen) < at_now + vh { seen } else { j }
          ai = j
          aoff = at_now - all.top(j)
          // (where a block marks what is read in it: the first whose start showed, as the list was last laid out, under
          // what covers its top where the hand left it, held by that start from there: what comes or goes in this fill
          // over it moves none of it)
          if !marks.is_empty() {
            let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
            let mut q = all.first_past(at_now + cover).min(all.length() - 1)
            let mut got = false
            while !got && q < all.length() && all.top(q) < at_now + vh - under {
              if all.known(q) && holds(all.key(q)) {
                match start_laid_of(all, q) {
                  Some(sq) if all.top(q) + sq >= at_now + cover - 0.001 && all.top(q) + sq < at_now + vh - under => {
                    ai = q
                    aoff = at_now - all.top(q)
                    s0 = Some(sq)
                    got = true
                  }
                  _ => ()
                }
              }
              q = q + 1
            }
          }
        }
      }
      _ => ()
    }
    // (a block asked to be brought to the middle or its top (ListPlace), once, as soon as it is among its keys: its
    // middle there as tall as it is counted; off its foot then)
    let mut centring = false
    // (asked to bring what a block holds of a go-to's before the eyes too (ListPlace::bring's `sought`): how much further
    // down than its top's place it is put so far in this fill, worked out anew in each pass as the block is measured)
    let mut seeking = false
    let mut sought_by = 0.0
    // (asked to put what a block marks sought this far under what covers its top: ListPlace::bring_sought)
    let mut sought_under : Double? = None
    let mut to_end = false
    // (asked: put there, what it was on by itself stopped; else moved by as much as the anchor says)
    let mut asked = false
    // (the place's ask taken in this fill, as it was asked: put back at its end where this fill could not make what
    // shows, below)
    let mut taken : ListAsk[Int]? = None
    match place {
      Some(p) =>
        match p.asked {
          Some(ToEnd) => {
            p.asked = None
            if p.jumped_to_end {
              p.jumped_to_end = false
              jumped_at.val = self.tree.cause_now()
            }
            taken = Some(ToEnd)
            if row is Some(n) {
              row_let.val = n
              row_hand_moved.val = false
            }
            to_end = true
            asked = true
          }
          Some(ask) => {
            let (k, off) = match ask {
              Bring(k, off, seek) => {
                seeking = seek
                (k, Some(off))
              }
              BringSought(k, under) => {
                seeking = true
                sought_under = Some(under)
                (k, Some(0.0))
              }
              Centre(k) => (k, None)
              ToEnd => panic()
            }
            match laid_at.get(k) {
              Some(i) => {
                p.asked = None
                taken = Some(ask)
                asked = true
                ai = i
                follows_foot = false
                match off {
                  // (from under what covers its top: as far under that edge as `off` says, as what is in sight
                  // tells `into`)
                  Some(off) => aoff = off - @signals.untracked(fn() { s.top_covered() })
                  None => centring = true
                }
              }
              None => ()
            }
          }
          None => ()
        }
      None => ()
    }
    // (asked to show a block or its foot: held where it was no more)
    if asked {
      s.held = false
      held = false
    }
    // (what was pressed let go: held by the nearest of what held it still there, what lay over it under that let go
    // with it and no longer counted)
    match (pin.val, pin_node.val) {
      (Some((_, _, over, _)), Some(v)) if !v.alive() =>
        match pin_up.val.iter().find_first(fn(u) { u.0.alive() }) {
          Some((a, from, under)) if from <= over.length() => {
            over.drain(0, from) |> ignore
            pin_less.val = under
            pin_node.val = Some(a)
            pin_up.val = pin_up.val
              .filter(fn(u) { u.1 >= from })
              .map(fn(u) { (u.0, u.1 - from, u.2 - under) })
          }
          _ => ()
        }
      _ => ()
    }
    match (pin.val, pin_node.val) {
      (Some((_, _, over, _)), Some(v)) if !v.alive() || over.iter().any(fn(o) { !o.alive() }) => {
        pin.val = None
        (unpin.val)()
      }
      _ => ()
    }
    if pin.val is Some(_) && pin_foot.val && !asked {
      let ks = @signals.untracked(keys)
      if pin_with.val != (ks.length(), ks.last()) {
        pin.val = None
        (unpin.val)()
        s.to_foot()
        // (held by a field in a row: held where it is at its foot from now, not followed)
        follows_foot = !row_holds
        held = row_holds
      }
    }
    // (held by what was pressed in a block: neither following its foot nor held at it meanwhile)
    if !asked && pin.val is Some((k, _, _, _)) && laid_at.contains(k) {
      follows_foot = false
      held = false
    }
    // (its foot followed no further than a block's top `margin` under what covers its top: held there, off its foot,
    // once it would go further, and followed no further after)
    // (held at its foot by a field in a row, the room it shows in another than as it was last so held: what shows held
    // from that room's foot, at its foot still)
    if held && row_holds && !s.held {
      let vh_now = shows().unwrap_or(0.0)
      if row_vh.val > 0.0 && vh_now > 0.0 {
        aoff = aoff + (row_vh.val - vh_now)
      }
    }
    // (a standing limit: its key met among the keys, gone from them after that, the limit with it)
    let from = match place {
      Some(p) =>
        match p.from {
          Some((k, margin)) =>
            match laid_at.get(k) {
              Some(i) => {
                p.from_met = true
                Some((i, margin))
              }
              None => {
                if p.from_met {
                  p.from = None
                  p.from_met = false
                }
                None
              }
            }
          None => None
        }
      None => None
    }
    let was_capped = @signals.untracked(capped_now)
    let mut binds = false
    // (where a limit that stands holds it as it glides back to its foot: that glide's end, fill_put)
    let mut glide_limit : Double? = None
    let mut top = 0.0
    let mut vh = 0.0
    let mut again = true
    let measured : Map[Int, Bool] = Map([])
    // (the blocks an ask's place spanned, unknown, a pass gone out from each: the fill's `spans_unknown`)
    let spanned : Map[Int, Bool] = Map([])
    // (what showed as this layout began, kept made while it still measures: a pass that finds what shows otherwise for
    // one never measured (the appended one at its foot, as tall as `est` till it is measured, all that shows by itself)
    // lets none of it go, to make it again a pass later; what shows no more let go once, after the last pass)
    let showed = shown_now.copy()
    let mut found : Array[Int] = []
    let mut visible : Array[Int] = []
    while again {
      again = false
      fill_passes.val = fill_passes.val + 1
      // (its head and its foot measured as the blocks are, at its width, in this layout: the head's height where its
      // keys start, the foot's the room under them. The head grown or shrunk where what shows starts in it or at its
      // very top: what shows starting there still, what is under it moved with it; else what is read where it is)
      match head_v.val {
        Some(hv) if hv.alive() => {
          let hh = rows_slot_on(self.tree.height_in(hv.at, self.at, w), self.tree.rows_grid_now())
          if hh != column.start {
            let was = places(laid.untracked())
            if was.length() > 0 {
              let i = ai.min(was.length() - 1).max(0)
              let shown_from = was.top(i) + aoff
              if shown_from < column.start || shown_from <= 0.0 {
                aoff = aoff - (hh - column.start)
              }
            }
            column.start_at(hh)
            head_tall.set(hh)
            tell()
          }
        }
        _ => ()
      }
      match foot_v.val {
        // (the foot's on the host's pixels as the head's is, the one reading of the room under the last block: the foot
        // placed that tall, so its top lies where the last block ends)
        Some(fv) if fv.alive() => {
          let fh = rows_slot_on(self.tree.height_in(fv.at, self.at, w), self.tree.rows_grid_now())
          s.foot_tall = fh
          foot_h.set(fh)
        }
        _ => ()
      }
      let all = places(laid.untracked())
      vh = shows().unwrap_or(0.0)
      if all.length() == 0 {
        found = []
        show_only([])
        top = 0.0
        break
      }
      // (a block brought to the middle: by its height as it is counted now, measured or not, again as it is measured)
      ai = ai.min(all.length() - 1).max(0)
      // (held by what was pressed in a block: the block's top as far up as what lies over what was pressed grew since,
      // the room under its foot as that asks)
      let mut pressed_holds = false
      if !asked && pin.val is Some((k, below, over, was)) && laid_at.get(k) is Some(i) && i < all.length() {
        ai = i
        pressed_holds = true
        aoff = over_h(over) - (was - pin_less.val) - below
        foot_room.set(dmax(0.0, all.top(i) + aoff + vh - blocks_foot(all)))
      } else if floor.val is Some((lk, e0)) {
        // (a key come at its foot: the stretch from the last that stayed as long as it was, it and what is under it and
        // the foot as they show now)
        match laid_at.get(lk) {
          Some(i) if i < all.length() => foot_room.set(dmax(0.0, e0 - (blocks_foot(all) - all.top(i))))
          _ => (floor_end.val)()
        }
      }
      if centring {
        // (its middle at the middle of what shows between what covers its top and its pinned foot's top)
        let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
        aoff = counted(laid.untracked()).h(ai) / 2.0 - (cover + vh - under) / 2.0
      }
      if seeking {
        // (what it holds of a go-to's, low in what shows with its top where it is brought (its middle past 80% of what
        // shows between what covers its top and its pinned foot's top): its middle at the middle of that instead;
        // the block's top shows `-aoff` under the list's top: list_sought.mbt)
        aoff = aoff - sought_by
        sought_by = 0.0
        match (sought_of(all, ai), sought_under) {
          // (its top `lead` under what covers the list's top, wherever it lies)
          (Some((y0, _)), Some(lead)) => {
            let cover = @signals.untracked(fn() { s.top_covered() })
            sought_by = y0 - cover - lead - aoff
            aoff = aoff + sought_by
          }
          (Some((y0, y1)), None) => {
            let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
            let mid = (y0 + y1) / 2.0
            if -aoff + mid > cover + 0.8 * (vh - under - cover) {
              sought_by = mid - (cover + vh - under) / 2.0 - aoff
              aoff = aoff + sought_by
            }
          }
          (None, _) => ()
        }
      }
      let most = dmax(0.0, whole_now() - vh)
      // (what is read in it where it starts now, held there: what came or went over that start in it moves none of it)
      let moved = match s0 {
        Some(was) if !asked && !pressed_holds && !centring =>
          match start_of(all, ai) {
            Some(now) => now - was
            None => 0.0
          }
        _ => 0.0
      }
      top = if follows_foot || to_end { most } else { dclamp(all.top(ai) + aoff + moved, 0.0, most) }
      // (its margin under what covers its top, as a block brought is: ListPlace::follow_from)
      let from_edge = fn(margin : Double) { margin + @signals.untracked(fn() { s.top_covered() }) }
      binds = false
      glide_limit = None
      match from {
        // (on its glide back to its foot: where it holds it, the glide's end; what shows where the glide has it now)
        Some((i, margin)) if on_end_glide && !asked && i < all.length() && all.top(i) - from_edge(margin) < most =>
          glide_limit = Some(dmax(0.0, all.top(i) - from_edge(margin)))
        _ => ()
      }
      match from {
        Some((i, margin)) if (follows_foot || was_capped || glide_landed) &&
          !asked &&
          i < all.length() &&
          all.top(i) - from_edge(margin) < most => {
          top = dmax(0.0, all.top(i) - from_edge(margin))
          follows_foot = false
          // (held by it while it binds, as it is measured anew in this fill too)
          ai = i
          aoff = -from_edge(margin)
          binds = true
        }
        _ => ()
      }
      // (what meets where it shows, made, going out from the one it is held by, or from its last at its foot: one
      // never measured as it is measured, those past it only once it is, where they start known then; none that was
      // made and still shows let go for one come in over it)
      let foot = follows_foot || to_end
      let mut spans_unknown = false
      let si = if foot {
        // (at its foot, from the last measured that meets where it shows: those come under it, never measured, made
        // as it goes down to them, what showed over them kept made. Gone out from its last alone, one come at its foot
        // and not measured yet showed alone, every block in sight let go and made again once it was measured: a job's
        // output following its end made every line it showed again for each line more, 2026-11-11)
        let mut i = all.length() - 1
        let mut from = all.length() - 1
        while i >= 0 && all.top(i) + all.h(i) > top {
          if all.known(i) {
            from = i
            break
          }
          i = i - 1
        }
        from
      } else if pressed_holds || (all.top(ai) + all.h(ai) > top && all.top(ai) < top + vh) {
        // (held by what was pressed in it, the block shows by that alone, where what is over that comes to now: what
        // shows goes out from it, never found by its place as counted at the last layout. As tall as it was then, what
        // it opened over the pressed grown since by more than a screen (no frame for 88 ms) put it off what shows: let
        // go, made anew, what it had opened shut, 2026-11-12. Made, it is measured in this pass and those round it
        // found again by where it ends now)
        ai
      } else {
        let past = all.first_past(top).min(all.length() - 1)
        // (asked to bring a block with the place under it as far down as past its own foot (a long message's first
        // piece and how far down the whole of it the reader was: a place kept whole, or the core's), and blocks between
        // it and where that comes to never measured: where that is, is known only once they are. From the first of them,
        // a pass again as each is measured, till the place falls where it was meant; once all are known, from where it
        // shows as ever, nothing more for it)
        let mut unknown = -1
        if asked && all.top(ai) + all.h(ai) <= top {
          let mut q = ai
          while q <= past && all.top(q) <= top {
            // (once each in a fill: one that stays unknown measured is no reason for another pass)
            if !all.known(q) && !spanned.contains(q) {
              spanned[q] = true
              unknown = q
              break
            }
            q = q + 1
          }
        }
        if unknown >= 0 {
          spans_unknown = true
          unknown
        } else {
          past
        }
      }
      let now = window(all, top, vh, si, si, !foot && !centring)
      visible = now
      let mut short = window_short.val || spans_unknown
      // (a block on its way: what shows where all of it ends as well, kept made till then; stopped short there too, at
      // one never measured, a pass again as well)
      let now = if !ways.is_empty() {
        let end = counted(all.col)
        let most_end = dmax(0.0, whole_of(end) - vh)
        let both = with_end(
          all,
          now,
          if foot { most_end } else { dclamp(end.top(ai) + (top - all.top(ai)), 0.0, most_end) },
          vh,
        )
        short = short || window_short.val
        both
      } else {
        now
      }
      found = now
      // (most often what showed is what shows: nothing to add, nothing told)
      if now == showed {
        show_only(now)
      } else {
        let kept = now.copy()
        let t_now = self.tree.cause_now()
        let fw = flip_way.untracked()
        for k in showed {
          if laid_at.get(k) is Some(i) && i < all.length() && !kept.contains(k) {
            let ltop = all.top(i)
            let lh = all.h(i)
            let in_laid = ltop + lh > top && ltop < top + vh
            let in_drawn = match (fw, flip_items.get(k)) {
              (Some(w), Some(it)) => {
                let (_, dy, _, dh) = w.drawn(it, t_now).0
                let dtop = ltop + dy
                let dh_now = dmax(0.0, lh - dh)
                dtop + dh_now > top && dtop < top + vh
              }
              _ => false
            }
            if in_laid || in_drawn {
              kept.push(k)
            }
          }
        }
        show_only(kept)
        // (what the pass found shows: those drawn on a way kept with it, never let go by its end for where they go)
        found = kept
      }
      slots_cover(all, now, top, vh)
      self.tree.room_bindings_run()
      // (each that shows measured, once in this fill, its height counted where it came out otherwise. One never measured
      // that comes out as tall as it was counted, on the host's pixels, moves nothing: every block is where this pass put
      // it, its height told and the column counting it measured, no pass again for it; but where the window stopped
      // short of what shows at one never measured (those past it made only once it is measured), or the block it is
      // held by is measured first (what it marks, what a go-to brings in it, read only once it is made), a pass again
      // all the same)
      let g = self.tree.rows_grid_now()
      let held_key = all.key(ai)
      let mut told_only = false
      for b in blocks.filter(fn(b) { b.0.alive() }) {
        let (v, key) = b
        let k = @signals.untracked(key)
        guard showing.contains(k) && !measured.contains(k) else { continue }
        measured[k] = true
        let bh = self.tree.height_in(v.at, self.at, w)
        if heights.get(k) != Some(bh) {
          let first = heights.get(k) is None
          heights[k] = bh
          heights_changed.push(k)
          if tall.get(k) is Some(c) {
            c.set(Some(bh))
          }
          if first && rows_slot_on(bh, g) == rows_slot_on(est, g) && k != held_key {
            told_only = true
          } else {
            again = true
          }
        }
      }
      if told_only && short {
        again = true
      }
      if again || told_only {
        tell()
        self.tree.room_bindings_run()
      }
    }
    capped.set(binds)
    if pin_ends.val {
      pin_ends.val = false
      pin.val = None
    }
    // (held by what was pressed no more: the room kept for it no more than still shows)
    if !(pin.val is Some((k, _, _, _)) && laid_at.contains(k)) {
      let left = dmax(0.0, top + vh - blocks_foot(places(laid.untracked())))
      if left < foot_room.untracked() {
        foot_room.set(left)
      }
    }
    // (an ask is taken only by a fill that could make what shows: one laid out where what shows could not be made in it
    // (its slots not made yet: a layout asked inside a change's open batch, as a structure's first making reads where
    // something is laid out, View::laid_window_now) measures nothing, and what it put would be held by a block only
    // counted. The ask put back, unless another came meanwhile: the next fill takes it anew, the block it asks for held
    // through every pass as what shows is made and measured)
    // So too one that could not put the list where it asks: the place it gives cut short by a foot still to go down
    // (what comes under it on its way: where all of it ends, the list goes further than it does now), the next fill
    // taking it anew, each going down with its foot till the block asked is where it was asked; taken for good by the
    // first not cut short, or cut only where the list ends (asked further than it ever goes: at its foot, done)
    let cut = match taken {
      // (back to its foot, where it does not follow it: its foot where all of it ends, further than it is now, the next
      // fill taking it anew as that way goes)
      Some(ToEnd) =>
        !@signals.untracked(follows) && dmax(0.0, whole_of(counted(laid.untracked())) - vh) > top + 0.5
      None => false
      Some(_) => {
        let all = places(laid.untracked())
        if all.length() == 0 {
          false
        } else {
          let i = ai.min(all.length() - 1).max(0)
          let wants = all.top(i) + aoff
          let ends = dmax(0.0, whole_of(counted(laid.untracked())) - vh)
          // (or its pinned foot not laid out as tall as it is yet (foot_unbuilt): where it ends is not known, and the
          // block asked further down than the list goes now may well be put there once it is)
          wants > top + 0.5 && (ends > top + 0.5 || foot_waiting())
        }
      }
    }
    ask_cut.val = false
    match (taken, place) {
      (Some(ask), Some(p)) if p.asked is None &&
        (cut || found.iter().any(fn(k) { !showing.contains(k) })) => {
        p.asked = Some(ask)
        ask_cut.val = cut
        ask_cut_was.val = if cut { Some(ask) } else { None }
      }
      (Some(_), _) =>
        // (what it has in sight owed as of then, told once this layout is done: ListPlace::on_sight)
        self.tree.sight_owe(self.tree.logic_said())
      _ => ()
    }
    // (keys come at its end, in the fill that has them measured (noted till then, room or none): from as tall as all
    // that change gave back under L's top, taken in their order, each never taller than itself, only ever raised)
    match one_move_key.val {
      Some((lk, kks, under, cause)) => {
        let rows = kks.map(fn(k) { (came_row.get(k), heights.get(k)) })
        // (its foot holding an old view not built since the cause: noted for the fill after it is, or before the
        // frame is painted, whichever is first: one_move_builds)
        let foot_waits = !one_move_free.val &&
          self.tree.old_builds <= one_move_builds.val &&
          (match foot_v.val {
            Some(fv) => fv.alive() && self.tree.holds_hosted(fv.at)
            None => false
          })
        if rows.iter().any(fn(r) { r.0 is Some(row) && row.alive() && r.1 is None }) {
          // (a row made, not measured yet: noted for the fill that measures it)
          ()
        } else if foot_waits {
          if one_move_e0.val is None {
            one_move_e0.val = match floor.val {
              Some((fk, e)) if fk == lk => Some(e)
              _ => None
            }
          }
          fn wait_old_move(settled : Bool) -> Unit {
            if !settled && self.tree.old_builds <= one_move_builds.val {
              self.tree.old_built_waits.push(wait_old_move)
            } else {
              one_move_free.val = true
              laid_again()
            }
          }
          self.tree.old_built_waits.push(wait_old_move)
        } else {
          one_move_key.val = None
          came_row.clear()
          let all = places(laid.untracked())
          let held_e0 = one_move_e0.val
          one_move_e0.val = None
          match (floor.val, laid_at.get(lk)) {
            (Some((fk, e0)), Some(i)) if fk == lk && i < all.length() => {
              // (waited for an old view's build: the floor put back to what it held at the cause, not what the fills
              // since raised it to by the key's way set out from none meanwhile, which no frame drew)
              let e0 = match held_e0 {
                Some(e) => {
                  floor.val = Some((fk, e))
                  e
                }
                None => e0
              }
              // (less what stays under the keys come, as tall as it is now: it keeps its place against the column's end)
              let mut stays = 0.0
              for u in under {
                match laid_at.get(u) {
                  Some(ui) if ui < all.length() => stays = stays + all.h(ui)
                  _ => ()
                }
              }
              let mut given = e0 - all.h(i) - stays - room_under() - s.tuck_room.untracked()
              let tree = self.tree
              let groups : Array[@flex.ComeGroup] = []
              for r in rows {
                guard r is (Some(row), Some(h)) &&
                  row.live() is Some(m) &&
                  m.coming &&
                  m.flex.style.come_at == cause else {
                  continue
                }
                let st = m.flex.style
                let from = dmax(dmin(h, given), 0.0)
                given = given - from
                guard from > st.come_from + 0.001 else { continue }
                st.come_from = from
                st.come_v = 0.0
                st.come_goal = h * st.come_to
                st.come_plan = st.come_goal
                match st.come_group {
                  // (in the one way it was said in, set already: that way's plan made again from there, below)
                  Some(g) if g.set && g.members.length() > 1 =>
                    if !groups.iter().any(fn(o) { physical_equal(o, g) }) {
                      groups.push(g)
                    }
                  // (in one not set yet: it is set from there)
                  Some(g) if !g.set => ()
                  // (alone: its own way from there)
                  _ => {
                    (m.come_off)()
                    st.come_group = None
                    // (on a way its page said: that way's length still, from where it now sets out; else a Move's)
                    st.come_ends = match st.come_spec {
                      Some((ms, _)) if ms > 0.0 => st.come_at + ms
                      _ => cause + @flex.come_way_ms(from, 0.0, h)
                    }
                    if st.come_ends <= cause + 0.001 {
                      come_done(tree, row, m)
                    } else {
                      m.come_off = row.at_moment(st.come_ends, fn() { come_done(tree, row, m) })
                      tree.hand_at_end(st.come_ends)
                    }
                  }
                }
                tree.layout_marked_at(row.at)
              }
              // (a way made again from where its keys now set out: each in it to rest at its new end, as
              // Tree::come_group_settle puts them)
              if groups.length() > 0 {
                let ways = tree.list_inner_at(held_node.val, cause)
                for k in tree.column_items(held_node.val) {
                  ways.push(tree.handle(k))
                }
                // (and whatever else under the list went in those groups, its end said again with theirs: a stale
                // end of its own would set it at rest before the group's)
                let below : Array[Int] = [held_node.val]
                while below.length() > 0 {
                  let at = below.pop().unwrap()
                  for kid in tree.nodes[at].kids {
                    let n = tree.nodes[kid]
                    if n.live && n.coming && n.flex.style.come_group is Some(o) &&
                      groups.iter().any(fn(g) { physical_equal(g, o) }) &&
                      !ways.iter().any(fn(w) { w.at == kid }) {
                      ways.push(tree.handle(kid))
                    }
                    below.push(kid)
                  }
                }
                for g in groups {
                  @flex.come_group_set(g)
                  for w in ways {
                    guard w.live() is Some(m) &&
                      m.flex.style.come_group is Some(o) &&
                      physical_equal(o, g) else {
                      continue
                    }
                    let st = m.flex.style
                    if st.come_to >= 1.0 {
                      (m.come_off)()
                      m.come_off = w.at_moment(st.come_ends, fn() { come_done(tree, w, m) })
                      tree.hand_at_end(st.come_ends)
                    } else if m.left_at >= 0.0 {
                      m.span = dmax(st.come_ends - m.left_at, 0.0)
                    }
                    tree.layout_marked_at(w.at)
                  }
                }
              }
            }
            _ => ()
          }
        }
      }
      None => ()
    }
    // (a block come at its foot that took the room, measured now: shorter than the room it set out from, from as tall
    // as it is (the rest of the room the floor's, so nothing over it comes down))
    if took_room.length() > 0 {
      for k in took_room.keys().collect() {
        guard took_room.get(k) is Some((row, r)) else { continue }
        match (row.live(), heights.get(k)) {
          (Some(m), Some(h)) => {
            took_room.remove(k)
            let st = m.flex.style
            if m.coming && h < r - 0.001 && st.come_from > h {
              st.come_from = h
              self.tree.layout_marked_at(row.at)
            }
          }
          (None, _) => took_room.remove(k) |> ignore
          _ => ()
        }
      }
    }
    // (what the last pass found, alone: what showed before and shows no more let go now, in this layout)
    show_only(found)
    self.tree.room_bindings_run()
    slots_cover(places(laid.untracked()), found, top, vh)
    let live = blocks.filter(fn(b) { b.0.alive() })
    blocks.clear()
    blocks.append(live)
    let all = places(laid.untracked())
    // (how tall the column is as this fill leaves it and where its blocks are: what a floor armed next is held to)
    laid_whole.val = blocks_foot(all) + foot_room.untracked()
    laid_last.val = Some(all)
    match floor.val {
      Some((lk, e0)) =>
        match laid_at.get(lk) {
          Some(i) if i < all.length() => {
            laid_stretch.val = laid_whole.val - all.top(i)
            // (on the host's grid the stretch comes to as its blocks' heights are put on its pixels each frame, the
            // part closing and the key opening each rounded: never let back from as long as it came to while held, so
            // what is over goes up only, never a device pixel down and back)
            let bare = laid_stretch.val - foot_room.untracked()
            if bare > e0 {
              floor.val = Some((lk, bare))
            }
          }
          _ => ()
        }
      None => ()
    }
    // (the anchor from now, where the scroll is put: anchor_put; the one held by its start kept while it is in sight,
    // unless the hand moved the list or it was asked somewhere)
    read_keeps.val = !read_moved && !asked && !centring && !to_end
    anchor_put(all, top, vh, top)
    read_keeps.val = false
    row_vh.val = vh
    // (what is made, the stretch it covers)
    made_now(all, visible)
    seen_rows.clear()
    let mut incomplete = past_made_at(top, vh, made.untracked())
    for k in shown_now {
      if row_ready(k) {
        seen_rows[k] = true
      } else {
        incomplete = true
      }
    }
    // In an outer batch the slot watches cannot mount the blocks until that change has been told.
    if vh > 0.0 && incomplete {
      check_coverage()
    }
    // (what came or went by the last change of its keys, told its rows by now: what shows found from here by its ways)
    if came_by_data.val.length() > 0 {
      came_by_data.val = Map([])
    }
    if gone_from.val.length() > 0 {
      gone_from.val = Map([])
    }
    if moved_now.val.length() > 0 {
      moved_now.val = Map([])
    }
    self.tree.room_bindings_run()
    // (the scroll put where the anchor says, told as one with how far it goes (View::scrolls' measure_reach): moved by
    // as much, a fling under way with it; at its foot where it follows it there, as it is)
    let has_pin = pin.val is Some((k, _, _, _)) && laid_at.contains(k)
    s.fill_put = fn() {
      if held {
        // (held where it is at its foot: put there once what it holds has grown under it, its foot further down now;
        // till then at its foot as it was)
        if top < dmax(0.0, whole_now() - vh) - 0.5 {
          s.put(top)
        }
      } else if !follows_foot && s.at_foot() {
        // (held by what was pressed, off its foot from where it was there)
        s.put(top)
      } else if !follows_foot && (top - x).abs() > 0.000001 {
        if s.as_list && !asked {
          s.grew_above(top - x)
        } else {
          s.put(top)
        }
      }
      // (back at its foot at rest, where it follows its foot: kept there from now as what it holds grows; not where an
      // ask cut short by its foot still going down was put back, the next fill going on with it. At the foot of the room
      // kept under its blocks for what was pressed it is not at its own: followed from there, it would drop by that room
      // as soon as anything at its foot changed. Held there instead, as long as the hand leaves it where it is, what comes
      // at its foot taking that room as it grows; once it is all taken, followed again from where that leaves it)
      if !follows_foot &&
        !held &&
        !binds &&
        !ask_cut.val &&
        !has_pin &&
        @signals.untracked(follows) &&
        vh > 0.0 &&
        s.rest_now() is None &&
        s.glides_till() is None {
        if room_held.val is Some((t0, _, _)) && (t0 - top).abs() > 0.5 {
          room_held.val = None
        }
        let at_end = top >= dmax(0.0, whole_now() - vh) - 0.5
        if foot_room.untracked() > 0.5 {
          if at_end && room_held.val is None {
            let ks = @signals.untracked(keys)
            room_held.val = Some((top, ks.length(), ks.last()))
          }
        } else {
          let room_taken = match room_held.val {
            Some((_, len0, last0)) => {
              let ks = @signals.untracked(keys)
              (len0, last0) != (ks.length(), ks.last())
            }
            None => false
          }
          room_held.val = None
          if at_end || room_taken {
            s.held = false
            row_let_go(false)
            s.to_foot()
          }
        }
      }
      // (gliding back to its foot, its foot moved since the glide set out or went on (a block measured or come at its
      // end, its pinned foot grown or shrunk, a way under it): on to where it is now, from where the glide has it and as
      // fast; another way in its place let be, the hand's, the wheel's, another ask's. A limit said meanwhile that holds
      // it short of its foot (ListPlace::follow_from: glide_limit), on to where it holds it instead, back up to it
      // where the glide is past it already)
      match (end_glide.val, s.notch.untracked()) {
        (Some(g), Some(n)) if physical_equal(g, n) && vh > 0.0 => {
          let most = dmax(0.0, whole_now() - vh)
          let to = glide_limit.unwrap_or(most)
          if (n.x0 + n.total - to).abs() > 1.0 / 128.0 {
            let t = dmax(self.tree.drawn_said(), n.t0)
            let (came, _) = ease_state(n.total, n.v0, t - n.t0, tau=n.tau)
            if to < n.x0 + came {
              s.glide_to(self, t, to)
            } else {
              s.glide_on(self, t, to, most)
            }
            end_glide_set(s.notch.untracked())
          }
        }
        (Some(_), _) => end_glide_set(None)
        _ => ()
      }
    }
  }
  s.whole = Some(whole_now)
  // (its ways kept till the latest end any of them declares (Style's come_ends, said as the change that set it was
  // taken), waited for as a moment (View::at_moment); there, those whose end is past let go, what shows found again
  // without them, the rest waited for again: one set off anew in a later change, as long as that says. One whose end
  // its layout has not said yet (not laid out in its change) ends at the longest a Move takes from its moment, as
  // View::comes waits for it; one never set off (its column's motion reduced, the tree not drawn yet) has no moment)
  let way_ends = fn(n : Node) {
    let st = n.flex.style
    if st.come_ends == st.come_ends {
      st.come_ends
    } else {
      st.come_at + @flex.move_most_ms
    }
  }
  // (a key coming or going by data on its way drawn by how much of its block shows, as an old list's row coming or
  // going where it is (ui's row_held_look, by view's row_held_at): what its block holds as big as that, about the side
  // across what it draws is laid from and its top down (Pivot's DrawnSide: what shows of a block on its way is its top,
  // so drawn there it is all within what shows, nothing of it cut; a reply from its start, one's own bubble from its
  // end, not the page's middle, the user, 2026-10-31: 「有些东西就应该偏心缩放」), and as opaque, none at half its size or less, whole at its
  // size; one set out from all its height whole at once, from part of it at that part from the first frame. Its block's
  // own, while it is on its way alone: as it ends, whole and at its size again, nothing of it kept at rest (the user,
  // 2026-10-31 and 2026-11-08: 缩到 50% 左右的时候就变成完全看不见了). Its way read where it is drawn
  // (View::drawn_while), how far it goes as its column's layout said it (`laid`, read so that it is worked out again once
  // the change's layout has measured it))
  let seen_on_way : Map[Int, (View, Array[View])] = Map([])
  // (how much of the block of row `v` on its way shows, 0 to 1, where it is drawn: one number, as the layout puts it,
  // its height then over its height at rest, each as its column lays it out (on the host's pixels where it sets a page's
  // list's rows on them: as flex lays a row on its way, flex's rows_on_way), so that what it holds drawn at it fills what
  // shows and its foot steps with the slot's, never between; as far as it set out from, where its way is not measured yet; 1
  // off its way. Read by the clock where it is drawn (View::drawn_while): `laid` is told what is measured, not each
  // layout of the way)
  let shown_share = fn(v : View) -> Double {
    laid.get() |> ignore
    guard v.live() is Some(m) && m.coming else { return 1.0 }
    let st = m.flex.style
    let ends = st.come_ends
    let g = self.tree.rows_grid_now()
    let whole = rows_slot_on(dmax(st.come_from, if st.come_goal == st.come_goal { st.come_goal } else { 0.0 }), g)
    guard ends == ends && whole > 0.0 else { return if st.come_from > 0.0 { 1.0 } else { 0.0 } }
    let t = v.drawn_while(fn(now) { now < ends })
    let at = if t == @double.infinity { ends } else { t }
    let shown = match @flex.come_state(st, at) {
      Some((h, _)) => h
      None => whole
    }
    dmin(rows_way_on(st, shown, st.come_goal, at, g) / whole, 1.0)
  }
  let seen_from = fn(v : View) {
    // (the same view already seen so: nothing to do; another made at its index since, or one let go, replaced)
    match seen_on_way.get(v.at) {
      Some((o, _)) if o.alive() && o.id() == v.id() => return
      _ => ()
    }
    // (the blocks it holds: what is drawn as big as it shows)
    let held = blocks.filter(fn(b) {
      guard b.0.alive() else { return false }
      let mut i = self.tree.nodes[b.0.at].parent
      while i >= 0 && i != v.at {
        i = self.tree.nodes[i].parent
      }
      i == v.at
    }).map(fn(b) { b.0 })
    seen_on_way[v.at] = (v, held)
    // (one said to come whole: drawn as at rest all its way)
    if whole_rows.iter().any(fn(r) { r.at == v.at && r.alive() && r.id() == v.id() }) {
      return
    }
    v.alpha(By(fn() { row_held_at(shown_share(v)).0 })) |> ignore
    for b in held {
      b.scale(By(fn() { row_held_at(shown_share(v)).1 }), about=DrawnSide(0.0)) |> ignore
    }
  }
  let seen_whole = fn(at : Int) {
    match seen_on_way.get(at) {
      Some((v, held)) => {
        seen_on_way.remove(at)
        if v.alive() {
          v.alpha(Is(1.0)) |> ignore
        }
        for b in held {
          if b.alive() {
            b.scale(Is(1.0)) |> ignore
          }
        }
      }
      None => ()
    }
  }
  let ways_due : Ref[() -> Unit] = Ref(fn() {  })
  ways_due.val = fn() {
    let t = self.tree.logic_said()
    let left = ways.filter(fn(w) { w.0.live() is Some(n) && way_ends(n) > t })
    for w in ways {
      if !left.iter().any(fn(l) { l.0.at == w.0.at }) {
        seen_whole(w.0.at)
      }
    }
    // (one let go on its way: its entry with it)
    let gone = seen_on_way.keys().filter(fn(at) { !(seen_on_way.get(at) is Some((o, _)) && o.alive()) }).collect()
    for at in gone {
      seen_on_way.remove(at)
    }
    for w in left {
      seen_from(w.0)
    }
    if left.length() != ways.length() {
      ways.clear()
      ways.append(left)
      laid_again()
    }
    if !whole_rows.is_empty() {
      whole_raised()
    }
    (ways_off.val)()
    ways_off.val = fn() {  }
    let mut end = @double.neg_infinity
    for w in ways {
      if w.0.live() is Some(n) {
        end = dmax(end, way_ends(n))
      }
    }
    if end > t {
      ways_off.val = self.at_moment(end, fn() { (ways_due.val)() })
    }
  }
  self.owns(fn() { (ways_off.val)() }) |> ignore
  // Whether a row its keys' change made or lets go (View::each's, `coming` or going) makes its way: where it is seen,
  // as it is told. Coming: come by data (not moved among them), its page saying it comes (`comes`, asked once now), and
  // where it ends seen, at its foot where it follows it; off it under what is read (the block holding the top of what
  // shows over it) and over where what shows ends. Going: it showed, at its foot or under the top of what showed. Else
  // there or gone at once. One that makes its way kept among its ways (Places) till that ends.
  // (the slot of key `k`, by its key while it is made: as tall as it is now)
  let slot_views : Map[Int, View] = Map([])
  // (`flips`: what its keys bring or take by data laid out at once as it ends, each block drawn off where it is laid
  // out by how far it was from there as the change came, all of it on one way (flex's FlipWay), read where it is drawn:
  // nothing laid out again on the way (the user, 2026-11-10 and 2026-11-15). `flip_way`: the way, while it goes;
  // `flip_items`: each block's offset as it set out, by its key; `flip_new`: those come by that change, drawn growing
  // from their top at its size's share)
  let flip_end_off : Ref[() -> Unit] = Ref(fn() {  })
  // (a flight in from outside the tree in a key's block (View::flies_in, Tree::carried): the change's moment, the key
  // and the flight's way: the way of a change that brings that key goes on the flight's rise, as long)
  let flip_said : Ref[(Double, Int, (Double, (Double) -> Double))?] = Ref(None)
  // (whether what flip_said holds is a lead's (View::flies_in's `lead`): no other flight of that moment takes its place)
  let flip_said_lead : Ref[Bool] = Ref(false)
  let flip_rebuild : Ref[() -> Unit] = Ref(fn() {  })
  // (what the held column's blocks hold coming or going tells it: the list's set-out, Tree's flip_lists)
  let flip_inner_tell : Ref[(Int) -> Unit] = Ref(fn(_) {  })
  // (the keys come at its end by the change being set out, at its foot: the room under the last block taken by them)
  let flip_takes : Ref[Array[Int]] = Ref([])
  // (block `k`'s offset drawn at `t`: across, down, less wide, less tall)
  let flip_at = fn(k : Int, t : Double) -> (Double, Double, Double, Double) {
    match (flip_way.untracked(), flip_items.get(k)) {
      (Some(w), Some(i)) => w.drawn(i, t).0
      _ => (0.0, 0.0, 0.0, 0.0)
    }
  }
  // (as drawn now, bound: following the clock while the way goes)
  let flip_drawn = fn(k : Int, v : View) -> (Double, Double, Double, Double) {
    match flip_way.get() {
      Some(w) => {
        let ends = w.ends()
        let t = v.drawn_while(fn(t) { t < ends })
        flip_at(k, t)
      }
      None => (0.0, 0.0, 0.0, 0.0)
    }
  }
  // (how much of block `k` is open as drawn now, 0 to 1: as it grows from its top, all of it at rest; a key a flight
  // carries open all the way, its words drawn whole as they fly (the flight's))
  let flip_whole : Map[Int, Bool] = Map([])
  let flip_open = fn(k : Int, v : View) -> Double {
    let (_, _, _, d) = flip_drawn(k, v)
    guard d > 0.0 && flip_new.contains(k) && !flip_whole.contains(k) else { return 1.0 }
    match tall.get(k) {
      Some(c) =>
        match c.untracked() {
          Some(h) if h > 0.0 => dmax(0.0, (h - d) / h)
          _ => 1.0
        }
      None => 1.0
    }
  }
  // (those a flight carries drawn over the rest of the list (its foot too) while they go: the paint's, Tree::raise_in_list)
  let flip_raise = fn() {
    let ids = []
    for k, _ in flip_whole {
      match slot_views.get(k) {
        Some(v) if v.alive() => ids.push(v.id())
        _ => ()
      }
    }
    self.tree.raise_in_list(self.at, ids)
  }
  // (what a block holds changing inside it (a part come or gone, a size said): each node of it drawn off where it is
  // laid out by how far it was from there as the change came, against what holds it, its own ground as tall as it
  // was, one that holds nothing grown from as big as it was, one come grown from none from its top, unseen till half
  // of it is open; all on the list's one way, nothing laid out on it (Node's flip_in, Tree::flip_in_by). By node: down,
  // shorter ground, less tall, whether come, at the way's set-out; the nodes of each block that are; where each
  // block's nodes were drawn as the change came (down from its top, how tall, how wide), by the change's moment)
  let flip_in_amts : Map[Int, (Double, Double, Double, Bool)] = Map([])
  let flip_in_bound : Map[Int, Int] = Map([])
  let flip_in_of : Map[Int, Array[Int]] = Map([])
  let flip_in_before : Map[Int, (Double, Map[Int, (Double, Double, Double)])] = Map([])
  let flip_in_take = fn(k : Int, at : Double) {
    match flip_in_before.get(k) {
      Some((t, _)) if t == at => return
      _ => ()
    }
    guard slot_views.get(k) is Some(v) && v.alive() && !flip_new.contains(k) && !flip_whole.contains(k) else {
      return
    }
    let m : Map[Int, (Double, Double, Double)] = Map([])
    fn walk(i : Int, base : Double) -> Unit {
      for c in self.tree.nodes[i].kids {
        let n = self.tree.nodes[c]
        guard n.live else { continue }
        if n.slot {
          walk(c, base)
          continue
        }
        guard n.placed else { continue }
        let y = base + n.flex.top + off_y(n)
        let (_, g, o, _) = n.flip_in
        m[c] = (y, if o != 1.0 { n.flex.height * o } else { n.flex.height - g }, n.flex.width)
        if o == 1.0 {
          walk(c, y)
        }
      }
    }
    let root = self.tree.nodes[v.at]
    m[v.at] = (0.0, root.flex.height - root.flip_in.1, root.flex.width)
    walk(v.at, 0.0)
    flip_in_before[k] = (at, m)
  }
  let flip_in_clear = fn() {
    flip_in_amts.clear()
    flip_in_of.clear()
  }
  let steady_left : Ref[Bool] = Ref(false)
  way_steady_fn.val = fn() {
    let t = self.tree.logic_said()
    let set_out = if flips {
      match flip_way.untracked() {
        Some(w) if w.ends() > t - 1.0 => w.at
        _ => -1.0
      }
    } else {
      let mut latest = -1.0
      for w in ways {
        if w.0.live() is Some(m) && m.coming {
          let st = m.flex.style
          let ends = if st.come_ends == st.come_ends { st.come_ends } else { st.come_at + @flex.move_most_ms }
          if ends > t - 1.0 && st.come_at > latest {
            latest = st.come_at
          }
        }
      }
      latest
    }
    let left = if flips {
      steady_left.val && set_out >= 0.0
    } else {
      let mut any_gone = false
      let mut any_come = false
      for w in ways {
        if w.0.live() is Some(m) && m.coming {
          if m.flex.style.come_to <= 0.0 {
            any_gone = true
          } else {
            any_come = true
          }
        }
      }
      any_gone && !any_come
    }
    let out : Array[(String, NodeId, Bool, Bool)] = []
    for k in slot_keys.untracked() {
      guard slot_views.get(k) is Some(sv) && sv.alive() else { continue }
      let sid : NodeId = { at: sv.at, gen: sv.gen }
      let kstr = "\{sv.at}:\{sv.gen}"
      let (comes, faint_open) = if flips {
        let is_new = flip_new.contains(k)
        let d = flip_at(k, t).3
        let open_share = if d > 0.0 && is_new && !flip_whole.contains(k) {
          match tall.get(k) {
            Some(c) =>
              match c.untracked() {
                Some(h) if h > 0.0 => dmax(0.0, (h - d) / h)
                _ => 1.0
              }
            None => 1.0
          }
        } else {
          1.0
        }
        (is_new, open_share < 0.5)
      } else {
        match sv.live() {
          Some(m) if m.coming => {
            let st = m.flex.style
            let is_new = st.come_from == 0.0 && st.come_to >= 1.0
            let h = m.flex.height
            let shown_h = self.tree.along_now(sv.at, t)
            (is_new, h > 0.0 && shown_h < 0.5 * h)
          }
          _ => (false, false)
        }
      }
      out.push((kstr, sid, comes, faint_open))
    }
    (set_out, left, out)
  }
  if flips {
    let flip_was : Ref[Array[Int]] = Ref([])
    // (what a block holds coming or going down its column (a show, a pick, an each in it: View::comes) laid out at once
    // in the change, the block then as tall as that, set out as its keys' change is: Tree's flip_lists)
    let inner_at = Ref(-1.0)
    // (the change at its foot let a key go from its end not said to leave its room (`leaves_room`): what is over it
    // comes down into that room on the list's way, not held where it was)
    let gave_back : Ref[Bool] = Ref(false)
    let pending_at : Ref[Double] = Ref(-1.0)
    let pending_was : Ref[Array[Int]] = Ref([])
    let pending_ks : Ref[Array[Int]] = Ref([])
    let pending_inner : Ref[Bool] = Ref(false)
    let pending_builds : Ref[Int] = Ref(0)
    fn change(ks : Array[Int], was : Array[Int], inner : Bool) -> Unit {
      guard was.length() > 0 else { return }
      let at = self.tree.cause_now()
      let base_was = if pending_at.val == at { pending_was.val } else { was }
      // (at its foot what goes from its end said to leave its room (`leaves_room`) leaves it under the last block: what
      // is over it never comes down for it (the user, 2026-11-12: a turn that ends with no answer carries nothing up to
      // let it fall back); what comes at its end takes that room first, what is over it going up only by what it needs
      // past it; the room goes as the hand scrolls it off, as ever. One not said so goes as any change does, what is over
      // it coming down on the list's way: an agent's line its answer came in over, gone as that answer is out, its room
      // not left empty under the answer for good)
      if !inner && @signals.untracked(fn() { s.seen.get() is Some(_) && s.at_foot() && follows() }) {
        let mut kept_step = ks.length()
        while kept_step > 0 && !was.contains(ks[kept_step - 1]) {
          kept_step = kept_step - 1
        }
        let last_kept = if kept_step > 0 { Some(ks[kept_step - 1]) } else { None }
        let at_end = match last_kept {
          Some(l) => {
            let i = was.search(l).unwrap_or(was.length() - 1)
            was[i + 1:].to_owned()
          }
          None => was
        }
        let mut gone = 0.0
        gave_back.val = false
        for k in at_end {
          if !ks.contains(k) {
            if @signals.untracked(fn() { leaves_room(k) }) {
              gone = gone + heights.get(k).unwrap_or(0.0)
            } else {
              gave_back.val = true
            }
          }
        }
        if gone > 0.0 {
          foot_room.set(foot_room.untracked() + gone)
        }
        // (what came at its end takes the room as it is measured: in the set-out, before where each rests is read)
        let mut kept = ks.length()
        while kept > 0 && !base_was.contains(ks[kept - 1]) {
          kept = kept - 1
        }
        flip_takes.val = ks[kept:].to_owned()
      }
      guard !@signals.untracked(self.tree.motion_reduced) else {
        steady_left.val = base_was.iter().any(fn(k) { !ks.contains(k) }) && !ks.iter().any(fn(k) { !base_was.contains(k) })
        return
      }
      if pending_at.val == at {
        if !inner {
          pending_ks.val = ks
        }
        pending_inner.val = pending_inner.val || inner
        pending_builds.val = self.tree.old_builds_begun
        return
      }
      pending_at.val = at
      pending_was.val = was
      pending_ks.val = ks
      pending_inner.val = inner
      pending_builds.val = self.tree.old_builds_begun
      // (how far off its foot it was as the change came: brought to its foot at once by it (words sent read up the
      // list: a go-to, no motion), where each was is counted as it would have been there)
      let off_foot = @signals.untracked(fn() { if s.at_foot() { 0.0 } else { dmax(0.0, s.most() - s.at(self.tree)) } })
      for k, _ in flip_in_of {
        flip_in_take(k, at)
      }
      let g_near = @signals.untracked(fn() { self.tree.rows_grid_now() })
      let near = if g_near > 0.0 { 1.0 / g_near } else { 0.0 }
      let before : Map[Int, (Double, Double, Double, Double)] = Map([])
      for k, v in slot_views {
        guard v.alive() else { continue }
        let (x, y, w, h) = v.placed_window_now()
        // (one a flight carries: drawn off as its slot is (where a change before moved it), open all the way; within a
        // pixel of the host's grid of its rest, drawn at its rest already: slot's drawn_off)
        // (one still growing open from its top: drawn where its way has it, as its slot is till all of it is open)
        let (a, b, c, d) = flip_at(k, at)
        let d = if flip_whole.contains(k) { 0.0 } else { d }
        let near_k = if d > 0.0 && flip_new.contains(k) { 0.0 } else { near }
        let a = if a.abs() < near_k { 0.0 } else { a }
        let b = if b.abs() < near_k { 0.0 } else { b }
        before[k] = (x + a, y + b, w - c, h - d)
      }
      // (and how fast: what is left of the way's speed then; none along an axis already at its rest on the grid)
      let speed : Map[Int, (Double, Double, Double, Double)] = Map([])
      match flip_way.untracked() {
        Some(w) =>
          for k, i in flip_items {
            let (oa, ob, _, od) = flip_at(k, at)
            let near_k = if od > 0.0 && flip_new.contains(k) && !flip_whole.contains(k) { 0.0 } else { near }
            let (va, vb, vc, vd) = w.drawn(i, at).1
            speed[k] = (
              if oa.abs() < near_k { 0.0 } else { va },
              if ob.abs() < near_k { 0.0 } else { vb },
              vc,
              if flip_whole.contains(k) { 0.0 } else { vd },
            )
          }
        None => ()
      }
      // (an old view hosted in its foot (the chat's composer) laid out only as the old frame is built: where all ends is
      // read once it is built since the cause, before that frame is painted (Tree::old_views_built); a bridge while
      // old views are hosted in a list's foot)
      let foot_old = match foot_v.val {
        Some(f) => self.tree.holds_hosted(f.at)
        None => false
      }
      @signals.after_flush(fn() {
        @signals.after_flush(fn() {
          let came_once : Ref[Bool?] = Ref(None)
          let snap_was : Ref[Array[Int]] = Ref(pending_was.val)
          let snap_ks : Ref[Array[Int]] = Ref(pending_ks.val)
          let snap_inner : Ref[Bool] = Ref(pending_inner.val)
          fn set_out(fix : Bool) -> Unit {
          if !fix {
            snap_was.val = pending_was.val
            snap_ks.val = pending_ks.val
            snap_inner.val = pending_inner.val
            pending_at.val = -1.0
            steady_left.val = snap_was.val.iter().any(fn(k) { !snap_ks.val.contains(k) }) &&
              !snap_ks.val.iter().any(fn(k) { !snap_was.val.contains(k) })
          }
          let was = snap_was.val
          let ks = snap_ks.val
          let inner = snap_inner.val
          // (set out: what its blocks hold may tell it again from here, at this same moment)
          inner_at.val = -1.0
          // (laid out as the change ends before anything is read: one set out inside the change's flush (what a block
          // holds told it) runs before the frame lays out, its nodes just made none tall till then)
          if !fix {
            self.tree.laid_now() |> ignore
          }
          let items : Map[Int, @flex.FlipItem] = Map([])
          let fresh : Map[Int, Bool] = Map([])
          // (where each is laid out as the change ends it)
          if !fix && flip_takes.val.length() > 0 {
            let mut came = 0.0
            for k in flip_takes.val {
              came = came + heights.get(k).unwrap_or(est)
            }
            flip_takes.val = []
            let left = dmax(0.0, foot_room.untracked() - came)
            if left != foot_room.untracked() {
              foot_room.set(left)
              self.tree.laid_now() |> ignore
            }
          }
          let after : Map[Int, (Double, Double, Double, Double)] = Map([])
          for k, v in slot_views {
            if v.alive() {
              after[k] = v.laid_window_now()
            }
          }
          if !fix && jumped_at.val == at && off_foot > 0.0 && @signals.untracked(fn() { s.at_foot() }) {
            for k, b in before {
              before[k] = (b.0, b.1 - off_foot, b.2, b.3)
            }
          }
          // (at its foot what was there goes up only: where the room the change leaves would have any of it come down
          // (what came measured shorter than what went, a pixel's rounding), that much more room kept under the last
          // block, so it rests where it was; not where the change gave a key's room back (`gave_back`))
          if !fix && !inner && !gave_back.val && @signals.untracked(fn() { s.at_foot() && follows() }) {
            let mut down = 0.0
            for k, b in before {
              match after.get(k) {
                Some(a) if ks.contains(k) => down = dmax(down, a.1 - b.1)
                _ => ()
              }
            }
            if down > 0.001 {
              foot_room.set(foot_room.untracked() + down)
              self.tree.laid_now() |> ignore
              for k, v in slot_views {
                if v.alive() {
                  after[k] = v.laid_window_now()
                }
              }
            }
          }
          let order = keys().filter(fn(k) { after.contains(k) })
          // (none come by data its page says comes, or gone: there at once as it is, no way)
          let came = match came_once.val {
            Some(c) => c
            None => {
              // (or one that showed put elsewhere among them: those that stay in another order)
              let kept_was = was.filter(fn(k) { ks.contains(k) })
              let kept_now = ks.filter(fn(k) { kept_was.contains(k) })
              let c = inner ||
                flip_came.length() > 0 ||
                was.iter().any(fn(k) { !ks.contains(k) && before.contains(k) }) ||
                kept_was != kept_now
              came_once.val = Some(c)
              c
            }
          }
          flip_came.clear()
          guard came else {
            (flip_end_off.val)()
            flip_items.clear()
            flip_new.clear()
            flip_whole.clear()
            flip_in_clear()
            flip_way.set(None)
            return
          }
          for i, k in order {
            let (ax, ay, aw, ah) = after[k]
            match before.get(k) {
              Some((bx, by, bw, bh)) => {
                let v = speed.get(k).unwrap_or((0.0, 0.0, 0.0, 0.0))
                // (what a block holds told it (inner): down its column alone, its height with it; across is what holds
                // the list's (a column moved or laid out at another width as the page goes: its own offset), never
                // the rows' set out again across on the list's way, the two at once)
                items[k] = if inner {
                  { off: (0.0, by - ay, 0.0, -(bh - ah)), v: (0.0, v.1, 0.0, v.3) }
                } else {
                  { off: (bx - ax, by - ay, -(bw - aw), -(bh - ah)), v }
                }
              }
              None =>
                if was.contains(k) {
                  ()
                } else {
                  // (come by this change: from none tall where it comes, under the one before it as that was drawn,
                  // else over the one after it)
                  let mut y = ay
                  let mut j = i - 1
                  let mut found = false
                  while j >= 0 && !found {
                    match before.get(order[j]) {
                      Some((_, by, _, bh)) => {
                        y = by + bh
                        found = true
                      }
                      None => j = j - 1
                    }
                  }
                  if !found {
                    let mut j = i + 1
                    while j < order.length() && !found {
                      match before.get(order[j]) {
                        Some((_, by, _, _)) => {
                          y = by
                          found = true
                        }
                        None => j = j + 1
                      }
                    }
                  }
                  if found {
                    items[k] = { off: (0.0, y - ay, 0.0, ah), v: (0.0, 0.0, 0.0, 0.0) }
                    fresh[k] = true
                  }
                }
            }
          }
          // (the key a flight carries in, told already: drawn where it rests, the flight bringing it, open all the way;
          // where a later change moves it while the flight goes, it goes on that way as the rest)
          let carried_in = fn(k : Int) -> Bool {
            fresh.contains(k) &&
            (flip_whole.contains(k) ||
            (match flip_said.val {
              Some((t, c, _)) => c == k && t >= at && t - at < 100.0
              None => false
            }))
          }
          for k, _ in fresh {
            if carried_in(k) && after.get(k) is Some(a) {
              items[k] = { off: (0.0, 0.0, 0.0, a.3), v: (0.0, 0.0, 0.0, 0.0) }
            }
          }
          // (one never drawn before, come into sight by the change: going with the one before it, else after it)
          for i, k in order {
            guard !items.contains(k) else { continue }
            let mut j = i - 1
            while j >= 0 && !(items.contains(order[j]) && !fresh.contains(order[j])) {
              j = j - 1
            }
            if j < 0 {
              j = i + 1
              while j < order.length() && !(items.contains(order[j]) && !fresh.contains(order[j])) {
                j = j + 1
              }
            }
            if j >= 0 && j < order.length() && items.get(order[j]) is Some(n) {
              items[k] = { off: (0.0, n.off.1, 0.0, 0.0), v: (0.0, n.v.1, 0.0, 0.0) }
            }
          }
          // (what changed inside a block: each of its nodes off where it is laid out now by how far it was drawn from
          // there, against what holds it; one come grown from none, from its top)
          let inner_now : Array[Int] = []
          for k, b in flip_in_before {
            guard b.0 == at && !fresh.contains(k) && slot_views.get(k) is Some(v) && v.alive() else { continue }
            match flip_in_of.get(k) {
              Some(ats) => for a in ats {
                flip_in_amts.remove(a)
              }
              None => ()
            }
            let m = b.1
            // (the block laid out at another width than it was as the change came)
            let laid_anew = match m.get(v.at) {
              Some((_, _, bw)) => (self.tree.nodes[v.at].flex.width - bw).abs() > 0.5
              None => false
            }
            let ats : Array[Int] = []
            let put = fn(a : Int, amt : (Double, Double, Double, Bool)) {
              guard amt.0.abs() > 0.01 || amt.1.abs() > 0.01 || amt.2 > 0.01 else { return }
              flip_in_amts[a] = amt
              ats.push(a)
              inner_now.push(a)
              let gen = self.tree.nodes[a].gen
              guard flip_in_bound.get(a) != Some(gen) else { return }
              flip_in_bound[a] = gen
              let hv = self.tree.handle(a)
              self.tree.flip_in_by(a, fn() {
                match flip_way.get() {
                  Some(w) =>
                    match flip_in_amts.get(a) {
                      Some((dy, g, sh, come)) => {
                        let ends = w.ends()
                        let t = hv.drawn_while(fn(t) { t < ends })
                        let left = w.left(t).0
                        let h = self.tree.nodes[a].flex.height
                        // (drawn as big as it is open only as it comes: what stays is drawn at its size, never squeezed
                        // by the way, whatever it was told)
                        let o = if come && sh > 0.0 && h > 0.0 { dmax(0.0, (h - sh * left) / h) } else { 1.0 }
                        (dy * left, g * left, o, if come { row_seen_at(o) } else { 1.0 })
                      }
                      None => (0.0, 0.0, 1.0, 1.0)
                    }
                  None => (0.0, 0.0, 1.0, 1.0)
                }
              })
            }
            fn walk(i : Int, base : Double, held : Double) -> Unit {
              for c in self.tree.nodes[i].kids {
                let n = self.tree.nodes[c]
                guard n.live else { continue }
                if n.slot {
                  walk(c, base, held)
                  continue
                }
                let y = base + n.flex.top + off_y(n) - n.flip_in.0
                let h = n.flex.height
                // (what a pick leaving makes for what it shows now (pick_leave.mbt) is drawn coming by its place's way
                // itself, held_scaled: not grown and faded in again here, the two at once)
                if self.tree.is_pick_fader(c) && !m.contains(c) {
                  continue
                }
                match m.get(c) {
                  // (in a block laid out at another width (its column on its way to another width, View::lays_anew),
                  // what comes out otherwise across was laid out anew: its words broken again, its ground round them
                  // as they are now, at once, as the window made another size has it, only its place on the list's
                  // way; never drawn as grown from its top, its words squeezed and sprung back (the user, 2026-11-17:
                  // 「新架构下文字的右侧展开收起挤压的时候效果不对」「很 q 弹的垃圾」))
                  Some((by, _, bw)) if laid_anew && (n.flex.width - bw).abs() > 0.5 => {
                    put(c, (by - y - held, 0.0, 0.0, false))
                    walk(c, y, by - y)
                  }
                  Some((by, bh, _)) => {
                    let d = by - y
                    let grown = h - bh
                    let leaf = !n.kids.iter().any(fn(x) { self.tree.nodes[x].live })
                    if leaf && grown > 0.5 {
                      // (a leaf grown: drawn as tall as it was, growing to as it rests on the way, as a ground alone (a
                      // box that holds nothing, its ground its look: sizes_steady's) is; one that draws something
                      // (words, pieces, a picture, shapes) at its size from the first frame, cut as tall as it is drawn
                      // (Tree::grown_cut_of), opened from its top, what is under it in its block coming down as it
                      // opens: never drawn smaller and grown back, its words squeezed and sprung back (the user,
                      // 2026-11-17: 「这种动效不是从原则上禁止存在吗」), nor over what is under it)
                      put(c, (d - held, grown, 0.0, false))
                    } else {
                      put(c, (d - held, if grown.abs() > 0.5 { grown } else { 0.0 }, 0.0, false))
                      walk(c, y, d)
                    }
                  }
                  None => if h > 0.5 { put(c, (0.0, 0.0, h, true)) }
                }
              }
            }
            let root = self.tree.nodes[v.at]
            match m.get(v.at) {
              Some((_, bh, _)) => {
                let grown = root.flex.height - bh
                put(v.at, (0.0, if grown.abs() > 0.5 { grown } else { 0.0 }, 0.0, false))
              }
              None => ()
            }
            walk(v.at, 0.0, 0.0)
            flip_in_of[k] = ats
          }
          // (worked out again as it is first placed: where each is laid out read once the frame has laid out all the
          // change ends, its pinned foot at its height then; the way as it was set out)
          if fix {
            flip_items.clear()
            for key, i in items {
              flip_items[key] = i
            }
            return
          }
          // (on a way still going as the change came: on from as fast as it went, one Move (a curve said by the cause
          // would stand it still where it goes, then set it off again); else the flight's rise, where one carries a key)
          let moving = speed.values().any(fn(v) { v.1.abs() > 0.01 })
          // (where it all comes to rest: what is under a still pointer found again there, and all of the way let go)
          let rests_at = fn(way : @flex.FlipWay) {
            if way.far > 0.5 {
              self.tree.hand_at_end(way.ends())
            }
            (flip_end_off.val)()
            flip_end_off.val = self.at_moment(way.ends(), fn() {
              flip_items.clear()
              flip_new.clear()
              flip_whole.clear()
              flip_raise()
              flip_in_clear()
              flip_way.set(None)
              self.tree.sight_owe(self.tree.cause_now())
            })
          }
          // (what each node in a block was set out to, as it is now: unscaled, the change's own)
          let amts_now : Map[Int, (Double, Double, Double, Bool)] = Map([])
          for a in inner_now {
            match flip_in_amts.get(a) {
              Some(amt) => amts_now[a] = amt
              None => ()
            }
          }
          // (on the way of the flight before it, that flight still going, as this change was set out)
          let on_prev = Ref(false)
          // (the way going as the change came a flight's: what comes now goes on a flight's way too, never a Move)
          let was_said = flip_way.untracked().bind(fn(p) { p.said }) is Some(_)
          // (a flight in the change's block told as it is committed, which may be the next frame's (Tree::carried, at the
          // end of the set-out): from then on all of it on its rise, as long, from where each was as the change came,
          // the flight's key drawn where it rests, open all the way; where a Move was going as the change came (not a
          // flight's), on as it went, the flight's key drawn whole)
          flip_rebuild.val = fn() {
            match flip_said.val {
              Some((t, k, w)) if t >= at && t - at < 100.0 && fresh.contains(k) && flip_way.untracked() is Some(_) => {
                // (the key this flight carries drawn whole on its way alone, as where it is told with the change: one an
                // earlier flight carried, still going on that one's way as the change came, is on this way now, whole
                // with it no more, what of it does not fly not held unseen till this one lands)
                flip_whole.clear()
                flip_whole[k] = true
                flip_raise()
                match after.get(k) {
                  Some(a) => items[k] = { off: (0.0, 0.0, 0.0, a.3), v: (0.0, 0.0, 0.0, 0.0) }
                  None => ()
                }
                let list : Array[@flex.FlipItem] = []
                flip_items.clear()
                for key, i in items {
                  flip_items[key] = i
                  list.push(i)
                }
                for key, _ in fresh {
                  flip_new[key] = true
                }
                for a, amt in amts_now {
                  flip_in_amts[a] = amt
                }
                let way = if moving && !was_said && !on_prev.val {
                  @flex.FlipWay::new(at, list)
                } else {
                  @flex.FlipWay::new(t, list, said=w)
                }
                flip_way_said(at, way)
                rests_at(way)
              }
              _ => ()
            }
          }
          // (on the way a flight said as the change came, that flight still going (words sent, the next change come
          // before they land): all of it goes on on that way, as long, from where each is drawn, so what flies and what
          // it flies among stay one motion; what comes now sets out on it as well, till a flight of its own is told)
          let carried_now = match flip_said.val {
            Some((t, k, _)) => t >= at && t - at < 100.0 && fresh.contains(k)
            None => false
          }
          match flip_way.untracked() {
            Some(prev) if !carried_now && prev.said is Some(_) && prev.left(at).0 > 0.05 => {
              on_prev.val = true
              let (k, _) = prev.left(at)
              let list : Array[@flex.FlipItem] = []
              flip_items.clear()
              for key, i in items {
                let (a, b, c, d) = i.off
                let it : @flex.FlipItem = { off: (a / k, b / k, c / k, d / k), v: (0.0, 0.0, 0.0, 0.0) }
                flip_items[key] = it
                list.push(it)
              }
              for key, _ in fresh {
                flip_new[key] = true
              }
              for a in inner_now {
                match flip_in_amts.get(a) {
                  Some((dy, g, sh, come)) => flip_in_amts[a] = (dy / k, g / k, sh / k, come)
                  None => ()
                }
              }
              let way = @flex.FlipWay::new(prev.at, list, said=prev.said.unwrap())
              flip_way_said(at, way)
              return
            }
            _ => ()
          }
          let list : Array[@flex.FlipItem] = []
          for _, i in items {
            list.push(i)
          }
          let said = match flip_said.val {
            Some((t, k, w)) if (!moving || was_said) && t >= at && t - at < 100.0 && fresh.contains(k) => Some((t, w))
            _ => None
          }
          // (on a flight's rise from where the flight sets out: the frame its change is drawn in, where that is later)
          let way = match said {
            Some((t, w)) => @flex.FlipWay::new(t, list, said=w)
            None => @flex.FlipWay::new(at, list)
          }
          flip_whole.clear()
          match flip_said.val {
            Some((t, k, _)) if t >= at && t - at < 100.0 && fresh.contains(k) => flip_whole[k] = true
            _ => ()
          }
          flip_raise()
          let kept_new : Array[Int] = []
          for k, _ in flip_new {
            if !flip_whole.contains(k) && items.get(k) is Some(i) && i.off.3 > 0.5 {
              kept_new.push(k)
            }
          }
          flip_items.clear()
          flip_new.clear()
          for k, i in items {
            flip_items[k] = i
          }
          for k in kept_new {
            flip_new[k] = true
          }
          for k, _ in fresh {
            flip_new[k] = true
          }
          if way.far > 0.5 {
            flip_way_said(at, way)
          } else {
            // (nothing moved by it, what a block holds told it (a pick to one as tall): what changed in it goes on the
            // least of a Move's time all the same, as it does where nothing holds it so (pick_leave.mbt's
            // leave_held_progress, as big at both ends), never at once)
            if inner {
              let ms = @flex.move_least_ms
              flip_gone_said(at, at + ms, fn(t) {
                let u = dmax(0.0, dmin(1.0, (t - at) / ms))
                1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u)
              })
            }
            flip_way.set(None)
          }
          rests_at(way)
          }
          fn wait_old(settled : Bool) -> Unit {
            if !settled && self.tree.old_builds <= pending_builds.val {
              self.tree.old_built_waits.push(wait_old)
            } else {
              set_out(false)
            }
          }
          // (what its blocks hold told it alone (inner), its keys as they were, waits for no old view: what is in its
          // foot is no part of it, and the frame laid out at the cause is drawn set out from where they were)
          if foot_old && !pending_inner.val && self.tree.old_builds <= pending_builds.val {
            // (meanwhile, a frame drawn before the old view is built is drawn from where each was, on the way that sets
            // out at the cause: never at where it goes for a frame and back (a word sent, the list up by its row for a
            // frame on a host's frames, which build an old view only as it is asked); worked out whole as it is built)
            // (held only from rest: a way still going goes on as it is, the change's set-out taking it over from where
            // it is drawn then, as it always did)
            guard flip_way.untracked() is None else {
              self.tree.old_built_waits.push(wait_old)
              return
            }
            // (each drawn as the change came held there, on the way that sets out at the cause; one laid out where it
            // goes off what shows (over its top, the list gone up by what came) shown still, as it is drawn where it
            // was: the fill that laid it out took it off what shows by where it goes, no way to draw it by yet, and
            // the next would have made it show again, a blink of every block over what came by as much as it brought
            // (a picture sent, its card); what is drawn on a way is kept showing by the fills after, as ever)
            self.tree.laid_now() |> ignore
            let held : Array[@flex.FlipItem] = []
            flip_items.clear()
            for k, v in slot_views {
              guard v.alive() && before.get(k) is Some((bx, by, bw, bh)) else { continue }
              let (ax, ay, aw, ah) = v.laid_window_now()
              let it : @flex.FlipItem = { off: (bx - ax, by - ay, -(bw - aw), -(bh - ah)), v: (0.0, 0.0, 0.0, 0.0) }
              flip_items[k] = it
              held.push(it)
            }
            flip_way_said(at, @flex.FlipWay::new(at, held))
            // (those drawn where the list shows as the change came: by where each was drawn then, the fill in the
            // change having found what shows by where all goes already)
            let (_, ly, _, lh) = self.placed_window_now()
            let back = shown_now.copy()
            for k, b in before {
              if !back.contains(k) && flip_items.contains(k) && b.1 + b.3 > ly && b.1 < ly + lh {
                back.push(k)
              }
            }
            if back.length() != shown_now.length() {
              show_only(back)
              // (laid out again showing them, placed where they are drawn from)
              laid_again()
              self.tree.laid_now() |> ignore
            }
            self.tree.old_built_waits.push(wait_old)
          } else if self.tree.moment_goes_on(at) {
            // (another change due at this same moment still to come (what a block holds made as one more of the
            // moment's changes tells it: an answer coming out of its agent's picture as that agent's line goes): set
            // out once the last of them is told, all of them as one, the changes after this one's merged into it)
            self.tree.moment_wait_push(fn() { set_out(false) })
          } else {
            set_out(false)
          }
        })
      })
    }
    self.reacts(fn() { keys() }, fn(ks) {
      let was = flip_was.val
      flip_was.val = ks
      change(ks, was, false)
    })
    flip_inner_tell.val = fn(part) {
      let at = self.tree.cause_now()
      // (the block it is in: where all of it was drawn, before it is laid out again)
      let blocks : Map[Int, Int] = Map([])
      for k, v in slot_views {
        if v.alive() {
          blocks[v.at] = k
        }
      }
      let mut p = part
      while p >= 0 {
        match blocks.get(p) {
          Some(k) => {
            flip_in_take(k, at)
            break
          }
          None => p = self.tree.nodes[p].parent
        }
      }
      guard inner_at.val != at else { return }
      inner_at.val = at
      let ks = @signals.untracked(fn() { keys() })
      change(ks, ks, true)
    }
    self.owns(fn() { (flip_end_off.val)() }) |> ignore
  }
  let slot_tall = fn(k : Int) {
    match slot_views.get(k) {
      Some(v) if v.alive() => self.tree.along_now(v.at, self.tree.cause_now())
      _ => 0.0
    }
  }
  // (how tall a block come at its foot sets out from: all the room under the last block, that one gone in its place
  // in the same change counted in it, the room none from then; measured shorter than that, from as tall as it is, the
  // rest of the room left: so the column is as tall as it was at that moment, and what is over it goes up by no more
  // than it needs past the room)
  // (the same where it comes with no way (there at once: motion reduced, or not seen to come): the room less by as tall
  // as it is, in the fill that measures it)
  let take_room = fn(k : Int, row : View) -> Double {
    let quiet = gone_quiet.keys().filter(fn(g) { gone_quiet.get(g) == Some(false) }).collect()
    for g in quiet {
      gone_quiet[g] = true
      floor_raise()
      foot_room.set(foot_room.untracked() + slot_tall(g))
    }
    if one_move_key.val is Some((_, kks, _, _)) && kks.contains(k) {
      came_row[k] = row
    }
    let r = foot_room.untracked()
    // (only at its foot, followed: held off it (the room kept for what was pressed, the press's ways ended), the room
    // stays where it shows and what comes under it takes it as it grows, nothing over it moving)
    guard r > 0.0 && came_by_data.val.contains(k) && @signals.untracked(fn() { s.at_foot() }) else { return 0.0 }
    foot_room.set(0.0)
    took_room[k] = (row, r)
    r
  }
  let from_of = fn(k : Int, row : View) -> Double { take_room(k, row) }
  // (a key gone leaving its room: what it showed fading out where it is, as a pick's that leaves (pick_leave.mbt), its
  // slot as tall as it is till that and its way in are done, then let go; back, seen again whole)
  let fade_off = Ref(fn() {  })
  let faded : Array[View] = []
  fade_undo.val = fn(k) {
    for b in blocks {
      if b.0.alive() && @signals.untracked(b.1) == k {
        b.0.alpha(Is(1.0)) |> ignore
      }
    }
  }
  fade_go.val = fn(k) {
    guard fading.val is Some((f, went)) && f == k else { return }
    for b in blocks {
      if b.0.alive() && @signals.untracked(b.1) == k {
        let v = b.0
        let key = b.1
        faded.push(v)
        // (by the key it holds: a block put by and taken for another key meanwhile seen whole)
        v.alpha(
          By(fn() {
            guard key() == k && fading.val is Some((f, _)) && f == k else { return 1.0 }
            let t = v.drawn_while(fn(now) { now < went + list_leaves_ms })
            1.0 - leave_eased((t - went) / list_leaves_ms)
          }),
        )
        |> ignore
      }
    }
    // (as long as that, and as its way in has still to go)
    let mut end = went + list_leaves_ms
    for w in ways {
      if w.1 == k && w.0.live() is Some(m) && m.coming {
        let e = m.flex.style.come_ends
        if e == e && e > end {
          end = e
        }
      }
    }
    (fade_off.val)()
    fade_off.val = self.at_moment(end, fn() {
      guard fading.val is Some((f, _)) && f == k else { return }
      fading.val = None
      // (what was faded and is still there, whole again: let go now, or put by and taken for another key)
      for v in faded {
        if v.alive() {
          v.alpha(Is(1.0)) |> ignore
        }
      }
      faded.clear()
      gone_quiet[k] = false
      fade_rev.set(fade_rev.untracked() + 1)
    })
  }
  self.owns(fn() { (fade_off.val)() }) |> ignore
  // (the room under the last block no more than still showed of it as the list goes back down to it once scrolled
  // up off it: read up by less than the room, off its foot by as much, and on the way back at its foot with what still
  // showed; the scroll read only while there is one; not while what was pressed holds it, as the fill keeps it then)
  let room_x : Ref[Double?] = Ref(None)
  self.reacts(fn() {
    guard foot_room.get() > 0.0 else { return None }
    // (where it comes to rest: where a wheel's notch eases to, else where it is)
    match s.notch.get() {
      Some(nt) if s.fling.get() is None && s.edge.get() is None => Some(nt.x0 + nt.total)
      _ => Some(at())
    }
  }, fn(x) {
    // (at its foot, followed: where it is drawn moves with the room it shows in, no hand's; off it, where it was, and
    // so where it went back down from, at its foot again or not)
    guard x is Some(x) else {
      room_x.val = None
      return
    }
    let was = room_x.val
    room_x.val = if s.at_foot() { None } else { Some(x) }
    guard was is Some(w) && x > w + 0.000001 else { return }
    guard !(pin.val is Some((k, _, _, _)) && laid_at.contains(k)) else { return }
    guard s.seen.untracked() is Some((_, vh)) && vh > 0.0 else { return }
    let all = places(laid.untracked())
    let left = dmax(0.0, top_now(all, w) + vh - blocks_foot(all))
    if left < foot_room.untracked() {
      foot_room.set(left)
    }
  })
  let way_of = fn(k : Int, row : View, coming : Bool) -> Bool {
    // (`flips`: no way of its own, nor any room kept or taken for one: FlipWay's)
    if flips {
      return false
    }
    let ok = @signals.untracked(fn() {
      guard !at_once && !flips && s.seen.get() is Some((_, vh)) && vh > 0.0 else { return false }
      if coming {
        let col = laid.get()
        guard came_by_data.val.contains(k) && laid_at.get(k) is Some(i) && i < col.length() else {
          return false
        }
        let all = places(col)
        if s.at_foot() {
          let end = counted(col)
          end.top(i) + end.h(i) > dmax(0.0, whole_of(end) - vh)
        } else {
          let top = top_now(all, at())
          if anchor_start.val is Some(_) {
            // (held by where what is read starts (View::read_from): where any of it would show under what covers
            // the top, whichever side of the anchor, over it taking its room upward on its way)
            all.top(i) + all.h(i) > top + s.top_covered() && all.top(i) < top + vh
          } else {
            let under = match held_at(all) {
              Some((a, _)) => i > a
              None => true
            }
            under && all.top(i) < top + vh
          }
        }
      } else {
        match gone_from.val.get(k) {
          Some((off, _)) => s.at_foot() || (off >= 0.0 && off < vh)
          None => false
        }
      }
    })
    // (gone leaving its room: at once, the room under the last block as tall as it was, where not counted already)
    match gone_quiet.get(k) {
      Some(counted) if !coming => {
        gone_quiet.remove(k)
        if !counted {
          floor_raise()
          let h = self.tree.along_now(row.at, self.tree.cause_now())
          foot_room.set(foot_room.untracked() + h)
        }
        return false
      }
      _ => ()
    }
    // (come at its foot with no way: it takes the room all the same, there at once)
    if coming && !ok && @signals.untracked(fn() { s.at_foot() }) {
      take_room(k, row) |> ignore
    }
    if ok &&
      coming &&
      @signals.untracked(fn() { comes_whole(k) && s.at_foot() && follows() }) &&
      !@signals.untracked(self.tree.motion_reduced) {
      let alive = whole_rows.filter(fn(r) { r.alive() && r.at != row.at })
      whole_rows.clear()
      whole_rows.append(alive)
      whole_rows.push(row)
      self.tree.nodes[row.at].come_uncut = true
      self.tree.raise_in_list(self.at, whole_rows.map(fn(r) { r.id() }))
    }
    // (carried by a flight in from outside the tree, found as the change is committed (Tree::carried): drawn whole at
    // its foot, as comes_whole says, and its way the flight's rise, as comes_way says)
    if ok && coming {
      let row_at = row.at
      self.tree.carried_rows[row_at] = fn(way) {
        if @signals.untracked(fn() { s.at_foot() && follows() }) && !@signals.untracked(self.tree.motion_reduced) {
          let alive = whole_rows.filter(fn(r) { r.alive() && r.at != row.at })
          whole_rows.clear()
          whole_rows.append(alive)
          whole_rows.push(row)
          self.tree.nodes[row.at].come_uncut = true
          self.tree.raise_in_list(self.at, whole_rows.map(fn(r) { r.id() }))
        }
        self.tree.lead_way(row_at, way)
      }
    }
    // (its way said by its page: given to View::comes as the each sets it off, after this, in this change)
    if ok && coming {
      match @signals.untracked(fn() { comes_way(k) }) {
        Some(w) => {
          self.tree.come_ways_said[row.at] = w
          @signals.after_flush(fn() { self.tree.come_ways_said.remove(row.at) })
        }
        None => ()
      }
    }
    if ok {
      let left = ways.filter(fn(w) { w.0.at != row.at })
      ways.clear()
      ways.append(left)
      ways.push((row, k, if coming { None } else { gone_from.val.get(k).bind(fn(g) { g.1 }) }))
      // (waited for once its end is said: this is asked before the each sets the row off (View::comes), which queues
      // its own wait for the change told whole, the change's layout that measures it and its column's group then; this
      // one queued after those, a wait inside a wait, so that it reads the end they said)
      @signals.after_flush(fn() { @signals.after_flush(fn() { (ways_due.val)() }) })
    }
    ok
  }
  let out = self.scrolls(s, slop?=slop, bar?=bar, top_covered~, bar_clear?, fn(held) {
    held.padding(By(fn() { (0.0, 0.0, 0.0, room_under() + s.tuck_room.get() + foot_room.get()) })) |> ignore
    // (what its blocks hold that comes or goes down a column in them: kept, how long a press there set off goes, and in
    // its one way unless it is said at once)
    held.list_keeps_inner(held.at, !at_once && !flips)
    held_node.val = held.at
    if flips {
      let held_at = held.at
      self.tree.flip_lists[held_at] = fn(at) { (flip_inner_tell.val)(at) }
      held.owns(fn() { self.tree.flip_lists.remove(held_at) }) |> ignore
    }
    // (short of what shows, its blocks at its foot: at least as tall as the room it shows them in, they at its end; with
    // a head, the head at its top, the room left under it, over its blocks)
    if from_end {
      held.min_height_share(Is(Some(1.0))) |> ignore
      if head is None {
        held.lies_along(Is(Lies::End)) |> ignore
      }
    }
    // (its bands, under all its blocks (drawn first): each one ground from where its first block's top is to where its
    // last's foot is, as the blocks are placed when it is drawn (Places, read where it is placed: View::shown_by),
    // nothing laid out for it, nothing of it pressed; placed again as what it says or the column's blocks change)
    match bands {
      Some((bs, look)) =>
        held.each(bs, fn(b) { b.from }, at_once=true, fn(v, b) {
          v.over(Is(true)).points(Is(false)) |> ignore
          look(v, fn() { b.get() })
          v.reacts(
            fn() {
              laid.get() |> ignore
              (b.get(), laid_rev.val)
            },
            fn(_) { if v.alive() { self.tree.place_marked_at(v.at) } },
            at_start=false,
          )
          v.shown_by(held, fn(tall) {
            let band = b.untracked()
            let all = places(laid.untracked())
            let n = all.length()
            match (laid_at.get(band.from), laid_at.get(band.upto)) {
              (Some(i), Some(j)) if i <= j && j < n => {
                let g = all.col.grid
                let on = fn(y : Double) { if g > 0.0 { (y * g + 0.5).floor() / g } else { y } }
                let top = on(all.top(i) + band.top)
                let foot = on(all.top(j) + all.h(j) + band.foot)
                { dx: 0.0, dy: top, dw: 0.0, dh: foot - top - tall, corners: None }
              }
              // (one of its blocks not among the keys now: none drawn)
              _ => { dx: 0.0, dy: 0.0, dw: 0.0, dh: -tall, corners: None }
            }
          })
          |> ignore
        })
      None => ()
    }
    // (its head, over its keys' blocks, as tall as what the page builds in it: where its keys start, its fill measuring it)
    match head {
      Some(make_head) =>
        // (as tall as where its keys start, what the page builds in it at its top)
        held.box(fn(o) {
          o.height(By(fn() { Some(head_tall.get()) })).shrink(Is(0.0)) |> ignore
          o.box(fn(h) {
            h.shrink(Is(0.0)) |> ignore
            head_v.val = Some(h)
            make_head(h)
          })
          |> ignore
        })
        |> ignore
      None => ()
    }
    // (over the slots, as tall as the blocks over them are counted: on the grid, as their tops are)
    held.box(fn(o) {
      if from_end && head is Some(_) {
        o.grow(Is(1.0)) |> ignore
      }
      o
      .height(By(fn() {
        let all = laid.get()
        match slot_keys.get().get(0) {
          Some(k) =>
            match laid_at.get(k) {
              Some(i) if i < all.length() => Some(all.top(i) - all.start)
              _ => Some(0.0)
            }
          None => Some(0.0)
        }
      }))
      .shrink(Is(0.0))
      |> ignore
    })
    |> ignore
    // (a row whose key moved among them by this change, its page saying it reorders: split, asked once)
    // (the row made anew for it another row from the one closing where it was: a number of its own, View::row_place's
    // and what judges how rows go)
    let splits = fn(k : Int) {
      guard moved_now.val.contains(k) else { return false }
      moved_now.val.remove(k)
      row_numbered.val = row_numbered.val + 1
      row_numbers[k] = row_numbered.val
      true
    }
    held.each_by(fn() { slot_keys.get() }, fn(k) { k }, way_of~, from_of~, splits~, fn(slot, item) {
      let k = item.untracked()
      let cell = @signals.signal(shown_now.contains(k), same=fn(a, b) { a == b })
      shown[k] = cell
      slot.owns(fn() { if shown.get(k) is Some(c) && physical_equal(c, cell) { shown.remove(k) } }) |> ignore
      let shows = fn() { cell.get() }
      // (its slot by its key, while it is: how tall it is now, as its room is taken, slot_tall)
      slot_views[k] = slot
      if flips {
        let slot_at = slot.at
        let aux = self.tree.motion_aux()
        aux.flip_rows[slot_at] = fn(w, anew, lead) {
          let now = self.tree.cause_now()
          // (of several flights in this key's block at its change, the longest, but where one leads its flight's others
          // (View::flies_in's `lead`): that one's; one said anew (Tree::flights_refresh_now, the foot's old view built)
          // taken as it is now, shorter or not)
          let keep = match flip_said.val {
            Some((t0, k0, w0)) if !lead &&
              t0 == now &&
              k0 == k &&
              (flip_said_lead.val || (!anew && w0.0 > w.0)) => Some(w0)
            _ => None
          }
          if keep is None {
            flip_said_lead.val = lead
          }
          flip_said.val = Some((now, k, keep.unwrap_or(w)))
          (flip_rebuild.val)()
          // (carried: at its rest from now on, as its flight sets out from here (what holds the flight, as it is drawn
          // off now, is where the flight goes from: Lift's held_off), not as the frame before had it)
          if flip_whole.contains(k) && slot.alive() {
            let d = match (flip_items.get(k), flip_way.untracked()) {
              (Some(it), Some(way)) => {
                let (s, _) = way.left(now)
                (it.off.0 * s, it.off.1 * s)
              }
              _ => (0.0, 0.0)
            }
            self.tree.nodes[slot.at].look.drawn_off = d
          }
        }
        slot.owns(fn() { aux.flip_rows.remove(slot_at) }) |> ignore
        // (how far the way the change at `at` set out has gone where this block is drawn: what a pick leaving in it at
        // that change is held by, to that way's end alone; a later change's way neither sets it out again nor takes it
        // back (the user, 2026-11-17: 「你 选择了…」 and 刚刚 shown twice, a row come under them as they were there);
        // none set out at that moment (or that way over): where it rests)
        aux.flip_gone[slot_at] = fn(v, at) {
          // (told as a way is said: one said for that change after this is first read)
          flip_way.get() |> ignore
          match flip_ways.get(at) {
            Some((ends, gone)) => {
              let t = v.drawn_while(fn(t) { t < ends })
              if t >= ends {
                1.0
              } else {
                gone(t)
              }
            }
            None => 1.0
          }
        }
        slot.owns(fn() { aux.flip_gone.remove(slot_at) }) |> ignore
      }
      // (`flips`: drawn off where it is laid out while its way goes, come by it growing from its top: FlipWay's. Bound
      // as it is made while a way is out, else once one first sets out (the list's one watch, flip_unbound): a block made
      // at rest (a page opened, scrolled to) is drawn where it is laid out and asks nothing of a way that is not there,
      // binding nothing till then (the chat's page's open, chat_nodes_open_budget))
      if flips {
        let bind = fn() {
          if slot.alive() {
            // (exact: what was drawn as the change came is where it is drawn from, to the bit, wherever on the host's pixels
            // that was; on them again at rest)
            slot
            .drawn_off(
              By(fn() {
                // (one a flight carries in: set out where it rests (its offset none), the flight bringing what of it flies
                // there; moved by a change after while the flight goes (the next words sent), on that way as any block,
                // what flies to it going with it: Tree::rides_said_way)
                let (a, b, _, _) = flip_drawn(k, slot)
                // (within a pixel of the host's of where it rests: there, as a row on its grid is at its rest before its
                // way ends, never past it; how far off it its way has it kept for what grows in it on the same way,
                // Node's near_rest. Only once all of it is open, as a row is put on its grid only then: one still growing
                // open from its top drawn where its way has it)
                let open = flip_open(k, slot) == 1.0
                let g = self.tree.rows_grid_now()
                let near = if open && g > 0.0 { 1.0 / g } else { 0.0 }
                self.tree.nodes[slot.at].near_rest = if b.abs() < near { b } else { 0.0 }
                (if a.abs() < near { 0.0 } else { a }, if b.abs() < near { 0.0 } else { b })
              }),
              exact=true,
            )
            // (what it held before its way set out, fading out over its place (a pick's that leaves), cut to where it rests:
            // never drawn over the blocks round it as they come up to it; while it opens or comes to another height on its
            // way alone, not as it only moves: what of it is moved past its sides by what holds the list (a column on its
            // way to another width) drawn there)
            .clips(By(fn() { flip_open(k, slot) < 1.0 || flip_drawn(k, slot).3.abs() > 0.01 }), down=true)
            // (and one closing, cut as tall as it is drawn now, not as it rests: what it held fading in all the room it
            // still takes as the blocks under it come up, from as tall as it was to as it rests; drawn only)
            .clips_past(By(fn() { dmax(0.0, -flip_drawn(k, slot).3) }))
            .scale(By(fn() { flip_open(k, slot) }), about=DrawnSide(0.0))
            // (one a flight carries in open all the way (flip_open), seen whole as in a list not said `flips`: what of it
            // goes with the flight says so itself, by View::flight_across_now or View::flying_now)
            .alpha(By(fn() { row_seen_at(flip_open(k, slot)) }))
            |> ignore
          }
        }
        if @signals.untracked(fn() { flip_way.get() is Some(_) }) {
          bind()
        } else {
          let n = flip_unbound_next.val
          flip_unbound_next.val = n + 1
          flip_unbound[n] = bind
          slot.owns(fn() { flip_unbound.remove(n) }) |> ignore
        }
      }
      slot.owns(fn() { if slot_views.get(k) is Some(v) && physical_equal(v, slot) { slot_views.remove(k) } }) |> ignore
      let my_tall = @signals.signal(heights.get(k), same=fn(a, b) { a == b })
      tall[k] = my_tall
      slot.owns(fn() { if tall.get(k) is Some(c) && physical_equal(c, my_tall) { tall.remove(k) } }) |> ignore
      // (as tall as it is counted, showing or not: as what it holds was told laid out, est before; never as tall as
      // what it holds is while that is still to be laid out, the column's end gone up and back in one frame)
      slot
      .height(By(fn() {
        Some(self.tree.rows_slot(my_tall.get().unwrap_or(est)))
      }))
      .shrink(Is(0.0))
      .holds_whole()
      // (as tall as it is counted, as wide as the column: what changes in what shows laid out from it alone; where that
      // comes out another height than it is counted, or what shows in it was never measured (one taken from another's
      // slot), the column laid out again, which measures it: Tree::alone_asks)
      .lays_out_alone()
      |> ignore
      let slot_at = slot.at
      // (its key's row: where a word in it is placed, View::row_place stops at it)
      self.tree.nodes[slot_at].each_row = true
      // (its number as its slot is made: a key moved among them, its row split, numbered anew for the one opening where
      // it is now, this one closing keeping its own)
      let number = number_of(k)
      let named = (self.id(), fn() { number }, fn() { laid_at.get(k).unwrap_or(-1) })
      self.tree.rows_named[slot_at] = named
      slot.owns(fn() {
        if self.tree.rows_named.get(slot_at) is Some(r) && physical_equal(r.2, named.2) {
          self.tree.rows_named.remove(slot_at)
        }
      })
      |> ignore
      self.tree.alone_asks[slot_at] = fn() {
        // (the block that shows its key)
        guard showing.contains(k) else { return false }
        // (in this slot: another's of the same key, a row split as its key moved, closing where it was, is not it)
        match
          blocks
          .iter()
          .find_first(fn(b) { b.0.alive() && @signals.untracked(b.1) == k && self.tree.holds_at(slot_at, b.0.at) }) {
          Some((v, _)) =>
            match room_w.untracked() {
              // (measured as the column's fill measures it, against how tall it is counted: as it was measured, else
              // `est`; the same, its slot as it is, nothing laid out again)
              Some(w) => {
                let h = self.tree.height_in(v.at, self.at, w)
                if h != heights.get(k).unwrap_or(est) {
                  true
                } else {
                  // (as tall as it was counted, never measured: measured now, what shows under it worked out by that)
                  if heights.get(k) is None {
                    heights[k] = h
                    heights_changed.push(k)
                    tell()
                  }
                  seen_rows[k] = true
                  false
                }
              }
              None => true
            }
          None => false
        }
      }
      slot.owns(fn() { self.tree.alone_asks.remove(slot_at) }) |> ignore
      // (one of a kind another may take: made, or taken from those of its kind put by, as it comes to show; put by as
      // it no more does, for the next of its kind to show)
      match (reused, make_reused) {
        (Some(kind_of), Some(make_by)) if kind_of(k) is Some(kind) => {
          let mine : Ref[(View, @signals.Signal[Int])?] = Ref(None)
          let stop = slot.tree.structured(shows, fn(on) {
            guard slot.alive() else { return }
            match (on, mine.val) {
              (true, None) => {
                slot.tree.work.structure = slot.tree.work.structure + 1
                // (its own if it was put by (gone and come again at once, the window told twice): where it was, as it
                // was; else the last put by)
                let taken = match spare.get(kind) {
                  Some(all) if all.length() > 0 =>
                    match all.search_by(fn(b) { b.1.untracked() == k }) {
                      Some(i) => Some(all.remove(i))
                      None => all.pop()
                    }
                  _ => None
                }
                match taken {
                  // (still in this slot, out of sight: as it was, what it binds read again)
                  Some((v, key, wake, Some(was_in))) if v.alive() && physical_equal(was_in, slot) => {
                    showing[k] = true
                    // (a block given another key, woken: what that makes or lets go in it so at once, as were the
                    // block made anew, answering.mbt; what its parts keep that key's: reused_state.mbt)
                    taken_for(v, key.untracked(), k, wake, key)
                    mine.val = Some((v, key))
                    if !heights.contains(k) {
                      self.tree.layout_marked_at(v.at)
                      self.tree.place_marked_at(v.at)
                    }
                  }
                  // (in another's slot, out of sight there, or held by no node since that slot left what has slots: taken
                  // into this one, made this one's)
                  Some((v, key, wake, was_in)) if v.alive() => {
                    match was_in {
                      Some(w) => w.park(v, rest=false) |> ignore
                      None => ()
                    }
                    slot.take_in(v)
                    showing[k] = true
                    // (a block given another key, woken: what that makes or lets go in it so at once, as were the
                    // block made anew, answering.mbt; what its parts keep that key's: reused_state.mbt)
                    taken_for(v, key.untracked(), k, wake, key)
                    mine.val = Some((v, key))
                  }
                  _ => {
                    let key = @signals.signal(k, same=fn(a, b) { a == b })
                    let v = slot.box(fn(v) {
                      // (what its parts keep of its key: what was kept of it given back as each is made, reused_state.mbt)
                      self.tree.reused_made(v, fn(path) { kept.x_of(k, path) }, fn(path) { kept.bool_of(k, path) }, kept_keys)
                      block(v, fn() { key.get() }, fn(v) { make_by(v, fn() { key.get() }) })
                    })
                    mine.val = Some((v, key))
                  }
                }
              }
              (false, Some((v, key))) => {
                slot.tree.work.structure = slot.tree.work.structure + 1
                mine.val = None
                unshow(k, v.at)
                // (what its parts keep kept by its key, put by or let go: stopped where they are, nothing going on by
                // itself out of sight; given back as a block shows that key again, reused_state.mbt)
                keep_from(v, key.untracked())
                let all = match spare.get(kind) {
                  Some(all) => all
                  None => {
                    let all = []
                    spare[kind] = all
                    all
                  }
                }
                // (left where it is, in its slot out of sight, what it binds at rest: nothing drawn changes as it goes,
                // so it is drawn again for nothing; moved only as the next to show takes it)
                if all.length() < spare_most && v.alive() {
                  // (its key gone from the list: let go with its slot, as were every slot kept; a slot counted at est
                  // cannot keep a block that may exceed est and overflow into sight)
                  if (slot_keys.untracked().contains(k) && heights.contains(k)) || !laid_at.contains(k) {
                    let wake = v.rests()
                    all.push((v, key, wake, Some(slot)))
                  } else {
                    // (its slot no more among those kept (found anew in the same change, let go as it is told), or its
                    // height forgotten: taken out of it first, held by no node, so the slot's going lets go none of it)
                    let wake = slot.park(v)
                    all.push((v, key, wake, None))
                  }
                } else {
                  slot.drop(v)
                }
              }
              _ => ()
            }
          })
          // (its slot let go: what shows in it let go with it, as what it holds)
          slot.owns(fn() {
            stop()
            if mine.val is Some((v, _)) {
              unshow(k, v.at)
              mine.val = None
            }
            // (what was put by in it let go with it)
            match spare.get(kind) {
              Some(all) =>
                match all.search_by(fn(b) { b.3 is Some(w) && physical_equal(w, slot) }) {
                  Some(i) => all.remove(i) |> ignore
                  None => ()
                }
              None => ()
            }
          })
          |> ignore
        }
        _ =>
          // (a block made or let go as it comes to show or leaves it as the list scrolls: there at once, no way of its
          // own; what it holds makes its way in it as anywhere)
          slot.show(shows, fn(v) { block(v, fn() { k }, fn(v) { make(v, k) }) }, at_once=true)
      }
    })
    // (under the slots, as tall as the blocks under them are counted)
    held.box(fn(o) {
      o
      .height(By(fn() {
        let all = laid.get()
        let foot = counted(all).foot()
        match slot_keys.get().last() {
          Some(k) =>
            match laid_at.get(k) {
              Some(i) if i < all.length() => Some(dmax(0.0, foot - (all.top(i) + all.h(i))))
              _ => Some(foot - all.start)
            }
          None => Some(foot - all.start)
        }
      }))
      .shrink(Is(0.0))
      |> ignore
    })
    |> ignore
  })
  // (its foot: pinned at the foot of what shows, over what scrolls (drawn after it, what is under it its own), as wide
  // as the list; as tall as what the page builds in it, its fill measuring it, the room kept under its last block)
  match foot {
    Some(make_foot) =>
      self.box(fn(f) {
        let fs = self.tree.nodes[f.at].flex.style
        fs.position = @flex.PositionType::Absolute
        fs.set_inset_left(Pt(0.0))
        fs.set_inset_right(Pt(0.0))
        fs.set_inset_bottom(Pt(0.0))
        fs.set_inset_top(Auto)
        // (as tall as the room under the last block, on the grid: what the page builds in it at its top, as the head's)
        f.height(By(fn() { Some(foot_h.get()) })).shrink(Is(0.0)) |> ignore
        // (what flies from a thing in it may be drawn under it: Scroll's foot_at)
        let foot_at = f.at
        s.foot_at = foot_at
        f.owns(fn() { if s.foot_at == foot_at { s.foot_at = -1 } }) |> ignore
        // (what comes, goes or resizes in it goes in the list's one way, as what its blocks hold does, unless it is said
        // at once: Tree::come_group_join by Tree's list_feet)
        if !at_once && held_node.val >= 0 {
          let tree = self.tree
          let at = f.at
          tree.list_feet[at] = held_node.val
          f.owns(fn() { tree.list_feet.remove(at) }) |> ignore
        }
        f.box(fn(i) {
          i.shrink(Is(0.0)) |> ignore
          foot_v.val = Some(i)
          make_foot(i)
          // (an old view in it: laid out as tall as it is only once it is built (Tree::old_views_built), the list laid out
          // again then; till then no ask to bring a block is taken by where it ends: foot_unbuilt)
          if self.tree.holds_hosted(i.at) {
            foot_unbuilt.val = true
            let begun = self.tree.old_builds_begun
            fn wait_built(settled : Bool) -> Unit {
              if !settled && (self.tree.old_builds <= begun || self.tree.holds_unlaid_hosted(i.at)) {
                self.tree.old_built_waits.push(wait_built)
              } else {
                foot_unbuilt.val = false
                // (an ask kept for it taken now; nothing else laid out again for it: the foot's own height laid out
                // as it is built tells the list as ever)
                match place {
                  Some(p) if p.asked is Some(_) => laid_again()
                  _ => ()
                }
              }
            }
            self.tree.old_built_waits.push(wait_built)
          }
        })
        |> ignore
      })
      |> ignore
    None => ()
  }
  // (those put by let go with the list: held by nothing, let go by nothing else)
  self.owns(spare_let_go) |> ignore
  out
}

///|
/// How far past where a page's list shows, in its heights, its slots reach over and under as they are found again
/// (View::scrolls_window): a screen, so that what a hand's move or a wheel's turn brings in is there already.
let slots_margin : Double = 1.0

///|
/// How near where a page's list shows comes to its slots' end, in its heights, before they are found again: half the
/// margin, so they are widened before what shows reaches their end, not as it does.
let slots_near : Double = 0.5

///|
/// How far past where a page's list shows its slots may reach, in its heights, before they are found again narrower:
/// twice the margin, so that a wheel going back and forth over where they end widens once and narrows never.
let slots_far : Double = 2.0

///|
/// How many blocks of one kind a list keeps put by (View::scrolls_window's `reused`): as many as come to show at once
/// as it is scrolled, the rest let go.
let spare_most : Int = 4

///|
/// How long what a key gone leaving its room showed takes to fade out where it is (View::scrolls_window's
/// `leaves_room`): as what goes from a list (the app's leave_ms), its fade alone.
let list_leaves_ms : Double = 200.0

///|
/// Further than this many of its heights from where it is asked to go, a page's list goes there at once, not gliding
/// (an old view's list's list_glide_rows).
let glide_most : Double = 2.0

///|
/// What a page's list is asked to show at a cause (ListPlace), done as its column is next laid out: a block brought to
/// its top (`off` under it; what it marks sought in it before the eyes too where the third says so: View::sought) or to
/// the middle.
priv enum ListAsk[K] {
  Bring(K, Double, Bool)
  /// what the block marks sought (View::sought) put this far under what covers its top (ListPlace::bring_sought)
  BringSought(K, Double)
  Centre(K)
  ToEnd
}

///|
/// What asks a page's list (View::scrolls_window's `place`) to show a block or its foot, as a press or what comes in
/// asks it (a cause, in its handler): each asked once, done as the column is next laid out (in that layout, by its
/// anchor: what is over it measured anew moves none of it), or gliding there from where it is, at that moment. One
/// asked before the block is among its keys waits for it; a later one in its place.
pub struct ListPlace[K] {
  priv at : PlaceAt
  priv ids : ListKeys[K]
}

///|
/// What a ListPlace keeps, of its list's keys by their numbers (ListKeys), as View::scrolls_window_ids reads and sets it.
priv struct PlaceAt {
  mut asked : ListAsk[Int]?
  mut jumped_to_end : Bool
  /// its foot followed no further than this block's top so far under what covers its top (ListPlace::follow_from): a
  /// standing limit, kept as it takes hold, till the hand takes the list, an ask, another said, or its key goes
  mut from : (Int, Double)?
  /// whether the key `from` names has been among the keys since it was said (gone after that, the limit goes with it)
  mut from_met : Bool
  /// said (ListPlace::follow_from) since the list's last fill took it: where the one before held it, the reader not
  /// having moved it, it follows its foot again for this one
  mut from_new : Bool
  mut laid_again : () -> Unit
  mut glide : (ListAsk[Int]) -> Bool
  /// what is told what is in sight as that changes (ListPlace::on_sight), what was told last (ListPlace::sight_now),
  /// and what its list has in sight as it is counted now (none before it is made)
  sight_fns : Array[(Sight[Int]) -> Unit]
  mut sight : Sight[Int]?
  mut sight_of : () -> Sight[Int]?
  mut sight_listened : () -> Unit
  /// how far one block's top lies under another's, by their numbers, as its list counts its blocks now
  /// (ListPlace::span_between; none before it is made; as last counted once it is let go, as `sight_of`)
  mut span_of : (Int, Int, Bool) -> Double?
}

///|
/// The keys of a page's list by number: each key given one as it is first seen (among its keys, asked of its place, a
/// band's), the same one for as long as the list is, so a number stands for one key and a key for one number and its
/// work, compiled once (View::scrolls_window_ids), compares and keeps them by number as it kept the keys. Kept as long
/// as the list: as its heights and what its rows kept are, a key's own.
priv struct ListKeys[K] {
  ids : Map[K, Int]
  keys : Array[K]
  // (the keys last numbered whole and their numbers: the same array asked again, its keys the same, is the same
  // numbers' array, so what the list's work tells by its keys being the same array is as it was)
  mut last : (Array[K], Array[Int])?
}

///|
fn[K : Hash + Eq] ListKeys::new() -> ListKeys[K] {
  { ids: Map([]), keys: [], last: None }
}

///|
fn[K : Hash + Eq] ListKeys::id(self : ListKeys[K], k : K) -> Int {
  match self.ids.get(k) {
    Some(i) => i
    None => {
      let i = self.keys.length()
      self.ids[k] = i
      self.keys.push(k)
      i
    }
  }
}

///|
fn[K] ListKeys::key(self : ListKeys[K], i : Int) -> K {
  self.keys[i]
}

///|
fn[K : Hash + Eq] ListKeys::all(self : ListKeys[K], ks : Array[K]) -> Array[Int] {
  if self.last is Some((was, nums)) && physical_equal(was, ks) && nums.length() == ks.length() {
    let mut same = true
    for j, k in ks {
      if self.id(k) != nums[j] {
        same = false
        break
      }
    }
    if same {
      return nums
    }
  }
  let nums = ks.map(fn(k) { self.id(k) })
  self.last = Some((ks, nums))
  nums
}

///|
/// One for a page's list, asking nothing yet.
pub fn[K : Hash + Eq] ListPlace::new() -> ListPlace[K] {
  {
    at: {
      asked: None,
      jumped_to_end: false,
      from: None,
      from_met: false,
      from_new: false,
      laid_again: fn() {  },
      glide: fn(_) { false },
      sight_fns: [],
      sight: None,
      sight_of: fn() { None },
      sight_listened: fn() {  },
      span_of: fn(_, _, _) { None },
    },
    ids: ListKeys::new(),
  }
}
///|
/// Block `key` brought to the top of where the list shows, under what covers its top (Scroll::top_covered: the bar it
/// runs under; none, its own top), `offset` above that edge (its top that far over it, under it where less than 0: what
/// is in sight told as `first` and `into`, `first` brought with `into` is where it was), as far as the list goes
/// (Ctx::list_scroll_to's): gliding there where `glide` and it is near. `sought`: and what the block holds of what a
/// go-to brings (View::sought) before the eyes, in the same fill: where it would lie low (its middle past 80% of the
/// room between what covers the list's top and its pinned foot's top), its middle at the middle of that room instead
/// (list_sought.mbt), as far as the list goes; gliding there too where `glide` and it is near, as it is laid out then.
pub fn[K : Hash + Eq] ListPlace::bring(
  self : ListPlace[K],
  key : K,
  offset? : Double = 0.0,
  glide? : Bool = false,
  sought? : Bool = false,
) -> Unit {
  self.at.bring(self.ids.id(key), offset~, glide~, sought~)
}

///|
/// ListPlace::bring, of a key by its number.
fn PlaceAt::bring(self : PlaceAt, key : Int, offset? : Double = 0.0, glide? : Bool = false, sought? : Bool = false) -> Unit {
  self.from = None
  self.jumped_to_end = false
  if glide && (self.glide)(Bring(key, offset, sought)) {
    self.asked = None
    return
  }
  self.asked = Some(Bring(key, offset, sought))
  (self.laid_again)()
}

///|
/// Block `key` brought so that what it marks sought (View::sought: a place in its words, where a text was left or a
/// find goes) stands `under` under what covers the list's top (Scroll::top_covered), its top that far down the room,
/// wherever in the block it lies, as far as the list goes; where the block marks none, its top there. In one fill, the
/// block measured as it is laid out (a reader's column opened where it was left: an old view's list scrolled there a
/// frame after its height was laid out). Not gliding.
pub fn[K : Hash + Eq] ListPlace::bring_sought(self : ListPlace[K], key : K, under? : Double = 0.0) -> Unit {
  self.at.from = None
  self.at.asked = Some(BringSought(self.ids.id(key), under))
  (self.at.laid_again)()
}

///|
/// Whether something asked of it (a block brought, its foot) is still to be done by its list's next layout: what it
/// has in sight told meanwhile (ListPlace::on_sight, at the input that asked it) is where it was, not where it goes.
pub fn[K] ListPlace::asking(self : ListPlace[K]) -> Bool {
  self.at.asked is Some(_)
}

///|
/// Block `key` brought to the middle of where the list shows, between what covers its top (Scroll::top_covered) and its
/// pinned foot's top, its middle there as tall as it is counted then (an entry gone to).
pub fn[K : Hash + Eq] ListPlace::centre(self : ListPlace[K], key : K) -> Unit {
  self.at.from = None
  self.at.jumped_to_end = false
  self.at.asked = Some(Centre(self.ids.id(key)))
  (self.at.laid_again)()
}

///|
/// Back to the list's foot (Ctx::list_to_end's): gliding there where `glide` and it is near (else at once), followed
/// there from then where its list follows its foot.
pub fn[K] ListPlace::to_end(self : ListPlace[K], glide? : Bool = true) -> Unit {
  self.at.to_end(glide~)
}

///|
/// ListPlace::to_end.
fn PlaceAt::to_end(self : PlaceAt, glide? : Bool = true) -> Unit {
  self.from = None
  self.jumped_to_end = false
  self.asked = None
  if glide && (self.glide)(ToEnd) {
    return
  }
  self.jumped_to_end = true
  self.asked = Some(ToEnd)
  (self.laid_again)()
}

///|
/// Its foot, where its list follows it, followed no further than block `key`'s top `margin` under what covers its top
/// (Scroll::top_covered: the bar it runs under; none, its own top), as a block brought is (Ctx::list_follow_from's: a
/// message come while it is at its foot read from its start). A standing limit (the coordinator of the migration,
/// 2026-11-14): not used up as it takes hold, it stands till the hand takes the list (a drag, the wheel, a key that
/// scrolls, the bar's thumb; to its foot too: the reader's choice, followed from there), an ask (`bring`, `centre`,
/// `to_end`, a glide), another said here (or None), or its key is no longer among the keys. While it stands and binds
/// (that top would go over the margin at its foot), the list is held by that top at the margin and is off its foot to
/// every rule of its foot, however near the foot it lies (Scroll::at_foot_now false, a key come after not followed by
/// the list itself), from the frame it would go further, however its key comes (on its way or at once) or grows; while
/// it stands and does not bind (all from that key down fits), the list is at its foot as any, following it, held again
/// as it comes to bind. Held so and not moved by the reader, it still follows its foot (Scroll::follows_now: the old
/// view's list's `following_row`), so another said then (a key come after it, or None) takes it back to its foot first,
/// held by that one from there; said while it glides back to its foot (`to_end`), that glide ends where this one holds
/// it. None: followed all the way again. (Counted from the list's own top till 2026-11-14, when only its own test said
/// it, under no cover.)
pub fn[K : Hash + Eq] ListPlace::follow_from(self : ListPlace[K], key : K?, margin? : Double = 0.0) -> Unit {
  self.at.from = key.map(fn(k) { (self.ids.id(k), margin) })
  self.at.from_met = false
  self.at.from_new = true
  (self.at.laid_again)()
}

///|
/// The passes of all page's lists' fills (View::scrolls_window's), counted for its tests: what a scroll or a change
/// laid out again, measured and made in each.
// kept across runs: only counted on, each test reading how far it went
let fill_passes : Ref[Int] = Ref(0)

///|
/// Which of `was` (where those that stay were among them before, in their order now) are among the most still in the
/// order they had: a longest increasing run of them. The others are the fewest that moved (View::scrolls_window's
/// `reorders`).
fn in_order_most(was : Array[Int]) -> Array[Bool] {
  let n = was.length()
  let ends : Array[Int] = []
  let back = Array::make(n, -1)
  for i in 0..<n {
    let mut lo = 0
    let mut hi = ends.length()
    while lo < hi {
      let mid = (lo + hi) / 2
      if was[ends[mid]] < was[i] {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    if lo > 0 {
      back[i] = ends[lo - 1]
    }
    if lo == ends.length() {
      ends.push(i)
    } else {
      ends[lo] = i
    }
  }
  let kept = Array::make(n, false)
  let mut i = if ends.is_empty() { -1 } else { ends[ends.length() - 1] }
  while i >= 0 {
    kept[i] = true
    i = back[i]
  }
  kept
}
