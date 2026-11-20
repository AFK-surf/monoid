// What the pages ask of the hub, the jobs and the files (routes/hub.ts): new chats and sessions, uploads (whole and in
// parts), messages, adding a session to a chat, relaying a chat, archiving, deleting, stopping, evicting, warming, a
// session's settings, clearing a chat's ended jobs, stopping a job. The hub's work is the station's parts' (the
// lifecycle's, the relay's, the jobs'): here what is asked is checked and answered as the station answers it.

///|
const MAX_UPLOAD : Int32 = 52428800

///|
const MAX_PARTS_UPLOAD : Double = 1073741824.0

///|
const MAX_UPLOAD_PART : Int32 = 16777216

///|
const DISK_SPARE : Double = 1073741824.0

///|
const PART_PREFIX : String = ".part-"

///|
const STAGED_FOR_MS : Double = 86400000.0

///|
const CONTENTS_KEEP : Int32 = 1000

///|
const NAMING_KEEP : Int32 = 100

///|
const ASSEMBLED_KEEP_MS : Double = 3600000.0

///|
const STILLFAIL_SURFACE : String = "chat"

///|
/// The hub's call.
async fn Admin::hub(self : Admin, call : String, args : Array[JV]) -> JV {
  self.backend.ask("hub." + call, args)
}

///|
/// A call the route does not wait for (`void p`, `p.catch(...)`): its failure told `failed`.
pub async fn Admin::later(self : Admin, f : async () -> Unit) -> Unit {
  self.state.background.push(
    @effect.runtime().fork(name="route later", async fn() {
      f() catch {
        _ => ()
      }
    }),
  )
  // (it asks what it asks first, as a promise made then: the route goes on after)
  @effect.pause()
}

///|
/// Every call not waited for, once done (a test's).
pub async fn Admin::drained(self : Admin) -> Unit {
  while self.state.background.length() > 0 {
    let f = self.state.background.remove(0)
    ignore(f.wait())
  }
}

///|
/// `wall.now()`.
async fn Admin::wall_now(self : Admin) -> Double {
  jnumber(Some(self.backend.ask("ops/fibers.wall.now", []))).unwrap_or(0.0)
}

///|
async fn Admin::log(
  self : Admin,
  level : String,
  part : String,
  said : String,
  fields : JV,
) -> Unit {
  self.backend.tell("ops/log.log." + level, [js(part), js(said), fields])
}

///|
/// A hub error the Rust maps to a status: a Refused as it is, anything else that status with its message.
async fn[X] as_status(status : Int32, f : async () -> X) -> X {
  f() catch {
    e =>
      match refused_of(e) {
        Some(_) => raise e
        None => raise Refused(status, message_of(e))
      }
  }
}

///|
/// files.rs `sweep_staged`: drops uploads that waited a day without a message taking them.
async fn Admin::sweep_staged(self : Admin, dir : String) -> Unit {
  let now = self.wall_now()
  let names = jitems(Some(self.fs("readdir", [js(dir)]))).filter_map(n => {
    jstr(Some(n))
  }) catch {
    _ => return
  }
  for name in names {
    let st = self.stat_or_none(join([dir, name]))
    match st {
      Some(st) if st.file && now - st.mtime_ms > STAGED_FOR_MS =>
        ignore(
          self.fs("rm", [js(join([dir, name])), jobj([("force", jbool(true))])]),
        )
      _ => ()
    }
  }
}

///|
/// `new Date(ms).toISOString().slice(0, 19)`.
pub fn iso_seconds(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64()).view(end_offset=19).to_string()
}

///|
fn hex_of(b : Bytes) -> String {
  @codec.hex_encode(b)
}

///|
/// Where an upload named `name` is kept in `dir`: its name made safe, and a path of its own.
pub async fn Admin::upload_path(
  self : Admin,
  dir : String,
  name : String,
) -> (String, String) {
  let base = name
    .replace_all(old="\\", new="/")
    .split("/")
    .last()
    .map(s => s.to_string())
    .unwrap_or("")
  let cleaned = points(base)
    .map(c => if c.unsafe_charcode_at(0) < 0x20 { "_" } else { c })
    .join("")
  let mut start = 0
  while start < cleaned.length() && cleaned.unsafe_charcode_at(start) == '.' {
    start += 1
  }
  let safe0 = chars(cleaned.unsafe_substring(start~, end=cleaned.length()), 120)
  let safe = if safe0 == "" { "file" } else { safe0 }
  self.mkdirs(dir)
  let stamp = iso_seconds(self.wall_now())
    .replace_all(old=":", new="-")
    .replace_all(old=".", new="-")
  let random = hex_of(
    bytes_of(self.backend.ask("crypto.randomBytes", [jint(3)])).unwrap_or(b""),
  )
  (safe, join([dir, "\{stamp}-\{random}-\{safe}"]))
}

///|
fn attachment(name : String, path : String, size : Double) -> JV {
  jobj([("name", js(name)), ("path", js(path)), ("size", jnum(size))])
}

///|
/// files.rs `save_upload`: a request's body kept in `dir` under its name, made safe and unique.
async fn Admin::save_upload(
  self : Admin,
  body : Bytes,
  dir : String,
  name : String,
  lang : String,
) -> JV {
  let (safe, path) = self.upload_path(dir, name)
  if body.length() > MAX_UPLOAD {
    raise Refused(413, self.tr(lang, "station.files.tooLarge"))
  }
  ignore(
    self.fs("writeFile", [js(path), jbytes(body), jobj([("flag", js("wx"))])]),
  )
  self.known(dir, @hash.sha256_hex(body[:]), path)
  attachment(safe, path, body.length().to_double())
}

///|
/// `path`, a whole upload in the uploads folder `dir`, is `sha256`.
async fn Admin::known(
  self : Admin,
  dir : String,
  sha256 : String,
  path : String,
) -> Unit {
  guard self.stat_or_none(path) is Some(st) else { return }
  let key = clean(dir)
  let held = match self.state.contents.get(key) {
    Some(h) => h
    None => {
      let h = {}
      self.state.contents[key] = h
      h
    }
  }
  held.remove(sha256)
  held[sha256] = { path, size: st.size, mtime_ms: st.mtime_ms, }
  while held.length() > CONTENTS_KEEP {
    let oldest = held.keys().next().unwrap()
    held.remove(oldest)
  }
}

