// The station's iroh endpoint, kept here for the station's Node (station/src/mesh/front.ts) across its handovers: one
// endpoint bound once, the connections and streams on it the Node's that took or made them, the bytes of each stream
// carried by the shell between iroh and a socket of the Node's (`istream.pipe`), none of them through this program.
//
// The Node asks on a Unix socket of this program's (`mesh`'s `path`), a JSON object a line both ways: `{id, op, …}`
// asked, `{id, ok}` or `{id, error}` answered, each as it is done (an `accept` waits for a connection, a `closed` for
// its end). It first says `bind` with where its own Unix socket is (`streams`): each stream it is given comes there,
// a socket of its own whose first 17 bytes say the connection's id and the stream's (8 each, big-endian) and whether
// the Node asked for it (1) or the other end opened it (0), its frames after (client/shell's `istream.pipe`). Those the
// other end opens are taken here as they come and given at once, no ask of the Node's between them. Connections coming go to the Node that bound last (the one taking over, in a handover), or wait for
// one, and are its once it takes them (`accept`, its routes said by then); those a Node has are closed when it closes
// the endpoint or its socket ends (it stopped, or died), and each is let go at the shell once it is no Node's.

///|
/// A Node asking (one of its sockets to this program).
priv struct Client {
  conn : Conn
  /// Its order of binding: the last to bind is given what comes.
  mut bound : Int
  /// Where its streams go (its Unix socket).
  mut streams : String
  /// The requests of `routes` ("GET /admin/api/chats") go to `front`'s sockets instead (`route`: answered there,
  /// station/src/mesh/served.ts), on the connections given it from then on.
  mut front : Json
  mut routes : Json
  /// Of the connections of this protocol only (its hex).
  mut alpn : Json
  /// What came for it and it has not taken yet.
  coming : @effect.Queue[Json]
  /// The connections it has, by their ids at the shell.
  conns : Map[String, Json]
  /// The calls it can give up (`giveUp`), by its ids: the shell's ids of them.
  calls : Map[String, Int64]
  mut gone : Bool
}

///|
/// The endpoint and the Nodes asking.
priv struct Mesh {
  host : @host.Host
  /// The endpoint at the shell, and what of its binding cannot change on it (`identity_of`): a `bind` of the same is
  /// given it as it is, another binds anew.
  mut endpoint : Json?
  mut identity : String
  /// The secret key's hex the endpoint bound now holds ("" before the first): the station's own, which no Node of
  /// another key takes from it (`foreign_key_bind`).
  mut bound_key : String
  /// Its relays and its congestion controller as they are on it: as the last bind named them, then as a Node's own
  /// `insertRelay`, `removeRelay` and `setCongestion` changed them. What a later bind changes in place.
  mut bound_relays : Array[String]
  mut bound_congestion : String
  mut bound_alpns : String
  mut said : Json
  /// What came while no Node had bound.
  waiting : Array[Json]
  clients : Array[Client]
  mut binds : Int
  /// Serialises `bind` and the changes to `bound_relays` and `bound_congestion` reconciled there, so two Nodes binding
  /// a fresh front side by side (a handover's new Node and the old Node's `#watch` linking again) never both run
  /// `iroh.bind` and leave an unclosed endpoint of the same key on the relays.
  bind_lock : @effect.Semaphore
  /// What is done once the endpoint bound now gives no more connections (`accepting`): by default the program ends, so
  /// the launcher starts another front (front.rs) and the Nodes bind it anew.
  on_accept_end : () -> Unit
}

///|
/// At most this many connections wait for a Node to bind (each a device that dialed meanwhile); the oldest closed.
let waiting_most : Int = 256

