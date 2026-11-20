// adb/link.ts: phones lent to this station's agents (the Rust station's adb.rs). A phone offers its adbd over its member
// link, and the station reaches it at `127.0.0.1:<port>`, a listener of its own whose every TCP connection is a stream
// it opens on the phone's connection (the phone's core takes it on to adbd). `adb connect` as the offer comes, `adb
// disconnect` as it goes; `adb pair` through the phone's pairing port when its person types the code. The agents read
// who lent what with the `adb_devices` tool (`Shares::list`).
//
// Wire (unchanged from the Rust station): a request stream whose head line has an `"adb"` object. `op: "share"` is an
// offer, answered `{status: 200, headers: {content-type: application/x-ndjson}}` and then a `{serial, adb, message}`
// line each time how adb holds the phone changes, for as long as the stream lasts; `op: "pair" | "grant"` is an ask,
// answered with a status and `{message}` (and `code` where the app goes by which failure it was: GRANT_REFUSED).
// Tunnels are streams the station opens on the offer's connection: `{"tunnel": "connect" | "pair"}`, the phone's
// `{ok: true}` (or `{error}`), then bytes both ways.

///|
/// Where a phone's port is looked for first: the same phone gets the same one while it is free.
pub let ports_start : Int = 37000

///|
pub let ports_end : Int = 38000

///|
/// How long the phone has to take a tunnel stream and reach its adbd.
let tunnel_open : Double = 10000.0

///|
let adb_quick : Double = 5000.0

///|
let adb_timeout : Double = 30000.0

///|
/// How long a phone whose offer ended is kept for another offer of it.
pub let grace : Double = 5000.0

///|
/// A phone's connection silent this long ends its offer.
pub let silent_ms : Double = 30000.0

///|
/// How long a connected phone's state is looked at before it is taken as it is.
pub let settle : Double = 6000.0

///|
/// How long after adb failed to get in it is tried again, doubled each time it fails again (up to RETRY_MOST).
pub let retry : Double = 2000.0

///|
pub let retry_most : Double = 60000.0

///|
/// The code a refused `grant` is answered with beside its words.
pub let grant_refused : String = "adb_grant_refused"

///|
/// Which offer it is, counted over the process (link.ts `nextOffer`).
let next_offer : Ref[Int] = { val: 1, }

///|
/// How long adb is given: to answer (`quick`), to connect or pair (`long`); None, as long as it takes.
pub struct Limits {
  quick : Double?
  long : Double?
}

///|
/// What a socket is asked to stop by: aborted once, its callbacks called.
struct Stop {
  mut aborted : Bool
  heard : Array[() -> Unit]
}

///|
fn Stop::new() -> Stop {
  { aborted: false, heard: [], }
}

///|
fn Stop::abort(self : Stop) -> Unit {
  if self.aborted {
    return
  }
  self.aborted = true
  let heard = self.heard.copy()
  self.heard.clear()
  for f in heard {
    f()
  }
}

///|
/// One phone, as its latest offer has it.
pub struct Share {
  port : Int
  owner : J
  server : J
  mut info : J
  mut conn : J
  mut lang : String
  mut offer : Int
  mut state : J
  mut version : Int
  mut screens : Array[String]
  mut on_set : (async (J) -> Unit)?
  mut refused : String?
  mut refused_unpaired : Bool
  refusal_waiters : Array[@effect.Deferred[Unit]]
  mut connecting : @effect.Deferred[Unit]?
  mut again : Bool
  mut failures : Int
  mut streams : Int
  mut keeping : @effect.Deferred[Unit]
  sockets : Array[(J, Stop)]
  mut closing : Bool
  waiters : Array[@effect.Deferred[Unit]]
}

///|
fn done_now() -> @effect.Deferred[Unit] {
  let d = @effect.Deferred::new()
  ignore(d.succeed(()))
  d
}

///|
fn Share::new(
  server : J,
  port : Int,
  owner : J,
  info : J,
  conn : J,
  lang : String,
  offer : Int,
) -> Share {
  {
    port,
    owner,
    server,
    info,
    conn,
    lang,
    offer,
    state: jo([
      ("serial", js("127.0.0.1:\{port}")),
      ("adb", js("connecting")),
      ("message", js("")),
    ]),
    version: 0,
    screens: [],
    on_set: None,
    refused: None,
    refused_unpaired: false,
    refusal_waiters: [],
    connecting: None,
    again: false,
    failures: 0,
    streams: 0,
    keeping: done_now(),
    sockets: [],
    closing: false,
    waiters: [],
  }
}

///|
pub fn Share::serial(self : Share) -> String {
  "127.0.0.1:\{self.port}"
}

///|
pub fn Share::email(self : Share) -> String {
  text_of(at(Some(self.owner), "email"))
}

///|
pub fn Share::adb_state(self : Share) -> String {
  text_of(at(Some(self.state), "adb"))
}

///|
fn Share::info_text(self : Share, k : String) -> String {
  text_of(at(Some(self.info), k))
}

///|
/// Every accepted socket belongs to this offer, including one still being checked for a grant.
async fn Share::take(self : Share, w : World, socket : J) -> Stop {
  let stop = Stop::new()
  if self.closing {
    ignore(w.ask("net.destroy", [socket]))
    stop.abort()
  } else {
    self.sockets.push((socket, stop))
    (w.spawn)(async fn() {
      ignore(w.ask("net.closed", [socket])) catch {
        _ => ()
      }
      match self.sockets.search_by(p => physical_equal(p.1, stop)) {
        Some(i) => ignore(self.sockets.remove(i))
        None => ()
      }
    })
  }
  stop
}

///|
/// Closing a listener alone waits for its clients forever: its tunnels ended before it is waited for.
async fn Share::close(self : Share, w : World) -> Unit {
  self.closing = true
  let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
  (w.spawn)(async fn() {
    ignore(w.ask("net.close", [self.server])) catch {
      _ => ()
    }
    ignore(closed.succeed(()))
  })
  for p in self.sockets.copy() {
    p.1.abort()
    ignore(w.ask("net.destroy", [p.0])) catch {
      _ => ()
    }
  }
  closed.wait()
}

