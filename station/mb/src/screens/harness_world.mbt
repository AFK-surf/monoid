// The harness's world (reader `--builder harness-screens`, station/test/mb-screens.test.ts): every port of `Io` asked
// of the test over the program's stdin and stdout, a JSON line a message, so the test gives the program and the
// TypeScript the one world and compares what each did in it.
// - the test's every message says its clock (`now`, ms; `us`, process.hrtime's µs), and may carry the world's files
//   as they are (`files`: path → base64, null a folder) for what is read before a part serves (node:fs's sync reads);
// - what needs an answer is asked `{"call": op, "id": m, …}` and answered `{"re": m, "ok": v}` or `{"re": m, "err":
//   {kind, message, …}}`: a command run to its end, a file's operation, the disks mounted, the LAN reached;
// - what is only told is `{"tell": op, …}`: a timer armed or let go, a child started, written to, ended or killed, a
//   connection opened, written to or let go, a folder watched, a line of the log, a part's callback;
// - what happens in the world comes as `{"ev": kind, …}`: a timer due, a child's output, failure or end, a write done,
//   a connection's events, a folder's change.

///|
priv struct Rpc {
  host : @host.Host
  mut next : Int
  waiting : Map[Int, @effect.Deferred[J]]
  timers : Map[Int, () -> Unit]
  children : Map[Int, ChildEvents]
  child_state : Map[Int, (Bool, Bool, Bool)]
  written : Map[Int, (String?) -> Unit]
  conns : Map[Int, ConnEvents]
  conn_gone : Map[Int, Bool]
  watches : Map[Int, ((String?) -> Unit, () -> Unit)]
  mut now : Double
  mut us : Double
  mut files : Map[String, J]
  mut random : Int
  mut catalog : @ops_platform.Catalog?
  mut os : J
}

///|
fn Rpc::send(self : Rpc, j : J) -> Unit {
  self.host.say(stringify(j))
}

///|
fn Rpc::id(self : Rpc) -> Int {
  self.next += 1
  self.next
}

///|
fn Rpc::tell(self : Rpc, op : String, fields : Array[(String, J)]) -> Unit {
  self.send(jo([("tell", js(op))] + fields))
}

///|
async fn Rpc::call(self : Rpc, op : String, fields : Array[(String, J)]) -> J {
  let id = self.id()
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  self.waiting[id] = d
  self.send(jo([("call", js(op)), ("id", ji(id))] + fields))
  d.wait()
}

///|
fn opt_num(v : Double?) -> J {
  match v {
    Some(d) => jn(d)
    None => Null
  }
}

///|
fn b64_of(j : J?) -> Bytes {
  @base64.decode_lossy(text(j).unwrap_or(""))
}

///|
/// An error the test raised for the world: as the port says it.
fn world_error(e : J) -> Error {
  let m = text(get(Some(e), "message")).unwrap_or("")
  match text(get(Some(e), "kind")) {
    Some("FsFailed") => FsFailed(m, text(get(Some(e), "code")).unwrap_or(""))
    Some("ExecFailed") =>
      ExecFailed(
        message=m,
        code=get(Some(e), "code").unwrap_or(Null),
        signal=text(get(Some(e), "signal")),
        stdout=text(get(Some(e), "stdout")).unwrap_or(""),
        stderr=text(get(Some(e), "stderr")).unwrap_or(""),
      )
    _ => Failed(m, get(Some(e), "fields").unwrap_or(Null))
  }
}

///|
async fn Rpc::fs_call(self : Rpc, op : String, fields : Array[(String, J)]) -> J raise FsFailed {
  self.call("fs.\{op}", fields) catch {
    FsFailed(_, _) as e => raise e
    e => raise FsFailed(message_of(e), "EIO")
  }
}

///|
fn stat_from(j : J) -> Stat {
  {
    dir: get(Some(j), "dir") is Some(Bool(true)),
    file: get(Some(j), "file") is Some(Bool(true)),
    link: get(Some(j), "link") is Some(Bool(true)),
    size: num(get(Some(j), "size")).unwrap_or(0.0),
    mtime_ms: num(get(Some(j), "mtimeMs")).unwrap_or(0.0),
  }
}

///|
/// The next of the world's made-up random bytes: the same sequence the test gives the TypeScript.
fn Rpc::random_byte(self : Rpc) -> Byte {
  self.random += 1
  ((self.random * 29 + 7) & 0xff).to_byte()
}

