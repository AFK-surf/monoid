// What a node reads out of a whole value by key (SolidJS's store reconciled over a keyed list, and its selector): a
// source that gives its list whole each time (an array worked out again, a topic's value) is kept by key as the node's
// own, so a row reading its own item is told only as that item changes, never as another does; and one key chosen of
// many (the one picked, the one in the hand) is read by member, so a change of choice tells the two rows it concerns.
// A row that looks its item up in the whole list (a find in it, a contains) is woken by every change of every item and
// walks all of them: n rows, n times n (detlint's `each-lookup`).

///|
/// `items()` kept by `key_of` as this node's own (a KeyedList): each new value of it put whole (KeyedList::reset), so
/// what reads an item by its key (`get`) is told only as that item comes out otherwise by `same` (by default, by its
/// data), comes or goes, and what reads its keys (`keys`) only as one comes, goes or moves. Two items of one key: the
/// first is the one kept. Followed while the node lives, as a node's reaction is (View::reacts: at rest with it, read
/// anew as it wakes), let go with it.
pub fn[K : Hash + Eq, V : Eq] View::keyed_by(
  self : View,
  items : () -> Array[V],
  key_of : (V) -> K,
  same? : (V, V) -> Bool = @signals.same_value,
) -> @signals.KeyedList[K, V] {
  let list : @signals.KeyedList[K, V] = @signals.keyed_list(same~)
  self.reacts(items, fn(all) {
    let keys : Array[K] = []
    let vals : Map[K, V] = Map([])
    for v in all {
      let k = key_of(v)
      if vals.contains(k) {
        continue
      }
      keys.push(k)
      vals[k] = v
    }
    list.reset(keys, vals)
  })
  list
}

///|
/// Whether a key is the one `chosen()` says (none: no key is), read by member (a Keyed): what reads it for a key is
/// told only as that key comes to be chosen or stops being so, never as the choice moves between two others. Followed
/// while the node lives, as View::keyed_by's source is.
pub fn[K : Hash + Eq] View::selected(self : View, chosen : () -> K?) -> (K) -> Bool {
  let set : @signals.Keyed[K] = @signals.keyed()
  self.reacts(chosen, fn(c) {
    match c {
      Some(k) => set.set([k])
      None => set.set([])
    }
  })
  fn(k) { set.has(k) }
}