///|
/// An upload of `dir` moved (into a chat's uploads, as a message takes it): known there now.
fn Admin::moved_upload(
  self : Admin,
  dir : String,
  from : String,
  to : String,
) -> Unit {
  match self.state.contents.get(clean(dir)) {
    Some(held) =>
      for _, e in held {
        if e.path == from {
          e.path = to
        }
      }
    None => ()
  }
}

///|
/// Where `dir`'s uploads keep a file of `size` bytes that is `sha256`, unchanged since: None when none is.
async fn Admin::kept_upload(
  self : Admin,
  dir : String,
  sha256 : String,
  size : Double,
) -> String? {
  guard self.state.contents.get(clean(dir)) is Some(held) else { return None }
  guard held.get(sha256) is Some(e) else { return None }
  let st = self.stat_or_none(e.path)
  match st {
    Some(st) if st.file &&
      st.size == size &&
      e.size == size &&
      st.mtime_ms == e.mtime_ms => Some(e.path)
    _ => {
      held.remove(sha256)
      None
    }
  }
}

///|
/// POST /uploads/parts: a part of a file at `offset`, added to what came of it before. One upload's parts in turn.
async fn Admin::save_part(
  self : Admin,
  body : Bytes,
  dir : String,
  id : String,
  name : String,
  size : Double,
  offset : Double,
  sha256 : String?,
  lang : String,
) -> JV {
  let before = self.state.part_turns.get(id)
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.state.part_turns[id] = mine
  match before {
    Some(b) => b.wait()
    None => ()
  }
  let out = self.save_part_now(body, dir, id, name, size, offset, sha256, lang) catch {
    e => {
      ignore(mine.succeed(()))
      if self.state.part_turns.get(id) is Some(m) && physical_equal(m, mine) {
        self.state.part_turns.remove(id)
      }
      raise e
    }
  }
  ignore(mine.succeed(()))
  if self.state.part_turns.get(id) is Some(m) && physical_equal(m, mine) {
    self.state.part_turns.remove(id)
  }
  out
}

///|
async fn Admin::save_part_now(
  self : Admin,
  body : Bytes,
  dir : String,
  id : String,
  name : String,
  size : Double,
  offset : Double,
  sha256 : String?,
  lang : String,
) -> JV {
  let now = self.wall_now()
  let gone = []
  for k, v in self.state.assembled {
    if now - v.0 > ASSEMBLED_KEEP_MS {
      gone.push(k)
    }
  }
  for k in gone {
    self.state.assembled.remove(k)
  }
  if !re("^[A-Za-z0-9_-]{8,64}$").matches(id) {
    raise Refused(400, "invalid upload id")
  }
  if !is_safe_integer(size) ||
    size < 0.0 ||
    !is_safe_integer(offset) ||
    offset < 0.0 ||
    offset > size {
    raise Refused(400, "invalid upload size or offset")
  }
  if size > MAX_PARTS_UPLOAD {
    raise Refused(413, self.tr(lang, "station.files.tooLargeParts"))
  }
  let length = body.length().to_double()
  if body.length() > MAX_UPLOAD_PART || offset + length > size {
    raise Refused(413, "upload part too large")
  }
  match sha256 {
    Some(s) if !re("^[0-9a-f]{64}$").matches(s) =>
      raise Refused(400, "invalid sha256")
    _ => ()
  }
  match self.state.assembled.get(id) {
    Some((_, file)) => return jobj([("have", jnum(size)), ("file", file)])
    None => ()
  }
  self.mkdirs(dir)
  let part = join([dir, "\{PART_PREFIX}\{id}"])
  let have = match self.stat_or_none(part) {
    Some(st) => st.size
    None => 0.0
  }
  match sha256 {
    Some(s) if offset == 0.0 && body.length() == 0 && have == 0.0 =>
      match self.kept_upload(dir, s, size) {
        Some(from) => {
          let (safe, path) = self.upload_path(dir, name)
          // A copy of its own (a clone where the disk makes one): the chat it goes to may change it, the other not.
          ignore(self.fs("copyFile", [js(from), js(path), jint(2)]))
          self.known(dir, s, path)
          let file = attachment(safe, path, size)
          self.state.assembled[id] = (now, file)
          return jobj([("have", jnum(size)), ("file", file)])
        }
        None => ()
      }
    _ => ()
  }
  if have > size {
    ignore(self.fs("rm", [js(part), jobj([("force", jbool(true))])]))
    raise Refused(400, "invalid upload size")
  }
  if have == 0.0 && offset == 0.0 {
    // A new file: refused at once when the disk cannot take it.
    let room = Some(self.fs("statfs", [js(dir)])) catch { _ => None }
    match room {
      Some(fs) => {
        let free = jnumber(fs.get("bavail")).unwrap_or(0.0) *
          jnumber(fs.get("bsize")).unwrap_or(0.0)
        if free < size + DISK_SPARE {
          raise Refused(507, self.tr(lang, "station.files.noRoom"))
        }
      }
      None => ()
    }
  }
  // Only what follows the file's end is added: none of a part asked again, the rest of one that overlaps it.
  if offset <= have && offset + length > have {
    let added = body[(have - offset).to_int():].to_bytes()
    if have == 0.0 {
      self.state.naming.remove(id)
      self.state.naming[id] = @hash.Sha256::new()
      while self.state.naming.length() > NAMING_KEEP {
        let oldest = self.state.naming.keys().next().unwrap()
        self.state.naming.remove(oldest)
      }
    }
    ignore(self.fs("appendFile", [js(part), jbytes(added)]))
    match self.state.naming.get(id) {
      Some(h) => h.update(added[:])
      None => ()
    }
  }
  let got = match self.stat_or_none(part) {
    Some(st) => st.size
    None => 0.0
  }
  if got < size {
    return jobj([("have", jnum(got))])
  }
  let (safe, path) = self.upload_path(dir, name)
  ignore(self.fs("rename", [js(part), js(path)]))
  let named = self.state.naming.get(id)
  self.state.naming.remove(id)
  match named {
    Some(h) => self.known(dir, h.hex(), path)
    None => ()
  }
  let file = attachment(safe, path, size)
  self.state.assembled[id] = (now, file)
  jobj([("have", jnum(size)), ("file", file)])
}

