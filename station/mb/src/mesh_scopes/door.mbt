// The relays' door (enrollment-door.ts `EnrollmentDoor`, relay-watch.ts `watchRelay`): on its own protocol a relay
// redeems the one-use token its workspace's station issued, or resumes the registration it has, and then may keep one
// stream open to its issuer for the scope's directory as it changes. A token grants a relay identity only: no
// station data, no route of the station's. The key the transport authenticated is the relay's, never what it says.

///|
pub let enrollment_alpn : String = "stillfail/mesh-enrollment/1"

///|
/// What the door is given of the station.
pub(all) struct DoorParts {
  enrollment : Enrollment
  /// Whether this station is in the scope's workspace now.
  allowed : (String) -> Bool
  /// The registration kept of a node in a scope by this issuer (the readers' `internalMeshControl` `registration`).
  read : async (String, String) -> Json
  /// A registration this door signed, kept as any station's (relay-records' take, then the directory's).
  registered : async (Json) -> Unit
  /// The scope's directory, where the station has one.
  sync : ScopeSync?
  crypto : Crypto
}

///|
pub struct EnrollmentDoor {
  parts : DoorParts
  priv mut active : Int
}

///|
pub fn EnrollmentDoor::new(parts : DoorParts) -> EnrollmentDoor {
  { parts, active: 0 }
}

///|
fn coded(code : String, words : String) -> Error {
  Failure::Failure("\{code}: \{words}")
}

///|
/// A request of the door answered (`answer`): enroll redeems a token, resume reads the registration there is.
pub async fn EnrollmentDoor::answer(self : EnrollmentDoor, request : Json, node : String) -> Json {
  let op = text(field(request, "op")).unwrap_or("")
  let scope = text(field(request, "scope"))
  let ok = (op == "enroll" || op == "resume") &&
    scope is Some(_) &&
    (op != "enroll" || field(request, "token") is String(_)) &&
    (self.parts.allowed)(scope.unwrap_or(""))
  guard ok else {
    raise coded("relay_scope_unavailable", "relay enrollment is not available for this scope")
  }
  let scope = scope.unwrap_or("")
  let record = if op == "resume" {
    match (self.parts.read)(scope, node) {
      Object(_) as row =>
        Some({
          scope: text(field(row, "scope")).unwrap_or(""),
          node: text(field(row, "node")).unwrap_or(""),
          issuer: text(field(row, "issuer")).unwrap_or(""),
          generation: safe_int(field(row, "generation")).unwrap_or(0L),
          name: text(field(row, "name")).unwrap_or(""),
          made_by: text(field(row, "made_by")).unwrap_or(""),
          revoked: safe_int(field(row, "revoked")).unwrap_or(1L),
        })
      _ => None
    }
  } else {
    Some(self.parts.enrollment.redeem(scope, text(field(request, "token")).unwrap_or(""), node))
  }
  guard record is Some(r) &&
    r.revoked == 0L &&
    r.node == node &&
    r.scope == scope &&
    r.issuer == self.parts.enrollment.issuer else {
    raise coded("relay_not_registered", "relay identity is not registered in this scope")
  }
  guard (self.parts.allowed)(scope) else {
    raise coded("relay_scope_unavailable", "relay enrollment is not available for this scope")
  }
  let signed = sign_relay_record(self.parts.crypto, r)
  (self.parts.registered)(signed)
  let out : Map[String, Json] = Map([("record", r.to_json())])
  match signed {
    Object(m) =>
      for k, v in m {
        out[k] = v
      }
    _ => ()
  }
  Json::object(out)
}

///|
fn words_of(e : Error) -> (String, String?) {
  let said = match e {
    Failure(s) => s
    _ => "\{e}"
  }
  for code in ["relay_scope_unavailable", "relay_not_registered"] {
    if said.has_prefix(code + ": ") {
      return (said[code.length() + 2:].to_owned(), Some(code))
    }
  }
  (said, None)
}

