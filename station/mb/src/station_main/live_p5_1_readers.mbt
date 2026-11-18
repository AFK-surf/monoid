// P5-1's readers (services.ts Readers, read/pool.ts, read/mb-reader.ts, read/requested-builder.ts): the program's own
// processes (`--data`, each a read-only connection), asked a line of JSON and answering one (a line that says `bytes`
// followed by its body), in lines that share none of them: the store's log written into the database (`log`, the
// checkpoint `CheckpointsLive` asks for as the store changes), the pages of sessions' histories (`pages`), and every
// other read (`moved`), what devices ask and what the station tells alike; a reader idle a minute let go but the first.
// A read refused while old state it needs is prepared has it prepared by its builder (`--builder <name>`, the readers'
// `prepare*`) and is asked again; the old lookups a store from before needs are built in the background once the
// process before is gone (store/legacy-said-builder.ts).

///|
pub(all) suberror ReadFailed {
  ReadFailed(Int, String)
}

///|
pub impl Show for ReadFailed with output(self, logger) {
  match self {
    ReadFailed(status, m) => logger.write_string("\{status} \{m}")
  }
}

// ── a program's process, its lines both ways ──

///|
priv struct MbProc {
  proc : Proc
  said : @effect.Queue[(Json, Bytes?)]
  ended : @effect.Deferred[Unit]
  mut gone : Bool
}

///|
/// The program (`argv0`, this one) with `args`, read a line (and its body) at a time.
fn mb_spawn(host : @host.Host, program : String, args : Array[String], stderr? : Sink = Ignored) -> MbProc raise SysError {
  let proc = spawn(host, program, args, stdin_piped=true, stdout=Piped, stderr~)
  let p : MbProc = { proc, said: @effect.Queue::unbounded(), ended: @effect.Deferred::new(), gone: false }
  ignore(
    host.rt.fork(name="mb program", async fn() {
      let carry = @buffer.new()
      let mut head : Json? = None
      let mut wanted = 0
      let body = @buffer.new()
      while true {
        match proc.events.take() {
          Out(bytes) => {
            let mut at = 0
            while at < bytes.length() {
              match head {
                Some(h) => {
                  let take = if wanted - body.length() < bytes.length() - at { wanted - body.length() } else { bytes.length() - at }
                  body.write_bytesview(bytes[at:at + take])
                  at += take
                  if body.length() >= wanted {
                    ignore(p.said.try_offer((h, Some(body.to_bytes()))))
                    body.reset()
                    head = None
                  }
                }
                None => {
                  let mut nl = -1
                  for i = at; i < bytes.length(); i = i + 1 {
                    if bytes[i] == b'\n' {
                      nl = i
                      break
                    }
                  }
                  if nl < 0 {
                    carry.write_bytesview(bytes[at:])
                    at = bytes.length()
                  } else {
                    carry.write_bytesview(bytes[at:nl])
                    at = nl + 1
                    let line = @utf8.decode_lossy(carry.to_bytes())
                    carry.reset()
                    match (try { Ok(@json.parse(line)) } catch { e => Err(e) }) {
                      Ok({ "bytes": Number(n, ..), .. } as h) if n > 0.0 => {
                        head = Some(h)
                        wanted = n.to_int()
                      }
                      Ok({ "bytes": Number(_, ..), .. } as h) => ignore(p.said.try_offer((h, Some(b""))))
                      Ok(h) => ignore(p.said.try_offer((h, None)))
                      Err(_) => ()
                    }
                  }
                }
              }
            }
          }
          Err(_) => ()
          Exit(_, _) => break
        }
      }
      p.gone = true
      ignore(p.ended.succeed(()))
      p.said.shutdown()
    }),
  )
  p
}

///|
fn MbProc::post(self : MbProc, message : Json) -> Bool {
  !self.gone && self.proc.write(@utf8.encode(message.stringify() + "\n"))
}

///|
fn MbProc::stop(self : MbProc) -> Unit {
  if !self.gone {
    self.proc.end_input()
    ignore(kill(self.proc.pid, "SIGTERM"))
  }
}

///|
/// What it says next (None: it ended).
async fn MbProc::next(self : MbProc) -> (Json, Bytes?)? {
  match (try { Ok(self.said.take()) } catch { e => Err(e) }) {
    Ok(m) => Some(m)
    Err(_) => None
  }
}

// ── the readers ──

///|
/// A read waiting or held.
priv struct Asked {
  id : Int
  ask : Json
  op : String
  background : Bool
  answer : @effect.Deferred[Result[Bytes, (Int, String)]]
}

///|
priv struct Slot {
  proc : MbProc
  mut held : Asked?
  mut idle_since : Int64
  /// The model catalog's version this reader was last given (read/pool.ts `Slot.catalogVersion`).
  mut catalog_version : Double
}