///|
fn field_text(o : JV, k : String, fallback : String, max : Int32) -> String {
  match o.get(k) {
    None | Some(Null) => fallback
    Some(Str(s)) => chars(s, max)
    Some(v) => chars(stringify(v), max)
  }
}

///|
/// files.rs `quotes_of`: quotes as the page sends them, bounded.
pub fn quotes_of(given : JV?) -> Array[JV] {
  guard given is Some(Arr(items)) else { return [] }
  let out = []
  for q in items[0:@cmp.minimum(20, items.length())] {
    let o = match q {
      Obj(_) => q
      _ => Obj([])
    }
    let mut quote = jobj([
      ("author", js(field_text(o, "author", "消息", 100))),
      ("text", js(field_text(o, "text", "", 4000))),
      ("comment", js(field_text(o, "comment", "", 4000))),
    ])
    match jstr(o.get("ts")) {
      Some(ts) if re("^[0-9]+\\.[0-9]+$").matches(ts) =>
        quote = jset(quote, "ts", js(ts))
      _ => ()
    }
    match jstr(o.get("role")) {
      Some(role) if ["agent", "person", "page", "image"].contains(role) =>
        quote = jset(quote, "role", js(role))
      _ => ()
    }
    match jstr(o.get("file")) {
      Some(f) if f != "" => quote = jset(quote, "file", js(chars(f, 200)))
      _ => ()
    }
    if trim_js(jstr(quote.get("text")).unwrap_or("")) != "" {
      out.push(quote)
    }
  }
  out
}

///|
/// A whole dimension (no fraction, 0 < v < 100000).
fn dimension(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if is_integer(n) && n > 0.0 && n < 100000.0 => Some(n)
    _ => None
  }
}

///|
/// Thrown where one of `keys` was handed to another station.
async fn Admin::moved_of(
  self : Admin,
  keys : Array[String],
  lang : String,
) -> Unit {
  for key in keys {
    let h = self.store("handedTo", [js(key)])
    if h is Null {
      continue
    }
    let ws = self.store("sessionWs", [js(key)])
    let handed = match jstr(Some(ws)) {
      Some(w) => w.has_prefix(handed_ws(""))
      None => false
    }
    if !handed {
      continue
    }
    raise Moved(
      self.tr(lang, "station.move.movedThere"),
      jobj([
        ("session", js(key)),
        ("station", h.get("station").unwrap_or(jundef)),
        ("thread", h.get("thread").unwrap_or(jundef)),
        ("there", h.get("there").unwrap_or(jundef)),
      ]),
    )
  }
}

///|
fn moved_json(message : String, moved : JV) -> Answer {
  json(409, stringify(jobj([("error", js(message)), ("moved", moved)])))
}

///|
async fn Admin::thread_keys(self : Admin, thread : Double) -> Array[String] {
  jitems(Some(self.store("threadSessions", [jnum(thread)]))).map(m => {
    jstr(jget(Some(m), "session")).unwrap_or("")
  })
}

///|
/// What a person's message to thread `thread` is answered where a chat in it was handed to another station (409,
/// with `moved`), as POST /threads/:id/messages answers it.
pub async fn Admin::moved_answer(
  self : Admin,
  thread : Double,
  lang : String,
) -> Answer? {
  let keys = self.thread_keys(thread)
  self.moved_of(keys, lang) catch {
    Moved(message, moved) => return Some(moved_json(message, moved))
    e => raise e
  }
  None
}

///|
/// Answered with the hub, its refusals as `{error}`; 503 while there is none (a station starting).
async fn Admin::hub_write(self : Admin, f : async () -> Answer) -> Answer {
  if !self.setup.has("store") || !self.setup.has("agents") {
    return error(503, "station starting")
  }
  f() catch {
    e =>
      match moved_of(e) {
        Some((message, moved)) => moved_json(message, moved)
        None =>
          match refused_of(e) {
            Some((status, message)) => error(status, message)
            None => error(500, message_of(e))
          }
      }
  }
}

///|
/// Refused while this station hands the asker's workspace's chats to another.
async fn Admin::retiring(self : Admin, r : Request) -> Unit {
  let ws = r.who("workspace").unwrap_or(jundef)
  if !(ws is Null) && self.hub("quietIn", [ws]) is Bool(true) {
    raise Refused(503, self.tr(r.lang, "station.retire.moving"))
  }
}

///|
/// A session there, and in the asker's workspace; one handed to another station is said where it went.
async fn Admin::session_there(self : Admin, key : String, r : Request) -> Unit {
  self.moved_of([key], r.lang)
  if self.store("getSession", [js(key)]) is Null ||
    !self.session_seen(r.viewer, key) {
    raise Refused(404, "unknown session \{key}")
  }
}

///|
async fn Admin::thread_there(self : Admin, id : String) -> JV {
  let found = match thread_number(id) {
    Some(n) => self.store("getThread", [jnum(n)])
    None => Null
  }
  if found is Null {
    raise Refused(404, "unknown thread \{id}")
  }
  found
}

///|
async fn Admin::thread_view(self : Admin, r : Request, id : JV) -> Answer {
  self.read(
    r,
    "thread",
    jobj([
      ("id", js(js_string(Some(id)))),
      ("viewer", r.viewer),
      ("lang", js(r.lang)),
    ]),
  )
}

///|
/// `{key, thread}`: a session made with its chat, the chat as GET /threads/:id has it.
async fn Admin::made(
  self : Admin,
  r : Request,
  key : String,
  id : JV,
) -> Answer {
  let view = self.thread_view(r, id)
  if view.status != 200 {
    return view
  }
  json(200, "{\"key\":\{stringify(js(key))},\"thread\":\{view.text()}}")
}

///|
async fn Admin::runtime_of(self : Admin, r : Request, i : JV) -> JV {
  let named = self.backend.ask("agents/runtime.runtimeKind", [
    js(text_of(i.get("runtime"))),
  ])
  if is_undef(named) {
    raise Refused(400, self.tr(r.lang, "station.admin.badRuntime"))
  }
  named
}

///|
/// Where uploaded files wait for the message that sends them.
async fn Admin::staged(self : Admin) -> String {
  join([jstr(self.hub("config", []).get("dataDir")).unwrap_or(""), "uploads"])
}

///|
fn str_field(o : JV, k : String) -> String? {
  jstr(o.get(k))
}