///|
fn Rpc::io(self : Rpc) -> Io {
  let host = self.host
  let clock : Clock = {
    now: () => self.now,
    after: (ms, f) => {
      let id = self.id()
      self.timers[id] = f
      self.tell("after", [("timer", ji(id)), ("ms", jn(ms))])
      () => if self.timers.contains(id) {
        self.timers.remove(id)
        self.tell("cancel", [("timer", ji(id))])
      }
    },
    micros: () => self.us,
  }
  let procs : Procs = {
    spawn: (file, args, o, events) => {
      let id = self.id()
      self.children[id] = events
      // (ended its input, destroyed its input, started)
      self.child_state[id] = (false, false, true)
      self.tell("spawn", [
        ("child", ji(id)),
        ("file", js(file)),
        ("args", jstrs(args)),
        (
          "env",
          match o.env {
            Some(e) => e.to_j()
            None => Null
          },
        ),
        ("group", jb(o.group)),
        ("verbatim", jb(o.verbatim)),
        ("stdio", jstrs([o.stdio.0, o.stdio.1, o.stdio.2])),
      ])
      let state = () => self.child_state.get(id).unwrap_or((true, true, false))
      {
        pid: () => if state().2 { Some(id) } else { None },
        write: (data, done) => {
          let fields = [("child", ji(id)), ("data", js(b64(data)))]
          match done {
            Some(f) => {
              let cb = self.id()
              self.written[cb] = f
              self.tell("child.write", fields + [("cb", ji(cb))])
            }
            None => self.tell("child.write", fields)
          }
        },
        end_input: data => {
          let (_, d, s) = state()
          self.child_state[id] = (true, d, s)
          self.tell("child.end", [("child", ji(id))] + (match data {
            Some(b) => [("data", js(b64(b)))]
            None => []
          }))
        },
        destroy_input: () => {
          let (e, _, s) = state()
          self.child_state[id] = (e, true, s)
          self.tell("child.destroy", [("child", ji(id))])
        },
        input_open: () => {
          let (e, d, _) = state()
          !e && !d
        },
        kill: signal => self.tell("child.kill", [("child", ji(id)), ("signal", js(signal)), ("group", jb(o.group))]),
        running: () => self.children.contains(id),
      }
    },
    exec: async fn(file, args, o) {
      let answer = self.call("exec", [
        ("file", js(file)),
        ("args", jstrs(args)),
        (
          "env",
          match o.env {
            Some(e) => e.to_j()
            None => Null
          },
        ),
        ("timeout", opt_num(o.timeout)),
        ("maxBuffer", opt_num(o.max_buffer)),
      ]) catch {
        ExecFailed(..) as e => raise e
        e => raise ExecFailed(message=message_of(e), code=Null, signal=None, stdout="", stderr="")
      }
      text(Some(answer)).unwrap_or("")
    },
  }
  let net : Net = {
    connect: (target, events) => {
      let id = self.id()
      self.conns[id] = events
      self.conn_gone[id] = false
      self.tell("conn", [("conn", ji(id))] + (match target {
        Unix(p) => [("unix", js(p))]
        Tcp(port) => [("port", ji(port))]
      }))
      {
        write: b => self.tell("conn.write", [("conn", ji(id)), ("data", js(b64(b)))]),
        end: () => self.tell("conn.end", [("conn", ji(id))]),
        destroy: () => {
          if self.conn_gone.get(id) == Some(true) {
            return
          }
          self.conn_gone[id] = true
          self.tell("conn.destroy", [("conn", ji(id))])
        },
        destroyed: () => self.conn_gone.get(id).unwrap_or(true),
        pause: () => (),
        flow_again: () => (),
      }
    },
  }
  let fs : Files = {
    read: async fn(path) { b64_of(Some(self.fs_call("read", [("path", js(path))]))) },
    write: async fn(path, data, mode) {
      ignore(self.fs_call("write", [("path", js(path)), ("data", js(b64(data))), ("mode", match mode { Some(m) => ji(m); None => Null })]))
    },
    access: async fn(path, mode) {
      let r = self.fs_call("access", [("path", js(path)), ("mode", ji(mode))]) catch { _ => return false }
      r is Bool(true)
    },
    readdir: async fn(path) {
      arr(Some(self.fs_call("readdir", [("path", js(path))])))
      .unwrap_or([])
      .map(e => { name: text(get(Some(e), "name")).unwrap_or(""), dir: get(Some(e), "dir") is Some(Bool(true)) })
    },
    mkdir: async fn(path, recursive, mode) {
      ignore(self.fs_call("mkdir", [("path", js(path)), ("recursive", jb(recursive)), ("mode", match mode { Some(m) => ji(m); None => Null })]))
    },
    mkdtemp: async fn(prefix) { text(Some(self.fs_call("mkdtemp", [("prefix", js(prefix))]))).unwrap_or("") },
    rename: async fn(from, to) { ignore(self.fs_call("rename", [("from", js(from)), ("to", js(to))])) },
    rm: async fn(path, recursive, force) {
      ignore(self.fs_call("rm", [("path", js(path)), ("recursive", jb(recursive)), ("force", jb(force))]))
    },
    unlink: async fn(path) { ignore(self.fs_call("unlink", [("path", js(path))])) },
    stat: async fn(path) { stat_from(self.fs_call("stat", [("path", js(path))])) },
    lstat: async fn(path) { stat_from(self.fs_call("lstat", [("path", js(path))])) },
    copy_tree: async fn(from, to) { ignore(self.fs_call("copyTree", [("from", js(from)), ("to", js(to))])) },
    read_at: async fn(path, offset, length) {
      b64_of(Some(self.fs_call("readAt", [("path", js(path)), ("offset", jn(offset)), ("length", ji(length))])))
    },
    write_at: async fn(path, offset, data) {
      ignore(self.fs_call("writeAt", [("path", js(path)), ("offset", jn(offset)), ("data", js(b64(data)))]))
    },
    create: async fn(path) { ignore(self.fs_call("create", [("path", js(path))])) },
    append: async fn(path, data) { ignore(self.fs_call("append", [("path", js(path)), ("data", js(b64(data)))])) },
    exists_sync: path => self.files.contains(path),
    read_sync: path => match self.files.get(path) {
      Some(Str(_) as s) => Some(@utf8.decode_lossy(b64_of(Some(s))))
      _ => None
    },
    watch: (dir, listener, failed) => {
      guard self.files.get(dir) is Some(Null) else {
        raise FsFailed("ENOENT: no such file or directory, watch '\{dir}'", "ENOENT")
      }
      let id = self.id()
      self.watches[id] = (listener, failed)
      self.tell("watch", [("watch", ji(id)), ("dir", js(dir))])
      () => if self.watches.contains(id) {
        self.watches.remove(id)
        self.tell("unwatch", [("watch", ji(id))])
      }
    },
  }
  let os_s = (k : String) => text(get(Some(self.os), k)).unwrap_or("")
  let os : Os = {
    hostname: () => os_s("hostname"),
    tmpdir: () => os_s("tmpdir"),
    homedir: () => os_s("homedir"),
    arch: os_s("arch"),
    os: os_s("os"),
    uid: num(get(Some(self.os), "uid")).map(d => d.to_int()),
    exec_path: os_s("execPath"),
    pid: num(get(Some(self.os), "pid")).unwrap_or(1.0).to_int(),
    env: () => Env::of_j(get(Some(self.os), "env").unwrap_or(Obj([]))),
    runnable: (file, args, _) => { file, args, verbatim: false },
    runnable_soon: async fn(file, args, _) { { file, args, verbatim: false } },
    mounts_soon: async fn() { arr(Some(self.call("mounts", []))).unwrap_or([]).filter_map(m => text(Some(m))) },
    code_dir: os_s("codeDir"),
    date_parse: s => date_parse_utc(s),
    cwd: os_s("cwd"),
  }
  {
    clock,
    spawn: f => ignore(host.rt.fork(f)),
    procs,
    net,
    fs,
    log: { say: (level, part, words, fields) => self.tell("log", [("level", js(level)), ("part", js(part)), ("message", js(words)), ("fields", fields)]) },
    os,
    words: {
      tr: (lang, key, args) => match self.catalog {
        Some(c) => {
          let m : Map[String, Json] = Map::new()
          match args {
            Obj(ps) => for p in ps {
              m[@jsjson.sanitize_str(p.0)] = core_json(p.1)
            }
            _ => ()
          }
          @ops_platform.tr(c, lang, key, m)
        }
        None => key
      },
      station_lang: () => "en",
    },
    random: n => Bytes::from_array(FixedArray::makei(n, _ => self.random_byte())),
    random_int: (lo, hi) => {
      self.random += 1
      lo + (self.random * 7919) % (hi - lo)
    },
  }
}

