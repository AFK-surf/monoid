// The admin API (station/src/api/admin.ts): a table of routes, each a method, a path pattern and what answers it,
// gathered from the route files (one a part of the API), the station's parts' after them. Reads go to the readers;
// what is not here answers 404 as an unknown route does. A write with an idempotency key is done once however often
// it is asked; a read-only member only reads (and marks their own); a session, chat or job of another workspace is
// none for its asker (api/seen.ts); a web service on the machine is reached through its preview's path.

///|

///|
pub struct Route {
  verb : String
  pattern : Re
  handle : async (Request, Array[String?]) -> Answer
}

///|
pub fn route(
  method_ : String,
  pattern : String,
  handle : async (Request, Array[String?]) -> Answer,
) -> Route {
  { verb: method_, pattern: re(pattern), handle, }
}

///|
/// What the station is as the program serves it, said once as it starts (and the parts that are there: a station
/// still starting has no store or agents yet, a test of reads none).
pub struct Setup {
  words : Words
  /// The station's build, as every answer says it.
  build : String
  /// Every runtime there is (agents/runtime.ts RUNTIME_KINDS).
  runtime_kinds : Array[String]
  /// A development station's (STILLFAIL_DEV=1): only there is /dev/inject a route.
  dev : Bool
  /// The station's data directory (stillfail.db, sessions/, thumbs/), where it is known.
  data : String?
  /// The station's key for the drive's grants (drive/grants.ts).
  grant_key : Bytes
  /// The station's own language (config.json `language`), for what it says on this machine.
  station_lang : String
  /// What is there of the station's parts, by name (`store`, `agents`, `events`, `config`, `data`, `cloud`,
  /// `grants`, `screens`, `parts`, `clones`, `resources.watch`...): absent is there.
  absent : Array[String]
}

///|
pub fn Setup::has(self : Setup, part : String) -> Bool {
  !self.absent.contains(part)
}

///|
/// A kept answer: its status, headers and bytes.
pub struct Kept {
  status : Int32
  headers : Map[String, String]
  body : Bytes
}

///|
priv struct Slot {
  mut at : Double?
  answer : @effect.Deferred[Kept?]
  mut settled : Kept?
}

///|
pub struct Admin {
  backend : Backend
  setup : Setup
  priv slots : Map[String, Slot]
  priv mut routes : Array[Route]
  /// The routes' own state, as their modules keep it (uploads in parts, stars as last read, ...).
  priv state : State
}

///|
let own_marks : Re = re(
  "^\\/*threads\\/+[^/]+\\/+(read|hidden|muted|dismissed|closed-card)(?:\\/.*)?$",
)

///|
let reads_re : Re = re("^\\/*(changed\\/+(chats|threads|sessions)|batch)$")

///|
let batched : Array[Re] = [
  re("^\\/threads\\/\\d+\\/entries$"),
  re("^\\/threads\\/\\d+\\/letters$"),
  re("^\\/threads\\/\\d+$"),
  re("^\\/sessions\\/[^/]+$"),
  re("^\\/sessions\\/[^/]+\\/timeline$"),
]

///|
const BATCH_MOST : Int32 = 64

///|
const BATCH_AT_ONCE : Int32 = 4

///|
const ONCE_KEEP_MS : Double = 600000.0

///|
let send_path : Re = re("^\\/*threads\\/+([^/]+)\\/+messages(?:\\/.*)?$")

///|
/// Roles that may read but not write (contract §4).
pub fn read_only(viewer : JV) -> Bool {
  jstr(jget(Some(viewer), "role")) == Some("viewer")
}

///|
/// Who manages the station itself: an owner or admin of any workspace it is in.
pub fn manages_station(viewer : JV) -> Bool {
  match jstr(jget(Some(viewer), "role")) {
    Some("owner" | "admin") => true
    _ => false
  }
}

///|
/// Whether `r` is one a read-only member may make: reads (GET, HEAD, and a list's changes), and their own marks.
pub fn read_only_may(method_ : String, path : String) -> Bool {
  method_ == "GET" ||
  method_ == "HEAD" ||
  (method_ == "PUT" && own_marks.matches(path)) ||
  (method_ == "POST" && reads_re.matches(path))
}

