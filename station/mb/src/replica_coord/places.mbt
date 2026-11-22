// The places that keep a station's copies (places.ts), and how a copy is brought level with one: the other stations
// of its workspace, each keeping what it is sent under <data>/replicas/, without reading inside it:
//
//   <root>/<workspace>/<origin>/files/<sha256>           the attached files, shared by its generations
//   <root>/<workspace>/<origin>/<gen>/log/<batch>         a generation's batches
//   <root>/<workspace>/<origin>/<gen>/head.json           written after its batches and files, before anything goes

///|
/// What a place holds of one station's copies in a workspace: each generation (its head, its batches) and the files.
pub struct Holding {
  gen : String
  head : J?
  batches : Array[String]
}

///|
pub struct Held {
  gens : Array[Holding]
  files : Array[String]
}

///|
pub fn Held::nothing() -> Held {
  { gens: [], files: [] }
}

///|
pub fn Held::to_json(self : Held) -> J {
  jo([
    (
      "gens",
      ja(
        self.gens.map(g => jo([
          ("gen", js(g.gen)),
          ("head", match g.head { Some(h) => h; None => Null }),
          ("batches", jstrs(g.batches)),
        ])),
      ),
    ),
    ("files", jstrs(self.files)),
  ])
}

///|
/// As peers.ts reads it back: `{gens: Array.isArray(...) ? ... : [], files: ...}`, each generation as it came.
pub fn Held::of_json(v : J) -> Held {
  let gens = items(at(v, "gens")).map(g => {
    gen: text_at(g, "gen"),
    head: match at(g, "head") {
      Some(Null) | None => None
      Some(h) => Some(h)
    },
    batches: strings_of(at(g, "batches")),
  })
  { gens, files: strings_of(at(v, "files")) }
}

///|
/// Where copies are put (places.ts `Place`): a station's own folder, or another station over the mesh.
pub struct Place {
  held : async (String, String) -> Held
  put : async (String, String, String, String, String, Bytes) -> Unit
  /// A file, by its hash, read from `source` (a path on this station).
  put_file : async (String, String, String, String) -> Unit
  drop : async (String, String, String, Array[String], Array[String]) -> Unit
}

///|
fn check(ws : String, origin : String, gen? : String) -> Unit raise {
  if !is_workspace(ws) || !is_station(origin) || (gen is Some(g) && !is_gen(g)) {
    raise failed("not a copy's name")
  }
}

///|
/// Where a station keeps what other stations send it (`<data>/replicas`), on its own disk.
pub struct FolderPlace {
  root : String
  fs : Fs
}

///|
pub fn FolderPlace::new(fs : Fs, root : String) -> FolderPlace {
  { root, fs }
}

///|
pub fn FolderPlace::dir(self : FolderPlace, ws : String, origin : String) -> String {
  self.fs.join([self.root, ws, origin])
}

///|
/// Written beside and renamed into place, synced: whole or not at all.
async fn FolderPlace::whole(self : FolderPlace, path : String, next : async () -> Bytes?) -> Unit {
  self.fs.mkdirs(self.fs.dirname(path))
  let tmp = "\{path}.\{self.fs.random_hex(4)}.tmp"
  let mut at = 0.0
  let put = async fn(offset : Double, data : Bytes, last : Bool) {
    let m : Map[String, Json] = { "path": Json::string(tmp), "offset": Json::number(offset) }
    if last {
      m["truncate"] = Json::boolean(true)
      m["sync"] = Json::boolean(true)
    }
    ignore(self.fs.host.shell("fs.put", Json::object(m), bytes=data))
  }
  try {
    while next() is Some(piece) {
      put(at, piece, false)
      at += piece.length().to_double()
    }
    put(at, b"", true)
  } catch {
    e => {
      self.fs.rm_f(tmp) catch {
        _ => ()
      }
      raise e
    }
  }
  self.fs.rename(tmp, path)
}

///|
async fn FolderPlace::head_at(self : FolderPlace, path : String) -> J? {
  match self.fs.read_text(path) {
    Some(t) => as_head(parse(t)) catch { _ => None }
    None => None
  }
}

