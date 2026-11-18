// What the harness gives the drivers in place of the machine and the program (`harness.mbt`): files in memory, the
// processes it says are alive, runners' sockets that say what a case scripts, and a program that keeps what it is told
// and answers each request by the case's replies. station/test/mb-agent-drivers.test.ts gives the TypeScript the same,
// on real files, its sockets and a fake of mb-agents.ts's `AgentsHost`.

///|
priv enum Node {
  File(Bytes)
  Dir
  Link(String)
}

///|
priv struct Entry {
  mut node : Node
  mut mtime : Double
  dev : Double
  ino : Double
}

///|
/// Files in memory, by their whole path.
priv struct FakeFs {
  entries : Map[String, Entry]
  mut next_ino : Double
}

///|
fn FakeFs::new() -> FakeFs {
  { entries: Map([]), next_ino: 1000000.0 }
}

///|
fn FakeFs::parent(path : String) -> String {
  match path.rev_find("/") {
    Some(0) => "/"
    Some(i) => path.substring(end=i)
    None => "."
  }
}

///|
/// A path with its links followed (none where a part is not there).
fn FakeFs::resolve(self : FakeFs, path : String, depth? : Int = 0) -> String? {
  if depth > 40 {
    return None
  }
  let parts = path.split("/").map(p => p.to_string()).filter(p => p != "").collect()
  let mut at = ""
  for i, part in parts {
    let next = "\{at}/\{part}"
    match self.entries.get(next) {
      Some({ node: Link(target), .. }) => {
        let t = if target.has_prefix("/") { target } else { "\{at}/\{target}" }
        guard self.resolve(t, depth=depth + 1) is Some(real) else { return None }
        at = real
      }
      Some(_) => at = next
      None =>
        if i == parts.length() - 1 {
          return None
        } else {
          return None
        }
    }
  }
  Some(if at == "" { "/" } else { at })
}

///|
fn FakeFs::lookup(self : FakeFs, path : String, follow : Bool) -> (String, Entry)? {
  if !follow {
    let parent = FakeFs::parent(path)
    let base = path.substring(start=parent.length() + (if parent == "/" { 0 } else { 1 }))
    guard (if parent == "/" { Some("") } else { self.resolve(parent) }) is Some(rp) else { return None }
    let key = "\{rp}/\{base}"
    return self.entries.get(key).map(e => (key, e))
  }
  guard self.resolve(path) is Some(real) else { return None }
  self.entries.get(real).map(e => (real, e))
}

///|
fn FakeFs::touch_ino(self : FakeFs) -> Double {
  self.next_ino += 1.0
  self.next_ino
}

///|
fn FakeFs::put(self : FakeFs, path : String, node : Node, mtime : Double) -> Unit {
  let parent = FakeFs::parent(path)
  let base = path.substring(start=parent.length() + (if parent == "/" { 0 } else { 1 }))
  let rp = match self.resolve(parent) {
    Some(r) => r
    None => parent
  }
  let key = if rp == "/" { "/\{base}" } else { "\{rp}/\{base}" }
  self.entries.set(key, { node, mtime, dev: 1.0, ino: self.touch_ino() })
}

///|
fn FakeFs::mkdirs(self : FakeFs, path : String, mtime : Double) -> Unit raise {
  let parts = path.split("/").map(p => p.to_string()).filter(p => p != "").collect()
  let mut at = ""
  for part in parts {
    let next = "\{at}/\{part}"
    match self.lookup(next, true) {
      Some((real, { node: Dir, .. })) => at = real
      Some(_) => raise Failed("EEXIST")
      None => {
        self.put(next, Dir, mtime)
        at = match self.resolve(next) {
          Some(r) => r
          None => next
        }
      }
    }
  }
}

///|
fn FakeFs::children(self : FakeFs, dir : String) -> Array[String] raise {
  guard self.lookup(dir, true) is Some((real, entry)) else { raise Failed("ENOENT") }
  guard entry.node is Dir else { raise Failed("ENOTDIR") }
  let prefix = if real == "/" { "/" } else { "\{real}/" }
  let out = []
  for k, _ in self.entries {
    if k.has_prefix(prefix) && k.length() > prefix.length() {
      let rest = k.substring(start=prefix.length())
      if !rest.contains("/") {
        out.push(rest)
      }
    }
  }
  out
}

