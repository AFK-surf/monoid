// Sessions, threads and jobs as the pages read them (routes/sessions.ts): GET /sessions, /sessions/:key and its
// timeline, files, parts, poster, transcript, widget-state, peek and open; GET /threads, /threads/:id; GET /jobs,
// /jobs/:id, /jobs/:id/log. A path's parts are those between slashes that are not empty, each percent-decoded (a `+`
// stays itself); parts after the third do not count.

///|
fn no_route(r : Request) -> Answer {
  error(404, "no route \{r.verb} \{r.path}")
}

///|
/// A file sent in a session's chat: in its workspace's uploads, or packed with its archived workspace.
priv enum Found {
  OnDisk(String, String)
  Archived(String, String, String, String)
  Answered(Answer)
}

///|
async fn Admin::uploaded(self : Admin, key : String, name : String) -> Found {
  let row = if self.setup.has("store") {
    self.store("getSession", [js(key)])
  } else {
    Null
  }
  if nullish(row) {
    return Answered(error(404, "unknown session \{key}"))
  }
  let not_found = () => Answered(error(404, "station.files.notFound"))
  let workspace = jstr(row.get("workspace")).unwrap_or("")
  let uploads = clean(join([workspace, "uploads"]))
  let base = re("[/\\\\]")
    .replace_all(name, _ => "\u{0}")
    .split("\u{0}")
    .last()
    .map(s => s.to_string())
    .unwrap_or("")
  let path = clean("\{uploads}/\{base}")
  if base == "" || !within(path, uploads) || same_path(path, uploads) {
    return not_found()
  }
  if self.stat_or_none(path) is Some(st) && st.file {
    return OnDisk(mime_of(path), path)
  }
  // Packed with its archived workspace: the route reads it out of the archive, under its lock.
  let room = match self.setup.data {
    None => JV::Null
    Some(data) =>
      self.backend.ask("sessions/footprint.roomOfSoon", [
        js(data),
        js(workspace),
      ])
  }
  guard jstr(Some(room)) is Some(room) else { return not_found() }
  if !self.exists(join([room, "workspace.tar.zst"])) {
    return not_found()
  }
  Archived(mime_of(path), room, path, "uploads/\{base}")
}

///|
/// read/sessions.ts `mime`: a file's type by its extension (none for a name with no dot, or only a leading one).
fn mime_of(p : String) -> String {
  let mut name = p
  if name.rev_find("/") is Some(i) {
    name = name[i + 1:].to_owned()
  }
  if name.rev_find("\\") is Some(i) {
    name = name[i + 1:].to_owned()
  }
  let dot = name.rev_find(".").unwrap_or(-1)
  if dot <= 0 {
    return "application/octet-stream"
  }
  match name[dot + 1:].to_owned().to_lower() {
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "svg" => "image/svg+xml"
    "pdf" => "application/pdf"
    "txt" => "text/plain; charset=utf-8"
    "md" => "text/markdown; charset=utf-8"
    "json" => "application/json"
    _ => "application/octet-stream"
  }
}

///|
fn answered(
  content_type : String,
  body : Body,
  extra~ : Array[(String, String)] = [],
) -> Answer {
  let headers : Map[String, String] = {
    "content-type": content_type,
    "cache-control": "private, max-age=3600",
  }
  for e in extra {
    headers[e.0] = e.1
  }
  { status: 200, headers, body, }
}

///|
const STREAMED : Double = 8388608.0

///|
/// A file on the disk as it goes out: read as it is sent once it is big, not taken into memory whole.
async fn Admin::from_disk(
  self : Admin,
  content_type : String,
  path : String,
) -> Answer {
  try {
    let size = self.fs_stat(path).size
    if size <= STREAMED {
      return answered(content_type, Whole(self.read_file(path)))
    }
    ignore(self.fs("access", [js(path)]))
    let stream = self.backend.ask("fs.createReadStream", [
      js(path),
      jobj([("highWaterMark", jint(1048576))]),
    ])
    answered(content_type, Stream(self.stream_of(stream)))
  } catch {
    e => error(500, self.io_message(e))
  }
}