///|
/// The request as a part is told it: `{method, path}`.
fn asked(r : Request) -> JV {
  jobj([("method", js(r.verb)), ("path", js(r.path))])
}

///|
pub fn Admin::new(backend : Backend, setup : Setup) -> Admin {
  let a = { backend, setup, slots: {}, routes: [], state: State::new(), }
  a.routes = a.all_routes()
  a
}

///|
/// A read of the readers (test/reference/ops.ts), answered as JSON; its error as `{error}` with its status.
pub async fn Admin::read(
  self : Admin,
  r : Request,
  op : String,
  args : JV,
) -> Answer {
  let signal = r.verb == "GET" || (r.verb == "POST" && reads_re.matches(r.path))
  let options = if signal && r.signal is Some(_) {
    jobj([
      ("background", jbool(r.background)),
      ("signal", jobj([("$signal", jbool(true))])),
    ])
  } else {
    jobj([("background", jbool(r.background))])
  }
  let got = self.backend.ask_bytes("readers.readBytes", [
    js(op),
    args,
    js(r.lang),
    options,
  ]) catch {
    e =>
      return match thrown_as(e, "HttpError") {
        Some(said) => error(status_of(said), message_of(e))
        None => error(500, message_of(e))
      }
  }
  json_bytes(200, got.unwrap_or(b""))
}

///|
/// A store's call: the station's own (`tools.store`).
async fn Admin::store(self : Admin, call : String, args : Array[JV]) -> JV {
  self.backend.ask("store." + call, args)
}

///|
/// The clock's now, ms.
async fn Admin::now(self : Admin) -> Double {
  jnumber(Some(self.backend.ask("clock.currentTimeMillisUnsafe", []))).unwrap_or(
    0.0,
  )
}

///|
pub fn Admin::tr(
  self : Admin,
  lang : String,
  key : String,
  args~ : Array[(String, String)] = [],
) -> String {
  self.setup.words.tr(lang, key, args~)
}

///|
/// An answer to the request, as the station gives it.
pub async fn Admin::handle(self : Admin, r : Request) -> Answer {
  // Who asks is remembered by name, as the cloud's names: what chats show of people who wrote.
  match r.who("name") {
    Some(Str("")) => ()
    name =>
      self.backend.tell("readers.names.set", [
        r.who("email").unwrap_or(jundef),
        name.unwrap_or(jundef),
      ])
  }
  let key = header_of(r.headers, "idempotency-key")
  // (not a read that sends what the client holds, or several reads in one: a retry reads again, and an answer as it
  // comes is never held whole to be kept)
  let keyed = match key {
    Some(k) =>
      k != "" &&
      k.length() <= 200 &&
      r.verb != "GET" &&
      r.verb != "HEAD" &&
      !reads_re.matches(r.path)
    None => false
  }
  let answer = if keyed {
    self.once("\{r.email()}\u{0}\{r.path}\u{0}\{key.unwrap()}", () => {
      self.answer(r)
    })
  } else {
    self.answer(r)
  }
  // Every answer says this station keeps writes to once, and its build (api/oldest.ts).
  answer.headers["stillfail-idempotent"] = "1"
  answer.headers["stillfail-build"] = self.setup.build
  self.runtime_compatible(r, answer)
}

///|
/// `write`'s answer, or the answer the first write under `key` had: while the first is under way the others wait for
/// it; a 5xx is not kept (the write may not have happened: asked again, it is tried again).
async fn Admin::once(
  self : Admin,
  key : String,
  write : async () -> Answer,
) -> Answer {
  let now = self.now()
  self.sweep(now)
  while self.slots.get(key) is Some(slot) {
    match slot.answer.wait() {
      Some(kept) =>
        return {
          status: kept.status,
          headers: kept.headers.copy(),
          body: Whole(kept.body),
        }
      None => ()
    }
    // The first one's was not kept: this one tries, unless another got there first.
    if self.slots.get(key) is Some(s) && physical_equal(s, slot) {
      self.slots.remove(key)
    }
  }
  let slot = { at: None, answer: @effect.Deferred::new(), settled: None, }
  self.slots[key] = slot
  let kept = try {
    let answer = write()
    let body = answer.bytes()
    ({ status: answer.status, headers: answer.headers, body, } : Kept)
  } catch {
    e => {
      ignore(slot.answer.succeed(None))
      self.slots.remove(key)
      raise e
    }
  }
  if kept.status < 500 {
    slot.at = Some(self.now())
    slot.settled = Some(kept)
    ignore(slot.answer.succeed(Some(kept)))
  } else {
    ignore(slot.answer.succeed(None))
    self.slots.remove(key)
  }
  { status: kept.status, headers: kept.headers.copy(), body: Whole(kept.body), }
}