///|
fn FakeFs::remove_all(self : FakeFs, path : String) -> Unit {
  guard self.lookup(path, false) is Some((key, _)) else { return }
  let prefix = "\{key}/"
  let gone = []
  for k, _ in self.entries {
    if k == key || k.has_prefix(prefix) {
      gone.push(k)
    }
  }
  for k in gone {
    self.entries.remove(k)
  }
}

///|
/// What a case's files are: each `{path, kind ("file", "dir", "link"), data (base64), target, mtime, ino}`.
fn FakeFs::from_json(v : JValue?) -> FakeFs {
  let fs = FakeFs::new()
  let items = arr_of(v).unwrap_or([])
  // (directories first, by their depth, so a file finds its folder)
  let sorted = items.copy()
  sorted.sort_by((a, c) => {
    let pa = str_at(Some(a), "path").unwrap_or("")
    let pc = str_at(Some(c), "path").unwrap_or("")
    pa.split("/").count().compare(pc.split("/").count())
  })
  for e in sorted {
    let path = str_at(Some(e), "path").unwrap_or("")
    let mtime = num_at(Some(e), "mtime").unwrap_or(0.0)
    let node = match str_at(Some(e), "kind") {
      Some("dir") => Dir
      Some("link") => Link(str_at(Some(e), "target").unwrap_or(""))
      _ => File(@base64.decode_lossy(str_at(Some(e), "data").unwrap_or("")))
    }
    let key = path
    let ino = match num_at(Some(e), "ino") {
      Some(i) => i
      None => fs.touch_ino()
    }
    fs.entries.set(key, { node, mtime, dev: num_at(Some(e), "dev").unwrap_or(1.0), ino })
  }
  fs
}

///|
/// The files as they stand, under `root`: each path, its kind, a file's contents, a link's target.
fn FakeFs::dump(self : FakeFs, root : String) -> JValue {
  let keys = []
  for k, _ in self.entries {
    if k == root || k.has_prefix("\{root}/") {
      keys.push(k)
    }
  }
  keys.sort_by(js_compare)
  arr(
    keys.map(k => {
      let e = self.entries.get(k).unwrap()
      match e.node {
        File(bytes) =>
          obj([("path", s(k)), ("kind", s("file")), ("data", s(@base64.encode(bytes)))])
        Dir => obj([("path", s(k)), ("kind", s("dir"))])
        Link(t) => obj([("path", s(k)), ("kind", s("link")), ("target", s(t))])
      }
    }),
  )
}

///|
/// A socket a case scripts: what a runner says once it is attached, and what it was told.
priv struct FakeSocket {
  path : String
  /// the lines it says after the client's first line, then whether it ends
  script : Array[String]
  told : Array[JValue]
}

///|
/// The world of a case: its files, processes, sockets and clock.
priv struct World {
  lp : Loop
  fs : FakeFs
  alive : Array[Int]
  start_times : Array[(Int, Double)]
  sockets : Array[FakeSocket]
  logs : Array[JValue]
}

///|
fn World::from_case(c : JValue) -> World {
  let lp = Loop::new(now=num_at(Some(c), "now").unwrap_or(0.0))
  let sockets = entries_of(get(Some(c), "sockets")).map(e => FakeSocket::{
    path: e.0,
    script: strings_in(Some(e.1)),
    told: [],
  })
  {
    lp,
    fs: FakeFs::from_json(get(Some(c), "fs")),
    alive: strings_in(None).map(_ => 0) +
    arr_at(Some(c), "alive").unwrap_or([]).filter_map(x => num_of(Some(x)).map(v => v.to_int())),
    start_times: entries_of(get(Some(c), "startTimes")).filter_map(e => match e.1 {
      Num(v) => Some((int_of(e.0), v))
      _ => None
    }),
    sockets,
    logs: [],
  }
}