///|
fn Share::wake(self : Share) -> Unit {
  let waiters = self.waiters.copy()
  self.waiters.clear()
  for d in waiters {
    ignore(d.succeed(()))
  }
}

///|
async fn Share::set(self : Share, adb : String, message~ : String = "") -> Unit {
  self.state = jo([
    ("serial", js(self.serial())),
    ("adb", js(adb)),
    ("message", js(js_trim(message))),
  ])
  self.version += 1
  match self.on_set {
    Some(f) => f(self.state)
    None => ()
  }
  self.wake()
}

///|
/// The chats whose screens are up changed: said to the phone with the state.
pub fn Share::set_screens(self : Share, titles : Array[String]) -> Unit {
  if titles.length() == self.screens.length() &&
    titles.iter().zip(self.screens.iter()).all(p => p.0 == p.1) {
    return
  }
  self.screens = titles
  self.version += 1
  self.wake()
}

///|
/// What the offer's stream is told: the state, and the chats whose screens are up (none: not said).
pub fn Share::line(self : Share) -> J {
  if self.screens.length() == 0 {
    self.state
  } else {
    set_field(self.state, "screens", jsa(self.screens))
  }
}

///|
/// The phone turned a tunnel down, saying why.
fn Share::refuse(self : Share, why : String, unpaired~ : Bool = false) -> Unit {
  self.refused = Some(why)
  self.refused_unpaired = unpaired
  let waiters = self.refusal_waiters.copy()
  self.refusal_waiters.clear()
  for d in waiters {
    ignore(d.succeed(()))
  }
}

///|
/// Done once a tunnel is turned down (at once if one was since `refused` was cleared).
async fn Share::refusal(self : Share) -> Unit {
  if self.refused is Some(_) {
    return
  }
  let d = @effect.Deferred::new()
  self.refusal_waiters.push(d)
  d.wait()
}

///|
/// What the agents are told of it (`adb_devices`).
pub fn Share::listed(self : Share) -> J {
  jo([
    ("serial", js(self.serial())),
    ("device", get(self.info, "device")),
    ("android", get(self.info, "android")),
    (
      "owner",
      jo([
        ("name", get(self.owner, "name")),
        ("email", get(self.owner, "email")),
      ]),
    ),
    ("adb", get(self.state, "adb")),
    ("message", get(self.state, "message")),
  ])
}

///|
/// The phones offered now, by whose and which (`key`).
pub struct Shares {
  w : World
  by_key : Map[String, Share]
  /// The phones' boots `adb tcpip` was asked in (keepTcp).
  tcp_asked : Set[String]
  /// When each person's phone was last offered no longer, and why.
  gone : Map[String, J]
  limits : Limits
  /// Whether a station's removal is heard (`cloud`).
  cloud : Bool
  /// The grants' adb servers, where phones are lent to chats' grants.
  servers : GrantServers?
  /// The grants live now of a phone's owner (by email): a phone with any is connected in their servers alone.
  granted : (async (String) -> Array[String])?
  /// How the station's adb holds a person's phone changed, or the phone is offered no longer (Null).
  stated : async (String, J) -> Unit
  /// Actual commands or data on a grant's adb transport.
  used : async (String, Bool) -> Unit
  mut stopping : Bool
  stop_waiters : Array[@effect.Deferred[Unit]]
}

///|
pub fn Shares::new(
  w : World,
  limits~ : Limits = { quick: Some(adb_quick), long: Some(adb_timeout), },
  cloud~ : Bool = false,
  servers? : GrantServers,
  granted? : async (String) -> Array[String],
  stated~ : async (String, J) -> Unit = fn(_, _) { () },
  used~ : async (String, Bool) -> Unit = fn(_, _) { () },
) -> Shares {
  {
    w,
    by_key: {},
    tcp_asked: Set::new(),
    gone: {},
    limits,
    cloud,
    servers,
    granted,
    stated,
    used,
    stopping: false,
    stop_waiters: [],
  }
}

///|
/// The phones offered now, for the `adb_devices` tool.
pub fn Shares::list(self : Shares) -> Array[J] {
  self.by_key.values().map(s => s.listed()).collect()
}

///|
async fn Shares::adb(self : Shares) -> String? {
  match self.w.ask("adb.path", []) {
    Str(_) as s => Some(js_text(s))
    _ => None
  }
}

///|
/// A wait on the shares' clock, ended as they close (a fiber of their scope).
async fn Shares::wait(self : Shares, ms : Double) -> Unit {
  if self.stopping {
    raise fail_("interrupted")
  }
  let stopped : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.stop_waiters.push(stopped)
  @effect.race_first(async fn() { self.w.sleep(ms) }, async fn() {
    stopped.wait()
    raise fail_("interrupted")
  })
}

///|
/// The station stopping or handing over: listeners closed, offers ended without telling adb.
pub async fn Shares::close(self : Shares) -> Unit {
  self.stopping = true
  let waiters = self.stop_waiters.copy()
  self.stop_waiters.clear()
  for d in waiters {
    ignore(d.succeed(()))
  }
  let shares = self.by_key.values().collect()
  self.by_key.clear()
  for s in shares {
    s.close(self.w)
  }
}

///|
/// Done once `close` is called.
async fn Shares::stopped(self : Shares) -> Unit {
  if self.stopping {
    return
  }
  let d = @effect.Deferred::new()
  self.stop_waiters.push(d)
  d.wait()
}

///|
/// The chats whose own screens are up on `email`'s phone, told to it.
pub fn Shares::screens(
  self : Shares,
  email : String,
  titles : Array[String],
) -> Unit {
  for share in self.by_key.values() {
    if share.email().to_lower() == email.to_lower() {
      share.set_screens(titles)
    }
  }
}

