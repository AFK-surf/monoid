// What the endpoint is bound with beside its relays, the relays told again, and the connections peers dial to it:
// as the TypeScript mesh does each (client/core-ts/src/mesh.ts: `make` and `#bind`, `retune`, `#accepting`), with
// the shells' own names and JSON, but for how the endpoint comes to be bound anew on other relays (`Mesh::retune`
// says) and for what a connection a peer dialled is here (`Mesh::incoming` says).

///|
/// One way in to a relay: `entry` is where a device connects to reach `relay`, one of the endpoint's relays.
#derive(Eq)
pub(all) struct RelayEntry {
  entry : String
  relay : String
}

///|
/// What the endpoint is bound with beside its relays and whether it goes through them alone (`Options`).
pub(all) struct Binding {
  /// Peers are looked up, on the LAN and where the shell looks (the Rust shell: mDNS and the DHT, under the names
  /// it has for them). Only on an endpoint with a relay that is not held to relays alone, as the TypeScript mesh; a
  /// page looks nothing up.
  lookup : Bool
  /// The protocols it takes connections on (`Mesh::incoming`); none: it takes none. A page takes none whatever
  /// is said here.
  takes : Array[String]
  /// Its relays' entries as it is made: each one's `relay` is among `Options.relays` (which entries are a relay's
  /// is the program's to work out; the TypeScript mesh does it from a table its program gives).
  entries : Array[RelayEntry]
}

///|
/// Nothing looked up, no connection taken, no entries: what a mesh is bound with where its program says none.
pub fn Binding::none() -> Binding {
  { lookup: false, takes: [], entries: [] }
}

///|
/// How long a connection a peer dialled has to open its first stream and say that stream's first line
/// (`Incoming::first`).
pub let first_ms : Int = 30_000

///|
fn entries_json(entries : Array[RelayEntry]) -> Json {
  Json::array(entries.map(e => { "entry": Json::string(e.entry), "relay": Json::string(e.relay) }))
}

///|
/// `text`'s bytes in hex: how the shells are told a protocol.
fn hex(text : String) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for b in @utf8.encode(text) {
    out.write_char(digits.get_char(b.to_int() / 16).unwrap())
    out.write_char(digits.get_char(b.to_int() % 16).unwrap())
  }
  out.to_string()
}

///|
/// An endpoint bound at the shell with the device's key: its handle. What it is asked is what it always was, with
/// what a `Binding` adds only where it adds any: `alpns` (each in hex) and `relayEntries` (`{entry, relay}`).
async fn bind(
  shell : @shell.Shell,
  relays : Array[String],
  relay_only : Bool,
  binding : Binding,
  entries : Array[RelayEntry],
  secret : Bytes,
) -> Json {
  let args : Map[String, Json] = {
    "relayUrls": Json::array(relays.map(relay => Json::string(relay))),
    "relayOnly": Json::boolean(relay_only),
    "lookup": Json::boolean(binding.lookup && !relay_only && relays.length() > 0),
  }
  if binding.takes.length() > 0 {
    args["alpns"] = Json::array(binding.takes.map(alpn => Json::string(hex(alpn))))
  }
  if entries.length() > 0 {
    args["relayEntries"] = entries_json(entries)
  }
  let bound = shell.call("iroh.bind", Json::object(args), bytes=secret) catch { e => raise under("bind_failed", e) }
  guard bound.json is { "id": endpoint, .. } else { raise failed("bind_failed") }
  endpoint
}

