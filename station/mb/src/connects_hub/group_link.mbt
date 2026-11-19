// A group connect's link to its IM anchor (group/link.ts; AFK-surf/group, protocol `im/2`): an iroh endpoint of the
// connect's own key, dialled to the server's endpoint through its relays, let in by its hello, then a request a
// stream. The framing is the mesh's (mesh/wire.ts, the door's): the first stream is the control stream, one JSON line
// each way at a time (the hello `{credential, name}` and its answer, then a ping and its answer), every other stream
// one request, a JSON head line `{method, path, headers}` then its body, answered a head line `{status, headers}` then
// the body.
//
// The device is the connect's key, which the connection proves; its hello says a code only where the device joins by
// one (an invitation, a device code). What answers it is the server's (its `LetIn`, or `{error, code, why}`).
//
// The same endpoint takes the connections other members' devices dial it by to hand it a secret (`im-secret/1`: one
// stream, one JSON line each way), which the surface serves (`accepted`).

///|
/// The IM's protocol (its anchor.mbt `alpn`).
pub let alpn : String = "im/2"

///|
/// What a device dials another member's device by to hand it a secret, end to end.
pub let secret_alpn : String = "im-secret/1"

///|
/// The server was not reached, or the link went (asked again on the connect's backoff): its code taken as no answer.
pub fn group_unreached(message : String) -> Error {
  @session_chats.Thrown("EHOSTUNREACH", message)
}

///|
/// The server said no to the hello (`why`: the server's word for it). Stands until the connect's code changes.
pub fn group_refused(message : String, why : String) -> Error {
  @session_chats.Thrown("GroupRefused:\{why}", message)
}

///|
/// A stream of a mesh connection (mesh/endpoint.ts `Stream`).
pub(all) struct MeshStream {
  read : async () -> Bytes?
  write : async (Bytes) -> Unit
  finish : async () -> Unit
  reset : async (Int) -> Unit
  /// Once what was sent is acknowledged.
  stopped : async () -> Unit
}

///|
/// A mesh connection (mesh/endpoint.ts `Connection`).
pub(all) struct MeshConn {
  open_bi : async () -> MeshStream
  close : (Int, String) -> Unit
  is_closed : () -> Bool
  /// A stream the other end opened (None: no more).
  accept_bi : async () -> MeshStream?
  /// The endpoint id of the other end.
  remote_id : () -> String
}

///|
/// An endpoint bound (mesh/endpoint.ts `Endpoint`).
pub(all) struct MeshEndpoint {
  id : () -> String
  /// Dials `{id, relays, ips?}` for a protocol.
  connect : async (J, String) -> MeshConn
  /// A connection dialled to it, as it comes (None: closed).
  accept : async () -> MeshConn?
  close : async () -> Unit
}

///|
/// What binds endpoints (mesh/endpoint.ts `Endpoints`): given `{secretKey (hex), alpns, relayUrls, discovery}`.
pub(all) struct Endpoints {
  bind : async (J) -> MeshEndpoint
}

///|
let max_head : Int = 16384

///|
let max_body : Int = 67108864

///|
/// One JSON line at a time from a stream, then the rest of it (mesh/wire.ts `Reader`).
pub struct LineReader {
  priv mut carry : Bytes
  stream : MeshStream
  priv max_line : Int
}

///|
pub fn LineReader::new(stream : MeshStream, max_line? : Int = max_head) -> LineReader {
  { carry: b"", stream, max_line }
}

///|
fn index_of_byte(b : Bytes, x : Byte) -> Int {
  for i in 0..<b.length() {
    if b[i] == x {
      return i
    }
  }
  -1
}

///|
pub async fn LineReader::line(self : LineReader) -> J? {
  let mut at_ = index_of_byte(self.carry, b'\n')
  if at_ < 0 {
    let parts = Buffer()
    parts.write_bytes(self.carry)
    let mut size = self.carry.length()
    while at_ < 0 {
      if size > self.max_line {
        raise fail_("head too large")
      }
      match (self.stream.read)() {
        None => {
          if size == 0 {
            return None
          }
          raise fail_("stream ended mid-line")
        }
        Some(more) => {
          let found = index_of_byte(more, b'\n')
          if found >= 0 {
            at_ = size + found
          }
          parts.write_bytes(more)
          size += more.length()
        }
      }
    }
    self.carry = parts.to_bytes()
  }
  if at_ > self.max_line {
    raise fail_("head too large")
  }
  let line = self.carry[0:at_]
  self.carry = self.carry[at_ + 1:].to_owned()
  Some(parse_js(text_of(line)))
}