///|
/// Under the archive room's lock (sessions/archive.ts `withLock`).
async fn[X] Admin::with_lock(
  self : Admin,
  room : String,
  f : async () -> X,
) -> X {
  self.backend.tell("sessions/archive.withLock.enter", [js(room)])
  let out = f() catch {
    e => {
      self.backend.tell("sessions/archive.withLock.exit", [js(room)])
      raise e
    }
  }
  self.backend.tell("sessions/archive.withLock.exit", [js(room)])
  out
}

///|
async fn Admin::workspace_file(
  self : Admin,
  room : String,
  relative : String,
) -> Bytes? {
  let got = self.backend.ask("sessions/archive.workspaceFile", [
    js(room),
    js(relative),
  ])
  if nullish(got) {
    None
  } else {
    bytes_of(got)
  }
}

///|
async fn Admin::thumbs_dir(self : Admin, data : String) -> String {
  jstr(Some(self.backend.ask("drive/thumbs.dir", [js(data)]))).unwrap_or("")
}

///|
async fn Admin::session_file(
  self : Admin,
  r : Request,
  key : String,
  name : String,
  thumb : Bool,
) -> Answer {
  match self.uploaded(key, name) {
    Answered(a) => a
    Archived(content_type, room, path, relative) => {
      // Restored meanwhile: it is back in its upload directory.
      let bytes = self.with_lock(room, async fn() {
        match (Some(self.read_file(path)) catch { _ => None }) {
          Some(b) => Some(b)
          None => self.workspace_file(room, relative)
        }
      })
      match bytes {
        None => error(404, "station.files.notFound")
        Some(b) => answered(content_type, Whole(b))
      }
    }
    OnDisk(content_type, file) => {
      let small = match self.setup.data {
        Some(data) if thumb => {
          let made = self.backend.ask("drive/thumbs.thumbnail", [
            js(file),
            js(self.thumbs_dir(data)),
          ])
          if nullish(made) {
            None
          } else {
            Some(made)
          }
        }
        _ => None
      }
      ignore(r)
      match small {
        Some(s) =>
          self.from_disk(
            jstr(s.get("type")).unwrap_or(""),
            jstr(s.get("path")).unwrap_or(""),
          )
        None => self.from_disk(content_type, file)
      }
    }
  }
}

///|
/// A file of a session on the disk, for a part of it or its poster: one packed with its archived workspace is put
/// back in its upload directory first. Its path and type, or the answer to give instead.
async fn Admin::on_disk(
  self : Admin,
  key : String,
  name : String,
) -> Result[(String, String), Answer] {
  match self.uploaded(key, name) {
    Answered(a) => Err(a)
    OnDisk(t, file) => Ok((file, t))
    Archived(t, room, path, relative) => {
      let back = self.with_lock(room, async fn() {
        if (Some(self.fs("access", [js(path)])) catch { _ => None }) is Some(_) {
          return true
        }
        match self.workspace_file(room, relative) {
          None => false
          Some(bytes) => {
            self.mkdirs(dirname(path))
            ignore(self.fs("writeFile", [js(path), jbytes(bytes)]))
            true
          }
        }
      })
      if back {
        Ok((path, t))
      } else {
        Err(error(404, "station.files.notFound"))
      }
    }
  }
}

///|
const MAX_PART : Double = 8388608.0

///|
fn range_of(r : Request) -> (Double, Double)? {
  let num = (name : String, fallback : Double) => {
    match r.param(name) {
      None => fallback
      Some(v) => if re("^[0-9]+$").matches(v) { js_number(v) } else { -1.0 }
    }
  }
  let offset = num("offset", 0.0)
  let length = num("length", MAX_PART)
  if !is_safe_integer(offset) ||
    offset < 0.0 ||
    !is_safe_integer(length) ||
    length < 0.0 ||
    length > MAX_PART {
    return None
  }
  Some((offset, length))
}

