// A web service on this machine, reached through the admin API (station/src/jobs/preview.ts): GET
// /admin/api/preview/<port>/<path> is <path> of http://localhost:<port>, passed through as it is, over a TCP
// connection of the shell's to 127.0.0.1 (`tcp.open`): HTTP/1.1 written and read here. A preview's WebSocket goes over
// a mesh `socket` stream, its messages framed (a kind byte, the payload's length in 4 bytes big-endian, the payload);
// the service's socket is opened here (the handshake and its frames, RFC 6455) and pumped.

///|
let lang_header : String = "stillfail-lang"

///|
let hop_headers : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te",
  "trailer", "host", "authorization", "traceparent", "tracestate", lang_header,
]

///|
let framing_headers : Array[String] = [
  "x-frame-options", "content-security-policy", "content-security-policy-report-only",
]

///|
/// The words a refusal is said in (client/i18n/catalog's station.preview.*), in `lang` ("zh", else English).
pub fn preview_words(lang : String, key : String, params : Array[(String, String)]) -> String {
  let zh = lang == "zh"
  let template = match key {
    "badAddress" => if zh { "地址无效：{error}" } else { "Bad address: {error}" }
    "badMethod" => if zh { "无法识别的请求方法 {method}" } else { "Unknown request method {method}" }
    "noAnswer" =>
      if zh {
        "本机的 localhost:{port} 无响应"
      } else {
        "localhost:{port} on this machine isn't responding"
      }
    "noAnswerSaying" =>
      if zh {
        "本机的 localhost:{port} 无响应：{error}"
      } else {
        "localhost:{port} on this machine isn't responding: {error}"
      }
    "socketRefused" =>
      if zh {
        "localhost:{port} 拒绝了此 WebSocket（{status}）"
      } else {
        "localhost:{port} rejected this WebSocket ({status})"
      }
    _ => key
  }
  let mut out = template
  for p in params {
    out = join(split(out, "{" + p.0 + "}"), p.1)
  }
  out
}

///|
/// An HTTP method as a token.
fn http_token(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    let ok = is_alpha_unit(c) ||
      is_digit(c) ||
      "!#$%&'*+-.^_`|~".find(String::from_array([Int::unsafe_to_char(c)])) is Some(_)
    if !ok || c >= 0x80 {
      return false
    }
  }
  true
}

///|
/// The port and path a /preview/<port>/<path> request is for.
pub fn preview_target(path : String) -> (Int, String)? {
  if !starts(path, "/preview/") {
    return None
  }
  let rest = from(path, 9)
  let at = index_of(rest, "/")
  let (port, target) = if at >= 0 { (slice(rest, 0, at), from(rest, at)) } else { (rest, "/") }
  if port == "" || port.length() > 5 || !all_digits(port) {
    return None
  }
  let n = digits_number(port).to_int()
  if n >= 1 && n <= 65535 {
    Some((n, target))
  } else {
    None
  }
}

///|
/// What goes back to the client: the service's status, its headers (by lowercase name, repeats kept), and its body a
/// chunk at a time (None at its end).
pub(all) struct PreviewAnswer {
  status : Int
  headers : Array[(String, String)]
  next : async () -> Bytes?
}

///|
fn plain_answer(status : Int, words : String) -> PreviewAnswer {
  let sent = Ref(false)
  {
    status,
    headers: [("content-type", "text/plain; charset=utf-8")],
    next: async fn() {
      if sent.val {
        None
      } else {
        sent.val = true
        Some(@utf8.encode(words))
      }
    },
  }
}

///|
/// A TCP connection of the shell's to this machine's `port`, read with what came before kept.
priv struct Conn {
  host : @host.Host
  socket : @net.Socket
  mut carry : Bytes
  mut ended : Bool
}

///|
async fn Conn::open(host : @host.Host, port : Int) -> Conn raise {
  { host, socket: host.tcp_open(port).socket, carry: b"", ended: false }
}

///|
async fn Conn::write(self : Conn, bytes : Bytes) -> Unit raise {
  self.socket.write(bytes)
}

///|
/// More bytes, false at its end.
async fn Conn::fill(self : Conn) -> Bool raise {
  if self.ended {
    return false
  }
  match self.socket.read() {
    None => {
      self.ended = true
      false
    }
    Some(b) => {
      self.carry = concat(self.carry, b)
      true
    }
  }
}