///|
/// The program tells the relays again, and their entries: what a peer is dialled through from now on, and what the
/// endpoint is on. Told what it has, nothing is done: by the strings as they are given, in their order (the
/// TypeScript mesh takes two for one where they are one URL written two ways; here a program writes a relay one
/// way).
///
/// The entries alone changed: the endpoint is told them (`iroh.setRelayEntries`), its links staying; one telling
/// at a time, and one whose turn comes after others were told is not made. Where the shell cannot, the endpoint is
/// bound anew as for other relays.
///
/// The relays changed: the endpoint is bound anew on them. Its handle changes, so first everything on it is let
/// go of, in this step: every link, open or being opened, as `Mesh::drop_link` lets go of one (whoever holds one
/// is told as of one replaced, whoever waits for one being opened fails as closed, a peer is told `reason`), and
/// every connection a peer dialled that the program took. As their ends are told the endpoint is bound, and the
/// one before closed; a link asked for meanwhile waits for that and is dialled on the new one, through the new
/// relays, as is one that already waited to dial (`Mesh::hold`). A bind that fails leaves the endpoint as it was, its links let go of all the same, to be bound by the
/// next link that finds nothing on it, `rebind_ms` later at the soonest; a link asked for before that is dialled
/// on the endpoint as it is, through the relays told.
///
/// (The TypeScript mesh binds anew at once and closes the old endpoint with its links on it, whose peers are told
/// what the transport says of an endpoint closed, and keeps them where the bind fails; here each is closed first,
/// saying `reason`.)
pub fn Mesh::retune(
  self : Mesh,
  relays : Array[String],
  entries? : Array[RelayEntry] = [],
  reason? : String = "closed",
) -> Unit {
  guard !self.closed else { return }
  let same = self.relays == relays
  guard !(same && self.entries == entries) else { return }
  // (its own from here: what its program does to the arrays it gave after is not the mesh's)
  let entries = entries.copy()
  self.entries = entries
  if !same {
    self.relays = relays.copy()
    self.rehome(reason)
    return
  }
  ignore(
    self.scope.fork(name="mesh entries", () => self.tuning.with_permit(() => {
      // (this waited its turn: told others since, the telling is theirs)
      guard !self.closed && physical_equal(self.entries, entries) else { return }
      // Being bound anew: that bind is with these as it ends (`Mesh::rebind`); where it fails, the endpoint is left
      // without them, to be bound by the next link that finds nothing on it.
      guard !self.rebinding else {
        self.retuned = true
        return
      }
      let endpoint = self.endpoint
      let told = attempt(() => self.shell.call("iroh.setRelayEntries", { "id": endpoint, "entries": entries_json(entries) }))
      // (and this waited at the shell: refused, the endpoint is bound anew for them only where they are still the
      // ones wanted and that still the endpoint; another was bound with them. Being bound anew by then, that bind
      // is with them: `Mesh::rehome` leaves it to that)
      guard told is Fell(_) && !self.closed && physical_equal(self.entries, entries) && self.endpoint == endpoint else {
        return
      }
      self.rehome(reason)
    })),
  )
}

///|
/// Everything on the endpoint is let go of, and the endpoint bound anew as their ends are told (`Mesh::rebind`):
/// all in the step it is called in, so that nothing comes to be on the endpoint between the two. One being bound
/// anew already is left to that, which binds what is wanted as it ends.
fn Mesh::rehome(self : Mesh, reason : String) -> Unit {
  self.retuned = true
  guard !self.rebinding else { return }
  let ends : Array[async () -> Unit] = []
  for link in self.live.copy() {
    // (one at its place is closed as the place is let go of, below)
    if !self.is_current(link) {
      link.close(reason~)
    }
    ends.push(() => {
      ignore(link.gone.wait())
      link.answered.wait()
    })
  }
  for place in self.links.keys().to_array() {
    self.let_go(place, reason)
  }
  for incoming in self.incomings.copy() {
    incoming.close(reason~)
    ends.push(() => ignore(incoming.gone.wait()))
  }
  // (the endpoints of a way's own no way is on any more go too)
  self.release_pinned()
  self.rebind(after=ends)
}

///|
/// What the wait for the next connection a peer dials ended with: one (its handle, its protocol in hex), none (the
/// endpoint asked takes none any more, or the mesh let go of the wait: `Mesh::forget_coming`), or a failure.
priv enum Taken {
  Came(Json, String)
  Ended
  Failed(Error)
}

