// A subscription's deltas applied as the core applies them (client/core-ts/src/collections.ts `applyKeyed`, which the
// web's and Android's appliers match): `set`, `append` and `remove` at a path; keyed `put`, `patch`, `drop` and
// `move` on a list's item found by its key. Nothing is changed in place on the input: only the arrays and objects
// along touched paths are copied (at most once per `apply_delta` call via Copy-on-Write), so a value a view still
// holds stays as it was, and the parts that did not change are shared.
// An op that does not fit its value (a path through what is not there) is skipped, as the core skips it.

///|
/// Structural equality on `Json` that short-circuits via `physical_equal` at every container and string node,
/// avoiding deep re-walks over unchanged subtrees shared across `apply_delta` updates.
pub fn json_same(a : Json, b : Json) -> Bool {
  if physical_equal(a, b) {
    return true
  }
  match (a, b) {
    (Null, Null) | (True, True) | (False, False) => true
    (Number(x, ..), Number(y, ..)) => x == y
    (String(x), String(y)) => physical_equal(x, y) || x == y
    (Array(x), Array(y)) => {
      if physical_equal(x, y) {
        return true
      }
      if x.length() != y.length() {
        return false
      }
      for i = 0; i < x.length(); i = i + 1 {
        if !json_same(x[i], y[i]) {
          return false
        }
      }
      true
    }
    (Object(x), Object(y)) => {
      if physical_equal(x, y) {
        return true
      }
      if x.length() != y.length() {
        return false
      }
      for k, v in x {
        match y.get(k) {
          Some(w) => if !json_same(v, w) { return false }
          None => return false
        }
      }
      true
    }
    _ => false
  }
}

///|
/// Copy-on-Write overlay for a single `apply_delta` invocation with multiple ops: each touched object or array is
/// copied at most once, while untouched subtrees remain `Shared(Json)` preserving pointer identity and immutability
/// of both the input `value` and `ops`.
priv enum Cow {
  Shared(Json)
  Obj(Map[String, Json], Map[String, Cow])
  Arr(CowArr)
}

///|
priv struct CowArr {
  mut items : Array[Json]
  children : Map[Int, Cow]
  mut key_fields : Array[Json]?
  mut key_index : Map[String, Int]?
  mut index_owned : Bool
}

///|
fn cow_arr_new(
  items : Array[Json],
  key_fields? : Array[Json]? = None,
  key_index? : Map[String, Int]? = None,
  index_owned? : Bool = false,
) -> CowArr {
  { items, children: Map([]), key_fields, key_index, index_owned }
}

///|
fn CowArr::flush_children(self : CowArr) -> Unit {
  if !self.children.is_empty() {
    for idx, child in self.children {
      self.items[idx] = cow_freeze(child)
    }
    self.children.clear()
  }
}

///|
fn CowArr::invalidate_index(self : CowArr) -> Unit {
  self.key_fields = None
  self.key_index = None
  self.index_owned = false
}

///|
fn cow_freeze(node : Cow) -> Json {
  match node {
    Shared(j) => j
    Obj(m, children) => {
      if !children.is_empty() {
        for k, child in children {
          m[k] = cow_freeze(child)
        }
        children.clear()
      }
      Json::object(m)
    }
    Arr(ca) => {
      ca.flush_children()
      if ca.items.length() >= keyed_at_least {
        match (ca.key_fields, ca.key_index) {
          (Some(fields), Some(idx)) => keyed_at_keep(ca.items, fields, Some(idx))
          _ => ()
        }
      }
      Json::array(ca.items)
    }
  }
}