///|
pub async fn LineReader::rest(self : LineReader) -> Bytes {
  let parts = Buffer()
  parts.write_bytes(self.carry)
  let mut size = self.carry.length()
  while (self.stream.read)() is Some(more) {
    parts.write_bytes(more)
    size += more.length()
    if size > max_body {
      raise fail_("request body too large")
    }
  }
  parts.to_bytes()
}

///|
/// The next piece of the rest as it comes (None: it ended).
pub async fn LineReader::chunk(self : LineReader) -> Bytes? {
  if self.carry.length() > 0 {
    let first = self.carry
    self.carry = b""
    return Some(first)
  }
  (self.stream.read)()
}

///|
pub async fn write_line(stream : MeshStream, value : J) -> Unit {
  (stream.write)(utf8(js_stringify(value) + "\n"))
}

///|
/// Who the server let this device in as (its protocol.ts `LetIn`).
pub(all) struct LetIn {
  member_id : String
  name : String
  owner : Bool
  joined : Bool
}

///|
/// An answer read whole: its status, headers (by their names in lowercase) and body.
pub(all) struct Answered {
  status : Int
  headers : Map[String, String]
  body : Bytes
}

///|
/// An answer read as it comes (the event stream): its head, its body's pieces, and what lets go of it.
pub struct Streamed {
  status : Int
  headers : Map[String, String]
  next : async () -> Bytes?
  cancel : () -> Unit
}

///|
pub struct LinkOptions {
  endpoints : Endpoints
  secret_key : String
  server : String
  relays : Array[String]
  /// Where the server is besides its relays (a test's endpoint on 127.0.0.1); none in config.json.
  ips : Array[String]
}

///|
fn headers_of(v : J?) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for f in fields_of(v) {
    match f.1 {
      Str(u) => out[@session_chats.lower(f.0)] = @jsjson.sanitize_str(u)
      _ => ()
    }
  }
  out
}

///|
/// A body asked with a request: none, JSON, or bytes as they are.
pub(all) enum Asked {
  NoAsked
  JsonAsked(J)
  BytesAsked(Bytes)
}

///|
pub struct GroupLink {
  priv o : LinkOptions
  priv mut endpoint : @effect.Deferred[MeshEndpoint]?
  priv mut conn : MeshConn?
  priv mut control : (MeshStream, LineReader)?
  /// One line at a time on the control stream: a ping waits for the one before it.
  priv mut turn : Turns
  priv mut closed : Bool
}

///|
pub fn GroupLink::new(o : LinkOptions) -> GroupLink {
  { o, endpoint: None, conn: None, control: None, turn: Turns::new(), closed: false }
}

///|
/// This device's endpoint id (its key's public half).
pub async fn GroupLink::device(self : GroupLink) -> String {
  (self.bound().id)()
}

///|
async fn GroupLink::bound(self : GroupLink) -> MeshEndpoint {
  let d = match self.endpoint {
    Some(d) => d
    None => {
      let d : @effect.Deferred[MeshEndpoint] = @effect.Deferred::new()
      self.endpoint = Some(d)
      let options = jo([("secretKey", js(self.o.secret_key)), ("alpns", jsa([secret_alpn])), ("relayUrls", jsa(self.o.relays)), ("discovery", jb(false))])
      spawn(async fn() {
        let e = (self.o.endpoints.bind)(options) catch {
          err => {
            ignore(d.fail(err))
            return
          }
        }
        ignore(d.succeed(e))
      })
      d
    }
  }
  d.wait()
}

///|
/// The connections dialled to this device (`im-secret/1`), as they come; None once its endpoint is closed.
pub async fn GroupLink::accepted(self : GroupLink) -> MeshConn? {
  if self.closed {
    return None
  }
  (self.bound().accept)()
}

///|
/// Whether a connection let in is up.
pub fn GroupLink::open(self : GroupLink) -> Bool {
  match (self.conn, self.control) {
    (Some(c), Some(_)) => !(c.is_closed)()
    _ => false
  }
}