///|
priv struct Line {
  name : String
  size : Int
  slots : Array[Slot]
  waiting : Array[Asked]
}

///|
priv struct Readers {
  host : @host.Host
  program : String
  data : String
  db : String
  moved : Line
  pages : Line
  log : Line
  mut next : Int
  mut closed : Bool
  /// People's names as their credentials say them, given to every read (the admin API's `readers.names`).
  names : Map[String, String]
  /// What only the hub knows, given to every read (its processes' states, its clients' keys).
  mut processes : async () -> Json
  mut client_keys : async () -> Json
  /// The model catalog now ({ version, models }), given to a reader with a read when it changed: its prices are the
  /// usage page's (readops `price`).
  mut catalog : () -> Json
  builders : Map[String, Requested]
  mut checkpointing : Bool
  mut again : Bool
  stops : Array[() -> Unit]
  /// The process before this one gone (what only one process may build waits on it).
  previous_gone : Ref[async () -> Unit]
}

///|
/// The reads the program answers itself (pool.ts MOVED) and its histories' (HISTORY): every read there is.
let reads_moved : Array[String] = [
  "job", "jobLog", "historyPendingCard", "statePendingCard", "deliveryCardState", "reviewPendingCard", "stateQuestion",
  "pendingDeliveries", "latestMessages", "chatHistoryMessages", "openedChatSaid", "widgetState", "transcriptFile",
  "memory", "machineSessions", "machineSession", "sessionsAtWork", "policyChecks", "recentConnectPeople", "usageTurns",
  "usageCalls", "outflowMessages", "archiveLook", "recentChatList", "searchChatList", "threadList", "sharedOf",
  "sharedChats", "chatMarks", "entries", "letters", "summary", "sessions", "session", "threads", "thread",
  "turnNotices", "saidNotices", "chats", "chatRows", "outflowChats", "openJobs", "resourceChats", "usage",
  "outflowUsage", "sessionPlace", "changed", "tailRead", "internalCardEditPage", "internalCardMessagePage",
]

///|
let reads_history : Array[String] = ["timeline", "transcriptState"]

///|
/// The reads given their words and the time (pool.ts WORDED), and those whose words the station says itself (SAID).
let reads_worded : Array[String] = [
  "sharedOf", "sharedChats", "chatMarks", "entries", "letters", "summary", "sessions", "session", "threads", "thread",
  "turnNotices", "saidNotices", "chats", "chatRows", "outflowChats", "openJobs", "resourceChats", "usage",
]

///|
let reads_interactive : Array[String] = [
  "thread", "chats", "chatMarks", "session", "summary", "latestMessages", "openedChatSaid", "chatHistoryMessages",
  "historyPendingCard", "stateQuestion", "statePendingCard", "deliveryCardState", "job",
]

///|
fn words_in(op : String, lang : String) -> Json {
  if op == "turnNotices" || op == "saidNotices" {
    {
      "localPage": Json::string(tr(lang, "station.creator.localPage")),
      "admin": Json::string(tr(lang, "station.author.admin")),
      "file": Json::string(tr(lang, "station.notice.file")),
      "untitled": Json::string(tr(lang, "station.chat.untitled")),
    }
  } else if op == "outflowChats" {
    {
      "localPage": Json::string(tr(lang, "station.creator.localPage")),
      "admin": Json::string(tr(lang, "station.author.admin")),
      "untitled": Json::string(tr(lang, "station.chat.untitled")),
      "directMessage": Json::string(tr(lang, "station.chat.directMessage")),
    }
  } else {
    Json::object({})
  }
}

///|
fn with_fields(args : Json, more : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = match args {
    Object(o) => o.copy()
    _ => {}
  }
  for kv in more {
    m[kv.0] = kv.1
  }
  Json::object(m)
}

///|
/// What a read is given beside its own args (pool.ts `enqueue`'s `given`).
fn given_args(op : String, args : Json, lang : String) -> Json {
  let now = Json::number(wall_ms().to_double())
  if op == "machineSessions" || op == "machineSession" {
    let home = env_get("HOME").unwrap_or(".")
    let codex = match env_get("CODEX_HOME") {
      Some(c) if c != "" => c
      _ => path([home, ".codex"])
    }
    with_fields(args, [("roots", { "claude": Json::string(path([home, ".claude", "projects"])), "codex": Json::string(path([codex, "sessions"])) })])
  } else if op == "sessionPlace" {
    with_fields(args, [
      (
        "env",
        { "home": Json::string(env_get("HOME").unwrap_or("")), "homedir": Json::string(homedir()), "mac": Json::boolean(platform() == "darwin") },
      ),
      ("now", now),
    ])
  } else if op == "changed" {
    match args {
      { "op": String(inner), .. } if reads_worded.contains(inner) => {
        let a = match args {
          Object(m) => m.get("args").unwrap_or(Json::object({}))
          _ => Json::object({})
        }
        with_fields(args, [("args", with_fields(a, [("words", words_in(inner, lang)), ("now", now)]))])
      }
      _ => args
    }
  } else if reads_worded.contains(op) {
    with_fields(args, [("words", words_in(op, lang)), ("now", now)])
  } else {
    args
  }
}