///|
/// `value` with `ops` (a `delta` message's array) applied.
pub fn apply_delta(value : Json, ops : Array[Json]) -> Json {
  let n = ops.length()
  if n == 0 {
    return value
  }
  if n == 1 {
    return match ops[0] {
      Object(o) =>
        match o.get("path") {
          Some(Array(path)) => apply_op(value, o, path, 0)
          _ => value
        }
      _ => value
    }
  }
  let mut root = Cow::Shared(value)
  let mut i = 0
  while i < n {
    match ops[i] {
      Object(o) =>
        match o.get("path") {
          Some(Array(path)) => {
            let drops = drop_run(ops, i, o)
            if drops > 1 {
              let (next, _) = cow_drop_run(root, path, 0, ops[i:i + drops], o)
              root = next
              i += drops
              continue
            }
            let next_same_keyed = has_following_index_preserving(ops, i, o)
            let (next, _) = cow_apply_op(root, o, path, 0, next_same_keyed)
            root = next
          }
          _ => ()
        }
      _ => ()
    }
    i += 1
  }
  cow_freeze(root)
}

///|
/// How many ops from `at` (`first`, its own) are keyed drops at the same path by the same key: 0 when it is none.
fn drop_run(ops : Array[Json], at : Int, first : Map[String, Json]) -> Int {
  guard first.get("drop") is Some(_) && first.get("key") is Some(Array(_)) else {
    return 0
  }
  let key = first.get("key")
  let path = first.get("path")
  let mut n = 1
  while at + n < ops.length() {
    guard ops[at + n] is Object(o) &&
      o.get("drop") is Some(_) &&
      o.get("key") == key &&
      o.get("path") == path else {
      break
    }
    n += 1
  }
  n
}

///|
/// Whether an index-preserving keyed op (`patch` or `put` without shift) at `at` is worth building a key index for:
/// either another keyed op on the same list follows, or this is the final op so the index is cached for the next delta.
fn has_following_index_preserving(ops : Array[Json], at : Int, cur : Map[String, Json]) -> Bool {
  guard cur.get("key") is Some(Array(_)) else { return false }
  guard cur.get("drop") is None && cur.get("move") is None else { return false }
  if cur.get("patch") is None {
    guard cur.get("put") is Some(_) else { return false }
    if cur.contains("before") {
      match cur.get("before") {
        None | Some(Null) => ()
        Some(_) => return false
      }
    }
  }
  if at + 1 >= ops.length() {
    return true
  }
  match ops[at + 1] {
    Object(next) => next.get("key") == cur.get("key") && next.get("path") == cur.get("path")
    _ => false
  }
}

