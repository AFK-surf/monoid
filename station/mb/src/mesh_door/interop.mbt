// The interop admission and client (station/test/mb-mesh-door.test.ts has their TypeScript twins, word for word): what
// is carried between the two meshes, the same transcript whichever side is which.
//
// Admission: hello `credential` "good" let in (`{ok, expires_at: 99}`), anything else refused (`{error: "refused"}`,
// code 1, reason "credential_refused"). A renewal "good" answered `{ok, renewed}`, "end" ends the connection (an
// `Ending`: "revoked", 3, "credential_revoked"), anything else answered `{error: "bad renewal"}`. A request: `/echo` its
// body back, `/json?n=` n items of JSON, `/events?n=` n events as they come, each compressed where asked.

///|
pub fn interop_admit(packer : @door.Packer) -> @door.Admit {
  (hello, _conn) => if hello is { "credential": "good", .. } {
    Let({
      line: { "ok": true, "expires_at": 99 },
      opened: () => (),
      renew: line => match line {
        { "credential": "good", .. } => { "ok": true, "renewed": true }
        { "credential": "end", .. } => raise @door.ending("revoked", 3, "credential_revoked")
        _ => raise @door.DoorError("bad renewal")
      },
      stream: () => Some(asked => interop_answer(packer, asked)),
      ended: () => (),
    })
  } else {
    Refused({
      line: { "error": "refused", "code": "nope" },
      code: 1,
      reason: "credential_refused",
      error: @door.DoorError("refused"),
    })
  }
}

///|
fn n_of(path : String) -> Int {
  match path.find("n=") {
    Some(i) => @string.parse_int(path.clamped_view(start=i + 2)) catch { _ => 0 }
    None => 0
  }
}

///|
fn headers_of(head : Json) -> Array[(String, String)] {
  match head {
    { "headers": Object(m), .. } => {
      let out = []
      for k, v in m {
        if v is String(s) {
          out.push((k, s))
        }
      }
      out
    }
    _ => []
  }
}

///|
/// One item of the JSON an interop request is answered.
fn item(i : Int) -> Json {
  { "i": num(i), "words": Json::string("item \{i} of a list that says much the same each time") }
}

///|
async fn interop_answer(packer : @door.Packer, asked : @door.Asked) -> Unit {
  let path = match asked.head { { "path": String(p), .. } => p; _ => "" }
  let headers = headers_of(asked.head)
  let answer : @door.Answer = if path.has_prefix("/echo") {
    let body = asked.reader.rest()
    { status: 200, headers: [("content-type", "application/octet-stream")], body: Whole(body) }
  } else if path.has_prefix("/json") {
    let items = Array::makei(n_of(path), i => item(i))
    let text = Json::array(items).stringify()
    { status: 200, headers: [("content-type", "application/json")], body: Whole(@utf8.encode(text)) }
  } else if path.has_prefix("/events") {
    let left = Ref(n_of(path))
    let at = Ref(0)
    {
      status: 200,
      headers: [("content-type", "text/event-stream")],
      body: Coming({
        next: () => if left.val > 0 {
          left.val -= 1
          at.val += 1
          Some(@utf8.encode("data: " + item(at.val).stringify() + "\n\n"))
        } else {
          None
        },
        stop: () => left.val = 0,
      }),
    }
  } else {
    { status: 404, headers: [("content-type", "application/json")], body: Whole(b"{\"error\":\"none\"}") }
  }
  let sent = @door.compressed(packer, answer, headers, path)
  @door.send(asked.stream, sent)
  (asked.stream.finish)()
}