///|
/// `email`'s grants changed: their phones connected anew in the servers they are to be in now.
pub fn Shares::regrant(self : Shares, email : String) -> Unit {
  for share in self.by_key.values() {
    if share.email().to_lower() != email.to_lower() || share.streams == 0 {
      continue
    }
    share.failures = 0
    (self.w.spawn)(async fn() { connect(self, share) catch { _ => () } })
  }
}

///|
async fn Shares::granted_of(self : Shares, email : String) -> Array[String] {
  match self.granted {
    Some(f) => f(email)
    None => []
  }
}

///|
/// Which phone of whose an offer or ask is about: the phone's device key as it says (`phone`), else the connection's.
pub fn key(w : World, viewer : J, conn : J, ask : J) -> String {
  ignore(w)
  let phone = match at(Some(ask), "phone") {
    Some(Str(_) as p) if hex64(js_text(p)) => js_text(p)
    _ => conn_remote_id(conn)
  }
  "\{text_of(at(Some(viewer), "sub"))}/\{phone}"
}

///|
fn hex64(s : String) -> Bool {
  s.length() == 64 &&
  s
  .iter()
  .all(c => {
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
  })
}

///|
/// api/request.ts `langOfCore`: the language a core asked in (`stillfail-lang`), Chinese where it says none.
pub fn lang_of_core(headers : J) -> String {
  match headers {
    Obj(fs) =>
      for f in fs {
        if @jsjson.sanitize_str(f.0).to_lower() == "stillfail-lang" {
          let l = js_trim(js_text(f.1)).to_lower()
          return if l == "" || l.has_prefix("zh") { "zh" } else { "en" }
        }
      } nobreak {
        "zh"
      }
    _ => "zh"
  }
}

///|
/// A stream whose head says `"adb"`: an offer, held as long as the stream is, or an ask about the phone's offer.
pub async fn answer_adb(
  shares : Shares,
  conn : J,
  viewer : J,
  head : J,
  stream : J,
) -> Unit {
  let w = shares.w
  let ask = match at(Some(head), "adb") {
    Some(Null) | None => jo([])
    Some(a) => a
  }
  let device = key(w, viewer, conn, ask)
  let headers = match at(Some(head), "headers") {
    Some(Obj(fs)) => J::Obj(fs.filter(f => f.1 is Str(_)))
    _ => jo([])
  }
  let asked = lang_of_core(headers)
  let reply = async fn(status : Int, message : String, code : String?) {
    write_line(
      w,
      stream,
      jo([
        ("status", ji(status)),
        ("headers", jo([("content-type", js("application/json"))])),
      ]),
    )
    let body = match code {
      None => jo([("message", js(message))])
      Some(c) => jo([("message", js(message)), ("code", js(c))])
    }
    stream_write(w, stream, @utf8.encode(stringify(body)))
    w.stream_finish(stream)
  }
  let op = at(Some(ask), "op")
  if op is Some(Str(_)) && text_of(op) == "share" {
    return offer(shares, conn, viewer, device, ask, asked, stream)
  }
  if op is Some(Str(_)) && (text_of(op) == "pair" || text_of(op) == "grant") {
    guard shares.by_key.get(device) is Some(share) else {
      return reply(409, w.tr(asked, "station.adb.notSharing"), None)
    }
    let done = try {
      let message = if text_of(op) == "pair" {
        pair(shares, share, str_of(at(Some(ask), "code")).unwrap_or(""), asked)
      } else {
        grant(shares, share, asked)
      }
      Ok(message)
    } catch {
      e =>
        Err(
          (
            message_of(e),
            if kind_of(e) == "GrantRefused" {
              Some(grant_refused)
            } else {
              None
            },
          ),
        )
    }
    w.log(
      "info",
      "adb",
      "adb asked",
      jo([
        ("email", get(viewer, "email")),
        ("op", op.unwrap()),
        (
          "done",
          js(
            match done {
              Ok(m) => m
              Err((e, _)) => "error: \{e}"
            },
          ),
        ),
      ]),
    )
    return match done {
      Ok(m) => reply(200, m, None)
      Err((e, code)) => reply(422, e, code)
    }
  }
  reply(400, w.tr(asked, "station.adb.unknownAsk"), None)
}

///|
/// Done once `conn` has answered nothing for SILENT_MS (never, with a connection that cannot be asked); `stop` ends
/// the asking.
fn silent(
  shares : Shares,
  conn : J,
  said : @effect.Deferred[String],
  stopped : Ref[Bool],
) -> Unit {
  let w = shares.w
  (w.spawn)(async fn() {
    let mut missed = 0
    while !stopped.val {
      // timer: a heartbeat of the phone's connection
      shares.wait(silent_ms / 3.0) catch {
        _ => stopped.val = true
      }
      if stopped.val {
        return
      }
      let answered = w.conn_answers(conn, silent_ms / 6.0) catch { _ => true }
      missed = if answered { 0 } else { missed + 1 }
      if missed >= 3 {
        ignore(said.succeed("silent"))
        return
      }
    }
  })
}

///|
/// A word the phone says of itself, short and on one line.
pub fn text(value : J?, max : Int) -> String {
  guard value is Some(Str(_)) else { return "" }
  let out = StringBuilder::new()
  let mut n = 0
  for c in text_of(value) {
    let cp = c.to_int()
    if cp <= 0x1f || (cp >= 0x7f && cp <= 0x9f) {
      continue
    }
    if n >= max {
      break
    }
    out.write_char(c)
    n += 1
  }
  out.to_string()
}

