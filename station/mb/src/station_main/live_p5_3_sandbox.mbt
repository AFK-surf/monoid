// The host side of a sandbox's bridge (station/src/agents/sandbox-bridge.mjs `host`), run by the station's own program
// where a release has no Node: `stillfail-reader <…>/sandbox-bridge.mjs host '<json>'`, which a sandbox's job runs in
// place of its command (agent_runtimes `sandbox_command`, its `node` this program). The far side is the same .mjs as
// ever, run by the sandbox's own node: its source, read here from the file named, goes on ssh's command line as the
// bridge's does. One SSH exec channel carries everything, in the bridge's frames (type 1 byte, stream 4 big-endian,
// length 4, then the payload): the files both sides use (`prepare`, `manifest`, `put`, `want`, `file`, `synced`), the
// program's start (`init`), its output and end, the connections it makes to the station's ports on 127.0.0.1 (`open`,
// `data`, `close`) and the pings that tell a connection lost. A job's stdin is nothing (jobs.ts: `stdio: "ignore"`), so
// its end is said at once.

///|
/// sandbox-bridge.mjs `T`.
let p53_t_init : Int = 0

///|
let p53_t_stdin_end : Int = 2

///|
let p53_t_signal : Int = 3

///|
let p53_t_ping : Int = 4

///|
let p53_t_data : Int = 5

///|
let p53_t_close : Int = 6

///|
let p53_t_prepare : Int = 7

///|
let p53_t_put : Int = 8

///|
let p53_t_want : Int = 9

///|
let p53_t_stdout : Int = 10

///|
let p53_t_stderr : Int = 11

///|
let p53_t_exit : Int = 12

///|
let p53_t_open : Int = 13

///|
let p53_t_error : Int = 14

///|
let p53_t_synced : Int = 16

///|
let p53_t_manifest : Int = 17

///|
let p53_t_file : Int = 18

///|
/// sandbox-bridge.mjs PING_MS, SILENT_MS, MAX_FILE, MAX_PUSH.
let p53_ping_ms : Int = 10000

///|
let p53_silent_ms : Int = 30000

///|
let p53_sbx_max_file : Double = 67108864.0

///|
let p53_sbx_max_push : Double = 536870912.0

///|
/// Whether `argv` runs a sandbox's bridge here (`<…>/sandbox-bridge.mjs host '<json>'`).
pub fn sandbox_bridge_of(argv : Array[String]) -> Bool {
  guard argv.length() >= 4 && argv[2] == "host" else { return false }
  let a = argv[1].replace_all(old="\\", new="/")
  a.has_suffix("/sandbox-bridge.mjs") || a == "sandbox-bridge.mjs"
}

///|
/// The shell's place for a bridge: its station's data directory's (the spec's `root`), else the system's temporary one.
pub fn sandbox_bridge_shell(argv : Array[String]) -> String {
  let spec = (try { Ok(@json.parse(argv[3])) } catch { e => Err(e) }).unwrap_or(Json::null())
  match p53_str(p53_get(spec, "root"), "path") {
    Some(root) if root != "" => @nodepath.join(sep(), [root, "shell"])
    _ => @nodepath.join(sep(), [tmpdir(), "stillfail-bridge-shell"])
  }
}

///|
#borrow(path)
extern "C" fn p53_utimes_ffi(path : Bytes, ms : Double) -> Int = "sfp53_utimes"

// ── frames ──

///|
fn p53_frame(t : Int, stream : Int, payload : Bytes) -> Bytes {
  let b = @buffer.Buffer()
  b.write_byte(t.to_byte())
  p53_u32(b, stream)
  p53_u32(b, payload.length())
  b.write_bytes(payload)
  b.to_bytes()
}

///|
fn p53_u32(b : @buffer.Buffer, n : Int) -> Unit {
  b.write_byte(((n >> 24) & 255).to_byte())
  b.write_byte(((n >> 16) & 255).to_byte())
  b.write_byte(((n >> 8) & 255).to_byte())
  b.write_byte((n & 255).to_byte())
}

///|
fn p53_u32_at(b : Bytes, at : Int) -> Int {
  (b[at].to_int() << 24) | (b[at + 1].to_int() << 16) | (b[at + 2].to_int() << 8) | b[at + 3].to_int()
}