///|
fn Readers::new(host : @host.Host, program : String, data : String) -> Readers {
  let size = match env_get("STILLFAIL_READERS").bind(s => attempt(() => @string.parse_int(s)).to_option()) {
    Some(n) if n > 0 => n
    _ => {
      let cpus = match machine() {
        { "cpus": Array(c), .. } => c.length()
        _ => 2
      }
      if cpus - 1 < 1 { 1 } else if cpus - 1 > 2 { 2 } else { cpus - 1 }
    }
  }
  {
    host,
    program,
    data,
    db: path([data, "stillfail.db"]),
    moved: { name: "moved", size, slots: [], waiting: [] },
    pages: { name: "pages", size: 2, slots: [], waiting: [] },
    log: { name: "log", size: 1, slots: [], waiting: [] },
    next: 0,
    closed: false,
    names: {},
    processes: async fn() { Json::array([]) },
    client_keys: async fn() { Json::array([]) },
    catalog: () => { "version": Json::number(0.0), "models": Json::object({}) },
    builders: {},
    checkpointing: false,
    again: false,
    stops: [],
    previous_gone: Ref(async fn() {  }),
  }
}

///|
/// A reader of `line` started, answering what it is given until it ends.
fn Readers::start(self : Readers, line : Line) -> Slot? {
  let proc = mb_spawn(self.host, self.program, ["--data", self.data]) catch {
    SysError(e) => {
      p51_log("ERROR", "readers", "a reader did not start", fields={ "error": Json::string(e) })
      return None
    }
  }
  let slot : Slot = { proc, held: None, idle_since: @host.now(), catalog_version: 0.0 }
  line.slots.push(slot)
  ignore(
    self.host.rt.fork(name="reader", async fn() {
      while proc.next() is Some((said, body)) {
        if said is { "ready": _, .. } {
          continue
        }
        guard slot.held is Some(asked) else { continue }
        let id = match said {
          { "id": Number(n, ..), .. } => n.to_int()
          _ => -1
        }
        if id != asked.id {
          continue
        }
        slot.held = None
        slot.idle_since = @host.now()
        let answer : Result[Bytes, (Int, String)] = match (body, said) {
          (Some(b), _) => Ok(b)
          (None, { "text": String(t), .. }) => Ok(@utf8.encode(t))
          (None, _) => {
            let status = match said {
              { "status": Number(s, ..), .. } => s.to_int()
              _ => 500
            }
            let m = match said {
              { "error": String(e), .. } => e
              _ => "read failed"
            }
            Err((status, m))
          }
        }
        ignore(asked.answer.succeed(answer))
        self.pump(line)
      }
      // (it ended: what it held failed, the next read starts another)
      match line.slots.search_by(s => physical_equal(s, slot)) {
        Some(i) => ignore(line.slots.remove(i))
        None => ()
      }
      match slot.held {
        Some(asked) => ignore(asked.answer.succeed(Err((500, "the reader stopped"))))
        None => ()
      }
      slot.held = None
      self.pump(line)
    }),
  )
  Some(slot)
}

///|
/// Reads in line go to its readers free, an interactive or a checkpoint first; a background one after the rest.
fn Readers::pump(self : Readers, line : Line) -> Unit {
  if self.closed {
    return
  }
  while line.waiting.length() > 0 {
    let first = line.waiting.search_by(a => !a.background && (reads_interactive.contains(a.op) || a.op == "checkpoint"))
    let fore = line.waiting.search_by(a => !a.background)
    let at = match (first, fore) {
      (Some(i), _) => i
      (None, Some(i)) => i
      (None, None) =>
        if line.slots.iter().any(s => s.held is Some(h) && h.background) {
          break
        } else {
          0
        }
    }
    let free = match line.slots.search_by(s => s.held is None) {
      Some(i) => Some(line.slots[i])
      None => if line.slots.length() < line.size { self.start(line) } else { None }
    }
    guard free is Some(slot) else { break }
    let asked = line.waiting.remove(at)
    slot.held = Some(asked)
    if !slot.proc.post(self.with_catalog(slot, asked.ask)) {
      slot.held = None
      ignore(asked.answer.succeed(Err((500, "the reader stopped"))))
    }
  }
}

///|
/// `ask` with the model catalog where it changed since this reader was last given it (read/pool.ts `give`).
fn Readers::with_catalog(self : Readers, slot : Slot, ask : Json) -> Json {
  guard (self.catalog)() is { "version": Number(version, ..), "models": models, .. } && version != slot.catalog_version &&
    ask is Object(fields) else {
    return ask
  }
  slot.catalog_version = version
  let given = fields.copy()
  given["catalog"] = models
  Json::object(given)
}

