// A Comma connect (station/src/comma/surface.ts): the station as a computer of a Comma workspace, whose agents work in
// the Comma Tasks given to it. It connects out to Comma (`<server>/v1/connect`, the connector protocol, with the
// connector token Comma's still.fail plugin gave) and speaks the Tasks protocol Comma's own stations speak:
// - task.invite: a Task for an agent here. Answered with the session it is to be; the session is made as the first
//   Message of the Task comes.
// - task.put: the Task's Messages, each heard as a message of its thread (the Task, channel TASK), from the Comma
//   member who said it; what the session here posted itself, and what it answered already, is not heard again.
// - task.post (to Comma): what the agent says in the thread, and where its turn stands at its end (all_done,
//   need_help: stands_at); a card it asks with goes as Comma's question card. task.posted_file: Comma reads the files
//   of a post while it waits for it. task.file: a file of a Task's Message, read a part at a time.
// - task.status: where the session stands. task.leave: the Task runs elsewhere; the session leaves its thread.
// - task.hello: as it connects, the Tasks it takes part in and how far it has each; Comma gives what it missed.
// - stats.index, task.index (to Comma): the workspace's statistics and its chats as Comma lists the Tasks its stations
//   host (stats.mbt), what Comma lacks of them a page at a time, as it connects and as they change.
// - task.read, task.say: the Router reads a chat of the Task index, or writes in it as itself (`chats`, module.mbt).
// Comma's heartbeat is answered with one. Whatever else Comma asks is refused.
//
// The socket, its dialing again and its heartbeat's watch are the connects' (connects/surface.ts ConnectedSurface): it
// hands this what Comma says (`message`), and says when a socket closed (`closed`).

///|
/// Comma's heartbeat comes every 15 seconds: a socket that said nothing for 45 is gone.
pub let ping_ms : Int = 15000

///|
pub let stale_ms : Int = 45000

///|
/// How long a request to Comma is waited for; a post that names files longer (Comma reads them from here first).
let request_ms : Int = 30000

///|
let file_post_ms : Int = 1800000

///|
/// Bytes one task.file or task.posted_file part carries at most (as Comma's stations: 256 KiB, base64).
let file_part : Int = 262144

///|
/// A post brings at most this many files.
let post_files : Int = 20

///|
/// The Tasks protocol it speaks: task.invite/put/post/hello.
let tasks_version : Int = 2

///|
/// Maximum number of workspace stations reported in capabilities.stillfail_workspace.
let max_workspace_stations : Int = 100

///|
/// Builds the capabilities.stillfail_workspace payload from a workspace membership and this station's id.
pub fn workspace_meta_of(m : J, self_id : String, fallback_host : String) -> J {
  let mp = Some(m)
  let self_name = match prop(mp, "name") {
    Some(Str(u)) if u != "" => u
    _ => fallback_host
  }
  let seen : Map[String, Int] = {}
  let mut stations : Array[(String, String)] = []
  match prop(mp, "peers") {
    Some(Arr(peers)) =>
      for p in peers {
        let pp = Some(p)
        guard prop(pp, "id") is Some(Str(id)) && id != "" else { continue }
        if seen.contains(id) {
          continue
        }
        let name = match prop(pp, "name") {
          Some(Str(n)) if n != "" => n
          _ => id
        }
        seen[id] = stations.length()
        stations.push((id, name))
      }
    _ => ()
  }
  if self_id != "" {
    match seen.get(self_id) {
      Some(idx) => stations[idx] = (self_id, self_name)
      None => stations.push((self_id, self_name))
    }
  }
  if stations.length() > max_workspace_stations {
    stations = stations[:max_workspace_stations].to_owned()
    if self_id != "" && !stations.iter().any(s => s.0 == self_id) {
      stations[max_workspace_stations - 1] = (self_id, self_name)
    }
  }
  let emoji = match prop(mp, "workspace_emoji") {
    Some(Str(e)) if e != "" => Some(jstr(e))
    _ => None
  }
  let icon = match prop(mp, "workspace_icon") {
    Some(Str(ic)) if ic != "" => Some(jstr(ic))
    _ => None
  }
  jo([
    ("id", Some(jstr(str_of(prop(mp, "workspace")).unwrap_or("")))),
    ("name", Some(jstr(str_of(prop(mp, "workspace_name")).unwrap_or("")))),
    ("station", Some(jstr(self_name))),
    ("emoji", emoji),
    ("icon", icon),
    ("stations", Some(Arr(stations.map(s => jobj([("id", jstr(s.0)), ("name", jstr(s.1))]))))),
  ])
}

///|
/// A Message's ts in its thread here: its seq at Comma, so what is given again is one message.
pub fn seq_ts(seq : Double) -> String {
  "\{num_text(seq)}.000000"
}

///|
/// `v[key]` where v is an object and it is a string, trimmed; "" else.
fn text(v : J?, key : String) -> String {
  match v {
    Some(Obj(_) | Arr(_)) =>
      match prop(v, key) {
        Some(Str(u)) => js_trim(u)
        _ => ""
      }
    _ => ""
  }
}

///|
/// A count: a safe integer of 0 or more.
fn count(v : J?) -> Double? {
  match v {
    Some(Num(n)) if safe_int(v) && n >= 0.0 => Some(if n == 0.0 { 0.0 } else { n })
    _ => None
  }
}

