// The cloud's transport (station/src/cloud/transport.ts): regional entries carry TCP only, the URL, HTTP Host, SNI and
// certificate identity staying the cloud's. A dial owns every candidate until one verified TLS socket is handed to
// HTTP or WebSocket; it never retries bytes. Only still.fail's canonical cloud HTTP and presence socket use an entry
// (station/AGENTS.md, Cloud TCP entries): direct TLS gets one second before one entry starts, both candidates share
// ten seconds for HTTP and twenty for a presence Upgrade, and a request's cancellation never owns a pool's dial.

///|
pub(all) struct CloudEntry {
  origin : String
  host : String
  port : Int
}

///|
pub let cloud_origin : String = "https://app.still.fail"

///|
/// A refusal or a failure of the cloud's network, with its words (`to_string` says them, not the type's name).
pub(all) suberror NetError {
  NetError(String)
}

///|
pub impl Show for NetError with output(self, logger) {
  match self {
    NetError(m) => logger.write_string(m)
  }
}

///|
/// config.json's `cloudEntry`: None where it names none; raised where it names one that is not right.
pub fn cloud_entry(config : Json) -> CloudEntry? raise NetError {
  let e = match config {
    Object(m) =>
      match m.get("cloudEntry") {
        None => return None
        Some(e) => e
      }
    _ => return None
  }
  let wrong = NetError(
    "cloudEntry needs origin https://app.still.fail, a host and a TCP port (1–65535); correct config.json",
  )
  match e {
    Object(m) => {
      guard m.get("origin") is Some(String(origin)) && origin == cloud_origin else {
        raise wrong
      }
      guard m.get("host") is Some(String(host)) && host != "" else {
        raise wrong
      }
      guard m.get("port") is Some(Number(port, ..)) &&
        port == port.floor() &&
        port >= 1.0 &&
        port <= 65535.0 else {
        raise wrong
      }
      Some({ origin, host, port: port.to_int() })
    }
    _ => raise wrong
  }
}

///|
/// A TLS socket a dial made: `destroy` lets it go (a loser's, a late success's).
pub(all) struct TlsSocket {
  id : Int
  host : String
  port : Int
  destroy : () -> Unit
}

///|
/// What a socket tells its dial: one of the two, once.
pub(all) struct TlsEvents {
  error : (String) -> Unit
  secure : () -> Unit
}

///|
/// What a dial is given (tests: theirs): a timer in the transport owner's scope and clock, and a TLS connection to
/// `host`:`port` that verifies `servername`'s certificate and sends it as SNI.
pub(all) struct DialIO {
  after : (Int, () -> Unit) -> () -> Unit
  tls : (String, Int, String, TlsEvents) -> TlsSocket raise
}

///|
/// Why a dial gave no socket: its words, and every candidate's own where they all failed (`AggregateError`).
pub(all) struct DialError {
  message : String
  errors : Array[String]
}

///|
pub let dial_timed_out : String = "cloud TLS connection timed out; check the network or regional entry"

///|
pub let dial_cancelled : String = "cloud connection cancelled"

///|
pub let dial_failed : String = "cloud TLS connections failed"

///|
/// What a failed socket says (presence.ts `failureText`): every address's own error when they all failed, else its
/// words.
pub fn failure_text(e : DialError) -> String {
  let each = e.errors.filter(m => m.length() > 0)
  if each.length() > 0 {
    each.join("; ")
  } else if e.message != "" {
    e.message
  } else if e.errors.length() > 0 {
    // (an AggregateError's name, where it says nothing else)
    "AggregateError"
  } else {
    "Error"
  }
}