///|
/// A new connection to the server, let in by `hello` (the one before it closed first): who it let this device in as.
pub async fn GroupLink::connect(self : GroupLink, hello : J) -> LetIn {
  if self.closed {
    raise group_unreached("the link is closed")
  }
  self.drop("dialled again")
  let endpoint = self.bound()
  let addr = jo([("id", js(self.o.server)), ("relays", jsa(self.o.relays))] + (if self.o.ips.length() > 0 { [("ips", jsa(self.o.ips))] } else { [] }))
  let conn = (endpoint.connect)(addr, alpn) catch { e => raise group_unreached("the server was not reached: \{thrown_message(e)}") }
  let (stream, reader, answer) = try {
    let stream = (conn.open_bi)()
    let reader = LineReader::new(stream)
    write_line(stream, hello)
    let answer = reader.line()
    (stream, reader, answer)
  } catch {
    e => {
      (conn.close)(0, "no hello")
      raise group_unreached("the server did not answer the hello: \{thrown_message(e)}")
    }
  }
  match answer {
    Some(a) if at(Some(a), "ok") is Some(Bool(true)) => ()
    None => {
      (conn.close)(0, "refused")
      raise group_unreached("the server did not answer the hello")
    }
    Some(a) => {
      (conn.close)(0, "refused")
      let why = match (str_of(at(Some(a), "why")), str_of(at(Some(a), "code"))) {
        (Some(w), _) => w
        (None, Some(c)) => c
        _ => "refused"
      }
      raise group_refused(str_of(at(Some(a), "error")).unwrap_or(why), why)
    }
  }
  let answer = answer.unwrap()
  if self.closed {
    (conn.close)(0, "closed")
    raise group_unreached("the link is closed")
  }
  self.conn = Some(conn)
  self.control = Some((stream, reader))
  self.turn = Turns::new()
  let text = (k : String) => match at(Some(answer), k) {
    Some(Null) | None => ""
    Some(v) => js_text(Some(v))
  }
  { member_id: text("member"), name: text("name"), owner: at(Some(answer), "owner") is Some(Bool(true)), joined: at(Some(answer), "joined") is Some(Bool(true)) }
}

///|
/// The control stream said a line again and was answered (the server asks again who the device is): the link is
/// alive. Fails where it is not, or the device is no member's any more.
pub async fn GroupLink::ping(self : GroupLink) -> Unit {
  guard self.control is Some((stream, reader)) else { raise group_unreached("not connected") }
  self.turn.run(async fn() {
    write_line(stream, jo([("credential", js(""))]))
    match reader.line() {
      None => raise group_unreached("the link went")
      Some(line) =>
        if !(at(Some(line), "ok") is Some(Bool(true))) && str_of(at(Some(line), "error")) is Some(error) {
          raise group_refused(error, str_of(at(Some(line), "why")).unwrap_or("refused"))
        }
    }
  })
}

///|
async fn GroupLink::opened(self : GroupLink, verb : String, path : String, body : Bytes?, headers : J) -> (MeshStream, LineReader, J) {
  guard self.conn is Some(conn) && !(conn.is_closed)() else { raise group_unreached("not connected") }
  let stream = try {
    let stream = (conn.open_bi)()
    write_line(stream, jo([("method", js(verb)), ("path", js(path)), ("headers", headers)]))
    match body {
      Some(b) if b.length() > 0 => (stream.write)(b)
      _ => ()
    }
    (stream.finish)()
    stream
  } catch {
    e => raise group_unreached("the request did not go: \{thrown_message(e)}")
  }
  let reader = LineReader::new(stream)
  let head = reader.line() catch { e => raise group_unreached("the request was not answered: \{thrown_message(e)}") }
  match head {
    Some(h) if at(Some(h), "status") is Some(Num(_)) => (stream, reader, h)
    _ => raise group_unreached("the request was not answered")
  }
}

///|
/// One request, its answer read whole.
pub async fn GroupLink::ask(self : GroupLink, verb : String, path : String, body? : Asked = NoAsked) -> Answered {
  let (bytes, headers) = match body {
    NoAsked => (None, jo([]))
    JsonAsked(v) => (Some(utf8(js_stringify(v))), jo([("content-type", js("application/json"))]))
    BytesAsked(b) => (Some(b), jo([("content-type", js("application/octet-stream"))]))
  }
  let (_, reader, head) = self.opened(verb, path, bytes, headers)
  let rest = reader.rest() catch { e => raise group_unreached("the answer was cut: \{thrown_message(e)}") }
  { status: num_of(at(Some(head), "status")).unwrap_or(0.0).to_int(), headers: headers_of(at(Some(head), "headers")), body: rest }
}

