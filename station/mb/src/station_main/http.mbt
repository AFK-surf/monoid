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
  let mut want = -1
  while true {
    // (the head looked for only while it has not ended: a few KB, not the body as it grows)
    if head_end is None {
      let all = got.to_bytes()
      head_end = find_head_end(all)
      if head_end is Some(e) {
        let head = @utf8.decode_lossy(all[0:e])
        want = e + 4
        for line in head.split("\r\n") {
          let l = line.to_owned()
          match l.find(":") {
            Some(c) if l[:c].to_owned().to_lower() == "content-length" =>
              want = e + 4 + (@string.parse_int(l[c + 1:].to_owned().trim().to_owned()) catch { _ => 0 })
            _ => ()
          }
        }
      }
    }
    if head_end is Some(_) && got_len >= want {
      break
    }
    if got_len > request_most || want > request_most {
      return None
    }
    let (said, bytes) = host.shell("tcp.read", { "id": id }) catch { _ => return None }
    if said is { "end": True, .. } {
      return None
    }
    match bytes {
      Some(b) => {
        got.write_bytes(b)
        got_len += b.length()
      }
      None => return None
    }
  }
  let all = got.to_bytes()
  guard head_end is Some(e) else { None }
  let head = @utf8.decode_lossy(all[0:e])
  let lines = head.split("\r\n").map(l => l.to_owned()).to_array()
  guard lines.length() > 0 else { None }
  let first = lines[0].split(" ").map(p => p.to_owned()).to_array()
  guard first.length() >= 2 else { None }
  let headers = []
  for k = 1; k < lines.length(); k = k + 1 {
    let l = lines[k]
    match l.find(":") {
      Some(c) => headers.push((l[:c].to_owned().to_lower().trim().to_owned(), l[c + 1:].to_owned().trim().to_owned()))
      None => ()
    }
  }
  let body = all[e + 4:want].to_owned()
  Some({ meth: first[0], target: first[1], headers, body })
}

///|
/// The reply written on connection `id`, and the connection closed.
async fn write_reply(host : @host.Host, id : Json, reply : Reply) -> Unit {
  let out = StringBuilder()
  out.write_string("HTTP/1.1 \{reply.status} \{reason(reply.status)}\r\n")
  for h in reply.headers {
    out.write_string("\{h.0}: \{h.1}\r\n")
  }
  out.write_string("content-length: \{reply.body.length()}\r\nconnection: close\r\n\r\n")
  let head = @utf8.encode(out.to_string())
  let all = @buffer.Buffer()
  all.write_bytes(head)
  all.write_bytes(reply.body)
  ignore(host.shell("tcp.write", { "id": id }, bytes=all.to_bytes())) catch {
    _ => ()
  }
  ignore(host.shell("tcp.end", { "id": id })) catch {
    _ => ()
  }
  ignore(host.shell("tcp.close", { "id": id })) catch {
    _ => ()
  }
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
  while @mesh_runtime.accept_through(async fn() { host.shell("tcp.accept", { "id": listening }).0 }) is Some(accepted) {
    match accepted {
      { "id": id, .. } =>
        ignore(
          host.rt.fork(name="http request", async fn() {
            match read_request(host, id) {
              Some(r) =>
                match (try { handle(r, id) } catch { e => Some(plain(500, "\{e}")) }) {
                  Some(reply) => write_reply(host, id, reply)
                  None => ()
                }
              None => ignore(host.shell("tcp.close", { "id": id })) catch { _ => () }
            }
          }),
        )
      _ => ()
    }
  }
  // (the listener closed: serving is over)
}

///|
/// Writes `bytes` on connection `id` (a stream's next piece); false once it is gone.
pub async fn write_on(host : @host.Host, id : Json, bytes : Bytes) -> Bool {
  (try { Ok(host.shell("tcp.write", { "id": id }, bytes~)) } catch { e => Err(e) }) is Ok(_)
}