///|
/// The interop client's run on `conn` (its memory wire `wire`, this program's end `me`): the hellos tried in turn on a
/// connection each where refused... here one connection: the first hello, then renewals, then requests at once, then
/// a renewal that ends it. What it heard, in order.
pub async fn interop_client(
  conn : @door.Connection,
  wire : @door.Wire,
  me : Int,
  hellos : Array[Json],
  host : @host.Host,
  advance : async () -> Unit,
) -> Array[Json] {
  let said : Array[Json] = []
  let control = (conn.open_bi)()
  let r = @door.Reader::new(control)
  @door.write_line(control, hellos[0])
  said.push(r.line().unwrap_or(Json::null()))
  if !(said[0] is { "ok": true, .. }) {
    advance()
    ignore((conn.closed)()) catch {
      _ => ()
    }
    said.push(closed_of(wire, me))
    return said
  }
  for h in hellos[1:] {
    @door.write_line(control, h)
    said.push(r.line().unwrap_or(Json::null()))
  }
  // Three requests at once: a body of 300 KB echoed in pieces, JSON compressed, events compressed.
  let big = Bytes::makei(300 * 1024, i => (i * 7 % 251).to_byte())
  let asks : Array[(String, Bytes, Array[(String, String)])] = [
    ("/echo", big, []),
    ("/json?n=300", b"", [("accept-encoding", "gzip, zstd")]),
    ("/events?n=5", b"", [("accept-encoding", "zstd")]),
    ("/json?n=3", b"", [("accept-encoding", "zstd")]),
  ]
  let answers = @effect.all(asks.map(a => async fn() -> Json raise {
    let s = (conn.open_bi)()
    let hs : Map[String, Json] = Map([])
    for kv in a.2 {
      hs[kv.0] = Json::string(kv.1)
    }
    @door.write_line(s, { "method": "GET", "path": Json::string(a.0), "headers": Json::object(hs) })
    let mut at = 0
    while at < a.1.length() {
      let end = if at + 65536 < a.1.length() { at + 65536 } else { a.1.length() }
      (s.write)(@door.own(a.1[at:end]))
      at = end
    }
    (s.finish)()
    let rr = @door.Reader::new(s)
    let head = rr.line().unwrap_or(Json::null())
    let body = rr.rest()
    let zstd = head is { "headers": { "content-encoding": "zstd", .. }, .. }
    let plain = if zstd {
      // (a stream's frames flushed, not ended: unpacked as they come)
      let (opened, _) = host.shell("zstd.open", {})
      let zid = match opened { { "id": id, .. } => id; _ => Json::null() }
      let out = host.shell("zstd.push", { "id": zid }, bytes=body).1.unwrap_or(b"")
      ignore(host.shell("zstd.close", { "id": zid }))
      out
    } else {
      body
    }
    { "head": head, "size": num(plain.length()), "sum": num(checksum(plain)), "text": Json::string(if plain.length() < 20000 && a.0 != "/echo" { @utf8.decode_lossy(plain) } else { "" }) }
  }))
  for a in answers {
    said.push(a)
  }
  // A renewal that ends it: answered, a stream after it reset, the connection closed once the clock moved.
  @door.write_line(control, { "credential": "end" })
  said.push(r.line().unwrap_or(Json::null()))
  let s = (conn.open_bi)()
  @door.write_line(s, { "method": "GET", "path": "/json?n=1" })
  said.push(Json::string(try { (s.read)().map(_ => "data").unwrap_or("end") } catch { e => @door.message_of(e) }))
  advance()
  ignore((conn.closed)()) catch {
    _ => ()
  }
  said.push(closed_of(wire, me))
  said
}

///|
fn checksum(b : Bytes) -> Int {
  let mut h = 0
  for x in b {
    h = (h * 31 + x.to_int()) & 0x7fffffff
  }
  h
}

///|
fn closed_of(wire : @door.Wire, me : Int) -> Json {
  match wire.closed_by() {
    Some((by, code, reason)) => { "closed": true, "by_peer": Json::boolean(by != me), "code": num(code), "reason": Json::string(reason) }
    None => { "closed": false }
  }
}

