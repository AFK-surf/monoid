// The framing of a mesh protocol's streams, and nothing of what they carry (station/src/mesh/wire.ts): one JSON line at
// a time off a stream, then the rest of it; a request, a JSON head line then its body until the stream finishes; its
// answer, a JSON head line `{status, headers}` then the body. Who may open a stream and what a request is answered are
// not here (door.mbt is given them).

///|
pub let max_head : Int = 16 * 1024

///|
/// Files sent to a session go through here: in parts of 16 MB at most, or whole up to 50 MB.
pub let max_body : Int = 64 * 1024 * 1024

///|
/// Headers of one hop, not of what is relayed.
pub let hop : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
  "te", "trailer", "host", "content-length",
]

///|
pub(all) suberror WireError {
  WireError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for WireError with output(self, logger) {
  match self {
    WireError(m) => logger.write_string(m)
  }
}

///|
/// A body as it comes (an event stream): the next piece, None at its end; `stop` lets go of it (TS's `return`).
pub(all) struct Chunks {
  next : async () -> Bytes?
  stop : () -> Unit
}

///|
pub(all) enum Body {
  Whole(Bytes)
  Coming(Chunks)
}

///|
/// What a request is answered. Headers in the order said.
pub(all) struct Answer {
  status : Int
  headers : Array[(String, String)]
  body : Body
}

///|
pub fn headers_json(headers : Array[(String, String)]) -> Json {
  let m : Map[String, Json] = Map([])
  for kv in headers {
    m[kv.0] = Json::string(kv.1)
  }
  Json::object(m)
}

///|
/// The first header named `name` (any case).
pub fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for kv in headers {
    if kv.0.to_lower() == name {
      return Some(kv.1)
    }
  }
  None
}

///|
/// One JSON line at a time from a stream, then the rest of it.
pub struct Reader {
  mut carry : Bytes
  mut stream : Stream
  /// How long a line may be.
  max_line : Int
}

///|
pub fn Reader::new(stream : Stream, max_line? : Int = max_head) -> Reader {
  { carry: b"", stream, max_line }
}

///|
fn index_nl(b : BytesView) -> Int? {
  for i in 0..<b.length() {
    if b[i] == b'\n' {
      return Some(i)
    }
  }
  None
}

///|
/// The next line's value; None where the stream ended with nothing more.
pub async fn Reader::line(self : Reader) -> Json? {
  let mut at = index_nl(self.carry[:]).unwrap_or(-1)
  if at < 0 {
    let parts = [self.carry]
    let mut size = self.carry.length()
    while at < 0 {
      if size > self.max_line {
        raise WireError("head too large")
      }
      let more = (self.stream.read)()
      match more {
        None => {
          if size == 0 {
            return None
          }
          raise WireError("stream ended mid-line")
        }
        Some(more) => {
          if index_nl(more[:]) is Some(found) {
            at = size + found
          }
          parts.push(more)
          size += more.length()
        }
      }
    }
    self.carry = concat(parts)
  }
  if at > self.max_line {
    raise WireError("head too large")
  }
  let line = own(self.carry[0:at])
  self.carry = own(self.carry[at + 1:])
  let text = @utf8.decode_lossy(line)
  Some(@json.parse(text))
}

///|
/// The rest, whole (MAX_BODY at most).
pub async fn Reader::rest(self : Reader) -> Bytes {
  let parts = [self.carry]
  let mut size = self.carry.length()
  while (self.stream.read)() is Some(more) {
    parts.push(more)
    size += more.length()
    if size > max_body {
      raise WireError("request body too large")
    }
  }
  self.carry = b""
  concat(parts)
}

///|
/// The rest as it comes, however long.
pub async fn Reader::chunk(self : Reader) -> Bytes? {
  if self.carry.length() > 0 {
    let first = self.carry
    self.carry = b""
    return Some(first)
  }
  (self.stream.read)()
}

///|
pub fn line_bytes(value : Json) -> Bytes {
  @utf8.encode(value.stringify() + "\n")
}

///|
pub async fn write_line(stream : Stream, value : Json) -> Unit {
  (stream.write)(line_bytes(value))
}

///|
/// One request as its stream was taken: its head line, the reader that read it (what came with the line still in its
/// `carry`), the stream, and when the stream was accepted (the clock's ms).
pub(all) struct Asked {
  head : Json
  reader : Reader
  stream : Stream
  accepted : Int64
}

///|
/// One request stream's head read, and `answer` called with it (what answers it starts then, and sees to its own
/// failing). A stream that ends with nothing asked is finished.
pub async fn request(raw : Stream, answer : (Asked) -> Unit) -> Unit {
  let accepted = @effect.now()
  let reader = Reader::new(raw)
  match reader.line() {
    None => (raw.finish)() catch { _ => () }
    Some(head) => answer({ head, reader, stream: raw, accepted })
  }
}

///|
/// An answer onto its stream: its head line, then its body. A body that comes (GET /events) ends when the caller stops
/// reading or goes, and is let go of however the writing ends. A whole body says its length, unless compressed.
pub async fn send(stream : Stream, response : Answer) -> Unit {
  match response.body {
    Whole(body) => {
      let said = response.headers.iter().any(kv => {
        let k = kv.0.to_lower()
        k == "content-length" || k == "content-encoding"
      })
      let headers = if said {
        response.headers
      } else {
        [..response.headers, ("content-length", body.length().to_string())]
      }
      write_line(stream, { "status": Json::number(response.status.to_double()), "headers": headers_json(headers) })
      (stream.write)(body)
    }
    Coming(chunks) => {
      let mut ended = false
      let end = () => if !ended {
        ended = true
        (chunks.stop)()
      }
      let rt = @effect.runtime()
      let watch = rt.fork(name="send stopped", () => {
        ignore((stream.stopped)()) catch {
          _ => ()
        }
        end()
      })
      defer {
        end()
        watch.interrupt()
      }
      write_line(stream, {
        "status": Json::number(response.status.to_double()),
        "headers": headers_json(response.headers),
      })
      while !ended && (chunks.next)() is Some(piece) {
        (stream.write)(piece)
      }
    }
  }
}

///|
/// What it reads from now on is read off `stream` (the same stream counted, traced).
pub fn Reader::set_stream(self : Reader, stream : Stream) -> Unit {
  self.stream = stream
}

///|
/// What came after the line and was not read yet, taken (the reader keeps none of it).
pub fn Reader::take_carry(self : Reader) -> Bytes {
  let c = self.carry
  self.carry = b""
  c
}
