// A member's device in its workspace's scope (leaf.ts `LeafAttachments`): only on the connection it was let in on,
// while its credential holds, never a forwarder; the endpoint (the front) keeps each attachment across handovers.

///|
/// What a leaf asks of the endpoint: attached on a connection the front holds (its id), detached.
pub(all) struct LeafEndpoint {
  id : String
  attach : async (Int?, Json) -> Json
  detach : async (Json) -> Unit
}

///|
priv struct Admitted {
  conn : @door.Connection
  workspace : String
  expires : Int64
}

///|
priv struct Follower {
  conn : @door.Connection
  wake : () -> Unit
}

///|
pub struct Leaves {
  endpoint : LeafEndpoint
  sync : ScopeSync
  priv members : Array[Admitted]
  priv followers : Array[Follower]
}

///|
pub fn Leaves::new(endpoint : LeafEndpoint, sync : ScopeSync) -> Leaves {
  { endpoint, sync, members: [], followers: [] }
}

///|
fn Leaves::admitted(self : Leaves, conn : @door.Connection) -> Admitted? {
  self.members.iter().find_first(a => physical_equal(a.conn, conn))
}

///|
/// A member's connection let in (or its credential renewed) for `workspace` until `expires` (unix seconds).
pub fn Leaves::authenticated(self : Leaves, conn : @door.Connection, workspace : String, expires : Int64) -> Unit {
  // (those of connections gone let go first)
  let kept = self.members.filter(a => !(a.conn.is_closed)() && !physical_equal(a.conn, conn))
  self.members.clear()
  self.members.append(kept)
  self.members.push({ conn, workspace, expires })
  for f in self.followers {
    if physical_equal(f.conn, conn) {
      (f.wake)()
    }
  }
}

///|
/// What a member's device is given of its workspace's scope (`view`).
pub fn Leaves::view(self : Leaves, workspace : String) -> Json raise {
  let cloud = self.sync.parts.cloud
  guard (cloud.origin)() is Some(origin) && (cloud.membership)(workspace) is Some(_) else {
    fail("leaf workspace removed")
  }
  let scope = workspace_scope(self.sync.crypto, origin, workspace)
  let policy = self.sync.directory.policy(scope)
  let peers = self.sync.directory
    .records(scope)
    .map(a => field((try { @json.parse(text(field(a, "body")).unwrap_or("")) } catch { _ => Json::null() }), "descriptor"))
  {
    "scope": Json::string(scope),
    "transit": Json::boolean(false),
    "peers": Json::array(peers),
    "relayUrls": field(policy, "relayUrls"),
    "globalRelays": field(policy, "globalRelays"),
    "stations": field(policy, "nodes"),
  }
}

///|
/// The scope's view written each time it changes, a line each, while the stream and connection last (`follow`).
pub async fn Leaves::follow(self : Leaves, conn : @door.Connection, workspace : String, stream : @door.Stream) -> Unit {
  let changed = Ref(true)
  let ended = Ref(false)
  let waiting : Ref[@effect.Deferred[Unit]?] = Ref(None)
  let wake = () => {
    changed.val = true
    match waiting.val {
      Some(d) => ignore(d.succeed(()))
      None => ()
    }
  }
  let follower : Follower = { conn, wake }
  self.followers.push(follower)
  let scope = text(field(self.view(workspace), "scope")).unwrap_or("")
  let off = self.sync.listen(s => if s == scope { wake() })
  ignore(
    self.sync.rt.fork(name="leaf stopped", async fn() {
      ignore((stream.stopped)()) catch {
        _ => ()
      }
      ended.val = true
      wake()
    }),
  )
  defer {
    off()
    match self.followers.search_by(f => physical_equal(f, follower)) {
      Some(i) => ignore(self.followers.remove(i))
      None => ()
    }
    (stream.finish)() catch {
      _ => ()
    }
  }
  while !ended.val && !(conn.is_closed)() {
    if !changed.val {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      waiting.val = Some(d)
      d.wait()
      waiting.val = None
    }
    if ended.val || (conn.is_closed)() {
      break
    }
    changed.val = false
    let view = match self.view(workspace) {
      Object(m) => m.copy()
      _ => Map([])
    }
    let expires = match self.admitted(conn) {
      Some(a) => a.expires
      None => 0L
    }
    view["credentialExpiresUnixMs"] = int_json(expires * 1000L)
    (stream.write)(utf8(Json::object(view).stringify() + "\n"))
  }
}

