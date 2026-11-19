// P5-3 of the station as the MoonBit program composes it (station/src/main.ts's layers of these parts, in MoonBit):
// the background jobs and their services (jobs/jobs.ts, tools/jobs.ts), the tasks other stations run here and this
// station's there (jobs/remote.ts, tools/remote.ts), a workspace's size (jobs/workspace-size.ts), the disk's upkeep
// (ops/storage.ts `Upkeep`, ops/disk.ts), links' previews (links/module.ts), what of the machine still.fail uses
// (resources/module.ts), the search (search/module.ts), the model catalog (models/module.ts), the accounts
// (accounts/index.ts), the shared profiles and skills (share/index.ts), the agents' memory brought level between the
// stations (share/memory.ts) and chats shared across workspaces (xshare/). Each made here, from what `run` gives the
// slices (`LiveBus`, live_bus.mbt), and saying what it adds to what the station answers through `bus.parts`; what the
// other parts ask of them goes through `bus.jobs_ask`.

///|
/// What a part of this slice failed at, said in words.
priv suberror P53Error {
  P53Error(String)
}

///|
impl Show for P53Error with output(self, logger) {
  match self {
    P53Error(s) => logger.write_string(s)
  }
}

///|
/// The parts of this slice, made by `start_live_p5_3`, as `bus.jobs_ask` reaches them.
priv struct P53 {
  bus : LiveBus
  program : P53Program
  jobs : P53Jobs
  remote : P53Remote
  resources : P53Resources
  search : P53Search
  accounts : P53Accounts
  share : P53Share
  upkeep : P53Upkeep
  watch : P53Watch
  links : @jobs_host.LinkPreviews
  models : P53Models
}

// ── JSON as the TypeScript reads it ──

