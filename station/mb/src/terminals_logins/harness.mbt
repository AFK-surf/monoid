// The tests' way in (station/test/mb-terminals-logins.test.ts, through stillfail-reader `--builder
// harness-terminals-logins`), held to the TypeScript of station/src/terminals and station/src/logins on the same cases.
// A JSON line a case on stdin, a JSON line its outcome on stdout (`{"ok": …}` or `{"error": …}`): "words" (the
// station's words, once), "pure" (a function of nothing but its arguments, by its TypeScript name), "vt" (writes to
// the terminal and what it shows and answers), "wire" (a runner's socket read and written), "terminals" (views on a
// station's terminals, with runners and members' streams of the test's), "run" (one login's run, its command's output
// given), "logins" (the logins, their commands, pages and callbacks of the test's). A case with steps is worked out
// whole in a world of its own on a clock of its own: each step taken, then all it set going run to rest, what each
// step answered and what the world was asked written down, so the outcome is a function of the case alone; the test
// gives the TypeScript the same world.

///|
let catalog : Ref[@ops_platform.Catalog?] = Ref(None)

///|
fn words_of_catalog(lang : String, key : String, args : Map[String, String]) -> String {
  let c = match catalog.val {
    Some(c) => c
    None => @ops_platform.Catalog::from_json(Json::null(), Json::null())
  }
  let m : Map[String, Json] = {}
  for k, v in args {
    m[k] = Json::string(v)
  }
  @ops_platform.tr(c, lang, key, m)
}

///|
/// A clock and its fibers, of a case's own.
priv struct World {
  rt : @effect.Runtime
  defects : Array[String]
}

///|
fn World::new(now : Double) -> World {
  let w = { rt: @effect.Runtime::new(start=now.to_int64()), defects: [] }
  w.rt.on_defect(e => w.defects.push(error_message(e)))
  w
}

///|
fn World::spawn(self : World, f : async () -> Unit) -> Unit {
  self.rt.fork(f) |> ignore
}

///|
fn World::after(self : World, ms : Int, f : () -> Unit) -> () -> Unit {
  let fiber = self.rt.fork(async fn() {
    @effect.sleep(if ms < 0 { 0 } else { ms })
    f()
  })
  () => fiber.interrupt()
}

///|
/// What was set going run to rest, the clock where it is.
fn World::settle(self : World) -> Unit {
  let mut turns = 0
  while turns < 100000 {
    turns += 1
    self.rt.advance(0)
    if self.rt.idle() {
      break
    }
  }
}

///|
/// The clock moved on `ms`, each timer at its own time, and all it set going run to rest.
fn World::advance(self : World, ms : Int) -> Unit {
  let until = self.rt.now() + ms.to_int64()
  while true {
    match self.rt.next_timer() {
      Some(at) if at <= until => {
        let d = at - self.rt.now()
        self.rt.advance(if d > 0L { d.to_int() } else { 0 })
        self.settle()
      }
      _ => break
    }
  }
  let left = until - self.rt.now()
  if left > 0L {
    self.rt.advance(left.to_int())
  }
  self.settle()
}

///|
fn World::now(self : World) -> Double {
  self.rt.now().to_double()
}

///|
fn arg_at(args : J?, i : Int) -> J? {
  match args {
    Some(Arr(a)) if i < a.length() => Some(a[i])
    _ => None
  }
}

///|
fn str_at(args : J?, i : Int) -> String? {
  text(arg_at(args, i))
}

///|
fn opt_str(s : String?) -> J {
  match s {
    Some(x) => js(x)
    None => Null
  }
}

///|
fn bytes_json(b : Bytes?) -> J {
  match b {
    Some(x) => js(base64_of(x))
    None => Null
  }
}

///|
fn screen_from(j : J?) -> Screen? {
  match j {
    Some(Obj(_)) => {
      let rows = match get(j, "rows") {
        Some(Arr(rs)) => rs.map(r => text(Some(r)).unwrap_or(""))
        _ => []
      }
      let c = get(j, "cursor")
      Some({
        rows,
        cursor: (int_of(get(c, "x")), int_of(get(c, "y"))),
        echo: !(get(j, "echo") is Some(Bool(false))),
        live: get(j, "live") is Some(Bool(true)),
      })
    }
    _ => None
  }
}