///|
fn Admin::sweep(self : Admin, now : Double) -> Unit {
  let gone = []
  for k, slot in self.slots {
    if slot.at is Some(at) && now - at >= ONCE_KEEP_MS {
      gone.push(k)
    }
  }
  for k in gone {
    self.slots.remove(k)
  }
}

///|
async fn Admin::answer(self : Admin, r : Request) -> Answer {
  // A viewer reads: no message sent, nothing changed; a part says what of its own a viewer changes too.
  if read_only(r.viewer) && !read_only_may(r.verb, r.path) {
    let may = self.setup.has("parts") &&
      self.backend.ask("parts.mayView", [asked(r)]) is Bool(true)
    if !may {
      return error(403, "read-only members cannot change this station")
    }
  }
  if r.verb == "POST" && re("^\\/*batch$").matches(r.path) {
    return self.batch(r)
  }
  // A session, chat or job of another workspace than the viewer's is none for them (api/seen.ts).
  if self.setup.has("store") {
    match self.elsewhere(r.path, r.viewer) {
      Some(hidden) => {
        // (a write to a chat handed to another station: answered where it went, as a message to it is)
        let there = if r.verb == "GET" || r.verb == "HEAD" {
          None
        } else {
          self.went(r.path, r.viewer)
        }
        return match there {
          Some(moved) =>
            json(
              409,
              stringify(
                jobj([
                  ("error", js(self.tr(r.lang, "station.move.movedThere"))),
                  ("moved", moved),
                ]),
              ),
            )
          None => error(404, hidden)
        }
      }
      None => ()
    }
  }
  // A web service on this machine, through its preview's path: any method, its answer as it comes.
  match preview_target(r.path) {
    Some((port, target)) => return self.preview(r, port, target)
    None => ()
  }
  for route in self.routes {
    if route.verb != r.verb {
      continue
    }
    match route.pattern.exec(r.path) {
      Some(found) => return (route.handle)(r, found[1:].to_array())
      None => ()
    }
  }
  error(404, "no route \{r.verb} \{r.path}")
}

///|
/// The port and path a /preview/<port>/<path> request is for (jobs/preview.ts `previewTarget`).
pub fn preview_target(path : String) -> (Int32, String)? {
  if !path.has_prefix("/preview/") {
    return None
  }
  let rest = path.unsafe_substring(start=9, end=path.length())
  let (port, target) = match rest.find("/") {
    Some(at) =>
      (
        rest.unsafe_substring(start=0, end=at),
        rest.unsafe_substring(start=at, end=rest.length()),
      )
    None => (rest, "/")
  }
  if port == "" || port.length() > 5 || !re("^[0-9]+$").matches(port) {
    return None
  }
  let n = js_number(port).to_int()
  if n >= 1 && n <= 65535 {
    Some((n, target))
  } else {
    None
  }
}

///|
async fn Admin::preview(
  self : Admin,
  r : Request,
  port : Int32,
  target : String,
) -> Answer {
  let headers = jarr(r.headers.map(h => jarr([js(h.0.to_lower()), js(h.1)])))
  let body = if r.body.length() > 0 { jbytes(r.body) } else { Null }
  let said = self.backend.ask("jobs/preview.proxyPreview", [
    js(r.verb),
    headers,
    body,
    jint(port),
    js(target + r.search.unwrap_or("")),
    js(r.lang),
  ])
  let joined : Map[String, String] = {}
  for h in jitems(said.get("headers")) {
    let pair = jitems(Some(h))
    if pair.length() < 2 {
      continue
    }
    let name = jstr(Some(pair[0])).unwrap_or("")
    let value = jstr(Some(pair[1])).unwrap_or("")
    joined[name] = match joined.get(name) {
      Some(was) => "\{was}, \{value}"
      None => value
    }
  }
  {
    status: jnumber(said.get("status")).unwrap_or(502.0).to_int(),
    headers: joined,
    body: Whole(bytes_of(said.get("body").unwrap_or(Null)).unwrap_or(b"")),
  }
}