///|
async fn Admin::range_answer(
  self : Admin,
  path : String,
  content_type : String,
  offset : Double,
  length : Double,
  extra~ : Array[(String, String)] = [],
) -> Answer {
  let mut handle : JV? = None
  let out = try {
    let h = self.fs("open", [js(path), js("r")])
    handle = Some(h)
    let hname = ref_of(h).unwrap_or("")
    let total = jnumber(self.backend.ask(hname + ".stat", []).get("size")).unwrap_or(
      0.0,
    )
    let want = @cmp.maximum(0.0, @cmp.minimum(length, total - offset))
    let bytes = self.backend
      .ask_bytes("drive/fs.readAt", [h, jnum(offset), jnum(want)])
      .unwrap_or(b"")
    answered(
      content_type,
      Whole(bytes),
      extra=extra + [("stillfail-total", num_text(total))],
    )
  } catch {
    e => error(500, self.io_message(e))
  }
  match handle {
    Some(h) => self.backend.tell(ref_of(h).unwrap_or("") + ".close", [])
    None => ()
  }
  out
}

///|
async fn Admin::session_part(self : Admin, r : Request, key : String) -> Answer {
  guard range_of(r) is Some((offset, length)) else {
    return error(400, "invalid offset or length")
  }
  match self.on_disk(key, r.param("name").unwrap_or("")) {
    Err(a) => a
    Ok((path, t)) => self.range_answer(path, t, offset, length)
  }
}

///|
async fn Admin::data_dir_of_hub(self : Admin) -> String? {
  if !self.setup.has("agents") {
    return None
  }
  jstr(self.backend.ask("hub.config", []).get("dataDir"))
}

///|
async fn Admin::poster_of(self : Admin, r : Request, key : String) -> Answer {
  let data = self.data_dir_of_hub()
  let name = r.param("name").unwrap_or("")
  let wanted = data is Some(_) &&
    self.backend.ask("drive/posters.wanted", [js(name)]) is Bool(true)
  if !wanted {
    return error(404, "no poster")
  }
  match self.on_disk(key, name) {
    Err(a) => a
    Ok((path, _)) => {
      let made = self.backend.ask("drive/posters.poster", [
        js(path),
        js(self.thumbs_dir(data.unwrap())),
      ])
      match jstr(Some(made)) {
        None => error(404, "no poster")
        Some(p) => self.from_disk("image/jpeg", p)
      }
    }
  }
}

///|
const PEEK_BYTES : Int32 = 65536

///|
const PEEK_LINES : Int32 = 12

///|
const PEEK_LINE : Int32 = 240

///|
const PEEK_IMAGE : Double = 262144.0

///|
const OPEN_MAX : Double = 16777216.0

///|
/// The file a request names (`path`), as `sessionPlace` finds it; else the answer to give.
async fn Admin::place_of(
  self : Admin,
  r : Request,
  key : String,
) -> Result[JV, Answer] {
  let answer = self.read(
    r,
    "sessionPlace",
    jobj([
      ("key", js(key)),
      ("path", js(r.param("path").unwrap_or(""))),
      ("lang", js(r.lang)),
    ]),
  )
  guard answer.status == 200 && answer.body is Whole(b) else {
    return Err(answer)
  }
  Ok(parse(utf8_text(b)))
}

///|
/// ICU's order of two names, as `localeCompare` has it for the names a directory holds: letters by their lower case
/// first, a lower case before its upper case.
fn locale_compare(a : String, b : String) -> Int32 {
  @jsjson.locale_compare(a, b)
}