///|
/// What the world says happened: given to the part that waits for it.
fn Rpc::event(self : Rpc, e : J) -> Unit {
  let n = (k : String) => num(get(Some(e), k)).unwrap_or(0.0).to_int()
  match text(get(Some(e), "ev")) {
    Some("timer") =>
      match self.timers.get(n("timer")) {
        Some(f) => {
          self.timers.remove(n("timer"))
          f()
        }
        None => ()
      }
    Some("child") => {
      let id = n("child")
      guard self.children.get(id) is Some(events) else { return }
      match text(get(Some(e), "kind")) {
        Some("out") => (events.out)(b64_of(get(Some(e), "data")))
        Some("err") => (events.err)(b64_of(get(Some(e), "data")))
        Some("error") => {
          if get(Some(e), "started") is Some(Bool(false)) {
            let (a, b, _) = self.child_state.get(id).unwrap_or((false, false, false))
            self.child_state[id] = (a, b, false)
          }
          (events.error)(text(get(Some(e), "message")).unwrap_or(""))
        }
        Some("close") => {
          self.children.remove(id)
          let code = num(get(Some(e), "code")).map(d => d.to_int())
          (events.close)(code, text(get(Some(e), "signal")))
        }
        _ => ()
      }
    }
    Some("written") =>
      match self.written.get(n("cb")) {
        Some(f) => {
          self.written.remove(n("cb"))
          f(text(get(Some(e), "error")))
        }
        None => ()
      }
    Some("conn") => {
      let id = n("conn")
      guard self.conns.get(id) is Some(events) else { return }
      match text(get(Some(e), "kind")) {
        Some("connect") => (events.connect)()
        Some("data") => (events.data)(b64_of(get(Some(e), "data")))
        Some("error") => (events.error)(text(get(Some(e), "message")).unwrap_or(""))
        Some("close") => {
          self.conns.remove(id)
          self.conn_gone[id] = true
          (events.close)()
        }
        _ => ()
      }
    }
    Some("watch") =>
      match self.watches.get(n("watch")) {
        Some((listener, failed)) =>
          if get(Some(e), "error") is Some(Bool(true)) {
            failed()
          } else {
            listener(text(get(Some(e), "name")))
          }
        None => ()
      }
    _ => ()
  }
}