///|
/// The device's own binding (`raw`) attached for `target` (this station or one of its workspace's): {attachment,
/// config} (`attach`). Its admission is looked at again once the endpoint has it: changed meanwhile, it is detached.
pub async fn Leaves::attach(self : Leaves, conn : @door.Connection, workspace : String, raw : Json, target : String) -> Json {
  let cloud = self.sync.parts.cloud
  let member = self.admitted(conn)
  let membership = (cloud.membership)(workspace)
  guard member is Some(m) && m.workspace == workspace && membership is Some(ms) && !(conn.is_closed)() else {
    fail("leaf member connection ended")
  }
  let is_station = (ms : @cloud_net.Membership) => ms.peers.iter().any(p => text(field(p, "id")) == Some(target))
  guard target == self.endpoint.id || is_station(ms) else { fail("leaf target is not a workspace station") }
  let config = self.view(workspace)
  let scope = text(field(config, "scope")).unwrap_or("")
  let descriptor = descriptor_of(self.sync.crypto, raw, scope, (conn.remote_id)())
  guard !(field(field(descriptor, "binding"), "transit") is True) else { fail("a device cannot provide transit") }
  let attachment = (self.endpoint.attach)(conn.handed, {
    "scope": Json::string(scope),
    "descriptor": descriptor,
    "target": Json::string(target),
    "expiresUnixMs": int_json(m.expires * 1000L),
  })
  let still = try {
    let latest = (cloud.membership)(workspace)
    let current = self.view(workspace)
    let issuer = match field(current, "peers") {
      Array(ps) =>
        ps
        .iter()
        .find_first(p => match field(field(p, "binding"), "endpoint") {
          Array(_) as e => hex_of_json_bytes(e) == self.endpoint.id
          _ => false
        })
        .map(p => field(p, "binding"))
      _ => None
    }
    let given = field(attachment, "issuer")
    let same_issuer = match issuer {
      Some(i) =>
        safe_int(field(i, "generation")) == safe_int(field(given, "generation")) &&
        Json::array([field(i, "policy"), field(i, "neighbor")]).stringify() ==
        Json::array([field(given, "policy"), field(given, "neighbor")]).stringify()
      None => false
    }
    let policy_of = (j : Json) => Json::array([field(j, "scope"), field(j, "relayUrls"), field(j, "globalRelays")]).stringify()
    let ok = !(conn.is_closed)() &&
      (match self.admitted(conn) {
        Some(a) => physical_equal(a, m)
        None => false
      }) &&
      (match latest {
        Some(l) => target == self.endpoint.id || is_station(l)
        None => false
      }) &&
      policy_of(current) == policy_of(config) &&
      same_issuer
    if !ok {
      fail("leaf admission changed")
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  match still {
    Ok(_) => { "attachment": attachment, "config": config }
    Err(e) => {
      (self.endpoint.detach)({ "scope": Json::string(scope), "attachmentId": field(attachment, "id") })
      raise e
    }
  }
}

///|
fn hex_of_json_bytes(j : Json) -> String {
  match j {
    Array(xs) => {
      let out : Array[Byte] = []
      for x in xs {
        out.push(safe_int(x).unwrap_or(0L).to_byte())
      }
      hex_of(Bytes::from_array(out))
    }
    _ => ""
  }
}