///|
/// A request as JSON, as a part is told it whole.
pub fn request_json(r : Request) -> JV {
  jobj([
    ("method", js(r.verb)),
    ("path", js(r.path)),
    ("query", jarr(r.query.map(q => jarr([js(q.0), js(q.1)])))),
    ("headers", jobj(r.headers.map(h => (h.0, js(h.1))))),
    ("body", jbytes(r.body)),
    ("viewer", r.viewer),
    ("lang", js(r.lang)),
  ])
}

///|
/// An answer a part gave as JSON (`{status, headers, body}`).
pub fn answer_of(said : JV) -> Answer {
  let headers : Map[String, String] = {}
  for f in jfields(said.get("headers")) {
    headers[f.0] = js_string(Some(f.1))
  }
  {
    status: jnumber(said.get("status")).unwrap_or(500.0).to_int(),
    headers,
    body: Whole(bytes_of(said.get("body").unwrap_or(Null)).unwrap_or(b"")),
  }
}

///|
/// Several reads in one (POST /batch `{ gets }`, each a path with its query): each answered as its GET is, all in one
/// answer, `{ answers: [{ status, body }] }` in their order. Only the reads in BATCHED. A client that accepts
/// `application/x-ndjson` is given each answer as a line of its own as soon as it is read (`batch_lines`).
async fn Admin::batch(self : Admin, r : Request) -> Answer {
  if r.body.length() > 1000000 {
    return error(413, "request too large")
  }
  let gets = match body_json(r) {
    Some(v) => jget(Some(v), "gets")
    None => None
  }
  let paths = match gets {
    Some(Arr(items)) if items.length() <= BATCH_MOST &&
      items.all(g => g is Str(_)) => items.map(g => jstr(Some(g)).unwrap())
    _ => return error(400, "gets: at most \{BATCH_MOST} paths to read")
  }
  let aborted = () => {
    match r.signal {
      Some(s) => s.aborted
      None => false
    }
  }
  if aborted() {
    return error(503, "read cancelled")
  }
  match batch_stream_type(header_of(r.headers, "accept").unwrap_or("")) {
    Some(content_type) => return self.batch_lines(r, paths, content_type)
    None => ()
  }
  let answers : Array[String] = Array::make(paths.length(), "")
  let next = Ref(0)
  let work = async fn() {
    while next.val < paths.length() {
      let i = next.val
      next.val += 1
      if aborted() {
        return
      }
      answers[i] = batch_line(self.batch_read(r, paths[i], r.signal))
    }
  }
  let n = if paths.length() < BATCH_AT_ONCE {
    paths.length()
  } else {
    BATCH_AT_ONCE
  }
  ignore(@effect.all(Array::makei(n, _ => work)))
  // A cancelled batch has no answer to keep; a retry must read its pages again.
  if aborted() {
    return error(503, "read cancelled")
  }
  json(200, "{\"answers\":[\{answers.join(",")}]}")
}

///|
/// A batch's reads one at a time, each answer a line (`{"status":…,"body":…}`) given as soon as it is read: a page read
/// waits for no other, and a client stopping (the device gone, or the stream let go of) starts no read after the one
/// under way. Each line is as a client from before takes it (compat.mbt, as the whole batch's answers are: that one
/// sees a stream, and leaves it as it is).
fn Admin::batch_lines(
  self : Admin,
  r : Request,
  paths : Array[String],
  content_type : String,
) -> Answer {
  let own = Signal::new()
  let stopped = Ref(false)
  let at = Ref(0)
  let gone = () => {
    stopped.val ||
    own.aborted ||
    (match r.signal {
      Some(s) => s.aborted
      None => false
    })
  }
  let next = async fn() -> Bytes? {
    if gone() || at.val >= paths.length() {
      stopped.val = true
      return None
    }
    let p = paths[at.val]
    at.val += 1
    let a = self.batch_read(r, p, Some(own))
    if gone() {
      stopped.val = true
      return None
    }
    let shown = self.runtime_compatible({ ..r, verb: "GET", path: path_of(p) }, a)
    Some(utf8(batch_line(shown) + "\n"))
  }
  let close = async fn() {
    stopped.val = true
    own.abort()
  }
  {
    status: 200,
    headers: { "content-type": content_type, "cache-control": "no-store" },
    body: Streamed(next, close),
  }
}

