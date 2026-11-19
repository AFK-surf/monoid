// These parts asked line by line (reader `--builder harness-connects-hub`), as station/test/mb-connects-hub.test.ts
// asks the TypeScript's on the same cases. A case is `{id, op, ...}`, answered `{id, ok}` or `{id, error, kind}`; cases
// run side by side, each a fiber of its own (a move asked while an event comes). While one asks the station or the
// machine, the program says `{call, args, cid}` and is answered `{re: cid, result}` or `{re: cid, threw, kind}`; what
// it only tells (the log, a listener heard) it says as `{note, args}`, in the order it happens. The station's clock is
// the test's: `{op: "clock", now}` says the time, a wait is asked (`clock.sleep`) and answered once the test's clock
// has passed it.

///|
priv struct Harness {
  host : @host.Host
  pending : Map[Int, @effect.Deferred[J]]
  mut next_cid : Int
  mut now : Double
  mut words : @session_chats.Words
  lang : Ref[String]
  mut uuids : Int
  /// What the station is (its id, its home workspace, its workspaces' stations), as the test says it.
  mut here : String
  mut home : String?
  mut stations : J
  /// config.json as these parts keep it (theirs to edit), and who hears it change.
  mut raw : J
  config_listeners : Listeners
  /// Whether the station is in its workspace, the workspaces it is in, its live sessions.
  mut bound : Bool
  mut workspaces : Array[String]
  mut live : Array[String]
  /// What the cases made, by their handles.
  mut next_h : Int
  lines : Map[Int, StatusLine]
  books : Map[Int, NameBook]
  files : Map[Int, PrivateFile]
  conns : Map[Int, FakeConn]
  connections : Map[Int, Connections]
  connects : Map[Int, Connects]
  parts : Map[Int, Part]
  surfaces : Map[Int, ConnectedSurface]
  remotes : Map[Int, RemoteConnects]
  answerers : Map[Int, CallAnswerer]
  workspaces_made : Map[Int, WorkspaceConnects]
  handlers : Map[String, async (String, J, String?, Bytes?) -> Answer]
  heard : Array[(String) -> Unit]
  groups : Map[Int, GroupParts]
  threads : Map[Int, GroupThreads]
  links : Map[Int, GroupLink]
  streams : Map[Int, Streamed]
  sses : Map[Int, SseLines]
  group_surfaces : Map[Int, GroupSurface]
  sockets : Map[Int, @effect.Queue[SocketEvent]]
  /// Each platform's names book a remote surface writes into (by its kind).
  kind_books : Map[String, Int]
}

///|
/// A connection of the test's (connections.mbt's `Connection`): what it is now as the test says it, its calls the
/// test's.
priv struct FakeConn {
  h : Int
  mut bot_user_id : String
  mut socket : J
  mut identity : J
  mut handler : (async (J) -> Unit)?
  listeners : Listeners
}

///|
fn Harness::new(host : @host.Host) -> Harness {
  {
    host,
    pending: Map([]),
    next_cid: 0,
    now: 0.0,
    words: @session_chats.Words::empty(),
    lang: Ref("zh"),
    uuids: 0,
    here: "",
    home: None,
    stations: jo([]),
    raw: jo([]),
    config_listeners: Listeners::new(),
    bound: true,
    workspaces: [],
    live: [],
    next_h: 0,
    lines: Map([]),
    books: Map([]),
    files: Map([]),
    conns: Map([]),
    connections: Map([]),
    connects: Map([]),
    parts: Map([]),
    surfaces: Map([]),
    remotes: Map([]),
    answerers: Map([]),
    workspaces_made: Map([]),
    handlers: Map([]),
    heard: [],
    groups: Map([]),
    threads: Map([]),
    links: Map([]),
    streams: Map([]),
    sses: Map([]),
    group_surfaces: Map([]),
    sockets: Map([]),
    kind_books: Map([]),
  }
}

///|
fn Harness::handle(self : Harness) -> Int {
  self.next_h += 1
  self.next_h
}