///|
/// A card as Comma's question card, where it is one: options, two to six of them (the recommended one marked). A text
/// card, or a single option, is said in the words alone.
pub fn question_of(card : J?, prompt : String) -> J? {
  if str_of(prop(card, "type")) != Some("options") {
    return None
  }
  guard prop(card, "options") is Some(Arr(all)) else { return None }
  let options = all.filter(o => match prop(Some(o), "label") {
    Some(Str(u)) => js_trim(u) != ""
    _ => false
  })
  if options.length() < 2 || options.length() > 6 {
    return None
  }
  let label = (o : J) => js_trim(str_of(prop(Some(o), "label")).unwrap_or(""))
  let said = js_trim(prompt)
  let prompt = if said != "" {
    said
  } else {
    options.map(o => str_of(prop(Some(o), "label")).unwrap_or("")).join(" / ")
  }
  Some(
    jobj([
      ("type", jstr("question")),
      ("prompt", jstr(first_points(prompt, 600))),
      (
        "choices",
        Arr(
          options.mapi((i, o) => {
            let oo = Some(o)
            jo([
              ("id", Some(jstr("o\{i + 1}"))),
              ("label", Some(jstr(first_points(label(o), 100)))),
              (
                "description",
                match prop(oo, "detail") {
                  Some(Str(u)) if js_trim(u) != "" => Some(jstr(first_points(js_trim(u), 300)))
                  _ => None
                },
              ),
              ("recommended", if prop(oo, "recommended") is Some(Bool(true)) { Some(Bool(true)) } else { None }),
            ])
          }),
        ),
      ),
      ("multi_select", Bool(false)),
      ("allow_other", Bool(true)),
    ]),
  )
}

///|
/// Bytes as base64 (`Buffer.toString("base64")`).
pub fn base64(b : Bytes) -> String {
  @codec.base64_encode(b)
}

///|
/// Base64 as node reads it (`Buffer.from(s, "base64")`): the URL-safe alphabet too, what is in neither skipped, up to
/// the first `=`.
pub fn unbase64(s : String) -> Bytes {
  @codec.base64_decode_loose(s)
}

///|
/// A file the station keeps for a post (store.ts Attachment, as far as a post reads it).
pub(all) struct Attachment {
  path : String
  name : String
  size : Double
}

///|
pub fn Attachment::of_j(v : J) -> Attachment {
  {
    path: str_of(prop(Some(v), "path")).unwrap_or(""),
    name: str_of(prop(Some(v), "name")).unwrap_or(""),
    size: num_of(prop(Some(v), "size")).unwrap_or(0.0),
  }
}

///|
/// A part of a file from `offset`, at most FILE_PART bytes (base64); `missing` when it is no longer there.
async fn read_part(io : Io, file : Attachment, offset : Double) -> J {
  match (io.file_part)(file.path, offset, file_part) {
    None => jobj([("missing", jstr("no longer on its station"))])
    Some((size, bytes)) =>
      jobj([("name", jstr(file.name)), ("size", Num(size)), ("offset", Num(offset)), ("data", jstr(base64(bytes)))])
  }
}

///|
/// A socket to Comma, as the connects give it: what it sends, and its close told.
pub(all) struct Socket {
  id : Int
  send : (String) -> Unit raise
  /// `socket.once("close", f)`: what it answers takes f off again (`socket.off`).
  on_close : (() -> Unit) -> () -> Unit
}

///|
/// The workspace's statistics and Task index a connect sends Comma (`Pick<CommaStats, "stats" | "tasks" | "start">`).
pub(all) struct CommaIndexes {
  stats : RevIndex
  tasks : RevIndex
  start : () -> Unit
}

///|
/// The chats of the Task index (a ref: chat_ref), as the Router reads one (`task.read`) and writes in it as itself
/// (`task.say`, once per key).
pub(all) struct CommaChats {
  read : async (String, Double, Double) -> J
  say : async (String, String, String, String, String) -> J
}

///|
/// What a connect asks of the station's store, its sessions' hub, and the names it keeps of people.
pub(all) struct SurfaceStore {
  /// `store.getSession(key)`: its row (`{key, running, ...}`), Null where there is none.
  get_session : async (String) -> J
  /// `store.pendingCount(key)`.
  pending_count : async (String) -> Double
  /// `store.threadAt(surface, channel, ts)`: its row (`{id, ...}`), Null where there is none.
  thread_at : async (String, String, String) -> J
  /// `store.leaveThread(thread, session)`.
  leave_thread : async (Double, String) -> Unit
  /// What the hub is handed (`Handler`): a message heard.
  handler : async (J) -> Unit
  /// `book.person(key, async () => person, changed)`: a person told; `book.person(key, async () => null)`: one known.
  book_person : (async (String, J) -> Unit)?
  book_known : (async (String) -> J)?
}

///|
/// A connect's surface's options.
pub(all) struct SurfaceOptions {
  connect : String
  /// Comma's address (`https://…`) and the connector token its still.fail plugin gave.
  server : String
  token : String
  /// What the station is called among the Group's computers.
  name : String
  /// The still.fail workspace the connect is of; None before the station is in one.
  workspace : String?
  /// The still.fail email of the person who owns this Comma connect, when known.
  owner_email : String?
  tasks : CommaTasks
  store : SurfaceStore
  /// The models its sessions can run (`{runtime, model}`).
  models : () -> Array[J]
  lang : String?
  /// The workspace's statistics and Task index it sends Comma; none, none are sent.
  stats : (() -> CommaIndexes raise)?
  /// The chats of the Task index as the Router reads and writes in them; none, it does neither.
  chats : CommaChats?
  /// Do not send an index while the previous process can still send its own.
  previous_exited : async () -> Unit
  /// The home workspace for this surface has not changed since it was created.
  in_scope : () -> Bool
  /// Metadata of this connect's still.fail workspace, reported in capabilities.stillfail_workspace.
  workspace_meta : (() -> J?)?
  /// Subscribes to workspace metadata changes so an open socket pushes updated metadata frames.
  on_workspace_meta_change : ((() -> Unit) -> () -> Unit)?
}

///|
priv struct Shared {
  task : String
  session : String
  seq : Double
  id : String?
  index : Double
}