///|
fn World::machine(self : World) -> Machine {
  let lp = self.lp
  let fs = self.fs
  {
    lp,
    sep: "/",
    socket_visible: true,
    says_leave: false,
    read_dir: p => {
      let names = fs.children(p) catch { e => return Later::fail(lp, e) }
      Later::ok(lp, names)
    },
    read_file: p => match fs.lookup(p, true) {
      Some((_, { node: File(bytes), .. })) => Later::ok(lp, utf8_text(bytes))
      Some(_) => Later::fail(lp, Failed("EISDIR"))
      None => Later::fail(lp, Failed("ENOENT"))
    },
    mtime: p => Later::ok(lp, fs.lookup(p, false).map(e => e.1.mtime)),
    size: p => Later::ok(lp, 
      match fs.lookup(p, true) {
        Some((_, { node: File(bytes), .. })) => Some(bytes.length())
        Some(_) => Some(0)
        None => None
      },
    ),
    read_at: (p, at, length) => match fs.lookup(p, true) {
      Some((_, { node: File(bytes), .. })) => {
        let start = if at < bytes.length() { at } else { bytes.length() }
        let end = if start + length < bytes.length() { start + length } else { bytes.length() }
        Later::ok(lp, bytes[start:end].to_owned())
      }
      _ => Later::fail(lp, Failed("ENOENT"))
    },
    remove: p => {
      match fs.lookup(p, false) {
        Some((key, { node: Dir, .. })) => {
          ignore(key)
          return Later::fail(lp, Failed("EISDIR"))
        }
        Some((key, _)) => fs.entries.remove(key)
        None => ()
      }
      Later::ok(lp, ())
    },
    there: p => Later::ok(lp, fs.lookup(p, true) is Some(_)),
    is_file: p => Later::ok(lp, fs.lookup(p, true) is Some((_, { node: File(_), .. }))),
    realpath: p => Later::ok(lp, fs.resolve(p)),
    make_dir: p => {
      fs.mkdirs(p, lp.now) catch {
        e => return Later::fail(lp, e)
      }
      Later::ok(lp, ())
    },
    link: (from, to) => {
      if fs.lookup(to, false) is Some(_) {
        return Later::fail(lp, Failed("EEXIST"))
      }
      match fs.lookup(from, true) {
        Some((_, entry)) => {
          let parent = FakeFs::parent(to)
          guard fs.resolve(parent) is Some(rp) else { return Later::fail(lp, Failed("ENOENT")) }
          let base = to.substring(start=parent.length() + 1)
          fs.entries.set("\{rp}/\{base}", entry)
        }
        None => fs.put(to, Link(from), lp.now)
      }
      Later::ok(lp, ())
    },
    stat: (p, follow) => Later::ok(lp, 
      fs
      .lookup(p, follow)
      .map(e => FileStat::{
        dev: e.1.dev,
        ino: e.1.ino,
        size: match e.1.node {
          File(bytes) => bytes.length().to_double()
          _ => 0.0
        },
        mtime: e.1.mtime,
        file: e.1.node is File(_),
        directory: e.1.node is Dir,
        symlink: e.1.node is Link(_),
      }),
    ),
    write_file: (p, text, _) => {
      guard fs.resolve(FakeFs::parent(p)) is Some(_) else { return Later::fail(lp, Failed("ENOENT")) }
      match fs.lookup(p, true) {
        Some((_, entry)) => {
          entry.node = File(@utf8.encode(text))
          entry.mtime = lp.now
        }
        None => fs.put(p, File(@utf8.encode(text)), lp.now)
      }
      Later::ok(lp, ())
    },
    append_file: (p, text) => {
      guard fs.resolve(FakeFs::parent(p)) is Some(_) else { return Later::fail(lp, Failed("ENOENT")) }
      match fs.lookup(p, true) {
        Some((_, { node: File(bytes), .. } as entry)) => {
          let buf = @buffer.Buffer()
          buf.write_bytes(bytes)
          buf.write_bytes(@utf8.encode(text))
          entry.node = File(buf.to_bytes())
          entry.mtime = lp.now
        }
        Some(_) => return Later::fail(lp, Failed("EISDIR"))
        None => fs.put(p, File(@utf8.encode(text)), lp.now)
      }
      Later::ok(lp, ())
    },
    remove_tree: p => {
      fs.remove_all(p)
      Later::ok(lp, ())
    },
    rename: (from, to) => {
      guard fs.lookup(from, false) is Some((key, entry)) else { return Later::fail(lp, Failed("ENOENT")) }
      fs.remove_all(to)
      let moved = []
      for k, e in fs.entries {
        if k.has_prefix("\{key}/") {
          moved.push((k, e))
        }
      }
      fs.entries.remove(key)
      let parent = FakeFs::parent(to)
      let rp = fs.resolve(parent).unwrap_or(parent)
      let base = to.substring(start=parent.length() + 1)
      let dest = "\{rp}/\{base}"
      fs.entries.set(dest, entry)
      for m in moved {
        fs.entries.remove(m.0)
        fs.entries.set(dest + m.0.substring(start=key.length()), m.1)
      }
      Later::ok(lp, ())
    },
    copy: (from, to) => {
      guard fs.lookup(from, true) is Some((key, entry)) else { return Later::fail(lp, Failed("ENOENT")) }
      let items = [(key, entry)]
      for k, e in fs.entries {
        if k.has_prefix("\{key}/") {
          items.push((k, e))
        }
      }
      let parent = FakeFs::parent(to)
      guard fs.resolve(parent) is Some(rp) else { return Later::fail(lp, Failed("ENOENT")) }
      let base = to.substring(start=parent.length() + 1)
      let dest = "\{rp}/\{base}"
      for it in items {
        fs.entries.set(dest + it.0.substring(start=key.length()), {
          node: it.1.node,
          mtime: it.1.mtime,
          dev: it.1.dev,
          ino: fs.touch_ino(),
        })
      }
      Later::ok(lp, ())
    },
    copy_file: (from, to) => match fs.lookup(from, true) {
      Some((_, { node: File(bytes), .. })) => {
        fs.put(to, File(bytes), lp.now)
        Later::ok(lp, ())
      }
      _ => Later::fail(lp, Failed("ENOENT"))
    },
    hard_link: (from, to) => {
      if fs.lookup(to, false) is Some(_) {
        return Later::fail(lp, Failed("EEXIST"))
      }
      match fs.lookup(from, true) {
        Some((_, entry)) => {
          let parent = FakeFs::parent(to)
          guard fs.resolve(parent) is Some(rp) else { return Later::fail(lp, Failed("ENOENT")) }
          let base = to.substring(start=parent.length() + 1)
          fs.entries.set("\{rp}/\{base}", entry)
          Later::ok(lp, ())
        }
        None => Later::fail(lp, Failed("ENOENT"))
      }
    },
    link_path: (from, to) => {
      fs.put(to, Link(from), lp.now)
      Later::ok(lp, ())
    },
    pid_alive: pid => self.alive.contains(pid),
    group_alive: pgid => self.alive.contains(-pgid),
    start_time: pid => Later::ok(lp, 
      match self.start_times.search_by(x => x.0 == pid) {
        Some(i) => Some(self.start_times[i].1)
        None => None
      },
    ),
    connect: (path, events) => self.connect(path, events),
    sleep: ms => {
      let out = Later::new(lp)
      lp.after(ms, () => out.resolve(())) |> ignore
      out
    },
    now: () => lp.now,
    log: (level, at, message, fields) => self.logs.push(
      obj([("level", s(level)), ("at", s(at)), ("message", s(message)), ("fields", fields)]),
    ),
  }
}

