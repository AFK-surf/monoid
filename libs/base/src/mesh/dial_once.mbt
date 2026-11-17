// A connection dialled to a peer on a protocol of its program's, once, on an endpoint of its own bound for it alone
// with a key drawn for it (`Mesh::dial_once`): the other way of what `Mesh::incoming` takes. Never the device's key,
// nor a relay endpoint's (`pinned_key`): an endpoint on the same relay with the same key as the device's endpoint
// would put that one off the relay, which takes one connection per endpoint id. So the peer sees an id nobody
// knows; what proves the device is its program's to send on it (`Mesh::sign`).

///|
/// A connection this device dialled to a peer on a protocol of its program's (`Mesh::dial_once`), on an endpoint
/// bound for it alone. As `Incoming`, it is never a link: no credential, ping or `links` entry knows it, and its
/// streams, its peer's (`accept`) and its program's (`open`), are waited for in the mesh's fibers, and are its
/// program's to bound.
///
/// What is kept of it: its handle at the shell, its endpoint's, and its place among those dialled, until it is
/// closed here (`close`), its end is told, or the mesh closes; then both are closed to be forgotten
/// (`forget: true`), the endpoint after the connection, and it is let go of.
pub struct Outgoing {
  /// The endpoint id it dialled.
  peer : String
  /// The protocol it was dialled on.
  alpn : String
  priv shell : @shell.Shell
  priv conn : Json
  priv endpoint : Json
  priv gone : @effect.Deferred[Closed]
  /// Its connection and endpoint closed to be forgotten, or being so: nothing is asked of either after.
  priv mut done : Bool
  /// The mesh's fibers: where the waits for its streams run (`accept`, `open`), and its end; and those waits.
  priv fibers : @effect.Scope
  priv accepting : Accepting
}

///|
/// The relays of `base`, then those of `more` that are not among them: in that order, each once.
fn relays_with(base : Array[String], more : Array[String]) -> Array[String] {
  let out = base.copy()
  for relay in more {
    if !out.contains(relay) {
      out.push(relay)
    }
  }
  out
}

///|
/// Where `peer` is dialled straight, as far as this mesh knows: what its program said (`Mesh::add_addr`), then what
/// the peer said of itself on a link in any scope (addrs.mbt), each once; none on an endpoint held to its relays.
fn Mesh::straight_to(self : Mesh, peer : String) -> Array[String] {
  guard !self.options.relay_only else { return [] }
  let out : Array[String] = []
  let add = (ips : Array[String]) => for ip in ips {
    if !out.contains(ip) {
      out.push(ip)
    }
  }
  for known in self.known {
    if known.peer == peer {
      add(known.ips)
    }
  }
  for key, said in self.said {
    if key == peer || key.has_suffix("/" + peer) {
      add(said.lan)
      add(said.tailnet)
    }
  }
  out
}

