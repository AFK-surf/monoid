// A person's presets as their devices carry them between the stations of a workspace (client/core-ts/src/
// preset-records.ts, one rule for the station and the core): a record counts its changes (`rev`), the higher wins, and a
// deletion is a record of its own.

///|
pub let name_max : Int = 60

///|
pub let instructions_max : Int = 20000

///|
pub let dirs_max : Int = 20

///|
let path_most : Int = 4096

///|
let address_most : Int = 300

///|
let who_most : Int = 320

///|
pub let gone_kept_most : Int = 200

///|
pub fn is_gone(r : J) -> Bool {
  at(Some(r), "gone") is Some(Bool(true))
}

///|
/// `v` as one text whatever order its keys were put in: an object's keys sorted by their UTF-16 code units.
pub fn canonical(v : J) -> String {
  match v {
    Arr(xs) => "[" + xs.map(canonical).join(",") + "]"
    Obj(fs) => {
      // (the last value of a key, as an object keeps it)
      let keys : Array[String] = []
      for f in fs {
        if !keys.contains(f.0) {
          keys.push(f.0)
        }
      }
      keys.sort_by(@jsjson.js_compare)
      let parts = keys.map(k => {
        let mut value = J::Null
        for f in fs {
          if f.0 == k {
            value = f.1
          }
        }
        @jsjson.stringify(Str(k)) + ":" + canonical(value)
      })
      "{" + parts.join(",") + "}"
    }
    other => @jsjson.stringify(other)
  }
}

///|
fn n_of(r : J, k : String) -> Double {
  num_of(at(Some(r), k)).unwrap_or(@double.not_a_number)
}

///|
/// The newer of two records of one preset: the higher `rev`; of the same, the deleted one; then the later `updatedAt`;
/// then the larger as canonical text.
pub fn newer_record(a : J, b : J) -> J {
  let (ra, rb) = (n_of(a, "rev"), n_of(b, "rev"))
  if ra != rb {
    return if ra > rb { a } else { b }
  }
  let ga = is_gone(a)
  if ga != is_gone(b) {
    return if ga { a } else { b }
  }
  let (ua, ub) = (n_of(a, "updatedAt"), n_of(b, "updatedAt"))
  if ua != ub {
    return if ua > ub { a } else { b }
  }
  if js_compare(canonical(a), canonical(b)) >= 0 {
    a
  } else {
    b
  }
}

///|
/// Of `gone`, those kept (GONE_KEPT of each owner's), in the order given.
pub fn gone_kept(gone : Array[J]) -> Array[J] {
  let owners : Array[(String, Array[Int])] = []
  for i, g in gone {
    let o = str_of(at(Some(g), "owner")).unwrap_or("")
    match owners.search_by(x => x.0 == o) {
      Some(k) => owners[k].1.push(i)
      None => owners.push((o, [i]))
    }
  }
  if owners.iter().all(x => x.1.length() <= gone_kept_most) {
    return gone
  }
  let kept : Array[Int] = []
  for x in owners {
    let list = x.1.copy()
    list.sort_by((ia, ib) => {
      let a = gone[ia]
      let b = gone[ib]
      let d = n_of(b, "updatedAt") - n_of(a, "updatedAt")
      if d != 0.0 && !d.is_nan() {
        return if d > 0.0 { 1 } else { -1 }
      }
      let r = n_of(b, "rev") - n_of(a, "rev")
      if r != 0.0 && !r.is_nan() {
        return if r > 0.0 { 1 } else { -1 }
      }
      let (x1, y1) = (@jsjson.units(str_of(at(Some(a), "id")).unwrap_or("")), @jsjson.units(str_of(at(Some(b), "id")).unwrap_or("")))
      let c = units_compare(x1, y1)
      if c != 0 {
        c
      } else {
        ia - ib
      }
    })
    for k in list[0:@cmp.minimum(gone_kept_most, list.length())] {
      kept.push(k)
    }
  }
  let out = []
  for i, g in gone {
    if kept.contains(i) {
      out.push(g)
    }
  }
  out
}