///|
/// files.rs `attachments`: files named in a message, waiting in the uploads or already in a session's upload directory.
async fn Admin::attachments(
  self : Admin,
  r : Request,
  id : Double,
  given : JV?,
) -> Array[JV] {
  let dirs = []
  for key in self.thread_keys(id) {
    let row = self.store("getSession", [js(key)])
    if row is Null {
      continue
    }
    dirs.push(
      (
        jstr(row.get("key")).unwrap_or(""),
        clean(join([jstr(row.get("workspace")).unwrap_or(""), "uploads"])),
      ),
    )
  }
  let staged_dir = clean(self.staged())
  let out = []
  let items = match given {
    Some(Arr(a)) => a[0:@cmp.minimum(20, a.length())].to_array()
    _ => []
  }
  for item in items {
    let o = match item {
      Obj(_) => item
      _ => Obj([])
    }
    let mut path = clean(str_field(o, "path").unwrap_or(""))
    let base = file_name(path).unwrap_or("")
    if inside(path, staged_dir) && base.has_prefix(PART_PREFIX) {
      raise Refused(400, self.tr(r.lang, "station.files.notUploaded"))
    }
    if inside(path, staged_dir) && dirs.length() > 0 {
      let first = dirs[0].1
      let into = join([first, base])
      // Sent again (a retry after the first try got here): it has moved already.
      if self.exists(path) {
        self.mkdirs(first)
        ignore(self.fs("rename", [js(path), js(into)]))
        self.moved_upload(staged_dir, path, into)
      }
      path = into
    }
    let owner = dirs.iter().find_first(d => inside(path, d.1))
    match owner {
      Some((_, dir)) if !self.exists(path) => {
        // Packed with its archived workspace: read back out of its archive, under its lock.
        let workspace = dirname(dir)
        let data = jstr(self.hub("config", []).get("dataDir")).unwrap_or("")
        let room = self.backend.ask("sessions/footprint.roomOfSoon", [
          js(data),
          js(workspace),
        ])
        match jstr(Some(room)) {
          Some(room) => {
            let rel = path.unsafe_substring(
              start=workspace.length() + 1,
              end=path.length(),
            )
            let bytes = self.with_lock(room, async fn() {
              self.workspace_file(room, rel)
            })
            match bytes {
              Some(b) => {
                self.mkdirs(dirname(path))
                ignore(self.fs("writeFile", [js(path), jbytes(b)]))
              }
              None => ()
            }
          }
          None => ()
        }
      }
      _ => ()
    }
    guard owner is Some((_, owner_dir)) else {
      raise Refused(400, self.tr(r.lang, "station.files.notUploaded"))
    }
    if !self.exists(path) {
      raise Refused(400, self.tr(r.lang, "station.files.notUploaded"))
    }
    // Its size as the sender read it; else, for a picture or a film, as its header says.
    let w = dimension(o.get("width"))
    let h = dimension(o.get("height"))
    let facts = self.backend.ask("sessions/image-size.shownFactsSoon", [
      js(path),
    ])
    let has_facts = !nullish(facts)
    let (width, height) = if w is Some(_) && h is Some(_) {
      (w.map(jnum), h.map(jnum))
    } else if has_facts {
      (
        defined(facts.get("width").unwrap_or(jundef)),
        defined(facts.get("height").unwrap_or(jundef)),
      )
    } else {
      (w.map(jnum), h.map(jnum))
    }
    let name = match str_field(o, "name") {
      Some(n) => n
      None =>
        path.unsafe_substring(start=owner_dir.length() + 1, end=path.length())
    }
    let size = match o.get("size") {
      Some(Num(n)) if n > 0.0 =>
        @cmp.minimum(
          if n < 0.0 {
            n.ceil()
          } else {
            n.floor()
          },
          9007199254740991.0,
        )
      _ => 0.0
    }
    let mut a = attachment(chars(name, 200), path, size)
    match (width, height) {
      (Some(wv), Some(hv)) => {
        a = jset(a, "width", wv)
        a = jset(a, "height", hv)
      }
      _ => ()
    }
    if has_facts {
      match facts.get("duration") {
        Some(d) if !is_undef(d) => a = jset(a, "duration", d)
        _ => ()
      }
      match facts.get("frames") {
        Some(f) if !is_undef(f) => a = jset(a, "frames", f)
        _ => ()
      }
    }
    out.push(a)
  }
  out
}

///|
async fn Admin::speed_asked(self : Admin, value : JV?) -> JV {
  match value {
    None | Some(Null) => Null
    Some(v) => {
      let speed = self.backend.ask("core/model-speed.modelSpeed", [v])
      if speed is Null {
        raise Refused(400, "speed must be standard, fast, ultrafast or null")
      }
      speed
    }
  }
}

///|
async fn Admin::context_asked(self : Admin, value : JV?, lang : String) -> JV {
  self.backend.ask("sessions/context-cap.contextAsked", [
    value.unwrap_or(jundef),
    js(lang),
  ])
}

///|
/// One of the machine's own sessions with where its transcript is, as the readers find it; None where there is none.
async fn Admin::found_machine_session(
  self : Admin,
  r : Request,
  runtime : JV,
  id : String,
) -> JV? {
  let a = self.read(
    r,
    "machineSession",
    jobj([
      ("lang", js(r.lang)),
      ("runtime", runtime),
      ("id", js(id)),
      ("found", jbool(true)),
    ]),
  )
  if a.status == 404 {
    return None
  }
  let said = parse(js_string(Some(js(a.text()))))
  if a.status != 200 {
    raise Refused(
      a.status,
      jstr(said.get("error")).unwrap_or("machine session not read"),
    )
  }
  Some(said.get("session").unwrap_or(jundef))
}

///|
fn is_cc(c : Int32) -> Bool {
  c < 0x20 || (c >= 0x7f && c <= 0x9f)
}

///|
fn strings_or_throw(v : JV) -> Bool {
  v is Arr(items) && items.all(x => x is Str(_))
}