///|
/// The answer to `op`, as the program gave it (bytes of JSON).
async fn Readers::read_bytes(self : Readers, op : String, args : Json, lang : String, background? : Bool = false) -> Bytes {
  let mut tries = 0
  while true {
    match (try { Ok(self.enqueue(op, args, lang, background)) } catch { e => Err(e) }) {
      Ok(b) => return b
      Err(ReadFailed(status, m)) if tries < 20 && self.prepare_for(m, args) is Some(prepare) => {
        tries += 1
        prepare() catch {
          e => raise ReadFailed(503, "\{e}")
        }
        ignore(status)
      }
      Err(e) => raise e
    }
  }
  raise ReadFailed(502, "station stopping")
}

///|
async fn Readers::read(self : Readers, op : String, args : Json, lang : String, background? : Bool = false) -> Json {
  let bytes = self.read_bytes(op, args, lang, background~)
  @json.parse(@utf8.decode_lossy(bytes)) catch {
    _ => Json::string(@utf8.decode_lossy(bytes))
  }
}

///|
async fn Readers::enqueue(self : Readers, op : String, args : Json, lang : String, background : Bool) -> Bytes {
  if self.closed {
    raise ReadFailed(502, "station stopping")
  }
  let history = reads_history.contains(op)
  if op != "checkpoint" && !history && !reads_moved.contains(op) {
    raise ReadFailed(500, "no read \{op}")
  }
  let line = if op == "checkpoint" { self.log } else if history { self.pages } else { self.moved }
  self.next += 1
  let names = Json::array(self.names.to_array().map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)])))
  let ask : Json = {
    "id": Json::number(self.next.to_double()),
    "op": Json::string(op),
    "args": if line.name == "moved" { given_args(op, args, lang) } else { args },
    "lang": Json::string(lang),
    "names": names,
    "processes": (self.processes)() catch { _ => Json::array([]) },
    "clientKeys": (self.client_keys)() catch { _ => Json::array([]) },
  }
  let asked : Asked = { id: self.next, ask, op, background, answer: @effect.Deferred::new() }
  if op == "checkpoint" {
    line.waiting.insert(0, asked)
  } else {
    line.waiting.push(asked)
  }
  self.pump(line)
  match asked.answer.wait() {
    Ok(b) => b
    Err((status, m)) => raise ReadFailed(status, m)
  }
}

///|
/// The store changed: its log written into the database shortly, by the log's reader, at most once each 2 s
/// (pool.ts `checkpointSoon`).
fn Readers::checkpoint_soon(self : Readers) -> Unit {
  if self.closed {
    return
  }
  if self.checkpointing {
    self.again = true
    return
  }
  self.checkpointing = true
  self.again = false
  ignore(
    self.host.rt.fork(name="checkpoint", async fn() {
      @effect.sleep(2000) // timer: a debounce of a burst (pool.ts CHECKPOINT_MS)
      ignore(self.read("checkpoint", Json::object({}), "en")) catch {
        e => p51_log("WARN", "readers", "the database's log not written into it", fields={ "error": Json::string("\{e}") })
      }
      self.checkpointing = false
      if self.again {
        self.checkpoint_soon()
      }
    }),
  )
}

///|
/// Readers idle a minute let go, but the first of what devices ask (pool.ts `letGoLater`, `kept`).
fn Readers::let_go_idle(self : Readers) -> Unit {
  let now = @host.now()
  for line in [self.moved, self.pages, self.log] {
    let idle = line.slots.filter(s => s.held is None && now - s.idle_since > 60000L)
    for s in idle {
      if line.name == "moved" && line.slots.length() > 0 && physical_equal(line.slots[0], s) {
        continue
      }
      match line.slots.search_by(x => physical_equal(x, s)) {
        Some(i) => ignore(line.slots.remove(i))
        None => ()
      }
      s.proc.stop()
    }
  }
  for name, b in self.builders {
    ignore(name)
    b.let_go_idle(now)
  }
}

///|
/// Short of memory: every reader and builder that answers nothing let go (pool.ts `trimIdle`), a count of them. A line
/// with reads waiting keeps its readers.
fn Readers::trim_idle(self : Readers) -> Int {
  if self.closed {
    return 0
  }
  let mut trimmed = 0
  for line in [self.moved, self.pages, self.log] {
    if line.waiting.length() > 0 {
      continue
    }
    for s in line.slots.filter(s => s.held is None) {
      match line.slots.search_by(x => physical_equal(x, s)) {
        Some(i) => ignore(line.slots.remove(i))
        None => ()
      }
      s.proc.stop()
      trimmed += 1
    }
  }
  for _, b in self.builders {
    if !b.running && b.waiting.length() == 0 && b.proc is Some(p) {
      p.stop()
      b.proc = None
      trimmed += 1
    }
  }
  trimmed
}