///|
pub struct CommaSurface {
  id : String
  priv server : String
  priv token : String
  priv name : String
  priv of_workspace : String?
  priv owner_email : String?
  priv tasks : CommaTasks
  priv store : SurfaceStore
  priv models : () -> Array[J]
  priv lang : String
  priv stats : (() -> CommaIndexes raise)?
  priv chats : CommaChats?
  priv previous_exited : async () -> Unit
  priv in_scope : () -> Bool
  priv workspace_meta : (() -> J?)?
  priv on_workspace_meta_change : ((() -> Unit) -> () -> Unit)?
  priv io : Io
  priv runtime : @effect.Runtime
  /// Stays the same across the sockets of one process (Comma tells a process replaced from a socket dialed again).
  instance : String
  /// The socket now, once Comma said it is connected; and the requests to Comma waiting for their answer.
  priv mut socket_ : Socket?
  priv mut stop_workspace_meta : (() -> Unit)?
  priv mut last_metadata_json : String?
  priv waiting : Map[String, @effect.Deferred[J]]
  /// The people of the Tasks, as Comma said with their Messages.
  priv people : Map[String, J]
  /// The files of the posts Comma has not answered yet, by the post's key: it reads them (task.posted_file) first.
  priv posting : Map[String, (String, Array[Attachment])]
  /// The files of the Messages being heard, by the id they are named by here, until they are fetched.
  priv shared : Map[String, Shared]
  /// Per-connect handler supplied by `connects_hub` (overrides `store.handler` when set).
  priv mut handler : (async (J) -> Unit)?
}

///|
pub fn CommaSurface::new(options : SurfaceOptions, io : Io, runtime : @effect.Runtime) -> CommaSurface {
  {
    id: options.connect,
    server: options.server,
    token: options.token,
    name: options.name,
    of_workspace: options.workspace,
    owner_email: match options.owner_email {
      Some(u) => {
        let email = @jscase.lower(js_trim(u))
        if email_like(email) && email.length() <= max_text {
          Some(email)
        } else {
          None
        }
      }
      None => None
    },
    tasks: options.tasks,
    store: options.store,
    models: options.models,
    lang: options.lang.unwrap_or((io.lang)()),
    stats: options.stats,
    chats: options.chats,
    previous_exited: options.previous_exited,
    in_scope: options.in_scope,
    workspace_meta: options.workspace_meta,
    on_workspace_meta_change: options.on_workspace_meta_change,
    io,
    runtime,
    instance: (io.uuid)(),
    socket_: None,
    stop_workspace_meta: None,
    last_metadata_json: None,
    waiting: {},
    people: {},
    posting: {},
    shared: {},
    handler: None,
  }
}

///|
/// Sets the per-connect inbound message handler (e.g. from `connects_hub` / `WorkspaceConnects`).
pub fn CommaSurface::set_handler(self : CommaSurface, handler : async (J) -> Unit) -> Unit {
  self.handler = Some(handler)
}

// ── the connection ─────────────────────────────────────────────────────────────────────────────────────────────

///|
/// Who the connect is to the station (BotIdentity).
pub fn CommaSurface::identify(self : CommaSurface) -> J {
  jobj([
    ("team", jstr("Comma")),
    ("teamId", jstr("")),
    ("url", jstr(self.server)),
    ("botUserId", jstr("stillfail:\{self.id}")),
    ("botName", jstr(self.name)),
    ("botImage", Null),
    ("botId", jstr("")),
  ])
}

///|
/// Where the socket is dialed.
pub fn CommaSurface::address(self : CommaSurface) -> String raise {
  connect_url(self.server, self.name, self.of_workspace, self.io.platform, self.io.arch)
}

///|
/// The headers it dials with.
pub fn CommaSurface::headers(self : CommaSurface) -> Array[(String, String)] {
  [
    ("authorization", "Bearer \{self.token}"),
    ("x-salix-connector-instance-id", self.instance),
    ("user-agent", "stillfail-station/\{self.io.version}"),
  ]
}

///|
/// A frame of Comma's on `socket`, as text; `end` ends the socket (Comma's close).
pub fn CommaSurface::message(self : CommaSurface, socket : Socket, data : String, end : () -> Unit) -> Unit {
  let frame = try {
    parse_json(data)
  } catch {
    _ => return
  }
  self.frame(socket, frame, end)
}

///|
fn CommaSurface::is_now(self : CommaSurface, socket : Socket) -> Bool {
  self.socket_ is Some(s) && s.id == socket.id
}

///|
pub fn CommaSurface::frame(self : CommaSurface, socket : Socket, frame : J, end : () -> Unit) -> Unit {
  let f = Some(frame)
  match str_of(prop(f, "type")) {
    Some("connected") => {
      self.socket_ = Some(socket)
      self.io.info("connected to Comma", [
        ("connect", Some(jstr(self.id))),
        ("device", prop(f, "device_id")),
        ("run", prop(f, "connector_run_id")),
      ])
      self.connect_metadata()
      self.hello()
      if self.stats is Some(_) && (self.in_scope)() {
        ignore(
          self.runtime.fork_daemon("comma stats index", on_error=e => self.io.warn("the statistics index was not sent", [("connect", Some(jstr(self.id))), ("error", Some(jstr(message_of(e))))]), async fn() {
            self.send_index(socket, "stats.index", StatsWire)
          }),
        )
        ignore(
          self.runtime.fork_daemon("comma task index", on_error=e => self.io.warn("the task index was not sent", [("connect", Some(jstr(self.id))), ("error", Some(jstr(message_of(e))))]), async fn() {
            self.send_index(socket, "task.index", TaskWire)
          }),
        )
      }
    }
    Some("heartbeat") => self.send(jobj([("type", jstr("heartbeat"))]))
    Some("response") | Some("error") as kind => {
      let id = js_text(or_null(nullish(prop(f, "id"), Some(jstr("")))))
      guard self.waiting.get(id) is Some(w) else { return }
      self.waiting.remove(id)
      if kind == Some("response") {
        ignore(w.succeed(or_null(nullish(prop(f, "result"), None))))
      } else {
        ignore(
          w.fail(
            fail_(
              match prop(f, "error") {
                Some(Str(u)) => u
                _ => "Comma refused it"
              },
            ),
          ),
        )
      }
    }
    Some("request") => {
      let id = js_text(or_null(nullish(prop(f, "id"), Some(jstr("")))))
      let method = js_text(or_null(nullish(prop(f, "method"), Some(jstr("")))))
      let refuse = (error : Error) => {
        if !self.is_now(socket) {
          return
        }
        self.io.info("a request from Comma was refused", [
          ("connect", Some(jstr(self.id))),
          ("method", Some(jstr(method))),
          ("error", Some(jstr(message_of(error)))),
        ])
        self.send(jobj([("id", jstr(id)), ("type", jstr("error")), ("error", jstr(message_of(error)))]))
      }
      let params = or_null(nullish(prop(f, "params"), Some(Obj([]))))
      ignore(
        self.runtime.fork_daemon("comma request", on_error=e => refuse(e), async fn() {
          let result = try {
            Ok(self.handle(method, params))
          } catch {
            e => Err(e)
          }
          match result {
            Err(e) => refuse(e)
            Ok(result) => {
              if !self.is_now(socket) {
                return
              }
              if method == "task.read" && !(self.in_scope)() {
                refuse(fail_("the workspace changed while reading"))
                return
              }
              if self.is_now(socket) {
                self.send(jobj([("id", jstr(id)), ("type", jstr("response")), ("result", result)]))
              }
            }
          }
        }),
      )
    }
    Some("close") => end()
    _ => ()
  }
}