///|
/// One read of a batch, as its GET is answered, in the background.
async fn Admin::batch_read(
  self : Admin,
  r : Request,
  p : String,
  signal : Signal?,
) -> Answer {
  let (path, query, search) = match p.find("?") {
    Some(at) =>
      (
        p.unsafe_substring(start=0, end=at),
        query_pairs(p.unsafe_substring(start=at + 1, end=p.length())),
        p.unsafe_substring(start=at, end=p.length()),
      )
    None => (p, [], "")
  }
  if batched.iter().any(b => b.matches(path)) {
    self.answer({
      ..r,
      signal,
      background: true,
      verb: "GET",
      path,
      query,
      search: Some(search),
      body: b"",
    })
  } else {
    error(400, "not read in a batch: \{path}")
  }
}

///|
/// A batch's answers a line at a time (`Admin::batch_lines`).
let batch_lines_type : String = "application/vnd.stillfail.batch-lines+json"

///|
let ndjson : String = "application/x-ndjson"

///|
fn batch_stream_type(accept : String) -> String? {
  let mut saw_ndjson = false
  for part in accept.split(",") {
    let raw = part.to_string()
    let base = match raw.find(";") {
      Some(i) => raw.unsafe_substring(start=0, end=i)
      None => raw
    }
    let token = base.trim(chars=" \t\n\r").to_owned().to_lower()
    if token == batch_lines_type {
      return Some(batch_lines_type)
    }
    if token == ndjson {
      saw_ndjson = true
    }
  }
  if saw_ndjson {
    Some(ndjson)
  } else {
    None
  }
}

///|
fn path_of(p : String) -> String {
  match p.find("?") {
    Some(at) => p.unsafe_substring(start=0, end=at)
    None => p
  }
}

///|
/// One answer of a batch as it is said: its body as it is where it is JSON, else as a string.
fn batch_line(a : Answer) -> String {
  let (text, is_json) = match a.body {
    Whole(b) => {
      let t = utf8_text(b)
      (
        t,
        a.headers.get("content-type").unwrap_or("").has_prefix("application/json") &&
        t != "",
      )
    }
    _ => ("", false)
  }
  "{\"status\":\{a.status},\"body\":\{if is_json { text } else { stringify(js(text)) }}}"
}

///|
/// A chat handed from here: `handed:` and its workspace (store/rows.ts `handedWs`).
pub fn handed_ws(ws : String) -> String {
  "handed:" + ws
}

///|
/// Whether a viewer sees what is of workspace `ws` (null: the home one's) (store/rows.ts `sees`).
pub fn sees(viewer : JV, ws : JV) -> Bool {
  let vws = jget(Some(viewer), "workspace").unwrap_or(jundef)
  let same = match (ws, vws) {
    (Str(a), Str(b)) => a == b
    (Null, Null) => true
    _ => false
  }
  same || (ws is Null && !(jget(Some(viewer), "home") is Some(Bool(false))))
}

///|
/// Whether `viewer` sees a session (one not there: the home workspace's, but another station's task its workspace's).
pub async fn Admin::session_seen(
  self : Admin,
  viewer : JV,
  key : String,
) -> Bool {
  let ws = self.store("sessionWs", [js(key)])
  if !is_undef(ws) {
    return sees(viewer, ws)
  }
  // (none there: the home workspace's, but another station's task its workspace's: rows.ts `seesMissing`)
  match remote_ws(key) {
    Some(w) =>
      match jget(Some(viewer), "workspace") {
        Some(Str(v)) => v == w
        _ => false
      }
    None => sees(viewer, Null)
  }
}
///|
/// store/rows.ts `remoteWs` (readops `remote_ws`): the workspace another station's task runs for, by its job's session key
/// (`remote:<workspace>:<station>:<session>`, as `/^remote:([^:/]+):[^:/]+:.+$/` reads it), none for any other key.
fn remote_ws(key : String) -> String? {
  @readops.remote_ws(key)
}