///|
/// The readers' and builders' processes running (resources' `programs`: the station's own memory).
fn Readers::pids(self : Readers) -> Array[Int] {
  let out : Array[Int] = []
  for line in [self.moved, self.pages, self.log] {
    for s in line.slots {
      if !s.proc.gone {
        out.push(s.proc.proc.pid)
      }
    }
  }
  for _, b in self.builders {
    match b.proc {
      Some(p) if !p.gone => out.push(p.proc.pid)
      _ => ()
    }
  }
  out
}

///|
fn Readers::close(self : Readers) -> Unit {
  self.closed = true
  for f in self.stops {
    f()
  }
  for line in [self.moved, self.pages, self.log] {
    for a in line.waiting {
      ignore(a.answer.succeed(Err((502, "station stopping"))))
    }
    line.waiting.clear()
    for s in line.slots {
      s.proc.stop()
    }
  }
  for _, b in self.builders {
    b.close()
  }
}

// ── old state prepared by its builders, as a read asks ──

///|
/// A builder of old state asked for items (read/requested-builder.ts): one process, an item at a time, each answered
/// `{done}` (not done: asked again after a pause), `{error}`, `{fallback}` (the writer repairs first), or asking the
/// backfill's permit (`{take}`: given at once, the station's writer being this process's alone).
priv struct Requested {
  readers : Readers
  args : Array[String]
  message : (Json) -> Json
  repair : (() -> Unit raise)?
  waiting : Array[(Json, @effect.Deferred[Result[Unit, String]])]
  mut proc : MbProc?
  mut running : Bool
  mut last : Int64
}

///|
fn Readers::builder(
  self : Readers,
  name : String,
  message : (Json) -> Json,
  repair? : () -> Unit raise,
  program? : String,
) -> Requested {
  match self.builders.get(name) {
    Some(b) => b
    None => {
      let b : Requested = {
        readers: self,
        args: ["--builder", program.unwrap_or(name), "--db", self.db],
        message,
        repair,
        waiting: [],
        proc: None,
        running: false,
        last: @host.now(),
      }
      self.builders[name] = b
      b
    }
  }
}

///|
/// The items ready (each prepared once, however many ask).
async fn Requested::ready(self : Requested, items : Array[Json]) -> Unit {
  let waits = []
  for item in items {
    let d : @effect.Deferred[Result[Unit, String]] = @effect.Deferred::new()
    self.waiting.push((item, d))
    waits.push(d)
  }
  self.run()
  for d in waits {
    match d.wait() {
      Ok(_) => ()
      Err(e) => raise ReadFailed(503, e)
    }
  }
}

///|
fn Requested::run(self : Requested) -> Unit {
  if self.running {
    return
  }
  self.running = true
  let host = self.readers.host
  ignore(
    host.rt.fork(name="old-state builder", async fn() {
      defer {
        self.running = false
      }
      // (the process before holds what only one process may build, until it is gone)
      (self.readers.previous_gone.val)()
      let mut pause = 250
      while self.waiting.length() > 0 && !self.readers.closed {
        let (item, d) = self.waiting[0]
        let proc = match self.proc {
          Some(p) if !p.gone => p
          _ =>
            match (try { Ok(mb_spawn(host, self.readers.program, self.args)) } catch { e => Err(e) }) {
              Ok(p) => {
                self.proc = Some(p)
                p
              }
              Err(SysError(e)) => {
                for w in self.waiting {
                  ignore(w.1.succeed(Err(e)))
                }
                self.waiting.clear()
                return
              }
            }
        }
        if !proc.post((self.message)(item)) {
          self.proc = None
          continue
        }
        // Its answer, the permit it asks for given on the way.
        let mut result : Json = Json::null()
        while proc.next() is Some((said, _)) {
          match said {
            { "take": True, .. } => ignore(proc.post({ "permit": true }))
            { "give": True, .. } => ()
            _ => {
              result = said
              break
            }
          }
        }
        // (the station stopping while it answered: `close` already told everyone waiting and emptied the queue, so
        // what it said last, a done or not, is nobody's)
        if self.readers.closed || self.waiting.length() == 0 {
          return
        }
        self.last = @host.now()
        match result {
          { "done": True, .. } | { "complete": True, .. } | { "id": _, "error": Null, .. } => {
            pause = 250
            ignore(self.waiting.remove(0))
            for w in self.waiting.filter(w => w.0 == item) {
              ignore(w.1.succeed(Ok(())))
            }
            self.waiting.retain(w => w.0 != item)
            ignore(d.succeed(Ok(())))
          }
          { "error": String(e), .. } => {
            let failed = self.waiting.filter(w => w.0 == item)
            self.waiting.retain(w => w.0 != item)
            for w in failed {
              ignore(w.1.succeed(Err(e)))
            }
          }
          { "fallback": True, .. } =>
            match self.repair {
              Some(repair) =>
                repair() catch {
                  e => {
                    // (the database busy with another's write: asked again after a pause)
                    if !@sql.busy(e) {
                      let failed = self.waiting.filter(w => w.0 == item)
                      self.waiting.retain(w => w.0 != item)
                      for w in failed {
                        ignore(w.1.succeed(Err("\{e}")))
                      }
                    }
                    @effect.sleep(pause) // timer: a retry after a failure (the writer busy), with a backoff
                  }
                }
              None => {
                let failed = self.waiting.filter(w => w.0 == item)
                self.waiting.retain(w => w.0 != item)
                for w in failed {
                  ignore(w.1.succeed(Err("the store needs a repair this builder cannot make")))
                }
              }
            }
          Null => {
            // (it ended: started again after a growing wait)
            self.proc = None
            @effect.sleep(pause) // timer: a retry after a failure, with a backoff
            pause = if pause * 2 > 30000 { 30000 } else { pause * 2 }
          }
          _ => {
            // Not done: to the back, after a pause.
            ignore(self.waiting.remove(0))
            self.waiting.push((item, d))
            @effect.sleep(250) // timer: a retry after a failure (a batch not done), with a pause
          }
        }
      }
    }),
  )
}