///|
/// The socket ended: what waited for Comma's answer is told it will not come.
pub fn CommaSurface::closed(self : CommaSurface) -> Unit {
  self.socket_ = None
  match self.stop_workspace_meta {
    Some(stop) => {
      stop()
      self.stop_workspace_meta = None
    }
    None => ()
  }
  self.last_metadata_json = None
  let ids = []
  for id, _ in self.waiting {
    ids.push(id)
  }
  for id in ids {
    match self.waiting.get(id) {
      Some(w) => {
        ignore(w.fail(fail_("Comma is not connected")))
        self.waiting.remove(id)
      }
      None => ()
    }
  }
}

///|
fn CommaSurface::connect_metadata(self : CommaSurface) -> Unit {
  self.send_metadata(true)
  if self.stop_workspace_meta is None {
    match self.on_workspace_meta_change {
      Some(listen) =>
        self.stop_workspace_meta = Some(
          listen(() => if self.socket_ is Some(_) && (self.in_scope)() { self.send_metadata(false) }),
        )
      None => ()
    }
  }
}

///|
fn CommaSurface::send_metadata(self : CommaSurface, force : Bool) -> Unit {
  if self.socket_ is None {
    return
  }
  let frame = jobj([
    ("type", jstr("metadata")),
    ("capabilities", self.capabilities()),
    ("skills", Arr([])),
    (
      "system_info",
      jobj([("os", jstr(self.io.platform)), ("arch", jstr(self.io.arch)), ("hostname", jstr(self.name))]),
    ),
  ])
  let json = stringify(frame)
  if !force && self.last_metadata_json == Some(json) {
    return
  }
  self.last_metadata_json = Some(json)
  self.send(frame)
}

///|
fn CommaSurface::send(self : CommaSurface, frame : J) -> Unit {
  match self.socket_ {
    Some(s) =>
      (s.send)(stringify(frame)) catch {
        e =>
          self.io.warn("a frame to Comma was not sent", [
            ("connect", Some(jstr(self.id))),
            ("error", Some(jstr(message_of(e)))),
          ])
      }
    None => ()
  }
}

///|
/// Asks Comma: what will be its answer, or why not (not connected, refused, no answer in time); the request is sent at
/// once.
fn CommaSurface::ask_start(self : CommaSurface, method : String, params : J, ms? : Int = request_ms) -> @effect.Deferred[J] raise {
  if self.socket_ is None {
    raise fail_(self.io.tr(self.lang, "station.comma.notConnected"))
  }
  let id = (self.io.uuid)()
  let answer : @effect.Deferred[J] = @effect.Deferred::new()
  self.waiting[id] = answer
  self.send(jobj([("id", jstr(id)), ("type", jstr("request")), ("method", jstr(method)), ("params", params)]))
  // Not answered in time: given up.
  ignore(
    (self.io.after)(ms, () => if self.waiting.get(id) is Some(w) {
      self.waiting.remove(id)
      ignore(w.fail(fail_("Comma did not answer \{method} in time")))
    }),
  )
  answer
}

///|
/// Asks Comma: its answer, or why not (not connected, refused, no answer in time).
async fn CommaSurface::ask(self : CommaSurface, method : String, params : J, ms? : Int = request_ms) -> J {
  self.ask_start(method, params, ms~).wait()
}

///|
/// What the computer says it can do: take Tasks, on these models.
fn CommaSurface::capabilities(self : CommaSurface) -> J {
  let models : Array[(String, J)] = []
  for m in (self.models)() {
    let runtime = js_text(or_null(prop(Some(m), "runtime")))
    let known = match entry_at(models, runtime) {
      Some(i) =>
        match models[i].1 {
          Arr(items) => items
          _ => []
        }
      None => {
        let items = []
        put_field(models, runtime, Arr(items))
        items
      }
    }
    match prop(Some(m), "model") {
      Some(Null) | None => ()
      Some(v) => if !known.iter().any(k => stringify(k) == stringify(v)) { known.push(v) }
    }
  }
  let meta : J? = if (self.in_scope)() {
    match self.workspace_meta {
      Some(f) => f()
      None => None
    }
  } else {
    None
  }
  jo([
    ("scope", Some(jstr(""))),
    ("persistent_processes", Some(Bool(false))),
    ("computer_use_tool", Some(Bool(false))),
    ("host_access_required", Some(Bool(false))),
    ("execution_boundary", Some(jstr("stillfail-connect"))),
    ("runtime_probe", Some(Bool(false))),
    ("tasks", Some(ji(tasks_version))),
    ("task_models", Some(Obj(models))),
    ("stats_index", if self.stats is Some(_) { Some(ji(1)) } else { None }),
    ("task_index", if self.stats is Some(_) { Some(ji(1)) } else { None }),
    ("stillfail_owner_email", self.owner_email.map(jstr)),
    ("stillfail_workspace", meta),
  ])
}