///|
/// Whether `viewer` sees a thread: one of its sessions is in their workspace (a thread with none: the home one's).
pub async fn Admin::thread_seen(self : Admin, viewer : JV, id : Double) -> Bool {
  let members = jitems(Some(self.store("threadSessions", [jnum(id)])))
  if members.length() == 0 {
    return sees(viewer, Null)
  }
  for m in members {
    if self.session_seen(viewer, jstr(jget(Some(m), "session")).unwrap_or("")) {
      return true
    }
  }
  false
}

///|
/// Whether `viewer` sees a job: its session is theirs.
pub async fn Admin::job_seen(self : Admin, viewer : JV, id : String) -> Bool {
  let job = self.store("getJob", [js(id)])
  nullish(job) ||
  self.session_seen(viewer, jstr(jget(Some(job), "sessionKey")).unwrap_or(""))
}

///|
let named_re : Re = re("^\\/*(sessions|threads|jobs)\\/+([^/]+)")

///|
let signed_int : Re = re("^[+-]?\\d+$")

///|
/// The thread id a path's segment is, where it is a safe integer.
pub fn thread_number(id : String) -> Double? {
  if !signed_int.matches(id) {
    return None
  }
  let n = js_number(id)
  if is_safe_integer(n) {
    Some(n)
  } else {
    None
  }
}

///|
/// The 404 a request is answered with when what its path names is there but of another workspace than the viewer's.
async fn Admin::elsewhere(self : Admin, path : String, viewer : JV) -> String? {
  guard named_re.exec(path) is Some(named) else { return None }
  let kind = named[1].unwrap()
  let id = segment(named[2].unwrap())
  match kind {
    "sessions" =>
      if !nullish(self.store("getSession", [js(id)])) &&
        !self.session_seen(viewer, id) {
        Some("unknown session \{id}")
      } else {
        None
      }
    "threads" =>
      match thread_number(id) {
        Some(n) =>
          if !nullish(self.store("getThread", [jnum(n)])) &&
            !self.thread_seen(viewer, n) {
            Some("unknown thread \{id}")
          } else {
            None
          }
        None => None
      }
    _ => if self.job_seen(viewer, id) { None } else { Some("no job \{id}") }
  }
}

///|
/// Where a chat a write's path names went, for a viewer it is not seen by here (api/seen.ts `went`).
async fn Admin::went(self : Admin, path : String, viewer : JV) -> JV? {
  guard named_re.exec(path) is Some(named) else { return None }
  let kind = named[1].unwrap()
  let id = segment(named[2].unwrap())
  let keys = if kind == "sessions" {
    [id]
  } else if kind == "threads" &&
    signed_int.matches(id) &&
    is_safe_integer(js_number(id)) {
    jitems(Some(self.store("threadSessions", [jnum(js_number(id))]))).map(m => {
      jstr(jget(Some(m), "session")).unwrap_or("")
    })
  } else {
    []
  }
  for key in keys {
    let h = self.store("handedTo", [js(key)])
    if nullish(h) {
      continue
    }
    let ws = self.store("sessionWs", [js(key)])
    let handed = match jstr(Some(ws)) {
      Some(w) => w.has_prefix(handed_ws(""))
      None => false
    }
    if !handed || !sees(viewer, h.get("ws").unwrap_or(Null)) {
      continue
    }
    return Some(
      jobj([
        ("session", js(key)),
        ("station", h.get("station").unwrap_or(Null)),
        ("thread", h.get("thread").unwrap_or(Null)),
        ("there", h.get("there").unwrap_or(Null)),
      ]),
    )
  }
  None
}

///|
/// A message's write kept under its key, as a hand-over carries it to the station its chat went to.
pub(all) struct KeptSend {
  viewer : String
  thread : Double
  key : String
  at : Double
  status : Int32
  headers : Map[String, String]
  /// base64
  body : String
}

