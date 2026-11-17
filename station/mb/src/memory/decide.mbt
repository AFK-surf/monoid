// What one station's record of a file of the memory and another's make (station/src/share/memory.ts, as its
// `decide` was before it moved here: station/test/reference/memory-merge.ts keeps it): the one that comes after the
// other, or, made beside each other, a merge both stations compute alike, its content written to blobs/ here.

///|
/// A file of the memory, as each station keeps and tells it (memory.ts `Rec`).
pub struct Rec {
  hash : String
  at : Double
  by : String
  prev : Array[String]
  size : Double
  mode : Double
  origin : Bool
}

///|
/// The field `key` of `j`.
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(o) => o.get(key)
    _ => None
  }
}

///|
fn str_field(j : Json, key : String) -> String? {
  match field(j, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn num_field(j : Json, key : String) -> Double? {
  match field(j, key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn strs_field(j : Json, key : String) -> Array[String] {
  let out = []
  if field(j, key) is Some(Array(xs)) {
    for x in xs {
      if x is String(s) {
        out.push(s)
      }
    }
  }
  out
}

///|
/// A record as the station gives it (one it checked: memory.ts `recOf`).
pub fn rec_of(j : Json) -> Rec? {
  guard str_field(j, "hash") is Some(hash) &&
    num_field(j, "at") is Some(at) &&
    str_field(j, "by") is Some(by) else {
    return None
  }
  Some({
    hash,
    at,
    by,
    prev: strs_field(j, "prev"),
    size: num_field(j, "size").unwrap_or(0),
    mode: num_field(j, "mode").unwrap_or(0o644.to_double()),
    origin: field(j, "origin") is Some(True),
  })
}

///|
/// `r` as the station keeps it: its fields in the order memory.ts writes them.
pub fn rec_json(r : Rec) -> Json {
  let m : Map[String, Json] = {
    "hash": Json::string(r.hash),
    "at": Json::number(r.at),
    "by": Json::string(r.by),
    "prev": Json::array(r.prev.map(Json::string)),
    "size": Json::number(r.size),
    "mode": Json::number(r.mode),
  }
  if r.origin {
    m["origin"] = Json::boolean(true)
  }
  Json::object(m)
}

///|
/// Which of two records is the newer: the later, then the station of the greater id, then the greater hash.
fn newer(a : Rec, b : Rec) -> Bool {
  if a.at != b.at {
    a.at > b.at
  } else if a.by != b.by {
    js_after(a.by, b.by)
  } else {
    js_after(a.hash, b.hash)
  }
}

///|
/// The hashes a record is of: its own and those it was made after, none deleted.
fn history(r : Rec) -> Array[String] {
  let out = []
  if r.hash != "" {
    out.push(r.hash)
  }
  for h in r.prev {
    if h != "" {
      out.push(h)
    }
  }
  out
}

///|
/// What two records make (memory.ts `Outcome`): this station's kept, theirs taken, or a merge (its record, and where
/// the other's content is kept beside it, when it is).
pub enum Outcome {
  Keep
  Take
  Merge(Rec, (String, Rec)?)
}

///|
/// What one station's record of `path` (`mine`) and another's (`theirs`) make. `content` gives what this station keeps
/// of a version (None: none); `keep` writes content made here to blobs/ and says its hash; `name_of` a station's name.
/// `prev_most`: memory.ts PREV_MOST.
pub async fn decide(
  path : String,
  mine : Rec?,
  theirs : Rec,
  content : async (String) -> Bytes?,
  keep : async (Bytes) -> String,
  name_of : (String) -> String,
  prev_most : Int,
) -> Outcome {
  guard mine is Some(mine) else { return Take }
  if mine.hash == theirs.hash {
    return if newer(theirs, mine) { Take } else { Keep }
  }
  if theirs.prev.contains(mine.hash) && mine.hash != "" {
    return Take
  }
  if mine.prev.contains(theirs.hash) && theirs.hash != "" {
    return Keep
  }
  // Deleted on one and still there on the other: what is there stays (an edit is not lost to a delete).
  if theirs.hash == "" && mine.hash == "" {
    return if newer(theirs, mine) { Take } else { Keep }
  }
  let (w, l) = if newer(theirs, mine) { (theirs, mine) } else { (mine, theirs) }
  let at = (if w.at > l.at { w.at } else { l.at }) + 1
  let made = fn(hash : String, size : Int) -> Rec {
    let prev = []
    for h in history(w) + history(l) {
      if !prev.contains(h) && prev.length() < prev_most * 2 {
        prev.push(h)
      }
    }
    {
      hash,
      at,
      by: w.by,
      prev,
      size: size.to_double(),
      mode: (if w.hash != "" { w } else { l }).mode,
      origin: false,
    }
  }
  if w.hash == "" || l.hash == "" {
    let kept = if w.hash == "" { l } else { w }
    guard content(kept.hash) is Some(c) else { return Keep }
    return Merge(made(kept.hash, c.length()), None)
  }
  guard content(w.hash) is Some(wc) else { return Keep }
  guard content(l.hash) is Some(lc) else { return Keep }
  let wh = history(w)
  let mut common : String? = None
  for h in history(l) {
    if wh.contains(h) {
      common = Some(h)
      break
    }
  }
  let base = match common {
    Some(h) => content(h)
    None => None
  }
  let mut text : String? = None
  if is_text(wc) && is_text(lc) {
    let (ws, ls) = (text_of(wc), text_of(lc))
    if base is Some(b) && is_text(b) {
      text = merge3(text_of(b), ws, ls)
    } else if common is Some(_) {
      // Of one history but the version both came from not here: their lines together, each once, so that nothing
      // either had is lost.
      text = Some(union_lines(ws, ls, None, None))
    } else if path == "MEMORY.md" {
      text = Some(
        union_lines(
          ws,
          ls,
          if w.origin { Some(name_of(w.by)) } else { None },
          if l.origin { Some(name_of(l.by)) } else { None },
        ),
      )
    } else if alike(ws, ls) {
      // One file each kept on apart (a skill copied once, edited on both since): their lines together, each once.
      text = Some(union_lines(ws, ls, None, None))
    }
  }
  if text is Some(t) {
    let bytes = @utf8.encode(t)
    return Merge(made(keep(bytes), bytes.length()), None)
  }
  // Not merged: the newer's, the other's beside it for an agent to merge.
  let beside : Rec = {
    hash: l.hash,
    at,
    by: w.by,
    prev: [],
    size: lc.length().to_double(),
    mode: l.mode,
    origin: false,
  }
  Merge(made(w.hash, wc.length()), Some((conflict_path(path, name_of(l.by)), beside)))
}