///|
/// Tells Comma it is here, and how far it has each Task it takes part in: Comma gives what it missed.
fn CommaSurface::hello(self : CommaSurface) -> Unit {
  let tasks = self.tasks
    .taking(self.id)
    .map(t => jobj([("task", jstr(t.task)), ("fetched", Num(t.fetched))]))
  let fail = (e : Error) => self.io.info("Comma was not told the station is here", [
    ("connect", Some(jstr(self.id))),
    ("error", Some(jstr(message_of(e)))),
  ])
  let asked = try {
    Ok(self.ask_start("task.hello", jobj([("tasks", Arr(tasks))])))
  } catch {
    e => Err(e)
  }
  match asked {
    Err(e) => fail(e)
    Ok(answer) => ignore(self.runtime.fork_daemon("comma answer", on_error=e => fail(e), async fn() { ignore(answer.wait()) catch { e => fail(e) } }))
  }
}

///|
/// The Comma codes an index's refusal is logged by; a peer's other text can contain private data.
let known_refusals : Array[String] = [
  "invalid_page", "page_too_large", "too_many_rows", "too_many_tasks", "not_this_group", "station_connection_changed",
]

///|
/// Keeps Comma's copy of an index current while `socket` is the connection: asks what Comma holds, sends what it lacks
/// a page at a time, and again a second after it changed. Comma answers `rate_limited` to more than a few pages a
/// second; any other refusal ends it until the next connection.
async fn CommaSurface::send_index(self : CommaSurface, socket : Socket, method : String, wire : Wire) -> Unit {
  let moved : Ref[@effect.Deferred[Unit]] = Ref(@effect.Deferred::new())
  let stop : Ref[() -> Unit] = Ref(() => ())
  let did_close = Ref(false)
  let live = () => !did_close.val && self.is_now(socket) && (self.in_scope)()
  let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
  let off = (socket.on_close)(() => {
    did_close.val = true
    ignore(closed.succeed(()))
  })
  ignore(off)
  let following : Ref[IndexSync?] = Ref(None)
  (async fn() {
    // An older process may still be sending the unscoped index. Clear or send ours only after it has exited.
    ignore(@effect.race(async fn() { (self.previous_exited)() }, async fn() { closed.wait() }))
    if !live() {
      return
    }
    guard self.stats is Some(of) else { return }
    // A scoped database may still be in use by the previous process; open and build it after handover.
    let indexes = of()
    (indexes.start)()
    let stats = if method == "stats.index" { indexes.stats } else { indexes.tasks }
    stop.val = stats.listen(() => ignore(moved.val.succeed(())))
    // An old sender uses the old epoch and does not register its readers here. Let it finish before this one resets.
    ignore(@effect.race(async fn() { (stats.ready)() }, async fn() { closed.wait() }))
    if !live() {
      return
    }
    let retry_wait = async fn(ms : Int) -> Bool {
      let open : @effect.Deferred[Bool] = @effect.Deferred::new()
      let cancel : Ref[() -> Unit] = Ref(() => ())
      let off : Ref[() -> Unit] = Ref(() => ())
      let finish = (o : Bool) => {
        (cancel.val)()
        (off.val)()
        ignore(open.succeed(o))
      }
      off.val = (socket.on_close)(() => finish(false))
      cancel.val = (self.io.after)(ms, () => finish(true)) // timer: retry a locked index with backoff
      if !live() {
        finish(false)
      }
      open.wait()
    }
    let read_index = async fn(read : () -> Page? raise) -> Page?? {
      let mut delay = 25
      while live() {
        let got = try {
          Ok(read())
        } catch {
          e => Err(e)
        }
        match got {
          Ok(v) => return Some(v)
          Err(e) => {
            if !@sql.busy(e) {
              raise e
            }
            // An old connection can hold the index during guard installation or acknowledgement. Retry that work,
            // with backoff, until it succeeds or this socket closes.
            if !retry_wait(delay) {
              return None
            }
            delay = if delay * 2 < 2000 { delay * 2 } else { 2000 }
          }
        }
      }
      None
    }
    let sync_ref : Ref[IndexSync?] = Ref(None)
    let started = read_index(fn() raise {
      sync_ref.val = Some(IndexSync::new(stats, wire~))
      None
    })
    guard started is Some(_) && sync_ref.val is Some(sync) else { return }
    following.val = Some(sync)
    let initial = read_index(fn() raise { Some(probe_page(stats)) })
    guard initial is Some(Some(first)) else { return }
    let mut page = first
    while live() {
      let answer = try {
        Ok(self.ask(method, page.to_j()))
      } catch {
        e => Err(e)
      }
      let answer = match answer {
        Ok(a) => a
        Err(e) => {
          let reason = message_of(e)
          if reason != "rate_limited" {
            if live() {
              self.io.info("an index was not sent", [
                ("connect", Some(jstr(self.id))),
                ("method", Some(jstr(method))),
                (
                  "error",
                  Some(
                    jstr(
                      if known_refusals.contains(reason) {
                        reason
                      } else {
                        "no answer or unrecognized refusal"
                      },
                    ),
                  ),
                ),
              ])
            }
            return
          }
          (self.io.sleep)(1000)
          continue
        }
      }
      if !live() {
        return
      }
      guard held_from(Some(answer)) is Some(held) else { return }
      let read = read_index(fn() raise { sync.next(held) })
      guard read is Some(next) else { return }
      match next {
        Some(p) => {
          page = p
          (self.io.sleep)(300)
          continue
        }
        None => ()
      }
      // Nothing more to send: until the statistics change, a second's changes together.
      ignore(@effect.race(async fn() { moved.val.wait() }, async fn() { closed.wait() }))
      moved.val = @effect.Deferred::new()
      (self.io.sleep)(1000)
      if !live() {
        return
      }
      let after_change = read_index(fn() raise {
        match sync.next(held) {
          Some(p) => Some(p)
          None => Some(probe_page(stats))
        }
      })
      guard after_change is Some(Some(p)) else { return }
      page = p
    }
  })() catch {
    e =>
      self.io.info("an index was not sent", [
        ("connect", Some(jstr(self.id))),
        ("method", Some(jstr(method))),
        ("error", Some(jstr(message_of(e)))),
      ])
  }
  (stop.val)()
  match following.val {
    Some(s) => s.close()
    None => ()
  }
}