///|
fn where_from(j : J?) -> Where? {
  match j {
    Some(Obj(_)) => Some({ station: text(get(j, "station")).unwrap_or(""), name: text(get(j, "name")).unwrap_or("") })
    _ => None
  }
}

///|
fn callback_from(j : J?) -> Callback {
  {
    method_: text(get(j, "method")).unwrap_or("GET"),
    path: text(get(j, "path")).unwrap_or("/"),
    headers: match get(j, "headers") {
      Some(Obj(ps)) => ps.map(p => (p.0, text(Some(p.1)).unwrap_or("")))
      _ => []
    },
    body: text(get(j, "body")),
  }
}

///|
fn env_from(j : J?) -> Env {
  let env : Env = {}
  match j {
    Some(Obj(ps)) =>
      for p in ps {
        env[p.0] = text(Some(p.1)).unwrap_or("")
      }
    _ => ()
  }
  env
}

///|
fn env_json(env : Env) -> J {
  jo(env.iter().map(kv => (kv.0, js(kv.1))).collect())
}

///|
fn pure_case(name : String, args : J?) -> J raise {
  match name {
    "asked" =>
      match asked(arg_at(args, 0)) {
        Some(a) => a.to_json()
        None => Null
      }
    "sizeOf" =>
      match size_of(utf8_of(str_at(args, 0).unwrap_or(""))) {
        Some((c, r)) => jo([("cols", ji(c)), ("rows", ji(r))])
        None => Null
      }
    "controlOf" =>
      match control_of(utf8_of(str_at(args, 0).unwrap_or(""))) {
        Some(c) => c.to_json()
        None => Null
      }
    "pastScreen" => {
      let out = { at: num(arg_at(args, 0)).unwrap_or(0.0), bytes: from_base64(str_at(args, 1).unwrap_or("")) }
      bytes_json(past_screen(out, num(arg_at(args, 2)).unwrap_or(0.0)))
    }
    "metaOf" =>
      match meta_of(arg_at(args, 0)) {
        Some(m) => m.to_json()
        None => Null
      }
    "shell" => {
      let (p, a) = shell_of(str_at(args, 0).unwrap_or(""), str_at(args, 1))
      jo([("program", js(p)), ("args", jstrs(a))])
    }
    "channelFrom" => js(channel_from(arg_at(args, 0), str_at(args, 1)))
    "featureOn" =>
      jb(feature_on_channel(str_at(args, 0), arg_at(args, 1) is Some(Bool(true)), str_at(args, 2).unwrap_or("")))
    "keychain" => {
      let env = env_from(arg_at(args, 0))
      keychain_out_of_git(env)
      env_json(env)
    }
    "lastLines" => js(last_lines(str_at(args, 0).unwrap_or("")))
    "slackPage" =>
      match slack_page(arg_at(args, 0).unwrap_or(Null)) {
        Some(p) => p
        None => Null
      }
    "limited" => limited(arg_at(args, 0).unwrap_or(Null))
    "screenFor" => js(screen_for(screen_from(arg_at(args, 0)), arg_at(args, 1).unwrap_or(Null)))
    "told" =>
      js(
        told_with(
          screen_from(arg_at(args, 3)),
          arg_at(args, 0).unwrap_or(Null),
          str_at(args, 1),
          where_?=where_from(arg_at(args, 2)),
        ),
      )
    "endedNotice" =>
      js(ended_notice(arg_at(args, 0).unwrap_or(Null), str_at(args, 1), where_?=where_from(arg_at(args, 2))))
    "promptNotice" =>
      js(
        prompt_notice_with(
          screen_from(arg_at(args, 3)),
          arg_at(args, 0).unwrap_or(Null),
          str_at(args, 1),
          where_?=where_from(arg_at(args, 2)),
        ),
      )
    "formGet" => opt_str(form_get(str_at(args, 0).unwrap_or(""), str_at(args, 1).unwrap_or("")))
    "stateOf" => opt_str(state_of(callback_from(arg_at(args, 0))))
    "fromBase64" => {
      let b = from_base64(str_at(args, 0).unwrap_or(""))
      ja(b.iter().map(x => ji(x.to_int())).collect())
    }
    "decode" => {
      let d = Utf8Decoder::new()
      match arg_at(args, 0) {
        Some(Arr(chunks)) => ja(chunks.map(c => js(d.write(from_base64(text(Some(c)).unwrap_or(""))))))
        _ => ja([])
      }
    }
    "encodeURIComponent" => js(encode_uri_component(str_at(args, 0).unwrap_or("")))
    "loginTool" => login_tool()
    "frame" => js(base64_of(frame(int_of(arg_at(args, 0)), from_base64(str_at(args, 1).unwrap_or("")))))
    "programOf" =>
      match arg_at(args, 0) {
        Some(Arr(ws)) => js(@ops_platform.program_of(ws.map(w => text(Some(w)).unwrap_or(""))))
        _ => Null
      }
    _ => raise Failure("no such function: \{name}")
  }
}

