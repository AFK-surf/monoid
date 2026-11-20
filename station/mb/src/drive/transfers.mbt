// Files copied (or moved) into this station's drive (transfers.ts): from a folder of its own, or from another station
// of the workspace, whose files this station reads over the station transport with what that station granted the
// member who asked (grants.mbt). Each is a transfer of its own here, on the station the files go to: one at a time, in
// the order asked, each file put together beside where it goes as an upload is and put there whole, the transfer kept
// on disk as it goes, so a station that restarts takes it up where it was. A move lets the originals go once every
// file is in place.
//
// A transfer is kept as the JavaScript object the TypeScript keeps (its keys in the order they were made, a key set
// again where it was, one deleted gone), so its file and what the pages are told are the same JSON.

using @jsjson {type JValue as JV}

///|
fn ju(s : String) -> String {
  s
}

///|
/// A JavaScript object's `key`.
pub fn oget(o : JV, key : String) -> JV? {
  match o {
    Obj(_) => o.get(key)
    _ => None
  }
}

///|
/// `o[key] = v`: where it is, else at the end.
pub fn oset(o : JV, key : String, v : JV) -> Unit {
  guard o is Obj(fields) else { return }
  let k = ju(key)
  for i, f in fields {
    if f.0 == k {
      fields[i] = (k, v)
      return
    }
  }
  fields.push((k, v))
}

///|
/// `delete o[key]`.
pub fn odel(o : JV, key : String) -> Unit {
  guard o is Obj(fields) else { return }
  let k = ju(key)
  for i, f in fields {
    if f.0 == k {
      fields.remove(i) |> ignore
      return
    }
  }
}

///|
pub fn jvs(s : String) -> JV {
  Str(ju(s))
}

///|
fn onum(o : JV, key : String) -> Double {
  match oget(o, key) {
    Some(Num(n)) => n
    _ => 0.0
  }
}

///|
fn ostr(o : JV, key : String) -> String? {
  match oget(o, key) {
    Some(Str(u)) => Some(@jsjson.sanitize_str(u))
    _ => None
  }
}

///|
fn oarr(o : JV, key : String) -> Array[JV] {
  match oget(o, key) {
    Some(Arr(a)) => a
    _ => []
  }
}

///|
fn ostrs(o : JV, key : String) -> Array[String] {
  oarr(o, key).filter_map(v => match v {
    Str(u) => Some(@jsjson.sanitize_str(u))
    _ => None
  })
}

///|
/// A deep copy (structuredClone of what JSON holds).
pub fn jclone(v : JV) -> JV {
  match v {
    Arr(a) => Arr(a.map(jclone))
    Obj(f) => Obj(f.map(p => (p.0, jclone(p.1))))
    v => v
  }
}

///|
/// Ended transfers are kept to be shown this long.
let kept_ms : Double = 86400000.0

///|
/// At most this many things in one transfer.
pub let most_items : Int = 100000

///|
/// Progress is written to disk at most this often while a file goes.
let save_every_ms : Double = 2000.0

///|
fn join2(a : String, b : String) -> String {
  if a == "" {
    b
  } else if b == "" {
    a
  } else {
    "\{a}/\{b}"
  }
}

///|
fn top_name(path : String) -> String {
  match path.find("/") {
    Some(i) => path.unsafe_substring(start=0, end=i)
    None => path
  }
}

///|
/// transfers.ts `free`: a name beside those taken, as Finder keeps both: `a 2.txt`, `a 3.txt`; a folder `b 2`.
pub fn free(name : String, dir : Bool, taken : (String) -> Bool) -> String {
  let (stem, ext) = match (if dir { None } else { name.rev_find(".") }) {
    Some(dot) if dot > 0 =>
      (
        name.unsafe_substring(start=0, end=dot),
        name.unsafe_substring(start=dot, end=name.length()),
      )
    _ => (name, "")
  }
  let mut n = 2
  while true {
    let next = "\{stem} \{n}\{ext}"
    if !taken(next) {
      return next
    }
    n += 1
  }
  ""
}

