// HTTP/1.1 served on a socket the shell listens on (`tcp.listen` on 127.0.0.1 or a launcher's descriptor, `unix.listen`
// for the status socket): each connection a request, answered and closed (`Connection: close`), each in a fiber of its
// own. What the station's own listeners need, no more: no keep-alive, no chunked request bodies.

///|
/// A request as it came.
pub(all) struct Request {
  meth : String
  /// The target as asked (path and query).
  target : String
  /// Headers by their lower-case names.
  headers : Array[(String, String)]
  body : Bytes
}

///|
pub fn Request::header(self : Request, name : String) -> String? {
  for h in self.headers {
    if h.0 == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// Its path, without the query.
pub fn Request::path(self : Request) -> String {
  match self.target.find("?") {
    Some(i) => self.target[:i].to_owned()
    None => self.target
  }
}

///|
/// Its query (after `?`), none where it has none.
pub fn Request::query(self : Request) -> String? {
  match self.target.find("?") {
    Some(i) => Some(self.target[i + 1:].to_owned())
    None => None
  }
}

///|
/// An answer.
pub(all) struct Reply {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
pub fn plain(status : Int, text : String) -> Reply {
  { status, headers: [("content-type", "text/plain; charset=utf-8")], body: @utf8.encode(text) }
}

///|
pub fn json_reply(status : Int, value : Json) -> Reply {
  { status, headers: [("content-type", "application/json")], body: @utf8.encode(value.stringify()) }
}

///|
fn reason(status : Int) -> String {
  match status {
    200 => "OK"
    202 => "Accepted"
    204 => "No Content"
    302 => "Found"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    413 => "Payload Too Large"
    500 => "Internal Server Error"
    503 => "Service Unavailable"
    _ => "Status"
  }
}

///|
/// The most a request's head and body may be.
let request_most : Int = 8 * 1024 * 1024

///|
/// The most a request's head (request line + headers, before `\r\n\r\n`) may be.
let head_most : Int = 64 * 1024

///|
/// RFC 9110 §5.6.2 token character (tchar).
fn is_http_tchar(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '\'' ||
  c == '*' || c == '+' || c == '-' || c == '.' || c == '^' || c == '_' ||
  c == '`' || c == '|' || c == '~'
}

///|
fn is_http_token(s : StringView) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if !is_http_tchar(c) {
      return false
    }
  }
  true
}

///|
/// Rejects control chars (including NUL, CR, LF) in request-target and header values.
/// Header values allow HTAB (0x09) and visible/obs-text bytes (>= 0x20, != 0x7F).
fn is_valid_header_value(s : StringView) -> Bool {
  for c in s {
    let code = c.to_int()
    if code == 0x09 {
      continue
    }
    if code < 0x20 || code == 0x7F {
      return false
    }
  }
  true
}

///|
fn is_valid_target(s : StringView) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    let code = c.to_int()
    if code <= 0x20 || code == 0x7F {
      return false
    }
  }
  true
}

///|
fn parse_http_head(head_bytes : BytesView) -> (String, String, Array[(String, String)], Int)? {
  let head = @utf8.decode_lossy(head_bytes)
  let lines = head.split("\r\n").map(l => l.to_owned()).to_array()
  guard lines.length() > 0 else { None }
  // Reject bare CR or LF inside any line
  for l in lines {
    for c in l {
      if c == '\r' || c == '\n' {
        return None
      }
    }
  }
  let first = lines[0].split(" ").map(p => p.to_owned()).to_array()
  guard first.length() == 3 else { None }
  guard is_http_token(first[0]) && is_valid_target(first[1]) else { None }
  guard first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { None }
  let headers : Array[(String, String)] = []
  let mut content_length : Int? = None
  for k = 1; k < lines.length(); k = k + 1 {
    let l = lines[k]
    // Reject empty lines, obs-fold (leading SP/HTAB), and header lines without ':'
    if l.length() == 0 {
      return None
    }
    match l.find(":") {
      None => return None
      Some(c) => {
        let raw_name = l[:c]
        // RFC 9112 §5.1: no whitespace between header field-name and colon, and field-name must be a token
        if !is_http_token(raw_name) {
          return None
        }
        let raw_val = l[c + 1:]
        if !is_valid_header_value(raw_val) {
          return None
        }
        let name = raw_name.to_owned().to_lower()
        let val = raw_val.to_owned().trim().to_owned()
        if name == "transfer-encoding" {
          // This server does not accept chunked or transfer-encoded request bodies (also prevents TE+CL smuggling)
          return None
        }
        if name == "content-length" {
          // Reject duplicate Content-Length headers (RFC 9112 §6.3 / Node llhttp)
          if content_length is Some(_) {
            return None
          }
          if val.length() == 0 {
            return None
          }
          for ch in val {
            if ch < '0' || ch > '9' {
              return None
            }
          }
          let cl = @string.parse_int(val) catch { _ => return None }
          if cl < 0 {
            return None
          }
          content_length = Some(cl)
        }
        headers.push((name, val))
      }
    }
  }
  Some((first[0], first[1], headers, content_length.unwrap_or(0)))
}