// ── what Comma asks ────────────────────────────────────────────────────────────────────────────────────────────

///|
async fn CommaSurface::handle(self : CommaSurface, method : String, params : J) -> J {
  let p = Some(params)
  match method {
    "task.invite" => self.invited(params)
    "task.put" => self.put(params)
    "task.status" => self.standing(params)
    "task.leave" => self.leave(params)
    "task.posted_file" => self.posted_file(params)
    "task.read" => {
      guard self.chats is Some(chats) && (self.in_scope)() else {
        raise fail_("task.read is not something this station does in this workspace")
      }
      let after = match prop(p, "after") {
        Some(Num(n)) if n >= 0.0 => n
        _ => 0.0
      }
      let limit = match prop(p, "limit") {
        Some(Num(n)) if n > 0.0 => if n < 100.0 { n } else { 100.0 }
        _ => 100.0
      }
      let result = (chats.read)(text(p, "task"), after, limit)
      if !(self.in_scope)() {
        raise fail_("the workspace changed while reading")
      }
      result
    }
    "task.say" => {
      guard self.chats is Some(chats) && (self.in_scope)() else {
        raise fail_("task.say is not something this station does in this workspace")
      }
      let said = text(p, "text")
      if js_trim(said) == "" {
        raise fail_("text is required")
      }
      // As people see who writes: its Group (several Comma workspaces and Agent Swarms may write here).
      let who = match text(p, "requester_name") {
        "" =>
          match text(p, "requester") {
            "" => "Router"
            r => r
          }
        n => n
      }
      let result = (chats.say)(text(p, "task"), said, text(p, "key"), who, self.id)
      if !(self.in_scope)() {
        raise fail_("the workspace changed while writing")
      }
      result
    }
    _ => raise fail_("\{method} is not something a still.fail station does")
  }
}

///|
/// A Task's session here (hub.ts sessionKey).
fn CommaSurface::session(self : CommaSurface, thread_ts : String) -> String {
  "\{self.id}:\{task_channel}:\{thread_ts}"
}

///|
/// The model a Task asked for, as the station runs it: that runtime and model where a profile runs them, that
/// runtime's default where only the runtime is; none asked, the connect's own (None). Raises where it runs neither.
fn CommaSurface::choice(self : CommaSurface, start : Start) -> J? raise {
  guard start.runtime is Some(runtime) else { return None }
  let models = (self.models)().filter(m => str_of(prop(Some(m), "runtime")) == Some(runtime))
  if models.length() == 0 {
    raise fail_(self.io.tr(self.lang, "station.comma.noRuntime", args=[("runtime", runtime)]))
  }
  match start.model {
    Some(model) if models.iter().any(m => str_of(prop(Some(m), "model")) == Some(model)) =>
      Some(jobj([("runtime", jstr(runtime)), ("model", jstr(model))]))
    _ => Some(jobj([("runtime", jstr(runtime)), ("model", Null)]))
  }
}

///|
/// `text(v, key) || null`.
fn text_or_null(v : J?, key : String) -> String? {
  match text(v, key) {
    "" => None
    t => Some(t)
  }
}

///|
/// task.invite: the session the Task is to be here (made as its first Message is heard).
fn CommaSurface::invited(self : CommaSurface, params : J) -> J raise {
  let p = Some(params)
  let task = text(p, "task")
  if task == "" {
    raise fail_("task is required")
  }
  let s = match prop(p, "start") {
    Some(Obj(_)) as s => s
    _ => raise fail_("start is required")
  }
  let had = self.tasks.get(self.id, task)
  if prop(p, "replace") is Some(Bool(true)) {
    raise fail_(self.io.tr(self.lang, "station.comma.oneModel"))
  }
  let start : Start = {
    requester: text(s, "requester"),
    title: text_or_null(s, "title"),
    runtime: text_or_null(s, "runtime"),
    model: text_or_null(s, "model"),
  }
  ignore(self.choice(start))
  let t = match had {
    Some(h) if !h.left => h
    _ => Task::of_j(self.tasks.invited(self.id, task, start, count(prop(p, "answered")).unwrap_or(0.0)))
  }
  self.io.info("a Comma Task for an agent here", [
    ("connect", Some(jstr(self.id))),
    ("task", Some(jstr(task))),
    ("session", Some(jstr(self.session(t.thread_ts)))),
  ])
  jobj([("session", jstr(self.session(t.thread_ts))), ("thread", jstr("\{task_channel}/\{t.thread_ts}"))])
}

///|
/// Stable, by seq (Array.prototype.sort).
fn sort_by_seq(xs : Array[J]) -> Array[J] {
  if xs.length() <= 1 {
    return xs
  }
  let mid = xs.length() / 2
  let a = sort_by_seq(xs[0:mid].to_array())
  let b = sort_by_seq(xs[mid:].to_array())
  let out = []
  let mut i = 0
  let mut j = 0
  let seq = (v : J) => num_of(prop(Some(v), "seq")).unwrap_or(0.0)
  while i < a.length() && j < b.length() {
    if seq(b[j]) - seq(a[i]) < 0.0 {
      out.push(b[j])
      j += 1
    } else {
      out.push(a[i])
      i += 1
    }
  }
  while i < a.length() {
    out.push(a[i])
    i += 1
  }
  while j < b.length() {
    out.push(b[j])
    j += 1
  }
  out
}