///|
/// transfers.ts `shown`: a transfer as the pages are told it, without its list of what it copies.
pub fn shown(t : JV) -> JV {
  guard t is Obj(fields) else { return t }
  let out : Array[(String, JV)] = []
  for f in fields {
    if f.0 != ju("items") && f.0 != ju("placed") {
      out.push(f)
    }
  }
  let items = oarr(t, "items")
  let files = items.filter(i => !(oget(i, "dir") is Some(Bool(true)))).length()
  out.push((ju("count"), Num(items.length().to_double())))
  out.push((ju("files"), Num(files.to_double())))
  let done = onum(t, "done").to_int()
  if ostr(t, "state") == Some("copying") && done >= 0 && done < items.length() {
    match oget(items[done], "path") {
      Some(p) => out.push((ju("current"), p))
      None => out.push((ju("current"), Null))
    }
  }
  Obj(out)
}

///|
fn item(path : String, dir : Bool, size : Double) -> JV {
  Obj([(ju("path"), jvs(path)), (ju("dir"), Bool(dir)), (ju("size"), Num(size))])
}

///|
/// walkDrive's `one`: a folder added and gone into, a file added.
fn walk_one(
  drive : Drive,
  root : String,
  path : String,
  anywhere : Bool,
  items : Array[JV],
  rel : String,
  e : Entry,
) -> Unit raise DriveError {
  let add = (i : JV) => {
    if items.length() >= most_items {
      raise drive_error("too_large", "more than \{most_items} files and folders")
    }
    items.push(i)
  }
  if !e.dir {
    add(item(rel, false, e.size))
    return
  }
  add(item(rel, true, 0.0))
  let (_, entries, truncated) = drive.list(root, join2(path, rel), anywhere)
  if truncated {
    raise drive_error(
      "too_large",
      "\{rel}: too many entries to list; select fewer files or smaller folders",
    )
  }
  for x in entries {
    walk_one(drive, root, path, anywhere, items, join2(rel, x.name), x)
  }
}

///|
/// transfers.ts `walkDrive`: the folders and files under `names` of `path`, folders before what is in them, at most
/// MOST_ITEMS.
pub fn walk_drive(
  drive : Drive,
  root : String,
  path : String,
  names : Array[String],
  anywhere : Bool,
) -> Array[JV] raise DriveError {
  let items : Array[JV] = []
  for name in names {
    if name == "" || name.contains("/") || name == "." || name == ".." {
      raise drive_error("invalid_request", "a name, not a path")
    }
    let e = drive.stat(root, join2(path, name), anywhere)
    walk_one(drive, root, path, anywhere, items, name, { ..e, name, })
  }
  items
}

///|
/// Where the files come from (transfers.ts `Source`): walked, read a part at a time, let go of (a move).
pub(all) struct Source {
  station : String?
  part : Double
  walk : async (Array[String]) -> Array[JV]
  /// (bytes, size, mtime)
  read : async (String, Double, Double) -> (Bytes, Double, Double)
  release : async (Array[String]) -> Unit
}