///|
fn Admin::hub_routes(self : Admin) -> Array[Route] {
  let dev = if self.setup.dev {
    [
      // Hands the station a chat message as if the connect had received it (development stations, for those who
      // manage them; anyone else finds no such route).
      route("POST", "^\\/dev\\/inject$", async fn(r, _) {
        if !manages_station(r.viewer) {
          return error(404, "no route \{r.verb} \{r.path}")
        }
        self.hub_write(async fn() {
          let i = input(r)
          let ts = text_of(i.get("ts"))
          self.backend.tell("hub.accept", [
            js(text_of(i.get("connect"))),
            jobj([
              ("channel", js(text_of(i.get("channel")))),
              ("threadTs", js(str_field(i, "threadTs").unwrap_or(ts))),
              ("ts", js(ts)),
              ("user", js(text_of(i.get("user")))),
              ("text", js(text_of(i.get("text")))),
              ("addressed", jbool(!(i.get("addressed") is Some(Bool(false))))),
            ]),
          ])
          ok(jobj([("ok", jbool(true))]))
        })
      }),
    ]
  } else {
    []
  }
  [
    route("POST", "^\\/*threads\\/+([^/]+)\\/+regenerate-title\\/*$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        if jstr(t.get("surface")) != Some(STILLFAIL_SURFACE) {
          raise Refused(
            400,
            self.tr(r.lang, "station.admin.renameOnlyStillfail"),
          )
        }
        let tid = t.get("id").unwrap_or(jundef)
        let members = []
        for key in self.thread_keys(jnumber(Some(tid)).unwrap_or(0.0)) {
          let row = self.store("getSession", [js(key)])
          if !(row is Null) &&
            self.session_seen(r.viewer, jstr(row.get("key")).unwrap_or("")) {
            members.push(row)
          }
        }
        self.backend.tell("sessions/regenerate-title.regenerateTitle", [
          jref("hub"),
          tid,
          jarr(members),
        ]) catch {
          e =>
            match thrown_as(e, "TitleError") {
              Some(said) => {
                let problem = js_string(said.get("problem"))
                raise Refused(
                  if problem == "changed" {
                    409
                  } else {
                    400
                  },
                  self.tr(r.lang, "station.title.\{problem}"),
                )
              }
              None => raise e
            }
        }
        self.thread_view(r, tid)
      })
    }),
  ] +
  dev +
  [
    // A new chat: its session and its thread are made first, so files can be uploaded into it before the first message.
    route("POST", "^\\/sessions$", async fn(r, _) {
      self.hub_write(async fn() {
        self.retiring(r)
        let i = input(r)
        let given = (k : String) => {
          match i.get(k) {
            Some(Str(s)) if s != "" => js(s)
            _ => Null
          }
        }
        let profiles = match i.get("profiles") {
          None => None
          Some(Null) => Some(JV::Null)
          Some(p) =>
            if strings_or_throw(p) {
              Some(p)
            } else {
              raise Refused(
                400, "profiles must be a list of profile ids or null",
              )
            }
        }
        let made = as_status(400, async fn() {
          let runtime = self.runtime_of(r, i)
          let speed = self.speed_asked(i.get("speed"))
          let context = self.context_asked(i.get("context"), r.lang)
          let preset_copy = match i.get("presetCopy") {
            None | Some(Null) => JV::Null
            Some(p) => self.backend.ask("sessions/presets.presetCopyInput", [p])
          }
          let opts = jobj(
            [("runtime", runtime), ("profile", given("profile"))] +
            (match profiles {
              Some(p) => [("profiles", p)]
              None => []
            }) +
            [
              ("model", given("model")),
              ("effort", given("effort")),
              (
                "fast",
                match i.get("fast") {
                  Some(Bool(b)) => jbool(b)
                  _ => Null
                },
              ),
              ("speed", speed),
              ("tui", jbool(i.get("tui") is Some(Bool(true)))),
              ("context", context),
              (
                "title",
                match i.get("title") {
                  Some(Str(t)) => js(chars(t, 120))
                  _ => Null
                },
              ),
              ("createdBy", js(r.email())),
              ("clientKey", given("clientKey")),
              ("ws", r.ws_or_null()),
              ("preset", given("preset")),
              ("presetCopy", preset_copy),
            ],
          )
          self.backend.ask("sessions/lifecycle.newSession", [
            jref("hub"),
            opts,
            js(r.lang),
          ])
        })
        let pair = jitems(Some(made))
        self.made(
          r,
          jstr(pair.get(0)).unwrap_or(""),
          jget(pair.get(1), "id").unwrap_or(jundef),
        )
      })
    }),
    // Going on in a chat with a session this machine's own Claude Code or Codex kept.
    route("POST", "^\\/machine-sessions$", async fn(r, _) {
      self.hub_write(async fn() {
        let i = input(r)
        let kind = self.runtime_of(r, i)
        let id = text_of(i.get("id"))
        let roots = self.backend.ask("read/machine.roots", [])
        let found = match kind {
          Str("claude" | "codex") => self.found_machine_session(r, kind, id)
          _ => None
        }
        guard found is Some(found) else {
          raise Refused(
            404,
            self.tr(r.lang, "station.admin.noLocalSession", args=[("id", id)]),
          )
        }
        let ws = if r.who("home") is Some(Bool(false)) {
          r.who("workspace").unwrap_or(jundef)
        } else {
          Null
        }
        let made = as_status(400, async fn() {
          self.backend.ask("sessions/lifecycle.continueMachineSession", [
            jref("hub"),
            roots,
            found,
            js(r.email()),
            js(r.lang),
            ws,
          ])
        })
        let pair = jitems(Some(made))
        let key = jstr(pair.get(0)).unwrap_or("")
        self.log(
          "info",
          "admin",
          "machine session continued from the admin page",
          jobj([("session", js(key)), ("from", js(id)), ("by", js(r.email()))]),
        )
        self.made(r, key, jget(pair.get(1), "id").unwrap_or(jundef))
      })
    }),
    // The chats handed from here to other stations, a page at a time by session (`after`), each with where it went.
    route("GET", "^\\/moved$", async fn(r, _) {
      self.hub_write(async fn() {
        let after = r.param("after").unwrap_or("")
        let asked = match r.param("limit") {
          Some(l) => js_number(l)
          None => 200.0
        }
        let asked = if asked.is_nan() || asked == 0.0 { 200.0 } else { asked }
        let limit = @cmp.minimum(@cmp.maximum(asked, 1.0), 500.0)
        let vws = r.who("workspace")
        let out = []
        for
          h in jitems(Some(self.store("handedChats", [js(after), jnum(limit)]))) {
          let hws = h.get("ws").unwrap_or(jundef)
          let mine = match
            (
              if nullish(hws) {
                JV::Null
              } else {
                hws
              },
              match vws {
                None => JV::Null
                Some(v) => if nullish(v) { JV::Null } else { v }
              },
            ) {
            (Null, Null) => true
            (Str(a), Str(b)) => a == b
            _ => false
          }
          let first = mine || vws is Some(Null) || hws is Null
          if !first {
            continue
          }
          let ws = self.store("sessionWs", [h.get("session").unwrap_or(jundef)])
          let handed = match jstr(Some(ws)) {
            Some(w) => w.has_prefix(handed_ws(""))
            None => false
          }
          if handed {
            out.push(
              jobj(
                [
                  ("session", h.get("session").unwrap_or(jundef)),
                  ("station", h.get("station").unwrap_or(jundef)),
                  ("thread", h.get("thread").unwrap_or(jundef)),
                  ("there", h.get("there").unwrap_or(jundef)),
                  ("at", h.get("at").unwrap_or(jundef)),
                ].filter(f => !is_undef(f.1)),
              ),
            )
          }
        }
        ok(jobj([("moved", jarr(out))]))
      })
    }),
    // Another chat on the pages with a session in it.
    route("POST", "^\\/threads$", async fn(r, _) {
      self.hub_write(async fn() {
        let i = input(r)
        let key = text_of(i.get("session"))
        self.session_there(key, r)
        let t = match i.get("title") {
          Some(Str(t)) => trim_js(t)
          _ => ""
        }
        let chat = self.backend.ask("sessions/lifecycle.ensureConversationChat", [
          jref("hub"),
          js(key),
          js(r.email()),
          if t == "" {
            Null
          } else {
            js(chars(t, 80))
          },
        ])
        self.thread_view(r, chat.get("id").unwrap_or(jundef))
      })
    }),
    // Files wait here, in no chat, until a message takes them into its chat.
    route("POST", "^\\/uploads$", async fn(r, _) {
      self.hub_write(async fn() {
        let dir = self.staged()
        self.sweep_staged(dir)
        ok(
          self.save_upload(
            r.body,
            dir,
            r.param("name").unwrap_or("file"),
            r.lang,
          ),
        )
      })
    }),
    // A file in parts: a big one goes up a piece at a time, and on from where it was after a broken connection.
    route("POST", "^\\/uploads\\/parts$", async fn(r, _) {
      self.hub_write(async fn() {
        let dir = self.staged()
        self.sweep_staged(dir)
        let num = (name : String) => {
          match r.param(name) {
            Some(v) if re("^[0-9]+$").matches(v) => js_number(v)
            _ => -1.0
          }
        }
        ok(
          self.save_part(
            r.body,
            dir,
            r.param("id").unwrap_or(""),
            r.param("name").unwrap_or("file"),
            num("size"),
            num("offset"),
            r.param("sha256"),
            r.lang,
          ),
        )
      })
    }),
    // A session deleted.
    route("DELETE", "^\\/*sessions\\/+([^/]+)\\/*$", async fn(r, m) {
      self.hub_write(async fn() {
        let key = segment(m[0].unwrap())
        self.session_there(key, r)
        self.backend.tell("sessions/lifecycle.deleteSession", [
          jref("hub"),
          js(key),
        ])
        self.log(
          "info",
          "admin",
          "session deleted from the admin page",
          jobj([("session", js(key)), ("by", js(r.email()))]),
        )
        ok(jobj([("ok", jbool(true))]))
      })
    }),
    // Its ended jobs cleared.
    route("DELETE", "^\\/*sessions\\/+([^/]+)\\/+jobs(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let key = segment(m[0].unwrap())
        self.session_there(key, r)
        let removed = self.backend.ask("jobs.clearEnded", [js(key)])
        self.log(
          "info",
          "admin",
          "ended jobs cleared from the admin page",
          jobj([
            ("session", js(key)),
            ("by", js(r.email())),
            ("count", jint(jitems(Some(removed)).length())),
          ]),
        )
        ok(jobj([("removed", removed)]))
      })
    }),
  ] +
  ["POST", "DELETE"].map(verb => {
    route(verb, "^\\/*sessions\\/+([^/]+)\\/+archive(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let key = segment(m[0].unwrap())
        self.session_there(key, r)
        self.backend.tell("sessions/lifecycle.archive", [
          jref("hub"),
          js(key),
          jbool(verb == "POST"),
        ])
        self.read(r, "summary", jobj([("key", js(key)), ("lang", js(r.lang))]))
      })
    })
  }) +
  [
    route(
      "POST",
      "^\\/*sessions\\/+([^/]+)\\/+(stop|cancel-retry|retry|reassign|evict|warm|compact|clear|settings)(?:\\/.*)?$",
      async fn(r, m) {
        self.hub_write(async fn() {
          self.session_action(r, segment(m[0].unwrap()), m[1].unwrap())
        })
      },
    ),
    // A background job stopped from the pages, as its agent's job_stop does.
    route("POST", "^\\/*jobs\\/+([^/]+)\\/+stop(?:\\/.*)?$", async fn(r, m) {
      self.hub_write(async fn() {
        let job = self.backend.ask("jobs.stopFor", [
          js(segment(m[0].unwrap())),
          js(r.email()),
        ])
        self.log(
          "info",
          "admin",
          "job stopped from the admin page",
          jobj([("job", job.get("id").unwrap_or(jundef)), ("by", js(r.email()))]),
        )
        ok(self.backend.ask("jobs/jobs.shown", [jref("store"), job]))
      })
    }),
    // A person's message in a chat on the pages, with its files and quotes.
    route("POST", "^\\/*threads\\/+([^/]+)\\/+messages(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() { self.message(r, segment(m[0].unwrap())) })
    }),
    // Another session brought into a chat.
    route("POST", "^\\/*threads\\/+([^/]+)\\/+sessions(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        let key = text_of(input(r).get("session"))
        self.session_there(key, r)
        let tid = t.get("id").unwrap_or(jundef)
        as_status(400, async fn() {
          self.backend.tell("sessions/lifecycle.addToThread", [
            jref("hub"),
            tid,
            js(key),
          ])
        })
        self.thread_view(r, tid)
      })
    }),
    // The people of where the chat would be relayed, for its note to mention.
    route("GET", "^\\/*threads\\/+([^/]+)\\/+relay\\/+people\\/*$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        let q = (name : String) => trim_js(r.param(name).unwrap_or(""))
        let (connect, channel, link) = (q("connect"), q("channel"), q("link"))
        if link == "" && (connect == "" || channel == "") {
          raise Refused(400, self.tr(r.lang, "station.relay.pick"))
        }
        let target = if link != "" {
          jobj(
            [("link", js(link))] +
            (if connect != "" { [("connect", js(connect))] } else { [] }),
          )
        } else {
          jobj([("connect", js(connect)), ("channel", js(channel))])
        }
        let people = as_status(400, async fn() {
          self.backend.ask("sessions/relay.relayPeople", [
            jref("hub"),
            t,
            target,
          ])
        })
        ok(jobj([("people", people)]))
      })
    }),
    // Where the chat can be relayed: each connect's channels and groups its bot is in.
    route("GET", "^\\/*threads\\/+([^/]+)\\/+relay(?:\\/.*)?$", async fn(
      _r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        let connects = as_status(400, async fn() {
          self.backend.ask("sessions/relay.relayPlaces", [jref("hub"), t])
        })
        ok(jobj([("connects", connects)]))
      })
    }),
    // The chat relayed to one of them, or to the Slack thread of a message's link, with a `note`.
    route("POST", "^\\/*threads\\/+([^/]+)\\/+relay(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        let i = input(r)
        let connect = trim_js(text_of(i.get("connect")))
        let channel = trim_js(text_of(i.get("channel")))
        let link = trim_js(text_of(i.get("link")))
        if link == "" && (connect == "" || channel == "") {
          raise Refused(400, self.tr(r.lang, "station.relay.pick"))
        }
        let name = trim_js(r.who_str("name"))
        let by = jobj([
          ("name", js(if name == "" { r.email() } else { name })),
          ("email", js(r.email())),
        ])
        let joins = i.get("join") is Some(Bool(true))
        let target = if link != "" {
          jobj(
            [("link", js(link))] +
            (if connect != "" { [("connect", js(connect))] } else { [] }),
          )
        } else {
          jobj(
            [("connect", js(connect)), ("channel", js(channel))] +
            (if joins { [("join", jbool(true))] } else { [] }),
          )
        }
        let note = js(chars(text_of(i.get("note")), 2000))
        ok(
          as_status(400, async fn() {
            self.backend.ask("sessions/relay.relay", [
              jref("hub"),
              t,
              by,
              target,
              note,
            ])
          }),
        )
      })
    }),
  ] +
  ["POST", "DELETE"].map(verb => {
    route(verb, "^\\/*threads\\/+([^/]+)\\/+archive(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.hub_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        let tid = t.get("id").unwrap_or(jundef)
        as_status(400, async fn() {
          self.backend.tell("sessions/lifecycle.archiveChat", [
            jref("hub"),
            tid,
            jbool(verb == "POST"),
          ])
        })
        self.thread_view(r, tid)
      })
    })
  })
}