///|
/// Apply a consecutive run of keyed `drop` ops at `path` in a single O(N + K) pass.
fn cow_drop_run(
  node : Cow,
  path : Array[Json],
  depth : Int,
  run : ArrayView[Json],
  first : Map[String, Json],
) -> (Cow, Bool) {
  if depth == path.length() {
    let fields = match first.get("key") {
      Some(Array(f)) => f
      _ => return (node, false)
    }
    let src = match node {
      Arr(ca) => {
        ca.flush_children()
        ca.items
      }
      Shared(Array(list)) => list
      _ => return (node, false)
    }
    let counts : Map[String, Int] = Map([])
    for op in run {
      guard op is Object(o) && o.get("drop") is Some(k) else { continue }
      let ks = k.stringify()
      counts[ks] = counts.get(ks).unwrap_or(0) + 1
    }
    if counts.is_empty() {
      return (node, false)
    }
    let out : Array[Json] = Array(capacity=src.length())
    let mut dropped = false
    for item in src {
      let ks = key_text(item, fields)
      match counts.get(ks) {
        Some(c) if c > 0 => {
          counts[ks] = c - 1
          dropped = true
        }
        _ => out.push(item)
      }
    }
    if !dropped {
      return (node, false)
    }
    return match node {
      Arr(ca) => {
        ca.items = out
        ca.invalidate_index()
        (node, true)
      }
      _ => (Arr(cow_arr_new(out)), true)
    }
  }
  match node {
    Shared(Array(a)) =>
      match index_of(path[depth]) {
        Some(i) if i < a.length() => {
          let (child, changed) = cow_drop_run(Shared(a[i]), path, depth + 1, run, first)
          if !changed {
            return (node, false)
          }
          let ca = cow_arr_new(a.copy())
          match child {
            Shared(j) => ca.items[i] = j
            _ => ca.children[i] = child
          }
          (Arr(ca), true)
        }
        _ => (node, false)
      }
    Arr(ca) =>
      match index_of(path[depth]) {
        Some(i) if i < ca.items.length() => {
          let cur = ca.children.get(i).unwrap_or(Shared(ca.items[i]))
          let (child, changed) = cow_drop_run(cur, path, depth + 1, run, first)
          if !changed {
            return (node, false)
          }
          ca.invalidate_index()
          match child {
            Shared(j) => {
              ca.items[i] = j
              ca.children.remove(i)
            }
            _ => ca.children[i] = child
          }
          (node, true)
        }
        _ => (node, false)
      }
    Shared(Object(m)) =>
      match path[depth] {
        String(k) =>
          match m.get(k) {
            Some(inner) => {
              let (child, changed) = cow_drop_run(Shared(inner), path, depth + 1, run, first)
              if !changed {
                return (node, false)
              }
              let c = m.copy()
              let children : Map[String, Cow] = Map([])
              match child {
                Shared(j) => c[k] = j
                _ => children[k] = child
              }
              (Obj(c, children), true)
            }
            None => (node, false)
          }
        _ => (node, false)
      }
    Obj(m, children) =>
      match path[depth] {
        String(k) =>
          if !m.contains(k) {
            (node, false)
          } else {
            let cur = children.get(k).unwrap_or(Shared(m.get(k).unwrap()))
            let (child, changed) = cow_drop_run(cur, path, depth + 1, run, first)
            if !changed {
              return (node, false)
            }
            match child {
              Shared(j) => {
                m[k] = j
                children.remove(k)
              }
              _ => children[k] = child
            }
            (node, true)
          }
        _ => (node, false)
      }
    _ => (node, false)
  }
}