///|
/// A connection a peer dialled to this endpoint, on a protocol it takes (`Binding.takes`): the first thing here
/// that a peer nobody knows starts. It is never a link: nothing presented a credential on it, and it is no way to
/// its peer for `Mesh::link`, `current` or the pings.
///
/// What is kept of it: its handle at the shell and its place among those taken, until its end is told, then let
/// go of (closed to be forgotten, as a link's). While it is there it is on the endpoint (`Mesh::idle`): an
/// endpoint taken for stuck is not bound anew under it, so its program ends it in a time of its own (`close`).
/// Its first stream is read through `first`, which bounds what an unknown peer may make it wait for and keep;
/// the streams after, its peer's (`accept`) and its program's (`open`), are its program's to bound, as a link's
/// are. One nobody asked for is kept by the shell, one at most by the mesh (`Mesh::incoming`), and goes with the
/// endpoint.
pub struct Incoming {
  /// Its peer's endpoint id, as the transport proved it; "" where the shell does not say.
  peer : String
  /// The protocol it came on: one of `Binding.takes` (as the shell said it, in hex, were it none of them).
  alpn : String
  priv shell : @shell.Shell
  priv conn : Json
  priv gone : @effect.Deferred[Closed]
  priv mut asked : Bool
  /// The mesh's fibers: where the waits for its streams run (`accept`, `open`); and those waits.
  priv fibers : @effect.Scope
  priv accepting : Accepting
}

///|
/// The next connection a peer dials to this endpoint; None once the mesh is closed, and at once of an endpoint
/// that takes none. One asker at a time: another waits its turn. Fails where the shell takes none (a page's).
///
/// The shell's wait for it (`iroh.accept`) is a fiber of the mesh's, not the asker's, and one is under way at
/// most (`Mesh::await_coming`): an asker that gives up loses nothing, and the connection that wait brings is the
/// next asker's. It is the endpoint's it was asked of: as that is bound anew the wait is let go of, a connection
/// it had brought that nobody took with it, and the one bound is asked.
pub async fn Mesh::incoming(self : Mesh) -> Incoming? {
  guard self.binding.takes.length() > 0 else { return None }
  self.taking.with_permit(() => {
    while !self.closed {
      // (being bound anew: the endpoint to ask is the one that comes. Told as that ended, `Mesh::eased`, or as
      // the mesh closes)
      if self.rebinding {
        ignore(attempt(() => self.hold(None)))
        continue
      }
      let coming = match self.coming {
        Some(coming) => coming
        None => self.await_coming()
      }
      let taken = coming.wait()
      // This waited, so all of it is looked at again. The endpoint being bound anew: whether the one this came
      // of stays is known as that ends, and nothing is taken on it before (one taken would be on an endpoint that
      // is let go of for having nothing on it).
      while !self.closed && self.rebinding {
        ignore(attempt(() => self.hold(None)))
      }
      // No more the wait the mesh keeps: its endpoint was bound anew, or the mesh closed, and what it brought was
      // let go of there (`Mesh::forget_coming`). The one there now is asked; of a mesh closed, none.
      guard self.coming is Some(kept) && physical_equal(kept, coming) else { continue }
      self.coming = None
      match taken {
        Came(conn, alpn) => return Some(self.took(conn, alpn))
        // (the shell says the endpoint, still the mesh's, takes none any more: none will come)
        Ended => return None
        Failed(e) => raise MeshError(code="host", message=text_of(e), cause="")
      }
    }
    None
  })
}

///|
/// The wait at the shell for the next connection a peer dials to the endpoint as it is now, begun: what it ends
/// with is kept (`coming`) until an asker takes it. Given up, the shell's wait would go on and take the next
/// connection for nobody, so it is the mesh's own fiber, as the wait for a peer's stream is (`Link::accept`).
///
/// Cut as the mesh closes, before its first step even, it says nothing: whoever waits is told by the close,
/// which lets go of the wait (`Mesh::forget_coming`). And as it is answered it looks again whether it is still
/// the wait the mesh keeps: let go of meanwhile (the endpoint bound anew), what it brings is nobody's, and is
/// closed to be forgotten here.
fn Mesh::await_coming(self : Mesh) -> @effect.Deferred[Taken] {
  let coming : @effect.Deferred[Taken] = @effect.Deferred::new()
  self.coming = Some(coming)
  let kept = () => self.coming is Some(now) && physical_equal(now, coming)
  ignore(
    self.scope.fork(name="mesh take", () => {
      let said = attempt(() => self.shell.call("iroh.accept", { "id": self.endpoint }))
      match said {
        Did({ json: { "id": conn, "alpn": String(alpn), .. }, .. }) =>
          if kept() {
            ignore(coming.succeed(Came(conn, alpn)))
          } else {
            self.shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
          }
        Did(_) => ignore(coming.succeed(Ended))
        Fell(e) => ignore(coming.succeed(Failed(e)))
      }
    }),
  )
  coming
}