///|
fn notice_of(i : JV) -> (Double, Double)? {
  match (i.get("thread"), i.get("seq")) {
    (Some(Num(t)), Some(Num(s))) if is_safe_integer(t) &&
      is_safe_integer(s) &&
      t > 0.0 &&
      s > 0.0 => Some((t, s))
    _ => None
  }
}

///|
async fn Admin::session_action(
  self : Admin,
  r : Request,
  key : String,
  action : String,
) -> Answer {
  let done = () => ok(jobj([("ok", jbool(true))]))
  match action {
    "stop" => {
      self.backend.tell("hub.stop", [js(key)])
      done()
    }
    "cancel-retry" | "retry" | "reassign" => {
      self.session_there(key, r)
      let i = input(r)
      guard notice_of(i) is Some((thread, seq)) else {
        raise Refused(
          400,
          if action == "cancel-retry" {
            "invalid retry notice"
          } else {
            "invalid failure notice"
          },
        )
      }
      let call = match action {
        "cancel-retry" => "hub.cancelRetry"
        "retry" => "hub.retryFailed"
        _ => "hub.reassign"
      }
      self.backend.tell(call, [js(key), jnum(thread), jnum(seq)])
      done()
    }
    "evict" => {
      self.backend.tell("hub.evict", [js(key)])
      done()
    }
    // Its context compacted (begun: its end is said in its chat), or cleared; refused while it runs.
    "compact" | "clear" => {
      self.session_there(key, r)
      let refused = if action == "compact" {
        self.hub("compact", [js(key)])
      } else {
        self.hub("clear", [
          js(key),
          jbool(input(r).get("readBack") is Some(Bool(true))),
        ])
      }
      if !(refused is Null) {
        raise Refused(409, js_string(Some(refused)))
      }
      self.log(
        "info",
        "admin",
        "session \{if action == "compact" { "compacted" } else { "cleared" }} from the admin page",
        jobj([("session", js(key)), ("by", js(r.email()))]),
      )
      done()
    }
    "warm" => {
      self.session_there(key, r)
      self.later(async fn() {
        self.backend.tell("hub.warm", [js(key)]) catch {
          e =>
            self.log(
              "warn",
              "admin",
              "warming failed",
              jobj([("session", js(key)), ("error", js(message_of(e)))]),
            )
        }
      })
      ok(jobj([("ok", jbool(true))]), status=202)
    }
    // How the session runs from its next turn on: its profile, model, effort (configure).
    _ => {
      let i = input(r)
      let pick = (name : String) => {
        match i.get(name) {
          None => None
          Some(Null) => Some(JV::Null)
          Some(v) => Some(js(text_of(Some(v))))
        }
      }
      let mut change = JV::Obj([])
      if jhas(i, "runtime") {
        match i.get("runtime") {
          Some(Str(s)) if s != "" => change = jset(change, "runtime", js(s))
          _ => raise Refused(400, "runtime must be a name")
        }
      }
      match pick("model") {
        Some(v) => change = jset(change, "model", v)
        None => ()
      }
      match pick("effort") {
        Some(v) => change = jset(change, "effort", v)
        None => ()
      }
      // A profile's id keeps the session to it; `profiles` keeps it to a chosen set; null gives the choice back.
      match i.get("profile") {
        Some(Str(_) as p) | Some(Null as p) =>
          change = jset(change, "profile", p)
        _ => ()
      }
      if jhas(i, "profiles") {
        let p = i.get("profiles").unwrap()
        if !(p is Null) && !strings_or_throw(p) {
          raise Refused(400, "profiles must be a list of profile ids or null")
        }
        change = jset(change, "profiles", p)
      }
      // Given back to the station and its account picked again now.
      if i.get("repick") is Some(Bool(true)) {
        change = jset(change, "repick", jbool(true))
      }
      if jhas(i, "afresh") {
        let a = i.get("afresh").unwrap()
        if !(a is Null) && !(a is Bool(_)) {
          raise Refused(400, "afresh is true, false or null")
        }
        change = jset(change, "afresh", a)
      }
      if jhas(i, "tui") {
        let mode = i.get("tui").unwrap()
        if !(mode is Bool(_)) { raise Refused(400, "tui must be a boolean") }
        change = jset(change, "tui", mode)
      }
      if jhas(i, "speed") {
        change = jset(change, "speed", self.speed_asked(i.get("speed")))
      }
      if jhas(i, "fast") {
        let f = i.get("fast").unwrap()
        if !(f is Null) && !(f is Bool(_)) {
          raise Refused(400, self.tr(r.lang, "station.admin.badFast"))
        }
        change = jset(change, "fast", f)
      }
      // The most context it runs with: null gives it the model's whole window.
      if jhas(i, "context") {
        let c = as_status(400, async fn() {
          self.context_asked(i.get("context"), r.lang)
        })
        change = jset(change, "context", c)
      }
      let given = change
      as_status(400, async fn() {
        self.backend.tell("sessions/lifecycle.configure", [
          jref("hub"),
          js(key),
          given,
          js(r.lang),
        ])
      })
      // With the profile it runs on now (picked again: the one picked).
      let row = self.backend.ask("hub.store.getSession", [js(key)])
      let profile = if nullish(row) {
        JV::Null
      } else {
        match row.get("profile") {
          Some(p) if !nullish(p) => p
          _ => Null
        }
      }
      ok(jobj([("ok", jbool(true)), ("profile", profile)]))
    }
  }
}

