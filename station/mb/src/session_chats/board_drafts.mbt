// A person's drafts of 待派发 (client/core-ts/src/board-drafts.ts, station/src/sessions/board-drafts.ts): carried by
// their devices between the stations of a workspace, kept in stillfail.db (`board_drafts`) and their files under
// `<data>/board-files`. IO is injected via `BoardDraftsDeps` so pure tests run without `@host.Host` and `station_main`
// runs entirely on async `host_*` IO.

///|
pub let drafts_most : Int = 200

///|
pub let gone_drafts_most : Int = 200

///|
pub let title_most : Int = 4000

///|
pub let draft_files_most : Int = 20

///|
let draft_name_most : Int = 200

///|
let draft_who_most : Int = 320

///|
pub let gone_files_ms : Double = 86400000.0

///|
let board_gone_dir : String = ".gone"

///|
fn draft_refusal(m : String) -> Thrown {
  Thrown("DraftRefusal", m)
}

///|
pub fn is_gone_draft(r : J) -> Bool {
  at(Some(r), "gone") is Some(Bool(true))
}

///|
fn draft_id_ok(id : String) -> Bool {
  if id.length() < 1 || id.length() > 120 {
    return false
  }
  for i in 0..<id.length() {
    let c = id.unsafe_charcode_at(i)
    if !(
      (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == ':' ||
      c == '_' ||
      c == '.' ||
      c == '-'
    ) {
      return false
    }
  }
  true
}

///|
/// The newer of two records of one draft: the higher `rev`; of the same, the deleted one; then the later `updatedAt`;
/// then the larger as canonical text.
pub fn newer_draft(a : J, b : J) -> J {
  let (ra, rb) = (n_of(a, "rev"), n_of(b, "rev"))
  if ra != rb {
    return if ra > rb { a } else { b }
  }
  let ga = is_gone_draft(a)
  if ga != is_gone_draft(b) {
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
/// A draft as a device or a station says it, checked and made what both sides keep (client/core-ts/src/board-drafts.ts
/// `draftOf`). Raises `Thrown("DraftRefusal", ...)` saying what is wrong.
pub fn draft_of(raw : J) -> J raise Thrown {
  guard raw is Obj(_) else { raise draft_refusal("a draft is an object") }
  let o = Some(raw)
  let id = match str_of(at(o, "id")) {
    Some(i) if draft_id_ok(i) => i
    _ => raise draft_refusal("id: 1 to 120 letters, digits, :, ., - or _")
  }
  let owner = match str_of(at(o, "owner")) {
    Some(w) if w != "" && w.length() <= draft_who_most => w
    _ => raise draft_refusal("owner: the sub of the person it is of")
  }
  if !count_ok(at(o, "rev"), 1.0) {
    raise draft_refusal("rev: how many times it was changed, from 1")
  }
  if !count_ok(at(o, "updatedAt"), 0.0) {
    raise draft_refusal("updatedAt: a time in ms")
  }
  let rev = at(o, "rev").unwrap()
  let updated_at = at(o, "updatedAt").unwrap()
  if at(o, "gone") is Some(Bool(true)) {
    return jo([
      ("id", js(id)),
      ("owner", js(owner)),
      ("rev", rev),
      ("gone", jb(true)),
      ("updatedAt", updated_at),
    ])
  }
  if !count_ok(at(o, "at"), 0.0) {
    raise draft_refusal("at: when it was written, in ms")
  }
  let at_val = at(o, "at").unwrap()
  let given = match at(o, "files") {
    None | Some(Null) => []
    Some(Arr(xs)) => xs
    Some(_) => raise draft_refusal("files: a list of files")
  }
  let files : Array[(String, String, J)] = []
  for f in given {
    let fid = match str_of(at(Some(f), "id")) {
      Some(x) if draft_id_ok(x) => x
      _ => raise draft_refusal("a file needs an id")
    }
    let name = match str_of(at(Some(f), "name")) {
      Some(n) if n != "" && n.length() <= draft_name_most => n
      _ => raise draft_refusal("file \{fid}: a name, \{draft_name_most} characters at most")
    }
    let size = match at(Some(f), "size") {
      None | Some(Null) => Some(J::Num(0.0))
      v => v
    }
    if !count_ok(size, 0.0) {
      raise draft_refusal("file \{fid}: size, in bytes")
    }
    if !files.iter().any(x => x.0 == fid) {
      files.push((fid, name, size.unwrap()))
    }
  }
  if files.length() > draft_files_most {
    raise draft_refusal("a draft has \{draft_files_most} files at most")
  }
  let title = trim(str_of(at(o, "title")).unwrap_or(""))
  if title.length() > title_most {
    raise draft_refusal("its words are too long")
  }
  if title == "" && files.length() == 0 {
    raise draft_refusal("a draft needs words or a file")
  }
  let station = match str_of(at(o, "station")) {
    Some(s) if s != "" && s.length() <= draft_name_most => s
    _ => raise draft_refusal("station: the address of the station it is to run on")
  }
  let station_name = str_of(at(o, "stationName")).unwrap_or("")
  if station_name.length() > draft_name_most {
    raise draft_refusal("stationName is too long")
  }
  jo([
    ("id", js(id)),
    ("owner", js(owner)),
    ("rev", rev),
    ("at", at_val),
    ("updatedAt", updated_at),
    ("title", js(title)),
    ("station", js(station)),
    ("stationName", js(station_name)),
    ("files", ja(files.map(f => jo([("id", js(f.0)), ("name", js(f.1)), ("size", f.2)])))),
  ])
}

///|
/// What a device or a station said of drafts, each checked; one that does not check left out.
pub fn drafts_of(raw : J) -> Array[J] {
  match raw {
    Arr(xs) => {
      let out : Array[J] = []
      for r in xs {
        try {
          out.push(draft_of(r))
        } catch {
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// `given` merged into `kept` (by id), the newer of each kept; then past `drafts_most` the oldest drafts by `at` go
/// (as a deletion of their own each), and past `gone_drafts_most` the deletions longest gone. Returns `(merged,
/// changed_ref)` where `changed_ref` is true when a new map was produced.
pub fn merge_drafts(kept : Map[String, J], given : Array[J]) -> (Map[String, J], Bool) {
  let mut all : Map[String, J]? = None
  for r in given {
    let rid = match str_of(at(Some(r), "id")) {
      Some(id) => id
      None => continue
    }
    let cur = match all {
      Some(m) => m
      None => kept
    }
    match cur.get(rid) {
      Some(was) if jeq(newer_draft(was, r), was) || canonical(was) == canonical(r) => continue
      _ => ()
    }
    let m = match all {
      Some(m) => m
      None => {
        let c = kept.copy()
        all = Some(c)
        c
      }
    }
    m[rid] = r
  }
  let now = match all {
    Some(m) => m
    None => kept
  }
  let live : Array[String] = []
  for id, r in now {
    if !is_gone_draft(r) {
      live.push(id)
    }
  }
  let mut out : Map[String, J]? = all
  if live.length() > drafts_most {
    live.sort_by((a, b) => {
      let d = n_of(now[b], "at") - n_of(now[a], "at")
      if d != 0.0 && !d.is_nan() {
        if d > 0.0 { 1 } else { -1 }
      } else {
        js_compare(a, b)
      }
    })
    let m = match out {
      Some(m) => m
      None => {
        let c = now.copy()
        out = Some(c)
        c
      }
    }
    for id in live[drafts_most:] {
      let d = now[id]
      m[id] = jo([
        ("id", js(id)),
        ("owner", at(Some(d), "owner").unwrap_or(js(""))),
        ("rev", jn(n_of(d, "rev") + 1.0)),
        ("gone", jb(true)),
        ("updatedAt", at(Some(d), "updatedAt").unwrap_or(ji(0))),
      ])
    }
  }
  let held = match out {
    Some(m) => m
    None => now
  }
  let gone : Array[String] = []
  for id, r in held {
    if is_gone_draft(r) {
      gone.push(id)
    }
  }
  if gone.length() > gone_drafts_most {
    gone.sort_by((a, b) => {
      let d = n_of(held[b], "updatedAt") - n_of(held[a], "updatedAt")
      if d != 0.0 && !d.is_nan() {
        return if d > 0.0 { 1 } else { -1 }
      }
      let r = n_of(held[b], "rev") - n_of(held[a], "rev")
      if r != 0.0 && !r.is_nan() {
        return if r > 0.0 { 1 } else { -1 }
      }
      js_compare(a, b)
    })
    let going : Set[String] = Set::new()
    for id in gone[gone_drafts_most:] {
      going.add(id)
    }
    let trimmed : Map[String, J] = Map::new()
    for id, r in held {
      if !going.contains(id) {
        trimmed[id] = r
      }
    }
    out = Some(trimmed)
  }
  match out {
    Some(m) => (m, true)
    None => (kept, false)
  }
}

///|
fn board_map_to_j(m : Map[String, J]) -> J {
  let fields : Array[(String, J)] = []
  for k, v in m {
    fields.push((k, v))
  }
  jo(fields)
}

///|
fn board_map_values(m : Map[String, J]) -> Array[J] {
  let out : Array[J] = []
  for _, v in m {
    out.push(v)
  }
  out
}

///|
fn board_hashed(parts : Array[String]) -> String {
  let joined = parts.join("\u{0}")
  slice(@drive.hex(@drive.sha256_bytes(@utf8.encode(joined))), 0, b=32)
}

///|
pub(all) struct BoardFileStat {
  is_file : Bool
  size : Double
  mtime_ms : Double
}

///|
pub(all) struct BoardDraftsDeps {
  read_store : (String, String) -> String? raise
  write_store : (String, String, String) -> Unit raise
  dir : () -> String
  uploads : () -> String
  now : () -> Double
  sep : String
  resolve : (String) -> String
  stat : async (String) -> BoardFileStat?
  mkdir : async (String) -> Unit
  rename : async (String, String) -> Unit
  rm : async (String, Bool) -> Unit
  readdir : async (String) -> Array[String]?
  utimes : async (String, Double) -> Unit
  read_bytes : async (String) -> Bytes
  copy_file : async (String, String) -> Unit
  random_hex6 : () -> String
  log_warn : (String, String) -> Unit
}

///|
pub struct BoardDrafts {
  deps : BoardDraftsDeps
  held : Map[String, Map[String, J]]
}

///|
pub fn BoardDrafts::new(deps : BoardDraftsDeps) -> BoardDrafts {
  { deps, held: Map::new() }
}

///|
fn BoardDrafts::read(self : BoardDrafts, ws : String, sub : String) -> Map[String, J] raise {
  let at_key = "\{ws}\u{0}\{sub}"
  match self.held.get(at_key) {
    Some(d) => d
    None => {
      let text = (self.deps.read_store)(ws, sub)
      let drafts : Map[String, J] = Map::new()
      match text {
        None => ()
        Some(t) =>
          try {
            let parsed = parse_js(t)
            let values = match parsed {
              Obj(_) => keys_of(Some(parsed)).map(k => at(Some(parsed), k).unwrap_or(Null))
              Arr(xs) => xs
              _ => []
            }
            for r in drafts_of(Arr(values)) {
              if str_of(at(Some(r), "owner")) == Some(sub) {
                if str_of(at(Some(r), "id")) is Some(id) {
                  drafts[id] = r
                }
              }
            }
          } catch {
            e =>
              (self.deps.log_warn)(
                "a person's drafts kept here do not read; taken as none",
                thrown_message(e),
              )
          }
      }
      self.held[at_key] = drafts
      drafts
    }
  }
}

///|
fn BoardDrafts::person(self : BoardDrafts, ws : String, sub : String) -> String {
  @nodepath.join(self.deps.sep, [(self.deps.dir)(), board_hashed([ws, sub])])
}

///|
fn BoardDrafts::file_at(
  self : BoardDrafts,
  ws : String,
  sub : String,
  draft : String,
  file : String,
  gone? : Bool = false,
) -> String {
  let p = self.person(ws, sub)
  if gone {
    @nodepath.join(self.deps.sep, [p, board_gone_dir, board_hashed([draft]), board_hashed([file])])
  } else {
    @nodepath.join(self.deps.sep, [p, board_hashed([draft]), board_hashed([file])])
  }
}

///|
async fn BoardDrafts::files(self : BoardDrafts, ws : String, sub : String, drafts : Map[String, J]) -> Array[String] {
  let out : Array[String] = []
  for _, d in drafts {
    if is_gone_draft(d) {
      continue
    }
    let did = match str_of(at(Some(d), "id")) {
      Some(id) => id
      None => continue
    }
    for f in arr_of(at(Some(d), "files")).unwrap_or([]) {
      let fid = match str_of(at(Some(f), "id")) {
        Some(id) => id
        None => continue
      }
      match (self.deps.stat)(self.file_at(ws, sub, did, fid)) {
        Some(st) if st.is_file => out.push(fid)
        _ => ()
      }
    }
  }
  out.sort_by(js_compare)
  out
}

///|
/// `sub`'s drafts in `ws` as kept here, and the files kept of them.
pub async fn BoardDrafts::said(self : BoardDrafts, ws : String, sub : String) -> J {
  let drafts = self.read(ws, sub)
  let files = self.files(ws, sub, drafts)
  jo([("drafts", ja(board_map_values(drafts))), ("files", jsa(files))])
}

///|
/// What `sub`'s device brought merged into what is kept.
pub async fn BoardDrafts::carry(self : BoardDrafts, ws : String, sub : String, given : J) -> J {
  guard given is Arr(items) else { raise draft_refusal("drafts: a list of drafts") }
  let records = drafts_of(given)
  if records.length() != items.length() {
    raise draft_refusal("a draft does not read")
  }
  if records.iter().any(r => str_of(at(Some(r), "owner")) != Some(sub)) {
    raise draft_refusal("a draft is its person's own")
  }
  let was = self.read(ws, sub)
  let (now, touched) = merge_drafts(was, records)
  let now_j = board_map_to_j(now)
  let changed = touched && canonical(now_j) != canonical(board_map_to_j(was))
  if changed {
    (self.deps.write_store)(ws, sub, stringify(now_j))
    self.held["\{ws}\u{0}\{sub}"] = now
    for id, before in was {
      if is_gone_draft(before) {
        continue
      }
      match now.get(id) {
        None => self.put_aside(ws, sub, before)
        Some(after) if is_gone_draft(after) => self.put_aside(ws, sub, before)
        Some(after) => {
          let after_files = arr_of(at(Some(after), "files")).unwrap_or([])
          for f in arr_of(at(Some(before), "files")).unwrap_or([]) {
            let fid = match str_of(at(Some(f), "id")) {
              Some(x) => x
              None => continue
            }
            if !after_files.iter().any(x => str_of(at(Some(x), "id")) == Some(fid)) {
              (self.deps.rm)(self.file_at(ws, sub, id, fid), false)
            }
          }
        }
      }
    }
  }
  self.sweep(ws, sub)
  let files = self.files(ws, sub, now)
  jo([("drafts", ja(board_map_values(now))), ("files", jsa(files)), ("changed", jb(changed))])
}

///|
async fn BoardDrafts::put_aside(self : BoardDrafts, ws : String, sub : String, d : J) -> Unit {
  let did = match str_of(at(Some(d), "id")) {
    Some(id) => id
    None => return
  }
  let sep = self.deps.sep
  for f in arr_of(at(Some(d), "files")).unwrap_or([]) {
    let fid = match str_of(at(Some(f), "id")) {
      Some(id) => id
      None => continue
    }
    let from = self.file_at(ws, sub, did, fid)
    match (self.deps.stat)(from) {
      Some(st) if st.is_file => ()
      _ => continue
    }
    let to = self.file_at(ws, sub, did, fid, gone=true)
    (self.deps.mkdir)(@nodepath.dirname(sep, to))
    (self.deps.rename)(from, to)
    (self.deps.utimes)(to, (self.deps.now)()) catch {
      _ => ()
    }
  }
  (self.deps.rm)(@nodepath.join(sep, [self.person(ws, sub), board_hashed([did])]), true)
}

///|
async fn BoardDrafts::sweep(self : BoardDrafts, ws : String, sub : String) -> Unit {
  let sep = self.deps.sep
  let aside = @nodepath.join(sep, [self.person(ws, sub), board_gone_dir])
  let drafts = match (self.deps.readdir)(aside) {
    Some(ds) => ds
    None => return
  }
  for d in drafts {
    let dir_d = @nodepath.join(sep, [aside, d])
    let files = match (self.deps.readdir)(dir_d) {
      Some(fs) => fs
      None => continue
    }
    for f in files {
      let p = @nodepath.join(sep, [dir_d, f])
      match (self.deps.stat)(p) {
        Some(st) if (self.deps.now)() - st.mtime_ms > gone_files_ms =>
          (self.deps.rm)(p, false)
        _ => ()
      }
    }
    let left = (self.deps.readdir)(dir_d).unwrap_or([])
    if left.length() == 0 {
      (self.deps.rm)(dir_d, true)
    }
  }
}

///|
/// The upload at `path` kept as file `file` of `sub`'s live draft `draft`, moved out of the uploads.
pub async fn BoardDrafts::keep(
  self : BoardDrafts,
  ws : String,
  sub : String,
  draft : String,
  file : String,
  path : String,
) -> J {
  let drafts = self.read(ws, sub)
  match drafts.get(draft) {
    Some(d) if !is_gone_draft(d) &&
      arr_of(at(Some(d), "files")).unwrap_or([]).iter().any(f => str_of(at(Some(f), "id")) == Some(file)) => ()
    _ => raise draft_refusal("no such draft or file")
  }
  let sep = self.deps.sep
  let uploads = (self.deps.resolve)((self.deps.uploads)())
  let from = (self.deps.resolve)(path)
  if @nodepath.dirname(sep, from) != uploads {
    raise draft_refusal("not an upload")
  }
  let base_start = if ends(uploads, sep) { uploads.length() } else { uploads.length() + 1 }
  if starts(slice(from, base_start), ".") {
    raise draft_refusal("not an upload")
  }
  match (self.deps.stat)(from) {
    Some(st) if st.is_file => ()
    _ => raise draft_refusal("not an upload")
  }
  let to = self.file_at(ws, sub, draft, file)
  (self.deps.mkdir)(@nodepath.dirname(sep, to))
  (self.deps.rename)(from, to)
  jo([("files", jsa(self.files(ws, sub, drafts)))])
}

///|
priv struct FoundBoardFile {
  path : String
  name : String
  size : Double
}

///|
async fn BoardDrafts::found(
  self : BoardDrafts,
  ws : String,
  sub : String,
  draft : String,
  file : String,
) -> FoundBoardFile? {
  let drafts = self.read(ws, sub)
  let named = match drafts.get(draft) {
    Some(d) if !is_gone_draft(d) => {
      let mut hit : String? = None
      for f in arr_of(at(Some(d), "files")).unwrap_or([]) {
        if str_of(at(Some(f), "id")) == Some(file) {
          hit = str_of(at(Some(f), "name"))
          break
        }
      }
      hit
    }
    _ => None
  }
  for gone in [false, true] {
    let p = self.file_at(ws, sub, draft, file, gone~)
    match (self.deps.stat)(p) {
      Some(st) if st.is_file => return Some({ path: p, name: named.unwrap_or(file), size: st.size })
      _ => ()
    }
  }
  None
}

///|
/// The bytes of file `file` of `sub`'s draft `draft`, and their MIME type by its name; None where none are kept here.
pub async fn BoardDrafts::bytes(
  self : BoardDrafts,
  ws : String,
  sub : String,
  draft : String,
  file : String,
) -> (String, Bytes)? {
  match self.found(ws, sub, draft, file) {
    None => None
    Some(found) => Some((@drive.type_of(found.name), (self.deps.read_bytes)(found.path)))
  }
}

///|
/// File `file` of `sub`'s draft `draft` copied among the uploads for a message to take; None where none are kept here.
pub async fn BoardDrafts::stage(
  self : BoardDrafts,
  ws : String,
  sub : String,
  draft : String,
  file : String,
  name : String,
) -> J? {
  let found = match self.found(ws, sub, draft, file) {
    Some(f) => f
    None => return None
  }
  let base = name
    .replace_all(old="\\", new="/")
    .split("/")
    .last()
    .map(s => s.to_string())
    .unwrap_or("")
  let cleaned = chars(base)
    .map(c => if c.unsafe_charcode_at(0) < 0x20 { "_" } else { c })
    .join("")
  let mut start = 0
  while start < cleaned.length() && cleaned.unsafe_charcode_at(start) == '.' {
    start += 1
  }
  let safe0 = first_chars(slice(cleaned, start), 120)
  let safe = if safe0 == "" { "file" } else { safe0 }
  let dir = (self.deps.uploads)()
  (self.deps.mkdir)(dir)
  let stamp = @time.format_iso_ms((self.deps.now)().floor().to_int64())
    .view(end_offset=19)
    .to_string()
    .replace_all(old=":", new="-")
    .replace_all(old=".", new="-")
  let dest = @nodepath.join(self.deps.sep, [dir, "\{stamp}-\{(self.deps.random_hex6)()}-\{safe}"])
  (self.deps.copy_file)(found.path, dest)
  Some(jo([("name", js(safe)), ("path", js(dest)), ("size", jn(found.size))]))
}