///|
/// Serves the mesh on the Unix socket at `path`, until it fails.
pub async fn mesh(host : @host.Host, path : String) -> Unit {
  let listening = host.unix_listen(path)
  let mesh : Mesh = {
    host,
    endpoint: None,
    identity: "",
    bound_relays: [],
    bound_congestion: default_congestion,
    bound_alpns: "",
    bound_key: "",
    said: Json::null(),
    waiting: [],
    clients: [],
    binds: 0,
    bind_lock: @effect.Semaphore::new(1),
    on_accept_end: () => @host.exit(1),
  }
  // `streams`: how it hands Node the streams the other end opens and what it does (front.rs `STREAMS`): 5, each with
  // its index, a route Node gave it (`route`, a segment `*` any one) to what answers it, and the mesh's scopes and
  // leaves (`meshConfigure`, `meshRemove`, `meshAttachLeaf`, `meshDetachLeaf`).
  host.say(({ "listening": Json::string(path), "streams": 5 } : Json).stringify())
  // Its stdin is the launcher's: ended (the launcher gone, or stopping the station), the endpoint goes with it.
  ignore(
    host.rt.fork_daemon("mesh parent", on_error=e => @host.note("mesh parent failed: \{e}"), () => {
      while host.line() is Some(_) {
        ()
      }
      @host.exit(0)
    }),
  )
  // (a failed accept tried again after 100 ms, one that says the listening socket is gone ending it; what serving a
  // Node fails with noted, never a defect)
  host
  .listener_of(listening.id)
  .serve(
    host.rt.root(),
    async fn(accepted) {
      let client : Client = {
        conn: { host, id: accepted.id },
        bound: 0,
        streams: "",
        front: Json::array([]),
        routes: Json::array([]),
        alpn: Json::null(),
        coming: @effect.Queue::unbounded(),
        conns: Map([]),
        calls: Map([]),
        gone: false,
      }
      mesh.clients.push(client)
      mesh.serve(client) catch {
        e => @host.note("mesh: a Node's socket failed: \{message(e)}")
      }
    },
    on_error=e => @host.note("mesh: accept failed: \{message(e)}"),
  )
}

///|
/// A Node's asks, each answered as it is done, till its socket ends.
async fn Mesh::serve(self : Mesh, client : Client) -> Unit {
  let lines = @wire.Lines::new()
  while true {
    let read = try { Ok(self.host.tcp_read(client.conn.id)) } catch { e => Err(e) }
    guard read is Ok(Some(bytes)) else { break }
    for line in lines.push(bytes[:]) {
      let asked = @json.parse(line) catch { _ => continue }
      ignore(
        self.host.rt.fork_daemon("mesh ask", () => self.answer(client, asked), on_error=e => @host.note("mesh: an ask failed: \{message(e)}")),
      )
    }
  }
  self.part(client)
  client.conn.close()
}

///|
/// A Node no longer asking (its socket ended, or it closed the endpoint): its connections closed, what came for it and it
/// did not take given to another.
async fn Mesh::part(self : Mesh, client : Client) -> Unit {
  if client.gone {
    return
  }
  client.gone = true
  if self.endpoint is Some(endpoint) {
    ignore(self.host.shell("iroh.meshUnsubscribe", { "id": endpoint, "socket": client.conn.id })) catch { _ => () }
  }
  client.bound = 0
  let left = []
  while client.coming.try_take() is Some(c) {
    left.push(c)
  }
  client.coming.shutdown()
  for _, conn in client.conns {
    self.forget(conn, "station stopping")
  }
  client.conns.clear()
  let at = self.clients.search_by(c => physical_equal(c, client))
  if at is Some(i) {
    ignore(self.clients.remove(i))
  }
  for c in left {
    self.give(c)
  }
}

///|
/// Connection `conn` closed (where it was not) and let go at the shell entirely (`forget`): a connection is never left
/// there once no Node has it, or the shell would keep what it knows of it as long as this program runs.
async fn Mesh::forget(self : Mesh, conn : Json, reason : String) -> Unit {
  ignore(
    self.host.shell("conn.close", { "id": conn, "code": 0, "reason": Json::string(reason), "forget": true }),
  ) catch {
    _ => ()
  }
}