///|
/// A relay's connection served (`serve`): one request answered, or its directory followed while it stays.
pub async fn EnrollmentDoor::serve(self : EnrollmentDoor, conn : @door.Connection) -> Unit {
  if self.active >= 32 {
    (conn.close)(1, "relay enrollment busy")
    return
  }
  self.active += 1
  defer {
    self.active -= 1
    (conn.close)(0, "relay enrollment ended")
  }
  let mut stream : @door.Stream? = None
  let served = try {
    guard @effect.timeout(10000, async fn() { (conn.accept_bi)() }) is Some(Some(s)) else {
      fail("relay handshake deadline")
    }
    stream = Some(s)
    let reader = @door.Reader::new(s, max_line=64 * 1024)
    guard @effect.timeout(10000, async fn() { reader.line() }) is Some(request) else {
      fail("relay request deadline")
    }
    let request = request.unwrap_or(Json::null())
    if text(field(request, "op")) == Some("watch") {
      guard self.parts.sync is Some(sync) else { fail("relay directory is not available") }
      let scope = text(field(request, "scope")).unwrap_or("")
      ignore(self.answer({ "op": "resume", "scope": Json::string(scope) }, (conn.remote_id)()))
      watch_relay(sync, scope, (conn.remote_id)(), field(request, "announcement"), s, conn, reader)
      return
    }
    @door.write_line(s, { "ok": self.answer(request, (conn.remote_id)()) })
    (s.finish)()
    ignore(@effect.timeout(10000, async fn() { (conn.closed)() }))
    Ok(())
  } catch {
    e => Err(e)
  }
  match served {
    Ok(_) => ()
    Err(e) => {
      match stream {
        Some(s) if !(conn.is_closed)() => {
          let (words, code) = words_of(e)
          let reply : Map[String, Json] = Map([("error", Json::string(words))])
          match code {
            Some(c) => reply["code"] = Json::string(c)
            None => ()
          }
          // (the relay is to have the reply before the connection closes: it closes it once read, or a second passes)
          ignore(
            @effect.timeout(1000, async fn() {
              @door.write_line(s, Json::object(reply))
              (s.finish)()
            }),
          )
          ignore(@effect.timeout(1000, async fn() { (conn.closed)() }))
        }
        _ => ()
      }
      raise e
    }
  }
}

///|
/// A registered relay's stream to its issuer (relay-watch.ts): the directory written whole each time it changed, what
/// changed while a slow relay read the last folded into the next; the relay's address announcements taken as it sends
/// them. A revocation closes the connection at once.
pub async fn watch_relay(
  sync : ScopeSync,
  scope : String,
  node : String,
  first : Json,
  stream : @door.Stream,
  conn : @door.Connection,
  reader : @door.Reader,
) -> Unit {
  sync.relay_announcement(scope, node, first)
  let dirty = Ref(true)
  let ended = Ref(false)
  let wake : Ref[@effect.Deferred[Unit]?] = Ref(None)
  let poke = () => match wake.val {
    Some(d) => ignore(d.succeed(()))
    None => ()
  }
  let off = sync.listen(changed => {
    if changed != scope || ended.val {
      return
    }
    ignore(sync.relay_view(scope, node)) catch {
      _ => (conn.close)(1, "relay registration removed")
    }
    dirty.val = true
    poke()
  })
  defer {
    ended.val = true
    poke()
    off()
    (conn.close)(0, "relay directory ended")
  }
  let write = async fn(frame : Json) {
    guard @effect.timeout(15000, async fn() { @door.write_line(stream, frame) }) is Some(_) else {
      fail("relay directory consumer stalled")
    }
  }
  let sending = async fn() {
    let mut revision = 0
    while !ended.val {
      if !dirty.val {
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        wake.val = Some(d)
        d.wait()
        wake.val = None
        continue
      }
      dirty.val = false
      let view = sync.relay_view(scope, node)
      revision += 1
      let records = match field(view, "records") {
        Array(r) => r
        _ => []
      }
      let head : Map[String, Json] = Map([("begin", Json::number(revision.to_double()))])
      match view {
        Object(m) =>
          for k, v in m {
            if k != "records" {
              head[k] = v
            }
          }
        _ => ()
      }
      head["count"] = Json::number(records.length().to_double())
      write(Json::object(head))
      for record in records {
        write({ "record": record })
      }
      write({ "end": Json::number(revision.to_double()) })
    }
  }
  let receiving = async fn() {
    while !ended.val {
      let update = reader.line()
      guard update is Some(Object(_) as u) && field(u, "announcement") is Object(_) else {
        fail("invalid relay address update")
      }
      sync.relay_announcement(scope, node, field(u, "announcement"))
    }
  }
  @effect.race(sending, async fn() {
    @effect.race(receiving, async fn() { ignore((conn.closed)()) })
  })
}