///|
/// Apply one op into the Copy-on-Write tree, returning `(next_node, changed)`.
/// Untouched ancestors stay `Shared` when an op is skipped (invalid/missing path).
fn cow_apply_op(
  node : Cow,
  op : Map[String, Json],
  path : Array[Json],
  depth : Int,
  build_index : Bool,
) -> (Cow, Bool) {
  if depth == path.length() {
    if op.contains("key") {
      return match node {
        Shared(Array(list)) => {
          let fields = match op.get("key") {
            Some(Array(f)) => f
            _ => return (node, false)
          }
          let cached = if list.length() >= keyed_at_least {
            keyed_at_lookup(list, fields)
          } else {
            None
          }
          let ca = match cached {
            Some(at) => cow_arr_new(list.copy(), key_fields=Some(fields), key_index=Some(at), index_owned=false)
            None => cow_arr_new(list.copy())
          }
          let changed = cow_apply_keyed(ca, op, fields, build_index)
          if !changed {
            return (node, false)
          }
          (Arr(ca), true)
        }
        Arr(ca) => {
          let fields = match op.get("key") {
            Some(Array(f)) => f
            _ => return (node, false)
          }
          ca.flush_children()
          let changed = cow_apply_keyed(ca, op, fields, build_index)
          (node, changed)
        }
        _ => (node, false)
      }
    }
    match op.get("set") {
      Some(v) => return (Shared(v), true)
      None => ()
    }
    return match op.get("append") {
      Some(Array(more)) =>
        match node {
          Shared(Array(a)) => {
            let c = a.copy()
            for x in more {
              c.push(x)
            }
            (Arr(cow_arr_new(c)), true)
          }
          Arr(ca) => {
            for x in more {
              ca.items.push(x)
            }
            ca.invalidate_index()
            (node, true)
          }
          _ => (node, false)
        }
      _ => (node, false)
    }
  }
  let last = depth == path.length() - 1
  match node {
    Shared(Array(a)) =>
      match index_of(path[depth]) {
        Some(i) if i < a.length() => {
          if last && !op.contains("key") {
            match op.get("set") {
              Some(v) => {
                let c = a.copy()
                c[i] = v
                return (Arr(cow_arr_new(c)), true)
              }
              None => ()
            }
          }
          let (child, changed) = cow_apply_op(Shared(a[i]), op, path, depth + 1, build_index)
          if !changed {
            return (node, false)
          }
          let ca = cow_arr_new(a.copy())
          match child {
            Shared(j) => ca.items[i] = j
            _ => ca.children[i] = child
          }
          (Arr(ca), true)
        }
        _ => (node, false)
      }
    Arr(ca) =>
      match index_of(path[depth]) {
        Some(i) if i < ca.items.length() => {
          if last && !op.contains("key") {
            match op.get("set") {
              Some(v) => {
                ca.items[i] = v
                ca.children.remove(i)
                ca.invalidate_index()
                return (node, true)
              }
              None => ()
            }
          }
          let cur = ca.children.get(i).unwrap_or(Shared(ca.items[i]))
          let (child, changed) = cow_apply_op(cur, op, path, depth + 1, build_index)
          if !changed {
            return (node, false)
          }
          ca.invalidate_index()
          match child {
            Shared(j) => {
              ca.items[i] = j
              ca.children.remove(i)
            }
            _ => ca.children[i] = child
          }
          (node, true)
        }
        _ => (node, false)
      }
    Shared(Object(m)) =>
      match path[depth] {
        String(k) =>
          if op.contains("remove") && last {
            if !m.contains(k) {
              return (node, false)
            }
            let c = m.copy()
            c.remove(k)
            (Obj(c, Map([])), true)
          } else if !m.contains(k) && !(op.contains("set") && last) {
            (node, false)
          } else if last && !op.contains("key") && op.get("set") is Some(v) {
            let c = m.copy()
            c[k] = v
            (Obj(c, Map([])), true)
          } else {
            let existed = m.contains(k)
            let inner = m.get(k).unwrap_or(Json::null())
            let (child, changed) = cow_apply_op(Shared(inner), op, path, depth + 1, build_index)
            if !changed && existed {
              return (node, false)
            }
            let c = m.copy()
            let children : Map[String, Cow] = Map([])
            match child {
              Shared(j) => c[k] = j
              _ => {
                c[k] = inner
                children[k] = child
              }
            }
            (Obj(c, children), true)
          }
        _ => (node, false)
      }
    Obj(m, children) =>
      match path[depth] {
        String(k) =>
          if op.contains("remove") && last {
            if !m.contains(k) {
              return (node, false)
            }
            m.remove(k)
            children.remove(k)
            (node, true)
          } else if !m.contains(k) && !(op.contains("set") && last) {
            (node, false)
          } else if last && !op.contains("key") && op.get("set") is Some(v) {
            m[k] = v
            children.remove(k)
            (node, true)
          } else {
            let existed = m.contains(k)
            let cur = match children.get(k) {
              Some(c) => c
              None => Shared(m.get(k).unwrap_or(Json::null()))
            }
            let (child, changed) = cow_apply_op(cur, op, path, depth + 1, build_index)
            if !changed && existed {
              return (node, false)
            }
            match child {
              Shared(j) => {
                m[k] = j
                children.remove(k)
              }
              _ => {
                if !existed {
                  m[k] = Json::null()
                }
                children[k] = child
              }
            }
            (node, true)
          }
        _ => (node, false)
      }
    _ => (node, false)
  }
}