///|
/// One request whose answer is read as it comes (GET /events).
pub async fn GroupLink::stream(self : GroupLink, verb : String, path : String) -> Streamed {
  let (stream, reader, head) = self.opened(verb, path, None, jo([]))
  let cancelled = Ref(false)
  let ended = Ref(false)
  {
    status: num_of(at(Some(head), "status")).unwrap_or(0.0).to_int(),
    headers: headers_of(at(Some(head), "headers")),
    next: async fn() {
      if cancelled.val || ended.val {
        return None
      }
      let got = reader.chunk() catch {
        // (cut: the link went, or it was let go)
        _ => None
      }
      if got is None || cancelled.val {
        ended.val = true
        return None
      }
      got
    },
    cancel: () => {
      if cancelled.val {
        return
      }
      cancelled.val = true
      spawn(async fn() { (stream.reset)(0) })
    },
  }
}

///|
/// The connection let go (the endpoint kept for the next).
pub fn GroupLink::drop(self : GroupLink, reason : String) -> Unit {
  let conn = self.conn
  self.conn = None
  self.control = None
  match conn {
    Some(c) if !(c.is_closed)() => (c.close)(0, reason)
    _ => ()
  }
}

///|
pub async fn GroupLink::close(self : GroupLink) -> Unit {
  self.closed = true
  self.drop("connect stopped")
  let endpoint = self.endpoint
  self.endpoint = None
  match endpoint {
    Some(d) => {
      let e = d.wait() catch { _ => return }
      (e.close)() catch { _ => () }
    }
    None => ()
  }
}

///|
/// The events of a stream's text (text/event-stream, as monoid's event log writes them): each `(event, data, id)`, an
/// id alone as `("", "", id)`.
pub struct SseLines {
  priv mut carry : String
  /// The bytes of a character cut between two pieces, kept for the next (TextDecoder's `stream: true`).
  priv mut partial : Bytes
}

///|
pub fn SseLines::new() -> SseLines {
  { carry: "", partial: b"" }
}

///|
/// How many bytes at the end of `b` begin a character the bytes after them are still to finish.
fn utf8_unfinished(b : Bytes) -> Int {
  let n = b.length()
  let mut back = 1
  while back <= 3 && back <= n {
    let x = b[n - back].to_int()
    if (x & 0xC0) == 0x80 {
      back += 1
      continue
    }
    let need = if (x & 0xE0) == 0xC0 {
      2
    } else if (x & 0xF0) == 0xE0 {
      3
    } else if (x & 0xF8) == 0xF0 {
      4
    } else {
      1
    }
    return if need > back { back } else { 0 }
  }
  0
}

///|
pub fn SseLines::feed(self : SseLines, chunk : Bytes) -> Array[(String, String, String?)] {
  let joined = Buffer()
  joined.write_bytes(self.partial)
  joined.write_bytes(chunk)
  let all = joined.to_bytes()
  let keep = utf8_unfinished(all)
  self.partial = all[all.length() - keep:].to_owned()
  self.carry = self.carry + text_of(all[0:all.length() - keep])
  let out : Array[(String, String, String?)] = []
  while true {
    let end = @session_chats.index_of(self.carry, "\n\n")
    if end < 0 {
      break
    }
    let block = @session_chats.slice(self.carry, 0, b=end)
    self.carry = @session_chats.slice(self.carry, end + 2)
    let mut event = ""
    let data : Array[String] = []
    let mut id : String? = None
    for line in @session_chats.split(block, "\n") {
      if line.has_prefix(":") {
        continue
      }
      let at_ = @session_chats.index_of(line, ":")
      let (field, value) = if at_ < 0 {
        (line, "")
      } else {
        let v = @session_chats.slice(line, at_ + 1)
        (@session_chats.slice(line, 0, b=at_), if v.has_prefix(" ") { @session_chats.slice(v, 1) } else { v })
      }
      match field {
        "event" => event = value
        "data" => data.push(value)
        "id" => id = Some(value)
        _ => ()
      }
    }
    if event == "" && data.length() > 0 {
      event = "message"
    }
    if event != "" || id is Some(_) {
      out.push((event, data.join("\n"), id))
    }
  }
  out
}