///|
/// Asks the test `name` with `args`; what it threw raises `Thrown(kind, message)`.
async fn Harness::ask(self : Harness, name : String, args : Array[J]) -> J {
  self.next_cid += 1
  let cid = self.next_cid
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  self.pending[cid] = d
  self.host.say(js_stringify(jo([("call", js(name)), ("args", ja(args)), ("cid", ji(cid))])))
  let v = d.wait()
  if is_undefined(v) {
    Null
  } else {
    v
  }
}

///|
/// Tells the test `name` with `args`, nothing answered.
fn Harness::note(self : Harness, name : String, args : Array[J]) -> Unit {
  self.host.say(js_stringify(jo([("note", js(name)), ("args", ja(drop_undefined(ja(args)) |> arr_items))])))
}

///|
fn arr_items(v : J) -> Array[J] {
  match v {
    Arr(xs) => xs
    _ => []
  }
}

///|
fn Harness::clock(self : Harness) -> Clock {
  { now: () => self.now, sleep: async fn(ms) { ignore(self.ask("clock.sleep", [jn(ms)])) } }
}

///|
fn Harness::log(self : Harness) -> Log {
  { write: (level, part, words, fields) => self.note("log", [js(level), js(part), js(words), drop_undefined(fields)]) }
}

///|
fn Harness::speech(self : Harness) -> Speech {
  { words: self.words, lang: self.lang }
}

///|
/// A made-up UUID, the next of the program's (the test reads each as any UUID).
fn Harness::uuid(self : Harness) -> String {
  self.uuids += 1
  let n = self.uuids.to_string()
  let pad = "000000000000".to_array()
  let digits = n.to_array()
  for i, c in digits {
    pad[pad.length() - digits.length() + i] = c
  }
  "00000000-0000-4000-8000-\{String::from_array(pad)}"
}

///|
/// The machine's files, asked of the test (which keeps them in a directory of the program's own).
fn Harness::fs(self : Harness) -> Fs {
  let unit = async fn(name : String, args : Array[J]) { ignore(self.ask(name, args)) }
  {
    sep: "/",
    read_text: async fn(p) { js_text(Some(self.ask("fs.read", [js(p)]))) },
    read_bytes: async fn(p) { unhex(js_text(Some(self.ask("fs.readBytes", [js(p)])))) },
    read_part: async fn(p, at, n) { unhex(js_text(Some(self.ask("fs.readPart", [js(p), jn(at), jn(n)])))) },
    size: async fn(p) { num_of(Some(self.ask("fs.size", [js(p)]))).unwrap_or(0.0) },
    write_text: async fn(p, t) { unit("fs.write", [js(p), js(t)]) },
    write_bytes: async fn(p, b) { unit("fs.writeBytes", [js(p), js(hex(b))]) },
    append_text: async fn(p, t) { unit("fs.append", [js(p), js(t)]) },
    rename: async fn(a, b) { unit("fs.rename", [js(a), js(b)]) },
    rm: async fn(p) { unit("fs.rm", [js(p)]) },
    mkdir: async fn(p) { unit("fs.mkdir", [js(p)]) },
    readdir: async fn(p) { arr_of(Some(self.ask("fs.readdir", [js(p)]))).unwrap_or([]).map(x => js_text(Some(x))) },
    write_private: async fn(p, t) { unit("fs.writePrivate", [js(p), js(t)]) },
  }
}

///|
/// The Ed25519 public half of a seed (hex), as the shell signs with it.
fn Harness::public_key(self : Harness, seed : String) -> String? {
  let answer = self.host.shell_sync("ed25519.sign", { "seed": Json::string(seed), "message": Json::string("") }) catch { _ => return None }
  match answer {
    { "publicKey": String(k), .. } => Some(k)
    _ => None
  }
}