///|
/// A connection the shell brought is its program's from here: among those taken until its end is told.
fn Mesh::took(self : Mesh, conn : Json, alpn : String) -> Incoming {
  let peer = match (self.shell.ask("conn.remoteId", { "id": conn }) catch { _ => Json::null() }) {
    String(id) => id
    _ => ""
  }
  let alpn = self.binding.takes.iter().find_first(take => hex(take) == alpn).unwrap_or(alpn)
  self.took_conn(conn, peer, alpn)
}

///|
/// A connection on the endpoint, a peer's (`Mesh::took`) or dialled from here (`Mesh::connect`), is its program's
/// from here, with its peer and its protocol as written: among those taken until its end is told.
fn Mesh::took_conn(self : Mesh, conn : Json, peer : String, alpn : String) -> Incoming {
  let shell = self.shell
  let incoming : Incoming = {
    peer,
    alpn,
    shell,
    conn,
    gone: @effect.Deferred::new(),
    asked: false,
    fibers: self.scope,
    accepting: Accepting::new(),
  }
  self.incomings.push(incoming)
  // Its end, waited for once (cut as the mesh closes, which says it of every one taken itself). Nobody waits to
  // dial for it to go, so its going is told nobody: with one taken the endpoint is dialled on as it is
  // (`Mesh::settling`), and what lets go of all of them for a bind waits for each end itself (`Mesh::rehome`).
  ignore(
    self.scope.fork(name="mesh taken", () => {
      let said = attempt(() => shell.call("conn.closed", { "id": conn }))
      let closed = match said {
        Did(answer) => closed_of(answer.json).unwrap_or({ kind: "other", reason: "" })
        Fell(e) => { kind: "other", reason: text_of(e) }
      }
      ignore(incoming.gone.succeed(closed))
      incoming.accepting.drop_kept(shell)
      shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
      self.incomings.retain(one => !physical_equal(one, incoming))
    }),
  )
  incoming
}