///|
async fn Admin::peek(self : Admin, r : Request, key : String) -> Answer {
  let data = self.data_dir_of_hub()
  let found = match self.place_of(r, key) {
    Err(a) => return a
    Ok(f) => f
  }
  let path = jstr(found.get("path")).unwrap_or("")
  let name = jstr(found.get("name")).unwrap_or("")
  let size = jnumber(found.get("size")).unwrap_or(0.0)
  let content_type = jstr(found.get("contentType")).unwrap_or("")
  let base = [
    ("path", found.get("path").unwrap_or(jundef)),
    ("name", found.get("name").unwrap_or(jundef)),
    ("size", found.get("size").unwrap_or(jundef)),
    ("mtime", found.get("mtime").unwrap_or(jundef)),
    ("type", found.get("contentType").unwrap_or(jundef)),
  ].filter(f => !is_undef(f.1))
  try {
    if found.get("dir") is Some(Bool(true)) {
      let entries = jitems(
          Some(
            self.fs("readdir", [
              js(path),
              jobj([("withFileTypes", jbool(true))]),
            ]),
          ),
        )
        .map(e => {
          (jstr(e.get("name")).unwrap_or(""), e.get("dir") is Some(Bool(true)))
        })
        .filter(e => !e.0.has_prefix("."))
      entries.sort_by((a, b) => {
        let d = (if b.1 { 1 } else { 0 }) - (if a.1 { 1 } else { 0 })
        if d != 0 {
          d
        } else {
          locale_compare(a.0, b.0)
        }
      })
      let shown = entries[0:@cmp.minimum(12, entries.length())]
        .to_array()
        .map(e => js(if e.1 { e.0 + "/" } else { e.0 }))
      return ok(
        jobj(
          base +
          [
            ("kind", js("dir")),
            ("entries", jarr(shown)),
            ("count", jint(entries.length())),
          ],
        ),
      )
    }
    if content_type.has_prefix("image/") {
      let small = match data {
        Some(d) if self.backend.ask("drive/thumbs.wanted", [js(name)])
          is Bool(true) &&
          size > PEEK_IMAGE => {
          let made = self.backend.ask("drive/thumbs.thumbnail", [
            js(path),
            js(self.thumbs_dir(d)),
          ])
          if nullish(made) {
            None
          } else {
            Some(made)
          }
        }
        _ => None
      }
      let (file, t) = match small {
        Some(s) =>
          (jstr(s.get("path")).unwrap_or(""), jstr(s.get("type")).unwrap_or(""))
        None => (path, content_type)
      }
      let bytes = if small is Some(_) || size <= PEEK_IMAGE {
        Some(self.read_file(file))
      } else {
        None
      }
      return ok(
        jobj(
          base +
          [("kind", js("image"))] +
          (match bytes {
            Some(b) =>
              [
                (
                  "image",
                  jobj([("type", js(t)), ("data", js(@base64.encode(b)))]),
                ),
              ]
            None => []
          }),
        ),
      )
    }
    let handle = self.fs("open", [js(path), js("r")])
    let hname = ref_of(handle).unwrap_or("")
    let want = if size < PEEK_BYTES.to_double() {
      size.to_int()
    } else {
      PEEK_BYTES
    }
    let head = try {
      let got = self.backend.ask(hname + ".read", [
        jbytes(Bytes::make(want, b'\x00')),
        jint(0),
        jint(want),
        jint(0),
      ])
      let n = jnumber(got.get("bytesRead")).unwrap_or(0.0).to_int()
      let b = bytes_of(got.get("buffer").unwrap_or(Null)).unwrap_or(b"")
      b[0:@cmp.minimum(n, b.length())].to_bytes()
    } catch {
      e => {
        self.backend.tell(hname + ".close", [])
        raise e
      }
    }
    self.backend.tell(hname + ".close", [])
    if head.iter().any(x => x == b'\x00') {
      return ok(jobj(base + [("kind", js("binary"))]))
    }
    let lines = re("\\r?\\n")
      .replace_all(utf8_text(head), _ => "\u{0}")
      .split("\u{0}")
      .map(l => l.to_string())
      .collect()
    // The last line of a cut read may be cut itself.
    if size > head.length().to_double() {
      ignore(lines.pop())
    }
    let asked = js_number(r.param("line").unwrap_or(""))
    let at = if is_safe_integer(asked) &&
      asked > 0.0 &&
      asked <= lines.length().to_double() {
      Some(asked.to_int())
    } else {
      None
    }
    let start = match at {
      None => 1
      Some(a) => @cmp.maximum(1, a - 3)
    }
    let shown = []
    for i in (start - 1)..<@cmp.minimum(lines.length(), start - 1 + PEEK_LINES) {
      let l = lines[i]
      shown.push(
        js(
          if code_points(l) > PEEK_LINE {
            chars(l, PEEK_LINE) + "…"
          } else {
            l
          },
        ),
      )
    }
    let lines_v = jobj(
      [("start", jint(start)), ("text", jarr(shown))] +
      (match at {
        None => []
        Some(a) => [("at", jint(a))]
      }),
    )
    ok(jobj(base + [("kind", js("text")), ("lines", lines_v)]))
  } catch {
    e => error(500, self.io_message(e))
  }
}