///|
/// Ed25519 as the shell does it (`ed25519.sign`, `crypto.verify`).
fn Harness::signer(self : Harness) -> Signer {
  {
    public_key: seed => self.public_key(seed),
    sign: fn(seed, message) {
      let answer = self.host.shell_sync("ed25519.sign", { "seed": Json::string(seed), "message": Json::string(hex(message)) }) catch { _ => return None }
      match answer {
        { "signature": String(sig), .. } => Some(sig)
        _ => None
      }
    },
    verify: fn(device, message, sig) {
      let answer = self.host.shell_sync("crypto.verify", { "alg": Json::string("Ed25519"), "key": Json::string(device), "signature": Json::string(sig), "message": Json::string(hex(message)) }) catch {
        _ => return false
      }
      match answer {
        True => true
        { "value": True, .. } => true
        _ => false
      }
    },
  }
}

///|
/// config.json as these parts keep it: edits written to the test as they are made.
fn Harness::config(self : Harness) -> Config {
  {
    raw: () => self.raw,
    update_soon: async fn(f) {
      self.raw = f(self.raw)
      ignore(self.ask("config.updated", [self.raw]))
    },
    listen: f => self.config_listeners.add(f),
    written: async fn() { ignore(self.ask("config.written", [])) },
  }
}

///|
/// A surface of the test's, as it said itself (`{remote, has, get, mention, link}`): what answers at once answered
/// from that, the rest asked of the test as `chat.call`.
fn Harness::chat_surface(self : Harness, id : String, said : J) -> Surface {
  let s = Some(said)
  let has = arr_of(at(s, "has")).unwrap_or([]).map(x => js_text(Some(x)))
  let values = at(s, "get")
  {
    has: name => has.contains(name),
    get: fn(name, args) {
      if !has.contains(name) && name != "botUserId" && name != "workspace" {
        return undefined()
      }
      match name {
        "mention" => {
          let m = arr_of(at(s, "mention")).unwrap_or([])
          js("\{js_text(m.get(0))}\{js_text(args.get(0))}\{js_text(m.get(1))}")
        }
        "sessionLink" =>
          match at(s, "link") {
            Some(Str(u)) => js(replace_first(replace_first(@jsjson.text(u), "\u{1}", js_text(args.get(0))), "\u{2}", js_text(args.get(1))))
            _ => Null
          }
        "knownPerson" | "knownChannel" | "working" | "standsAt" => {
          self.note("chat.get", [js(id), js(name), ja(args)])
          match at(values, name) {
            Some(v) => v
            None => undefined()
          }
        }
        _ =>
          match at(values, name) {
            Some(v) => v
            None => undefined()
          }
      }
    },
    // (what it answers at once, its said values, answered so; the rest asked)
    call: async fn(name, args) {
      if ["knownPerson", "knownChannel", "working", "standsAt", "mention", "sessionLink", "botUserId", "workspace"].contains(name) ||
        at(values, name) is Some(_) {
        return (self.chat_surface(id, said).get)(name, args)
      }
      self.ask("chat.call", [js(id), js(name), ja(args)])
    },
    remote: false,
  }
}

///|
/// A connection of the test's, made as `conn.create` answers (its handle there).
fn Harness::fake_conn(self : Harness, h : Int) -> Connection {
  let c : FakeConn = { h, bot_user_id: "", socket: jo([("connected", jb(false)), ("lastError", Null)]), identity: Null, handler: None, listeners: Listeners::new() }
  self.conns[h] = c
  let surface : Surface = {
    has: name => name == "cards" || name == "cardEnded" || name == "knownPerson" || name == "knownChannel",
    get: fn(name, args) {
      match name {
        "botUserId" => js(c.bot_user_id)
        "identity" => c.identity
        "cards" => jb(true)
        "knownPerson" | "knownChannel" => {
          self.note("conn.get", [ji(h), js(name), ja(args)])
          Null
        }
        _ => undefined()
      }
    },
    call: async fn(name, args) { self.ask("conn.call", [ji(h), js(name), ja(args)]) },
    remote: false,
  }
  {
    surface,
    start: async fn(handler) {
      c.handler = Some(handler)
      ignore(self.ask("conn.start", [ji(h)]))
    },
    stop: async fn() { ignore(self.ask("conn.stop", [ji(h)])) },
    socket: () => c.socket,
    identity: () => c.identity,
    on_change: f => c.listeners.add(f),
    refresh_identity: async fn() { ignore(self.ask("conn.refreshIdentity", [ji(h)])) },
  }
}