///|
/// What came, given to the Node that bound last, or kept till one does. It is that Node's only once it takes it
/// (`accept`): by then it said its routes (`route`), which the streams the other end opens go by, and one that parts
/// before it takes it leaves it to another.
fn Mesh::give(self : Mesh, conn : Json) -> Unit {
  let mut to : Client? = None
  for c in self.clients {
    if !c.gone && c.bound > 0 && (to is None || c.bound > to.unwrap().bound) {
      to = Some(c)
    }
  }
  match to {
    Some(c) => ignore(c.coming.try_offer(conn))
    None => {
      if self.waiting.length() >= waiting_most {
        if self.waiting.remove(0) is { "conn": id, .. } {
          ignore(self.host.rt.fork_quiet(name="mesh drop", () => self.forget(id, "station starting")))
        }
      }
      self.waiting.push(conn)
    }
  }
}

///|
/// What is known of a connection at once: its other end, its protocol, how it runs and what went over it.
fn Mesh::seen(self : Mesh, id : Json) -> Json raise {
  {
    "conn": id,
    "remote": self.host.shell_sync("conn.remoteId", { "id": id }),
    "alpn": self.host.shell_sync("conn.alpn", { "id": id }),
    "via": self.host.shell_sync("conn.via", { "id": id }),
    "paths": self.host.shell_sync("conn.paths", { "id": id }),
    "stats": self.host.shell_sync("conn.stats", { "id": id }),
  }
}

///|
/// The connections coming to `endpoint`, each given a Node, till it closes. Where it is still the endpoint bound when
/// it gives no more (its driver ended), nothing comes to this station again while the Nodes go on asking of it and its
/// relays look well: so this program ends (`on_accept_end`) for the launcher to start another. One let go after another
/// was bound in its place ends quietly.
async fn Mesh::accepting(self : Mesh, endpoint : Json) -> Unit {
  self.accepted(endpoint)
  if accept_ended_unbidden(self.endpoint, endpoint) {
    @host.note("mesh endpoint accept ended; exiting front")
    (self.on_accept_end)()
  }
}

///|
/// Whether an endpoint that gives no more connections ended unbidden: it is the one bound now, not one let go after
/// another was bound in its place (`Mesh::bind`).
fn accept_ended_unbidden(bound : Json?, endpoint : Json) -> Bool {
  bound is Some(e) && e == endpoint
}

///|
/// The connections coming to `endpoint`, each given a Node, till it gives no more.
async fn Mesh::accepted(self : Mesh, endpoint : Json) -> Unit {
  while true {
    // (an endpoint let go after another was bound in its place is no handle any more: its end)
    let (got, _) = self.host.shell("iroh.accept", { "id": endpoint }) catch {
      _ => return
    }
    guard got is { "id": id, .. } else { return }
    let seen = self.seen(id) catch {
      _ => {
        // (gone as it came: let go, or the shell keeps it)
        ignore(self.host.rt.fork_quiet(name="mesh drop", () => self.forget(id, "")))
        continue
      }
    }
    self.give(seen)
  }
}

///|
/// The congestion controller an endpoint is bound with where its options name none (the shell's `transport`).
let default_congestion : String = "cubic"