///|
pub async fn FolderPlace::held(self : FolderPlace, ws : String, origin : String) -> Held {
  check(ws, origin)
  let dir = self.dir(ws, origin)
  let gens = []
  for gen in self.fs.names(dir) {
    if !is_gen(gen) {
      continue
    }
    let batches = self.fs.names(self.fs.join([dir, gen, "log"])).filter(is_batch)
    batches.sort_by(js_cmp)
    gens.push({ gen, head: self.head_at(self.fs.join([dir, gen, "head.json"])), batches })
  }
  gens.sort_by((a, b) => {
    let d = gen_made(a.gen) - gen_made(b.gen)
    if d < 0.0 {
      -1
    } else if d > 0.0 {
      1
    } else if js_less(a.gen, b.gen) {
      -1
    } else {
      1
    }
  })
  { gens, files: self.fs.names(self.fs.join([dir, "files"])).filter(is_hash) }
}

///|
pub async fn FolderPlace::put(self : FolderPlace, ws : String, origin : String, gen : String, kind : String, name : String, bytes : Bytes) -> Unit {
  check(ws, origin, gen~)
  let dir = self.fs.join([self.dir(ws, origin), gen])
  if kind == "batch" {
    if !is_batch(name) {
      raise failed("not a batch's name")
    }
    // (a batch is never written over: what it holds is what its name says)
    if self.fs.there(self.fs.join([dir, "log", name])) {
      return
    }
    self.whole(self.fs.join([dir, "log", name]), Whole(bytes).reader(self.fs))
  } else {
    let head = as_head(parse(@utf8.decode_lossy(bytes)))
    guard head is Some(h) && head_gen(h) == gen && text_at(h, "origin") == origin && text_at(h, "workspace") == ws else {
      raise failed("not a head of this copy")
    }
    // A head never goes back: one older than what is held is not taken.
    if self.head_at(self.fs.join([dir, "head.json"])) is Some(was) && head_to(was) > head_to(h) {
      return
    }
    for b in head_batches(h) {
      if !self.fs.there(self.fs.join([dir, "log", b])) {
        raise failed("batch \{b} is not here yet")
      }
    }
    self.whole(self.fs.join([dir, "head.json"]), Whole(bytes).reader(self.fs))
  }
}

///|
pub async fn FolderPlace::put_file(self : FolderPlace, ws : String, origin : String, hash : String, source : String) -> Unit {
  let size = match self.fs.stat(source) {
    Some((_, s, _)) => s
    None => 0.0
  }
  self.put_file_from(ws, origin, hash, File(source, 0.0, size).reader(self.fs))
}

///|
/// Takes a file sent as it comes.
pub async fn FolderPlace::put_file_from(self : FolderPlace, ws : String, origin : String, hash : String, next : async () -> Bytes?) -> Unit {
  check(ws, origin)
  if !is_hash(hash) {
    raise failed("not a file's hash")
  }
  let path = self.fs.join([self.dir(ws, origin), "files", hash])
  if self.fs.there(path) {
    while next() is Some(_) {

    }
    return
  }
  self.whole(path, next)
}

///|
pub async fn FolderPlace::drop(self : FolderPlace, ws : String, origin : String, gen : String, batches : Array[String], files : Array[String]) -> Unit {
  check(ws, origin, gen~)
  let dir = self.dir(ws, origin)
  let head = self.head_at(self.fs.join([dir, gen, "head.json"]))
  let named = match head {
    Some(h) => head_batches(h)
    None => []
  }
  for b in batches {
    if is_batch(b) && !named.contains(b) {
      self.fs.files.unlink(self.fs.join([dir, gen, "log", b])) catch {
        _ => ()
      }
    }
  }
  if files.length() == 0 {
    return
  }
  // (a file stays while any generation held names it)
  let kept : Map[String, Bool] = {}
  for g in self.held(ws, origin).gens {
    match g.head {
      Some(h) => {
        for f in head_files(h) { kept[f] = true }
        for f in head_transcript_files(h) { kept[f] = true }
      }
      None => ()
    }
  }
  for f in files {
    if is_hash(f) && !kept.contains(f) {
      self.fs.files.unlink(self.fs.join([dir, "files", f])) catch {
        _ => ()
      }
    }
  }
}

///|
/// Where a batch, a head or a file held here is, by its name; None where it is not.
pub async fn FolderPlace::path_of(self : FolderPlace, ws : String, origin : String, gen : String?, name : String) -> String? {
  check(ws, origin, gen?)
  let path = match gen {
    None => if is_hash(name) { Some(self.fs.join([self.dir(ws, origin), "files", name])) } else { None }
    Some(g) =>
      if name == "head.json" {
        Some(self.fs.join([self.dir(ws, origin), g, "head.json"]))
      } else if is_batch(name) {
        Some(self.fs.join([self.dir(ws, origin), g, "log", name]))
      } else {
        None
      }
  }
  match path {
    Some(p) => if self.fs.there(p) { Some(p) } else { None }
    None => None
  }
}