///|
/// A frame's payload of a JSON header and bytes after it (`packed`).
fn p53_packed(header : Json, bytes : Bytes) -> Bytes {
  let h = @utf8.encode(header.stringify())
  let b = @buffer.Buffer()
  p53_u32(b, h.length())
  b.write_bytes(h)
  b.write_bytes(bytes)
  b.to_bytes()
}

///|
fn p53_unpacked(payload : Bytes) -> (Json, Bytes) {
  guard payload.length() >= 4 else { (Json::null(), b"") }
  let n = p53_u32_at(payload, 0)
  guard payload.length() >= 4 + n else { (Json::null(), b"") }
  let header = (try { Ok(@json.parse(@utf8.decode_lossy(payload[4:4 + n]))) } catch { e => Err(e) }).unwrap_or(
    Json::null(),
  )
  (header, payload[4 + n:].to_bytes())
}

// ── paths, as Node's path on POSIX (the far side is Linux; the near side runs /bin/sh) ──

///|
fn p53_norm_parts(path : String) -> Array[String] {
  let out = []
  for part in path.split("/") {
    let p = part.to_string()
    if p == "" || p == "." {
      continue
    }
    if p == ".." {
      ignore(out.pop())
    } else {
      out.push(p)
    }
  }
  out
}

///|
/// Node's path.relative for absolute POSIX paths.
fn p53_relative(from : String, to : String) -> String {
  let a = p53_norm_parts(from)
  let b = p53_norm_parts(to)
  let mut i = 0
  while i < a.length() && i < b.length() && a[i] == b[i] {
    i += 1
  }
  let out = []
  for _ in i..<a.length() {
    out.push("..")
  }
  for j in i..<b.length() {
    out.push(b[j])
  }
  out.join("/")
}

///|
fn p53_pjoin(a : String, b : String) -> String {
  @nodepath.join("/", [a, b])
}

///|
/// sandbox-bridge.mjs `within`.
fn p53_within(dir : String, path : String) -> Bool {
  let r = p53_relative(dir, path)
  r == "" || (!r.has_prefix("..") && !r.has_prefix("/"))
}

// ── the files here ──

///|
/// What `fs.lstat` says of a path (links not followed), None where nothing is.
async fn p53_sbx_lstat(host : @host.Host, path : String) -> Json? {
  match (try { Ok(host.shell("fs.lstat", { "path": p53_s(path) })) } catch { e => Err(e) }) {
    Ok((Object(_) as o, _)) => Some(o)
    _ => None
  }
}