///|
/// A connection dialled from the endpoint itself to `peer` (its endpoint id) on `alpn`, a protocol of its program's
/// that the peer's endpoint takes (this one need not): the other way of `Mesh::incoming`, and handed out as one of
/// those, kept and let go of as they are (`Incoming`: on the endpoint while it is open, closed to be forgotten as
/// it ends, the endpoint is bound anew or the mesh closes). Unlike `Mesh::dial_once`, no endpoint is bound for it:
/// the peer's transport proves it is the device's (its `Incoming.peer` is `Mesh::device_id`), and nothing is put
/// off a relay. Its `peer` and `alpn` are as given.
///
/// Dialled through the mesh's relays and where the peer is dialled straight: `ips` the caller gives, then what the
/// mesh knows (`Mesh::straight_to`), each once; none where the mesh is held to relays. As a link's dial, it waits
/// while the endpoint is being bound anew, or, taken for stuck or not on the relays told, is to be bound once what
/// is on it ends by itself (begun here where nothing is: `Mesh::link`); its time, `within` ms, counts from when the
/// endpoint is on a relay (`onto_max_ms` at most), at once where it has addresses; the handshake is a fiber of the
/// mesh's, counted as on the endpoint while it lasts (`Mesh::idle`), given up at the shell (`Shell::give_up`)
/// where this ends first. Running out of time does not take the endpoint for stuck: the peer may only be away.
/// The endpoint bound anew or replaced under it (`Mesh::retune`, `Mesh::migrate`), it is dialled again on the one
/// there. Fails as closed where the mesh is or closes meanwhile, as no answer where the time runs out, as
/// unreached where the shell says so; failed, or cut, nothing of it is kept, a connection that came after closed
/// to be forgotten.
pub async fn Mesh::connect(
  self : Mesh,
  peer : String,
  alpn : String,
  ips? : Array[String] = [],
  within? : Int = connect_timeout_ms,
) -> Incoming {
  guard !self.closed else { raise failed("closed") }
  guard is_id(peer) else {
    raise MeshError(code="invalid_params", message="a dial names an endpoint id (64 hex), not \"\{peer}\"", cause="")
  }
  guard alpn != "" else { raise MeshError(code="invalid_params", message="a dial names its protocol", cause="") }
  // (its own from here: what its program does to the array it gave after is not the mesh's)
  let ips = ips.copy()
  while true {
    guard !self.closed else { raise failed("closed") }
    // As `Mesh::link`: an endpoint taken for stuck, or not yet on the relays told, nothing on it, is bound anew,
    // begun in this step; nothing is dialled on one being bound anew, nor on one that is to be once what is still
    // on it ends by itself (`Mesh::settling`). This waits to be told (`Mesh::eased`), then looks again.
    if !self.rebinding && (self.stuck || self.retuned) && self.idle() && self.may_rebind() {
      self.rebind()
    }
    if self.rebinding || ((self.stuck || self.retuned) && self.may_rebind() && self.settling()) {
      self.hold(None)
      continue
    }
    let endpoint = self.endpoint
    let tried = attempt(() => self.connect_on(endpoint, peer, alpn, ips, within))
    // (this waited: the endpoint bound anew or replaced meanwhile, the one there is dialled; what came on the one
    // before is let go of, nothing being kept of that one)
    let moved = !self.closed && (self.rebinding || self.endpoint != endpoint)
    match tried {
      Did(conn) =>
        if moved {
          self.shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
        } else {
          return self.took_conn(conn, peer, alpn)
        }
      Fell(e) => if !moved { raise e }
    }
  }
  raise failed("closed")
}