///|
/// A connection to a scripted socket: attached, it says its script a line at a time; none there, an error.
fn World::connect(self : World, path : String, events : SocketEvents) -> Socket {
  let lp = self.lp
  let found = self.sockets.search_by(x => x.path == path)
  let ended = Ref(false)
  let said = Ref(false)
  match found {
    None => lp.soon(() => (events.error)("ECONNREFUSED"))
    Some(_) => lp.soon(() => (events.connected)())
  }
  {
    write: text => match found {
      Some(i) => {
        let sock = self.sockets[i]
        for line in text.split("\n") {
          let l = line.to_string()
          if l != "" {
            sock.told.push(parse_json(l).unwrap_or(s(l)))
          }
        }
        if !said.val {
          said.val = true
          for line in sock.script {
            lp.soon(() => if !ended.val { (events.data)(line + "\n") })
          }
        }
      }
      None => ()
    },
    end: () => if !ended.val {
      ended.val = true
      lp.soon(() => (events.closed)())
    },
    destroy: () => ended.val = true,
    writable: () => !ended.val && found is Some(_),
    destroyed: () => ended.val,
  }
}

///|
/// A process as the harness's program has it: what it was told, its exit, its ack.
priv struct FakeProc {
  n : Int
  options : HostedOptions
  mut frozen : Bool
  mut gone : Bool
  mut killing : Bool
  mut said : String?
  exited : Later[String]
  frozen_state : (JValue, JValue)?
  mut to : Int
  mut waiting : Later[Unit]?
}