///|
/// task.put: the Task's Messages, each heard in its thread here in order.
async fn CommaSurface::put(self : CommaSurface, params : J) -> J {
  let p = Some(params)
  let task = text(p, "task")
  guard self.tasks.get(self.id, task) is Some(t) else {
    return jobj([("unknown", Bool(true)), ("gone", Bool(true))])
  }
  if t.left {
    return jobj([("gone", Bool(true))])
  }
  let given = count(prop(p, "answered")).unwrap_or(0.0)
  let answered = js_max(t.answered, given)
  let session = self.session(t.thread_ts)
  let messages = sort_by_seq(
    arr_of(prop(p, "messages")).unwrap_or([]).filter(m => count(prop(Some(m), "seq")) is Some(_)),
  )
  let mut first = (self.store.get_session)(session) is Null
  for m in messages {
    let mm = Some(m)
    let seq = num_of(prop(mm, "seq")).unwrap_or(0.0)
    // What the session here said, and what it answered already, is not heard again.
    if seq <= answered || prop(prop(mm, "author"), "session") is Some(Str(_)) {
      continue
    }
    let said = str_of(prop(mm, "text")).unwrap_or("")
    let files = []
    for f in arr_of(prop(mm, "files")).unwrap_or([]) {
      let ff = Some(f)
      let name = match prop(ff, "name") {
        Some(Str(u)) if u.length() > 0 => u
        _ => continue
      }
      guard count(prop(ff, "index")) is Some(index) && count(prop(ff, "size")) is Some(size) else { continue }
      let id = "\{num_text(seq)}-\{num_text(index)}"
      self.shared[id] = { task, session, seq, id: str_of(prop(mm, "id")), index }
      files.push(jobj([("id", jstr(id)), ("name", jstr(name)), ("size", Num(size)), ("url", Null)]))
    }
    if said == "" && files.length() == 0 {
      continue
    }
    let user = self.learn(prop(mm, "author"))
    let model = if first { Some(self.choice(t.start)) } else { None }
    let event = jobj([
      ("type", jstr("message")),
      (
        "message",
        jo([
          ("channel", Some(jstr(task_channel))),
          ("threadTs", Some(jstr(t.thread_ts))),
          ("ts", Some(jstr(seq_ts(seq)))),
          ("user", Some(jstr(user))),
          ("text", Some(jstr(said))),
          ("addressed", Some(Bool(true))),
          ("files", Some(Arr(files))),
          ("model", model.bind(x => x)),
        ]),
      ),
    ])
    match self.handler {
      Some(h) => h(event)
      None => (self.store.handler)(event)
    }
    first = false
    for f in files {
      self.shared.remove(str_of(prop(Some(f), "id")).unwrap_or(""))
    }
  }
  self.tasks.given(self.id, task, count(prop(p, "through")), count(prop(p, "answered")))
  jobj([("through", count(prop(p, "through")).map(jn).unwrap_or(Null))])
}

///|
/// Who said a Message, by their id here (a person's Comma id; an agent's, its Router, `agent:<id>`), as Comma says.
async fn CommaSurface::learn(self : CommaSurface, author : J?) -> String {
  let kind = prop(author, "kind")
  let person_kind = str_of(kind) == Some("person")
  let id = match prop(author, "id") {
    Some(Str(u)) if u.length() > 0 => u
    _ => "comma"
  }
  let user = if person_kind { id } else { "agent:\{id}" }
  let name = match prop(author, "name") {
    Some(Str(u)) if u.length() > 0 => u
    _ => if person_kind { self.io.tr(self.lang, "station.comma.member") } else { "Comma" }
  }
  let person = jobj([
    ("name", jstr(name)),
    ("email", jstr(if person_kind { str_of(prop(author, "email")).unwrap_or("") } else { "" })),
    ("picture", jstr(str_of(prop(author, "picture")).unwrap_or(""))),
  ])
  self.people[user] = person
  match self.store.book_person {
    Some(f) => f("u:\{self.id}:\{user}", person)
    None => ()
  }
  user
}

///|
/// task.status: where the Task's session stands. A read.
async fn CommaSurface::standing(self : CommaSurface, params : J) -> J {
  let gone = jobj([("state", jstr("gone")), ("pending", ji(0)), ("for_ms", Null), ("last_failure", Null)])
  guard self.tasks.get(self.id, text(Some(params), "task")) is Some(t) && !t.left else { return gone }
  let row = (self.store.get_session)(self.session(t.thread_ts))
  // Invited, its first Message not heard yet: idle, waiting for it.
  if row is Null {
    return jobj([("state", jstr("idle")), ("pending", ji(0)), ("for_ms", Null), ("last_failure", Null)])
  }
  let running = match prop(Some(row), "running") {
    Some(Bool(b)) => b
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(Obj(_) | Arr(_)) => true
    _ => false
  }
  let pending = (self.store.pending_count)(js_text(or_null(prop(Some(row), "key"))))
  jobj([
    ("state", jstr(if running { "running" } else { "idle" })),
    ("pending", Num(pending)),
    ("for_ms", Null),
    ("last_failure", Null),
  ])
}

///|
/// task.leave: the Task runs elsewhere now. Its session leaves the thread; the thread stays, as what was said.
async fn CommaSurface::leave(self : CommaSurface, params : J) -> J {
  let task = text(Some(params), "task")
  guard self.tasks.get(self.id, task) is Some(t) else { return Obj([]) }
  self.tasks.left(self.id, task)
  let thread = (self.store.thread_at)(self.surface(), task_channel, t.thread_ts)
  if !(thread is Null) {
    (self.store.leave_thread)(num_of(prop(Some(thread), "id")).unwrap_or(0.0), self.session(t.thread_ts))
  }
  self.io.info("a Comma Task runs elsewhere now", [("connect", Some(jstr(self.id))), ("task", Some(jstr(task)))])
  Obj([])
}

///|
fn CommaSurface::surface(self : CommaSurface) -> String {
  "comma:\{self.id}"
}

///|
/// task.posted_file: a part of a file of a post Comma has not answered yet.
async fn CommaSurface::posted_file(self : CommaSurface, params : J) -> J {
  let p = Some(params)
  let posting = self.posting.get(text(p, "key"))
  let index = count(prop(p, "index"))
  match (posting, index) {
    (Some((task, files)), Some(i)) if task == text(p, "task") =>
      if i < files.length().to_double() {
        read_part(self.io, files[i.to_int()], count(prop(p, "offset")).unwrap_or(0.0))
      } else {
        jobj([("missing", jstr("no such file"))])
      }
    _ => jobj([("missing", jstr("no such post"))])
  }
}