///|
/// An Android package name, as `pm grant` takes it: nothing a shell would read otherwise.
pub fn is_package(name : String) -> Bool {
  name.length() > 0 &&
  name.length() <= 200 &&
  name
  .iter()
  .all(c => {
    (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    (c >= '0' && c <= '9') ||
    c == '.' ||
    c == '_'
  })
}

///|
fn info_of(ask : J) -> J {
  let package_ = match at(Some(ask), "package") {
    Some(Str(_) as p) if is_package(js_text(p)) => p
    _ => js("")
  }
  let connect = match at(Some(ask), "connect") {
    Some(Num(n)) if is_int(n) && n > 0.0 && n < 65536.0 => jn(n)
    _ => J::Null
  }
  jo([
    ("device", js(text(at(Some(ask), "device"), 80))),
    ("android", js(text(at(Some(ask), "android"), 20))),
    ("package", package_),
    (
      "adbd",
      match at(Some(ask), "adbd") {
        Some(Bool(b)) => jb(b)
        _ => jb(true)
      },
    ),
    (
      "pair",
      match at(Some(ask), "pair") {
        Some(Bool(b)) => jb(b)
        _ => jb(false)
      },
    ),
    ("connect", connect),
  ])
}

///|
/// An offer: the phone in `shares` (its listener up), adb told, and how adb holds it said down the stream until the
/// phone stops it, its connection goes, or the station is removed. A later offer from the phone takes this one's place.
async fn offer(
  shares : Shares,
  conn : J,
  viewer : J,
  device : String,
  ask : J,
  asked : String,
  stream : J,
) -> Unit {
  let w = shares.w
  let info = info_of(ask)
  let number = next_offer.val
  next_offer.val += 1
  let mut share = shares.by_key.get(device)
  // What adb is asked again on: only what changes how it reaches the phone.
  let before = share.map(s => s.info)
  match share {
    Some(s) => {
      s.info = info
      s.conn = conn
      s.lang = asked
      s.offer = number
    }
    None => {
      let (server, port) = bind(w, device)
      let made = Share::new(server, port, viewer, info, conn, asked, number)
      let email = text_of(at(Some(viewer), "email"))
      made.on_set = Some(async fn(state) { (shares.stated)(email, state) })
      // Another offer of the same phone may have come while this one bound its port: the first in keeps it.
      let raced = shares.by_key.get(device)
      if raced is Some(_) || shares.stopping {
        (w.spawn)(async fn() {
          ignore(w.ask("net.close", [server])) catch {
            _ => ()
          }
        })
        if shares.stopping {
          w.stream_reset(stream, 0)
          return
        }
        let r = raced.unwrap()
        r.info = info
        r.conn = conn
        r.lang = asked
        r.offer = number
        share = Some(r)
      } else {
        listen(shares, made)
        shares.by_key[device] = made
        w.log(
          "info",
          "adb",
          "phone offered for adb",
          jo([("email", js(email)), ("port", ji(made.port))]),
        )
        share = Some(made)
      }
    }
  }
  let share = share.unwrap()
  write_line(
    w,
    stream,
    jo([
      ("status", ji(200)),
      ("headers", jo([("content-type", js("application/x-ndjson"))])),
    ]),
  )
  let remote = js(conn_remote_id(conn))
  w.log(
    "info",
    "adb",
    "adb offer",
    spread(
      spread(jo([("offer", ji(number))]), conn_about(conn)),
      jo([
        ("main", jb(jeq(remote, at(Some(ask), "phone").unwrap_or(Null)))),
        ("adbd", get(info, "adbd")),
        ("pair", get(info, "pair")),
        ("connect", get(info, "connect")),
      ]),
    ),
  )
  // adbd's port changing (Wireless debugging turned off and on) is said by phones from 2026-10-26 on.
  let moved = match before {
    Some(b) =>
      !(get(b, "connect") is Null) &&
      !(get(info, "connect") is Null) &&
      !jeq(get(b, "connect"), get(info, "connect"))
    None => false
  }
  // A phone paired with its own adbd offers again without changing its ports.
  let waiting_for_phone = share.adb_state() == "unpaired" ||
    (share.adb_state() == "connecting" && share.connecting is Some(_))
  if before is None ||
    !jeq(get(before.unwrap(), "adbd"), get(info, "adbd")) ||
    moved ||
    share.adb_state() == "failed" ||
    share.adb_state() == "missing" ||
    waiting_for_phone {
    share.failures = 0
    (w.spawn)(async fn() { connect(shares, share) catch { _ => () } })
  }
  share.streams += 1
  let ends : @effect.Deferred[String] = @effect.Deferred::new()
  (w.spawn)(async fn() {
    w.stream_stopped(stream)
    ignore(ends.succeed("stopped"))
  })
  (w.spawn)(async fn() {
    w.conn_closed(conn)
    ignore(ends.succeed("closed"))
  })
  let silence = Ref(false)
  silent(shares, conn, ends, silence)
  if shares.cloud {
    (w.spawn)(async fn() {
      if w.ask("cloud.removed", []) is Bool(true) {
        ignore(ends.succeed("removed"))
        return
      }
      ignore(w.ask("cloud.removedLater", []))
      ignore(ends.succeed("removed"))
    })
  }
  (w.spawn)(async fn() {
    shares.stopped()
    ignore(ends.succeed("stopping"))
  })
  let mut ended = ""
  let mut seen = -1
  while true {
    if share.version != seen {
      seen = share.version
      let wrote = try {
        write_line(w, stream, share.line())
        true
      } catch {
        _ => false
      }
      if !wrote {
        ended = "stream"
        break
      }
      // Changed again while it was written: said at once.
      if share.version != seen {
        continue
      }
    }
    let changed : @effect.Deferred[Unit] = @effect.Deferred::new()
    share.waiters.push(changed)
    let next = @effect.race_first(
      async fn() {
        changed.wait()
        "changed"
      },
      async fn() { ends.wait() },
    )
    if next != "changed" {
      ended = next
      break
    }
  }
  silence.val = true
  share.streams -= 1
  if ended == "stopping" {
    return
  }
  // Only the latest offer takes the phone away, and only if no other comes a moment after.
  if ended != "removed" {
    shares.wait(grace) catch {
      _ => ()
    }
  }
  if !shares.stopping &&
    share.offer == number &&
    shares.by_key.get(device) is Some(s) &&
    physical_equal(s, share) {
    shares.by_key.remove(device)
    (w.spawn)(async fn() { share.close(w) })
    w.log(
      "info",
      "adb",
      "phone no longer offered for adb",
      jo([
        ("email", get(viewer, "email")),
        ("port", ji(share.port)),
        ("ended", js(ended)),
      ]),
    )
    shares.gone[text_of(at(Some(viewer), "email")).to_lower()] = jo([
      ("at", jn((w.now)())),
      ("ended", js(ended)),
    ])
    (shares.stated)(text_of(at(Some(viewer), "email")), Null)
    let adb = shares.adb()
    // (after what was keeping it lending: closing, it asks nothing more, and what it had asked is done)
    share.keeping.wait()
    match adb {
      Some(adb) => {
        let servers = servers_of(shares, share).unwrap_or([[]])
        for server in servers {
          ignore(
            run(
              w,
              adb,
              server + ["disconnect", share.serial()],
              shares.limits.quick,
            ),
          ) catch {
            _ => ()
          }
        }
      }
      None => ()
    }
  }
  w.stream_finish(stream)
}

///|
/// Each TCP connection to the phone's port, a tunnel on its offer's connection.
fn listen(shares : Shares, share : Share) -> Unit {
  let w = shares.w
  (w.spawn)(async fn() {
    while true {
      let socket = w.ask("net.accept", [share.server]) catch { _ => Null }
      if socket is Null {
        break
      }
      (w.spawn)(async fn() { take_socket(shares, share, socket) })
    }
  })
}

///|
async fn take_socket(shares : Shares, share : Share, socket : J) -> Unit {
  let w = shares.w
  let signal = share.take(w, socket)
  if signal.aborted {
    return
  }
  let conn = share.conn
  let ids = shares.granted_of(share.email())
  let ended = async fn(error : Error) {
    w.log(
      "info",
      "adb",
      "adb tunnel ended",
      spread(
        jo([("error", js(message_of(error))), ("offer", ji(share.offer))]),
        conn_about(conn),
      ),
    )
    share.refuse(refusal(error), unpaired=kind_of(error) == "Unpaired")
  }
  match (ids.length() > 0, shares.servers) {
    (true, Some(servers)) => {
      // Granted to chats: only their adb servers are let in (another chat's agent, knowing the port, is not).
      let id = servers.owner(socket, ids)
      if signal.aborted {
        return
      }
      guard id is Some(id) else {
        w.log(
          "info",
          "adb",
          "a connection to a granted phone's port from no grant's adb server turned away",
          jo([("port", ji(share.port))]),
        )
        ignore(w.ask("net.destroy", [socket]))
        return
      }
      let activity = AdbActivity::new(share.info_text("package"), force => {
        (w.spawn)(async fn() { (shares.used)(id, force) })
      })
      tunnel(
        w,
        conn,
        "connect",
        socket,
        signal=Some(signal),
        activity=Some(activity),
      ) catch {
        e => ended(e)
      }
    }
    _ =>
      tunnel(w, conn, "connect", socket, signal=Some(signal)) catch {
        e => ended(e)
      }
  }
}

///|
/// A port of the phone's own: its usual one if free, else any.
pub async fn bind(w : World, device : String) -> (J, Int) {
  let usual = usual_port(device)
  // An offer from before may hold it a moment yet: tried 5 times, each miss waited 500 ms after.
  for i in 0..<5 {
    match listen_on(w, usual) {
      Some(l) => return l
      None => w.sleep(500.0)
    }
    ignore(i)
  }
  listen_on(w, 0).unwrap()
}

///|
/// The port a phone looks for first: by its key's hash.
pub fn usual_port(device : String) -> Int {
  let hash = @memory.sha256_hex(@utf8.encode(device))
  let mut first = 0
  for c in js_slice(hash, 0, b=4) {
    first = first * 16 +
      (if c >= 'a' {
        c.to_int() - 'a'.to_int() + 10
      } else {
        c.to_int() - '0'.to_int()
      })
  }
  ports_start + first % (ports_end - ports_start)
}

///|
/// A listener of 127.0.0.1 on `port` (0: any), or None where it is not free.
async fn listen_on(w : World, port : Int) -> (J, Int)? {
  // (127.0.0.1 alone: the machine's own adb reaches it)
  let l = w.ask("net.listen", [
    jo([
      ("host", js("127.0.0.1")),
      ("port", ji(port)),
      ("exclusive", jb(true)),
      ("pauseOnConnect", jb(true)),
    ]),
  ]) catch {
    e => if port == 0 { raise e } else { return None }
  }
  Some((get(l, "id"), num_of(at(Some(l), "port")).unwrap_or(0.0).to_int()))
}

///|
/// What a tunnel's end tells the lending: the phone's own words where it turned it down.
fn refusal(error : Error) -> String {
  let m = message_of(error)
  let head = "the phone did not reach adb: "
  if kind_of(error) == "Refused" && m.has_prefix(head) {
    js_slice(m, head.length())
  } else {
    m
  }
}

///|
/// A stream to the phone for `socket`: `{"tunnel": kind}`, the phone's answer once it reached adbd (or why not), then
/// the bytes both ways until either side ends. `signal` ends it at once.
async fn tunnel(
  w : World,
  conn : J,
  kind : String,
  socket : J,
  signal~ : Stop? = None,
  activity~ : AdbActivity? = None,
) -> Unit {
  let stream : Ref[J] = { val: Null, }
  let abort = () => {
    (w.spawn)(async fn() {
      ignore(w.ask("net.destroy", [socket])) catch {
        _ => ()
      }
      if !(stream.val is Null) {
        w.stream_reset(stream.val, 0)
      }
    })
  }
  let listening = Ref(true)
  match signal {
    Some(s) => s.heard.push(() => if listening.val { abort() })
    None => ()
  }
  defer {
    listening.val = false
  }
  // Why is known (to its offer) before adb hears the socket end: its stream's reset is not waited for.
  errdefer {
    (w.spawn)(async fn() {
      ignore(w.ask("net.destroy", [socket])) catch {
        _ => ()
      }
    })
    if !(stream.val is Null) {
      let st = stream.val
      (w.spawn)(async fn() { w.stream_reset(st, 0) })
    }
  }
  stream.val = w.conn_open_bi(conn)
  if signal is Some(s) && s.aborted {
    return abort()
  }
  write_line(w, stream.val, jo([("tunnel", js(kind))]))
  let reader = Reader::new(w, stream.val)
  let answer = w.within(
    tunnel_open,
    async fn() { reader.line() },
    "the phone did not answer",
  )
  guard answer is Some(answer) else {
    raise fail_("the phone closed the tunnel")
  }
  match at(Some(answer), "error") {
    Some(Str(_) as e) =>
      raise if at(Some(answer), "unpaired") is Some(Bool(true)) {
        refused("Unpaired", js_text(e))
      } else {
        refused("Refused", "the phone did not reach adb: \{js_text(e)}")
      }
    _ => ()
  }
  let s = stream.val
  let up = async fn() -> Unit {
    defer (w.spawn)(async fn() { w.stream_finish(s) })
    while true {
      guard w.ask("net.read", [socket]) is Str(chunk) else { break }
      let bytes = unb64(@jsjson.sanitize_str(chunk))
      match activity {
        Some(a) => a.take(bytes)
        _ => ()
      }
      stream_write(w, s, bytes)
    }
  }
  let down = async fn() -> Unit {
    if reader.carry.length() > 0 {
      ignore(w.ask("net.write", [socket, js(b64(reader.carry))]))
    }
    while stream_read(w, s) is Some(more) {
      ignore(w.ask("net.write", [socket, js(b64(more))]))
    }
    ignore(w.ask("net.end", [socket]))
  }
  let results = @effect.all([
    async fn() {
      up() catch {
        e => return Some(e)
      }
      None
    },
    async fn() {
      down() catch {
        e => return Some(e)
      }
      None
    },
  ])
  for r in results {
    match r {
      Some(e) => raise e
      None => ()
    }
  }
}

///|
/// `adb connect` to the phone, one at a time: one asked while another is under way has it done once more after.
async fn connect(shares : Shares, share : Share) -> Unit {
  match share.connecting {
    Some(d) => {
      share.again = true
      return d.wait()
    }
    None => ()
  }
  let w = shares.w
  let started = (w.now)()
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  share.connecting = Some(d)
  let result = try {
    while true {
      share.again = false
      connect_once(shares, share)
      if !(share.again && !shares.stopping) {
        break
      }
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  share.connecting = None
  w.log(
    "info",
    "adb",
    "adb holds the phone",
    jo([("adb", get(share.state, "adb")), ("ms", jn((w.now)() - started))]),
  )
  match result {
    Err(e) => {
      ignore(d.fail(e))
      raise e
    }
    Ok(_) => ()
  }
  if share.adb_state() == "failed" {
    again(shares, share)
  } else {
    share.failures = 0
  }
  ignore(d.succeed(()))
}

///|
/// adb tried again once RETRY (doubled for each failure before) is over, while an offer of the phone's stream is open
/// and nothing else took adb on to it meanwhile.
fn again(shares : Shares, share : Share) -> Unit {
  let mut wait = retry
  for _ in 0..<share.failures {
    wait = wait * 2.0
  }
  let wait = @cmp.minimum(wait, retry_most)
  share.failures += 1
  let version = share.version
  (shares.w.spawn)(async fn() {
    try {
      shares.wait(wait)
      if shares.stopping ||
        share.streams == 0 ||
        share.version != version ||
        share.connecting is Some(_) {
        return
      }
      connect(shares, share)
    } catch {
      _ => ()
    }
  })
}

///|
/// The adb servers the phone is connected in: its grants' (`-P <port>` each), else the station's own (nothing given);
/// None when a grant's would not start.
pub async fn servers_of(
  shares : Shares,
  share : Share,
) -> Array[Array[String]]? {
  let ids = shares.granted_of(share.email())
  guard ids.length() > 0 && shares.servers is Some(servers) else {
    return Some([[]])
  }
  let out = []
  for id in ids {
    match servers.ensure(id) {
      Some(s) => out.push(["-P", s.port.to_string()])
      None => ()
    }
  }
  if out.length() > 0 {
    Some(out)
  } else {
    None
  }
}

///|
/// `adb connect` to the phone in each server it is to be in, and how adb holds it then, as the first has it.
async fn connect_once(shares : Shares, share : Share) -> Unit {
  let w = shares.w
  let adb = shares.adb()
  let servers = servers_of(shares, share)
  match (adb, servers) {
    (Some(adb), Some(s)) if s[0].length() > 0 =>
      ignore(run(w, adb, ["disconnect", share.serial()], shares.limits.quick)) catch {
        _ => ()
      }
    _ => ()
  }
  guard servers is Some(servers) else {
    return share.set(
      "failed",
      message=w.tr(share.lang, "station.adb.serverDown"),
    )
  }
  let mut first : J? = None
  for server in servers {
    connect_in(shares, share, server)
    if first is None {
      first = Some(share.state)
    }
  }
  match first {
    Some(f) if !jeq(get(f, "adb"), get(share.state, "adb")) =>
      share.set(
        text_of(at(Some(f), "adb")),
        message=text_of(at(Some(f), "message")),
      )
    _ => ()
  }
}

///|
/// `adb connect` to the phone in one adb server (`server`: its `-P <port>`, or none for the station's own), unless it
/// holds it already, and how it holds it then.
async fn connect_in(
  shares : Shares,
  share : Share,
  server : Array[String],
) -> Unit {
  let w = shares.w
  let run_in = async fn(
    bin : String,
    args : Array[String],
    timeout : Double?,
  ) -> String {
    run(w, bin, server + args, timeout)
  }
  let speaks = share.lang
  guard shares.adb() is Some(adb) else {
    return share.set("missing", message=w.tr(speaks, "station.adb.install"))
  }
  let serial = share.serial()
  // Nothing to reach: adb is not left trying to.
  if get(share.info, "adbd") is Bool(false) {
    ignore(run_in(adb, ["disconnect", serial], shares.limits.quick)) catch {
      _ => ()
    }
    return share.set("off", message=w.tr(speaks, "station.adb.wirelessOff"))
  }
  let state = async fn() -> String {
    run_in(adb, ["-s", serial, "get-state"], shares.limits.quick) catch {
      _ => ""
    }
  }
  // Held already (another offer: the pairing port opened, a new link): it stays so.
  if state() == "device" {
    keep_lending_up(shares, share, server)
    return share.set("connected")
  }
  share.set("connecting")
  share.refused = None
  // What adb kept of a tunnel gone goes first.
  ignore(run_in(adb, ["disconnect", serial], shares.limits.quick)) catch {
    _ => ()
  }
  ignore(run_in(adb, ["connect", serial], shares.limits.long)) catch {
    e => return share.set("failed", message=message_of(e))
  }
  // adb says `connected to …` for a TLS port it is not paired with too; only its state says whether it got in: looked
  // at every 500 ms until it is `device`, the phone turned its tunnel down, or SETTLE is over.
  let started = (w.now)()
  let mut now = ""
  while true {
    now = state()
    if now == "device" ||
      share.refused is Some(_) ||
      (w.now)() - started >= settle {
      break
    }
    @effect.race_first(async fn() { w.sleep(500.0) }, async fn() {
      share.refusal()
    })
  }
  let refused = share.refused
  let unpaired = share.refused_unpaired
  share.refused = None
  share.refused_unpaired = false
  if now == "device" {
    keep_lending_up(shares, share, server)
    share.set("connected")
  } else if now == "unauthorized" {
    share.set("unauthorized", message=w.tr(speaks, "station.adb.allowPrompt"))
  } else if refused is Some(refused) {
    // adb would go on dialling it a few times a second: let go until the next offer.
    ignore(run_in(adb, ["disconnect", serial], shares.limits.quick)) catch {
      _ => ()
    }
    if unpaired {
      share.set("unpaired", message=refused)
    } else {
      share.set("failed", message=refused)
    }
  } else {
    share.set("unpaired", message=w.tr(speaks, "station.adb.unpaired"))
  }
}

///|
/// `adb pair` through the phone's pairing port (open while its 使用配对码配对设备 dialog is), then connected anew.
async fn pair(
  shares : Shares,
  share : Share,
  typed : String,
  lang : String,
) -> String {
  let w = shares.w
  let code = StringBuilder::new()
  for c in typed {
    if c >= '0' && c <= '9' {
      code.write_char(c)
    }
  }
  let code = code.to_string()
  if code.length() != 6 {
    raise fail_(w.tr(lang, "station.adb.codeDigits"))
  }
  if !(get(share.info, "pair") is Bool(true)) {
    raise fail_(w.tr(lang, "station.adb.pairingClosed"))
  }
  guard shares.adb() is Some(adb) else {
    raise fail_(w.tr(lang, "station.adb.noAdb"))
  }
  // A port for this pairing alone, its one connection the phone's pairing port.
  let (server, port) = listen_on(w, 0).unwrap()
  let conn = share.conn
  let done = Stop::new()
  let close_server = () => {
    (w.spawn)(async fn() {
      ignore(w.ask("net.close", [server])) catch {
        _ => ()
      }
    })
  }
  let timer = match shares.limits.long {
    None => () => ()
    Some(ms) => w.after(ms, fn() { close_server() })
  }
  let tunnelled : Ref[@effect.Deferred[Unit]] = { val: done_now(), }
  let accepting = Ref(true)
  (w.spawn)(async fn() {
    let socket = w.ask("net.accept", [server]) catch { _ => Null }
    if socket is Null || !accepting.val {
      return
    }
    timer()
    close_server()
    let t : @effect.Deferred[Unit] = @effect.Deferred::new()
    tunnelled.val = t
    tunnel(w, conn, "pair", socket, signal=Some(done)) catch {
      e =>
        w.log(
          "info",
          "adb",
          "adb pairing tunnel ended",
          spread(jo([("error", js(message_of(e)))]), conn_about(conn)),
        )
    }
    ignore(t.succeed(()))
  })
  let said = Ok(
    run(w, adb, ["pair", "127.0.0.1:\{port}", code], shares.limits.long),
  ) catch {
    e => Err(e)
  }
  timer()
  close_server()
  // Not ended with adb: what it wrote last is still on its way to the phone, which keeps the key only once it has it.
  // The tunnel ends as both sides finish; reset only if the phone holds it open past TUNNEL_OPEN.
  let late = w.after(tunnel_open, fn() { done.abort() })
  let settled = tunnelled.val
  (w.spawn)(async fn() {
    settled.wait()
    late()
  })
  let said = match said {
    Ok(s) => s
    Err(e) => raise e
  }
  if !said.contains("Successfully paired") {
    raise fail_(w.tr(lang, "station.adb.pairFailed", args=[("said", said)]))
  }
  (w.spawn)(async fn() { connect(shares, share) catch { _ => () } })
  w.tr(lang, "station.adb.paired")
}

///|
/// As the station's adb comes to hold the phone, what keeps it lending with no one at it, done through that adb (in
/// `server`): the app may turn Wireless debugging on itself (`WRITE_SECURE_SETTINGS`), and Android's idling leaves the
/// app's connection be (`deviceidle whitelist`). What the phone refuses is logged, not said.
fn keep_lending_up(
  shares : Shares,
  share : Share,
  server : Array[String],
) -> Unit {
  let w = shares.w
  let pkg = share.info_text("package")
  if pkg == "" || !is_package(pkg) {
    return
  }
  let before = share.keeping
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  share.keeping = done
  (w.spawn)(async fn() {
    before.wait() catch {
      _ => ()
    }
    try {
      guard shares.adb() is Some(adb) else { return }
      let asks = [
        [
          "shell", keep_lending, "pm", "grant", pkg, "android.permission.WRITE_SECURE_SETTINGS",
        ],
        ["shell", keep_lending, "cmd", "deviceidle", "whitelist", "+\{pkg}"],
      ]
      for ask in asks {
        if share.closing {
          break
        }
        let said = run(
          w,
          adb,
          server + ["-s", share.serial()] + ask,
          shares.limits.long,
        ) catch {
          e => message_of(e)
        }
        let first = js_trim(
          said.split("\n").next().map(l => l.to_owned()).unwrap_or(""),
        )
        w.log(
          "info",
          "adb",
          "adb kept the phone lending",
          spread(
            jo([
              ("ask", js(ask[2:4].to_array().join(" "))),
              ("said", js(js_slice(first, 0, b=160))),
            ]),
            conn_about(share.conn),
          ),
        )
      }
      if !share.closing {
        keep_tcp(shares, share, adb, server)
      }
    } catch {
      _ => ()
    }
    ignore(done.succeed(()))
  })
}

///|
/// adbd's plain port, TCP_PORT, on: what the app holds its session to once Wi-Fi is gone. Asked once a boot, so a phone
/// that does not keep it is not restarted again and again.
pub async fn keep_tcp(
  shares : Shares,
  share : Share,
  adb : String,
  server : Array[String],
) -> Unit {
  let w = shares.w
  if get(share.info, "connect") is Num(n) && n == tcp_port.to_double() {
    return
  }
  let said = run(
    w,
    adb,
    server + ["-s", share.serial(), "shell", keep_tcp_command],
    shares.limits.long,
  ) catch {
    _ => ""
  }
  let lines = said.split("\n").map(l => js_trim(l.to_owned())).collect()
  let boot = lines.get(0).unwrap_or("")
  let port = lines.get(1)
  if port == Some(tcp_port.to_string()) ||
    boot == "" ||
    !boot
    .iter()
    .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c == '-') ||
    shares.tcp_asked.contains(boot) {
    return
  }
  shares.tcp_asked.add(boot)
  let done = run(
    w,
    adb,
    server + ["-s", share.serial(), "tcpip", tcp_port.to_string()],
    shares.limits.long,
  ) catch {
    e => message_of(e)
  }
  let first = js_trim(
    done.split("\n").next().map(l => l.to_owned()).unwrap_or(""),
  )
  w.log(
    "info",
    "adb",
    "adb asked for adbd's plain port",
    spread(jo([("said", js(js_slice(first, 0, b=160)))]), conn_about(share.conn)),
  )
}

///|
/// Lets the app turn Wireless debugging on itself from now on (`WRITE_SECURE_SETTINGS`): the app asks, each time the
/// phone is newly held here while it may not yet.
async fn grant(shares : Shares, share : Share, lang : String) -> String {
  let w = shares.w
  let pkg = share.info_text("package")
  if pkg == "" {
    raise fail_(w.tr(lang, "station.adb.noPackage"))
  }
  guard shares.adb() is Some(adb) else {
    raise fail_(w.tr(lang, "station.adb.noAdb"))
  }
  let server = servers_of(shares, share).unwrap_or([[]])[0]
  let said = run(
    w,
    adb,
    server +
    [
      "-s",
      share.serial(),
      "shell",
      "pm",
      "grant",
      pkg,
      "android.permission.WRITE_SECURE_SETTINGS",
    ],
    shares.limits.long,
  )
  // Quiet is granted. MIUI and ColorOS refuse the shell's grant until a switch in Developer options is on: said as
  // which one; anything else, by its first line.
  if said.contains("GRANT_RUNTIME_PERMISSIONS") {
    raise refused("GrantRefused", w.tr(lang, "station.adb.grantRefused"))
  }
  if said != "" {
    let first = js_trim(
      said.split("\n").next().map(l => l.to_owned()).unwrap_or(""),
    )
    raise fail_(w.tr(lang, "station.adb.grantFailed", args=[("said", first)]))
  }
  w.tr(lang, "station.adb.granted")
}

///|
/// Where adb may be, in the order looked at: on `PATH`, else the Android SDK's, else a package manager's. `env`: the
/// environment's `PATH`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `HOME`, `LOCALAPPDATA`; `exe`: adb's file's name there
/// (`adb.exe` on Windows); `sep` and `delimiter`, the machine's.
pub fn adb_candidates(
  env : J,
  on_path : String?,
  exe : String,
  sep : String,
  delimiter : String,
) -> Array[String] {
  let e = (k : String) => {
    match at(Some(env), k) {
      Some(Str(_) as s) => js_text(s)
      _ => ""
    }
  }
  let join = (parts : Array[String]) => @nodepath.join(sep, parts)
  let out = []
  match on_path {
    Some(p) if p != "" => out.push(p)
    _ => ()
  }
  for d in e("PATH").split(delimiter) {
    if d != "" {
      out.push(join([d.to_owned(), exe]))
    }
  }
  for k in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
    if e(k) != "" {
      out.push(join([e(k), "platform-tools", exe]))
    }
  }
  if e("HOME") != "" {
    out.push(join([e("HOME"), "Library/Android/sdk/platform-tools/adb"]))
    out.push(join([e("HOME"), "Android/Sdk/platform-tools/adb"]))
  }
  if e("LOCALAPPDATA") != "" {
    out.push(join([e("LOCALAPPDATA"), "Android", "Sdk", "platform-tools", exe]))
  }
  out + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
}

///|
/// What adb says to `args` (out, then err), within `timeout`. Said whatever its exit; fails only if it could not be
/// started or did not answer in time.
pub async fn run(
  w : World,
  adb : String,
  args : Array[String],
  timeout : Double?,
) -> String {
  let ran = w.ask("proc.run", [
    jo([
      ("file", js(adb)),
      ("args", jsa(args)),
      (
        "timeout",
        match timeout {
          Some(t) => jn(t)
          None => J::Null
        },
      ),
    ]),
  ])
  if at(Some(ran), "timedOut") is Some(Bool(true)) {
    raise fail_("adb did not answer in time")
  }
  js_trim(text_of(at(Some(ran), "out")) + text_of(at(Some(ran), "err")))
}