///|
/// The program of a case (`AgentsHost`): what it is told, each request answered by the case's replies.
priv struct FakeProgram {
  lp : Loop
  posts : Array[JValue]
  procs : Array[FakeProc]
  /// each meth's replies in turn (the last again once the rest are given)
  replies : Array[(String, Array[JValue])]
  /// the next id's ack prefix (a Codex app-server's or an ACP runtime's JSON-RPC)
  starts : Array[JValue]
  replays : Array[JValue]
  replay_own : JValue
}

///|
fn FakeProgram::new(lp : Loop, c : JValue) -> FakeProgram {
  {
    lp,
    posts: [],
    procs: [],
    replies: entries_of(get(Some(c), "replies")).map(e => (e.0, arr_of(Some(e.1)).unwrap_or([]))),
    starts: [],
    replays: [],
    replay_own: get(Some(c), "replayOwn").unwrap_or(obj([])),
  }
}

///|
fn FakeProgram::post(self : FakeProgram, v : JValue) -> Unit {
  self.posts.push(v)
}

///|
fn FakeProgram::proc_of(self : FakeProgram, n : Int) -> FakeProc? {
  match self.procs.search_by(p => p.n == n) {
    Some(i) => Some(self.procs[i])
    None => None
  }
}

///|
/// What the program read of process `n` given its owner (`HostedProcess.heard`), acknowledged once taken.
fn FakeProgram::hear(self : FakeProgram, p : FakeProc, heard : JValue) -> Unit {
  let go = () => {
    if p.gone || p.frozen {
      return None
    }
    let ack = () => self.post(obj([("ack", n(p.n)), ("to", get(Some(heard), "to").unwrap_or(Null))]))
    match (p.options.heard)({ json: heard }) {
      Took(taken) => {
        if !taken && !p.gone && !p.frozen {
          ack()
        }
        None
      }
      Writing(writing) => Some(writing.map(_ => if !p.gone && !p.frozen { ack() }))
    }
  }
  let next = match p.waiting {
    Some(w) =>
      Some(
        w.bind(_ => match go() {
          Some(l) => l
          None => done(self.lp)
        }),
      )
    None => go()
  }
  guard next is Some(next) else { return }
  p.waiting = Some(next)
  next.on(_ => match p.waiting {
    Some(w) if physical_equal(w, next) => p.waiting = None
    _ => ()
  })
}

///|
/// A line written to process `n`: a request answered by the case's replies on the next turn of the loop.
fn FakeProgram::written(self : FakeProgram, p : FakeProc, line : String) -> Unit {
  guard parse_json(line) is Some(msg) else { return }
  guard str_at(Some(msg), "method") is Some(meth) else { return }
  guard get(Some(msg), "id") is Some(id) && !(id is Null) else { return }
  guard self.replies.search_by(r => r.0 == meth) is Some(i) else { return }
  let queue = self.replies[i].1
  guard queue.length() > 0 else { return }
  let reply = if queue.length() > 1 { queue.remove(0) } else { queue[0] }
  let rpc_ = p.options.kind == "acp"
  let fields = if rpc_ { [("jsonrpc", s("2.0")), ("id", id)] } else { [("id", id)] }
  let text = json_text(spread([obj(fields), reply]))
  self.lp.soon(() => {
    let from = p.to
    p.to += @utf8.encode(text).length() + 1
    self.hear(
      p,
      obj([
        ("events", arr([])),
        ("to", n(p.to)),
        ("lines", arr([obj([("text", s(text)), ("from", n(from)), ("to", n(p.to))])])),
      ]),
    )
  })
}