///|
fn vt_case(c : J) -> J {
  let rows = int_of(get(Some(c), "rows"))
  let vt = Vt::new(int_of(get(Some(c), "cols")), rows, int_of(get(Some(c), "scrollback")))
  let replies = []
  vt.on_data(d => replies.push(js(d)))
  vt.osc(10, data => if data == "?" {
    replies.push(js("\u{1b}]10;rgb:0000/0000/0000\u{1b}\\"))
    true
  } else {
    false
  })
  vt.osc(11, data => if data == "?" {
    replies.push(js("\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\"))
    true
  } else {
    false
  })
  match get(Some(c), "writes") {
    Some(Arr(ws)) =>
      for w in ws {
        vt.write(text(Some(w)).unwrap_or(""))
      }
    _ => ()
  }
  jo([
    ("rows", ja(Array::makei(rows, i => js(vt.row(i))))),
    ("x", ji(vt.cursor_x())),
    ("y", ji(vt.cursor_y())),
    ("replies", ja(replies)),
  ])
}

///|
fn said_json(m : Said) -> J {
  match m {
    Line(j) => jo([("line", j)])
    Output(at, bytes) => jo([("out", jo([("at", jn(at)), ("bytes", js(base64_of(bytes)))]))])
  }
}

///|
fn wire_case(c : J) -> J {
  let written = []
  let datas : Array[(Bytes) -> Unit] = []
  let closes : Array[() -> Unit] = []
  let writable = !(get(Some(c), "writable") is Some(Bool(false)))
  let wire = runner_wire({
    write: line => written.push(js(line)),
    end: () => written.push(js("<end>")),
    writable: () => writable,
    on_data: f => datas.push(f),
    on_close: f => closes.push(f),
    says_leave: get(Some(c), "saysLeave") is Some(Bool(true)),
  })
  let told = []
  (wire.on_line)(m => told.push(said_json(m)))
  let closed = Ref(0)
  (wire.on_close)(() => closed.val += 1)
  match get(Some(c), "reads") {
    Some(Arr(rs)) =>
      for r in rs {
        let b = from_base64(text(Some(r)).unwrap_or(""))
        for f in datas {
          f(b)
        }
      }
    _ => ()
  }
  match get(Some(c), "writes") {
    Some(Arr(ws)) =>
      for w in ws {
        (wire.write)(text(Some(w)).unwrap_or(""))
      }
    _ => ()
  }
  if get(Some(c), "end") is Some(Bool(true)) {
    (wire.end)()
  }
  if get(Some(c), "close") is Some(Bool(true)) {
    for f in closes {
      f()
    }
  }
  jo([("told", ja(told)), ("written", ja(written)), ("closed", ji(closed.val))])
}

// ── terminals ──

///|
/// A runner as its link sees it: what it was sent, and what it says.
priv struct FakeRunner {
  sent : Array[J]
  lines : Array[(Said) -> Unit]
  closes : Array[() -> Unit]
  mut at : Double
}

///|
fn FakeRunner::new() -> FakeRunner {
  { sent: [], lines: [], closes: [], at: 0.0 }
}

///|
fn FakeRunner::wire(self : FakeRunner) -> Wire {
  {
    write: line => self.sent.push(js(line)),
    end: () => self.sent.push(js("<end>")),
    on_line: f => self.lines.push(f),
    on_close: f => self.closes.push(f),
  }
}

///|
fn FakeRunner::say(self : FakeRunner, m : J) -> Unit {
  for f in self.lines.copy() {
    f(Line(m))
  }
}

///|
/// A member's stream: what the client sends (its head line given apart), what it is answered.
priv struct FakeStream {
  written : Array[Bytes]
  inbox : @effect.Queue[Bytes?]
  mut finished : Bool
  mut done : Bool
  mut error : String?
}

///|
fn FakeStream::new() -> FakeStream {
  { written: [], inbox: @effect.Queue::unbounded(), finished: false, done: false, error: None }
}

///|
fn FakeStream::stream(self : FakeStream) -> Stream {
  {
    read: async fn() { self.inbox.take() },
    write: async fn(b) { self.written.push(b) },
    finish: async fn() { self.finished = true },
  }
}

///|
fn FakeStream::to_json(self : FakeStream) -> J {
  let b = @buffer.new()
  for w in self.written {
    b.write_bytes(w)
  }
  jo([
    ("written", js(base64_of(b.to_bytes()))),
    ("finished", jb(self.finished)),
    ("done", jb(self.done)),
    ("error", opt_str(self.error)),
  ])
}

///|
fn viewer_from(j : J?) -> Viewer {
  let name = text(get(j, "name")).unwrap_or("")
  {
    name,
    email: text(get(j, "email")).unwrap_or(name + "@x"),
    role: text(get(j, "role")).unwrap_or("member"),
    workspace: text(get(j, "workspace")).unwrap_or("w1"),
    device: text(get(j, "device")).unwrap_or(name + "-device"),
  }
}

///|
fn frame_bytes(step : J?) -> Bytes? {
  if get(step, "end") is Some(Bool(true)) {
    return None
  }
  match text(get(step, "raw")) {
    Some(raw) => Some(from_base64(raw))
    None => Some(frame(int_of(get(step, "kind")), utf8_of(text(get(step, "payload")).unwrap_or(""))))
  }
}

///|
fn terminals_case(c : J) -> J {
  let w = World::new(num(get(Some(c), "now")).unwrap_or(0.0))
  let now = num(get(Some(c), "wall")).unwrap_or(0.0)
  let runners : Array[FakeRunner] = []
  let starts = []
  let gone = []
  let changes = Ref(0)
  let n = Ref(0)
  let fails = match get(Some(c), "startFails") {
    Some(Obj(_) as f) => Some(f)
    _ => None
  }
  let chats = get(Some(c), "chats")
  let offered = match get(Some(c), "offered") {
    Some(Bool(b)) => Some(fn() { b })
    _ => None
  }
  let terminals = Terminals::new({
    home: text(get(Some(c), "home")).unwrap_or("/home/a"),
    chat_dir: chat => text(get(chats, chat)),
    new_id: () => {
      n.val += 1
      "term-\{n.val}"
    },
    changed: _ => changes.val += 1,
    meta: None,
    gone: id => gone.push(js(id)),
    offered,
    now: () => now,
    spawn: f => w.spawn(f),
    log: (_, _) => (),
    start: async fn(id, o, cwd, meta) {
      starts.push(
        jo([("id", js(id)), ("cwd", js(cwd)), ("cols", ji(o.cols)), ("rows", ji(o.rows)), ("meta", meta.to_json())]),
      )
      match text(get(fails, starts.length().to_string())) {
        Some(m) => raise Failure(m)
        None => ()
      }
      let r = FakeRunner::new()
      runners.push(r)
      TerminalLink::new(r.wire())
    },
  })
  let streams : Map[String, FakeStream] = {}
  let results = []
  match get(Some(c), "steps") {
    Some(Arr(steps)) =>
      for step in steps {
        let s = Some(step)
        let result : J = match text(get(s, "do")) {
          Some("view") => {
            let name = text(get(s, "stream")).unwrap_or("")
            let fs = FakeStream::new()
            streams[name] = fs
            let head = match get(s, "head") {
              Some(h) => h
              None =>
                jo([
                  ("method", js("POST")),
                  ("path", js("/admin/api/terminals/\{text(get(s, "id")).unwrap_or("new")}/view")),
                  ("terminal", or_null(get(s, "terminal"))),
                ])
            }
            let carry = from_base64(text(get(s, "carry")).unwrap_or(""))
            let viewer = viewer_from(get(s, "viewer"))
            w.spawn(async fn() {
              terminals.answer(fs.stream(), carry, head, viewer) catch {
                e => fs.error = Some(error_message(e))
              }
              fs.done = true
            })
            Null
          }
          Some("out") => {
            let r = runners[int_of(get(s, "runner"))]
            let data = utf8_of(text(get(s, "text")).unwrap_or(""))
            r.say(jo([("op", js("out")), ("stream", js("out")), ("at", jn(r.at)), ("data", js(base64_of(data)))]))
            r.at += data.length().to_double()
            Null
          }
          Some("screen") => {
            let r = runners[int_of(get(s, "runner"))]
            let ps = [
              ("op", js("screen")),
              ("at", jn(num(get(s, "at")).unwrap_or(r.at))),
              ("data", js(base64_of(utf8_of(text(get(s, "text")).unwrap_or(""))))),
            ]
            match get(s, "cols") {
              Some(v) => ps.push(("cols", v))
              None => ()
            }
            match get(s, "rows") {
              Some(v) => ps.push(("rows", v))
              None => ()
            }
            r.say(jo(ps))
            Null
          }
          Some("say") => {
            runners[int_of(get(s, "runner"))].say(or_null(get(s, "message")))
            Null
          }
          Some("close") => {
            for f in runners[int_of(get(s, "runner"))].closes.copy() {
              f()
            }
            Null
          }
          Some("send") => {
            let fs = streams.get(text(get(s, "stream")).unwrap_or("")).unwrap()
            fs.inbox.try_offer(frame_bytes(s)) |> ignore
            Null
          }
          Some("end") =>
            jb(
              terminals.end(
                text(get(s, "id")).unwrap_or(""),
                text(get(s, "by")).unwrap_or(""),
                text(get(s, "workspace")).unwrap_or("w1"),
              ),
            )
          Some("keep") => {
            let r = FakeRunner::new()
            runners.push(r)
            match meta_of(get(s, "meta")) {
              Some(m) =>
                terminals.keep(
                  text(get(s, "id")).unwrap_or(""),
                  TerminalLink::new(r.wire()),
                  m,
                  (get(s, "cols"), get(s, "rows")),
                )
              None => ()
            }
            Null
          }
          Some("detach") => {
            terminals.detach()
            Null
          }
          Some("list") => terminals.list(text(get(s, "workspace")).unwrap_or("w1"))
          Some("workspaces") => jstrs(terminals.workspaces())
          _ => Null
        }
        w.settle()
        results.push(result)
      }
    _ => ()
  }
  jo([
    ("results", ja(results)),
    ("starts", ja(starts)),
    ("gone", ja(gone)),
    ("changes", ji(changes.val)),
    ("runners", ja(runners.map(r => ja(r.sent)))),
    ("streams", jo(streams.iter().map(kv => (kv.0, kv.1.to_json())).collect())),
    ("defects", jstrs(w.defects)),
  ])
}

// ── one login's run ──

///|
fn run_snapshot(r : LoginRun, changed : Int, drawn : Int) -> J {
  jo([
    ("state", js(r.state)),
    ("step", opt_str(r.step)),
    ("url", opt_str(r.url)),
    (
      "loopback",
      match r.loopback {
        Some(l) => loopback_json(l)
        None => Null
      },
    ),
    ("code", opt_str(r.code)),
    ("codeUrl", opt_str(r.code_url)),
    ("waiting", jb(r.waiting)),
    ("paste", jb(r.paste)),
    ("echo", jb(r.echo)),
    ("error", opt_str(r.error)),
    (
      "endedAt",
      match r.ended_at {
        Some(t) => jn(t)
        None => Null
      },
    ),
    ("timedOut", jb(r.timed_out)),
    ("hadBrowserStep", jb(r.had_browser_step)),
    ("relayed", jb(r.relayed)),
    ("secret", jb(r.secret())),
    ("active", jb(r.active())),
    ("startedAt", jn(r.started_at)),
    ("expiresAt", jn(r.expires_at)),
    ("screen", r.screen().to_json()),
    ("changed", ji(changed)),
    ("drawn", ji(drawn)),
  ])
}

///|
/// What a world's platform answers where a case says nothing of it.
fn plain_run_io(w : World, files : Map[String, String], log : Array[J]) -> RunIo {
  {
    now: () => w.now(),
    after: (ms, f) => w.after(ms, f),
    spawn: f => w.spawn(f),
    home: env => env.get("HOME"),
    prepend_path: (env, dir) => {
      let out = env.copy()
      out["PATH"] = match env.get("PATH") {
        Some(p) if p != "" => dir + ":" + p
        _ => dir
      }
      out
    },
    exe: name => name,
    with_shell_command: async fn(_, _) { None },
    terminal: async fn(_, _, _, _) { None },
    runnable: async fn(file, args, _) { (file, args) },
    start_command: (_, _, _, _) => raise Failure("no commands in this world"),
    started: async fn(_) { None },
    end_command: (_, signal) => log.push(jo([("signal", js(signal))])),
    descendants: async fn(_) { [] },
    echoes: async fn(_) { None },
    commands: async fn(_) { [] },
    read_file: async fn(path) {
      match files.get(path) {
        Some(t) => t
        None => raise Failure("ENOENT: no such file or directory, open '\{path}'")
      }
    },
    watch: (_, _) => () => (),
    tr: words_of_catalog,
    log: (_, _) => (),
  }
}

///|
fn run_case(c : J) -> J {
  let w = World::new(num(get(Some(c), "now")).unwrap_or(0.0))
  let files : Map[String, String] = {}
  let log = []
  let opened = text(get(Some(c), "opened")).unwrap_or("/data/run/logins/l1.opened")
  let changed = Ref(0)
  let drawn = Ref(0)
  let words = match get(Some(c), "command") {
    Some(Arr(ws)) => ws.map(x => text(Some(x)).unwrap_or(""))
    _ => ["gh", "auth", "login"]
  }
  let run = LoginRun::new(
    {
      id: "l1",
      command: words,
      env: {},
      cwd: "/home/a",
      shims: "/data/run/login-shims",
      opened,
      lang: text(get(Some(c), "lang")).unwrap_or("en"),
      changed: () => changed.val += 1,
      drawn: () => drawn.val += 1,
    },
    plain_run_io(w, files, log),
  )
  let results = []
  match get(Some(c), "steps") {
    Some(Arr(steps)) =>
      for step in steps {
        let s = Some(step)
        let result : J = match text(get(s, "do")) {
          Some("say") => {
            run.output(text(get(s, "text")).unwrap_or(""))
            Null
          }
          Some("file") => {
            files[opened] = text(get(s, "text")).unwrap_or("")
            Null
          }
          Some("advance") => {
            w.advance(int_of(get(s, "ms")))
            Null
          }
          Some("input") => {
            match (text(get(s, "key")), text(get(s, "text"))) {
              (Some(k), _) => run.input(key=k)
              (_, Some(t)) => run.input(text=t)
              _ => run.input()
            }
            Null
          }
          Some("cancel") => {
            run.cancel()
            Null
          }
          Some("close") => {
            run.close()
            Null
          }
          Some("paste") => jb(run.ask_paste(get(s, "on") is Some(Bool(true))))
          Some("answered") => {
            run.answered_now()
            Null
          }
          Some("relayed") => {
            run.relayed_now()
            Null
          }
          Some("check") =>
            try {
              check(run, callback_from(get(s, "callback")))
              js("ok")
            } catch {
              Refused(status, message) => jo([("status", ji(status)), ("message", js(message))])
            }
          Some("quiet") => {
            // what waits for the next quiet: whether it came by the steps after
            let d = run.next_quiet()
            let got = Ref(false)
            w.spawn(async fn() {
              d.wait()
              got.val = true
            })
            w.settle()
            jb(got.val)
          }
          Some("snapshot") => run_snapshot(run, changed.val, drawn.val)
          _ => Null
        }
        w.settle()
        results.push(result)
      }
    _ => ()
  }
  jo([
    ("results", ja(results)),
    ("final", run_snapshot(run, changed.val, drawn.val)),
    ("log", ja(log)),
    ("defects", jstrs(w.defects)),
  ])
}

///|
fn case_of(c : J) -> J raise {
  match text(get(Some(c), "op")) {
    Some("words") => {
      catalog.val = Some(
        @ops_platform.Catalog::from_json(
          @json.parse(stringify(or_null(get(Some(c), "zh")))),
          @json.parse(stringify(or_null(get(Some(c), "en")))),
        ),
      )
      Null
    }
    Some("pure") => pure_case(text(get(Some(c), "fn")).unwrap_or(""), get(Some(c), "args"))
    Some("vt") => vt_case(c)
    Some("wire") => wire_case(c)
    Some("terminals") => terminals_case(c)
    Some("run") => run_case(c)
    Some("logins") => logins_case(c)
    _ => raise Failure("no such case")
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = try {
      let c = parse(line)
      jo([("ok", case_of(c))])
    } catch {
      e => jo([("error", js(error_message(e)))])
    }
    host.say(stringify(answer))
  }
}
