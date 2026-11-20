// Members' connections over the mesh (station/src/mesh/serve.ts `serve`, `admission`, `answerAsked`): the credential
// first, nothing served before it checks out; then a request a stream. The streams are the door's; who is let in
// (`admission`) and what is answered (`answer_request`) are here, the admin API and what else answers a request given
// as `Members`.

///|
pub let alpn : String = "stillfail/admin/1"

///|
/// A request the admin API answers (api/admin.ts `handle`).
pub(all) struct AdminAsk {
  verb : String
  path : String
  query : Array[(String, String)]
  search : String
  headers : Array[(String, String)]
  body : Bytes
  viewer : Viewer
  lang : String
  /// Whether its device stopped reading (reads only: a write is finished whoever goes).
  aborted : (() -> Bool)?
}

///|
/// What a part that answers a kind of request on a member's link itself is given (parts.ts `MemberAsk`).
pub(all) struct MemberAsk {
  conn : @door.Connection
  viewer : Viewer
  head : Json
  stream : @door.Stream
  reader : @door.Reader
}

///|
/// A span of a caller's trace (mesh/traces.ts `Span`), the traces' own.
pub(all) struct Traces {
  start : (String?) -> Json?
  traceparent : (Json) -> String
  end : (Json, Int64, String, Array[(String, Json)], Bool) -> Unit
}

///|
/// Who each connection's member is, told the program that answers some requests itself (served.ts `viewer`).
pub type ToldViewer = (Int, Viewer?, Bool, Int?) -> Unit

///|
pub(all) struct Members {
  keeper : Keeper
  packer : @door.Packer
  /// Whether the station answers now.
  up : () -> Bool
  admin : async (AdminAsk) -> @door.Answer
  /// Who asks is remembered by name as the admin API remembers them.
  remember_name : (String, String) -> Unit
  streams : ((Json) -> (async (MemberAsk) -> Unit)?)?
  screens : (async (@door.Stream, Bytes, Json, Viewer, () -> Bool) -> Unit)?
  /// A preview page's WebSocket (`"socket": true`, jobs/preview.ts): its stream carried to the service.
  socket : (async (@door.Stream, @door.Reader, Json, String) -> Unit)?
  traces : Traces?
  lan : () -> Array[String]
  tailnet : () -> Array[String]
  connected : () -> Unit
  served : ToldViewer?
  /// A core's language by its headers (api/request.ts `langOfCore`), and what it is told to update in it.
  lang_of : (Array[(String, String)]) -> String
  update_words : (String) -> String
  /// A member's device in its workspace's mesh scope (mesh/leaf.ts), where the station keeps a directory.
  leaves : LeafDoor?
}

///|
/// What a member's connection asks of its workspace's mesh scope (leaf.ts `LeafAttachments`): told each admission
/// and renewal of the connection (workspace, expiry in unix seconds), the scope's view, followed as it changes, and a
/// device's binding attached.
pub(all) struct LeafDoor {
  authenticated : (@door.Connection, String, Int64) -> Unit
  view : (String) -> Json raise
  follow : async (@door.Connection, String, @door.Stream) -> Unit
  attach : async (@door.Connection, String, Json, String) -> Json
}

///|
/// The ways a connection has, as the log says them (reply-watch.ts `pathsOf`).
pub fn paths_of(conn : @door.Connection) -> String {
  match conn.paths {
    None => ""
    Some(p) =>
      p()
      .map(p => {
        let at = match (p.relay, p.ip) { (Some(r), _) => r; (_, Some(ip)) => ip; _ => "?" }
        let rtt = match p.rtt_ms { Some(ms) => "\{(ms + 0.5).floor().to_int64()}ms"; None => "?" }
        "\{if p.selected { "*" } else { "" }}\{at} \{rtt} \{p.tx_packets.to_int64()}/\{p.lost_packets.to_int64()}"
      })
      .join(", ")
  }
}

///|
let id_collections : Array[String] = [
  "sessions", "threads", "connects", "profiles", "logins", "workspaces", "stations",
  "members", "enrollments", "accounts",
]