///|
fn FakeProgram::make(
  self : FakeProgram,
  info : RunnerInfo,
  options : HostedOptions,
  _turn : JValue,
  _live : JValue,
) -> Proc {
  let p = {
    n: self.procs.length(),
    options,
    frozen: false,
    gone: false,
    killing: false,
    said: None,
    exited: Later::new(self.lp),
    frozen_state: None,
    to: 0,
    waiting: None,
  }
  self.procs.push(p)
  let lp = self.lp
  {
    info,
    write: line => if !p.frozen {
      self.post(obj([("write", n(p.n)), ("line", s(line))]))
      self.written(p, line)
    },
    tell: what => if !p.frozen {
      if what == "compact" {
        self.post(obj([("begin", n(p.n)), ("compact", b(true))]))
      } else {
        self.post(obj([(what, n(p.n))]))
      }
    },
    say: (what, fields) => if !p.frozen {
      self.post(spread([obj([(what, n(p.n))]), fields]))
    },
    keep_from: at => self.post(obj([("keep", n(p.n)), ("at", n(at))])),
    freeze: () => p.frozen = true,
    frozen_state: () => p.frozen_state,
    detach: () => {
      p.frozen = true
      if !p.gone {
        p.gone = true
        self.post(obj([("detach", n(p.n))]))
      }
    },
    kill: _ => {
      if p.frozen {
        return done(lp)
      }
      if p.killing {
        return p.exited.map(_ => ())
      }
      p.killing = true
      self.post(obj([("signal", n(p.n)), ("name", s("TERM"))]))
      // (the runner's process ends on TERM)
      lp.soon(() => self.exit(p, None, Some("TERM"), "") |> ignore)
      p.exited.map(_ => self.post(obj([("done", n(p.n))])))
    },
    released: () => done(lp),
    has_exited: () => p.said is Some(_),
    handed: () => p.frozen,
    thread: (thread, live, routed) => self.post(
      obj(
        [("codexThread", n(p.n)), ("id", s(thread)), ("live", live)] +
        (if routed { [("routed", b(true))] } else { [] }),
      ),
    ),
    drop_thread: thread => self.post(obj([("codexDrop", n(p.n)), ("id", s(thread))])),
    route_thread: (thread, on, was) => {
      if on || was {
        self.post(obj([("route", n(p.n)), ("on", b(on)), ("thread", s(thread))]))
      }
      false
    },
    route: _ => (),
    orphans_off: () => self.post(obj([("orphans", n(p.n)), ("on", b(false))])),
  }
}

///|
/// Its process ended (`HostedProcess.exited_`).
fn FakeProgram::exit(self : FakeProgram, p : FakeProc, code : Int?, signal : String?, stderr : String) -> Later[Unit] {
  if p.said is Some(_) {
    return done(self.lp)
  }
  let said = describe_exit(code, signal)
  p.said = Some(said)
  p.exited.resolve(said)
  if p.frozen {
    return done(self.lp)
  }
  let told = (p.options.exit)(said, stderr)
  if !p.killing {
    self.post(obj([("done", n(p.n))]))
  }
  told
}

///|
fn FakeProgram::procs_record(self : FakeProgram, m : Machine, c : JValue) -> Procs {
  ignore(m)
  ignore(c)
  {
    start: (id, program, args, env, cwd, options, turn) => {
      let info : RunnerInfo = {
        json: obj([
          ("id", s(id)),
          ("runner", n(900000 + self.procs.length())),
          ("pid", n(910000 + self.procs.length())),
          ("pgid", n(920000 + self.procs.length())),
          ("startedAt", n(0)),
          ("program", s(program)),
          ("args", strs(args)),
          ("socket", s("")),
        ]),
      }
      let fields = [
        ("id", s(id)),
        ("program", s(program)),
        ("args", strs(args)),
        ("env", env.to_json()),
        ("cwd", s(cwd)),
        ("label", s(options.label)),
        ("kind", s(options.kind)),
        ("turn", turn),
      ]
      self.starts.push(obj(fields))
      Later::ok(self.lp, self.make(info, options, turn, Null))
    },
    adopt: (info, options, turn, live) => {
      self.starts.push(
        obj([
          ("adopt", s(info.id())),
          ("label", s(options.label)),
          ("kind", s(options.kind)),
          ("turn", turn),
          ("live", live),
        ]),
      )
      self.make(info, options, turn, live)
    },
    replay_own: (kind, file, at, extra) => {
      self.replays.push(obj([("kind", s(kind)), ("file", s(file)), ("at", n(at)), ("extra", extra)]))
      Later::ok(self.lp, self.replay_own)
    },
    replay: runs => {
      self.replays.push(obj([("runs", arr(runs.map(arr)))]))
      Later::ok(self.lp, self.replay_own)
    },
    freeze: _ => done(self.lp),
    thaw: _ => (),
    close: () => done(self.lp),
  }
}

///|
/// A decimal integer's value (0 for what is not one).
fn int_of(text : String) -> Int {
  let mut v = 0
  let mut sign = 1
  for i, c in text {
    if i == 0 && c == '-' {
      sign = -1
    } else if c >= '0' && c <= '9' {
      v = v * 10 + (c.to_int() - 0x30)
    } else {
      return 0
    }
  }
  v * sign
}
