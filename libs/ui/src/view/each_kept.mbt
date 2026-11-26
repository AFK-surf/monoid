// A row of View::each kept as its key leaves (its `keeps`): put by (View::park: held by no node, so not laid out,
// placed, drawn, pressed, focused or read out; what it binds at rest via Tree::rest_begin / @signals.rest: what is held
// while it is read let go of on deep park, nothing of it worked out again meanwhile) instead of let go, and taken in
// again (View::take_in, its item set, woken in pre-order, put in its order by each_place) as its key is among the items
// again: the same nodes, as they were left. Let go (via retire_parked during events/ways, else let_go) as its key is no
// more kept, and with the each. Nothing else of it is its own: no way in or out (it is there already, or out of sight
// at once). By default, View::at_moment entries still come due while resting (at_rest_today_wbtest.mbt); pass
// `while_active=true` (or use View::while_active_every) for park-aware timers that unschedule on rest and wake at most
// once. Nested EachKept pools propagate outer deep sleep onto still-covered (`holding=true`) entries and restore their
// covered state on outer wake.

///|
/// Non-generic nested parking pool propagator owned by `EachKept`: tracks still-covered (`holding=true`) entries so
/// outer `deep` sleep propagates into them without monomorphizing per `[K, T]`, and handles same-batch races where an
/// inner entry enters `holding` while an outer `deep` scope is already active.
priv struct NestedPool {
  slot : View
  holding : Array[View]
  outer_buckets : Array[Array[() -> Unit]]
}

///|
fn NestedPool::new(slot : View) -> NestedPool {
  let pool : NestedPool = { slot, holding: [], outer_buckets: [] }
  slot.register_nested_pool(fn() {
    let bucket : Array[() -> Unit] = []
    for v in pool.holding {
      if v.alive() {
        bucket.push(pool.slot.tree.rest_begin(v.at, drop_holds=true))
      }
    }
    pool.outer_buckets.push(bucket)
    fn() {
      match pool.outer_buckets.search_by(fn(b) { physical_equal(b, bucket) }) {
        Some(i) => pool.outer_buckets.remove(i) |> ignore
        None => ()
      }
      for r in bucket {
        r()
      }
      bucket.clear()
      bucket.shrink_to_fit()
    }
  })
  pool
}

///|
fn NestedPool::add_holding(self : NestedPool, v : View) -> Unit {
  self.holding.push(v)
  // Same-batch race guard: if one or more outer deep scopes are already active on `slot`, immediately apply deep to `v`.
  if self.outer_buckets.length() > 0 && v.alive() {
    for bucket in self.outer_buckets {
      bucket.push(self.slot.tree.rest_begin(v.at, drop_holds=true))
    }
  }
}

///|
fn NestedPool::remove_holding(self : NestedPool, v : View) -> Unit {
  match self.holding.search_by(fn(x) { x.same(v) }) {
    Some(i) => {
      self.holding.remove(i) |> ignore
      if self.holding.is_empty() {
        self.holding.shrink_to_fit()
      }
    }
    None => ()
  }
}

///|
fn NestedPool::clear(self : NestedPool) -> Unit {
  self.holding.clear()
  self.holding.shrink_to_fit()
}

///|
/// What an each keeps of the rows whose keys left: `keys_of` the keys kept, read where the items are read (a change of
/// it is a change of them, View::each); `keys` as it was read last; each row put by with what wakes it; the wakings due
/// as the change taking them in ends.
priv struct EachKept[K, T] {
  keys_of : () -> Array[K]
  keeps_holds : (K) -> Bool
  mut keys : Array[K]
  put_by : Map[K, (View, @signals.Signal[T], Array[() -> Unit], Ref[Bool])]
  wakes : Array[() -> Unit]
  pool : NestedPool
}

///|
fn[K : Hash + Eq, T] EachKept::new(
  slot : View,
  keys_of : () -> Array[K],
  keeps_holds : (K) -> Bool,
) -> EachKept[K, T] {
  { keys_of, keeps_holds, keys: [], put_by: Map([]), wakes: [], pool: NestedPool::new(slot) }
}