///|
fn p53_get(j : Json, k : String) -> Json {
  match j {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn p53_str(j : Json, k : String) -> String? {
  match p53_get(j, k) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// The first of two that is some.
fn p53_either(a : String?, b : String?) -> String? {
  match a {
    Some(_) => a
    None => b
  }
}

///|
fn p53_either_n(a : Double?, b : Double?) -> Double? {
  match a {
    Some(_) => a
    None => b
  }
}

///|
fn p53_text(j : Json, k : String) -> String {
  p53_str(j, k).unwrap_or("")
}

///|
fn p53_num(j : Json, k : String) -> Double? {
  match p53_get(j, k) {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
fn p53_true(j : Json, k : String) -> Bool {
  p53_get(j, k) is True
}

///|
fn p53_s(s : String) -> Json {
  Json::string(s)
}

///|
fn p53_n(n : Double) -> Json {
  Json::number(n)
}

///|
fn p53_i(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
fn p53_b(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn p53_opt(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn p53_obj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
/// A field set on a JSON object (a copy).
fn p53_with(j : Json, k : String, v : Json) -> Json {
  let m : Map[String, Json] = Map([])
  match j {
    Object(o) =>
      for kk, vv in o {
        m[kk] = vv
      }
    _ => ()
  }
  m[k] = v
  Json::object(m)
}

///|
/// The words of a failure, as `(error as Error).message` says them.
fn p53_words(e : Error) -> String {
  match e {
    P53Error(s) => s
    BusError(s) => s
    @jobs_host.HostError(s) => s
    @accounts_pool.Thrown(_, _) => @accounts_pool.message_of(e)
    @accounts_oauth.Said(m)
    | @accounts_oauth.RenewRefused(_, m)
    | @accounts_oauth.Failed(m)
    | @accounts_oauth.FsError(_, m)
    | @accounts_oauth.JsonError(m) => m
    @api_routes.Thrown(kind, said) =>
      match said {
        Obj(_) =>
          match said.get("message") {
            Some(Str(m)) => m
            _ => kind
          }
        _ => kind
      }
    @jobs_host.Refused(m) | @jobs_host.Unreached(m) | @jobs_host.NoBytes(m) | @jobs_host.NoLink(m) => m
    _ => {
      // (the mesh's errors their words; anything else as it shows)
      let s = @gate.words_of(e)
      // (a suberror's show: its name and its words in quotes)
      match s.find("(\"") {
        Some(i) if s.has_suffix("\")") =>
          match attempt(() => @json.parse(s[i + 1:s.length() - 1].to_owned())) {
            Ok(String(w)) => w
            _ => s
          }
        _ => s
      }
    }
  }
}

///|
/// A tool's answer (tools/mcp.ts): its text.
fn p53_said(text : String) -> Json {
  p53_obj([("content", Json::array([p53_obj([("type", p53_s("text")), ("text", p53_s(text))])]))])
}

///|
/// What JSON.stringify(v, null, 2) writes.
fn p53_pretty(v : Json) -> String {
  v.stringify(indent=2)
}

///|
/// The session a tool's call is of: the context's (the agents' door's own, P5-2's), else its bearer's.
fn p53_session_of(bus : LiveBus, context : Json) -> String raise P53Error {
  match p53_str(context, "session") {
    Some(s) if s != "" => return s
    _ => ()
  }
  let token = match p53_str(context, "authorization") {
    Some(a) if a.has_prefix("Bearer ") => a[7:].to_owned()
    _ => ""
  }
  if token == "" {
    raise P53Error("unknown session")
  }
  match (try { Ok(bus.store.session_key_by_token(token)) } catch { e => Err(e) }) {
    Ok(String(k)) => k
    _ => raise P53Error("unknown session")
  }
}

///|
/// A session's record, or null.
fn p53_session_row(bus : LiveBus, key : String) -> Json {
  bus.store.get_session(key) catch {
    _ => Json::null()
  }
}

///|
/// A part's tool (tools/mcp.ts `Tool`): its declaration and its call, given its arguments and its session.
fn p53_tool(
  bus : LiveBus,
  name : String,
  description : String,
  schema : Json,
  run : async (String, Json) -> String,
) -> PartTool {
  {
    name,
    declared: p53_obj([("name", p53_s(name)), ("description", p53_s(description)), ("inputSchema", schema)]),
    call: async fn(args, context) {
      // (a refusal is the tool's answer, said in its words: tools/mcp.ts `isError`)
      try {
        let session = p53_session_of(bus, context)
        p53_said(run(session, args))
      } catch {
        e => p53_with(p53_said(p53_words(e)), "isError", p53_b(true))
      }
    },
  }
}

///|
/// Text, in UTF-8.
fn p53_utf8(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// A file read as text, none where it is not there.
async fn p53_read(host : @host.Host, path : String) -> String? {
  match (try { Ok(host.shell("fs.read", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// A file written whole (the shell's `fs.write`: beside it, synced and renamed into place, its folders made).
async fn p53_write(host : @host.Host, path : String, text : String) -> Unit {
  ignore(try { Ok(host.shell("fs.write", { "path": Json::string(path), "text": Json::string(text) })) } catch { e => Err(e) })
}

///|
/// A file of the station's user's alone written whole: beside it with mode 0600, then renamed into place.
async fn p53_write_private(host : @host.Host, path : String, bytes : Bytes) -> Unit {
  ignore(host.shell("fs.mkdir", { "path": Json::string(@nodepath.dirname(sep(), path)), "recursive": Json::boolean(true) }))
  let tmp = "\{path}.\{@drive.pid()}.tmp"
  ignore(host.shell("fs.put", { "path": Json::string(tmp), "offset": Json::number(0.0), "truncate": Json::boolean(true), "mode": Json::number(384.0) }, bytes~))
  ignore(host.shell("fs.chmod", { "path": Json::string(tmp), "mode": Json::number(384.0) }))
  ignore(host.shell("fs.rename", { "from": Json::string(tmp), "to": Json::string(path) }))
}

///|
/// The station's log line of a part (ops/log.ts), on stderr as the program's are.
fn p53_log(level : String, part : String, message : String, fields? : Json = Json::object({})) -> Unit {
  slice_log(level, part, message, fields)
}

///|
/// The cloud's state as this station keeps it (mesh/cloud.json), through the bus.
fn p53_cloud(bus : LiveBus) -> Json {
  (bus.cloud_state.val)().unwrap_or(Json::null())
}

///|
/// The station's id in its workspaces (cloud.json `station`), else its key's.
fn p53_station_id(bus : LiveBus) -> String {
  match p53_str(p53_cloud(bus), "station") {
    Some(s) if s != "" => s
    _ => bus.key.id
  }
}

///|
/// The home workspace (cloud.json `workspace`), none where the station is in none.
fn p53_home(bus : LiveBus) -> String? {
  match p53_str(p53_cloud(bus), "workspace") {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}

///|
/// A program run to its end (`proc.run`), its stdout; none where it failed.
async fn p53_run(host : @host.Host, command : String, args : Array[String], timeout_ms? : Int = 10000) -> String? {
  match
    (try {
      Ok(
        host.shell("proc.run", {
          "command": Json::string(command),
          "args": Json::array(args.map(a => Json::string(a))),
          "timeoutMs": Json::number(timeout_ms.to_double()),
        }),
      )
    } catch {
      e => Err(e)
    }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// The station starts the parts of P5-3 on the bus: each made, what it adds said to `bus.parts`, its asks answered on
/// `bus.jobs_ask`.
pub async fn start_live_p5_3(bus : LiveBus) -> Unit {
  // (the sessions' program, in which the jobs and the remote tasks run as they run under the TypeScript station)
  let program = P53Program::new(bus)
  program.start() catch {
    e => {
      p53_log("error", "jobs", "the sessions' program does not start", fields=p53_obj([("error", p53_s(p53_words(e)))]))
      (bus.stop_station)(p53_words(e))
      return
    }
  }
  let jobs = P53Jobs::new(bus, program)
  let remote = P53Remote::new(bus, program, jobs)
  let resources = P53Resources::new(bus, jobs)
  let search = P53Search::new(bus)
  let accounts = P53Accounts::new(bus)
  let share = P53Share::new(bus, accounts)
  let upkeep = P53Upkeep::new(bus, jobs, remote)
  let watch = P53Watch::new(bus, jobs, remote)
  let links = @jobs_host.LinkPreviews::new(@jobs_host.LinkIo::shell(bus.host))
  let models = P53Models::new(bus, accounts)
  // (every part's that answers nothing let go, and every program the station runs counted: pool.ts `onTrim`,
  // self-memory.ts `MbProcess.live`)
  resources.trim_idle = async fn() { search.trim_idle() + bus.trim_helpers() }
  bus.register_pids(() => [program.pid(), search.pid()].filter_map(x => x))
  resources.programs = () => bus.all_helper_pids()
  let p : P53 = { bus, program, jobs, remote, resources, search, accounts, share, upkeep, watch, links, models }
  // (each part's own: its routes, tools, door places, peers' methods, carried memory)
  jobs.attach()
  remote.attach()
  resources.attach()
  search.attach()
  accounts.attach()
  share.attach()
  upkeep.attach()
  watch.attach()
  models.attach()
  bus.parts.routes([
    {
      meth: "GET",
      path: "/link-preview",
      answer: async fn(r) {
        let url = p53_text(p53_get(r, "query"), "url")
        if url == "" {
          raise P53Error("no url")
        }
        match p.links.preview(url, wall_ms().to_double()) {
          Some(v) => v
          None => Json::null()
        }
      },
    },
  ])
  bus.jobs_ask.val = async fn(op, arg) { p.ask(op, arg) }
  // (what the parts said to the station, asked by a program on this machine where the station is run so: the admin
  // API's routes are the mesh's, P5-1's, which a station run alone in a test has none of)
  if env_get("STILLFAIL_PARTS_DOOR") == Some("1") {
    bus.parts.door({ prefix: "parts", request: async fn(r, _conn) { Some(p53_parts_door(bus, r)) } })
  }
  // (the station stops: the jobs go on, what follows them here ends; the parts' programs and timers let go)
  ignore(
    bus.host.rt.fork(name="p5-3 stop", async fn() {
      ignore(bus.stopped.wait())
      p.jobs.shutdown()
      ignore(p.program.call(p53_remote_key, "close", [])) catch { _ => () }
      p.share.close()
      p.models.written() catch { _ => () }
      p.accounts.close()
      p.search.close()
      p.program.close()
    }),
  )
  // (what waits for the agents' door: a job's notify place, the jobs taken up)
  ignore(
    bus.host.rt.fork(name="p5-3 door", async fn() {
      let url = bus.door_ready.wait()
      p.jobs.door_open(url)
    }),
  )
}

///|
/// What the other parts ask of these (`bus.jobs_ask`): the Hub (`jobsStopAll`, `jobsRelaunch`), the admin API and the
/// agents' tools (their arguments in order, as an array, as station/mb's api_routes and mcp_tools ask them), a rig's
/// main (`stop`, `relaunch`, `stopAll`, `upkeep.renewables`, `remote.relieve`, `setNotifyUrl`: an object), the moves
/// (move_coord, retire). An argument is the array's `i`th, or the object's `key`.
async fn P53::ask(self : P53, op : String, arg : Json) -> Json {
  let at = (i : Int, key : String) => match arg {
    Array(xs) => if i < xs.length() { xs[i] } else { Json::null() }
    _ => p53_get(arg, key)
  }
  let str = (i : Int, key : String) => match at(i, key) {
    String(t) => Some(t)
    _ => None
  }
  let text = (i : Int, key : String) => str(i, key).unwrap_or("")
  let num = (i : Int, key : String) => match at(i, key) {
    Number(n, ..) => Some(n)
    _ => None
  }
  let strs = (v : Json) => match v {
    Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
    _ => []
  }
  let positional = arg is Array(_)
  match op {
    // ── Jobs ──
    "jobsStopAll" | "jobs.stopAll" | "stopAll" =>
      // (a session's alone: the hub's; every one, `why` said in each log: a rig's, the station leaving its workspace)
      if positional {
        self.jobs.stop_all(None, why?=str(0, "why"))
      } else {
        self.jobs.stop_all(p53_str(arg, "session"), why?=p53_str(arg, "why"))
      }
    "jobsRelaunch" | "jobs.relaunch" | "relaunch" => self.jobs.relaunch()
    "jobs.start" =>
      Json::object(
        if positional {
          self.jobs.start(text(0, ""), text(1, ""), text(2, ""), text(3, ""), num(4, ""), at(5, "") is True, None, at(6, "") is True, Json::null())
        } else {
          self.jobs.start(
            p53_text(arg, "session"),
            p53_text(arg, "name"),
            p53_text(arg, "command"),
            p53_text(arg, "cwd"),
            p53_num(arg, "port"),
            p53_true(arg, "watch"),
            p53_str(arg, "id"),
            false,
            p53_get(arg, "queue"),
          )
        },
      )
    "jobs.stop" | "stop" => self.jobs.stop(text(0, "id"))
    "jobs.stopFor" => self.jobs.stop_for(text(0, "id"), text(1, "who"))
    "jobs.clearEnded" => Json::array(self.jobs.clear_ended(text(0, "session")).map(p53_s))
    "jobs.list" | "jobs.store.listJobs" => Json::array(self.jobs.list(str(0, "session")))
    "jobs.get" => self.jobs.shown(text(0, "id"))
    "jobs.store.getJob" => self.jobs.get(text(0, "id"))
    "jobs.view" => self.jobs.view(at(0, "job"))
    "jobs/jobs.shown" => self.jobs.shown(p53_text(at(1, "job"), "id"))
    "jobs/jobs.tail" => p53_s(@jobs_host.tail(self.bus.host, text(0, "path"), num(1, "lines").unwrap_or(50.0).to_int()))
    "jobs/jobs.named" => {
      let job = at(0, "job")
      p53_s(@jobs_host.job_named(p53_text(job, "id"), p53_text(job, "name"), p53_num(job, "port")))
    }
    "jobs.json" => @jobs_host.job_json(at(0, "job"))
    "jobs.log" => p53_s(self.jobs.log(text(0, "id"), num(1, "lines").unwrap_or(50.0).to_int()))
    "jobs.workspace" =>
      match p53_str(p53_session_row(self.bus, text(0, "session")), "workspace") {
        Some(w) => p53_s(w)
        None => Json::null()
      }
    "jobs.say" => {
      self.jobs.tell_session(text(0, "session"), text(1, "text"))
      Json::null()
    }
    "jobs.queueOf" => self.jobs.queue_of(text(0, "id"))
    "jobs.screenHolder" => p53_opt(self.jobs.screen_holder(str(0, "except")))
    "jobs.memorySeen" => {
      self.jobs.memory_seen(str(0, "pressure"))
      Json::null()
    }
    "jobs.sessionEnded" => {
      self.jobs.session_ended(text(0, "session"))
      Json::null()
    }
    "setNotifyUrl" | "jobs.setNotifyUrl" => {
      self.jobs.machine.set_notify_url(text(0, "url"))
      Json::null()
    }
    "preview" => self.jobs.preview_json(arg)
    // ── Jobs, as the moves ask (move/live.ts `jobs`) ──
    "jobs.upIn" | "jobs.upAsMoves" | "jobs.up" => {
      let keys = match at(0, "keys") {
        Array(_) as k => Some(k)
        _ => None
      }
      Json::array(self.jobs.up_in(keys, str(1, "ws")))
    }
    "jobs.running" => self.bus.store.running_jobs()
    "jobs.stopNamed" => {
      self.jobs.stop_named(text(0, "session"), text(1, "name"))
      Json::null()
    }
    "jobs.stopAllIn" => self.jobs.stop_all_in(text(0, "ws"), str(1, "why"))
    "jobs.startMoved" => Json::object(self.jobs.start_moved(at(0, "job")))
    "store.jobsMarkOf" =>
      self.bus.store.jobs_mark_of(match at(0, "keys") { Array(xs) => xs; _ => [] })
    "store.jobsUpOf" =>
      Json::array(self.bus.store.jobs_up_of(match at(0, "keys") { Array(xs) => xs; _ => [] }))
    // ── Remote ──
    "remote.tool" =>
      if positional {
        self.program.call(p53_remote_key, "tool", [at(0, ""), at(1, ""), at(2, "")])
      } else {
        self.program.call(p53_remote_key, "tool", [p53_get(arg, "tool"), p53_get(arg, "session"), p53_get(arg, "args")])
      }
    "remote.closeSession" => self.program.call(p53_remote_key, "closeSession", [at(0, "session"), p53_n(self.bus.store.now().to_double())])
    "remote.recordUse" => self.program.call(p53_remote_key, "recordUse", [at(0, "workspace"), at(1, "session"), at(2, "station")])
    "remote.listLocal" => self.program.call(p53_remote_key, "listLocal", [at(0, "dir")])
    "remote.describe" => self.remote.describe("", text(0, "workspace"))
    "remote.ask" => {
      let (answer, _) = self.remote.ask(text(0, "station"), at(1, "request"))
      answer
    }
    // (agents.ts `hub.onPeer`: a session's request of another station, as xshare addresses it where it is another
    // workspace's; the bytes it carries (`$bytes`, base64) and those of its answer alike)
    "xshare.send" => {
      let request = at(1, "request")
      let (req, bytes) = match request {
        Object(m) if m.get("$bytes") is Some(String(b)) => {
          let c = m.copy()
          c.remove("$bytes")
          (Json::object(c), Some(@base64.decode(b)))
        }
        _ => (request, None)
      }
      let station = text(0, "station")
      let got : Ref[Bytes?] = Ref(None)
      let send = async fn(r : Json) -> Json {
        let (answer, back) = self.remote.ask(station, r, bytes?)
        got.val = back
        answer
      }
      let answer = match self.share.shares {
        Some(s) => s.send(station, req, send)
        None => send(req)
      }
      match (got.val, answer) {
        (Some(b), Object(m)) => {
          let out = m.copy()
          out["$bytes"] = Json::string(@base64.encode(b))
          Json::object(out)
        }
        _ => answer
      }
    }
    "remote.workspaceStation" => p53_s(self.remote.workspace_station(text(0, "session"), text(1, "named")))
    "remote.relieve" => {
      self.remote.relieve(num(0, "now").unwrap_or(wall_ms().to_double()), num(1, "soft").unwrap_or(0.0))
      Json::null()
    }
    // ── Resources, the disk, a workspace's size ──
    "resources" => self.resources.view()
    // (what the admin API's routes ask of them: resources/watch.ts, links/preview.ts, jobs/preview.ts, the usage
    // counter's reading, xshare's shares)
    // (usage/module.ts: whether the counter still reads everything for the first time: the hub's)
    "usage.readingAll" => (self.bus.hub_ask.val)("readingAll", Json::array([]))
    "resources.watch.snapshot" => self.resources.snapshot()
    "resources.watch.want" => {
      self.resources.want()
      Json::null()
    }
    "resources.watch.end" =>
      Json::string(
        self.resources.end(num(0, "pid").unwrap_or(-1.0).to_int(), text(1, "session")) catch {
          P53Error(m) => raise @api_routes.Thrown("NotEndable", @jsjson.JV::of_json({ "message": Json::string(m) }))
          e => raise e
        },
      )
    "resources.watch.follow" => {
      let f = at(0, "told")
      let bus = self.bus
      let stop = self.resources.follow(() => ignore(bus.host.rt.fork(name="resources told", async fn() {
        ignore(bus.call_peer("self", None, "$admin.called", { "id": p53_get(f, "$fn"), "args": [] })) catch { _ => () }
      })))
      p53_follows_next.val += 1
      let handle = "resources.watch.stop:\{p53_follows_next.val}"
      p53_follows[handle] = stop
      { "$ref": Json::string(handle) }
    }
    _ if op.has_prefix("resources.watch.stop:") => {
      match p53_follows.get(op) {
        Some(stop) => {
          p53_follows.remove(op)
          stop()
        }
        None => ()
      }
      Json::null()
    }
    "links/preview.linkPreview" =>
      match p53_link_previews(self.bus).preview(text(0, "url"), wall_ms().to_double()) {
        Some(v) => v
        None => Json::null()
      }
    "jobs/preview.proxyPreview" => {
      // [method, headers [[name, value]], body {$bytes} or null, port, target, lang]
      let headers = match at(1, "headers") {
        Array(xs) => xs.filter_map(x => match x { Array([String(k), String(v), ..]) => Some((k, v)); _ => None })
        _ => []
      }
      let body = match at(2, "body") {
        Object(m) =>
          match m.get("$bytes") {
            Some(String(b)) => Some(@base64.decode(b))
            _ => None
          }
        _ => None
      }
      let answer = @jobs_host.proxy_preview(
        self.bus.host,
        text(0, "method"),
        headers,
        body,
        num(3, "port").unwrap_or(0.0).to_int(),
        text(4, "target"),
        str(5, "lang").unwrap_or((self.bus.lang.val)()),
      )
      let out = @buffer.Buffer()
      while true {
        match (answer.next)() {
          Some(b) => out.write_bytes(b)
          None => break
        }
      }
      p53_obj([
        ("status", p53_i(answer.status)),
        ("headers", Json::array(answer.headers.map(h => Json::array([p53_s(h.0), p53_s(h.1)])))),
        ("body", p53_obj([("$bytes", p53_s(@base64.encode(out.to_bytes())))])),
      ])
    }
    "xshare.share" =>
      match self.share.shares {
        Some(s) =>
          match s.share(text(0, "key"), match at(1, "targets") { Array(xs) => xs; _ => [] }, at(2, "write") is True, text(3, "by")) {
            Some(v) => v
            None => Json::null()
          }
        None => raise P53Error("chats are not shared from here yet")
      }
    "xshare.trust" => {
      match self.share.shares {
        Some(s) => s.trust(text(0, "workspace"), text(1, "name"), text(2, "station"), text(3, "stationName"), as_=str(4, "as"))
        None => raise P53Error("chats are not shared from here yet")
      }
      Json::null()
    }
    "upkeep" => self.upkeep.pass()
    "relieve" => self.upkeep.relieving()
    "upkeep.renewables" => {
      let did = []
      self.upkeep.renewables(
        num(0, "now").unwrap_or(wall_ms().to_double()),
        p53_thumbs_cap,
        p53_node_part_ms,
        async fn(what, f) { did.push(p53_obj([("what", p53_s(what)), ("did", f())])) },
      )
      Json::array(did)
    }
    "memory.sample" => self.resources.sample()
    // (self-memory.ts `trimIdle` as a sample past the limits does it: every part's idle programs let go, the readers'
    // too, a count; and the programs counted after)
    "memory.trimIdle" => {
      let parts = (self.resources.trim_idle)()
      let readers = match (self.bus.reader_ask.val)("trimIdle", Json::null(), (self.bus.lang.val)()) {
        Number(n, ..) => n.to_int()
        _ => 0
      }
      p53_obj([("parts", p53_i(parts)), ("readers", p53_i(readers)), ("programs", Json::array(self.bus.all_helper_pids().map(p53_i)))])
    }
    "workspaceLimit" | "workspaceWatch.setLimit" =>
      p53_n(self.watch.set_limit(text(0, "session"), text(1, "station"), num(2, "gib").unwrap_or(0.0)))
    "workspaceWatch.ready" => {
      ignore(self.watch.ready())
      Json::null()
    }
    // (agents.ts's `hub.onClose`: a deleted session's limits let go)
    "workspaceWatch.forget" => {
      self.watch.ready().forget(text(0, "session"))
      Json::null()
    }
    "workspaceWatch.limit" => p53_n(self.watch.limit(text(0, "session"), text(1, "station")))
    // ── Search, skills ──
    "search" | "search.query" | "searchDeps.search.query" =>
      self.search.query(text(0, "query"), at(1, "options"))
    "searchDeps.readSkill" => p53_s(self.search.read_skill(str(0, "workspace"), text(1, "name"), match str(2, "file") { Some(f) => f; None => "SKILL.md" }))
    "searchDeps.workspaceOf" => p53_place_of(self.bus, text(0, "session"))
    "searchDeps.stations" => Json::array(p53_stations_of(self.bus, text(0, "workspace")))
    "searchDeps.ask" => {
      let request = at(1, "request")
      let (answer, _) = self.bus.call_peer(text(0, "station"), p53_str(request, "workspace"), p53_text(request, "method"), request)
      answer
    }
    "searchDeps.link" => (self.bus.hub_ask.val)("link", p53_obj([("session", at(0, "chat"))]))
    // ── Accounts and models ──
    // (a change of config.json through the bus: what every part checks it against first, the accounts' among them)
    "config.put" => (self.bus.config_update.val)(_ => arg)
    // (what the routes' `accounts.profiles` list, and what this slice said of it before: the view)
    "accounts.profiles" if !positional => self.accounts.profiles_view()
    _ if op.has_prefix("accounts.") => self.accounts.ask(op[9:].to_owned(), arg)
    // ── the shared profiles and skills (sharing/index.ts) ──
    "sharing.lendClaude" => {
      let (token, until) = self.accounts.sharing().lend_claude(at(0, "profile"), rejected=str(1, "rejected"))
      p53_obj([("token", p53_s(token)), ("expiresAt", p53_n(until))])
    }
    "sharing.lendCodex" => p53_n(self.accounts.sharing().lend_codex(at(0, "profile"), rejected=at(1, "rejected") is True))
    "sharing.lendAgy" => p53_n(self.accounts.sharing().lend_agy(at(0, "profile"), rejected=at(1, "rejected") is True))
    "sharing.shareProfile" => {
      let among = match at(3, "among") {
        Array(_) as xs => Some(strs(xs))
        _ => None
      }
      self.accounts.sharing().share_profile(text(0, "id"), !(at(1, "on") is False), at(2, "allow"), among~, by=str(4, "by"))
      Json::null()
    }
    "sharing.shareSkill" => {
      self.accounts.sharing().share_skill(text(0, "name"), !(at(1, "on") is False), at(2, "allow"))
      Json::null()
    }
    "models.refresh" => {
      self.models.refresh(str(0, "etag"))
      Json::null()
    }
    // ── Sharing, the memory, chats shared across workspaces ──
    "share.state" => self.share.state()
    "share.status" => self.share.status(arg)
    "sharing.moveProfile" => {
      let (id, share) = self.accounts.sharing().move_profile(text(0, "id"), text(1, "to"), lang=str(2, "lang"))
      p53_obj([("id", p53_s(id)), ("share", p53_opt(share))])
    }
    "sharing.unshareMoved" => p53_b(self.accounts.sharing().unshare_moved(text(0, "share"), strs(at(1, "stations"))))
    "sharing.lendTo" => {
      let (share, made, widened) = self.accounts.sharing().lend_to(text(0, "id"), text(1, "to"))
      p53_obj([("share", p53_s(share)), ("made", p53_b(made)), ("widened", p53_b(widened))])
    }
    "sharing.unlend" => {
      self.accounts.sharing().unlend(text(0, "share"), text(1, "to"), at(2, "made") is True, at(3, "widened") is True)
      Json::null()
    }
    "memory.kept" => self.share.memory_kept(text(0, "workspace"))
    "memory.level" => {
      self.share.level_now()
      Json::null()
    }
    "xshare.reaches" => p53_b(self.share.reaches(text(0, "target"), str(1, "workspace")))
    "xshare.state" => self.share.xshare_state()
    // (hub.ts `outsideChats`: the chats other workspaces share with workspace `ws`, xshare/index.ts `borrowed`)
    "xshare.borrowed" =>
      match self.share.shares {
        Some(s) => Json::array(s.borrowed(as_=str(0, "workspace")))
        None => Json::array([])
      }
    _ => raise P53Error("no jobs' ask \{op}")
  }
}

///|
/// Whether a route's path pattern (`/jobs/:id`) is `path`, and its parameters.
fn p53_route_match(pattern : String, path : String) -> Map[String, Json]? {
  let ps = pattern.split("/").filter(x => x != "").map(x => x.to_string()).to_array()
  let xs = path.split("/").filter(x => x != "").map(x => x.to_string()).to_array()
  if ps.length() != xs.length() {
    return None
  }
  let params : Map[String, Json] = Map([])
  for i, p in ps {
    if p.has_prefix(":") {
      params[p[1:].to_owned()] = Json::string(xs[i])
    } else if p != xs[i] {
      return None
    }
  }
  Some(params)
}

///|
/// `/parts/route/<path>` (a part's route of the admin API, as a request of it: `{method, path, params, query, body,
/// viewer, lang}`), `/parts/ask/<op>` (`bus.jobs_ask`), `/parts/overview/<field>`, `/parts/peer/<method>` (a peer's
/// request of this station, as the mesh would hand it: `bus.dispatch_peer`).
async fn p53_parts_door(bus : LiveBus, r : Request) -> Reply {
  let path = r.path()
  let body = if r.body.length() == 0 { Json::null() } else { attempt(() => @json.parse(p53_utf8(r.body))).unwrap_or(Json::null()) }
  let query : Map[String, Json] = Map([])
  match r.query() {
    Some(q) =>
      for kv in q.split("&") {
        let t = kv.to_string()
        match t.find("=") {
          Some(i) => query[t[:i].to_owned()] = Json::string(@share_sync.decode_uri_component(t[i + 1:].to_owned()) catch { _ => t[i + 1:].to_owned() })
          None => query[t] = Json::string("")
        }
      }
    None => ()
  }
  let viewer = p53_obj([("workspace", p53_opt(p53_home(bus))), ("home", p53_b(true)), ("role", p53_s("owner")), ("name", p53_s("a test"))])
  try {
    if path.has_prefix("/parts/route/") {
      let target = path[12:].to_owned()
      for route in bus.parts.all_routes(Json::null()) {
        if route.meth != r.meth {
          continue
        }
        match p53_route_match(route.path, target) {
          Some(params) => {
            let asked = p53_obj([
              ("method", p53_s(r.meth)),
              ("path", p53_s(target)),
              ("params", Json::object(params)),
              ("query", Json::object(query)),
              ("body", body),
              ("viewer", viewer),
              ("lang", p53_s((bus.lang.val)())),
            ])
            return json_reply(200, (route.answer)(asked))
          }
          None => ()
        }
      }
      return json_reply(404, p53_obj([("error", p53_s("no route \{r.meth} \{target}"))]))
    }
    if path.has_prefix("/parts/ask/") {
      return json_reply(200, (bus.jobs_ask.val)(path[11:].to_owned(), body))
    }
    // (the agents' side's, by name, as another part asks it on the bus: `hub_ask`)
    if path.has_prefix("/parts/hub/") {
      return json_reply(200, (bus.hub_ask.val)(path[11:].to_owned(), body))
    }
    if path.has_prefix("/parts/overview/") {
      let field = path[16:].to_owned()
      let all = bus.parts.overview_of(viewer, (bus.lang.val)())
      return json_reply(200, all.get(field).unwrap_or(Json::null()))
    }
    if path.has_prefix("/parts/peer/") {
      let (answer, _) = bus.dispatch_peer(p53_text(query |> Json::object, "from"), p53_home(bus), path[12:].to_owned(), body, None)
      return json_reply(200, answer)
    }
    json_reply(404, p53_obj([("error", p53_s("no such place"))]))
  } catch {
    // (a part's refusal by its kind too, as the routes take it: a renewal refused, a refusal, words for people)
    e =>
      json_reply(
        400,
        p53_obj([
          ("error", p53_s(p53_words(e))),
          (
            "kind",
            match e {
              @api_routes.Thrown(kind, _) | @accounts_pool.Thrown(kind, _) => p53_s(kind)
              _ => Json::null()
            },
          ),
        ]),
      )
  }
}

///|
/// What a page's stream of the resources stops by (`resources.watch.stop:<n>`).
let p53_follows : Map[String, () -> Unit] = Map([])

///|
let p53_follows_next : Ref[Int] = Ref(0)

///|
/// links/preview.ts: the previews of links, kept a while (one keeper for the station).
let p53_previews : Ref[@jobs_host.LinkPreviews?] = Ref(None)

///|
fn p53_link_previews(bus : LiveBus) -> @jobs_host.LinkPreviews {
  match p53_previews.val {
    Some(p) => p
    None => {
      let p = @jobs_host.LinkPreviews::new(@jobs_host.LinkIo::shell(bus.host))
      p53_previews.val = Some(p)
      p
    }
  }
}
