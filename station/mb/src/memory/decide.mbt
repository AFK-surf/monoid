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
/// Two-pass compaction of a merged `PROJECTS.jsonl` (strictly order-independent across all line orders):
/// Pass 1 collects max deletion watermark `max_del[name]` from `deleted: true` tombstones and `deletedAt` on live rows.
/// Pass 2 drops all live rows with `updatedAt <= max_del[name]`, merges remaining live rows (higher `updatedAt` wins
/// `note`, tie-break via `js_after`; `refs` takes order-preserving deduplicated union), and preserves `deletedAt` on
/// recreated live rows (or emits tombstone when no live row survives). Non-JSON lines are appended verbatim.
fn compact_projects_jsonl(text : String) -> String {
  let max_del : Map[String, Double] = Map([])
  // Parsed live rows: (name, at, has_at, note, note_at, has_note_at, refs_with_at, has_refs_at, note_cleared_at, refs_cleared_at)
  let parsed_live : Array[(String, Double, Bool, String, Double, Bool, Array[(String, Double)], Bool, Double?, Double?)] = []
  let extra : Array[String] = []
  // Pass 1: parse and collect max deletion watermarks.
  for raw_view in text.split("\n") {
    let raw = raw_view.to_owned()
    let trimmed = raw.trim().to_owned()
    if trimmed == "" {
      continue
    }
    let parsed : @jsjson.JValue? = Some(@jsjson.parse(trimmed)) catch { _ => None }
    match parsed {
      Some(@jsjson.JValue::Obj(_) as obj) =>
        match obj.get("name") {
          Some(@jsjson.JValue::Str(name)) if name != "" => {
            let (at, has_at) = match obj.get("updatedAt") {
              Some(@jsjson.JValue::Num(n)) => (n, true)
              _ => (-1.0, false)
            }
            let deleted = match obj.get("deleted") {
              Some(@jsjson.JValue::Bool(true)) => true
              _ => false
            }
            if deleted {
              let del_at = if has_at { at } else { 0.0 }
              match max_del.get(name) {
                Some(prev) if prev >= del_at => ()
                _ => max_del[name] = del_at
              }
              continue
            }
            if obj.get("deletedAt") is Some(@jsjson.JValue::Num(del_at)) {
              match max_del.get(name) {
                Some(prev) if prev >= del_at => ()
                _ => max_del[name] = del_at
              }
            }
            let (note_at, has_note_at) = match obj.get("noteAt") {
              Some(@jsjson.JValue::Num(n)) => (n, true)
              _ => (at, has_at)
            }
            let (refs_fallback, has_refs_fallback) = match obj.get("refsAt") {
              Some(@jsjson.JValue::Num(n)) => (n, true)
              _ => (at, has_at)
            }
            let note_cleared_at : Double? = match obj.get("noteClearedAt") {
              Some(@jsjson.JValue::Num(n)) => Some(n)
              _ => None
            }
            let refs_cleared_at : Double? = match obj.get("refsClearedAt") {
              Some(@jsjson.JValue::Num(n)) => Some(n)
              _ => None
            }
            let note = match obj.get("note") {
              Some(@jsjson.JValue::Str(s)) => s
              _ => ""
            }
            let ref_ats_obj = match obj.get("refAts") {
              Some(@jsjson.JValue::Obj(_) as m) => Some(m)
              _ => None
            }
            let refs_with_at : Array[(String, Double)] = []
            let seen_refs : Map[String, Bool] = Map([])
            let mut has_any_ref_at = false
            match obj.get("refs") {
              Some(@jsjson.JValue::Arr(xs)) =>
                for x in xs {
                  if x is @jsjson.JValue::Str(s) && s != "" && !seen_refs.contains(s) {
                    seen_refs[s] = true
                    let (r_at, r_has) = match ref_ats_obj {
                      Some(m) =>
                        match m.get(s) {
                          Some(@jsjson.JValue::Num(n)) => (n, true)
                          _ => (refs_fallback, has_refs_fallback)
                        }
                      None => (refs_fallback, has_refs_fallback)
                    }
                    if r_has {
                      has_any_ref_at = true
                    }
                    refs_with_at.push((s, r_at))
                  }
                }
              _ => ()
            }
            parsed_live.push((name, at, has_at, note, note_at, has_note_at, refs_with_at, has_any_ref_at, note_cleared_at, refs_cleared_at))
          }
          _ => extra.push(trimmed)
        }
      _ => extra.push(trimmed)
    }
  }
  // Filter surviving live rows (at > max_del) and collect field-level clear watermarks.
  let surviving : Array[(String, Double, Bool, String, Double, Bool, Array[(String, Double)], Bool)] = []
  let max_note_cleared : Map[String, Double] = Map([])
  let max_refs_cleared : Map[String, Double] = Map([])
  for item in parsed_live {
    let (name, at, has_at, note, note_at, has_note_at, refs_with_at, has_refs_at, nc, rc) = item
    if max_del.get(name) is Some(del_at) && at <= del_at {
      continue
    }
    surviving.push((name, at, has_at, note, note_at, has_note_at, refs_with_at, has_refs_at))
    if nc is Some(v) {
      match max_note_cleared.get(name) {
        Some(prev) if prev >= v => ()
        _ => max_note_cleared[name] = v
      }
    }
    if rc is Some(v) {
      match max_refs_cleared.get(name) {
        Some(prev) if prev >= v => ()
        _ => max_refs_cleared[name] = v
      }
    }
  }
  // Pass 2: filter cleared fields by max(clear watermark, project deletion watermark) & per-ref `refAts`, and merge associatively.
  // by_name: (at, has_at, note, note_at, has_note_at, ref_ats_map, has_refs_at)
  let by_name : Map[String, (Double, Bool, String, Double, Bool, Map[String, Double], Bool)] = Map([])
  for item in surviving {
    let (name, at, has_at, raw_note, raw_note_at, raw_has_note_at, raw_refs_with_at, raw_has_refs_at) = item
    let del_cut = max_del.get(name)
    let eff_note_cut = match (max_note_cleared.get(name), del_cut) {
      (Some(a), Some(b)) => Some(if a > b { a } else { b })
      (Some(a), None) => Some(a)
      (None, Some(b)) => Some(b)
      (None, None) => None
    }
    let eff_refs_cut = match (max_refs_cleared.get(name), del_cut) {
      (Some(a), Some(b)) => Some(if a > b { a } else { b })
      (Some(a), None) => Some(a)
      (None, Some(b)) => Some(b)
      (None, None) => None
    }
    let note_keep = raw_note != "" && !(eff_note_cut is Some(cut) && raw_note_at <= cut)
    let note = if note_keep { raw_note } else { "" }
    let note_at = if note_keep { raw_note_at } else { -1.0 }
    let has_note_at = note_keep && raw_has_note_at
    let row_refs : Map[String, Double] = Map([])
    let mut row_has_refs_at = false
    for pair in raw_refs_with_at {
      let (r, r_at) = pair
      if eff_refs_cut is Some(cut) && r_at <= cut {
        continue
      }
      match row_refs.get(r) {
        Some(prev) if prev >= r_at => ()
        _ => row_refs[r] = r_at
      }
      if raw_has_refs_at {
        row_has_refs_at = true
      }
    }
    match by_name.get(name) {
      Some((prev_at, prev_has_at, prev_note, prev_note_at, prev_has_note_at, prev_ref_ats, prev_has_refs_at)) => {
        let (merged_note, merged_note_at, merged_has_note_at) = if note != "" && prev_note != "" {
          let in_wins = if note_at != prev_note_at { note_at > prev_note_at } else { js_after(note, prev_note) }
          if in_wins { (note, note_at, has_note_at) } else { (prev_note, prev_note_at, prev_has_note_at) }
        } else if note != "" {
          (note, note_at, has_note_at)
        } else {
          (prev_note, prev_note_at, prev_has_note_at)
        }
        for r, r_at in row_refs {
          match prev_ref_ats.get(r) {
            Some(prev) if prev >= r_at => ()
            _ => prev_ref_ats[r] = r_at
          }
        }
        let merged_has_refs_at = row_has_refs_at || prev_has_refs_at
        let merged_has_at = has_at || prev_has_at
        let merged_at = if at > prev_at { at } else { prev_at }
        by_name[name] = (merged_at, merged_has_at, merged_note, merged_note_at, merged_has_note_at, prev_ref_ats, merged_has_refs_at)
      }
      None => by_name[name] = (at, has_at, note, note_at, has_note_at, row_refs, row_has_refs_at)
    }
  }
  let name_set : Map[String, Bool] = Map([])
  for k in by_name.keys() {
    name_set[k] = true
  }
  for k in max_del.keys() {
    name_set[k] = true
  }
  let names = name_set.keys().collect()
  names.sort_by(fn(a, b) { if a == b { 0 } else if js_after(a, b) { 1 } else { -1 } })
  let out : Array[String] = []
  for name in names {
    match by_name.get(name) {
      Some((at, has_at, note, note_at, has_note_at, ref_ats_map, has_refs_at)) => {
        let fields : Array[(String, @jsjson.JValue)] = [("name", @jsjson.js(name))]
        if note != "" {
          fields.push(("note", @jsjson.js(note)))
          if has_note_at {
            fields.push(("noteAt", @jsjson.jnum(note_at)))
          }
        }
        let sorted_refs = ref_ats_map.keys().collect()
        if !sorted_refs.is_empty() {
          sorted_refs.sort_by(fn(a, b) {
            let da = ref_ats_map.get(a).unwrap_or(-1.0)
            let db = ref_ats_map.get(b).unwrap_or(-1.0)
            if da != db {
              if db > da { 1 } else { -1 }
            } else if a == b {
              0
            } else if js_after(a, b) {
              1
            } else {
              -1
            }
          })
          fields.push(("refs", @jsjson.jstrs(sorted_refs)))
          if has_refs_at {
            let mut max_ra = -1.0
            let ra_fields : Array[(String, @jsjson.JValue)] = []
            for r in sorted_refs {
              let v = ref_ats_map.get(r).unwrap_or(-1.0)
              if v > max_ra {
                max_ra = v
              }
              ra_fields.push((r, @jsjson.jnum(v)))
            }
            if max_ra >= 0.0 {
              fields.push(("refsAt", @jsjson.jnum(max_ra)))
            }
            fields.push(("refAts", @jsjson.jobj(ra_fields)))
          }
        }
        if has_at {
          fields.push(("updatedAt", @jsjson.jnum(at)))
        }
        if max_del.get(name) is Some(del_at) {
          fields.push(("deletedAt", @jsjson.jnum(del_at)))
        }
        if max_note_cleared.get(name) is Some(nc) {
          fields.push(("noteClearedAt", @jsjson.jnum(nc)))
        }
        if max_refs_cleared.get(name) is Some(rc) {
          fields.push(("refsClearedAt", @jsjson.jnum(rc)))
        }
        out.push(@jsjson.stringify(@jsjson.jobj(fields)))
      }
      None =>
        if max_del.get(name) is Some(del_at) {
          out.push(@jsjson.stringify(@jsjson.jobj([
            ("name", @jsjson.js(name)),
            ("deleted", @jsjson.jbool(true)),
            ("updatedAt", @jsjson.jnum(del_at)),
          ])))
        }
    }
  }
  for line in extra {
    out.push(line)
  }
  if out.is_empty() { "" } else { out.join("\n") + "\n" }
}

let projects_file_most : Int = 512 * 1024

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
      if text is None && path == "PROJECTS.jsonl" {
        text = Some(union_lines(ws, ls, None, None))
      }
    } else if common is Some(_) || path == "PROJECTS.jsonl" {
      // Of one history without base, or PROJECTS.jsonl made apart: union lines deterministically, no conflict copy.
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
    let t = if path == "MEMORY.md" { dedup_memory_lines(t) } else { t }
    let mut bytes = @utf8.encode(t)
    if path == "PROJECTS.jsonl" && bytes.length() > projects_file_most {
      bytes = @utf8.encode(compact_projects_jsonl(t))
      if bytes.length() > projects_file_most {
        return Keep
      }
    }
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