///|
/// encodeURIComponent.
pub fn encode_uri_component(s : String) -> String {
  @url.encode_uri_component(s)
}

///|
async fn Admin::open_file(self : Admin, r : Request, key : String) -> Answer {
  let found = match self.place_of(r, key) {
    Err(a) => return a
    Ok(f) => f
  }
  if found.get("dir") is Some(Bool(true)) {
    return error(400, "a directory")
  }
  let path = jstr(found.get("path")).unwrap_or("")
  let name = jstr(found.get("name")).unwrap_or("")
  let content_type = jstr(found.get("contentType")).unwrap_or("")
  let mtime = js_string(found.get("mtime"))
  let size = js_string(found.get("size"))
  let named = [
    ("stillfail-name", encode_uri_component(name)),
    ("stillfail-path", encode_uri_component(path)),
    ("stillfail-mtime", mtime),
  ]
  // (the version the device keeps, not changed since: no bytes, they are its already)
  if r.param("raw") == Some("1") && r.param("have") == Some(mtime + ":" + size) {
    let headers : Map[String, String] = {
      "content-type": content_type,
      "cache-control": "no-store",
    }
    for e in named {
      headers[e.0] = e.1
    }
    headers["stillfail-total"] = size
    return { status: 304, headers, body: Whole(b"") }
  }
  if r.param("raw") == Some("1") &&
    (r.param("offset") is Some(_) || r.param("length") is Some(_)) {
    guard range_of(r) is Some((offset, length)) else {
      return error(400, "invalid offset or length")
    }
    return self.range_answer(path, content_type, offset, length, extra=named)
  }
  if jnumber(found.get("size")).unwrap_or(0.0) > OPEN_MAX {
    return error(413, "too big to open here")
  }
  try {
    let bytes = self.read_file(path)
    if r.param("raw") == Some("1") {
      return answered(content_type, Whole(bytes), extra=named)
    }
    ok(
      jobj(
        [
          ("name", found.get("name").unwrap_or(jundef)),
          ("path", found.get("path").unwrap_or(jundef)),
          ("type", found.get("contentType").unwrap_or(jundef)),
          ("size", jint(bytes.length())),
          ("bytes", js(@base64.encode(bytes))),
        ].filter(f => !is_undef(f.1)),
      ),
    )
  } catch {
    e => error(500, self.io_message(e))
  }
}

///|
fn sessions_of(r : Request) -> JV {
  jobj([
    ("connect", jopt(r.param("connect"))),
    ("archived", jbool(r.param("archived") == Some("1"))),
    ("lang", js(r.lang)),
    ("viewer", r.viewer),
  ])
}

///|
fn threads_of(r : Request) -> JV {
  jobj([
    ("viewer", r.viewer),
    ("session", jopt(r.param("session"))),
    ("lang", js(r.lang)),
  ])
}

///|
/// `{k: param}` where a param undefined is left out (as JSON drops it).
fn params_obj(
  r : Request,
  fields : Array[(String, JV)],
  optional : Array[String],
) -> JV {
  jobj(
    fields +
    optional.filter_map(name => {
      match r.param(name) {
        Some(v) => Some((name, js(v)))
        None => None
      }
    }),
  )
}