///|
/// The bus of the station transport's interop (the test's twin, word for word): a request's echo, with the size and sum of
/// its bytes; `file` answered `n` bytes after; `fail` refused.
pub fn interop_bus() -> @gate.PeerBus {
  let bus = @gate.PeerBus::new()
  bus.otherwise(async fn(peer, request, bytes, workspace) {
    let verb = match request { { "method": String(m), .. } => m; _ => "" }
    if verb == "fail" {
      raise @gate.Refused("refused as asked")
    }
    let mut size = 0
    let mut sum = 0
    if bytes is Some(b) {
      while (b.next)() is Some(piece) {
        size += piece.length()
        for x in piece {
          sum = (sum * 31 + x.to_int()) & 0x7fffffff
        }
      }
    }
    let said : Json = {
      "asked": request,
      "peer": Json::string(peer),
      "workspace": Json::string(workspace),
      "size": num(size),
      "sum": num(sum),
    }
    if verb == "file" {
      let n = match request { { "n": Number(x, ..), .. } => x.to_int(); _ => 0 }
      let left = Ref(n)
      let body : @gate.Body = {
        next: async fn() {
          if left.val <= 0 {
            return None
          }
          let k = if left.val < 65536 { left.val } else { 65536 }
          left.val -= k
          Some(Bytes::makei(k, i => ((n - left.val - k + i) * 7 % 251).to_byte()))
        },
        stop: async fn() { left.val = 0 },
        check: None,
      }
      (said, Some(body))
    } else {
      (said, None)
    }
  })
  bus
}

///|
/// One step of the station transport's interop client: a request (with `bytes` that many bytes after), what it was
/// answered (and the size and sum of what came after), or why not.
pub async fn peer_client_step(call : @gate.PeerCall, target : String, step : Json) -> Json {
  let request = match step { { "request": r, .. } => r; _ => Json::null() }
  let ws = match step { { "workspace": String(w), .. } => Some(w); _ => None }
  let to = match step { { "to": String(t), .. } => t; _ => target }
  let n = match step { { "bytes": Number(x, ..), .. } => x.to_int(); _ => -1 }
  let body : @gate.Body? = if n < 0 {
    None
  } else {
    let left = Ref(n)
    Some({
      next: async fn() {
        if left.val <= 0 {
          return None
        }
        let k = if left.val < 65536 { left.val } else { 65536 }
        left.val -= k
        Some(Bytes::makei(k, i => ((n - left.val - k + i) * 7 % 251).to_byte()))
      },
      stop: async fn() { left.val = 0 },
      check: None,
    })
  }
  try {
    let (result, bytes) = call(to, ws, request, body)
    let mut size = 0
    let mut sum = 0
    if bytes is Some(b) {
      while (b.next)() is Some(piece) {
        size += piece.length()
        for x in piece {
          sum = (sum * 31 + x.to_int()) & 0x7fffffff
        }
      }
    }
    if bytes is Some(_) {
      { "result": result, "size": num(size), "sum": num(sum) }
    } else {
      { "result": result }
    }
  } catch {
    e => { "error": Json::string(@gate.words_of(e)), "refused": Json::boolean(e is @gate.PeerRefused(_)) }
  }
}

///|
/// This machine as the web interop's station reaches it (the test's twin): port 4242 the station's own, 4343 a forward's,
/// 5000 a service that greets and ends, nothing else listening.
pub fn interop_here() -> @gate.HereLocal {
  {
    reach: Some(async fn(port) {
      if port != 5000 {
        raise @gate.Refused("connect ECONNREFUSED 127.0.0.1:\{port}")
      }
      async fn(stream, _carry) {
        (stream.write)(b"greetings from 5000")
        (stream.finish)()
      }
    }),
    own: port => port == 4242,
    forwarded: Some(port => port == 4343),
    allowed: None,
    device: None,
    proxy: async fn(_verb, _headers, _body, _port, _path) { raise @gate.Refused("no services here") },
    socket: async fn(_headers, _port, _path, _stream, _carry) raise @gate.HttpRefusal { raise @gate.HttpRefusal(501, "no sockets here", false) },
  }
}