///|
/// Apply one keyed op directly onto an owned `CowArr` (no array copy).
/// Reuses an existing key index when valid, builds one only for index-preserving ops when worthwhile,
/// and falls back to zero-allocation `key_match` linear scan on shifting ops (`drop`, `move`, `put` with `before`).
fn cow_apply_keyed(
  ca : CowArr,
  op : Map[String, Json],
  fields : Array[Json],
  build_index : Bool,
) -> Bool {
  let out = ca.items
  let has_valid_index = match (ca.key_fields, ca.key_index) {
    (Some(kf), Some(_)) => kf == fields
    _ => false
  }
  if !has_valid_index {
    ca.invalidate_index()
    if build_index && out.length() >= keyed_at_least {
      ca.key_fields = Some(fields)
      ca.key_index = Some(build_key_index(out, fields))
      ca.index_owned = true
    }
  }
  let find = fn(k : Json) -> Int {
    match ca.key_index {
      Some(at) =>
        match at.get(k.stringify()) {
          Some(i) if i < out.length() && key_match(out[i], fields, k) => return i
          _ => ()
        }
      None => ()
    }
    for i, item in out {
      if key_match(item, fields, k) {
        return i
      }
    }
    -1
  }
  let place = fn(item : Json, before : Json?) {
    let at = match before {
      None | Some(Null) => -1
      Some(b) => find(b)
    }
    if at < 0 {
      out.push(item)
    } else {
      out.insert(at, item)
    }
  }
  match (op.get("drop"), op.get("patch"), op.get("move")) {
    (Some(k), _, _) => {
      let i = find(k)
      if i >= 0 {
        out.remove(i) |> ignore
        ca.invalidate_index()
        return true
      }
      false
    }
    (None, Some(k), _) => {
      let i = find(k)
      match op.get("ops") {
        Some(Array(inner)) if i >= 0 => {
          let was = out[i]
          let now = apply_delta(was, inner)
          out[i] = now
          if !same_key(now, was, fields) {
            ca.invalidate_index()
          }
          true
        }
        _ => false
      }
    }
    (None, None, Some(k)) => {
      let i = find(k)
      if i < 0 {
        return false
      }
      let item = out.remove(i)
      // (after removal, index shifted; invalidate before `place` searches `before`)
      ca.invalidate_index()
      place(item, op.get("before"))
      true
    }
    (None, None, None) => {
      let put = match op.get("put") {
        Some(p) => p
        None => return false
      }
      let i = find(key_of(put, fields))
      if i >= 0 && !op.contains("before") {
        out[i] = put
        true
      } else {
        if i >= 0 {
          out.remove(i) |> ignore
          ca.invalidate_index()
        }
        place(put, op.get("before"))
        if i < 0 && out.length() > 0 && physical_equal(out[out.length() - 1], put) {
          match ca.key_index {
            Some(m) => {
              let idx = if ca.index_owned {
                m
              } else {
                let c = m.copy()
                ca.key_index = Some(c)
                ca.index_owned = true
                c
              }
              let pk = key_text(put, fields)
              if !idx.contains(pk) {
                idx[pk] = out.length() - 1
              }
            }
            None => ()
          }
        } else {
          ca.invalidate_index()
        }
        true
      }
    }
  }
}

///|
fn apply_op(
  node : Json,
  op : Map[String, Json],
  path : Array[Json],
  depth : Int,
) -> Json {
  if depth == path.length() {
    if op.contains("key") {
      return match node {
        Array(list) => Json::array(apply_keyed(list, op))
        _ => node
      }
    }
    match op.get("set") {
      Some(v) => return v
      None => ()
    }
    return match (node, op.get("append")) {
      (Array(a), Some(Array(more))) => {
        let c = a.copy()
        for x in more {
          c.push(x)
        }
        Json::array(c)
      }
      _ => node
    }
  }
  let last = depth == path.length() - 1
  match node {
    Array(a) =>
      match index_of(path[depth]) {
        Some(i) if i < a.length() => {
          let c = a.copy()
          c[i] = apply_op(a[i], op, path, depth + 1)
          Json::array(c)
        }
        _ => node
      }
    Object(m) =>
      match path[depth] {
        String(k) =>
          if op.contains("remove") && last {
            let c = m.copy()
            c.remove(k)
            Json::object(c)
          } else if !m.contains(k) && !(op.contains("set") && last) {
            node
          } else {
            let c = m.copy()
            c[k] = apply_op(m.get(k).unwrap_or(Json::null()), op, path, depth + 1)
            Json::object(c)
          }
        _ => node
      }
    _ => node
  }
}