///|
fn Requested::let_go_idle(self : Requested, now : Int64) -> Unit {
  if !self.running && self.waiting.length() == 0 && now - self.last > 5000L {
    match self.proc {
      Some(p) => {
        p.stop()
        self.proc = None
      }
      None => ()
    }
  }
}

///|
fn Requested::close(self : Requested) -> Unit {
  for w in self.waiting {
    ignore(w.1.succeed(Err("station stopping")))
  }
  self.waiting.clear()
  match self.proc {
    Some(p) => p.stop()
    None => ()
  }
}

///|
/// The readers closed while a builder's process is on an item (the harness's `requestedCloseInFlight`): `program` is
/// run as the builder `said`, asked one item, and the readers closed the moment that ask is written, so what the
/// process says after (its `take`, then `said` once its stdin is closed) comes to a builder whose queue `close`
/// emptied. What the ask was answered, and whether the builder came to its end with nothing left waiting.
async fn p51_requested_close_in_flight(host : @host.Host, data : String, program : String, said : String) -> Json {
  let readers = Readers::new(host, program, data)
  let asked : @effect.Deferred[Unit] = @effect.Deferred::new()
  let b = readers.builder(
    "close-in-flight",
    k => {
      ignore(asked.succeed(()))
      { "session": k }
    },
    program=said,
  )
  let answered : @effect.Deferred[String] = @effect.Deferred::new()
  ignore(
    host.rt.fork(name="close-in-flight ask", async fn() {
      let what = b.ready([Json::string("s1")]) catch { e => "\{e}" } noraise { _ => "ready" }
      ignore(answered.succeed(what))
    }),
  )
  asked.wait()
  readers.close()
  let answer = answered.wait()
  // (the builder's process ends once it said its last; the builder's fiber is let run to its end after)
  match b.proc {
    Some(p) => p.ended.wait()
    None => ()
  }
  while b.running {
    @effect.pause()
  }
  { "answer": Json::string(answer), "waiting": Json::number(b.waiting.length().to_double()) }
}