///|
async fn Conn::close(self : Conn) -> Unit {
  self.socket.destroy()
}

///|
fn concat(a : Bytes, b : Bytes) -> Bytes {
  if a.length() == 0 {
    return b
  }
  let buf = @buffer.new(size_hint=a.length() + b.length())
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
fn bytes_from(b : Bytes, i : Int) -> Bytes {
  b[i:].to_bytes()
}

///|
/// Where "\r\n\r\n" is in `b`.
fn head_end(b : Bytes) -> Int {
  for i in 0..<(b.length() - 3) {
    if b[i] == b'\r' && b[i + 1] == b'\n' && b[i + 2] == b'\r' && b[i + 3] == b'\n' {
      return i
    }
  }
  -1
}

///|
/// A response's head read: its status and raw headers (as sent, case kept), the rest of what came kept.
async fn Conn::head(self : Conn) -> (Int, Array[(String, String)]) raise {
  while head_end(self.carry) < 0 {
    if !self.fill() {
      raise HostError("socket hang up")
    }
    if self.carry.length() > 1 << 20 {
      raise HostError("Header overflow")
    }
  }
  let end = head_end(self.carry)
  let text = @utf8.decode_lossy(self.carry[0:end].to_bytes())
  self.carry = bytes_from(self.carry, end + 4)
  let lines = split(text, "\r\n")
  let first = lines[0]
  // HTTP/1.1 200 OK
  let parts = split(first, " ")
  if parts.length() < 2 || !starts(parts[0], "HTTP/") || !all_digits(parts[1]) {
    raise HostError("Parse Error: Invalid response status")
  }
  let status = digits_number(parts[1]).to_int()
  let headers = []
  for line in lines[1:] {
    let i = index_of(line, ":")
    if i <= 0 {
      continue
    }
    headers.push((slice(line, 0, i), trim(from(line, i + 1))))
  }
  (status, headers)
}

///|
/// A response's body a chunk at a time, as Node's response stream gives it: by its length, its chunks, or to the end.
fn Conn::body(self : Conn, method : String, status : Int, headers : Array[(String, String)]) -> async () -> Bytes? {
  let get = (name : String) => match headers.search_by(h => lower_ascii(h.0) == name) {
    Some(k) => Some(headers[k].1)
    None => None
  }
  let none = method == "HEAD" || status == 204 || status == 304 || (status >= 100 && status < 200)
  let chunked = match get("transfer-encoding") {
    Some(t) => index_ci(t, "chunked") >= 0
    None => false
  }
  let left : Ref[Double] = Ref(
    match get("content-length") {
      Some(n) if all_digits(trim(n)) => digits_number(trim(n))
      _ => -1.0
    },
  )
  let done = Ref(none)
  // chunked: the bytes of the chunk under way left (0: its size next)
  let in_chunk : Ref[Int] = Ref(0)
  async fn() {
    if done.val {
      self.close()
      return None
    }
    if chunked {
      while true {
        if in_chunk.val > 0 {
          if self.carry.length() == 0 && !self.fill() {
            done.val = true
            raise HostError("aborted")
          }
          let n = if self.carry.length() < in_chunk.val { self.carry.length() } else { in_chunk.val }
          let out = self.carry[0:n].to_bytes()
          self.carry = bytes_from(self.carry, n)
          in_chunk.val -= n
          if in_chunk.val == 0 {
            // its CRLF
            while self.carry.length() < 2 {
              if !self.fill() {
                break
              }
            }
            self.carry = bytes_from(self.carry, if self.carry.length() >= 2 { 2 } else { self.carry.length() })
          }
          return Some(out)
        }
        // a size line
        let mut line_end = -1
        while true {
          for i in 0..<(self.carry.length() - 1) {
            if self.carry[i] == b'\r' && self.carry[i + 1] == b'\n' {
              line_end = i
              break
            }
          }
          if line_end >= 0 || !self.fill() {
            break
          }
        }
        if line_end < 0 {
          done.val = true
          raise HostError("aborted")
        }
        let line = @utf8.decode_lossy(self.carry[0:line_end].to_bytes())
        self.carry = bytes_from(self.carry, line_end + 2)
        let size_text = trim(split(line, ";")[0])
        let mut size = 0
        for i in 0..<size_text.length() {
          size = size * 16 + hex_unit(size_text.unsafe_charcode_at(i)).unwrap_or(0)
        }
        if size == 0 {
          done.val = true
          self.close()
          return None
        }
        in_chunk.val = size
      }
      None
    } else {
      if left.val == 0.0 {
        done.val = true
        self.close()
        return None
      }
      if self.carry.length() == 0 && !self.fill() {
        done.val = true
        self.close()
        if left.val > 0.0 {
          raise HostError("aborted")
        }
        return None
      }
      let n = if left.val >= 0.0 && left.val < self.carry.length().to_double() {
        left.val.to_int()
      } else {
        self.carry.length()
      }
      let out = self.carry[0:n].to_bytes()
      self.carry = bytes_from(self.carry, n)
      if left.val >= 0.0 {
        left.val -= n.to_double()
      }
      Some(out)
    }
  }
}

///|
/// Who a request comes from: a preview's page (its authorization the admin call's, its answer shown framed and read
/// plain), or a program on another station of the workspace (its own authorization and encodings go to the service).
pub(all) enum Asker {
  Preview
  Peer
} derive(Eq, Show)

///|
/// Methods whose request Node sends with no length said when it has no body.
fn bodiless_method(m : String) -> Bool {
  m == "GET" || m == "HEAD" || m == "DELETE" || m == "OPTIONS" || m == "TRACE" || m == "CONNECT"
}

///|
/// Passes a request to localhost:`port` and its answer back (preview.ts `proxyPreview`). `headers` are the request's,
/// by lowercase name; `lang` is what its refusals are said in. Redirects are not followed (they go back as they are,
/// a redirect to the service itself kept on the preview's path).
pub async fn proxy_preview(
  host : @host.Host,
  http_method : String,
  headers : Array[(String, String)],
  body : Bytes?,
  port : Int,
  path : String,
  lang : String,
  asker? : Asker = Preview,
) -> PreviewAnswer {
  if !http_token(http_method) {
    return plain_answer(400, preview_words(lang, "badMethod", [("method", http_method)]))
  }
  let peer = asker == Peer
  // (by name, in the order first said; repeats kept)
  let names : Array[String] = []
  let values : Map[String, Array[String]] = Map([])
  for h in headers {
    let (name, value) = h
    let skip = if peer {
      hop_headers.contains(name) && name != "authorization"
    } else {
      hop_headers.contains(name) || name == "accept-encoding"
    }
    if skip || starts(name, "x-stillfail-") {
      continue
    }
    match values.get(name) {
      Some(vs) => vs.push(value)
      None => {
        names.push(name)
        values[name] = [value]
      }
    }
  }
  let set = (name : String, value : String) => {
    if !values.contains(name) {
      names.push(name)
    }
    values[name] = [value]
  }
  set("host", "localhost:\{port}")
  if !peer {
    set("accept-encoding", "identity")
  }
  match body {
    Some(b) if !values.contains("content-length") && !values.contains("transfer-encoding") =>
      set("content-length", b.length().to_string())
    None if !bodiless_method(http_method) &&
      !values.contains("content-length") &&
      !values.contains("transfer-encoding") => set("content-length", "0")
    _ => ()
  }
  let out = StringBuilder::new()
  out.write_string("\{http_method} \{path} HTTP/1.1\r\n")
  for name in names {
    for v in values[name] {
      out.write_string("\{name}: \{v}\r\n")
    }
  }
  out.write_string("Connection: close\r\n\r\n")
  let services = ["http", "https"].map(s => [
      "\{s}://localhost:\{port}",
      "\{s}://127.0.0.1:\{port}",
      "\{s}://[::1]:\{port}",
    ]).fold(init=[], (a, b) => a + b)
  let conn = Conn::open(host, port) catch {
    e =>
      return plain_answer(
        502,
        preview_words(lang, "noAnswerSaying", [("port", port.to_string()), ("error", words_of(e))]),
      )
  }
  let answered = try {
    conn.write(concat(@utf8.encode(out.to_string()), body.unwrap_or(b"")))
    conn.head()
  } catch {
    e => {
      conn.close()
      return plain_answer(
        502,
        preview_words(lang, "noAnswerSaying", [("port", port.to_string()), ("error", words_of(e))]),
      )
    }
  }
  let (status, raw) = answered
  let back = []
  for h in raw {
    let name = @jscase.lower(h.0)
    let mut value = h.1
    if hop_headers.contains(name) || (!peer && framing_headers.contains(name)) {
      continue
    }
    if name == "location" {
      match
        services.search_by(o => starts(value, o) &&
          {
            let rest = from(value, o.length())
            rest == "" || starts(rest, "/") || starts(rest, "?") || starts(rest, "#")
          }) {
        Some(k) => {
          value = from(value, services[k].length())
          if !starts(value, "/") {
            value = "/" + value
          }
        }
        None => ()
      }
    }
    back.push((name, value))
  }
  { status, headers: back, next: conn.body(http_method, status, raw) }
}

// ── a service's WebSocket ──

///|
pub let frame_text : Int = 1

///|
pub let frame_binary : Int = 2

///|
pub let frame_close : Int = 8

///|
let max_frame : Int = 16 * 1024 * 1024

///|
let open_within_ms : Int = 20_000

///|
let close_answer_ms : Int = 5000

///|
let socket_headers : Array[String] = ["sec-websocket-protocol", "cookie", "user-agent"]

///|
/// One frame on a preview's socket stream.
pub fn frame(kind : Int, payload : Bytes) -> Bytes {
  let buf = @buffer.new(size_hint=5 + payload.length())
  buf.write_byte(kind.to_byte())
  let n = payload.length()
  buf.write_byte((n >> 24).to_byte())
  buf.write_byte(((n >> 16) & 0xff).to_byte())
  buf.write_byte(((n >> 8) & 0xff).to_byte())
  buf.write_byte((n & 0xff).to_byte())
  buf.write_bytes(payload)
  buf.to_bytes()
}

///|
/// Frames from a byte stream (preview.ts `FrameReader`): `read` gives chunks until None (its end).
pub struct FrameReader {
  priv read : async () -> Bytes?
  priv mut carry : Bytes
}

///|
pub fn FrameReader::new(read : async () -> Bytes?, carry? : Bytes = b"") -> FrameReader {
  { read, carry }
}

///|
async fn FrameReader::fill(self : FrameReader, n : Int) -> Bool {
  while self.carry.length() < n {
    guard (self.read)() is Some(more) else { return false }
    self.carry = concat(self.carry, more)
  }
  true
}

///|
/// The next frame; None when the stream ended between frames (an end inside one is an error).
pub async fn FrameReader::next(self : FrameReader) -> (Int, Bytes)? raise {
  if !self.fill(1) {
    return None
  }
  if !self.fill(5) {
    raise HostError("the stream ended inside a frame")
  }
  let c = self.carry
  let length = (c[1].to_int() << 24) | (c[2].to_int() << 16) | (c[3].to_int() << 8) | c[4].to_int()
  if length > max_frame || length < 0 {
    raise HostError("frame too long")
  }
  if !self.fill(5 + length) {
    raise HostError("the stream ended inside a frame")
  }
  let kind = self.carry[0].to_int()
  let payload = self.carry[5:5 + length].to_bytes()
  self.carry = bytes_from(self.carry, 5 + length)
  Some((kind, payload))
}

///|
/// A message a service's socket said: its text or bytes, or its close (code, reason).
pub(all) enum Message {
  Text(Bytes)
  Binary(Bytes)
  Close(Int, Bytes)
} derive(Eq, Show)

///|
/// Why a socket was not opened: the status to answer, and the words.
pub(all) suberror SocketRefused {
  SocketRefused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for SocketRefused with output(self, logger) {
  match self {
    SocketRefused(_, m) => logger.write_string(m)
  }
}

///|
/// A service's socket, open (preview.ts `ServiceSocket`): what it says read from the moment it opened.
pub struct ServiceSocket {
  priv conn : Conn
  /// The sub-protocol the service chose.
  protocol : String?
  priv mut closed : Bool
  priv mut sent_close : Bool
  priv mut told_close : Bool
  priv mut message : Bytes
  priv mut message_kind : Int
}

///|
fn ServiceSocket::is_open(self : ServiceSocket) -> Bool {
  !self.closed && !self.sent_close
}

///|
/// A frame to the service, masked as a client's are.
async fn ServiceSocket::send_frame(self : ServiceSocket, opcode : Int, payload : Bytes) -> Unit raise {
  let mask = @hex.decode(random_hex(self.conn.host, 4)) catch { _ => b"\x01\x02\x03\x04" }
  let buf = @buffer.new(size_hint=payload.length() + 14)
  buf.write_byte((0x80 | opcode).to_byte())
  let n = payload.length()
  if n < 126 {
    buf.write_byte((0x80 | n).to_byte())
  } else if n < 65536 {
    buf.write_byte((0x80 | 126).to_byte())
    buf.write_byte((n >> 8).to_byte())
    buf.write_byte((n & 0xff).to_byte())
  } else {
    buf.write_byte((0x80 | 127).to_byte())
    for i in 0..<4 {
      buf.write_byte(b'\x00')
      ignore(i)
    }
    buf.write_byte((n >> 24).to_byte())
    buf.write_byte(((n >> 16) & 0xff).to_byte())
    buf.write_byte(((n >> 8) & 0xff).to_byte())
    buf.write_byte((n & 0xff).to_byte())
  }
  buf.write_bytes(mask)
  for i in 0..<n {
    buf.write_byte(payload[i] ^ mask[i % 4])
  }
  self.conn.write(buf.to_bytes())
}

///|
/// Whether a close code may be sent (ws's `isValidStatusCode`).
fn sendable_code(code : Int) -> Bool {
  (code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006) ||
  (code >= 3000 && code <= 4999)
}

///|
/// Its close sent (ws's `close(code, reason)`; a code it may not send: closed without one).
pub async fn ServiceSocket::close(self : ServiceSocket, code : Int, reason : String) -> Unit {
  if self.sent_close || self.closed {
    return
  }
  self.sent_close = true
  let r = @utf8.encode(reason)
  let payload = if sendable_code(code) && r.length() <= 123 {
    let buf = @buffer.new()
    buf.write_byte((code >> 8).to_byte())
    buf.write_byte((code & 0xff).to_byte())
    buf.write_bytes(r)
    buf.to_bytes()
  } else {
    b""
  }
  self.send_frame(0x8, payload) catch {
    _ => ()
  }
}

///|
/// A text or bytes to the service; false where it did not go.
pub async fn ServiceSocket::send(self : ServiceSocket, binary : Bool, payload : Bytes) -> Bool {
  if !self.is_open() {
    return false
  }
  self.send_frame(if binary { 2 } else { 1 }, payload) catch {
    _ => return false
  }
  true
}

///|
/// The connection ended at once.
pub async fn ServiceSocket::terminate(self : ServiceSocket) -> Unit {
  self.closed = true
  self.conn.close()
}

///|
/// What it says next; its close last (1005 when it gave no code, 1006 when it went without a close).
pub async fn ServiceSocket::next(self : ServiceSocket) -> Message {
  if self.told_close {
    return Close(1006, b"")
  }
  while true {
    let c = self.conn
    let have = async fn(n : Int) -> Bool {
      while c.carry.length() < n {
        let more = c.fill() catch { _ => false }
        if !more {
          return false
        }
      }
      true
    }
    if !have(2) {
      self.told_close = true
      self.closed = true
      return Close(1006, b"")
    }
    let b0 = c.carry[0].to_int()
    let b1 = c.carry[1].to_int()
    let fin = (b0 & 0x80) != 0
    let opcode = b0 & 0x0f
    let masked = (b1 & 0x80) != 0
    let mut len = (b1 & 0x7f).to_int64()
    let mut at = 2
    if len == 126L {
      if !have(4) {
        self.told_close = true
        return Close(1006, b"")
      }
      len = ((c.carry[2].to_int() << 8) | c.carry[3].to_int()).to_int64()
      at = 4
    } else if len == 127L {
      if !have(10) {
        self.told_close = true
        return Close(1006, b"")
      }
      len = 0L
      for i in 2..<10 {
        len = (len << 8) | c.carry[i].to_int64()
      }
      at = 10
    }
    let mask_at = at
    if masked {
      at += 4
    }
    let n = len.to_int()
    if !have(at + n) {
      self.told_close = true
      self.closed = true
      return Close(1006, b"")
    }
    let payload = FixedArray::make(n, b'\x00')
    for i in 0..<n {
      let v = c.carry[at + i]
      payload[i] = if masked { v ^ c.carry[mask_at + i % 4] } else { v }
    }
    c.carry = bytes_from(c.carry, at + n)
    let data = Bytes::from_array(payload)
    match opcode {
      0x0 => {
        self.message = concat(self.message, data)
        if fin {
          let m = self.message
          self.message = b""
          return if self.message_kind == 1 { Text(m) } else { Binary(m) }
        }
      }
      0x1 | 0x2 =>
        if fin {
          return if opcode == 1 { Text(data) } else { Binary(data) }
        } else {
          self.message_kind = opcode
          self.message = data
        }
      0x8 => {
        let code = if n >= 2 { (data[0].to_int() << 8) | data[1].to_int() } else { 1005 }
        let reason = if n > 2 { data[2:].to_bytes() } else { b"" }
        // (its close answered with its code, as ws does, then the connection ended)
        if !self.sent_close {
          self.sent_close = true
          self.send_frame(0x8, if n >= 2 { data[0:2].to_bytes() } else { b"" }) catch {
            _ => ()
          }
        }
        self.told_close = true
        self.closed = true
        self.conn.close()
        return Close(code, reason)
      }
      0x9 => self.send_frame(0xA, data) catch { _ => () }
      _ => ()
    }
  }
  Close(1006, b"")
}

///|
/// Opens `path` of ws://localhost:`port` for a preview's page, with its headers (by lowercase name), as a page of the
/// service itself would (its origin). The socket, or a SocketRefused: the service's own refusal, 502 when it does not
/// answer.
pub async fn open_socket(
  host : @host.Host,
  headers : Array[(String, String)],
  port : Int,
  path : String,
  lang : String,
  asker? : Asker = Preview,
) -> ServiceSocket raise SocketRefused {
  let passed = []
  let mut protocols : Array[String] = []
  for h in headers {
    let (name, value) = h
    if !socket_headers.contains(name) && !(asker == Peer && name == "authorization") {
      continue
    }
    if name == "sec-websocket-protocol" {
      protocols = split(value, ",").map(trim).filter(p => p != "")
    } else {
      passed.push((name, value))
    }
  }
  if !starts(path, "/") {
    raise SocketRefused(400, preview_words(lang, "badAddress", [("error", "Invalid URL")]))
  }
  let opened = @effect.timeout(open_within_ms, async fn() -> Result[ServiceSocket, SocketRefused] {
    let conn = Conn::open(host, port) catch {
      e =>
        return Err(
          SocketRefused(
            502,
            preview_words(lang, "noAnswerSaying", [("port", port.to_string()), ("error", words_of(e))]),
          ),
        )
    }
    let key = @base64.encode(@hex.decode(random_hex(host, 16)) catch { _ => b"0123456789abcdef" })
    let out = StringBuilder::new()
    out.write_string("GET \{path} HTTP/1.1\r\n")
    out.write_string("Sec-WebSocket-Version: 13\r\n")
    out.write_string("Sec-WebSocket-Key: \{key}\r\n")
    out.write_string("Connection: Upgrade\r\n")
    out.write_string("Upgrade: websocket\r\n")
    for p in passed {
      out.write_string("\{p.0}: \{p.1}\r\n")
    }
    if protocols.length() > 0 {
      out.write_string("Sec-WebSocket-Protocol: \{join(protocols, ",")}\r\n")
    }
    out.write_string("Host: localhost:\{port}\r\n")
    out.write_string("Origin: http://localhost:\{port}\r\n\r\n")
    let head = try {
      conn.write(@utf8.encode(out.to_string()))
      conn.head()
    } catch {
      e => {
        conn.close()
        return Err(
          SocketRefused(
            502,
            preview_words(lang, "noAnswerSaying", [("port", port.to_string()), ("error", words_of(e))]),
          ),
        )
      }
    }
    let (status, raw) = head
    if status != 101 {
      conn.close()
      return Err(
        SocketRefused(
          if status < 400 { 502 } else { status },
          preview_words(lang, "socketRefused", [("port", port.to_string()), ("status", status.to_string())]),
        ),
      )
    }
    let get = (name : String) => match raw.search_by(h => lower_ascii(h.0) == name) {
      Some(k) => Some(raw[k].1)
      None => None
    }
    let expected = @base64.encode(sha1(@utf8.encode(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
    let failure = if get("sec-websocket-accept") != Some(expected) {
      Some("Invalid Sec-WebSocket-Accept header")
    } else {
      match get("sec-websocket-protocol") {
        Some(p) if !protocols.contains(p) => Some("Server sent an invalid subprotocol")
        None if protocols.length() > 0 => Some("Server sent no subprotocol")
        _ => None
      }
    }
    match failure {
      Some(f) => {
        conn.close()
        Err(
          SocketRefused(
            502,
            preview_words(lang, "noAnswerSaying", [("port", port.to_string()), ("error", f)]),
          ),
        )
      }
      None =>
        Ok({
          conn,
          protocol: get("sec-websocket-protocol"),
          closed: false,
          sent_close: false,
          told_close: false,
          message: b"",
          message_kind: 1,
        })
    }
  }) catch {
    _ => None
  }
  match opened {
    Some(Ok(s)) => s
    Some(Err(e)) => raise e
    None => raise SocketRefused(502, preview_words(lang, "noAnswer", [("port", port.to_string())]))
  }
}

///|
/// Where frames to the client go.
pub(all) struct ByteSink {
  write : async (Bytes) -> Unit
  finish : async () -> Unit
}

///|
/// Passes messages between the service's socket and the client's stream until either closes (preview.ts
/// `pumpSocket`); a close on one is passed on to the other. The service's side ending ends both; the client's ending
/// leaves the service a moment to answer its close, which goes back as it would.
pub async fn pump_socket(
  rt : @effect.Runtime,
  socket : ServiceSocket,
  from_client : FrameReader,
  to_client : ByteSink,
) -> Unit {
  let over = Ref(false)
  let up_done : @effect.Deferred[Unit] = @effect.Deferred::new()
  let down_done : @effect.Deferred[Unit] = @effect.Deferred::new()
  let up = rt.fork(async fn() {
    defer ignore(up_done.succeed(()))
    while true {
      let got = from_client.next() catch { _ => None }
      if over.val {
        return
      }
      guard got is Some((kind, payload)) else {
        socket.close(1001, "")
        return
      }
      if kind == frame_close {
        let code = if payload.length() >= 2 {
          (payload[0].to_int() << 8) | payload[1].to_int()
        } else {
          1000
        }
        let reason = if payload.length() > 2 {
          @utf8.decode_lossy(payload[2:].to_bytes())
        } else {
          ""
        }
        socket.close(code, reason)
        return
      }
      if kind != frame_text && kind != frame_binary {
        continue
      }
      if !socket.is_open() {
        return
      }
      if !socket.send(kind == frame_binary, payload) {
        return
      }
    }
  })
  let down = rt.fork(async fn() {
    defer ignore(down_done.succeed(()))
    while true {
      let m = socket.next()
      match m {
        Close(code, reason) => {
          let buf = @buffer.new()
          buf.write_byte((code >> 8).to_byte())
          buf.write_byte((code & 0xff).to_byte())
          buf.write_bytes(reason)
          (to_client.write)(frame(frame_close, buf.to_bytes())) catch {
            _ => ()
          }
          break
        }
        Text(d) => (to_client.write)(frame(frame_text, d)) catch { _ => return }
        Binary(d) => (to_client.write)(frame(frame_binary, d)) catch { _ => return }
      }
    }
    (to_client.finish)() catch {
      _ => ()
    }
  })
  let first = @effect.race(
    async fn() {
      up_done.wait()
      "up"
    },
    async fn() {
      down_done.wait()
      "down"
    },
  ) catch {
    _ => "down"
  }
  if first == "up" {
    ignore(@effect.timeout(close_answer_ms, async fn() { down_done.wait() }) catch { _ => None })
  }
  over.val = true
  if !socket.closed {
    socket.terminate()
  }
  up.interrupt()
  down.interrupt()
}