///|
/// A batch, a head or a file held here, whole; None where it is not.
pub async fn FolderPlace::read(self : FolderPlace, ws : String, origin : String, gen : String?, name : String) -> Bytes? {
  match self.path_of(ws, origin, gen, name) {
    Some(p) => self.fs.files.read_bytes(p)
    None => None
  }
}

///|
/// A batch, a head or a file held here, a piece at a time.
pub async fn FolderPlace::stream(self : FolderPlace, ws : String, origin : String, gen : String?, name : String) -> Body {
  match self.path_of(ws, origin, gen, name) {
    Some(p) => {
      let size = match self.fs.stat(p) {
        Some((_, s, _)) => s
        None => 0.0
      }
      File(p, 0.0, size)
    }
    None => raise failed("\{name} is not there")
  }
}

///|
/// Every station whose copies are held here in `ws`, with each generation's head.
pub async fn FolderPlace::origins(self : FolderPlace, ws : String) -> Array[(String, Array[J])] {
  if !is_workspace(ws) {
    return []
  }
  let out = []
  for origin in self.fs.names(self.fs.join([self.root, ws])) {
    if !is_station(origin) {
      continue
    }
    let heads = self.held(ws, origin).gens.filter_map(g => g.head)
    if heads.length() > 0 {
      out.push((origin, heads))
    }
  }
  out
}

///|
pub fn origins_json(list : Array[(String, Array[J])]) -> J {
  ja(list.map(o => jo([("origin", js(o.0)), ("heads", ja(o.1))])))
}

///|
/// All it holds of a workspace, or of one station's copies there, let go.
pub async fn FolderPlace::remove(self : FolderPlace, ws : String, origin? : String) -> Unit {
  let path = match origin {
    None => self.fs.join([self.root, ws])
    Some(o) => self.dir(ws, o)
  }
  self.fs.rm_rf(path) catch {
    _ => ()
  }
}

///|
pub fn FolderPlace::place(self : FolderPlace) -> Place {
  {
    held: (ws, origin) => self.held(ws, origin),
    put: (ws, origin, gen, kind, name, bytes) => self.put(ws, origin, gen, kind, name, bytes),
    put_file: (ws, origin, hash, source) => self.put_file(ws, origin, hash, source),
    drop: (ws, origin, gen, batches, files) => self.drop(ws, origin, gen, batches, files),
  }
}

///|
/// The generation of this station's own copy being brought to a place: its head, its batches' bytes, where its files
/// are now.
pub struct Own {
  head : J
  batch : async (String) -> Bytes
  sources : async (Array[String]) -> Array[(String, String)]
}

///|
/// What a place holds of this station's generation, as this station last left it there.
pub struct Known {
  gen : String
  batches : Array[String]
  files : Map[String, Bool]
  others : Map[String, Bool]
  mut to : Double
  mut made : Double
}

///|
/// What bringing a place level found: `behind`, or how far it goes now, the files not sent, what it holds now.
pub enum Levelled {
  Behind
  Level(Double, Int, Known)
}

///|
/// Whether what a place holds of a generation was written by runs this station's own head does not account for.
pub fn behind(own : J, held : Held) -> Bool {
  let origin = text_at(own, "origin")
  let own_gen = head_gen(own)
  let runs = head_runs(own)
  for g in held.gens {
    guard g.head is Some(h) && text_at(h, "origin") == origin else { continue }
    if g.gen != own_gen {
      if gen_made(g.gen) > gen_made(own_gen) {
        return true
      }
      continue
    }
    let theirs = head_runs(h)
    guard theirs.last() is Some(last) else { continue }
    let mut i = -1
    for k, r in runs {
      if r.0 == last.0 {
        i = k
        break
      }
    }
    if i < 0 {
      if head_to(h) > 0.0 && !(runs.length() > 0 && head_to(h) < runs[0].1) {
        return true
      }
      continue
    }
    let end = if i + 1 < runs.length() { runs[i + 1].1 - 1.0 } else { head_to(own) }
    if head_to(h) > end {
      return true
    }
  }
  false
}