///|
/// The messages written under a key to threads `threads` here (each to its id on the station it went to).
pub fn Admin::kept_sends(
  self : Admin,
  threads : Map[Double, Double],
) -> Array[KeptSend] {
  let out = []
  for k, slot in self.slots {
    guard slot.at is Some(at) else { continue }
    let parts = k.split("\u{0}").map(p => p.to_string()).collect()
    if parts.length() < 3 {
      continue
    }
    let (viewer, path, key) = (parts[0], parts[1], parts[2])
    guard send_path.exec(path) is Some(m) else { continue }
    let thread = js_number(percent_decode_uri(m[1].unwrap()))
    guard threads.get(thread) is Some(there) else { continue }
    guard slot.settled is Some(kept) else { continue }
    if kept.status < 200 || kept.status >= 300 {
      continue
    }
    out.push({
      viewer,
      thread: there,
      key,
      at,
      status: kept.status,
      headers: kept.headers,
      body: @base64.encode(kept.body),
    })
  }
  out
}

///|
/// What another station kept of the messages of a chat it handed here, kept here as if written here.
pub fn Admin::keep_sends(self : Admin, sends : Array[KeptSend]) -> Unit {
  for s in sends {
    let k = "\{s.viewer}\u{0}/threads/\{num_text(s.thread)}/messages\u{0}\{s.key}"
    match self.slots.get(k) {
      Some(had) =>
        if had.at is None {
          continue
        } else {
          match had.settled {
            Some(kept) if kept.status >= 200 && kept.status < 300 => continue
            _ => ()
          }
        }
      None => ()
    }
    let kept : Kept = {
      status: s.status,
      headers: s.headers,
      body: @base64.decode(s.body) catch {
        _ => b""
      },
    }
    let slot = {
      at: Some(s.at),
      answer: @effect.Deferred::new(),
      settled: Some(kept),
    }
    ignore(slot.answer.succeed(Some(kept)))
    self.slots[k] = slot
  }
}

///|
/// What `claimSay` answers: the first one's answer given again, a refusal, or the timestamp to write it at and what
/// to settle its key with once answered.
pub enum Claim {
  KeptAnswer(Kept)
  RefusedAnswer(Kept)
  Write(String, async (Kept?) -> Unit)
}

///|
fn kept_of(a : Answer) -> Kept {
  { status: a.status, headers: a.headers, body: a.whole().unwrap_or(b""), }
}

///|
/// A person's message the MoonBit program writes (mesh/served.ts `say`): as `once` keeps a keyed write's answer,
/// asked before it is written, with the timestamp it is written at and what to settle the key with once answered.
pub async fn Admin::claim_say(
  self : Admin,
  viewer : JV,
  path : String,
  key : String?,
  lang : String,
) -> Claim {
  if !self.setup.has("store") || !self.setup.has("agents") {
    return RefusedAnswer(kept_of(error(503, "station starting")))
  }
  let ws = jget(Some(viewer), "workspace")
  match ws {
    Some(Null) | None => ()
    Some(w) =>
      if self.backend.ask("hub.quietIn", [w]) is Bool(true) {
        return RefusedAnswer(
          kept_of(error(503, self.tr(lang, "station.retire.moving"))),
        )
      }
  }
  // (a chat handed to another station: answered where it went, never written here)
  match send_path.exec(path) {
    Some(m) => {
      let t = percent_decode_uri(m[1].unwrap())
      if re("^\\d+$").matches(t) {
        match self.moved_answer(js_number(t), lang) {
          Some(moved) => return RefusedAnswer(kept_of(moved))
          None => ()
        }
      }
    }
    None => ()
  }
  let next_ts = async fn() {
    jstr(Some(self.backend.ask("hub.nextTs", []))).unwrap_or("")
  }
  match key {
    None => return Write(next_ts(), async fn(_) {  })
    Some(k) if k == "" || k.length() > 200 =>
      return Write(next_ts(), async fn(_) {  })
    Some(_) => ()
  }
  let slot_key = "\{jstr(jget(Some(viewer), "email")).unwrap_or("")}\u{0}\{path}\u{0}\{key.unwrap()}"
  let now = self.now()
  self.sweep(now)
  while self.slots.get(slot_key) is Some(slot) {
    match slot.answer.wait() {
      Some(kept) =>
        return KeptAnswer({
          status: kept.status,
          headers: kept.headers.copy(),
          body: kept.body,
        })
      None => ()
    }
    if self.slots.get(slot_key) is Some(s) && physical_equal(s, slot) {
      self.slots.remove(slot_key)
    }
  }
  let slot = { at: None, answer: @effect.Deferred::new(), settled: None, }
  self.slots[slot_key] = slot
  let ts = next_ts()
  Write(ts, async fn(answer) {
    match answer {
      Some(a) if a.status < 500 => {
        slot.at = Some(self.now())
        slot.settled = Some(a)
        ignore(slot.answer.succeed(Some(a)))
      }
      _ => {
        ignore(slot.answer.succeed(None))
        if self.slots.get(slot_key) is Some(s) && physical_equal(s, slot) {
          self.slots.remove(slot_key)
        }
      }
    }
  })
}