///|
/// `records` (by id, in their order) with the deletions `gone_kept` does not keep left out.
pub fn records_kept(records : Array[(String, J)]) -> Array[(String, J)] {
  let gone = records.filter(r => is_gone(r.1)).map(r => r.1)
  let kept = gone_kept(gone)
  if kept.length() == gone.length() {
    return records
  }
  records.filter(r => !is_gone(r.1) || kept.iter().any(k => jeq(k, r.1)))
}

///|
fn count_ok(v : J?, least : Double) -> Bool {
  match v {
    Some(Num(d)) => !d.is_nan() && !d.is_inf() && d == d.floor() && d.abs() <= 9007199254740991.0 && d >= least
    _ => false
  }
}

///|
/// model-speed.ts `modelSpeed`.
pub fn model_speed(v : J?) -> String? {
  match str_of(v) {
    Some(("standard" | "fast" | "ultrafast") as s) => Some(s)
    _ => None
  }
}

///|
/// A model configuration as a preset is given one: each field trimmed, what is empty left out; none without a model.
pub fn model_of(v : J?) -> J? {
  guard v is Some(Obj(_)) else { return None }
  let m = trim(str_of(at(v, "model")).unwrap_or(""))
  if m == "" {
    return None
  }
  let out = [("model", js(m))]
  let rt = trim(str_of(at(v, "runtime")).unwrap_or(""))
  if rt != "" {
    out.push(("runtime", js(rt)))
  }
  let eff = trim(str_of(at(v, "effort")).unwrap_or(""))
  if eff != "" {
    out.push(("effort", js(eff)))
  }
  match at(v, "fast") {
    Some(Bool(b)) => out.push(("fast", jb(b)))
    _ => ()
  }
  if at(v, "tui") is Some(Bool(true)) { out.push(("tui", jb(true))) }
  match model_speed(at(v, "speed")) {
    Some(s) => out.push(("speed", js(s)))
    None => ()
  }
  match at(v, "context") {
    Some(Num(c)) if !c.is_nan() && !c.is_inf() && c == c.floor() && c > 0.0 => out.push(("context", jn(c)))
    _ => ()
  }
  let prof = trim(str_of(at(v, "profile")).unwrap_or(""))
  if prof != "" {
    out.push(("profile", js(prof)))
  }
  match at(v, "profiles") {
    Some(Arr(xs)) => {
      let ps : Array[String] = []
      for x in xs {
        match str_of(Some(x)) {
          Some(s) if trim(s) != "" && !ps.contains(trim(s)) => ps.push(trim(s))
          _ => ()
        }
      }
      if ps.length() > 0 {
        out.push(("profiles", jsa(ps)))
      }
    }
    _ => ()
  }
  Some(jo(out))
}

///|
/// Where a preset's chats are opened, as it is given: (autoStation, station, stations).
pub fn stations_of(o : J?) -> (Bool, String?, Array[String]?) {
  match at(o, "stations") {
    Some(Arr(xs)) => {
      let list : Array[String] = []
      for x in xs {
        match str_of(Some(x)) {
          Some(s) if trim(s) != "" && !list.contains(trim(s)) => list.push(trim(s))
          _ => ()
        }
      }
      if list.length() == 1 {
        return (false, Some(list[0]), None)
      }
      if list.length() > 1 {
        return (false, None, Some(list))
      }
      return (false, None, None)
    }
    _ => ()
  }
  let s = trim(str_of(at(o, "station")).unwrap_or(""))
  if s != "" {
    return (false, Some(s), None)
  }
  if at(o, "autoStation") is Some(Bool(true)) {
    return (true, None, None)
  }
  (false, None, None)
}

///|
/// The fields `stations_of` says, as a record has them.
pub fn station_fields(st : (Bool, String?, Array[String]?)) -> Array[(String, J)] {
  let out = []
  if st.0 {
    out.push(("autoStation", jb(true)))
  }
  if st.1 is Some(s) {
    out.push(("station", js(s)))
  }
  if st.2 is Some(ss) {
    out.push(("stations", jsa(ss)))
  }
  out
}

///|
fn refusal(m : String) -> Thrown {
  Thrown("RecordRefusal", m)
}