// ── the surface ────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// A post in a Task's thread: its seq at Comma, as the ts the message is kept by here.
pub async fn CommaSurface::post(
  self : CommaSurface,
  channel : String,
  thread_ts : String,
  message : String,
  files : Array[Attachment],
  card? : J? = None,
) -> String {
  self.say(channel, thread_ts, message, files, card, None)
}

///|
/// Writes into the Task at Comma: its seq there, as the ts the message is kept by here.
async fn CommaSurface::say(
  self : CommaSurface,
  channel : String,
  thread_ts : String,
  message : String,
  files : Array[Attachment],
  card : J?,
  declared : String?,
) -> String {
  guard self.tasks.by_thread(self.id, thread_ts) is Some(t) else {
    raise fail_("no Comma Task \{channel}/\{thread_ts} here")
  }
  if files.length() > post_files {
    raise fail_("a post brings at most \{post_files} files")
  }
  let key = (self.io.uuid)()
  let question = question_of(card, message)
  let request = jo([
    ("task", Some(jstr(t.task))),
    ("session", Some(jstr(self.session(t.thread_ts)))),
    ("text", Some(jstr(message))),
    ("key", Some(jstr(key))),
    ("declared", Some(declared.map(jstr).unwrap_or(Null))),
    ("question", question),
    (
      "files",
      if files.length() > 0 {
        Some(
          Arr(
            files.mapi((index, f) => jobj([("index", ji(index)), ("name", jstr(f.name)), ("size", Num(f.size))])),
          ),
        )
      } else {
        None
      },
    ),
  ])
  if files.length() > 0 {
    self.posting[key] = (t.task, files)
  }
  let answer = try {
    Ok(self.ask("task.post", request, ms=if files.length() > 0 { file_post_ms } else { request_ms }))
  } catch {
    e => Err(e)
  }
  self.posting.remove(key)
  let answer = match answer {
    Ok(a) => a
    Err(e) => raise e
  }
  match count(prop(Some(answer), "seq")) {
    Some(seq) => seq_ts(seq)
    None => raise fail_("Comma answered without the Message's seq")
  }
}

///|
/// Where the turn stands at its end, written into the Task: Comma takes the Task as done, or as waiting for its people.
/// `kind`: "done", "need" or "left".
pub fn CommaSurface::stands_at(self : CommaSurface, channel : String, thread_ts : String, kind : String, words : String?) -> Unit {
  if kind == "left" {
    return
  }
  let said = match words {
    Some(w) if js_trim(w) != "" => js_trim(w)
    _ => self.io.tr(self.lang, if kind == "done" { "station.comma.done" } else { "station.comma.need" })
  }
  ignore(
    self.runtime.fork_daemon("comma turn state", on_error=_ => (), async fn() {
      ignore(
        self.say(channel, thread_ts, said, [], None, Some(if kind == "done" { "all_done" } else { "need_help" })),
      ) catch {
        e =>
          self.io.warn("where a turn stands was not said in its Comma Task", [
            ("connect", Some(jstr(self.id))),
            ("thread", Some(jstr(thread_ts))),
            ("error", Some(jstr(message_of(e)))),
          ])
      }
    }),
  )
}

///|
/// A file of a Task's Message, read from Comma a part at a time.
pub async fn CommaSurface::download(self : CommaSurface, file_id : String, file_name : String, size : Double) -> Bytes {
  guard self.shared.get(file_id) is Some(at) else { raise fail_("no such file of the Task") }
  let out = @buffer.new()
  let mut have = 0.0
  while have < size {
    let answer = self.ask(
      "task.file",
      jo([
        ("task", Some(jstr(at.task))),
        ("session", Some(jstr(at.session))),
        ("seq", Some(Num(at.seq))),
        ("id", match at.id { Some(i) if i != "" => Some(jstr(i)); _ => None }),
        ("index", Some(Num(at.index))),
        ("offset", Some(Num(have))),
      ]),
    )
    let a = Some(answer)
    match prop(a, "missing") {
      Some(Str(u)) => raise fail_(u)
      _ => ()
    }
    let data = match prop(a, "data") {
      Some(Str(u)) => Some(unbase64(u))
      _ => None
    }
    match data {
      Some(d) if count(prop(a, "offset")) == Some(have) &&
        d.length() > 0 &&
        have + d.length().to_double() <= size => {
        out.write_bytes(d)
        have = have + d.length().to_double()
      }
      _ => raise fail_("Comma gave a wrong part of \{file_name} at \{num_text(have)}")
    }
  }
  out.to_bytes()
}

///|
/// A Task has no link of its own here: the session's page is not said in it.
pub fn CommaSurface::session_link(_self : CommaSurface) -> String? {
  None
}

///|
pub async fn CommaSurface::mention(self : CommaSurface, user : String) -> String {
  let name = match prop(self.people.get(user), "name") {
    Some(Null) | None =>
      match prop(Some(self.known_person(user)), "name") {
        Some(Null) | None => jstr(user)
        Some(n) => n
      }
    Some(n) => n
  }
  "@" + js_text(name)
}

///|
/// A person as Comma said them or the names kept say them; Null where neither knows them.
pub async fn CommaSurface::known_person(self : CommaSurface, user : String) -> J {
  match self.people.get(user) {
    Some(p) => p
    None =>
      match self.store.book_known {
        Some(f) => f("u:\{self.id}:\{user}")
        None => Null
      }
  }
}

///|
pub fn CommaSurface::look_up(self : CommaSurface, user : String) -> J {
  self.people.get(user).unwrap_or(Null)
}

///|
/// The person Comma said by an email (a lowercase one), by their id here.
pub fn CommaSurface::look_up_email(self : CommaSurface, email : String) -> String? {
  for user, p in self.people {
    if @jscase.lower(str_of(prop(Some(p), "email")).unwrap_or("")) == email {
      return Some(user)
    }
  }
  None
}

///|
/// What the station calls itself to Comma on this connect.
pub fn CommaSurface::name(self : CommaSurface) -> String {
  self.name
}

///|
/// The workspace the connect is of.
pub fn CommaSurface::of_workspace(self : CommaSurface) -> String? {
  self.of_workspace
}