///|
/// A person's message the MoonBit program wrote (`row`, as the entries table has it): told the store's followers and
/// delivered to the chat's sessions.
pub async fn Admin::said_elsewhere(
  self : Admin,
  thread : Double,
  n : Double,
  text : String,
  row : JV,
) -> Unit {
  if !self.setup.has("store") || !self.setup.has("agents") {
    return
  }
  let entry = self.backend.ask("rows.toEntry", [row])
  self.store("told", [
    jarr([
      jobj([
        ("type", js("thread")),
        ("id", jnum(thread)),
        ("entries", jarr([entry])),
      ]),
    ]),
  ])
  |> ignore
  let sessions = jitems(Some(self.store("threadSessions", [jnum(thread)]))).map(m => {
      jget(Some(m), "session").unwrap_or(Null)
    },
  )
  self.backend.tell("hub.deliver", [
    jnum(thread),
    jnum(n),
    jarr(sessions),
    js(text),
  ])
}

///|
/// decodeURIComponent, lossily: a sequence that is no UTF-8 left as it is.
pub fn percent_decode_uri(s : String) -> String {
  match decode_uri_component(s) {
    Some(d) => d
    None => s
  }
}

///|
/// decodeURIComponent: None where it throws (a `%` not followed by two hex digits, bytes that are not UTF-8).
pub fn decode_uri_component(s : String) -> String? {
  @url.decode_uri_component(s)
}

///|
/// A callback given a part (`{"$fn": id}`), called as the part says (`Admin::called`).
pub fn Admin::callback(self : Admin, f : async (Array[JV]) -> Unit) -> JV {
  self.callback_answering(async fn(args) {
    f(args)
    jundef
  })
}

///|
/// A callback whose answer the part takes.
pub fn Admin::callback_answering(
  self : Admin,
  f : async (Array[JV]) -> JV,
) -> JV {
  self.state.callback_next += 1
  let id = self.state.callback_next
  self.state.callbacks[id] = f
  jobj([("$fn", jint(id))])
}

///|
/// A part calls back what it was given: its answer.
pub async fn Admin::called(self : Admin, id : Int32, args : Array[JV]) -> JV {
  match self.state.callbacks.get(id) {
    Some(f) => f(args)
    None => jundef
  }
}

///|
/// An answer a part made (`{status, headers, body}`, its body bytes or a stream).
pub fn Admin::answer_from(self : Admin, said : JV) -> Answer {
  let headers : Map[String, String] = {}
  for f in jfields(said.get("headers")) {
    headers[f.0] = js_string(Some(f.1))
  }
  let body = said.get("body").unwrap_or(Null)
  {
    status: jnumber(said.get("status")).unwrap_or(500.0).to_int(),
    headers,
    body: if body.get("$stream") is Some(id) {
      // (its reader gone: the stream let go at the backend, `$stream.stop`)
      Streamed(self.stream_of(body), async fn() {
        self.backend.tell("$stream.stop", [id]) catch {
          _ => ()
        }
      })
    } else {
      Whole(bytes_of(body).unwrap_or(b""))
    },
  }
}