///|
async fn Admin::message(self : Admin, r : Request, raw : String) -> Answer {
  let t = self.thread_there(raw)
  if jstr(t.get("surface")) != Some(STILLFAIL_SURFACE) {
    raise Refused(400, self.tr(r.lang, "station.admin.postOnlyStillfail"))
  }
  self.retiring(r)
  let tid = t.get("id").unwrap_or(jundef)
  let tn = jnumber(Some(tid)).unwrap_or(0.0)
  self.moved_of(self.thread_keys(tn), r.lang)
  let i = input(r)
  let said = trim_js(text_of(i.get("text")))
  let files = self.attachments(r, tn, i.get("attachments"))
  let quotes = quotes_of(i.get("quotes"))
  if said == "" && files.length() == 0 && quotes.length() == 0 {
    raise Refused(400, self.tr(r.lang, "station.admin.emptyMessage"))
  }
  let mut answered_card : JV? = None
  // Only a quote naming a message can match a pending card.
  let original = jitems(i.get("quotes"))
  let named = original
    .iter()
    .any(q => is_objectish(Some(q)) && q.get("ts") is Some(Str(_)))
  let mut pending = if named {
    self.store("pendingCardHeaderIfReady", [tid])
  } else {
    Null
  }
  while is_undef(pending) {
    if !self.setup.has("hub.prepareCardPosts") {
      raise Refused(503, "card lookup is not ready")
    }
    self.backend.tell("hub.prepareCardPosts", [jarr([tid])])
    if self.store("getThread", [tid]) is Null {
      raise Refused(404, "unknown thread \{js_string(Some(tid))}")
    }
    pending = self.store("pendingCardHeaderIfReady", [tid])
  }
  if !(pending is Null) {
    let pair = jitems(Some(pending))
    let asked = pair.get(0).unwrap_or(jundef)
    let card = pair.get(1).unwrap_or(jundef)
    let options = jitems(jget(Some(card), "options"))
    let selected = options
      .iter()
      .any(o => {
        is_objectish(Some(o)) &&
        o.get("label") == Some(js(said)) &&
        o.get("action") == Some(js("close"))
      })
    let asked_ts = asked.get("ts").unwrap_or(jundef)
    let quoted = original
      .iter()
      .any(q => {
        is_objectish(Some(q)) && q.get("ts").unwrap_or(jundef) == asked_ts
      })
    if files.length() == 0 && selected && quoted {
      raise Refused(409, self.tr(r.lang, "station.admin.updateClientForOption"))
    }
    if quoted {
      answered_card = Some(asked.get("n").unwrap_or(jundef))
    }
  }
  // Which app sent it ("android 0.1.1123"): for its agent, never shown. Older apps say nothing.
  let client = match i.get("client") {
    Some(Str(c)) =>
      chars(
        points(trim_js(c))
        .filter(p => !(p.length() == 1 && is_cc(p.unsafe_charcode_at(0))))
        .join(""),
        80,
      )
    _ => ""
  }
  let data = jstr(self.hub("config", []).get("dataDir")).unwrap_or("")
  let kept = self.backend.ask("drive/thumbs.keep", [
    jarr(files),
    js(self.thumbs_dir(data)),
  ])
  let n = self.backend.ask("sessions/lifecycle.say", [
    jref("hub"),
    tid,
    js(r.email()),
    js(said),
    kept,
    jarr(quotes),
    if client == "" {
      Null
    } else {
      js(client)
    },
  ])
  // Copied to the Slack and Feishu threads of the chat its sender picked: after the answer, not waited on.
  let cc_to = jitems(i.get("cc")).filter(x => x is Num(_))
  if cc_to.length() > 0 {
    let name = trim_js(r.who_str("name"))
    let by = if name == "" { r.email() } else { name }
    self.later(async fn() {
      self.backend.tell("sessions/cc.cc", [
        jref("hub"),
        tid,
        js(by),
        js(r.email()),
        js(said),
        kept,
        jarr(cc_to),
      ]) catch {
        _ => ()
      }
    })
  }
  // Answering from the decisions page means the question was read, even without opening its chat.
  match answered_card {
    Some(card) => ignore(self.store("setRead", [js(r.email()), tid, card]))
    None => ()
  }
  ok(jobj([("n", n)]))
}