///|
/// A path without its ids: a segment after a collection, or one that is no plain word, is `:id` (traces.ts `route`).
pub fn route_of(path : String) -> String {
  let cut = match (path.find("?"), path.find("#")) {
    (Some(a), Some(b)) => if a < b { a } else { b }
    (Some(a), None) => a
    (None, Some(b)) => b
    (None, None) => path.length()
  }
  let mut after_collection = false
  path
  .clamped_view(end=cut)
  .split("/")
  .map(seg => {
    let segment = seg.to_owned()
    let plain = segment.iter().all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
    let word = segment != "" && segment.length() <= 24 && plain && segment.iter().any(c => c >= 'a' && c <= 'z')
    let id = segment != "" && (after_collection || !word)
    after_collection = !id && id_collections.contains(segment)
    if id {
      ":id"
    } else {
      segment
    }
  })
  .collect()
  .join("/")
}

///|
fn hex_of(s : String, n : Int) -> Bool {
  s.length() == n && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

///|
/// A W3C traceparent's trace id (traces.ts `parseParent`), None where it is none.
pub fn parent_trace(header : String?) -> String? {
  let parts = header.unwrap_or("").trim(chars=" \t\n\r").split("-").map(p => p.to_owned()).collect()
  if parts.length() != 4 {
    return None
  }
  let (version, trace, span, flags) = (parts[0], parts[1], parts[2], parts[3])
  if version.length() != 2 || version == "ff" || !hex_of(flags, 2) {
    return None
  }
  if !hex_of(trace, 32) || !hex_of(span, 16) || trace.iter().all(c => c == '0') || span.iter().all(c => c == '0') {
    return None
  }
  Some(trace.to_lower())
}

///|
/// The headers a head line says (strings only).
pub fn headers_of(head : Json) -> Array[(String, String)] {
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
/// One member's connection: the credential first, nothing served before it checks out; then a request a stream.
pub async fn serve(m : Members, conn : @door.Connection) -> Unit {
  if (m.keeper.removed)() {
    (conn.close)(2, "station_removed")
    raise @door.DoorError("station removed")
  }
  let device = (conn.remote_id)()
  @door.door(conn, admission(m, device))
}

///|
/// Who the door lets in here: a member's device, by the credential its hello brings and the lock; with what its later
/// lines and its requests are answered, and what ends the connection meanwhile (serve.ts `admission`).
pub fn admission(m : Members, device : String) -> @door.Admit {
  let k = m.keeper
  (hello, conn) => {
    let rt = @effect.runtime()
    let proof = lock_proof(field(hello, "lock"))
    let check = async fn(line : Json, verified : (String) -> Unit) -> (Admitted, String) {
      let keys : Map[String, Json] = Map([])
      let home = (k.home)()
      for ms in (k.memberships)() {
        keys[ms.workspace] = (k.grant_keys)(if Some(ms.workspace) == home { None } else { Some(ms.workspace) })
      }
      let fallback = (k.grant_keys)(None)
      let admitted = verify_member_of(
        credential_of(line),
        ws => keys.get(ws).unwrap_or(fallback),
        (k.memberships)(),
        device,
        (k.now_secs)(),
        k.verify,
        accepted=(k.accepted)(),
      )
      let named = admitted.viewer.role
      verified(admitted.viewer.sub)
      let admitted = match proof {
        Some(p) => { ..admitted, viewer: { ..admitted.viewer, lock_device: Some(p) } }
        None => admitted
      }
      let base = match proof {
        Some((b, p)) if (k.endpoint_proof)(admitted.viewer.workspace, b, device, p) => Some(b)
        _ => None
      }
      k.seen.saw(
        (k.now_secs)(),
        admitted.viewer.workspace,
        admitted.viewer.sub,
        admitted.viewer.email,
        device,
        base,
        field(line, "lock").unwrap_or(Json::null()),
        role?=if admitted.viewer.role != "" { Some(admitted.viewer.role) } else { None },
      )
      let in_it = in_lock_bringing(k, admitted, named, device, line)
      let in_it = if in_it.viewer.lock_id is None && base is Some(_) {
        { ..in_it, viewer: { ..in_it.viewer, lock_id: base } }
      } else {
        in_it
      }
      (in_it, named)
    }
    let whose : Ref[String?] = Ref(None)
    let checked = try {
      Ok(check(hello, sub => whose.val = Some(sub)))
    } catch {
      e => Err(e)
    }
    let (first, first_named) = match checked {
      Ok(c) => c
      Err(e) => {
        if (m.served, conn.handed) is (Some(told), Some(h)) {
          told(h, None, false, None)
        }
        let line = refusal_of(k, hello, device, e, (k.accepted)(), whose.val)
        return Refused({
          line,
          code: 1,
          reason: if is_lock_refusal(e) { "lock_unconfirmed" } else { "credential_refused" },
          error: e,
        })
      }
    }
    let current = Ref(first)
    let named = Ref(first_named)
    let head = lock_head_json(k, joined_of(k, current.val.viewer.workspace))
    let lan = (m.lan)()
    let tailnet = (m.tailnet)()
    let station = match (k.membership)(current.val.viewer.workspace) {
      Some((name, _)) => name
      None => (k.name)()
    }
    match m.leaves {
      Some(l) => (l.authenticated)(conn, current.val.viewer.workspace, current.val.exp)
      None => ()
    }
    let line_m : Map[String, Json] = {
      "ok": true,
      "station": Json::string(station),
      "expires_at": Json::number(current.val.exp.to_double()),
    }
    if head != Json::null() {
      line_m["lock"] = head
    }
    if lan.length() > 0 {
      line_m["lan"] = Json::array(lan.map(x => Json::string(x)))
    }
    if tailnet.length() > 0 {
      line_m["tailnet"] = Json::array(tailnet.map(x => Json::string(x)))
    }
    if m.leaves is Some(_) {
      line_m["meshLeaf"] = true
    }
    let last_ways = Ref("")
    // Who the member is, told what answers a route itself as it is now (None: gone).
    let told = async fn(gone : Bool) -> Unit {
      guard (m.served, conn.handed) is (Some(tell), Some(h)) else { return }
      if gone {
        tell(h, None, false, None)
        return
      }
      let viewer = { ..current.val.viewer, home: Some((k.home)() == Some(current.val.viewer.workspace)) }
      if viewer.name != "" {
        (m.remember_name)(viewer.email, viewer.name)
      }
      let floor = moved_floor(k, viewer.workspace)
      tell(h, Some(viewer), floor is Some(_), floor)
    }
    // The connection ends when its credential runs out or is revoked, or the station leaves its workspace, or the lock
    // takes the device away (or lowers its member's role).
    let gone = async fn() -> Bool {
      let of = (k.membership)(current.val.viewer.workspace)
      if (k.removed)() || of is None {
        (conn.close)(2, "station_removed")
      } else if revoked(current.val, of.unwrap().1) {
        (conn.close)(3, "credential_revoked")
      } else if current.val.exp <= (k.now_secs)() {
        (conn.close)(3, "credential_expired")
      } else {
        match (try { Ok(still_in(k, current.val, named.val, device)) } catch { e => Err(e) }) {
          Ok(now) => {
            current.val = now
            told(false)
            return false
          }
          Err(_) => (conn.close)(3, "lock_unconfirmed")
        }
      }
      true
    }
    let expiry : Ref[(() -> Unit)?] = Ref(None)
    fn watch_expiry() -> Unit {
      if expiry.val is Some(off) {
        off()
      }
      let left = current.val.exp * 1000L - (k.now_secs)() * 1000L
      let ms = (if left < 0L { 0L } else { left }) + 50L
      let at = if ms > 2147483647L { 2147483647 } else { ms.to_int() }
      expiry.val = Some(@door.after(rt, at, () => ignore(rt.fork_daemon("member expiry", on_error=_ => (conn.close)(3, "lock_unconfirmed"), () => if !gone() { watch_expiry() }))))
    }
    let unlisten : Ref[() -> Unit] = Ref(() => ())
    Let({
      line: Json::object(line_m),
      opened: () => {
        let trace = parent_trace(match field(hello, "traceparent") { Some(String(t)) => Some(t); _ => None })
        let opened = rt.now()
        @door.log("info", "mesh", "client connected", {
          "email": Json::string(current.val.viewer.email),
          "device": Json::string(short(device)),
          "trace": match trace { Some(t) => Json::string(t); None => Json::null() },
          "via": Json::string((conn.via)().unwrap_or("direct")),
          "ways": Json::string(paths_of(conn)),
        })
        (m.connected)()
        last_ways.val = paths_of(conn)
        ignore(rt.fork_daemon("member closed", on_error=_ => (), () => {
          let why = (conn.closed)() catch { _ => return }
          let ways = paths_of(conn)
          let with_ : Map[String, Json] = {
            "device": Json::string(short(device)),
            "trace": match trace { Some(t) => Json::string(t); None => Json::null() },
            "why": Json::string(why),
            "lasted": Json::number((rt.now() - opened).to_double()),
            "ways": Json::string(if ways == "" { last_ways.val } else { ways }),
          }
          if conn.stats is Some(stats) {
            let t = stats()
            with_["rx"] = Json::number(t.get("rxBytes").unwrap_or(0.0))
            with_["tx"] = Json::number(t.get("txBytes").unwrap_or(0.0))
          }
          @door.log("info", "mesh", "a device's connection ended", Json::object(with_))
        }))
        watch_expiry()
        let on_change = () => ignore(rt.fork_daemon("member gone", on_error=_ => (conn.close)(3, "lock_unconfirmed"), () => ignore(gone())))
        let off_cloud = (k.listen)(on_change)
        let off_persons = (k.persons_listen)(on_change)
        unlisten.val = () => {
          off_cloud()
          off_persons()
        }
        ignore(rt.fork_quiet(name="member told", () => told(false)))
      },
      renew: line => {
        let (a, n) = check(line, _ => ())
        current.val = a
        named.val = n
        match m.leaves {
          Some(l) => (l.authenticated)(conn, a.viewer.workspace, a.exp)
          None => ()
        }
        watch_expiry()
        told(false)
        { "ok": true, "expires_at": Json::number(current.val.exp.to_double()) }
      },
      stream: () => {
        // (`gone` asks the keeper: looked at as the stream is taken, in the fiber that answers it)
        last_ways.val = paths_of(conn)
        Some(asked => {
          if gone() {
            (asked.stream.reset)(0) catch {
              _ => ()
            }
            return
          }
          let viewer = { ..current.val.viewer, home: Some((k.home)() == Some(current.val.viewer.workspace)) }
          answer_asked(m, asked, viewer, conn)
        })
      },
      ended: () => {
        if expiry.val is Some(off) {
          off()
        }
        (unlisten.val)()
        ignore(rt.fork_quiet(name="member told gone", () => told(true)))
      },
    })
  }
}

///|
fn short(id : String) -> String {
  if id.length() > 12 {
    id.clamped_view(end=12).to_owned()
  } else {
    id
  }
}

///|
/// One request: to the admin API in this process (serve.ts `answerAsked`).
pub async fn answer_asked(m : Members, asked : @door.Asked, viewer : Viewer, conn : @door.Connection) -> Unit {
  let verb = match field(asked.head, "method") { Some(String(v)) => v.to_upper(); _ => "GET" }
  let path = match field(asked.head, "path") { Some(String(p)) => p; _ => "" }
  let (stream, head, end) = tracing(m.traces, asked.head, verb, path, (conn.via)(), asked.accepted, asked.stream, asked.reader.carry.length())
  asked.reader.set_stream(stream)
  answer_request(m, stream, asked.reader, head, verb, path, viewer, conn) catch {
    e => {
      end(Some(@door.message_of(e)))
      raise e
    }
  }
  end(None)
}

///|
/// A request's span while it runs, and the stream it is answered on, counted (serve.ts `tracing`): the stream, the head
/// as it goes on (its traceparent the span's), and what ends the span.
fn tracing(
  traces : Traces?,
  head : Json,
  verb : String,
  path : String,
  via : String?,
  accepted : Int64,
  stream : @door.Stream,
  carried : Int,
) -> (@door.Stream, Json, (String?) -> Unit) {
  let theirs = match path_of(head, ["headers", "traceparent"]) { Some(String(t)) => Some(t); _ => None }
  guard traces is Some(t) && (t.start)(theirs) is Some(span) else { return (stream, head, _ => ()) }
  let headers = match field(head, "headers") { Some(Object(h)) => h.copy(); _ => Map([]) }
  headers["traceparent"] = Json::string((t.traceparent)(span))
  let head = match head {
    Object(h) => {
      let c = h.copy()
      c["headers"] = Json::object(headers)
      Json::object(c)
    }
    other => other
  }
  let outcome_status = Ref(0)
  let received = Ref(carried)
  let sent = Ref(0)
  let head_seen = Ref(false)
  let live = Ref(true)
  let end = (streamed : Bool, error : String?) => {
    if !live.val {
      return
    }
    live.val = false
    let attributes : Array[(String, Json)] = [
      ("http.request.method", Json::string(verb)),
      ("url.path", Json::string(route_of(path))),
      ("http.response.status_code", Json::number(outcome_status.val.to_double())),
      ("http.request.body.size", Json::number(received.val.to_double())),
    ]
    attributes.push(if streamed { ("stillfail.stream", Json::boolean(true)) } else { ("http.response.body.size", Json::number(sent.val.to_double())) })
    if via is Some(v) {
      attributes.push(("stillfail.path", Json::string(v)))
    }
    if error is Some(e) {
      attributes.push(("error.type", Json::string(e)))
    }
    (t.end)(span, accepted, "\{verb} \{route_of(path)}", attributes, error is Some(_) || outcome_status.val >= 500)
  }
  let counted : @door.Stream = {
    read: async fn() -> Bytes? {
      let more = (stream.read)()
      if more is Some(b) {
        received.val += b.length()
      }
      more
    },
    write: async fn(bytes : Bytes) {
      (stream.write)(bytes)
      if !head_seen.val {
        head_seen.val = true
        let mut nl = bytes.length()
        for i in 0..<bytes.length() {
          if bytes[i] == b'\n' {
            nl = i
            break
          }
        }
        try {
          let said = @json.parse(@utf8.decode_lossy(@door.own(bytes[0:nl])))
          outcome_status.val = match field(said, "status") { Some(Number(n, ..)) => n.to_int(); _ => 0 }
          let kind = match path_of(said, ["headers", "content-type"]) { Some(String(s)) => s; _ => "" }
          if outcome_status.val == 101 ||
            kind.has_prefix("text/event-stream") ||
            kind.has_prefix("application/x-ndjson") ||
            kind.has_prefix("application/x-stillfail-screen") {
            end(true, None)
          }
        } catch {
          _ => ()
        }
        sent.val += bytes.length() - nl - 1
      } else {
        sent.val += bytes.length()
      }
    },
    finish: async fn() { (stream.finish)() },
    stopped: async fn() -> Int? { (stream.stopped)() },
    reset: async fn(code : Int) { (stream.reset)(code) },
  }
  (counted, head, error => end(false, error))
}

///|
async fn answer_json(stream : @door.Stream, code : Int, body : String) -> Unit {
  @door.write_line(stream, { "status": Json::number(code.to_double()), "headers": { "content-type": "application/json" } })
  (stream.write)(@utf8.encode(body))
  (stream.finish)()
}

///|
/// Whether a request only reads (what is let go when its device stops reading).
pub fn reads_of(verb : String, path : String) -> Bool {
  let rest = if path.length() >= 10 { path.clamped_view(start=10).to_owned() } else { "" }
  let bare = match rest.find("?") { Some(i) => rest.clamped_view(end=i).to_owned(); None => rest }
  if verb == "GET" {
    return true
  }
  if verb != "POST" {
    return false
  }
  let mut at = 0
  while at < bare.length() && bare.code_unit_at(at) == '/'.to_int().to_uint16() {
    at += 1
  }
  let name = bare.clamped_view(start=at).to_owned()
  name == "batch" || name == "changed/chats" || name == "changed/threads" || name == "changed/sessions"
}

///|
/// What a query says, as api/request.ts `queryPairs` reads it.
pub fn query_pairs(query : String) -> Array[(String, String)] {
  let out = []
  for part in query.split("&") {
    let p = part.to_owned()
    if p == "" {
      continue
    }
    let (k, v) = match p.find("=") {
      Some(i) => (p.clamped_view(end=i).to_owned(), p.clamped_view(start=i + 1).to_owned())
      None => (p, "")
    }
    out.push((decode_component(k), decode_component(v)))
  }
  out
}

///|
/// `+` as a space and %XX as its byte, as URLSearchParams decodes (UTF-8, what is no byte left as it is).
fn decode_component(s : String) -> String {
  let bytes = []
  let units = s.replace_all(old="+", new=" ")
  let enc = @utf8.encode(units)
  let mut i = 0
  while i < enc.length() {
    let c = enc[i]
    if c == b'%' && i + 2 < enc.length() + 0 && i + 2 <= enc.length() - 1 && is_hex(enc[i + 1]) && is_hex(enc[i + 2]) {
      bytes.push((hex_val(enc[i + 1]) * 16 + hex_val(enc[i + 2])).to_byte())
      i += 3
    } else {
      bytes.push(c)
      i += 1
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
fn is_hex(b : Byte) -> Bool {
  (b >= b'0' && b <= b'9') || (b >= b'a' && b <= b'f') || (b >= b'A' && b <= b'F')
}

///|
fn hex_val(b : Byte) -> Int {
  if b >= b'0' && b <= b'9' {
    (b - b'0').to_int()
  } else if b >= b'a' && b <= b'f' {
    (b - b'a').to_int() + 10
  } else {
    (b - b'A').to_int() + 10
  }
}

///|
async fn answer_request(
  m : Members,
  stream : @door.Stream,
  reader : @door.Reader,
  head : Json,
  verb : String,
  path : String,
  viewer : Viewer,
  conn : @door.Connection,
) -> Unit {
  let k = m.keeper
  if !path.has_prefix("/admin/api/") || path.contains("..") {
    return answer_json(stream, 404, "{\"error\":\"only the admin API is reachable over the mesh\"}")
  }
  let asking = match field(head, "headers") { Some(Object(_) as h) => h; _ => Json::object(Map([])) }
  let lang = (m.lang_of)(headers_of(head))
  if core_too_old(k, asking) {
    return answer_json(stream, 426, ({ "error": Json::string((m.update_words)(lang)), "update": true } : Json).stringify())
  }
  let build = saw_build(k, viewer, asking)
  if moved_too_old(k, viewer, build) {
    return answer_json(stream, 426, ({ "error": Json::string((m.update_words)(lang)), "update": true } : Json).stringify())
  }
  // (a device's leaf in its workspace's mesh scope: serve.ts's `/admin/api/mesh/leaf`, its events)
  if path == "/admin/api/mesh/leaf/events" && verb == "GET" {
    guard m.leaves is Some(l) else {
      return answer_json(stream, 404, ({ "error": "no leaf transport" } : Json).stringify())
    }
    @door.write_line(stream, { "status": 200, "headers": { "content-type": "application/x-ndjson" } })
    return (l.follow)(conn, viewer.workspace, stream)
  }
  if path == "/admin/api/mesh/leaf" {
    guard m.leaves is Some(l) else {
      return answer_json(stream, 404, ({ "error": "no leaf transport" } : Json).stringify())
    }
    let answered = try {
      if verb == "GET" {
        Ok((200, (l.view)(viewer.workspace)))
      } else {
        let body = reader.rest()
        if verb != "POST" || body.length() > 16384 {
          Ok((400, ({ "error": "invalid leaf attachment request" } : Json)))
        } else {
          let input = @json.parse(@utf8.decode_lossy(body))
          match input {
            Object(o) if o.get("target") is Some(String(target)) =>
              Ok((200, (l.attach)(conn, viewer.workspace, o.get("descriptor").unwrap_or(Json::null()), target)))
            _ => Ok((400, ({ "error": "missing leaf target" } : Json)))
          }
        }
      }
    } catch {
      e => Err(e)
    }
    return match answered {
      Ok((code, said)) => answer_json(stream, code, said.stringify())
      Err(e) => answer_json(stream, 403, ({ "error": Json::string("\{e}") } : Json).stringify())
    }
  }
  if m.streams is Some(parts) && parts(head) is Some(part) {
    return part({ conn, viewer, head, stream, reader })
  }
  if field(head, "screen") is Some(Object(_)) {
    match m.screens {
      None => return answer_json(stream, 404, ({ "error": "no screens on this station" } : Json).stringify())
      Some(screens) => return screens(stream, reader.carry, head, viewer, m.up)
    }
  }
  if field(head, "socket") == Some(Json::boolean(true)) {
    if read_only(viewer.role) {
      return answer_json(stream, 403, ({ "error": "read-only members cannot change this station" } : Json).stringify())
    }
    match m.socket {
      Some(socket) => return socket(stream, reader, head, path)
      None => return answer_json(stream, 404, ({ "error": "only a preview's WebSocket is opened over the mesh" } : Json).stringify())
    }
  }
  let body = reader.rest()
  let rt = @effect.runtime()
  let aborted = Ref(false)
  let handling = Ref(true)
  let watch = if reads_of(verb, path) {
    Some(rt.fork(name="request stopped", () => {
      ignore((stream.stopped)()) catch {
        _ => ()
      }
      if handling.val {
        aborted.val = true
      }
    }))
  } else {
    None
  }
  let (handled, headers, rest, plain) = handled_of(m, verb, path, head, body, viewer, if watch is Some(_) { Some(() => aborted.val) } else { None })
  handling.val = false
  if watch is Some(w) {
    w.interrupt()
  }
  if plain {
    let text = match handled.body { Whole(b) => @utf8.decode_lossy(b); Coming(_) => "" }
    return answer_json(stream, handled.status, text)
  }
  let sent = @door.compressed(m.packer, handled, headers, rest)
  @door.send(stream, sent)
  (stream.finish)()
}

///|
/// A request's answer once its body is in, as the admin API and the station's own routes give it (not compressed), with
/// the headers it went on with, its path after /admin/api, and whether it is the station's own answer said as it is
/// (serve.ts `handledOf`).
pub async fn handled_of(
  m : Members,
  verb : String,
  path : String,
  head : Json,
  body : Bytes,
  viewer : Viewer,
  aborted : (() -> Bool)?,
) -> (@door.Answer, Array[(String, String)], String, Bool) {
  let k = m.keeper
  let json = (code : Int, said : Json) => ({
    status: code,
    headers: [("content-type", "application/json")],
    body: Whole(@utf8.encode(said.stringify())),
  } : @door.Answer)
  let kept = async fn(code : Int, said : Json) -> @door.Answer {
    if verb != "POST" {
      return json(code, said)
    }
    try {
      (k.persons_written)()
    } catch {
      e => return json(500, { "error": Json::string("not kept on this station, try again: \{words_of(e)}") })
    }
    json(code, said)
  }
  let headers = []
  for kv in headers_of(head) {
    let lower = kv.0.to_lower()
    if @door.hop.contains(lower) || lower.has_prefix("x-stillfail-") || lower == "traceparent" || lower == "tracestate" {
      continue
    }
    headers.push(kv)
  }
  let rest = if path.length() >= 10 { path.clamped_view(start=10).to_owned() } else { "" }
  if !(m.up)() {
    return (json(502, { "error": "station unreachable: not started" }), headers, rest, true)
  }
  let at = rest.find("?")
  let route = match at { Some(i) => rest.clamped_view(end=i).to_owned(); None => rest }
  let query = match at { Some(i) => query_pairs(rest.clamped_view(start=i + 1).to_owned()); None => [] }
  if route == "/lock" {
    let (code, said) = lock_route(k, verb, query, body, viewer)
    return (kept(code, said), headers, rest, true)
  }
  if route == "/ways" {
    let (code, said) = ways_route(k, verb, body, viewer)
    return (json(code, said), headers, rest, true)
  }
  if route == "/station-marks" || route == "/station-mark" {
    let (code, said) = station_marks_route(k, verb, body, viewer, route == "/station-mark")
    return (json(code, said), headers, rest, true)
  }
  for part in ["person", "devices", "bodies", "logs", "heads", "given"] {
    if route == "/lock/" + part {
      let (code, said) = lock_part_route(k, part, verb, body, viewer)
      return (kept(code, said), headers, rest, true)
    }
  }
  let handled = (m.admin)({
    verb,
    path: route,
    query,
    search: match at { Some(i) => rest.clamped_view(start=i).to_owned(); None => "" },
    headers,
    body,
    viewer,
    lang: (m.lang_of)(headers),
    aborted,
  })
  (handled, headers, rest, false)
}

///|
/// A request the program that answers some itself gave back, answered as one on a stream is once its body is in
/// (serve.ts `answerGiven`).
pub async fn answer_given(m : Members, viewer : Viewer, head : Json, body : Bytes) -> @door.Answer {
  let verb = match field(head, "method") { Some(String(v)) => v.to_upper(); _ => "GET" }
  let path = match field(head, "path") { Some(String(p)) => p; _ => "" }
  handled_of(m, verb, path, head, body, viewer, None).0
}

///|
/// The language a core asks in: its `stillfail-lang`, Chinese for a core from before languages (api/request.ts
/// `langOfCore`, ops/i18n.ts `langOf`).
pub fn lang_of_core(headers : Array[(String, String)]) -> String {
  match headers.iter().find_first(kv => kv.0.to_lower() == "stillfail-lang") {
    None => "zh"
    Some(kv) => {
      let l = kv.1.trim(chars=" \t\n\r").to_owned().to_lower()
      if l == "" || l.has_prefix("zh") {
        "zh"
      } else {
        "en"
      }
    }
  }
}