///|
/// A connection to `peer` (its endpoint id) on `alpn`, a protocol its endpoint takes: dialled on an endpoint bound
/// for it alone, with a key of 32 bytes drawn for it (never the device's: the module's head says why), on the
/// mesh's relays and their entries, then `relays` the caller adds (the peer's, where it is on others), held to
/// relays as the mesh is, looking peers up as it does, and told where the peer is dialled straight as far as the
/// mesh knows (`Mesh::straight_to`).
///
/// As a link's dial: its time, `within` ms, counts from when the endpoint is on a relay (`onto_max_ms` at most),
/// at once where it is given addresses; the handshake is a fiber of the mesh's, given up at the shell
/// (`Shell::give_up`) where this ends first. Fails as closed where the mesh is or closes meanwhile, as no answer
/// where the time runs out, as unreached where the shell says so; failed, or cut, the endpoint bound for it is
/// closed to be forgotten, a connection that came with it, and nothing of it is kept.
pub async fn Mesh::dial_once(
  self : Mesh,
  peer : String,
  alpn : String,
  relays? : Array[String] = [],
  within? : Int = connect_timeout_ms,
) -> Outgoing {
  guard !self.closed else { raise failed("closed") }
  guard is_id(peer) else {
    raise MeshError(code="invalid_params", message="a dial names an endpoint id (64 hex), not \"\{peer}\"", cause="")
  }
  guard alpn != "" else { raise MeshError(code="invalid_params", message="a dial names its protocol", cause="") }
  let shell = self.shell
  let relays = relays_with(self.relays, relays)
  let entries = self.entries.filter(e => relays.contains(e.relay))
  let ips = self.straight_to(peer)
  // What is made here, closed to be forgotten unless handed out: whatever ends this (a failure, the caller cut).
  let endpoint : Ref[Json?] = Ref(None)
  let call : Ref[Int64?] = Ref(None)
  let connection : Ref[Json?] = Ref(None)
  let abandoned = Ref(false)
  let handed = Ref(false)
  defer {
    if !handed.val {
      abandoned.val = true
      if call.val is Some(id) {
        shell.give_up(id)
      }
      if connection.val is Some(conn) {
        shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
      }
      if endpoint.val is Some(endpoint) {
        shell.tell("iroh.close", { "id": endpoint, "forget": true })
      }
    }
  }
  // (the shell binds whoever waits: not cut short, and kept in the step it comes, so the defer above closes it)
  let key = shell.random(32)
  let binding : Binding = { lookup: self.binding.lookup, takes: [], entries: [] }
  @effect.uninterruptible(() => {
    let bound = bind(shell, relays, self.options.relay_only, binding, entries, key)
    endpoint.val = Some(bound)
  })
  guard !self.closed && endpoint.val is Some(bound) else { raise failed("closed") }
  let addr : Map[String, Json] = { "id": Json::string(peer), "relays": strings(relays) }
  if ips.length() > 0 {
    addr["ips"] = strings(ips)
  }
  let addr = Json::object(addr)
  let dialled : @effect.Deferred[Json] = @effect.Deferred::new()
  ignore(
    self.scope.fork(name="mesh dial once", () => {
      guard !abandoned.val else { return }
      let made = attempt(() => shell.call(
        "iroh.connect",
        { "id": bound, "addr": addr },
        bytes=@utf8.encode(alpn),
        called=id => call.val = Some(id),
      ))
      call.val = None
      match made {
        Did({ json: { "id": conn, .. }, .. }) =>
          if abandoned.val {
            shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
          } else {
            connection.val = Some(conn)
            ignore(dialled.succeed(conn))
          }
        Did(_) => ignore(dialled.fail(failed("unreached")))
        Fell(e) => ignore(dialled.fail(unreached(e)))
      }
    }),
  )
  let conn = @effect.race_first(
    () => dialled.wait(),
    () => @effect.race_first(
      () => {
        for waited = 0; ips.length() == 0 && waited < onto_max_ms && !self.on_a_relay(bound); waited = waited + onto_recheck_ms {
          @effect.sleep(onto_recheck_ms)
        }
        @effect.sleep(within)
        raise failed("no_answer")
      },
      // (the mesh closed meanwhile: its close cut the dial's fiber, which says nothing then; it tells `change`)
      () => {
        while !self.closed {
          self.change.wait()
        }
        raise failed("closed")
      },
    ),
  )
  guard !self.closed else { raise failed("closed") }
  let outgoing : Outgoing = {
    peer,
    alpn,
    shell,
    conn,
    endpoint: bound,
    gone: @effect.Deferred::new(),
    done: false,
    fibers: self.scope,
    accepting: Accepting::new(),
  }
  self.outgoings.push(outgoing)
  handed.val = true
  // Its end, waited for once (cut as the mesh closes, which closes every one dialled itself), or its closing here.
  ignore(
    self.scope.fork(name="mesh dialled once", () => {
      let ended = @effect.race_first(
        () => {
          let said = attempt(() => shell.call("conn.closed", { "id": conn }))
          match said {
            Did(answer) => Some(closed_of(answer.json).unwrap_or({ kind: "other", reason: "" }))
            Fell(e) => Some({ kind: "other", reason: text_of(e) })
          }
        },
        () => {
          ignore(outgoing.gone.wait())
          None
        },
      )
      if ended is Some(closed) {
        ignore(outgoing.gone.succeed(closed))
      }
      self.let_go_once(outgoing)
    }),
  )
  outgoing
}

///|
/// Lets go of a connection dialled once whose end is told: a stream nobody took reset, its connection closed to be
/// forgotten (saying the reason it was closed for here, if it was), then its endpoint, each waited for so the peer
/// is told before the endpoint goes. Then it is let go of. Once only; not cut short, as the mesh's close is not.
async fn Mesh::let_go_once(self : Mesh, outgoing : Outgoing) -> Unit {
  guard !outgoing.done else { return }
  outgoing.done = true
  let reason = match (outgoing.gone.poll() catch { _ => None }) {
    Some({ kind: "local", reason }) if reason != "" => reason
    _ => "closed"
  }
  outgoing.accepting.drop_kept(outgoing.shell)
  @effect.uninterruptible(() => {
    ignore(attempt(() => outgoing.shell.call("conn.close", {
      "id": outgoing.conn,
      "code": 0,
      "reason": Json::string(reason),
      "forget": true,
    })))
    ignore(attempt(() => outgoing.shell.call("iroh.close", { "id": outgoing.endpoint, "forget": true })))
  })
  self.outgoings.retain(one => !physical_equal(one, outgoing))
}

///|
/// The next stream its peer opens on it; None once it ended, or the mesh closed. As `Incoming::accept`.
pub async fn Outgoing::accept(self : Outgoing) -> Inbound? {
  accept_on(self.shell, self.conn, self.fibers, self.gone, self.accepting)
}

///|
/// A stream opened on it from this side, to its peer, as `Incoming::open`. Fails as cut where it ended first.
pub async fn Outgoing::open(self : Outgoing) -> Inbound {
  guard !self.gone.is_done() else { raise failed("cut") }
  inbound_of(open_on(self.shell, self.conn, self.fibers, self.gone), None)
}

///|
/// Closes it, and the endpoint bound for it; `reason`: what its peer is told it was closed for ("closed" unless
/// said). Its end is told at once; the shell is asked by the mesh's fiber that waits for it (`Mesh::let_go_once`),
/// or by the mesh's close. Nothing of one that ended.
pub fn Outgoing::close(self : Outgoing, reason? : String = "closed") -> Unit {
  ignore(self.gone.succeed({ kind: "local", reason }))
}

///|
/// Waits for its end: why it ended.
pub async fn Outgoing::closed(self : Outgoing) -> Closed {
  self.gone.wait()
}

///|
/// Whether it has ended (closed here, by its peer, or with the mesh).
pub fn Outgoing::ended(self : Outgoing) -> Bool {
  self.gone.is_done()
}