///|
async fn p53_realpath(host : @host.Host, path : String) -> String? {
  match (try { Ok(host.shell("fs.realpath", { "path": p53_s(path) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// What a sync entry has here (sandbox-bridge.mjs `scan`): path → [kind, size, mtime ms, link?, exec?]; "f" a file,
/// "l" a link kept as one (its target in the data directory `root`).
async fn p53_sbx_scan(host : @host.Host, entry : Json, base : String, root : String?) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  let root = match root {
    Some(r) => Some(p53_realpath(host, r).unwrap_or(r))
    None => None
  }
  let skip = match p53_get(entry, "skip") {
    Array(xs) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
    _ => []
  }
  let todo : Array[(String, Int)] = [(base, 0)]
  while todo.pop() is Some((path, depth)) {
    guard p53_sbx_lstat(host, path) is Some(st0) else { continue }
    let mut st = st0
    if p53_str(st, "kind") == Some("link") {
      let target = match (try { Ok(host.shell("fs.readlink", { "path": p53_s(path) })) } catch { e => Err(e) }) {
        Ok((String(t), _)) => t
        _ => ""
      }
      guard p53_realpath(host, path) is Some(real) else { continue }
      if root is Some(r) && p53_within(r, real) {
        out[path] = Json::array([p53_s("l"), p53_i(0), p53_i(0), p53_s(target)])
        continue
      }
      guard p53_sbx_lstat(host, real) is Some(followed) else { continue }
      st = followed
    }
    match p53_str(st, "kind") {
      Some("dir") => {
        if depth > 32 {
          continue
        }
        let names = match (try { Ok(host.shell("fs.readdir", { "path": p53_s(path) })) } catch { e => Err(e) }) {
          Ok((Array(xs), _)) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
          _ => []
        }
        // (in the order Node's walk goes: the first name first)
        for i = names.length() - 1; i >= 0; i = i - 1 {
          if !skip.contains(names[i]) {
            todo.push((p53_pjoin(path, names[i]), depth + 1))
          }
        }
      }
      Some("file") => {
        let size = p53_num(st, "size").unwrap_or(0.0)
        if size <= p53_sbx_max_file {
          let mode = p53_num(st, "mode").unwrap_or(0.0).to_int()
          out[path] = Json::array([p53_s("f"), p53_n(size), p53_n(p53_num(st, "mtimeMs").unwrap_or(0.0)), Json::null(), p53_b((mode & 64) != 0)])
        }
      }
      _ => ()
    }
  }
  out
}

///|
/// A file's bytes, whole.
async fn p53_file_bytes(host : @host.Host, path : String) -> Bytes? {
  match host.shell("fs.bytes", { "path": p53_s(path) }) {
    (String(h), _) => Some(p53_unhex(h))
    (_, Some(raw)) => Some(raw)
    _ => None
  }
}

///|
/// Gives a file the other side's executable bits (`setExec`; none said: a bridge from before).
async fn p53_set_exec(host : @host.Host, path : String, exec : Json) -> Unit {
  guard exec is (True | False) else { return }
  guard p53_sbx_lstat(host, path) is Some(st) else { return }
  let mode = p53_num(st, "mode").unwrap_or(0.0).to_int() & 4095
  let want = if exec is True { mode | ((mode & 292) >> 2) } else { mode & (4095 ^ 73) }
  if want != mode {
    ignore(try { Ok(host.shell("fs.chmod", { "path": p53_s(path), "mode": p53_i(want) })) } catch { e => Err(e) })
  }
}

///|
/// Writes a file copied from the other side (`place`): through links here, with the other side's time and executable
/// bits; `offset` (an "append" file): from there, what is beyond dropped.
async fn p53_place(host : @host.Host, path : String, bytes : Bytes, mtime : Double, offset : Double?, exec : Json) -> Unit raise {
  let target = match p53_realpath(host, path) {
    Some(t) => t
    None =>
      match p53_realpath(host, @nodepath.dirname("/", path)) {
        Some(d) => p53_pjoin(d, @nodepath.basename("/", path))
        None => {
          ignore(host.shell("fs.mkdir", { "path": p53_s(@nodepath.dirname("/", path)) }))
          path
        }
      }
  }
  let there = p53_sbx_lstat(host, target) is Some(_)
  match offset {
    Some(at) if there =>
      ignore(host.shell("fs.put", { "path": p53_s(target), "offset": p53_n(at), "truncate": p53_b(true) }, bytes~))
    _ => {
      let tmp = "\{target}.sbx-\{@drive.pid()}"
      ignore(host.shell("fs.remove", { "path": p53_s(tmp) })) catch { _ => () }
      ignore(host.shell("fs.put", { "path": p53_s(tmp), "offset": p53_i(0), "truncate": p53_b(true) }, bytes~))
      ignore(host.shell("fs.rename", { "from": p53_s(tmp), "to": p53_s(target) }))
    }
  }
  p53_set_exec(host, target, exec)
  ignore(p53_utimes_ffi(cstr(target), mtime))
}

///|
async fn p53_place_link(host : @host.Host, path : String, target : String) -> Unit raise {
  ignore(host.shell("fs.mkdir", { "path": p53_s(@nodepath.dirname("/", path)) }))
  match p53_sbx_lstat(host, path) {
    Some(st) => {
      if p53_str(st, "kind") == Some("link") {
        match host.shell("fs.readlink", { "path": p53_s(path) }) {
          (String(t), _) if t == target => return
          _ => ()
        }
      }
      ignore(host.shell("fs.remove", { "path": p53_s(path), "recursive": p53_b(true) }))
    }
    None => ()
  }
  ignore(host.shell("fs.symlink", { "path": p53_s(path), "target": p53_s(target) }))
}

///|
/// The station's GitHub login lent to the program there (`lendGh`): its token as GH_TOKEN, git's credentials for
/// github.com from gh there; nothing where gh here is not signed in or the program has a token already.
async fn p53_lend_gh(host : @host.Host, env : Map[String, String]) -> Unit {
  if env.contains("GH_TOKEN") || env.contains("GITHUB_TOKEN") {
    return
  }
  let token = match p53_run(host, "gh", ["auth", "token", "-h", "github.com"], timeout_ms=10000) {
    Some(t) => t.trim(chars=" \n\r\t").to_string()
    None => ""
  }
  if token == "" {
    return
  }
  env["GH_TOKEN"] = token
  let n = match env.get("GIT_CONFIG_COUNT") {
    Some(c) => (try { Ok(@string.parse_int(c)) } catch { e => Err(e) }).unwrap_or(0)
    None => 0
  }
  env["GIT_CONFIG_KEY_\{n}"] = "credential.https://github.com.helper"
  env["GIT_CONFIG_VALUE_\{n}"] = "!gh auth git-credential"
  env["GIT_CONFIG_COUNT"] = (n + 1).to_string()
}

// ── the bridge ──

///|
/// Here (sandbox-bridge.mjs `host`): makes the sandbox when asked to (its size), then stands in for the program. Its
/// exit code: the program's, LOST_EXIT where the connection was lost, 255 where the sandbox was not reached.
pub async fn run_sandbox_bridge(host : @host.Host, argv : Array[String]) -> Int {
  let spec = (try { Ok(@json.parse(argv[3])) } catch { e => Err(e) }).unwrap_or(Json::null())
  match p53_get(spec, "create") {
    Array(create) if create.length() > 0 => {
      let words = create.filter_map(x => if x is String(s) { Some(s) } else { None })
      let made = spawn(host, words[0], words[1:].to_array(), stdout=Piped, stderr=Piped) catch {
        SysError(why) => {
          err_write("sandbox: ssh did not start: \{why}\n")
          return 255
        }
      }
      let (code, _, out, err) = made.finished()
      // (made now, or there already with this size: on to it)
      if code != Some(0) {
        let said = (@utf8.decode_lossy(out) + @utf8.decode_lossy(err)).trim(chars=" \n\r\t").to_string()
        err_write("sandbox: the sandbox was not made: \{said}\n")
        return 255
      }
    }
    _ => ()
  }
  p53_bridge_connect(host, argv[1], spec)
}

///|
/// Starts the far side through ssh and stands in for the program (`connect`).
async fn p53_bridge_connect(host : @host.Host, bridge : String, spec : Json) -> Int {
  let source = match (try { Ok(host.shell("fs.read", { "path": p53_s(bridge) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => s
    _ => {
      err_write("sandbox: the bridge \{bridge} does not read\n")
      return 255
    }
  }
  // (the far side's own file, given on its command line: nothing to install in the sandbox)
  let remote = "exec node --input-type=module -e \"$(printf %s \{@base64.encode(@utf8.encode(source))} | base64 -d)\" remote"
  let ssh_words = match p53_get(spec, "ssh") {
    Array(xs) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
    _ => []
  }
  guard ssh_words.length() > 0 else {
    err_write("sandbox: ssh did not start: no ssh command\n")
    return 255
  }
  let ssh = spawn(host, ssh_words[0], [..ssh_words[1:], remote], stdin_piped=true, stdout=Piped, stderr=Piped) catch {
    SysError(why) => {
      err_write("sandbox: ssh did not start: \{why}\n")
      return 255
    }
  }
  let send = (t : Int, stream : Int, payload : Bytes) => ignore(ssh.write(p53_frame(t, stream, payload)))
  let env : Map[String, String] = Map([])
  for kv in env_all() {
    env[kv.0] = kv.1
  }
  env.remove("STILLFAIL_SANDBOX_BRIDGE")
  let run = !(p53_get(spec, "program") is Null)
  if p53_true(spec, "gh") && run {
    p53_lend_gh(host, env)
  }
  let silent = p53_num(spec, "silentMs").map(n => n.to_int()).unwrap_or(p53_silent_ms)
  let sync = match p53_get(spec, "sync") {
    Array(xs) => xs.map(e => if p53_get(e, "to") is String(_) { e } else { p53_with(e, "to", p53_get(e, "path")) })
    _ => []
  }
  let root = match p53_str(p53_get(spec, "root"), "path") {
    Some(r) => Some(r)
    None => None
  }
  // First the files: what each side has, then what goes either way; the program once both have them. A directory here
  // (or one not made yet) is watched there as one; a single file (one fetched) is not.
  let prepared = []
  for e in sync {
    let dir = match p53_get(e, "dir") {
      True => true
      False => false
      _ =>
        match p53_sbx_lstat(host, p53_text(e, "path")) {
          None => true
          Some(_) =>
            (try { Ok(host.shell("fs.stat", { "path": p53_get(e, "path") })) } catch { e => Err(e) }) is Ok((String("dir"), _))
        }
    }
    let fields : Array[(String, Json)] = [("path", p53_get(e, "to")), ("mode", p53_get(e, "mode")), ("dir", p53_b(dir))]
    for k in ["skip", "back"] {
      match p53_get(e, k) {
        Null => ()
        v => fields.push((k, v))
      }
    }
    prepared.push(p53_obj(fields))
  }
  send(
    p53_t_prepare,
    0,
    @utf8.encode(
      p53_obj([
        ("root", p53_get(spec, "root")),
        ("dirs", match p53_get(spec, "dirs") { Array(_) as d => d; _ => Json::array([]) }),
        ("sync", Json::array(prepared)),
      ]).stringify(),
    ),
  )
  let heard = Ref(wall_ms().to_double())
  let reached = Ref(false)
  let synced = Ref(false)
  let exit : Ref[Json?] = Ref(None)
  let done = Ref(false)
  // (until the far side is first heard, SILENT_MS at the least: a shortened silence is for a connection once made)
  ignore(
    host.rt.fork(name="the bridge's pings", async fn() {
      let every = if silent / 3 < p53_ping_ms { silent / 3 } else { p53_ping_ms }
      while !done.val {
        @effect.sleep(if every < 1 { 1 } else { every }) // timer: a heartbeat that keeps the connection, and measures it
        if done.val {
          break
        }
        let limit = if reached.val { silent } else if silent > p53_silent_ms { silent } else { p53_silent_ms }
        if wall_ms().to_double() - heard.val > limit.to_double() {
          ignore(kill(ssh.pid, "SIGKILL"))
        } else {
          send(p53_t_ping, 0, b"")
        }
      }
    }),
  )
  if run {
    // (a job's stdin is nothing: its end said at once)
    send(p53_t_stdin_end, 0, b"")
    on_signals(host, name => if name == "SIGTERM" || name == "SIGINT" || name == "SIGHUP" {
      send(p53_t_signal, 0, @utf8.encode(name))
    })
  }
  let ports = match p53_get(spec, "ports") {
    Array(xs) => xs
    _ => []
  }
  let sockets : Map[Int, Int64] = Map([])
  let pending = @buffer.Buffer()
  let mut ended : (Int?, String?) = (None, None)
  let mut going = true
  while going {
    match ssh.events.take() {
      Err(b) => ignore(fd_write(2, b))
      Exit(code, signal) => {
        ended = (code, signal)
        going = false
      }
      Out(chunk) => {
        pending.write_bytes(chunk)
        let all = pending.to_bytes()
        let mut at = 0
        while all.length() - at >= 9 {
          let length = p53_u32_at(all, at + 5)
          if all.length() - at < 9 + length {
            break
          }
          let t = all[at].to_int()
          let stream = p53_u32_at(all, at + 1)
          let payload = all[at + 9:at + 9 + length].to_bytes()
          at += 9 + length
          heard.val = wall_ms().to_double()
          reached.val = true
          if t == p53_t_stdout {
            ignore(fd_write(1, payload))
          } else if t == p53_t_manifest {
            let theirs = (try { Ok(@json.parse(@utf8.decode_lossy(payload))) } catch { e => Err(e) }).unwrap_or(
              Json::null(),
            )
            p53_bridge_exchange(host, sync, root, theirs, send)
            if run {
              let env_json : Map[String, Json] = Map([])
              for k, v in env {
                env_json[k] = p53_s(v)
              }
              send(
                p53_t_init,
                0,
                @utf8.encode(
                  p53_obj([
                    ("program", p53_get(spec, "program")),
                    ("args", p53_get(spec, "args")),
                    ("cwd", p53_get(spec, "cwd")),
                    ("env", Json::object(env_json)),
                    ("ports", p53_get(spec, "ports")),
                    ("agent", p53_b(p53_true(spec, "agent"))),
                    ("silentMs", p53_i(silent)),
                  ]).stringify(),
                ),
              )
            } else {
              send(p53_t_synced, 0, b"")
            }
          } else if t == p53_t_file {
            let (header, bytes) = p53_unpacked(payload)
            p53_bridge_receive(host, sync, header, bytes)
          } else if t == p53_t_synced {
            synced.val = true
            ssh.end_input()
          } else if t == p53_t_stderr {
            ignore(fd_write(2, payload))
          } else if t == p53_t_exit {
            exit.val = Some((try { Ok(@json.parse(@utf8.decode_lossy(payload))) } catch { e => Err(e) }).unwrap_or(Json::null()))
          } else if t == p53_t_error {
            err_write("sandbox: \{@utf8.decode_lossy(payload)}\n")
          } else if t == p53_t_open {
            let asked = (try { Ok(@string.parse_int(@utf8.decode_lossy(payload))) } catch { e => Err(e) }).unwrap_or(-1)
            let port = ports
              .filter_map(p => match p {
                Number(n, ..) => Some((n.to_int(), n.to_int()))
                Object(_) => Some((p53_num(p, "sandbox").unwrap_or(-1.0).to_int(), p53_num(p, "here").unwrap_or(-1.0).to_int()))
                _ => None
              })
              .iter()
              .find_first(p => p.0 == asked)
            match port {
              None => send(p53_t_close, stream, b"")
              Some((_, here)) =>
                match (try { Ok(host.tcp_open(here)) } catch { e => Err(e) }) {
                  Ok(conn) => {
                    let id = match conn.id {
                      Number(n, ..) => n.to_int64()
                      _ => 0L
                    }
                    sockets[stream] = id
                    ignore(
                      host.rt.fork(name="a connection through the bridge", async fn() {
                        while true {
                          match (try { Ok(host.tcp_read(Json::number(id.to_double()))) } catch { e => Err(e) }) {
                            Ok(Some(b)) if b.length() > 0 => send(p53_t_data, stream, b)
                            _ => break
                          }
                        }
                        if sockets.get(stream) == Some(id) {
                          sockets.remove(stream)
                          send(p53_t_close, stream, b"")
                        }
                        host.tcp_close(Json::number(id.to_double()))
                      }),
                    )
                  }
                  Err(_) => send(p53_t_close, stream, b"")
                }
            }
          } else if t == p53_t_data {
            match sockets.get(stream) {
              Some(id) =>
                host.tcp_write(Json::number(id.to_double()), payload) catch {
                  _ => ()
                }
              None => ()
            }
          } else if t == p53_t_close {
            match sockets.get(stream) {
              Some(id) => {
                sockets.remove(stream)
                host.tcp_end(Json::number(id.to_double())) catch {
                  _ => ()
                }
              }
              None => ()
            }
          }
        }
        let rest = all[at:].to_bytes()
        pending.reset()
        pending.write_bytes(rest)
      }
    }
  }
  done.val = true
  let code_said = match ended.0 {
    Some(c) => c.to_string()
    None => "null"
  }
  if !run {
    if synced.val {
      return 0
    }
    err_write("sandbox: the files were not copied (ssh exited \{code_said})\n")
    return 255
  }
  match exit.val {
    None if reached.val => {
      err_write("\{@agent_runtimes.connection_lost} (ssh exited \{code_said})\n")
      match p53_str(spec, "lostFile") {
        Some(f) if f != "" => ignore(try { Ok(host.shell("fs.put", { "path": p53_s(f), "offset": p53_i(0), "truncate": p53_b(true) }, bytes=b"")) } catch { e => Err(e) })
        _ => ()
      }
      @agent_runtimes.lost_exit
    }
    None => {
      err_write("sandbox: the sandbox could not be reached (ssh exited \{code_said})\n")
      255
    }
    Some(said) => {
      match p53_str(said, "signal") {
        Some(sig) if sig != "" => ignore(kill(@drive.pid(), sig))
        _ => ()
      }
      p53_num(said, "code").map(n => n.to_int()).unwrap_or(1)
    }
  }
}

///|
/// The manifest come (`exchange`): what is newer here goes there, what is newer there is asked for.
async fn p53_bridge_exchange(
  host : @host.Host,
  sync : Array[Json],
  root : String?,
  theirs : Json,
  send : (Int, Int, Bytes) -> Unit,
) -> Unit {
  let mut pushed = 0.0
  let seconds = (ms : Double) => (ms / 1000.0).floor()
  for e in sync {
    let here = p53_text(e, "path")
    let to = p53_text(e, "to")
    let append = p53_str(e, "mode") == Some("append")
    let push = !(p53_get(e, "push") is False)
    let back = !(p53_get(e, "back") is False)
    let mine = p53_sbx_scan(host, e, here, root)
    let there : Map[String, Json] = Map([])
    match p53_get(theirs, to) {
      Object(o) => for k, v in o { there[k] = v }
      _ => ()
    }
    let asked = []
    let map = (path : String) => p53_pjoin(to, p53_relative(here, path))
    let unmap = (path : String) => p53_pjoin(here, p53_relative(to, path))
    let at = (v : Json, i : Int) => match v {
      Array(xs) if i < xs.length() => xs[i]
      _ => Json::null()
    }
    let num = (v : Json) => match v {
      Number(n, ..) => n
      _ => 0.0
    }
    for path, v in mine {
      let kind = at(v, 0)
      let other = there.get(map(path))
      if kind is String("l") {
        let link = at(v, 3)
        let same = match other {
          Some(o) => at(o, 0) is String("l") && at(o, 3) == link
          None => false
        }
        if push && !same {
          send(p53_t_put, 0, p53_packed(p53_obj([("path", p53_s(map(path))), ("link", link)]), b""))
        }
        continue
      }
      let size = num(at(v, 1))
      let mtime = num(at(v, 2))
      let exec = at(v, 4)
      let mut newer = match other {
        None => "here"
        Some(o) =>
          if append {
            if size > num(at(o, 1)) { "here" } else if size < num(at(o, 1)) { "there" } else { "" }
          } else if seconds(mtime) > seconds(num(at(o, 2))) {
            "here"
          } else if seconds(mtime) < seconds(num(at(o, 2))) {
            "there"
          } else if size != num(at(o, 1)) {
            "here"
          } else {
            ""
          }
      }
      // (only the executable bit changed, chmod keeping the mtime: this side's is the one meant)
      match other {
        Some(o) if newer == "" && !append && !(at(o, 4) is Null) && at(o, 4) != exec && push => newer = "here"
        _ => ()
      }
      if newer == "here" && push {
        if pushed + size > p53_sbx_max_push {
          err_write("sandbox: over \{p53_sbx_max_push.to_int64()} bytes to copy there; \{path} and what follows left out\n")
          continue
        }
        match (try { Ok(p53_file_bytes(host, path)) } catch { e => Err(e) }) {
          Ok(Some(bytes)) => {
            send(p53_t_put, 0, p53_packed(p53_obj([("path", p53_s(map(path))), ("mtime", p53_n(mtime)), ("exec", exec)]), bytes))
            pushed += size
          }
          _ => ()
        }
      } else if newer == "there" && back {
        asked.push(map(path))
      }
    }
    if back {
      for path, v in there {
        if at(v, 0) is String("f") && !mine.contains(unmap(path)) {
          asked.push(path)
        }
      }
    }
    for path in asked {
      let have = if append {
        match mine.get(unmap(path)) {
          Some(v) => num(at(v, 1))
          None => 0.0
        }
      } else {
        0.0
      }
      send(p53_t_want, 0, @utf8.encode(p53_obj([("path", p53_s(path)), ("have", p53_n(have))]).stringify()))
    }
  }
}

///|
/// A file copied back (`receive`): to its place here.
async fn p53_bridge_receive(host : @host.Host, sync : Array[Json], header : Json, bytes : Bytes) -> Unit {
  let path_there = p53_text(header, "path")
  guard sync.iter().find_first(x => p53_within(p53_text(x, "to"), path_there) && !(p53_get(x, "back") is False))
    is Some(e) else {
    return
  }
  let path = p53_pjoin(p53_text(e, "path"), p53_relative(p53_text(e, "to"), path_there))
  let placed = try {
    Ok(
      match p53_get(header, "link") {
        String(link) => p53_place_link(host, path, link)
        _ => p53_place(host, path, bytes, p53_num(header, "mtime").unwrap_or(0.0), p53_num(header, "offset"), p53_get(header, "exec"))
      },
    )
  } catch {
    e => Err(e)
  }
  if placed is Err(e) {
    err_write("sandbox: \{path} not copied back: \{p53_words(e)}\n")
  }
}