///|
/// One dial of `Mesh::connect` on `endpoint`: its connection, handed out in the step it comes back to the asker
/// (who takes it in that step: `Mesh::took_conn`); failed, or cut, the dial is given up at the shell and a connection
/// that came is closed to be forgotten, as `Mesh::dial_once`'s.
async fn Mesh::connect_on(
  self : Mesh,
  endpoint : Json,
  peer : String,
  alpn : String,
  ips : Array[String],
  within : Int,
) -> Json {
  let shell = self.shell
  let straight : Array[String] = []
  let add = (more : Array[String]) => for ip in more {
    if !straight.contains(ip) {
      straight.push(ip)
    }
  }
  if !self.options.relay_only {
    add(ips)
  }
  add(self.straight_to(peer))
  let addr : Map[String, Json] = { "id": Json::string(peer), "relays": strings(self.relays) }
  if straight.length() > 0 {
    addr["ips"] = strings(straight)
  }
  let addr = Json::object(addr)
  let call : Ref[Int64?] = Ref(None)
  let connection : Ref[Json?] = Ref(None)
  let abandoned = Ref(false)
  let handed = Ref(false)
  // (on the endpoint while it lasts: it is not bound anew under the dial, `Mesh::idle`)
  self.dialling_main += 1
  defer {
    self.dialling_main -= 1
    if !handed.val {
      abandoned.val = true
      if call.val is Some(id) {
        shell.give_up(id)
      }
      if connection.val is Some(conn) {
        shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
      }
    }
    self.eased()
  }
  let dialled : @effect.Deferred[Json] = @effect.Deferred::new()
  ignore(
    self.scope.fork(name="mesh connect", () => {
      guard !abandoned.val else { return }
      let made = attempt(() => shell.call(
        "iroh.connect",
        { "id": endpoint, "addr": addr },
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
        for waited = 0; straight.length() == 0 && waited < onto_max_ms && !self.on_a_relay(endpoint); waited = waited + onto_recheck_ms {
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
  handed.val = true
  conn
}

///|
/// The wait for a connection is let go of, with the endpoint it was asked of (bound anew, or the mesh closed):
/// it is no more the one the mesh keeps. A connection it had brought that nobody took is closed to be forgotten;
/// still out, whoever waits on it is told to look again (the shell ends it with its endpoint, and where it brings
/// a connection first, that is closed as it comes: `Mesh::await_coming`).
fn Mesh::forget_coming(self : Mesh) -> Unit {
  guard self.coming is Some(coming) else { return }
  self.coming = None
  let kept : Taken? = coming.poll() catch { _ => None }
  match kept {
    Some(Came(conn, _)) => self.shell.tell("conn.close", { "id": conn, "code": 0, "reason": "closed", "forget": true })
    Some(_) => ()
    None => ignore(coming.succeed(Ended))
  }
}

///|
/// Its first stream and that stream's first line, and the stream from there (what came after the line first):
/// what its peer has `within` ms of this being asked to open and say. Asked once. What came is kept a read of the
/// shell's at a time (64 KiB at most natively), and given up once more than `most` bytes are there with no
/// line's end: so `most` and one read is the most kept of a peer here, the line's own length too.
///
/// A peer that does not (no stream, no line in time, a line too long, the connection ended), and an asker that
/// gives up while it waits, end the connection: it is closed, saying `closed`, and its stream goes with it, so
/// nothing of the shell's reads that go on is ever read again. Fails then as no answer, as too long, or as cut.
/// (The time is its program's to begin: one taken and never asked this is held to none, until it is closed.)
///
/// Asked after `accept` was, it fails as its program's mistake: the first stream was that one's. An `accept` asked
/// while this waits waits for it, and is the stream after.
pub async fn Incoming::first(self : Incoming, within? : Int = first_ms, most? : Int = max_head) -> (String, Inbound) {
  guard !self.asked else {
    raise MeshError(code="invalid_params", message="a connection's first stream is asked for once", cause="")
  }
  self.asked = true
  self.accepting.lock.with_permit(() => {
    let had = Ref(false)
    defer {
      if !had.val {
        self.close()
      }
    }
    let found = @effect.timeout(within, () => {
      let said = self.shell.call("conn.acceptBi", { "id": self.conn }) catch { e => raise cut(e) }
      guard said.json is { "id": id, .. } else { raise failed("cut") }
      let stream : Stream = { shell: self.shell, id }
      let lines : Lines = { stream, carry: @wire.Carry::new(), most }
      guard lines.next() is Some(line) else { raise failed("cut") }
      (line, stream, lines.carry.take())
    })
    guard found is Some((line, stream, rest)) else { raise failed("no_answer") }
    had.val = true
    (line, inbound_of(stream, if rest.length() > 0 { Some(rest) } else { None }))
  })
}

///|
/// The next stream its peer opens on it, after the first (`first`), or the first where its program reads that
/// itself; None once it ended, or the mesh closed. One asker at a time: another waits its turn. As `Link::accept`:
/// the shell's wait is the mesh's fiber, so an asker that gives up loses nothing, and the stream it brings is the
/// next asker's; one nobody took as the connection ends is reset. What comes on it is not bounded here: a peer
/// nobody knows is its program's to hold to a time and a length.
pub async fn Incoming::accept(self : Incoming) -> Inbound? {
  self.asked = true
  accept_on(self.shell, self.conn, self.fibers, self.gone, self.accepting)
}

///|
/// A stream opened on it from this side, to its peer: as `Link::stream`, the shell's wait is the mesh's fiber, and
/// what it opens for an asker that gave up is reset. Fails as cut where the connection ended first.
pub async fn Incoming::open(self : Incoming) -> Inbound {
  guard !self.gone.is_done() else { raise failed("cut") }
  inbound_of(open_on(self.shell, self.conn, self.fibers, self.gone), None)
}

///|
/// Closes it; `reason`: what its peer is told it was closed for ("closed" unless said). Nothing of one that ended.
pub fn Incoming::close(self : Incoming, reason? : String = "closed") -> Unit {
  // (its end told: it was let go of at the shell, and nothing is asked of it after)
  guard !self.gone.is_done() else { return }
  self.shell.tell("conn.close", { "id": self.conn, "code": 0, "reason": Json::string(reason) })
}

///|
/// Waits for its end: why it ended.
pub async fn Incoming::closed(self : Incoming) -> Closed {
  self.gone.wait()
}