///|
/// What a refusal of a read asks to be prepared first (pool.ts `saidRead` and the reads after it), as an ask of its
/// builder; None where it asks nothing.
fn Readers::prepare_for(self : Readers, refusal : String, args : Json) -> (async () -> Unit)? {
  let after = (prefix : String) => if refusal.has_prefix(prefix) {
    match (try { Ok(@json.parse(refusal[prefix.length():].to_owned())) } catch { e => Err(e) }) {
      Ok(Array(items)) => Some(items)
      Ok(v) => Some([v])
      Err(_) => None
    }
  } else {
    None
  }
  let thread = (flag : String?) => (t : Json) => {
    let m : Map[String, Json] = { "thread": t }
    match flag {
      Some(f) => m[f] = Json::boolean(true)
      None => ()
    }
    Json::object(m)
  }
  let field = (k : String) => (t : Json) => {
    let m : Map[String, Json] = {}
    m[k] = t
    Json::object(m)
  }
  if refusal == "legacy edit lookup pending" {
    let b = self.builder("legacy-edits", thread(Some("legacyEdits")), repair=() => self.repair_edits())
    return Some(async fn() { b.ready([Json::number(0.0)]) })
  }
  if refusal == "legacy said lookup pending" {
    let b = self.builder("legacy-said", thread(Some("legacySaid")))
    return Some(async fn() { b.ready([Json::number(0.0)]) })
  }
  let threaded = [
    ("page letter lookup pending: ", "page-letters", Some("pageLetters")),
    ("last message pending: ", "archive-last", Some("archiveLast")),
    ("card posts pending:", "card-posts", None),
    ("closed cards pending:", "closed-cards", Some("closed")),
    ("people time pending:", "people-since", Some("people")),
    ("sidebar said state pending: ", "said", None),
  ]
  for t in threaded {
    if after(t.0) is Some(items) {
      let b = self.builder(t.1, thread(t.2))
      return Some(async fn() { b.ready(items) })
    }
  }
  if after("turn count pending: ") is Some(sessions) {
    let b = self.builder("turn-counts", field("session"))
    return Some(async fn() { b.ready(sessions) })
  }
  if after("copy destination sessions pending:") is Some(sessions) {
    let b = self.builder("cc-index", field("session"))
    return Some(async fn() { b.ready(sessions) })
  }
  if after("job name first member pending: ") is Some([session, first]) {
    let b = self.builder("session-up-jobs-first", program="session-up-jobs", k => match k {
      Array([s, f]) => { "session": s, "first": f }
      _ => k
    })
    return Some(async fn() { b.ready([Json::array([session, first])]) })
  }
  let scoped = [
    ("session binding index is still being prepared", "session-bindings", "all"),
    ("session list index is still being prepared", "session-list", "all"),
  ]
  for s in scoped {
    if refusal == s.0 {
      let b = self.builder(s.1, field("scope"))
      return Some(async fn() { b.ready([Json::string(s.2)]) })
    }
  }
  if refusal == "recent chat order is still being prepared" {
    let scope = match args {
      Object(m) => Json::array([m.get("ws").unwrap_or(Json::null()), m.get("home").unwrap_or(Json::null())]).stringify()
      _ => "[null,null]"
    }
    let b = self.builder("recent-chat", field("scope"))
    return Some(async fn() { b.ready([Json::string(scope)]) })
  }
  if refusal == "outflow chat order is still being prepared" {
    let b = self.builder("outflow-chats", field("scope"))
    // (store/outflow-index.ts `outflowChatScopes`)
    let scopes = match args {
      { "ws": { "workspace": String(w), "home": False, .. }, .. } => ["W" + w]
      { "ws": { "workspace": String(w), .. }, .. } => ["H", "W" + w]
      _ => ["H", "W\u{0}home"]
    }
    return Some(async fn() { b.ready(scopes.map(x => Json::string(x))) })
  }
  if refusal == "usage chat statistics are still being filled" || refusal == "remote task statistics are still being filled" {
    let b = self.builder("usage-check", k => k)
    let viewer = match args {
      Object(m) => m.get("viewer").unwrap_or(Json::null())
      _ => Json::null()
    }
    let ask : Json = if refusal.has_prefix("usage") { { "id": 1, "chats": viewer } } else { { "id": 1, "remote": true } }
    return Some(async fn() { b.ready([ask]) })
  }
  None
}

///|
/// The merged view a builder leaves to the writer, repaired on the station's own write connection (services.ts
/// `repairEdits`), waiting for no lock: one found busy is tried again after a pause.
fn Readers::repair_edits(self : Readers) -> Unit raise {
  match p51_live.val {
    Some(p) => {
      let db = p.bus.db
      let timeout = match db.all("PRAGMA busy_timeout", []) {
        [row, ..] =>
          match row.values().next() {
            Some(Number(n, ..)) => n.to_int()
            _ => 5000
          }
        _ => 5000
      }
      db.exec("PRAGMA busy_timeout = 0")
      defer (try { db.exec("PRAGMA busy_timeout = \{timeout}") } catch { _ => () })
      @store_schema.repair_merged_edit_lookup(db)
    }
    None => ()
  }
}

// ── put together ──

