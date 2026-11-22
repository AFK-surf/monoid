// A subscription's deltas applied as the core applies them (client/core-ts/src/collections.ts `applyKeyed`, which the
// web's and Android's appliers match): `set`, `append` and `remove` at a path; keyed `put`, `patch`, `drop` and
// `move` on a list's item found by its key. Nothing is changed in place: only the arrays and objects along an op's
// path are copied, so a value a view still holds stays as it was, and the parts that did not change are shared.
// An op that does not fit its value (a path through what is not there) is skipped, as the core skips it.

///|
/// `value` with `ops` (a `delta` message's array) applied.
pub fn apply_delta(value : Json, ops : Array[Json]) -> Json {
  let mut v = value
  let mut i = 0
  while i < ops.length() {
    match ops[i] {
      Object(o) =>
        match o.get("path") {
          Some(Array(path)) => {
            // Patches of one list's items in a row (a station's state on each of its 1400 rows) go together: the list
            // copied and its keys read once, not once a patch (35 ms a delta of 1400 on a Mac, 160 of 3000).
            let run = patch_run(ops, i, o)
            if run > 1 {
              v = at_list(v, path, 0, fn(list) { patch_all(list, ops[i:i + run], o) })
              i += run
              continue
            }
            v = apply_op(v, o, path, 0)
          }
          _ => ()
        }
      _ => ()
    }
    i += 1
  }
  v
}

///|
/// How many ops from `at` (`first`, its own) are keyed patches at the same path by the same key: 0 when it is none.
fn patch_run(ops : Array[Json], at : Int, first : Map[String, Json]) -> Int {
  guard first.get("patch") is Some(_) && first.get("drop") is None && first.get("key") is Some(Array(_)) else {
    return 0
  }
  let key = first.get("key")
  let path = first.get("path")
  let mut n = 1
  while at + n < ops.length() {
    guard ops[at + n] is Object(o) &&
      o.get("patch") is Some(_) &&
      o.get("drop") is None &&
      o.get("key") == key &&
      o.get("path") == path else {
      break
    }
    n += 1
  }
  n
}

///|
/// `node` with the list at `path` (from `depth`) made by `f`, the arrays and objects along it copied; as it was when
/// the path goes through what is not there, as apply_op skips a keyed op then.
fn at_list(node : Json, path : Array[Json], depth : Int, f : (Array[Json]) -> Json) -> Json {
  if depth == path.length() {
    return match node {
      Array(list) => f(list)
      _ => node
    }
  }
  match node {
    Array(a) =>
      match index_of(path[depth]) {
        Some(i) if i < a.length() => {
          let c = a.copy()
          c[i] = at_list(a[i], path, depth + 1, f)
          Json::array(c)
        }
        _ => node
      }
    Object(m) =>
      match path[depth] {
        String(k) =>
          match m.get(k) {
            Some(inner) => {
              let c = m.copy()
              c[k] = at_list(inner, path, depth + 1, f)
              Json::object(c)
            }
            None => node
          }
        _ => node
      }
    _ => node
  }
}

///|
/// The list with each of `run`'s patches applied in turn, as apply_keyed applies them one by one: each to the first
/// item with its key. The items' keys are read once, and again only after a patch changed one.
fn patch_all(list : Array[Json], run : ArrayView[Json], first : Map[String, Json]) -> Json {
  let fields = match first.get("key") {
    Some(Array(f)) => f
    _ => return Json::array(list)
  }
  let out = list.copy()
  let index : Map[String, Int] = Map([])
  let mut stale = true
  for op in run {
    guard op is Object(o) && o.get("patch") is Some(k) else { continue }
    if stale {
      index.clear()
      for i, item in out {
        let key = key_of(item, fields).stringify()
        if !index.contains(key) {
          index[key] = i
        }
      }
      stale = false
    }
    match (index.get(k.stringify()), o.get("ops")) {
      (Some(i), Some(Array(ops))) => {
        let was = out[i]
        out[i] = apply_delta(was, ops)
        if !same_key(out[i], was, fields) {
          stale = true
        }
      }
      _ => ()
    }
  }
  Json::array(out)
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
  // chat's last message finds it at once, not after every message before it; the first of a key where it is there
  // twice, as walking from the start finds it)
  let at = if list.length() >= keyed_at_least { Some(keyed_at_of(list, fields)) } else { None }
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
        Some(Array(ops)) if i >= 0 => out[i] = apply_delta(out[i], ops)
        _ => ()
      }
      // (each where it was)
      keyed_at_keep(out, fields, at)
    }
    (None, None, Some(k)) => {
      let i = find(k)
      if i < 0 {
        return list
      }
      let item = out.remove(i)
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
        }
        place(put, op.get("before"))
        // (a new one at the end: each where it was, it last)
        if i < 0 && out.length() > 0 && physical_equal(out[out.length() - 1], put) {
          match at {
            Some(m) => {
              let pk = key_of(put, fields).stringify()
              if !m.contains(pk) {
                m[pk] = out.length() - 1
              }
              keyed_at_keep(out, fields, Some(m))
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
/// Where each key of `list` (by `fields`) is: kept for it, else worked out once.
fn keyed_at_of(list : Array[Json], fields : Array[Json]) -> Map[String, Int] {
  for a in keyed_ats {
    if physical_equal(a.list, list) && a.fields == fields {
      return a.at
    }
  }
  let at : Map[String, Int] = Map([])
  for i, item in list {
    let k = key_of(item, fields).stringify()
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