///|
/// Brings `place` level with this station's own copy of `ws`: its batches and files first, its head, then what is not
/// named any more goes. `known`: what the place held after it was levelled last (None: asked of it now).
pub async fn level(place : Place, ws : String, own : Own, known? : Known? = None, include_transcripts? : Bool = true) -> Levelled {
  let origin = text_at(own.head, "origin")
  let gen = head_gen(own.head)
  let k = match known {
    Some(k) if k.gen == gen => k
    _ => {
      let held = (place.held)(ws, origin)
      if behind(own.head, held) {
        return Behind
      }
      let holding = held.gens.search_by(g => g.gen == gen).map(i => held.gens[i])
      let others : Map[String, Bool] = {}
      for g in held.gens {
        if g.gen != gen {
          match g.head {
            Some(h) => for f in head_all_files(h, include_transcripts~) { others[f] = true }
            None => ()
          }
        }
      }
      let files : Map[String, Bool] = {}
      for f in held.files {
        files[f] = true
      }
      let (to, made) = match holding {
        Some({ head: Some(h), .. }) => (head_to(h), num_at(h, "made").unwrap_or(-1.0))
        _ => (-1.0, -1.0)
      }
      {
        gen,
        batches: match holding {
          Some(x) => x.batches.copy()
          None => []
        },
        files,
        others,
        to,
        made,
      }
    }
  }
  for b in head_batches(own.head) {
    if k.batches.contains(b) {
      continue
    }
    (place.put)(ws, origin, gen, "batch", b, (own.batch)(b))
    k.batches.push(b)
  }
  let wanted = head_all_files(own.head, include_transcripts~)
  let lacking = wanted.filter(h => !k.files.contains(h))
  let sources = if lacking.length() == 0 { [] } else { (own.sources)(lacking) }
  let mut missing = 0
  for hash in lacking {
    match pair_get(sources, hash) {
      None => missing += 1
      Some(source) => {
        (place.put_file)(ws, origin, hash, source)
        k.files[hash] = true
      }
    }
  }
  if k.to != head_to(own.head) || k.made != head_made(own.head) {
    (place.put)(ws, origin, gen, "head", "head.json", @utf8.encode(@jsjson.stringify_indent(own.head, 1)))
    k.to = head_to(own.head)
    k.made = head_made(own.head)
  }
  let named = wanted
  let batches = head_batches(own.head)
  let old_batches = k.batches.filter(b => !batches.contains(b))
  let old_files = []
  for f, _ in k.files {
    if !named.contains(f) && !k.others.contains(f) {
      old_files.push(f)
    }
  }
  if old_batches.length() > 0 || old_files.length() > 0 {
    (place.drop)(ws, origin, gen, old_batches, old_files)
    let left = k.batches.filter(b => !old_batches.contains(b))
    k.batches.clear()
    k.batches.push_iter(left.iter())
    for f in old_files {
      k.files.remove(f)
    }
  }
  Level(head_to(own.head), missing, k)
}

///|
/// Whether `theirs` holds as much as `mine`: each generation as far, and every file.
pub fn holds_all(mine : Held, theirs : Held) -> Bool {
  for f in mine.files {
    if !theirs.files.contains(f) {
      return false
    }
  }
  for g in mine.gens {
    guard g.head is Some(h) else { continue }
    let to = match theirs.gens.search_by(t => t.gen == g.gen) {
      Some(i) =>
        match theirs.gens[i].head {
          Some(th) => head_to(th)
          None => -1.0
        }
      None => -1.0
    }
    if to < head_to(h) {
      return false
    }
  }
  true
}

///|
/// Brings `to` level with what `from` holds of another station's copies: every generation, nothing dropped. Whether
/// `to` holds all of it now.
pub async fn hand_over(from : FolderPlace, to : Place, ws : String, origin : String) -> Bool {
  let mine = from.held(ws, origin)
  let theirs = (to.held)(ws, origin)
  for hash in mine.files {
    if theirs.files.contains(hash) {
      continue
    }
    match from.path_of(ws, origin, None, hash) {
      Some(path) => (to.put_file)(ws, origin, hash, path)
      None => ()
    }
  }
  for g in mine.gens {
    guard g.head is Some(h) else { continue }
    let t = theirs.gens.search_by(x => x.gen == g.gen).map(i => theirs.gens[i])
    let their_to = match t {
      Some({ head: Some(th), .. }) => head_to(th)
      _ => -1.0
    }
    if their_to >= head_to(h) {
      continue
    }
    let has = match t {
      Some(x) => x.batches
      None => []
    }
    for b in head_batches(h) {
      if has.contains(b) {
        continue
      }
      match from.read(ws, origin, Some(g.gen), b) {
        Some(bytes) => (to.put)(ws, origin, g.gen, "batch", b, bytes)
        None => ()
      }
    }
    (to.put)(ws, origin, g.gen, "head", "head.json", @utf8.encode(@jsjson.stringify_indent(h, 1)))
  }
  holds_all(mine, (to.held)(ws, origin))
}