///|
/// One direct attempt and at most one delayed entry, sharing one budget. The cancellation owns only pending sockets.
/// `done` is told once; what it returns cancels.
pub fn dial_cloud(
  io : DialIO,
  origin : String,
  entry : CloudEntry?,
  budget : Int,
  done : (Result[TlsSocket, DialError]) -> Unit,
) -> () -> Unit {
  let target = match parse_url(origin) {
    Some(u) => u
    None => {
      done(Err({ message: "Invalid URL", errors: [] }))
      return fn() {  }
    }
  }
  let sockets : Array[TlsSocket] = []
  let failures : Array[String] = []
  let mut finished = false
  let mut edge_started = false
  let mut stop_hedge : () -> Unit = fn() {  }
  let mut stop_deadline : () -> Unit = fn() {  }
  let finish = (result : Result[TlsSocket, DialError]) => {
    if finished {
      if result is Ok(winner) {
        (winner.destroy)()
      }
      return
    }
    finished = true
    stop_hedge()
    stop_deadline()
    let winner = match result {
      Ok(w) => w.id
      Err(_) => -1
    }
    for s in sockets {
      if s.id != winner {
        (s.destroy)()
      }
    }
    sockets.clear()
    done(result)
  }
  letrec start_edge = fn() -> Unit {
    if finished || edge_started {
      return
    }
    guard entry is Some(e) else { return }
    edge_started = true
    stop_hedge()
    start(e.host, e.port)
  }
  and start = fn(host : String, port : Int) -> Unit {
    if finished {
      return
    }
    let mine : Ref[TlsSocket?] = Ref(None)
    let failed = (error : String) => {
      if finished {
        return
      }
      if mine.val is Some(s) {
        match sockets.search_by(x => x.id == s.id) {
          Some(i) => ignore(sockets.remove(i))
          None => ()
        }
        (s.destroy)()
      }
      failures.push(error)
      if entry is Some(_) && !edge_started {
        start_edge()
      } else if sockets.length() == 0 {
        finish(Err({ message: dial_failed, errors: failures.copy() }))
      }
    }
    let events = {
      error: failed,
      secure: fn() {
        match mine.val {
          Some(s) => finish(Ok(s))
          None => ()
        }
      },
    }
    let made = (io.tls)(host, port, target.hostname(), events) catch {
      e => {
        failed(error_words(e))
        return
      }
    }
    mine.val = Some(made)
    sockets.push(made)
  }

  // timer: the delayed connection hedge and deadline, both in the transport owner's scope and clock.
  stop_deadline = (io.after)(budget, fn() {
    finish(Err({ message: dial_timed_out, errors: [] }))
  })
  if entry is Some(_) {
    stop_hedge = (io.after)(1000, start_edge)
  }
  let port = match target.port {
    Some(p) => p
    None => 443
  }
  start(target.hostname(), port)
  fn() {
    if !finished {
      finish(Err({ message: dial_cancelled, errors: [] }))
    }
  }
}

///|
/// An error's words, as `Error.message` says them.
pub fn error_words(e : Error) -> String {
  match e {
    Failure(m) => m
    NetError(m) => m
    _ => e.to_string()
  }
}

///|
/// A socket of the presence connection's own (a WebSocket), as its owner sees it.
pub(all) struct WsSocket {
  send : (String) -> Unit
  /// A clean close; `terminate` a dead one's.
  close : () -> Unit
  terminate : () -> Unit
  is_open : () -> Bool
}

///|
/// What a WebSocket tells, as `ws` does: `unexpected` an HTTP answer other than the Upgrade (its status), `close` once
/// at its end (its code and reason).
pub(all) struct WsEvents {
  open : () -> Unit
  message : (String) -> Unit
  unexpected : (Int) -> Unit
  error : (String) -> Unit
  close : (Int, String) -> Unit
}

///|
/// How a WebSocket is opened: `over` a TLS socket a dial made (the entry's way), or by itself (None).
pub(all) struct WsIO {
  open : (String, Headers, TlsSocket?, WsEvents) -> WsSocket raise
}

///|
/// The cloud's transport: the pending dials, and whether it is closed. What it is given: the current entry (config.json
/// read anew at each use) and the dial's IO.
pub struct CloudTransport {
  entry : () -> CloudEntry?
  io : DialIO
  pending : Map[Int, () -> Unit]
  mut next : Int
  mut closed : Bool
}

///|
pub fn CloudTransport::new(entry : () -> CloudEntry?, io : DialIO) -> CloudTransport {
  { entry, io, pending: {}, next: 0, closed: false }
}

///|
/// A dial of its own, with `budget` ms for every candidate; what it returns cancels it (and nothing else).
pub fn CloudTransport::dial(
  self : CloudTransport,
  budget : Int,
  done : (Result[TlsSocket, DialError]) -> Unit,
) -> () -> Unit {
  if self.closed {
    done(Err({ message: "cloud transport closed", errors: [] }))
    return fn() {  }
  }
  self.next += 1
  let id = self.next
  let cancel : Ref[() -> Unit] = Ref(fn() {  })
  let held = fn() { (cancel.val)() }
  self.pending[id] = held
  cancel.val = dial_cloud(self.io, cloud_origin, (self.entry)(), budget, r => {
    self.pending.remove(id)
    done(r)
  })
  held
}

///|
/// Whether `url` goes by the entry: still.fail's canonical origin with an entry named. Raised where `url` is none.
pub fn CloudTransport::eligible(
  self : CloudTransport,
  url : String,
  provider? : Provider = Stillfail,
) -> Bool raise NetError {
  let u = match parse_url(url) {
    Some(u) => u
    None => raise NetError("Invalid URL: \{url}")
  }
  provider is Stillfail && u.origin() == cloud_origin && (self.entry)() is Some(_)
}