///|
/// The row put by for key `k`, as its item `it` is among the items again: taken into `slot` (after what it holds: put in
/// its order as the change ends, each_place), its item set as it rests (worked out as it wakes), its waking due as the
/// change ends (each_kept_settle). None: none put by for it.
fn[K : Hash + Eq, T] each_kept_takes(
  slot : View,
  kept : EachKept[K, T]?,
  k : K,
  it : T,
) -> (View, @signals.Signal[T])? {
  guard kept is Some(e) && e.put_by.get(k) is Some((v, item, wakes, holding)) else { return None }
  e.put_by.remove(k)
  if holding.val {
    holding.val = false
    e.pool.remove_holding(v)
  }
  guard v.alive() else { return None }
  slot.take_in(v)
  item.set(it)
  e.wakes.push(fn() {
    answering(fn() {
      for w in wakes {
        w()
      }
    })
  })
  Some((v, item))
}

///|
/// Row `r` of key `k`, gone from the items, put by where its key is kept (before it is asked of any way out: it takes
/// none); whether it was.
fn[K : Hash + Eq, T] each_kept_parks(
  slot : View,
  kept : EachKept[K, T]?,
  k : K,
  r : (View, @signals.Signal[T]),
) -> Bool {
  guard kept is Some(e) && e.keys.contains(k) && r.0.alive() else { return false }
  if !(e.keeps_holds)(k) {
    let wake = slot.park(r.0)
    e.put_by[k] = (r.0, r.1, [wake], Ref(false))
  } else {
    slot.park(r.0, rest=false) |> ignore
    let wakes : Array[() -> Unit] = []
    let holding = Ref(true)
    e.put_by[k] = (r.0, r.1, wakes, holding)
    e.pool.add_holding(r.0)
    slot.tree.after_bindings.push(fn() {
      if e.put_by.contains(k) && r.0.alive() && holding.val {
        wakes.push(slot.tree.rest_begin(r.0.at, drop_holds=false))
      }
    })
  }
  true
}

///|
/// As a change of the each ends: those put by whose keys are no more kept let go (held by nothing, let go by nothing
/// else), those that stopped keeping holds drop their holds, and those taken in woken, each binding that let go of what
/// it read or whose reads changed meanwhile worked out anew, in their places.
fn[K : Hash + Eq, T] each_kept_settle(slot : View, kept : EachKept[K, T]?) -> Unit {
  guard kept is Some(e) else { return }
  let gone = e.put_by.keys().filter(fn(k) { !e.keys.contains(k) }).collect()
  for k in gone {
    match e.put_by.get(k) {
      Some((v, _, _, holding)) => {
        if holding.val {
          holding.val = false
          e.pool.remove_holding(v)
        }
        e.put_by.remove(k)
        if v.alive() {
          if slot.tree.in_events > 0 || slot.tree.ways_going_at(slot.tree.logic) {
            v.retire_parked()
          } else {
            v.let_go()
          }
        }
      }
      None => ()
    }
  }
  for k, entry in e.put_by {
    let (v, _, wakes, holding) = entry
    if holding.val && !(e.keeps_holds)(k) {
      holding.val = false
      e.pool.remove_holding(v)
      if v.alive() {
        wakes.push(slot.tree.rest_begin(v.at, drop_holds=true))
      }
    }
  }
  let wakes = e.wakes.copy()
  e.wakes.clear()
  e.wakes.release_unused(placeholder=run_gone)
  for w in wakes {
    w()
  }
}

///|
/// All it put by let go, with the each.
fn[K, T] EachKept::let_go_all(self : EachKept[K, T]) -> Unit {
  let all = self.put_by.values().collect()
  self.put_by.clear()
  self.pool.clear()
  for r in all {
    (r.3).val = false
    r.0.let_go()
  }
}