///|
/// A path segment as an array index: a whole number from 0.
fn index_of(seg : Json) -> Int? {
  match seg {
    Number(d, ..) =>
      if d >= 0.0 && d < 2147483647.0 && d == d.floor() {
        Some(d.to_int())
      } else {
        None
      }
    _ => None
  }
}

///|
/// An item's key: the one field's value, or the fields' values in order (a field missing is null).
fn key_of(item : Json, fields : Array[Json]) -> Json {
  if fields.length() == 1 {
    key_field(item, fields[0])
  } else {
    Json::array(fields.map(fn(f) { key_field(item, f) }))
  }
}

///|
/// The JSON text of `key_of(item, fields)` without allocating an intermediate `Array[Json]` for composite keys.
fn key_text(item : Json, fields : Array[Json]) -> String {
  let n = fields.length()
  if n == 1 {
    return key_field(item, fields[0]).stringify()
  }
  if n == 2 {
    return "[" + key_field(item, fields[0]).stringify() + "," + key_field(item, fields[1]).stringify() + "]"
  }
  let buf = StringBuilder()
  buf.write_char('[')
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(key_field(item, fields[i]).stringify())
  }
  buf.write_char(']')
  buf.to_string()
}

///|
/// A field of an item by its key's field `f` (a field missing is null).
fn key_field(item : Json, f : Json) -> Json {
  match (item, f) {
    (Object(m), String(name)) => m.get(name).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// Whether `item`'s key is `target` (key_of's, an op's `patch`, `drop`, `move` or `before`), nothing made to tell: a
/// list's items are looked through for one, and an array made of each one's fields (a chat's messages' `seq` and
/// `outgoing`) was an allocation an item, hundreds per message patch.
fn key_match(item : Json, fields : Array[Json], target : Json) -> Bool {
  if fields.length() == 1 {
    return key_field(item, fields[0]) == target
  }
  guard target is Array(t) && t.length() == fields.length() else { return false }
  for i, f in fields {
    if key_field(item, f) != t[i] {
      return false
    }
  }
  true
}

///|
/// Whether items `a` and `b` have the same key (key_of's), nothing made to tell.
fn same_key(a : Json, b : Json, fields : Array[Json]) -> Bool {
  for f in fields {
    if key_field(a, f) != key_field(b, f) {
      return false
    }
  }
  true
}

///|
fn apply_keyed(list : Array[Json], op : Map[String, Json]) -> Array[Json] {
  let fields = match op.get("key") {
    Some(Array(f)) => f
    _ => return list
  }
  let out = list.copy()
  // (where each key is, of a list as long as a chat's: kept for the list each op makes, so an in-place patch to a
  // chat's last message finds it at once, not after every message before it; only build a fresh index when the op
  // preserves positions so the index is worth keeping, otherwise reuse a cached one or fall back to zero-alloc scan)
  let preserves = op.get("drop") is None &&
    op.get("move") is None &&
    (op.get("patch") is Some(_) || !op.contains("before") || op.get("before") is Some(Null))
  let (init_at, from_cache) = if list.length() >= keyed_at_least {
    match keyed_at_lookup(list, fields) {
      Some(m) => (Some(m), true)
      None => if preserves { (Some(build_key_index(list, fields)), false) } else { (None, false) }
    }
  } else {
    (None, false)
  }
  let mut at = init_at
  let find = fn(k : Json) -> Int {
    match at {
      Some(at) =>
        match at.get(k.stringify()) {
          Some(i) if i < out.length() && key_match(out[i], fields, k) => return i
          _ => ()
        }
      None => ()
    }
    for i, item in out {
      if key_match(item, fields, k) {
        return i
      }
    }
    -1
  }
  // Before the item keyed `before`; at the end when that is null, absent or not there.
  let place = fn(item : Json, before : Json?) {
    let at = match before {
      None | Some(Null) => -1
      Some(b) => find(b)
    }
    if at < 0 {
      out.push(item)
    } else {
      out.insert(at, item)
    }
  }
  match (op.get("drop"), op.get("patch"), op.get("move")) {
    (Some(k), _, _) => {
      let i = find(k)
      if i >= 0 {
        out.remove(i) |> ignore
      }
    }
    (None, Some(k), _) => {
      let i = find(k)
      match op.get("ops") {
        Some(Array(ops)) if i >= 0 => {
          let was = out[i]
          let now = apply_delta(was, ops)
          out[i] = now
          if same_key(now, was, fields) {
            keyed_at_keep(out, fields, at)
          }
        }
        _ => keyed_at_keep(out, fields, at)
      }
    }
    (None, None, Some(k)) => {
      let i = find(k)
      if i < 0 {
        return list
      }
      let item = out.remove(i)
      at = None
      place(item, op.get("before"))
    }
    (None, None, None) => {
      let put = match op.get("put") {
        Some(p) => p
        None => return list
      }
      let i = find(key_of(put, fields))
      if i >= 0 && !op.contains("before") {
        out[i] = put
        keyed_at_keep(out, fields, at)
      } else {
        if i >= 0 {
          out.remove(i) |> ignore
          at = None
        }
        place(put, op.get("before"))
        // (a new one at the end: each where it was, it last; copy cached map before mutating so `list` stays intact)
        if i < 0 && out.length() > 0 && physical_equal(out[out.length() - 1], put) {
          match at {
            Some(m) => {
              let next_m = if from_cache { m.copy() } else { m }
              let pk = key_text(put, fields)
              if !next_m.contains(pk) {
                next_m[pk] = out.length() - 1
              }
              keyed_at_keep(out, fields, Some(next_m))
            }
            None => ()
          }
        }
      }
    }
  }
  out
}

///|
/// How long a keyed list is before where each of its keys is is kept for it (keyed_at_of): a shorter one is walked.
let keyed_at_least : Int = 32

///|
/// Where each key of a keyed list is (by its key's JSON text, the first where it is there twice), of the list it was
/// worked out of: the lists apply_keyed made last, each looked for by itself.
priv struct KeyedAt {
  list : Array[Json]
  fields : Array[Json]
  at : Map[String, Int]
}

///|
// kept across runs: a list here is found only by being the very list given, so one of a run before is never found
let keyed_ats : Array[KeyedAt] = []

///|
/// How many lists' keys are kept at once (keyed_ats): each of a value's keyed lists changed in turn.
let keyed_ats_most : Int = 8

///|
/// Look up a cached key index for `list` (by exact array identity and key fields).
fn keyed_at_lookup(list : Array[Json], fields : Array[Json]) -> Map[String, Int]? {
  for a in keyed_ats {
    if physical_equal(a.list, list) && a.fields == fields {
      return Some(a.at)
    }
  }
  None
}

///|
/// Build a fresh key-to-first-index map for `list`.
fn build_key_index(list : Array[Json], fields : Array[Json]) -> Map[String, Int] {
  let at : Map[String, Int] = Map([])
  for i, item in list {
    let k = key_text(item, fields)
    if !at.contains(k) {
      at[k] = i
    }
  }
  at
}

///|
/// `at` kept for `list` (made from the list it was of, each key where it was), the oldest let go past keyed_ats_most.
fn keyed_at_keep(list : Array[Json], fields : Array[Json], at : Map[String, Int]?) -> Unit {
  guard at is Some(at) else { return }
  if keyed_ats.length() >= keyed_ats_most {
    keyed_ats.remove(0) |> ignore
  }
  keyed_ats.push({ list, fields, at })
}