///|
/// Field `k` of an object, null where there is none.
fn field(o : Json, k : String) -> Json {
  match o {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// What of a binding cannot change on an endpoint bound already: its key, whether it finds and is found, its address,
/// whether it goes by relays alone and the DSCP its packets are marked with (`dscp`, set by the shell's `iroh.bind`
/// alone). Its relays, its congestion controller and its protocols can (`Mesh::bind`): a Node that takes another set
/// of protocols (a release that adds one, the MoonBit station's and Node's) is not given an endpoint of its own beside
/// the one there, whose closing refused every connection that came to it meanwhile (2026-11-18, Office-Host-2 as
/// 0.1.10002 took over from 0.1.9996).
fn identity_of(options : Json, key : Bytes) -> String {
  let parts : Array[Json] = [
    Json::string(hex(key)),
    field(options, "discovery"),
    field(options, "bindAddr"),
    field(options, "relayOnly"),
    field(options, "dscp"),
  ]
  Json::array(parts).stringify()
}

///|
/// The relays a binding names (`relayUrls`).
fn relays_of(options : Json) -> Array[String] {
  let out = []
  if field(options, "relayUrls") is Array(urls) {
    for u in urls {
      if u is String(url) {
        out.push(url)
      }
    }
  }
  out
}

///|
/// Whether `url` is among `urls`, a trailing slash or not.
fn has_relay(urls : Array[String], url : String) -> Bool {
  urls.iter().any(u => bare_url(u) == bare_url(url))
}

///|
fn bare_url(url : String) -> String {
  let mut end = url.length()
  while end > 0 && url[end - 1] == '/' {
    end = end - 1
  }
  url[:end].to_string()
}

///|
/// The congestion controller a binding names, or the shell's own.
fn congestion_of(options : Json) -> String {
  match field(options, "congestion") {
    String(c) if c != "" => c
    _ => default_congestion
  }
}

///|
/// Whether a binding names a fixed port (`bindAddr`'s, not 0): one endpoint at a time can hold it.
fn fixed_port(options : Json) -> Bool {
  guard field(options, "bindAddr") is String(addr) else { return false }
  guard addr.rev_find(":") is Some(at) else { return false }
  let mut n = 0
  for c in addr[at + 1:] {
    guard c >= '0' && c <= '9' else { return false }
    n = n * 10 + (c.to_int() - '0'.to_int())
    if n > 0 {
      return true
    }
  }
  false
}

///|
/// The endpoint bound as `options` say (`key` its secret key's hex). One bound already with the same identity
/// (`identity_of`) is kept as it is, its connections with it: the next Node of a handover binds with the relays and
/// the congestion controller the station has now, which a running station changes on its endpoint as they change
/// (relays.ts, mesh.ts `applyNetwork`), so those are changed on it in place, never by binding anew. Another identity
/// (the same key, its discovery, address, relays alone or DSCP changed) binds anew, the old endpoint let go at the
/// shell entirely: after the new one is bound, so a bind that fails leaves the old as it was, unless a fixed port says
/// only one of them can hold it. A bind with another key is refused while an endpoint is bound (`foreign_key_bind`):
/// a front is its station's, and a process that found its socket by the environment it inherited (a test an agent
/// ran, with a key of its own) would otherwise close the station's endpoint and take it off the mesh.
async fn Mesh::bind(self : Mesh, options : Json, key : Bytes) -> Json {
  let key_hex = hex(key)
  if foreign_key_bind(self.endpoint, self.bound_key, key_hex) {
    @host.note("mesh: refused bind for another key")
    fail("another station's key: front already holds an endpoint")
  }
  let identity = identity_of(options, key)
  if self.endpoint is Some(endpoint) && self.identity == identity {
    let relays = relays_of(options)
    for url in relays {
      if !has_relay(self.bound_relays, url) {
        match (try { Ok(self.host.shell("iroh.insertRelay", { "id": endpoint, "url": Json::string(url) })) } catch { e => Err(e) }) {
          Ok(_) => @host.note("mesh: relay \{url} added as a Node bound")
          Err(e) => @host.note("mesh: relay \{url} not added: \{message(e)}")
        }
      }
    }
    for url in self.bound_relays {
      if !has_relay(relays, url) {
        match (try { Ok(self.host.shell("iroh.removeRelay", { "id": endpoint, "url": Json::string(url) })) } catch { e => Err(e) }) {
          Ok(_) => @host.note("mesh: relay \{url} removed as a Node bound")
          Err(e) => @host.note("mesh: relay \{url} not removed: \{message(e)}")
        }
      }
    }
    self.bound_relays = relays
    let congestion = congestion_of(options)
    if congestion != self.bound_congestion {
      ignore(self.host.shell("iroh.setCongestion", { "id": endpoint, "congestion": Json::string(congestion) })) catch {
        e => @host.note("mesh: congestion controller not changed: \{message(e)}")
      }
      self.bound_congestion = congestion
    }
    let alpns = field(options, "alpns").stringify()
    if alpns != self.bound_alpns {
      match (try { Ok(self.host.shell("iroh.setAlpns", { "id": endpoint, "alpns": field(options, "alpns") })) } catch { e => Err(e) }) {
        Ok(_) => self.bound_alpns = alpns
        Err(e) => @host.note("mesh: protocols not changed: \{message(e)}")
      }
    }
    return self.said
  }
  let mut old = self.endpoint
  if old is Some(o) && fixed_port(options) {
    self.endpoint = None
    old = None
    self.let_go(o)
  }
  let (bound, _) = self.host.shell("iroh.bind", options, bytes=key)
  guard bound is { "id": endpoint, .. } else { fail("the shell bound no endpoint") }
  // (the new one bound before the old is let go: the old one's accepting, ending as it goes, finds it replaced)
  self.endpoint = Some(endpoint)
  if old is Some(o) {
    self.let_go(o)
  }
  self.identity = identity
  self.bound_key = key_hex
  self.bound_relays = relays_of(options)
  self.bound_congestion = congestion_of(options)
  self.bound_alpns = field(options, "alpns").stringify()
  self.said = {
    "id": self.host.shell_sync("iroh.endpointId", { "id": endpoint }),
    "sockets": self.host.shell_sync("iroh.sockets", { "id": endpoint }),
  }
  ignore(self.host.rt.fork_daemon("mesh accept", on_error=e => @host.note("mesh accept failed: \{e}"), () => self.accepting(endpoint)))
  self.said
}

///|
/// Whether a bind with `key` (its hex) would take the endpoint bound now (`bound`, of `bound_key`) from the key that
/// holds it: refused, the endpoint neither replaced nor let go.
fn foreign_key_bind(bound : Json?, bound_key : String, key : String) -> Bool {
  bound is Some(_) && bound_key != "" && bound_key != key
}

///|
/// An endpoint another was bound in place of, closed and let go at the shell entirely (`forget`).
async fn Mesh::let_go(self : Mesh, endpoint : Json) -> Unit {
  ignore(self.host.shell("iroh.close", { "id": endpoint, "forget": true })) catch {
    _ => ()
  }
}

///|
/// The streams the other end of connection `conn` opens, each given to `client` as it comes by the shell itself
/// (`conn.hand`: its head the ids, a 2 and the stream's index), till the connection is gone.
fn Mesh::taking(self : Mesh, client : Client, conn : Json, alpn : Json) -> Unit {
  ignore(
    self.host.rt.fork_daemon("mesh streams", on_error=e => @host.note("mesh streams failed: \{e}"), () => {
      let routed = alpn == client.alpn
      let asked : Json = {
        "id": conn,
        "path": Json::string(client.streams),
        "front": if routed { client.front } else { Json::array([]) },
        "routes": if routed { client.routes } else { Json::array([]) },
      }
      ignore(self.host.shell("conn.hand", asked)) catch {
        _ => ()
      }
      client.conns.remove(conn.stringify())
    }),
  )
}

///|
/// A stream this program opened (`id`, on connection `conn`) given to `client`: a socket of its own to it, the ids and a
/// 1 first, carried from then on by the shell (`istream.hand`). Told once it is under way.
fn Mesh::hand(self : Mesh, client : Client, conn : Json, id : Json) -> Unit {
  let head = FixedArray::make(17, b'\x00')
  for k, v in [conn, id] {
    let n = match v {
      Number(n, ..) => n.to_int64()
      _ => 0L
    }
    for i = 0; i < 8; i = i + 1 {
      head[8 * k + i] = ((n >> (8 * (7 - i))) & 0xFFL).to_byte()
    }
  }
  head[16] = b'\x01'
  ignore(
    self.host.rt.fork_quiet(name="mesh stream", () => {
      ignore(
        self.host.shell("istream.hand", { "id": id, "path": Json::string(client.streams) }, bytes=Bytes::from_array(head)),
      ) catch {
        _ => ()
      }
    }),
  )
}

///|
/// The endpoint, or a refusal while none is bound.
fn Mesh::bound(self : Mesh) -> Json raise {
  match self.endpoint {
    Some(e) => e
    None => fail("no endpoint bound")
  }
}

///|
/// One ask answered.
async fn Mesh::answer(self : Mesh, client : Client, asked : Json) -> Unit {
  guard asked is { "id": ask, "op": String(op), .. } else { return }
  let arg = (k : String) => match asked {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
  let done = try {
    Ok(self.act(client, ask, op, arg))
  } catch {
    @wire.ShellError(m) => Err(m)
    e => Err(e.to_string())
  }
  client.calls.remove(ask.stringify())
  let line : Json = match done {
    Ok(ok) => { "id": ask, "ok": ok }
    Err(m) => { "id": ask, "error": Json::string(m) }
  }
  // (a Node that closed the endpoint is told it is closed, then nothing more)
  if !client.gone || op == "close" {
    self.host.tcp_write(client.conn.id, @utf8.encode(line.stringify() + "\n")) catch {
      _ => ()
    }
  }
}

///|
async fn Mesh::act(self : Mesh, client : Client, ask : Json, op : String, arg : (String) -> Json) -> Json {
  match op {
    "bind" => {
      guard arg("streams") is String(streams) else { fail("no streams") }
      guard arg("key") is String(key) else { fail("no key") }
      let options = arg("options")
      guard options is Object(_) else { fail("no options") }
      let key_bytes = unhex(key)
      self.bind_lock.with_permit(() => {
        // (a Node gone while it waited here binds nothing, nor is it given what comes)
        if client.gone {
          fail("the endpoint is closed")
        }
        let said = self.bind(options, key_bytes)
        if client.gone {
          fail("the endpoint is closed")
        }
        if self.endpoint is Some(endpoint) {
          ignore(self.host.shell("iroh.meshSubscribe", { "id": endpoint, "socket": client.conn.id }))
          if client.gone {
            ignore(self.host.shell("iroh.meshUnsubscribe", { "id": endpoint, "socket": client.conn.id })) catch {
              _ => ()
            }
            fail("the endpoint is closed")
          }
        }
        // (nothing waits from here on: one gone by now has not parted yet, and its part undoes this)
        client.streams = streams
        self.binds += 1
        client.bound = self.binds
        let waited = self.waiting.copy()
        self.waiting.clear()
        for c in waited {
          self.give(c)
        }
        said
      })
    }
    "route" => {
      client.front = arg("front")
      client.routes = arg("routes")
      client.alpn = arg("alpn")
      Json::null()
    }
    "accept" => {
      let next = try { Ok(client.coming.take()) } catch { e => Err(e) }
      match next {
        Ok(conn) => {
          if client.gone {
            // (it parted as this was taken: another Node's)
            self.give(conn)
            return { "end": true }
          }
          // Its now, with the routes it said by now (`route`, said before it accepts).
          if conn is { "conn": id, .. } {
            client.conns[id.stringify()] = id
            self.taking(client, id, conn.value("alpn").unwrap_or(Json::null()))
          }
          conn
        }
        Err(_) => { "end": true }
      }
    }
    "close" => {
      self.part(client)
      Json::null()
    }
    "connect" => {
      guard arg("alpn") is String(alpn) else { fail("no alpn") }
      let endpoint = self.bound()
      let (made, _) = self.host.shell(
        "iroh.connect",
        { "id": endpoint, "addr": arg("addr"), "additional": arg("additional") },
        bytes=unhex(alpn),
        called=id => client.calls[ask.stringify()] = id,
      )
      guard made is { "id": id, .. } else { fail("no connection") }
      if client.gone {
        self.forget(id, "station stopping")
        fail("the endpoint is closed")
      }
      let seen = self.seen(id) catch {
        e => {
          // (gone as it was made: let go, or the shell keeps it)
          self.forget(id, "")
          raise e
        }
      }
      client.conns[id.stringify()] = id
      self.taking(client, id, seen.value("alpn").unwrap_or(Json::null()))
      seen
    }
    "giveUp" => {
      match client.calls.get(arg("of").stringify()) {
        Some(call) => ignore(self.host.shell_sync("fetch.cancel", { "id": Json::number(call.to_double()) }))
        None => ()
      }
      Json::null()
    }
    "openBi" | "openUni" => {
      let conn = arg("conn")
      let (got, _) = self.host.shell("conn." + op, { "id": conn })
      match got {
        { "id": id, .. } => {
          self.hand(client, conn, id)
          { "stream": id }
        }
        _ => { "end": true }
      }
    }
    "stopped" => self.host.shell("istream.stopped", { "id": arg("stream") }).0
    "reset" => self.host.shell("istream.reset", { "id": arg("stream"), "code": arg("code") }).0
    // A view's frames as datagrams from now on (client/shell `istream.mediaDatagrams`): asked by the Node before its
    // reply's head goes (front.ts `FrontStream.mediaDatagrams`).
    "mediaDatagrams" => self.host.shell("istream.mediaDatagrams", { "id": arg("stream"), "token": arg("token") }).0
    "conn.close" => {
      let conn = arg("conn")
      client.conns.remove(conn.stringify())
      // (one let go already, its end told: `conn.closed`)
      self.host.shell("conn.close", { "id": conn, "code": arg("code"), "reason": arg("reason") }).0 catch {
        @wire.ShellError(m) if m.has_prefix("no handle ") => {}
        e => raise e
      }
    }
    // The Node asks this of each connection it has and, told, asks nothing more of it (front.ts `FrontConnection`):
    // let go at the shell then, or it keeps what it knows of the connection as long as this program runs.
    "conn.closed" => {
      let conn = arg("conn")
      let said = self.host.shell("conn.closed", { "id": conn }).0
      client.conns.remove(conn.stringify())
      self.forget(conn, "")
      said
    }
    "conn.answers" => self.host.shell("conn.answers", { "id": arg("conn"), "within": arg("within") }).0
    "conn.seen" => self.seen(arg("conn"))
    // (what is on the endpoint now, which the next bind is reconciled with: one bind's reconciling at a time)
    "insertRelay" | "removeRelay" | "setCongestion" =>
      self.bind_lock.with_permit(() => {
        let args = match asked_args(arg) {
          Object(m) => {
            m["id"] = self.bound()
            Json::object(m)
          }
          _ => { "id": self.bound() }
        }
        let said = self.host.shell("iroh." + op, args).0
        match (op, field(args, "congestion"), field(args, "url")) {
          ("setCongestion", String(c), _) => self.bound_congestion = c
          ("insertRelay", _, String(url)) =>
            if !has_relay(self.bound_relays, url) {
              self.bound_relays.push(url)
            }
          ("removeRelay", _, String(url)) =>
            self.bound_relays = self.bound_relays.filter(u => bare_url(u) != bare_url(url))
          _ => ()
        }
        said
      })
    // (not under `bind_lock`: `online` waits up to 15 s for a relay, and `probeRelay` up to 20 s for its probe, which a
    // bind must not wait behind)
    "online" | "publicRelays" | "keep" | "holdIncoming" | "setRelayEntries" | "networkChange" | "disabledRelays" | "probeRelay" | "meshConfigure" | "meshRemove" | "meshAttachLeaf" | "meshDetachLeaf" => {
      let args = match asked_args(arg) {
        Object(m) => {
          m["id"] = self.bound()
          Json::object(m)
        }
        _ => { "id": self.bound() }
      }
      self.host.shell("iroh." + op, args).0
    }
    "addAddr" => self.host.shell_sync("iroh.addAddr", { "id": self.bound(), "addr": arg("addr") })
    "relayStatus" => self.host.shell_sync("iroh.relayStatus", { "id": self.bound() })
    _ => fail("no operation \{op}")
  }
}

///|
/// An ask's own arguments (`args`), as the shell takes them.
fn asked_args(arg : (String) -> Json) -> Json {
  match arg("args") {
    Object(m) => Json::object(m.copy())
    _ => Json::object(Map([]))
  }
}

///|
fn hex(b : Bytes) -> String {
  @codec.hex_encode(b)
}

///|
fn unhex(s : String) -> Bytes {
  let nibble = (c : Int) => @codec.hex_digit(c).unwrap_or(0)
  let out = FixedArray::make(s.length() / 2, b'\x00')
  for i = 0; i < out.length(); i = i + 1 {
    out[i] = (nibble(s[2 * i].to_int()) * 16 + nibble(s[2 * i + 1].to_int())).to_byte()
  }
  Bytes::from_array(out)
}