///|
/// The deadline of a presence Upgrade (TLS and the HTTP Upgrade both), and of each WebSocket's own dial.
pub let upgrade_budget : Int = 20_000

///|
/// The budget of an HTTP request's pool dial.
pub let http_budget : Int = 10_000

///|
/// Each WebSocket gets its own dial and an encompassing TLS + Upgrade deadline: what it returns is the socket, whose
/// `terminate` cancels its dial too.
pub fn CloudTransport::websocket(
  self : CloudTransport,
  url : String,
  headers : Headers,
  ws : WsIO,
  events : WsEvents,
) -> WsSocket {
  let inner : Ref[WsSocket?] = Ref(None)
  let mut ended = false
  let mut cancel_dial : () -> Unit = fn() {  }
  let mut stop : () -> Unit = fn() {  }
  let end = fn(code : Int, reason : String) {
    if ended {
      return
    }
    ended = true
    stop()
    cancel_dial()
    (events.close)(code, reason)
  }
  let own = {
    open: fn() {
      stop()
      (events.open)()
    },
    message: events.message,
    unexpected: events.unexpected,
    error: fn(e) {
      stop()
      cancel_dial()
      (events.error)(e)
    },
    close: end,
  }
  let terminate = fn() {
    cancel_dial()
    stop()
    match inner.val {
      Some(s) => (s.terminate)()
      None => {
        // (closed before the socket was had: what `ws` says then)
        if !ended {
          (events.error)(
            "WebSocket was closed before the connection was established",
          )
        }
        end(1006, "")
      }
    }
  }
  cancel_dial = self.dial(upgrade_budget, r => match r {
    Ok(sock) =>
      if ended {
        (sock.destroy)()
      } else {
        inner.val = Some(
          (ws.open)(url, headers, Some(sock), own) catch {
            e => {
              (own.error)(error_words(e))
              end(1006, "")
              return
            }
          },
        )
      }
    Err(e) => {
      (own.error)(failure_text(e))
      end(1006, "")
    }
  })
  // timer: a deadline for this exclusive TLS + HTTP Upgrade handshake.
  stop = (self.io.after)(upgrade_budget, terminate)
  if ended {
    stop()
  }
  {
    send: fn(text) {
      if inner.val is Some(s) {
        (s.send)(text)
      }
    },
    close: fn() {
      match inner.val {
        Some(s) => (s.close)()
        None => terminate()
      }
    },
    terminate,
    is_open: fn() {
      match inner.val {
        Some(s) => (s.is_open)()
        None => false
      }
    },
  }
}

///|
/// Closed: every pending dial cancelled, and no more dials.
pub fn CloudTransport::close(self : CloudTransport) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let all = self.pending.values().collect()
  for cancel in all {
    cancel()
  }
}

///|
/// How many dials are pending (tests).
pub fn CloudTransport::pending_dials(self : CloudTransport) -> Int {
  self.pending.length()
}

///|
/// Node's `http.STATUS_CODES` reason phrase for an HTTP status code.
pub fn http_status_text(status : Int) -> String {
  match status {
    100 => "Continue"
    101 => "Switching Protocols"
    102 => "Processing"
    103 => "Early Hints"
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    203 => "Non-Authoritative Information"
    204 => "No Content"
    205 => "Reset Content"
    206 => "Partial Content"
    207 => "Multi-Status"
    208 => "Already Reported"
    226 => "IM Used"
    300 => "Multiple Choices"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    305 => "Use Proxy"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    402 => "Payment Required"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    406 => "Not Acceptable"
    407 => "Proxy Authentication Required"
    408 => "Request Timeout"
    409 => "Conflict"
    410 => "Gone"
    411 => "Length Required"
    412 => "Precondition Failed"
    413 => "Payload Too Large"
    414 => "URI Too Long"
    415 => "Unsupported Media Type"
    416 => "Range Not Satisfiable"
    417 => "Expectation Failed"
    418 => "I'm a Teapot"
    421 => "Misdirected Request"
    422 => "Unprocessable Entity"
    423 => "Locked"
    424 => "Failed Dependency"
    425 => "Too Early"
    426 => "Upgrade Required"
    428 => "Precondition Required"
    429 => "Too Many Requests"
    431 => "Request Header Fields Too Large"
    451 => "Unavailable For Legal Reasons"
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    505 => "HTTP Version Not Supported"
    506 => "Variant Also Negotiates"
    507 => "Insufficient Storage"
    508 => "Loop Detected"
    509 => "Bandwidth Limit Exceeded"
    510 => "Not Extended"
    511 => "Network Authentication Required"
    _ => ""
  }
}