///|
fn find_head_end(b : Bytes) -> Int? {
  for i = 0; i + 3 < b.length(); i = i + 1 {
    if b[i] == b'\r' && b[i + 1] == b'\n' && b[i + 2] == b'\r' && b[i + 3] == b'\n' {
      return Some(i)
    }
  }
  None
}

///|
/// The request read off connection `id`; None where it ended first or is no request.
async fn read_request(host : @host.Host, id : Json) -> Request? {
  let got = @buffer.Buffer()
  let mut got_len = 0
  let mut head_end : Int? = None
  let mut parsed : (String, String, Array[(String, String)], Int)? = None
  let mut want = -1
  while true {
    // (the head looked for only while it has not ended: a few KB, not the body as it grows)
    if head_end is None {
      let all = got.to_bytes()
      head_end = find_head_end(all)
      match head_end {
        Some(e) => {
          if e > head_most {
            return None
          }
          match parse_http_head(all[0:e]) {
            Some((meth, target, headers, cl)) => {
              if cl > request_most - (e + 4) {
                return None
              }
              parsed = Some((meth, target, headers, cl))
              want = e + 4 + cl
            }
            None => return None
          }
        }
        None =>
          if got_len > head_most {
            return None
          }
      }
    }
    if got_len > request_most || want > request_most {
      return None
    }
    if head_end is Some(_) && got_len >= want {
      break
    }
    match (host.tcp_read(id) catch { _ => return None }) {
      Some(b) => {
        got.write_bytes(b)
        got_len += b.length()
      }
      None => return None
    }
  }
  let all = got.to_bytes()
  guard head_end is Some(e) else { None }
  guard parsed is Some((meth, target, headers, _)) else { None }
  if want < e + 4 || want > all.length() {
    return None
  }
  let body = all[e + 4:want].to_owned()
  Some({ meth, target, headers, body })
}

///|
/// The reply written on connection `id`, and the connection closed.
async fn write_reply(host : @host.Host, id : Json, reply : Reply) -> Unit {
  let out = StringBuilder()
  out.write_string("HTTP/1.1 \{reply.status} \{reason(reply.status)}\r\n")
  for h in reply.headers {
    let name = h.0.to_lower()
    if name != "content-length" && name != "transfer-encoding" && name != "connection" {
      out.write_string("\{h.0}: \{h.1}\r\n")
    }
  }
  out.write_string("content-length: \{reply.body.length()}\r\nconnection: close\r\n\r\n")
  let head = @utf8.encode(out.to_string())
  let all = @buffer.Buffer()
  all.write_bytes(head)
  all.write_bytes(reply.body)
  let socket = host.socket_of(id)
  socket.write(all.to_bytes()) catch {
    _ => ()
  }
  socket.end_write() catch {
    _ => ()
  }
  socket.destroy()
}

///|
/// Serves listener `listening` (a shell id) until it is closed: each connection's request given to `handle`, its answer
/// written. `streamed`: a request whose answer is written by `handle` itself on the connection (None: it answers).
pub async fn serve_http(
  host : @host.Host,
  listening : Json,
  handle : async (Request, Json) -> Reply?,
) -> Unit {
  // (a try that failed with the listener still there, the machine out of descriptors for a while, taken again: one
  // such failure ended serving, the MCP's and the admin API's ports unanswered until the station was started again)
  host
  .listener_of(listening)
  .serve(host.rt.root(), async fn(conn) {
    let id = conn.id
    match read_request(host, id) {
      Some(r) =>
        match (try { handle(r, id) } catch { e => Some(plain(500, "\{e}")) }) {
          Some(reply) => write_reply(host, id, reply)
          None => ()
        }
      None => conn.socket.destroy()
    }
  })
  // (the listener closed: serving is over)
}

///|
/// Writes `bytes` on connection `id` (a stream's next piece); false once it is gone.
pub async fn write_on(host : @host.Host, id : Json, bytes : Bytes) -> Bool {
  (try { Ok(host.tcp_write(id, bytes)) } catch { e => Err(e) }) is Ok(_)
}