///|
/// services.ts Readers and CheckpointsLive: the pool (its first reader started before anything is asked), its
/// checkpoints as the store changes, idle readers let go, and the old lookups built in the background once the process
/// before is gone; the bus's `reader_ask` from now on.
fn P51::readers_live(self : P51) -> Readers {
  let bus = self.bus
  let r = Readers::new(self.host, bus.argv0, bus.data)
  r.previous_gone.val = bus.previous_gone
  r.catalog = () => (bus.model_catalog.val)()
  r.processes = async fn() {
    match (bus.hub_ask.val)("processes", Json::null()) {
      Array(_) as a => a
      _ => Json::array([])
    }
  }
  r.client_keys = async fn() {
    match (bus.hub_ask.val)("clientKeys", Json::null()) {
      Array(_) as a => a
      _ => Json::array([])
    }
  }
  // warm: the first of what devices ask
  ignore(r.start(r.moved))
  // (`$cardPosts`: hub.ts `prepareCardPosts`, the old cards' posts of these threads built before a read that needs them)
  bus.reader_ask.val = async fn(op, args, lang) {
    // (`$latestThreads`: hub.ts `prepareLatestThreads`, the cc index's latest conversations of these sessions)
    if op == "$latestThreads" {
      r.builder("cc-index-latest", s => { "session": s, "latest": true }, program="cc-index").ready(jitems(args))
      return Json::null()
    }
    // (`$sessionChatNames`: hub.ts `prepareSessionChatNames`, the cc index's chat names of these sessions)
    if op == "$sessionChatNames" {
      r.builder("cc-index-names", s => { "session": s, "name": true }, program="cc-index").ready(jitems(args))
      return Json::null()
    }
    // (`$sessionCounts`: agents.ts `waitForSessionCounts`, the sessions' counts built for the overview, a batch at a
    // time, by `--builder session-counts`)
    if op == "$sessionCounts" {
      r.builder("session-counts", _ => Json::object({})).ready([Json::string("all")])
      return Json::null()
    }
    // (the station short of memory: what answers nothing let go, a count; resources/module.ts `trimIdle`)
    if op == "trimIdle" {
      return Json::number(r.trim_idle().to_double())
    }
    if op == "$cardPosts" {
      r.builder("card-posts", t => { "thread": t }).ready(jitems(args))
      return Json::null()
    }
    r.read(op, args, lang)
  }
  self.stops.push(bus.subscribe_store(_ => r.checkpoint_soon()))
  bus.register_pids(() => r.pids())
  self.every("idle readers", 15000, async fn() { r.let_go_idle() }) // timer: a debounce of a burst (a reader idle a minute let go, pool.ts IDLE_MS)
  self.fork("old lookups", async fn() { r.legacy_lookups(bus) })
  r
}

///|
/// store/legacy-said-builder.ts `buildLegacyEntryLookups`: once the process before is gone, one builder takes turns
/// with each old lookup a store from before lacks (`--builder session-backfill`, a kind a batch) until each says it is
/// done; again as the store's threads change.
async fn Readers::legacy_lookups(self : Readers, bus : LiveBus) -> Unit {
  (bus.previous_gone)()
  let kinds = [
    "legacy-said", "legacy-agent", "legacy-login", "legacy-edits", "legacy-policy", "legacy-decision-time", "legacy-decision-session",
    "legacy-decision-session-repair", "page-letter-gc",
  ]
  let wake : @effect.Queue[Unit] = @effect.Queue::unbounded()
  self.stops.push(
    bus.subscribe_store(change => match change {
      { "type": "thread", "entries": Array(e), .. } if e.length() > 0 => ignore(wake.try_offer(()))
      { "type": "threadRemoved", .. } => ignore(wake.try_offer(()))
      _ => ()
    }),
  )
  let left = kinds.copy()
  while !self.closed {
    if left.length() > 0 {
      // (nobody waits on it: under the machine's background policy, its disk IO yielding to the foreground's)
      let (program, args) = background_wrapped(self.program, ["--builder", "session-backfill", "--db", self.db])
      let proc = mb_spawn(self.host, program, args) catch {
        SysError(e) => {
          p51_log("WARN", "store", "the old message lookup worker could not start", fields={ "error": Json::string(e) })
          @effect.sleep(30000) // timer: a retry after a failure, with a backoff
          continue
        }
      }
      // (ended however this ends, the station's stop too: interrupted while it waited on the builder's answer, it left
      // the builder running past the station, writing in its data directory)
      defer proc.stop()
      let mut i = 0
      while left.length() > 0 && !self.closed {
        let kind = left[i % left.length()]
        if !proc.post({ "kind": Json::string(kind) }) {
          break
        }
        let mut answer = Json::null()
        while proc.next() is Some((said, _)) {
          match said {
            { "take": True, .. } => ignore(proc.post({ "permit": true }))
            { "give": True, .. } => ()
            _ => {
              answer = said
              break
            }
          }
        }
        match answer {
          { "done": True, .. } => left.retain(k => k != kind)
          { "error": String(e), .. } => {
            p51_log("WARN", "store", "an old message lookup batch stopped", fields={ "kind": Json::string(kind), "error": Json::string(e) })
            left.retain(k => k != kind)
          }
          Null => break
          _ => i += 1
        }
      }
    }
    // (asked again as the store's threads change: a new message may need its lookup)
    ignore(wake.take())
    while wake.try_take() is Some(_) {

    }
    if left.length() == 0 {
      left.push("legacy-said")
      left.push("page-letter-gc")
    }
  }
}

///|
/// platform's `backgrounded`: macOS's taskpolicy -b, Linux's ionice and nice, none on Windows (unix.ts `backgroundedOn`).
fn background_wrapped(program : String, args : Array[String]) -> (String, Array[String]) {
  if is_windows() {
    return (program, args)
  }
  let there = (p : String) => attempt(() => @drive.realpath(p)) is Ok(_)
  let how = @ops_platform.background_found(platform() == "darwin", there, p => attempt(() => @drive.realpath(p)).to_option())
  @ops_platform.backgrounded_on(how, program, args)
}