///|
/// transfers.ts `localSource`: this station's own drive as a source, as the asker reaches it.
pub fn local_source(
  drive : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> Source {
  {
    station: None,
    part: max_read,
    walk: async fn(names) { walk_drive(drive, root, path, names, anywhere) },
    read: async fn(rel, offset, length) {
      let got = drive.read(root, join2(path, rel), offset, length, anywhere)
      (got.bytes, got.total, got.mtime)
    },
    release: async fn(names) {
      for name in names {
        remove_or_trash(drive, root, join2(path, name), anywhere)
      }
    },
  }
}

///|
/// transfers.ts `removeOrTrash`: to the machine's trash; where none takes it, removed.
pub fn remove_or_trash(
  drive : Drive,
  root : String,
  path : String,
  anywhere : Bool,
) -> Unit raise DriveError {
  drive.remove(root, path, anywhere, false) catch {
    DriveError({ code: "no_trash", .. }) => drive.remove(root, path, anywhere, true)
    e => raise e
  }
}

///|
/// transfers.ts `TransfersDeps`.
pub(all) struct TransfersDeps {
  dir : String
  drive_for : (JV) -> Drive
  remote : (JV) -> Source
  now : () -> Double
  changed : (JV) -> Unit
  /// Where a transfer runs (the program's runtime).
  rt : @effect.Runtime
}

///|
/// transfers.ts `Transfers`: the transfers into this station, run one at a time in the order asked.
pub struct Transfers {
  priv deps : TransfersDeps
  priv all : Map[String, JV]
  priv mut running : String?
  priv stop : Map[String, Bool]
  priv waiting : Array[@effect.Deferred[Unit]]
  priv mut last_save : Double
  priv mut closed : Bool
}

///|
fn ended(t : JV) -> Bool {
  let s = ostr(t, "state")
  s == Some("done") || s == Some("cancelled")
}

///|
pub fn Transfers::new(deps : TransfersDeps) -> Transfers {
  let self : Transfers = {
    deps,
    all: {},
    running: None,
    stop: {},
    waiting: [],
    last_save: 0.0,
    closed: false,
  }
  mkdir(deps.dir, true, mode=0o700) catch {
    _ => ()
  }
  let listed = match attempt(() => names(deps.dir)) {
    Ok(n) => n
    Err(_) => []
  }
  for name in listed {
    if !name.has_suffix(".json") {
      continue
    }
    let t = try @jsjson.parse(@utf8.decode_lossy(read_all(join([deps.dir, name])))) catch {
      _ => continue
    }
    guard ostr(t, "id") is Some(id) else { continue }
    match oget(t, "endedAt") {
      Some(Num(at)) if (deps.now)() - at > kept_ms => {
        rm_force(join([deps.dir, name]))
        continue
      }
      _ => ()
    }
    self.all.set(id, t)
  }
  if self.all.values().any(t => !ended(t)) {
    self.kick()
  }
  self
}

///|
/// The asker's transfers, newest first.
pub fn Transfers::list(self : Transfers, by : String) -> Array[JV] {
  let mine = self.all.values().filter(t => ostr(t, "by") == Some(by)).collect()
  stable_sort(mine, (a, b) => {
    let d = onum(b, "createdAt") - onum(a, "createdAt")
    if d < 0.0 {
      -1
    } else if d > 0.0 {
      1
    } else {
      0
    }
  })
}

///|
pub fn Transfers::get(self : Transfers, id : String) -> JV? {
  self.all.get(id)
}

///|
/// transfers.ts `start`: a transfer asked, kept, and run once those before it are.
pub fn Transfers::start(self : Transfers, spec : JV) -> JV raise DriveError {
  let from = oget(spec, "from").unwrap_or(Null)
  if oarr(from, "names").is_empty() {
    raise drive_error("invalid_request", "nothing to copy")
  }
  let fields = match spec {
    Obj(f) => f.copy()
    _ => []
  }
  let t : JV = Obj(fields)
  let id = random_uuid().replace_all(old="-", new="")
  oset(t, "id", jvs(id))
  oset(t, "state", jvs("queued"))
  oset(t, "items", Arr([]))
  oset(t, "done", Num(0.0))
  oset(t, "at", Num(0.0))
  oset(t, "total", Num(0.0))
  oset(t, "copied", Num(0.0))
  oset(t, "placed", Obj([]))
  oset(t, "createdAt", Num((self.deps.now)()))
  self.save(t, true)
  self.kick()
  t
}

///|
/// Stopped (what is in place stays; the file under way is let go with its upload).
pub fn Transfers::cancel(self : Transfers, by : String, id : String) -> JV raise DriveError {
  let t = self.mine(by, id)
  if ended(t) {
    return t
  }
  if self.running == Some(id) {
    self.stop.set(id, true)
  }
  self.end(t, "cancelled", None)
  t
}

///|
/// One that failed taken up again where it was.
pub fn Transfers::retry(self : Transfers, by : String, id : String) -> JV raise DriveError {
  let t = self.mine(by, id)
  if ostr(t, "state") != Some("failed") {
    return t
  }
  oset(t, "state", jvs(if oarr(t, "items").length() > 0 { "copying" } else { "queued" }))
  odel(t, "error")
  odel(t, "endedAt")
  self.save(t, true)
  self.kick()
  t
}

///|
/// Settled when none is left to run.
pub async fn Transfers::idle(self : Transfers) -> Unit {
  if self.running is Some(_) {
    let d = @effect.Deferred::new()
    self.waiting.push(d)
    d.wait()
  }
}

///|
/// Nothing more run.
pub fn Transfers::close(self : Transfers) -> Unit {
  self.closed = true
  for d in self.waiting {
    d.succeed(()) |> ignore
  }
  self.waiting.clear()
}

///|
fn Transfers::mine(self : Transfers, by : String, id : String) -> JV raise DriveError {
  match self.all.get(id) {
    Some(t) if ostr(t, "by") == Some(by) => t
    _ => raise drive_error("not_found", "no such transfer")
  }
}

///|
fn Transfers::save(self : Transfers, t : JV, tell : Bool) -> Unit {
  let id = ostr(t, "id").unwrap_or("")
  self.all.set(id, t)
  write_private(join([self.deps.dir, "\{id}.json"]), @jsjson.stringify(t)) catch {
    _ => ()
  }
  self.last_save = (self.deps.now)()
  if tell {
    (self.deps.changed)(t)
  }
}

///|
fn Transfers::end(self : Transfers, t : JV, state : String, error : String?) -> Unit {
  oset(t, "state", jvs(state))
  if error is Some(e) {
    oset(t, "error", jvs(e))
  }
  oset(t, "endedAt", Num((self.deps.now)()))
  self.save(t, true)
}

///|
/// The next one run, unless one runs.
fn Transfers::kick(self : Transfers) -> Unit {
  if self.running is Some(_) || self.closed {
    return
  }
  let waiting = self.all
    .values()
    .filter(t => !ended(t) && ostr(t, "state") != Some("failed"))
    .collect()
  let next = stable_sort(waiting, (a, b) => {
    let d = onum(a, "createdAt") - onum(b, "createdAt")
    if d < 0.0 {
      -1
    } else if d > 0.0 {
      1
    } else {
      0
    }
  })
  if next.is_empty() {
    for d in self.waiting {
      d.succeed(()) |> ignore
    }
    self.waiting.clear()
    return
  }
  let t = next[0]
  let id = ostr(t, "id").unwrap_or("")
  self.running = Some(id)
  self.deps.rt.fork(async fn() {
    self.run(t)
    self.running = None
    self.stop.remove(id)
    self.kick()
  })
  |> ignore
}

///|
/// What an error says (an Error's message).
pub fn message_of(e : Error) -> String {
  match e {
    DriveError(d) => d.message
    FsError(f) => f.message
    Refused(m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
async fn Transfers::run(self : Transfers, t : JV) -> Unit noraise {
  let drive = (self.deps.drive_for)(t)
  let from = oget(t, "from").unwrap_or(Null)
  let to = oget(t, "to").unwrap_or(Null)
  let anywhere = oget(t, "anywhere") is Some(Bool(true))
  let id = ostr(t, "id").unwrap_or("")
  let source = match oget(from, "station") {
    Some(Str(_)) => (self.deps.remote)(t)
    _ =>
      local_source(
        drive,
        ostr(from, "root").unwrap_or(""),
        ostr(from, "path").unwrap_or(""),
        anywhere,
      )
  }
  let stopped = () => self.stop.contains(id) || self.closed
  ignore(to)
  try {
    self.separate(t, drive)
    if stopped() {
      return
    }
    if oarr(t, "items").is_empty() {
      oset(t, "state", jvs("walking"))
      self.save(t, true)
      let conflicts = oget(t, "conflicts").unwrap_or(Null)
      let names = ostrs(from, "names").filter(n => ostr(conflicts, n) != Some("skip"))
      let items = (source.walk)(names)
      if stopped() {
        return
      }
      self.place(t, drive, items, stopped)
      if stopped() {
        return
      }
      oset(t, "items", Arr(items))
      let mut total = 0.0
      for i in items {
        total = total + onum(i, "size")
      }
      oset(t, "total", Num(total))
      oset(t, "state", jvs("copying"))
      self.save(t, true)
    }
    while onum(t, "done").to_int() < oarr(t, "items").length() {
      if stopped() {
        return
      }
      self.copy(t, drive, source, oarr(t, "items")[onum(t, "done").to_int()], stopped)
      if stopped() {
        return
      }
      oset(t, "done", Num(onum(t, "done") + 1.0))
      oset(t, "at", Num(0.0))
      self.save(t, true)
    }
    if oget(t, "move") is Some(Bool(true)) {
      let placed = match oget(t, "placed") {
        Some(Obj(f)) => f.map(p => @jsjson.sanitize_str(p.0))
        _ => []
      }
      (source.release)(placed)
    }
    self.end(t, "done", None)
  } catch {
    e => {
      if stopped() {
        return
      }
      self.end(t, "failed", Some(message_of(e)))
    }
  }
}

///|
/// transfers.ts `#separate`: a local copy must not replace what it still reads; a move must not put its result inside
/// what it later removes. Every selected source checked before any destination is changed, by their real paths.
fn Transfers::separate(self : Transfers, t : JV, drive : Drive) -> Unit raise DriveError {
  ignore(self)
  let from = oget(t, "from").unwrap_or(Null)
  if oget(from, "station") is Some(Str(_)) {
    return
  }
  let to = oget(t, "to").unwrap_or(Null)
  let anywhere = oget(t, "anywhere") is Some(Bool(true))
  let conflicts = oget(t, "conflicts").unwrap_or(Null)
  let placed = oget(t, "placed").unwrap_or(Null)
  let (into_found, _) = drive.locate(
    ostr(to, "root").unwrap_or(""),
    ostr(to, "path").unwrap_or(""),
    anywhere,
  )
  let names = ostrs(from, "names").filter(n => ostr(conflicts, n) != Some("skip"))
  let sources = names.map(name => drive.locate(
    ostr(from, "root").unwrap_or(""),
    join2(ostr(from, "path").unwrap_or(""), name),
    anywhere,
  ))
  if sources.iter().any(s => within(into_found, s.0)) {
    raise drive_error(
      "invalid_request", "choose a different destination folder: a folder cannot go into itself",
    )
  }
  for name in names {
    if ostr(conflicts, name) == Some("keep") && ostr(placed, name) is None {
      continue
    }
    let (_, to_entry) = drive.locate(
      ostr(to, "root").unwrap_or(""),
      join2(ostr(to, "path").unwrap_or(""), ostr(placed, name).unwrap_or(name)),
      anywhere,
    )
    if sources.iter().any(s => within(s.1, to_entry) || within(s.0, to_entry)) {
      raise drive_error(
        "invalid_request", "choose a different destination or keep both: replacing it would remove a source",
      )
    }
  }
}

///|
/// transfers.ts `#place`: where each name goes: its own name, one kept beside, or the one there let go first.
fn Transfers::place(
  self : Transfers,
  t : JV,
  drive : Drive,
  items : Array[JV],
  stopped : () -> Bool,
) -> Unit raise DriveError {
  ignore(self)
  let to = oget(t, "to").unwrap_or(Null)
  let from = oget(t, "from").unwrap_or(Null)
  let anywhere = oget(t, "anywhere") is Some(Bool(true))
  let conflicts = oget(t, "conflicts").unwrap_or(Null)
  let placed = match oget(t, "placed") {
    Some(Obj(_) as p) => p
    _ => {
      let p : JV = Obj([])
      oset(t, "placed", p)
      p
    }
  }
  let to_root = ostr(to, "root").unwrap_or("")
  let to_path = ostr(to, "path").unwrap_or("")
  let (_, listed, _) = drive.list(to_root, to_path, anywhere)
  let there : Map[String, Bool] = {}
  for e in listed {
    there.set(path_key(e.name), true)
  }
  for name in ostrs(from, "names") {
    if stopped() {
      return
    }
    let answer = ostr(conflicts, name)
    if answer == Some("skip") {
      continue
    }
    let dir = match items.search_by(i => ostr(i, "path") == Some(name)) {
      Some(i) => oget(items[i], "dir") is Some(Bool(true))
      None => false
    }
    if there.contains(path_key(name)) && answer == Some("keep") {
      let kept = free(name, dir, n => there.contains(path_key(n)))
      oset(placed, name, jvs(kept))
      there.set(path_key(kept), true)
      continue
    }
    if there.contains(path_key(name)) && answer == Some("replace") {
      remove_or_trash(drive, to_root, join2(to_path, name), anywhere)
    } else if there.contains(path_key(name)) {
      raise drive_error("exists", "\{name}: there is already one by that name")
    }
    oset(placed, name, jvs(name))
  }
}

///|
/// transfers.ts `#copy`: one folder made, or one file put together beside where it goes and put there whole.
async fn Transfers::copy(
  self : Transfers,
  t : JV,
  drive : Drive,
  source : Source,
  it : JV,
  stopped : () -> Bool,
) -> Unit {
  let to = oget(t, "to").unwrap_or(Null)
  let to_root = ostr(to, "root").unwrap_or("")
  let anywhere = oget(t, "anywhere") is Some(Bool(true))
  let path = ostr(it, "path").unwrap_or("")
  let name = top_name(path)
  let placed = ostr(oget(t, "placed").unwrap_or(Null), name).unwrap_or(name)
  let dest = join2(
    ostr(to, "path").unwrap_or(""),
    placed + path.unsafe_substring(start=name.length(), end=path.length()),
  )
  if oget(it, "dir") is Some(Bool(true)) {
    drive.mkdir(to_root, dest, anywhere) |> ignore catch {
      DriveError({ code: "exists", .. }) => ()
      e => raise e
    }
    return
  }
  let tid = ostr(t, "id").unwrap_or("")
  let upload_id = "\{if tid.length() > 32 { tid.unsafe_substring(start=0, end=32) } else { tid }}-\{js_number(onum(t, "done"))}"
  let mut mtime : Double? = None
  while true {
    let (bytes, size, got_mtime) = (source.read)(path, onum(t, "at"), source.part)
    if mtime is Some(m) && got_mtime != m {
      oset(t, "copied", Num(onum(t, "copied") - onum(t, "at")))
      oset(t, "at", Num(0.0))
      mtime = None
      continue
    }
    mtime = Some(got_mtime)
    if size != onum(it, "size") {
      oset(t, "total", Num(onum(t, "total") + size - onum(it, "size")))
      oset(it, "size", Num(size))
    }
    let put = try
      Ok(
        drive.upload(
          to_root,
          dest,
          upload_id,
          onum(t, "at"),
          size,
          bytes,
          false,
          anywhere,
        ),
      )
    catch {
      DriveError({ code: "upload_lost", have: Some(h), .. }) => Err(h)
      e => raise e
    }
    match put {
      Err(have) => {
        oset(t, "copied", Num(onum(t, "copied") - (onum(t, "at") - have)))
        oset(t, "at", Num(have))
        continue
      }
      Ok((have, entry)) => {
        oset(t, "copied", Num(onum(t, "copied") + have - onum(t, "at")))
        oset(t, "at", Num(have))
        if entry is Some(_) || onum(t, "at") >= size {
          return
        }
        if stopped() {
          return
        }
        if (self.deps.now)() - self.last_save >= save_every_ms {
          self.save(t, true)
        }
      }
    }
  }
}

///|
/// A number as JavaScript writes it in a template (an integer without its `.0`).
pub fn js_number(n : Double) -> String {
  if n == n.floor() && n.abs() < 1.0e21 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}
