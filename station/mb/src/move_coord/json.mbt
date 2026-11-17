// JSON as the TypeScript of station/src/move/ holds it (`@jsjson`: JSON.parse and JSON.stringify's own): an object's
// keys in the order they were first set, a spread's (`{ ...a, ...b }`) keeping a's places and adding b's after, so
// what is written to disk and said on the wire is that TypeScript's byte for byte.

///|
pub using @jsjson {type JValue as J}

///|
pub fn js(s : String) -> J {
  Str(@jsjson.units(s))
}

///|
pub fn jn(d : Double) -> J {
  Num(d)
}

///|
pub fn ji(i : Int) -> J {
  Num(i.to_double())
}

///|
pub fn jl(i : Int64) -> J {
  Num(i.to_double())
}

///|
pub fn jb(b : Bool) -> J {
  Bool(b)
}

///|
pub fn jo(pairs : Array[(String, J)]) -> J {
  Obj(pairs.map(p => (@jsjson.units(p.0), p.1)))
}

///|
pub fn ja(items : Array[J]) -> J {
  Arr(items)
}

///|
pub fn jstrs(items : Array[String]) -> J {
  Arr(items.map(js))
}

///|
/// `o[k]` where `o` is an object.
pub fn get(o : J?, k : String) -> J? {
  match o {
    Some(Obj(_) as obj) => obj.get(k)
    _ => None
  }
}

///|
pub fn text(j : J?) -> String? {
  match j {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
pub fn num(j : J?) -> Double? {
  match j {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
pub fn is_true(j : J?) -> Bool {
  j is Some(Bool(true))
}

///|
pub fn arr(j : J?) -> Array[J]? {
  match j {
    Some(Arr(a)) => Some(a)
    _ => None
  }
}

///|
/// `v !== null && typeof v === "object" && !Array.isArray(v)`.
pub fn is_map(j : J?) -> Bool {
  j is Some(Obj(_))
}

///|
/// Present: neither absent nor null (`v != null`).
pub fn present(j : J?) -> Bool {
  match j {
    None | Some(Null) => false
    _ => true
  }
}

///|
pub fn keys_of(o : J) -> Array[String] {
  match o {
    Obj(ps) => ps.map(p => @jsjson.text(p.0))
    _ => []
  }
}

///|
pub fn has_key(o : J, k : String) -> Bool {
  let u = @jsjson.units(k)
  match o {
    Obj(ps) => ps.iter().any(p => p.0 == u)
    _ => false
  }
}

///|
/// `o[k] = v` on a copy: in its place where `o` has it, else last.
pub fn set(o : J, k : String, v : J) -> J {
  let u = @jsjson.units(k)
  match o {
    Obj(ps) => {
      let out = ps.copy()
      match out.search_by(p => p.0 == u) {
        Some(i) => out[i] = (u, v)
        None => out.push((u, v))
      }
      Obj(out)
    }
    _ => Obj([(u, v)])
  }
}

///|
/// `o[k] = v` where `v` is something, a copy.
pub fn set_opt(o : J, k : String, v : J?) -> J {
  match v {
    Some(x) => set(o, k, x)
    None => o
  }
}

///|
/// `delete o[k]` on a copy.
pub fn del(o : J, k : String) -> J {
  let u = @jsjson.units(k)
  match o {
    Obj(ps) => Obj(ps.filter(p => p.0 != u))
    _ => o
  }
}

///|
/// `{ ...a, ...b }`.
pub fn spread(a : J, b : J) -> J {
  match b {
    Obj(ps) => {
      let mut out = match a {
        Obj(_) => a
        _ => Obj([])
      }
      for p in ps {
        out = set(out, @jsjson.text(p.0), p.1)
      }
      out
    }
    _ =>
      match a {
        Obj(_) => a
        _ => Obj([])
      }
  }
}

///|
pub fn stringify(j : J) -> String {
  @jsjson.stringify(j)
}

///|
pub fn parse(s : String) -> J raise {
  @jsjson.parse(s)
}

///|
/// `JSON.stringify(a) === JSON.stringify(b)`.
pub fn same(a : J?, b : J?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => stringify(x) == stringify(y)
    _ => false
  }
}

///|
/// A number as JavaScript's `String(n)` says it (what words are filled with).
pub fn num_text(d : Double) -> String {
  stringify(Num(d))
}

///|
/// `s.slice(0, n)` (by UTF-16 units, as JavaScript's).
pub fn slice_to(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.unsafe_substring(start=0, end=n)
  }
}

///|
/// `s.slice(start)`.
pub fn slice_from(s : String, start : Int) -> String {
  if start >= s.length() {
    ""
  } else if start <= 0 {
    s
  } else {
    s.unsafe_substring(start~, end=s.length())
  }
}

///|
/// `s.slice(start, end)`, `end` past its end clamped.
pub fn slice(s : String, start : Int, end : Int) -> String {
  let e = if end > s.length() { s.length() } else { end }
  if start >= e {
    ""
  } else {
    s.unsafe_substring(start~, end=e)
  }
}

///|
/// `s.indexOf(sub)` (-1: none).
pub fn index_of(s : String, sub : String) -> Int {
  match s.find(sub) {
    Some(i) => i
    None => -1
  }
}

///|
/// `s.lastIndexOf(sub)` (-1: none).
pub fn last_index_of(s : String, sub : String) -> Int {
  match s.rev_find(sub) {
    Some(i) => i
    None => -1
  }
}
