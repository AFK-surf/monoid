// A list kept by key, read by member (SolidJS's store over a keyed list, `reconcile` by key): its order is one signal,
// each item one of its own. What reads an item is told only as that item changes, what reads the order only as an item
// comes, goes or moves; a change to one item tells nothing else, and nothing is compared but what was changed. So a
// list a source changes item by item (a core's keyed ops: put, patch, drop, move) is changed here the same way, and
// what reads it does work for what changed alone (the model's 2: only what is needed is done).

///|
/// A list of values by their keys, in an order.
pub struct KeyedList[K, V] {
  /// its keys in order: a new array as the order changes (what read the one before still holds it as it was)
  priv mut order : Array[K]
  priv vals : Map[K, V]
  /// told as the order changes
  priv order_said : Signal[Int]
  /// a signal for each key read (its value's version), made as it is first read
  priv said : Map[K, Signal[Int]]
  /// whether two values are the same (none told where an item is put as it was)
  priv same : (V, V) -> Bool
}

///|
/// An empty one, `same` saying when a value put is as it was (by default, physically the same).
pub fn[K : Hash + Eq, V] keyed_list(same? : (V, V) -> Bool = fn(a, b) { physical_equal(a, b) }) -> KeyedList[K, V] {
  { order: [], vals: {}, order_said: signal(0), said: {}, same }
}

///|
/// Its keys in order: what reads them is told as one comes, goes or moves, never as an item changes. Not to be changed
/// by the reader.
pub fn[K, V] KeyedList::keys(self : KeyedList[K, V]) -> Array[K] {
  self.order_said.get() |> ignore
  self.order
}

///|
/// Its keys in order, as they stand, read by nothing.
pub fn[K, V] KeyedList::peek_keys(self : KeyedList[K, V]) -> Array[K] {
  self.order
}

///|
/// The value of `k` (none where it is not in it): what reads it is told as that value changes, comes or goes, nothing
/// else.
pub fn[K : Hash + Eq, V] KeyedList::get(self : KeyedList[K, V], k : K) -> V? {
  let s = match self.said.get(k) {
    Some(s) => s
    None => {
      let s = signal(0)
      self.said[k] = s
      s
    }
  }
  s.get() |> ignore
  self.vals.get(k)
}

///|
/// The value of `k` as it stands, read by nothing.
pub fn[K : Hash + Eq, V] KeyedList::peek(self : KeyedList[K, V], k : K) -> V? {
  self.vals.get(k)
}

///|
/// How many it holds, read by nothing.
pub fn[K, V] KeyedList::count(self : KeyedList[K, V]) -> Int {
  self.order.length()
}

///|
/// What read `k` told (where anything did).
fn[K : Hash + Eq, V] KeyedList::tell(self : KeyedList[K, V], k : K) -> Unit {
  match self.said.get(k) {
    Some(s) => s.set(s.untracked() + 1)
    None => ()
  }
}

///|
/// The order is now `order`.
fn[K, V] KeyedList::ordered(self : KeyedList[K, V], order : Array[K]) -> Unit {
  self.order = order
  self.order_said.set(self.order_said.untracked() + 1)
}

///|
/// Where `k` is in the order (-1: not in it). Walks the order: for what changes it, never for what reads an item.
fn[K : Eq, V] KeyedList::index(self : KeyedList[K, V], k : K) -> Int {
  // (from the end: what comes, goes or moves is mostly what is new)
  let mut i = self.order.length() - 1
  while i >= 0 {
    if self.order[i] == k {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// `k`'s value `v` (a key's patch, or a value put for it again): only what read `k` told, and only where it is not the
/// same as it was. A key not in it comes in before `before` (at the end where that is none or not in it).
pub fn[K : Hash + Eq, V] KeyedList::put(self : KeyedList[K, V], k : K, v : V, before? : K? = None) -> Unit {
  match self.vals.get(k) {
    Some(was) => {
      if (self.same)(was, v) {
        return
      }
      self.vals[k] = v
      self.tell(k)
    }
    None => {
      start_batch()
      self.vals[k] = v
      let order = self.order.copy()
      let at = match before {
        Some(b) => self.index(b)
        None => -1
      }
      if at < 0 {
        order.push(k)
      } else {
        order.insert(at, k)
      }
      self.ordered(order)
      self.tell(k)
      end_batch()
    }
  }
}

///|
/// `k` taken out: what read it and what reads the order told (nothing where it was not in it). A key nothing reads is
/// let go of with it.
pub fn[K : Hash + Eq, V] KeyedList::drop(self : KeyedList[K, V], k : K) -> Unit {
  guard self.vals.contains(k) else { return }
  start_batch()
  self.vals.remove(k)
  let order = self.order.copy()
  let at = self.index(k)
  if at >= 0 {
    order.remove(at) |> ignore
  }
  self.ordered(order)
  match self.said.get(k) {
    Some(s) => if s.watched() { s.set(s.untracked() + 1) } else { self.said.remove(k) }
    None => ()
  }
  end_batch()
}

///|
/// `k` moved before `before` (to the end where that is none or not in it): only what reads the order told.
pub fn[K : Eq, V] KeyedList::move_before(self : KeyedList[K, V], k : K, before? : K? = None) -> Unit {
  let from = self.index(k)
  guard from >= 0 else { return }
  let order = self.order.copy()
  order.remove(from) |> ignore
  let at = match before {
    Some(b) if b != k => {
      let mut i = -1
      for j, o in order {
        if o == b {
          i = j
          break
        }
      }
      i
    }
    _ => -1
  }
  if at < 0 {
    order.push(k)
  } else {
    order.insert(at, k)
  }
  if order == self.order {
    return
  }
  self.ordered(order)
}

///|
/// It holds `keys`, in that order, with their values `vals` (a source's whole value: its first, or one asked again):
/// each key whose value is not the same as it was told, the order told only where it is another; the keys gone taken
/// out. The one change that compares all of it.
pub fn[K : Hash + Eq, V] KeyedList::reset(self : KeyedList[K, V], keys : Array[K], vals : Map[K, V]) -> Unit {
  start_batch()
  let gone : Array[K] = []
  self.vals.each(fn(k, _) { if !vals.contains(k) { gone.push(k) } })
  for k in gone {
    self.vals.remove(k)
    match self.said.get(k) {
      Some(s) => if s.watched() { s.set(s.untracked() + 1) } else { self.said.remove(k) }
      None => ()
    }
  }
  for k in keys {
    match vals.get(k) {
      Some(v) =>
        match self.vals.get(k) {
          Some(was) if (self.same)(was, v) => ()
          _ => {
            self.vals[k] = v
            self.tell(k)
          }
        }
      None => ()
    }
  }
  if keys != self.order {
    self.ordered(keys.copy())
  }
  end_batch()
  // (what was read once and is read no more, kept by none: let go)
  if self.said.length() > 64 && self.said.length() > 4 * (self.vals.length() + 1) {
    let unread : Array[K] = []
    self.said.each(fn(k, s) { if !s.watched() && !self.vals.contains(k) { unread.push(k) } })
    for k in unread {
      self.said.remove(k)
    }
  }
}
