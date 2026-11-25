// A subscription's deltas applied as the core applies them (client/core-ts/src/collections.ts `applyKeyed`, which the
// web's and Android's appliers match): `set`, `append` and `remove` at a path; keyed `put`, `patch`, `drop` and
// `move` on a list's item found by its key. Nothing is changed in place on the input: only the arrays and objects
// along touched paths are copied (at most once per `apply_delta` call via Copy-on-Write), so a value a view still
// holds stays as it was, and the parts that did not change are shared.
// An op that does not fit its value (a path through what is not there) is skipped, as the core skips it.

///|
/// Structural equality on valid (finite) `Json` values matching MoonBit `Json::op_equal` (including `Number` repr
/// insensitivity and `-0.0 == 0.0`), while short-circuiting via `physical_equal` at every container and string node to
/// avoid deep re-walks over unchanged subtrees shared across `apply_delta` updates. Directly shared `NaN` leaves still
/// return `false`; shared container subtrees are assumed to contain valid finite JSON (no `NaN`, per RFC 8259).
fn json_same(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Number(x, ..), Number(y, ..)) => x == y
    (Null, Null) | (True, True) | (False, False) => true
    (String(x), String(y)) => physical_equal(x, y) || x == y
    (Array(x), Array(y)) => {
      if physical_equal(a, b) || physical_equal(x, y) {
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
      if physical_equal(a, b) || physical_equal(x, y) {
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
fn CowArr::index_append(self : CowArr, item : Json, at_idx : Int) -> Unit {
  match (self.key_fields, self.key_index) {
    (Some(fields), Some(m)) => {
      let idx = if self.index_owned {
        m
      } else {
        let c = m.copy()
        self.key_index = Some(c)
        self.index_owned = true
        c
      }
      let pk = key_text(item, fields)
      if !idx.contains(pk) {
        idx[pk] = at_idx
      }
    }
    _ => ()
  }
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
            let build_index = should_build_index(ops, i, o)
            let (next, _) = cow_apply_op(root, o, path, 0, build_index)
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
/// How many ops from `at` (`first`, its own) are unambiguous keyed drops at the same path by the same key:
/// ops also carrying `remove` or `set` are excluded because object descent rules treat them specially.
fn drop_run(ops : Array[Json], at : Int, first : Map[String, Json]) -> Int {
  guard first.get("drop") is Some(_) &&
    !first.contains("remove") &&
    !first.contains("set") &&
    first.get("key") is Some(Array(_)) else {
    return 0
  }
  let key = first.get("key")
  let path = first.get("path")
  let mut n = 1
  while at + n < ops.length() {
    guard ops[at + n] is Object(o) &&
      o.get("drop") is Some(_) &&
      !o.contains("remove") &&
      !o.contains("set") &&
      o.get("key") == key &&
      o.get("path") == path else {
      break
    }
    n += 1
  }
  n
}

///|
/// Whether a keyed op at `at` should lazily build a key index when none is cached yet:
/// - `patch` and in-place `put` (no `before`) always preserve positions, so building once serves both subsequent
///   (even interleaved) ops on this list and the next delta via `keyed_ats`.
/// - `put` with `before: null` only builds on the final op or when another op on the same list follows.
/// - `drop`, `move`, and `put` with a non-null `before` shift indices and never build a throwaway index.
fn should_build_index(ops : Array[Json], at : Int, cur : Map[String, Json]) -> Bool {
  guard cur.get("key") is Some(Array(_)) else { return false }
  guard cur.get("drop") is None && cur.get("move") is None else { return false }
  if cur.get("patch") is Some(_) {
    return true
  }
  guard cur.get("put") is Some(_) else { return false }
  if !cur.contains("before") {
    return true
  }
  match cur.get("before") {
    None | Some(Null) =>
      if at + 1 >= ops.length() {
        true
      } else {
        match ops[at + 1] {
          Object(next) => next.get("key") == cur.get("key") && next.get("path") == cur.get("path")
          _ => false
        }
      }
    Some(_) => false
  }
}

///|
/// Apply a consecutive run of unambiguous keyed `drop` ops at `path` in a single O(N + K) pass.
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
      let ks = json_key_text(k)
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
          // Look up or lazily build an authoritative key index on `list` before copying it:
          // consecutive missed patches/drops/moves then resolve in O(1) without copying `list` or rebuilding the index.
          let (idx_opt, from_cache) = if list.length() >= keyed_at_least {
            match keyed_at_lookup(list, fields) {
              Some(at) => (Some(at), true)
              None =>
                if build_index {
                  let built = build_key_index(list, fields)
                  keyed_at_keep(list, fields, Some(built))
                  (Some(built), true)
                } else {
                  (None, false)
                }
            }
          } else {
            (None, false)
          }
          // Pre-check missing targets for drop/patch/move to avoid allocating `list.copy()` on a no-op miss.
          match (op.get("drop"), op.get("patch"), op.get("move")) {
            (Some(k), _, _) =>
              if keyed_find_in(list, fields, idx_opt, k) < 0 {
                return (node, false)
              }
            (None, Some(k), _) =>
              match op.get("ops") {
                Some(Array(_)) =>
                  if keyed_find_in(list, fields, idx_opt, k) < 0 {
                    return (node, false)
                  }
                _ => return (node, false)
              }
            (None, None, Some(k)) =>
              if keyed_find_in(list, fields, idx_opt, k) < 0 {
                return (node, false)
              }
            (None, None, None) =>
              if op.get("put") is None {
                return (node, false)
              }
          }
          let ca = match idx_opt {
            Some(at) => cow_arr_new(list.copy(), key_fields=Some(fields), key_index=Some(at), index_owned=!from_cache)
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
              let idx = ca.items.length()
              ca.items.push(x)
              ca.index_append(x, idx)
            }
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
/// Look up the first index in `list` whose wire key matches `k`, using authoritative `idx` in O(1) when present
/// (with an O(1) `key_match` hit verification so any external mutation self-heals) and falling back to
/// zero-allocation `key_match` linear scan when `idx` is `None`.
fn keyed_find_in(
  list : Array[Json],
  fields : Array[Json],
  idx : Map[String, Int]?,
  k : Json,
) -> Int {
  match idx {
    Some(at) =>
      match at.get(json_key_text(k)) {
        Some(i) if i < list.length() && key_match(list[i], fields, k) => return i
        None => return -1
        Some(_) => ()
      }
    None => ()
  }
  for i, item in list {
    if key_match(item, fields, k) {
      return i
    }
  }
  -1
}

///|
/// Apply one keyed op directly onto an owned `CowArr` (no array copy).
/// Reuses an existing authoritative key index when valid, builds one lazily for index-preserving ops,
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
  let find = fn(k : Json) -> Int { keyed_find_in(out, fields, ca.key_index, k) }
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
          ca.index_append(put, out.length() - 1)
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
/// Parse an ECMAScript canonical array index property name (`"0"` or non-zero-leading decimal integer in
/// `[0, 2^32 - 2]`, per ES2015 `OrdinaryOwnPropertyKeys`), returning `None` for all other strings.
fn js_array_index(s : String) -> Int64? {
  let len = s.length()
  if len == 0 || len > 10 {
    return None
  }
  if len == 1 {
    let c = s.code_unit_at(0).to_int()
    return if c >= 48 && c <= 57 { Some((c - 48).to_int64()) } else { None }
  }
  let c0 = s.code_unit_at(0).to_int()
  if c0 < 49 || c0 > 57 {
    return None
  }
  let mut v : Int64 = (c0 - 48).to_int64()
  for i = 1; i < len; i = i + 1 {
    let c = s.code_unit_at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10L + (c - 48).to_int64()
  }
  if v <= 4294967294L {
    Some(v)
  } else {
    None
  }
}

///|
/// Canonical wire-key JSON text matching JS `JSON.stringify` (`client/core-ts/src/collections.ts:text`):
/// - Finite `Number` formats by its IEEE-754 `Double` value (normalizing `-0.0` to `0.0`, ignoring raw `repr`);
///   non-finite `Number` (`Infinity`, `NaN`, e.g. `1e400`) formats as `"null"` just like JS `JSON.stringify`.
/// - `Object` enumerates ECMAScript array-index keys in ascending numeric order followed by remaining keys in
///   insertion order (`OrdinaryOwnPropertyKeys`).
/// So `key_index`, `cow_drop_run`, `key_match`, `same_key`, and `KeyedField` all share one exact equivalence relation.
fn json_key_text(j : Json) -> String {
  match j {
    Null => "null"
    True => "true"
    False => "false"
    Number(d, ..) => {
      if !(d - d == 0.0) {
        return "null"
      }
      let norm = if d == 0.0 { 0.0 } else { d }
      Json::number(norm).stringify()
    }
    String(_) => j.stringify()
    Array(xs) => {
      let buf = StringBuilder()
      buf.write_char('[')
      for i = 0; i < xs.length(); i = i + 1 {
        if i > 0 {
          buf.write_char(',')
        }
        buf.write_string(json_key_text(xs[i]))
      }
      buf.write_char(']')
      buf.to_string()
    }
    Object(m) => {
      let idx_keys : Array[(Int64, String, Json)] = []
      let str_keys : Array[(String, Json)] = []
      for k, v in m {
        match js_array_index(k) {
          Some(n) => idx_keys.push((n, k, v))
          None => str_keys.push((k, v))
        }
      }
      if idx_keys.length() > 1 {
        idx_keys.sort_by(fn(a, b) { a.0.compare(b.0) })
      }
      let buf = StringBuilder()
      buf.write_char('{')
      let mut first = true
      for e in idx_keys {
        if !first {
          buf.write_char(',')
        }
        first = false
        buf.write_string(Json::string(e.1).stringify())
        buf.write_char(':')
        buf.write_string(json_key_text(e.2))
      }
      for e in str_keys {
        if !first {
          buf.write_char(',')
        }
        first = false
        buf.write_string(Json::string(e.0).stringify())
        buf.write_char(':')
        buf.write_string(json_key_text(e.1))
      }
      buf.write_char('}')
      buf.to_string()
    }
  }
}

///|
/// Wire-key equality matching `json_key_text(a) == json_key_text(b)` with zero allocation for primitive keys
/// (`String`, `Number`, `Bool`, `Null`) and ES2015 property-order semantics for `Object` keys.
fn key_val_eq(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) | (True, True) | (False, False) => true
    (Null, Number(y, ..)) | (Number(y, ..), Null) => !(y - y == 0.0)
    (Number(x, ..), Number(y, ..)) =>
      if x - x == 0.0 && y - y == 0.0 {
        x == y
      } else {
        !(x - x == 0.0) && !(y - y == 0.0)
      }
    (String(x), String(y)) => physical_equal(x, y) || x == y
    (Array(x), Array(y)) => {
      if physical_equal(x, y) {
        return true
      }
      if x.length() != y.length() {
        return false
      }
      for i = 0; i < x.length(); i = i + 1 {
        if !key_val_eq(x[i], y[i]) {
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
      json_key_text(a) == json_key_text(b)
    }
    _ => false
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
/// The canonical wire-key text of `key_of(item, fields)` without allocating an intermediate `Array[Json]` for composite keys.
fn key_text(item : Json, fields : Array[Json]) -> String {
  let n = fields.length()
  if n == 1 {
    return json_key_text(key_field(item, fields[0]))
  }
  if n == 2 {
    return "[" + json_key_text(key_field(item, fields[0])) + "," + json_key_text(key_field(item, fields[1])) + "]"
  }
  let buf = StringBuilder()
  buf.write_char('[')
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(json_key_text(key_field(item, fields[i])))
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
/// Whether `item`'s key is `target` (wire-key equality matching `json_key_text`), with zero allocation for primitive keys.
fn key_match(item : Json, fields : Array[Json], target : Json) -> Bool {
  if fields.length() == 1 {
    return key_val_eq(key_field(item, fields[0]), target)
  }
  guard target is Array(t) && t.length() == fields.length() else { return false }
  for i, f in fields {
    if !key_val_eq(key_field(item, f), t[i]) {
      return false
    }
  }
  true
}

///|
/// Whether items `a` and `b` have the same wire key (key_of's), including object key order.
fn same_key(a : Json, b : Json, fields : Array[Json]) -> Bool {
  for f in fields {
    if !key_val_eq(key_field(a, f), key_field(b, f)) {
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
    (op.get("patch") is Some(_) || !op.contains("before"))
  let (init_at, from_cache) = if list.length() >= keyed_at_least {
    match keyed_at_lookup(list, fields) {
      Some(m) => (Some(m), true)
      None => if preserves { (Some(build_key_index(list, fields)), false) } else { (None, false) }
    }
  } else {
    (None, false)
  }
  let mut at = init_at
  let find = fn(k : Json) -> Int { keyed_find_in(out, fields, at, k) }
  // Before the item keyed `before`; at the end when that is null, absent or not there.
  let place = fn(item : Json, before : Json?) {
    let pos = match before {
      None | Some(Null) => -1
      Some(b) => find(b)
    }
    if pos < 0 {
      out.push(item)
    } else {
      out.insert(pos, item)
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
/// How long a keyed list is before where each of its keys is is kept for it (keyed_at_lookup): a shorter one is walked.
let keyed_at_least : Int = 32

///|
/// Where each key of a keyed list is (by its canonical wire-key text, the first where it is there twice), of the list
/// it was worked out of: the lists apply_keyed made last, each looked for by itself.
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
/// Build a fresh canonical-wire-key-to-first-index map for `list`.
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