///|
fn id_ok(id : String) -> Bool {
  if id.length() < 1 || id.length() > 64 {
    return false
  }
  for i in 0..<id.length() {
    let c = id.unsafe_charcode_at(i)
    if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
      return false
    }
  }
  true
}

///|
/// A record as a device or a station says it, checked and made what both sides keep.
pub fn record_of(raw : J) -> J raise Thrown {
  guard raw is Obj(_) else { raise refusal("a record is an object") }
  let o = Some(raw)
  let id = match str_of(at(o, "id")) {
    Some(i) if id_ok(i) => i
    _ => raise refusal("id: 1 to 64 letters, digits, - or _")
  }
  let owner = match str_of(at(o, "owner")) {
    Some(w) if w.length() <= who_most => w
    _ => raise refusal("owner: the sub of the person it is of")
  }
  if !count_ok(at(o, "rev"), 1.0) {
    raise refusal("rev: how many times it was changed, from 1")
  }
  if !count_ok(at(o, "updatedAt"), 0.0) {
    raise refusal("updatedAt: a time in ms")
  }
  let rev = at(o, "rev").unwrap()
  let updated_at = at(o, "updatedAt").unwrap()
  if at(o, "gone") is Some(Bool(true)) {
    return jo([("id", js(id)), ("owner", js(owner)), ("rev", rev), ("gone", jb(true)), ("updatedAt", updated_at)])
  }
  let name = trim(str_of(at(o, "name")).unwrap_or(""))
  if name == "" {
    raise refusal("a preset needs a name")
  }
  if char_count(name) > name_max {
    raise refusal("a preset's name is \{name_max} characters at most")
  }
  let instructions = trim(str_of(at(o, "instructions")).unwrap_or(""))
  if instructions.length() > instructions_max {
    raise refusal("its instructions are too long")
  }
  let given = match at(o, "dirs") {
    None | Some(Null) => []
    Some(Arr(xs)) => xs
    Some(_) => raise refusal("dirs: a list of folders")
  }
  let dirs : Array[(String, String?, String)] = []
  for d in given {
    let path = match str_of(at(Some(d), "path")) {
      Some(p) if trim(p) != "" && p.length() <= path_most => p
      _ => raise refusal("a folder needs a path")
    }
    let station = match str_of(at(Some(d), "station")) {
      Some(s) if trim(s) != "" && s.length() <= address_most => s
      _ => raise refusal("folder \{path}: station, the address of the station it is on")
    }
    let repo = str_of(at(Some(d), "repo"))
    if repo is Some(r) && r.length() > path_most {
      raise refusal("folder \{path}: repo is too long")
    }
    if !dirs.iter().any(x => x.0 == path && x.2 == station) {
      dirs.push((path, match repo { Some("") => None; r => r }, station))
    }
  }
  if dirs.length() > dirs_max {
    raise refusal("a preset has \{dirs_max} folders at most")
  }
  let st = stations_of(o)
  let model = model_of(at(o, "model"))
  let created_by = str_of(at(o, "createdBy")).unwrap_or("")
  if created_by.length() > who_most {
    raise refusal("createdBy is too long")
  }
  let created_at = match at(o, "createdAt") {
    None => Some(J::Num(0.0))
    v => v
  }
  if !count_ok(created_at, 0.0) {
    raise refusal("createdAt: a time in ms")
  }
  let home = match str_of(at(o, "home")) {
    Some(h) if h != "" && h.length() <= address_most => h
    _ => raise refusal("home: the id of the station it was made on")
  }
  let fields = [
    ("id", js(id)),
    ("name", js(name)),
    ("dirs", ja(dirs.map(d => jo([("path", js(d.0)), ("repo", jopt(d.1)), ("station", js(d.2))])))),
    ("instructions", js(instructions)),
  ]
  for f in station_fields(st) {
    fields.push(f)
  }
  if model is Some(m) {
    fields.push(("model", m))
  }
  fields.push(("createdBy", js(created_by)))
  fields.push(("createdAt", created_at.unwrap()))
  fields.push(("updatedAt", updated_at))
  fields.push(("owner", js(owner)))
  fields.push(("rev", rev))
  fields.push(("home", js(home)))
  jo(fields)
}