///|
/// `Date.parse` of what these parts read, the time zone where the words say none taken as UTC (the test's own):
/// ISO's `2026-11-06T08:34:52(.123)(Z|±hh:mm)` and `ps`'s `Fri Nov  6 16:34:52 2026`; NaN for anything else.
pub fn date_parse_utc(s : String) -> Double {
  let t = trim_js(s)
  let digits = (from : Int, n : Int) => {
    if from + n > t.length() {
      return None
    }
    let mut v = 0
    for i in from..<(from + n) {
      let c = t.unsafe_get(i).to_int()
      if c < '0'.to_int() || c > '9'.to_int() {
        return None
      }
      v = v * 10 + (c - '0'.to_int())
    }
    Some(v)
  }
  let at = (i : Int) => if i < t.length() { t.unsafe_get(i).to_int() } else { -1 }
  // ISO 8601
  match (digits(0, 4), at(4), digits(5, 2), at(7), digits(8, 2)) {
    (Some(y), 45, Some(mo), 45, Some(d)) => {
      if t.length() == 10 {
        return utc_ms(y, mo, d, 0, 0, 0, 0)
      }
      guard at(10) == 'T'.to_int() else { return @double.not_a_number }
      guard (digits(11, 2), at(13), digits(14, 2)) is (Some(h), 58, Some(mi)) else { return @double.not_a_number }
      let mut i = 16
      let mut sec = 0
      let mut ms = 0
      if at(i) == ':'.to_int() {
        guard digits(i + 1, 2) is Some(se) else { return @double.not_a_number }
        sec = se
        i += 3
        if at(i) == '.'.to_int() {
          let mut j = i + 1
          let mut frac = 0
          let mut n = 0
          while at(j) >= '0'.to_int() && at(j) <= '9'.to_int() {
            if n < 3 {
              frac = frac * 10 + (at(j) - '0'.to_int())
              n += 1
            }
            j += 1
          }
          while n < 3 {
            frac *= 10
            n += 1
          }
          ms = frac
          i = j
        }
      }
      let mut offset = 0
      if at(i) == 'Z'.to_int() {
        i += 1
      } else if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
        let sign = if at(i) == '+'.to_int() { 1 } else { -1 }
        guard (digits(i + 1, 2), at(i + 3), digits(i + 4, 2)) is (Some(oh), 58, Some(om)) else { return @double.not_a_number }
        offset = sign * (oh * 60 + om)
        i += 6
      }
      if i != t.length() {
        return @double.not_a_number
      }
      return utc_ms(y, mo, d, h, mi, sec, ms) - offset.to_double() * 60000.0
    }
    _ => ()
  }
  // `Fri Nov  6 16:34:52 2026`
  let words = split_space(t)
  if words.length() == 5 {
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    match months.search(words[1]) {
      Some(m) => {
        let d = js_number(words[2])
        let y = js_number(words[4])
        let hms = words[3].split(":").map(v => js_number(v.to_string())).collect()
        if hms.length() == 3 && is_integer(d) && is_integer(y) && hms.iter().all(is_integer) {
          return utc_ms(y.to_int(), m + 1, d.to_int(), hms[0].to_int(), hms[1].to_int(), hms[2].to_int(), 0)
        }
      }
      None => ()
    }
  }
  @double.not_a_number
}

///|
fn utc_ms(y : Int, mo : Int, d : Int, h : Int, mi : Int, s : Int, ms : Int) -> Double {
  let days = @time.days_from_civil(y, mo, d)
  days.to_double() * 86400000.0 + (h * 3600000 + mi * 60000 + s * 1000 + ms).to_double()
}