///|
/// The mesh's endpoints, the test's (each endpoint, connection and stream by its handle there).
fn Harness::endpoints(self : Harness) -> Endpoints {
  let stream_of = fn(sh : J) -> MeshStream { {
    read: async fn() {
      match self.ask("mesh.read", [sh]) {
        Null => None
        v => Some(unhex(js_text(Some(v))))
      }
    },
    write: async fn(b) { ignore(self.ask("mesh.write", [sh, js(hex(b))])) },
    finish: async fn() { ignore(self.ask("mesh.finish", [sh])) },
    reset: async fn(code) { ignore(self.ask("mesh.reset", [sh, ji(code)])) },
    stopped: async fn() { ignore(self.ask("mesh.stopped", [sh])) },
  } }
  let conn_of = fn(ch : J, remote : String) -> MeshConn {
    let closed = Ref(false)
    {
      open_bi: async fn() { stream_of(self.ask("mesh.openBi", [ch])) },
      close: fn(code, reason) {
        closed.val = true
        self.note("mesh.close", [ch, ji(code), js(reason)])
      },
      is_closed: () => closed.val,
      accept_bi: async fn() {
        match self.ask("mesh.acceptBi", [ch]) {
          Null => None
          sh => Some(stream_of(sh))
        }
      },
      remote_id: () => remote,
    }
  }
  {
    bind: async fn(options) {
      let got = self.ask("mesh.bind", [options])
      let eh = at(Some(got), "h").unwrap_or(Null)
      let id = js_text(at(Some(got), "id"))
      {
        id: () => id,
        connect: async fn(addr, alpn) {
          let ch = self.ask("mesh.connect", [eh, addr, js(alpn)])
          conn_of(ch, js_text(at(Some(addr), "id")))
        },
        accept: async fn() {
          match self.ask("mesh.accept", [eh]) {
            Null => None
            got => Some(conn_of(at(Some(got), "h").unwrap_or(Null), js_text(at(Some(got), "remote"))))
          }
        },
        close: async fn() { ignore(self.ask("mesh.endpointClose", [eh])) },
      }
    },
  }
}

///|
/// The program's harness: cases line by line, each answered as it ends, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h = Harness::new(host)
  while true {
    guard host.line() is Some(line) else { break }
    let msg = try parse_js(line) catch {
      _ => continue
    }
    match at(Some(msg), "re") {
      Some(Num(cid)) => {
        match h.pending.get(cid.to_int()) {
          Some(d) => {
            h.pending.remove(cid.to_int())
            match at(Some(msg), "threw") {
              Some(m) => ignore(d.fail(@session_chats.Thrown(str_of(at(Some(msg), "kind")).unwrap_or(""), js_text(Some(m)))))
              None => ignore(d.succeed(at(Some(msg), "result").unwrap_or(Null)))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    let id = at(Some(msg), "id").unwrap_or(Null)
    // (the time said: set before anything else goes on, as the test's clock moves)
    if str_of(at(Some(msg), "op")) == Some("clock") {
      h.now = num_of(at(Some(msg), "now")).unwrap_or(h.now)
      host.say(js_stringify(jo([("id", id), ("ok", Null)])))
      continue
    }
    spawn(async fn() {
      let answer = try {
        let v = h.op(msg)
        jo([("id", id), ("ok", if is_undefined(v) { J::Null } else { drop_undefined(v) })])
      } catch {
        e => jo([("id", id), ("error", js(thrown_message(e))), ("kind", js(thrown_kind(e)))])
      }
      host.say(js_stringify(answer))
    })
  }
}