///|
fn Admin::sessions_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/sessions$", async fn(r, _) {
      self.read(r, "sessions", sessions_of(r))
    }),
    route("POST", "^\\/changed\\/sessions$", async fn(r, _) {
      self.changed(r, "sessions", sessions_of(r), "key")
    }),
    route("POST", "^\\/changed\\/threads$", async fn(r, _) {
      self.changed(r, "threads", threads_of(r), "id")
    }),
    route("GET", "^\\/*sessions\\/+([^/]+)(?:\\/+([^/]+))?(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      let key = segment(m[0].unwrap())
      let action = match m[1] {
        Some(a) => Some(segment(a))
        None => None
      }
      match action {
        None =>
          self.read(
            r,
            "session",
            params_obj(
              r,
              [("key", js(key)), ("viewer", r.viewer), ("lang", js(r.lang))],
              ["turns", "jobs"],
            ),
          )
        // `brief=1`: in brief; `from`, `to`: those entries whole, as one is opened.
        Some("timeline") => {
          let a = jspread(
            params_obj(r, [("key", js(key))], ["before", "limit"]),
            jobj([("lang", js(r.lang))]),
          )
          self.read(
            r,
            "timeline",
            jspread(a, params_obj(r, [], ["from", "to", "brief", "after"])),
          )
        }
        Some("files") =>
          self.session_file(
            r,
            key,
            r.param("name").unwrap_or(""),
            r.param("thumb") == Some("1"),
          )
        Some("parts") => self.session_part(r, key)
        Some("poster") => self.poster_of(r, key)
        Some("transcript") =>
          self.read(
            r,
            "transcriptFile",
            jobj([("key", js(key)), ("lang", js(r.lang))]),
          )
        Some("widget-state") =>
          self.read(
            r,
            "widgetState",
            jspread(
              params_obj(r, [("key", js(key))], ["path"]),
              jobj([("lang", js(r.lang))]),
            ),
          )
        Some("peek") => self.peek(r, key)
        Some("open") => self.open_file(r, key)
        _ => no_route(r)
      }
    }),
    route("GET", "^\\/threads$", async fn(r, _) {
      self.read(r, "threads", threads_of(r))
    }),
    route(
      "GET",
      "^\\/*threads\\/+([^/]+)(?:\\/+(?!(?:entries|relay)(?:\\/|$))([^/]+)(?:\\/.*)?|\\/*)$",
      async fn(r, m) {
        let id = segment(m[0].unwrap())
        let answer = self.read(
          r,
          "thread",
          jobj([("id", js(id)), ("viewer", r.viewer), ("lang", js(r.lang))]),
        )
        if m[1] is None || answer.status != 200 {
          return answer
        }
        if segment(m[1].unwrap()) == "entries" {
          return self.read(
            r,
            "entries",
            jobj([
              ("viewer", r.viewer),
              ("thread", jnum(js_number(id))),
              ("params", query_json(r)),
            ]),
          )
        }
        no_route(r)
      },
    ),
    // `chats=0`: without the chat each is in, for a device that names it from the sidebar it holds.
    route("GET", "^\\/jobs$", async fn(r, _) {
      self.read(
        r,
        "openJobs",
        jobj([
          ("viewer", r.viewer),
          ("lang", js(r.lang)),
          ("chats", jbool(r.param("chats") != Some("0"))),
        ]),
      )
    }),
    route("GET", "^\\/*jobs\\/+([^/]+)(?:\\/+([^/]+))?(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      let id = segment(m[0].unwrap())
      match m[1] {
        None => self.read(r, "job", jobj([("id", js(id))]))
        Some(a) =>
          if segment(a) == "log" {
            self.read(r, "jobLog", params_obj(r, [("id", js(id))], ["lines"]))
          } else {
            no_route(r)
          }
      }
    }),
  ]
}
