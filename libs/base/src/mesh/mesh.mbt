// The device side of the mesh: this device's iroh endpoint (the shell's) and its links to peers, as the
// TypeScript mesh keeps them (client/core-ts/src/mesh.ts), whose bytes and times these are: the endpoint's key the
// device key (kept under `device`, 32 bytes), a link dialled on the protocol its user names and let in by the
// credential its user gives, said in the control stream's first line with what its user says in every one; the
// credential presented again every `tick_ms` as the link's ping and every `renew_ms` as its renewal; a request a
// stream, its body whole or a step at a time, its reply whole or as it comes, or the stream open both ways after
// its head; and the streams its peer opens (link.mbt). A link that ended, or whose renewal was refused, is opened
// again by the next `link`.
//
// A link is its program's by two things: the peer, and a scope, a string of the program's own that the mesh never
// reads (one program is let in to one peer under several credentials at once, a link each: `Mesh::link`'s `scope`;
// a program with one says none). Each has its own credential, is renewed, let go and opened again by itself; all
// are dialled to the same peer on the one endpoint. The link there is now is asked without dialling
// (`Mesh::current`), whoever holds one is told as it is no more the one there (`Mesh::replaced`), and its program
// lets one go, with the reason the peer is to be told (`Mesh::drop_link`).
//
// A link's pings are measured (their round trips smoothed, `Link::pings`), and say how its place is: whether a way to
// it answers (`Mesh::standing`, `Mesh::healthy`), told to whoever waits as it changes (`Mesh::health_change`). A link
// that misses a ping its peer used to answer quickly is suspect at once: a new one is raced beside it, and takes its
// place if it opens before the old one answers (health.mbt, whose head and `Mesh::race` say where that differs from
// the TypeScript mesh's).
//
// At its program's word that its connections are suspect (`Mesh::wake`) the shell is told, every link raced and every
// opening tried a second time beside its first; and an endpoint a dial found stuck is bound anew before the next
// dial, while nothing is on it (wake.mbt).
//
// The endpoint is bound as its program says (`Binding`: peers looked up, the protocols it takes connections on,
// its relays' entries), the relays are told again (`Mesh::retune`), and a connection a peer dials to it is its
// program's to take (`Mesh::incoming`), never a link (bind.mbt).
//
// Where a peer said a device dials it straight is kept, told the endpoint and given to its dials, and where its
// program says a peer is told each endpoint bound (`Mesh::add_addr`, addrs.mbt).
//
// A place may have several ways, each a link: on the endpoint, on an endpoint bound on one relay alone, at the
// addresses the peer said on an endpoint of their own; requests go on the one in `links`, moved among them as they
// answer (ways.mbt). `Mesh::ways` (health.mbt) counts them for what asks whether any way, or no other way, is up.
// Each way's speed and each peer's bytes today (speed.mbt), what the mesh tells its program's tracer and record
// (trace.mbt), and what else a program asks of it (a slow read's other way, signing with the device key, the key
// taken over: hooks.mbt, sign.mbt) are that mesh's too. Peers are looked up by the shell (`Binding.lookup`).

///|
/// The key the device's key is kept under.
pub let device_key : String = "device"

///|
/// How often a link presents a fresh credential.
pub let renew_ms : Int = 5 * 60_000

///|
/// How long an opening may take once the endpoint is on a relay, and how long it waits to be on one before that counts
/// all the same (looked at every `onto_recheck_ms`).
pub let connect_timeout_ms : Int = 10_000

///|
pub let onto_max_ms : Int = 30_000

///|
let onto_recheck_ms : Int = 250

///|
/// How often a link is pinged (its credential presented again, answered by the peer itself), and when a ping not
/// answered counts as missed.
pub let tick_ms : Int = 5_000

///|
pub let ping_timeout_ms : Int = 3_000

///|
/// Pings in a row a link may miss before it is let go, and its peer dialled anew.
let dead_pings : Int = 3

///|
/// How long a suspect link is given to answer while a new one is raced beside it.
pub let probe_ms : Int = 5_000

///|
/// How long a link another took the place of stays open: what is under way on it may still end.
pub let retire_ms : Int = 10_000

///|
/// The fields of a control line that are the mesh's own to write: what `Options.says` may not name.
let own_fields : Array[String] = ["credential", "traceparent"]

///|
/// Where the mesh keeps what it keeps (the device's key): small values by key.
pub(all) struct Store {
  get : async (String) -> Bytes?
  set : async (String, Bytes) -> Unit
}

///|
/// The shell's own keeping (`storage.*`): a file a key in the directory the shell was started with.
pub fn shell_store(shell : @shell.Shell) -> Store {
  {
    get: key => shell.call("storage.get", { "key": Json::string(key) }).bytes,
    set: (key, value) => ignore(shell.call("storage.set", { "key": Json::string(key) }, bytes=value)),
  }
}

///|
/// What a mesh is made with: its user's protocol, none of which it says itself.
pub(all) struct Options {
  /// The protocol its links are dialled on (what the peer's endpoint takes).
  alpn : String
  /// The relays the endpoint is on, and a peer is dialled through.
  relays : Array[String]
  /// Through the relays alone: the endpoint has no way direct.
  relay_only : Bool
  /// What every line of a link's control stream says after its credential, the first and those that present it again;
  /// none: the credential alone. Never `credential` nor `traceparent`, a line's own.
  says : Map[String, Json]?
  /// What a peer's refusal of a link's first line is, by its answer as parsed (an object with `error`) and the reason
  /// it gave, where it refuses for something else than the credential; none, or None of it: the credential refused.
  refusal : ((Json, String) -> Error?)?
}

///|
/// How an opening ended.
priv enum Opened {
  Open(Link)
  /// What it failed with, and whether for no answer in time.
  Failed(Error, Bool)
}

///|
/// Where a link is: the scope its program gave (as it gave it, never read) and the peer's endpoint id.
#derive(Eq, Hash)
priv struct Place {
  scope : String
  peer : String
}

///|
/// An opening, shared by everyone who asks for the same place meanwhile.
priv struct Opening {
  done : @effect.Deferred[Link]
  mut result : Opened?
  /// What it is dialled with: what a second dial beside the first is dialled with too (`Mesh::hedge`).
  credentials : async (String, Bool) -> Presented
  fresh : Bool
  /// The fiber of its dial, and of one tried beside it (wake.mbt): each cut where the opening ends otherwise (the
  /// other's link took it, or its program let go of it: `Mesh::drop_link`).
  mut first : @effect.Fiber[Unit]?
  mut hedge : @effect.Fiber[Unit]?
  /// How many of its dials have not ended, and what its first failed with once it has: what the opening fails
  /// with where both do.
  mut dials : Int
  mut failure : Error?
  /// Its `mesh.connect` span (trace.mbt), ended as it ends.
  mut span : Span?
}

///|
fn Opening::new(credentials : async (String, Bool) -> Presented, fresh : Bool) -> Opening {
  {
    done: @effect.Deferred::new(),
    result: None,
    credentials,
    fresh,
    first: None,
    hedge: None,
    dials: 0,
    failure: None,
    span: None,
  }
}

///|
/// The opening's time ran out: whether the connection was made by then.
priv suberror OpeningTimeout {
  OpeningTimeout(Bool)
}

///|
impl Show for OpeningTimeout with output(self, logger) {
  let OpeningTimeout(direct) = self
  logger.write_string(if direct { "opening timed out (direct)" } else { "opening timed out" })
}

///|
pub struct Mesh {
  priv shell : @shell.Shell
  priv options : Options
  /// The endpoint at the shell, and its id. The endpoint is bound anew where it is stuck (`Mesh::rebind`,
  /// wake.mbt): only while nothing is on it, so nothing holds the handle of before.
  priv mut endpoint : Json
  priv mut id : String
  /// The device's key: what the endpoint is bound with, each time.
  priv mut secret : Bytes
  /// The relays the endpoint is on and a peer is dialled through, and their entries: as it was made with, then as
  /// it was last told (`Mesh::retune`, bind.mbt). And what else it is bound with, which stays.
  priv mut relays : Array[String]
  priv mut entries : Array[RelayEntry]
  priv binding : Binding
  /// The relays were told again and the endpoint is not yet on them: it is bound anew by the next link that finds
  /// nothing on it, where the bind begun as they were told did not come to it.
  priv mut retuned : Bool
  /// One telling of the entries at the shell at a time, in the order told (`Mesh::retune`).
  priv tuning : @effect.Semaphore
  /// The connections peers dial to the endpoint (bind.mbt): one asks for the next at a time; what the wait under
  /// way at the shell ends with, kept until an asker takes it, or let go of with the endpoint it was asked of
  /// (`Mesh::forget_coming`: an asker takes only what is still here, and is told to look again as it is let go
  /// of, the close's doing too); those taken whose end is not told yet.
  priv taking : @effect.Semaphore
  priv mut coming : @effect.Deferred[Taken]?
  priv incomings : Array[Incoming]
  /// The connections dialled once (dial_once.mbt), each on an endpoint of its own, until both are let go of.
  priv outgoings : Array[Outgoing]
  /// A dial ran out of time with no connection made: the endpoint may be stuck, and is bound anew before the next
  /// dial where nothing is on it, `rebind_ms` after the last time at the soonest. When it last was; and whether
  /// one is under way: whoever would dial meanwhile waits (`held`).
  priv mut stuck : Bool
  priv mut rebound_at : Int64?
  priv mut rebinding : Bool
  /// Whoever asked for a link and waits before any dial is made for it (`Mesh::hold`): for the endpoint to be
  /// bound anew, or, taken for stuck, to have nothing left on it. Each with its place: told to look again as
  /// either may be so (`Mesh::eased`), and failed as closed where its place is let go of (`drop_link`) or the
  /// mesh closes. No opening is theirs yet, so `links` does not say them. With no place: whoever asked for a
  /// connection a peer dials and waits for the endpoint being bound anew (`Mesh::incoming`).
  priv held : Array[(Place?, @effect.Deferred[Unit])]
  /// Its fibers: the dials, each link's answer, pings and renewal.
  priv scope : @effect.Scope
  /// The links, by place. An opening not yet ended is always here, which `close` goes by: one is taken out or put
  /// over only once it ended (`drop_link` ends one itself first), and by what waited meanwhile only if it is still
  /// the one here (`Mesh::steer`).
  priv links : Map[Place, Opening]
  /// The links handed out whose answer or whose end is not said yet: what `close` says them of.
  priv live : Array[Link]
  /// Done as `links` next changes (`Mesh::changed`), and another put here then: what `Mesh::replaced` waits on.
  priv mut change : @effect.Deferred[Unit]
  /// The places whose link is raced against a new one now (health.mbt).
  priv racing : Map[Place, Race]
  /// Whether a way to each place answered its pings, as last told (`Mesh::tell_health`), and who waits to be told
  /// it is no more what they said it was.
  priv health : Map[Place, Bool]
  priv health_waits : Array[(Place, Bool, @effect.Deferred[Bool])]
  /// Where peers said they are dialled straight, by place (addrs.mbt), kept in `store` under `addresses`, one
  /// writing at a time; where its program said peers are (`Mesh::add_addr`); and the places whose last dial on the
  /// endpoint went unanswered given addresses, with those addresses.
  priv store : Store
  priv addresses : String
  priv said : Map[String, Said]
  priv keeping : @effect.Semaphore
  priv known : Array[Known]
  priv unanswered_at : Map[Place, String]
  /// The ways to each place and what is kept of them (ways.mbt); the endpoints of a way's own, by way, and the dials
  /// under way on them (none is let go of meanwhile); the ways no more gone on, closed `retire_ms` after; the dials
  /// on the endpoint beside a place's link (`Mesh::explore`) and on no link's (`Mesh::connect`, bind.mbt); and what
  /// a relay's endpoint's key is made with.
  priv ways_of : Map[Place, Ways]
  priv pinned : Map[String, Pinned]
  priv mut dialing : Int
  priv retiring : Array[Link]
  priv mut dialling_main : Int
  priv pinned_prefix : Bytes
  /// The wall's clock; the speeds seen on each peer's ways and the days counted of what its links carried, kept
  /// under their keys; what came through each (peer, relay) of replies timed (speed.mbt); and whether they are
  /// counted now (`Mesh::tally_if`).
  priv clock : WallClock
  priv speeds : Map[String, Map[String, Speed]]
  priv speeds_key : String
  priv came_by : Map[String, Int]
  priv days : Map[String, Day]
  priv days_key : String
  priv mut days_changed : Bool
  priv mut tallying : Bool
  /// Its program's tracer and record (trace.mbt); when each (peer, relay)'s speed was last told; the dials made so
  /// far (each record line's number); whether the DHT's lines are kept, and when last taken.
  priv trace : Trace
  priv recorder : Recorder
  priv speed_said : Map[String, Int64]
  priv mut dials_n : Int
  priv mut dht_kept : Bool
  priv mut dht_at : Int64
  /// The places whose next dial comes after the endpoint was bound anew for them (its span says so).
  priv rebound_for : Map[Place, Unit]
  priv mut closed : Bool
}

///|
/// Binds the endpoint with the device key kept in `store` (made and kept the first time).
///
/// `binding`: what else the endpoint is bound with (bind.mbt); none said: nothing looked up, no connection taken,
/// no entries, as before there was any. `addresses`: the key what peers say of where they are dialled straight is
/// kept under in `store` (addrs.mbt), read here: what is not there or cannot be read is taken for nothing.
/// `pinned_prefix`: what the key of an endpoint on one relay alone is made with, beside the device's key and the
/// relay (ways.mbt, `pinned_key`).
pub async fn Mesh::make(
  shell : @shell.Shell,
  store : Store,
  options : Options,
  binding? : Binding = Binding::none(),
  addresses? : String = addresses_key,
  pinned_prefix? : Bytes = relay_key_prefix,
  clock? : WallClock,
  speeds_key? : String = speed_key,
  days_key? : String = net_day_key,
  trace? : Trace = Trace::none(),
  recorder? : Recorder = Recorder::none(),
) -> Mesh {
  if options.says is Some(says) {
    for field in own_fields {
      if says.contains(field) {
        // (its user's mistake: no link would say what it means)
        raise MeshError(code="invalid_params", message="Options.says names \{field}: a control line's own, which the mesh writes", cause="")
      }
    }
  }
  let kept = (store.get)(device_key) catch { e => raise MeshError(code="host", message=text_of(e), cause="") }
  let secret = match kept {
    Some(secret) if secret.length() == 32 => secret
    _ => {
      let secret = shell.random(32)
      (store.set)(device_key, secret) catch {
        e => raise MeshError(code="host", message=text_of(e), cause="")
      }
      secret
    }
  }
  let said = said_of((store.get)(addresses) catch { _ => None })
  let speeds = speeds_of((store.get)(speeds_key) catch { _ => None })
  let days = days_of((store.get)(days_key) catch { _ => None })
  let relays = options.relays.copy()
  let entries = binding.entries.copy()
  let endpoint = bind(shell, relays, options.relay_only, binding, entries, secret)
  let id = match (shell.ask("iroh.endpointId", { "id": endpoint }) catch { e => raise under("bind_failed", e) }) {
    String(id) => id
    _ => raise failed("bind_failed")
  }
  {
    shell,
    options,
    endpoint,
    id,
    secret,
    relays,
    entries,
    binding,
    retuned: false,
    tuning: @effect.Semaphore::new(1),
    taking: @effect.Semaphore::new(1),
    coming: None,
    incomings: [],
    outgoings: [],
    stuck: false,
    rebound_at: None,
    rebinding: false,
    held: [],
    scope: shell.rt.scope(),
    links: Map([]),
    live: [],
    change: @effect.Deferred::new(),
    racing: Map([]),
    health: Map([]),
    health_waits: [],
    store,
    addresses,
    said,
    keeping: @effect.Semaphore::new(1),
    known: [],
    unanswered_at: Map([]),
    ways_of: Map([]),
    pinned: Map([]),
    dialing: 0,
    retiring: [],
    dialling_main: 0,
    pinned_prefix,
    clock: clock.unwrap_or(WallClock::of(shell.rt)),
    speeds,
    speeds_key,
    came_by: Map([]),
    days,
    days_key,
    days_changed: false,
    tallying: false,
    trace,
    recorder,
    speed_said: Map([]),
    dials_n: 0,
    dht_kept: false,
    dht_at: 0L,
    rebound_for: Map([]),
    closed: false,
  }
}

///|
/// This device's endpoint id (64 hex): the public half of its key.
pub fn Mesh::device_id(self : Mesh) -> String {
  self.id
}

///|
fn is_id(id : String) -> Bool {
  guard id.length() == 64 else { return false }
  for c in id {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
/// The link to `peer` (its endpoint id) in `scope`, open: the one there is, the one being opened, or one opened now,
/// with the credential `credentials` gives (asked with this device's id, and whether for a new one: the last was
/// refused). It is handed out as its credential is sent (`Link::admitted` waits for the peer's answer). Fails as
/// the peer could not be reached, and as closed where its program let go of the place meanwhile (`drop_link`).
/// Before it dials it may wait: for the endpoint being bound anew, or, the endpoint taken for stuck, for what
/// is under way on it to end (wake.mbt, `Mesh::rebind`).
///
/// `scope`: what the program tells its links to one peer apart by, a string of its own; the same peer in another
/// scope has a link of its own, opened with that one's credential. None said: the one scope of a program with one.
///
/// `theirs`, `off`: what its program says of the ways there, as `Mesh::set_ways` (ways.mbt); not said, as they were.
/// A link no more usable with another way open there that answered: requests go on that one at once.
///
/// `asker`: what waits on it, said on its dial's span; `traceparent`: what that span is under (trace.mbt).
pub async fn Mesh::link(
  self : Mesh,
  peer : String,
  credentials : async (String, Bool) -> Presented,
  scope? : String = "",
  theirs? : Array[String],
  off? : Array[String],
  asker? : String,
  traceparent? : String,
) -> Link {
  let place : Place = { scope, peer }
  if theirs is Some(_) || off is Some(_) {
    self.set_ways(peer, scope~, theirs?, off?)
  }
  let mut fresh = false
  if self.links.get(place) is Some(existing) {
    match existing.result {
      None => {
        // Being opened: as that dial ends, unless it gave up for no answer before this waited `connect_timeout_ms` on
        // it: begun earlier, that says nothing of now, and the peer is dialled again.
        let asked = self.shell.rt.now()
        let joined = attempt(() => existing.done.wait())
        match joined {
          Did(link) => return link
          Fell(e) => {
            let unanswered = existing.result is Some(Failed(_, true))
            if !unanswered || self.shell.rt.now() - asked >= connect_timeout_ms.to_int64() {
              raise e
            }
            // (and what is at its place now is looked at anew: this waited)
            return self.link(peer, credentials, scope~, asker?, traceparent?)
          }
        }
      }
      Some(Open(link)) => {
        if link.usable() {
          return link
        }
        // (refused for something its user named, the credential was fine: no new one asked of its source)
        fresh = link.refused is Some(_) && !link.control.named
        // Gone, with another way still open: requests go on that one at once.
        if !fresh {
          let up = self.live_ways(place).filter(way => !physical_equal(way.link, link) && way.link.missed == 0)
          if self.best_way(place, self.takeable(place, up)) is Some(way) {
            self.promote(place, way, "lost")
            return way.link
          }
        }
      }
      Some(Failed(e, _)) => fresh = code_of(e) == "credential_refused"
    }
  }
  guard !self.closed else { raise failed("closed") }
  // The endpoint taken for stuck, or not yet on the relays it was told (`Mesh::retune`), nothing on it: it is
  // bound anew, begun in this step.
  let rebound = !self.rebinding && (self.stuck || self.retuned) && self.idle() && self.may_rebind()
  if rebound {
    self.rebind()
    self.rebound_for[place] = ()
  } else if self.stuck {
    self.record("conn stuck", () => {
      let open = self.live.filter(link => link.pin is None && link.ended() is None).length()
      "\{peer_tag(place)} not rebound: \{open} link(s) open"
    })
  }
  // Nothing is dialled on an endpoint that is being bound anew, nor on one taken for stuck, or not yet on the
  // relays told, that is to be once what is still on it ended by itself (`Mesh::settling`): a dial begun there
  // would keep it from ever being so. This waits to be told (`Mesh::hold`), and then looks at everything anew, its
  // place first: it waited.
  if self.rebinding || ((self.stuck || self.retuned) && self.may_rebind() && self.settling()) {
    self.hold(Some(place))
    return self.link(peer, credentials, scope~, asker?, traceparent?)
  }
  self.dial(place, credentials, fresh, asker?, traceparent?).done.wait()
}

///|
/// Waits before a dial for `place` is made, until told to look again (`Mesh::eased`); fails as closed where the
/// place is let go of meanwhile (`drop_link`) or the mesh closes. Given up, it is no more waited for.
async fn Mesh::hold(self : Mesh, place : Place?) -> Unit {
  let turn : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.held.push((place, turn))
  defer {
    self.held.retain(one => !physical_equal(one.1, turn))
  }
  turn.wait()
}

///|
/// Something left the endpoint, or it was bound anew: whoever waits to dial looks again (`Mesh::link`). Said
/// wherever an opening ends (`Mesh::dialled`, `drop_link`, which ends a race there too), a link is no more
/// `live` (`Mesh::said`), a race ends by itself (`Mesh::race`), a bind ends (`Mesh::rebind`): one of them missed,
/// an asker would wait for good.
fn Mesh::eased(self : Mesh) -> Unit {
  guard self.held.length() > 0 else { return }
  let held = self.held.copy()
  self.held.clear()
  for one in held {
    ignore(one.1.succeed(()))
  }
}

///|
/// An opening put at `place`, over what is there, and its dial begun: all in the step it is called in, so that
/// between what was there being taken for gone and this being the one there, nothing else runs. What lets go of the
/// place after finds it (`drop_link`, `close`), dialled for by `link` or by the mesh itself (`Mesh::steer`). A race
/// under way there (health.mbt) is ended with what it was put over.
///
/// Told as `mesh.connect` (trace.mbt): `asker`, what waits on it; `traceparent`, what it is under; whether the
/// endpoint was bound anew for it first (`rebound_for`).
fn Mesh::dial(
  self : Mesh,
  place : Place,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  asker? : String,
  traceparent? : String,
) -> Opening {
  let rebound = self.rebound_for.contains(place)
  self.rebound_for.remove(place)
  // (a race there was deciding of the link this is put over, ended meanwhile: it has nothing left to decide, and
  // one dial is made for a place, not two)
  self.end_race(place)
  // (what the link put over carried is counted first: speed.mbt)
  if self.links.get(place) is Some({ result: Some(Open(before)), .. }) {
    self.count(place.peer, before)
  }
  let opening = Opening::new(credentials, fresh)
  let span = self.span("mesh.connect", place.peer, parent?=traceparent)
  if asker is Some(asker) {
    (span.own)("asker", Str(asker))
  }
  if rebound {
    (span.own)("rebound", Flag(true))
  }
  (span.own)("relay", Str(self.relay_status(self.endpoint)))
  opening.span = Some(span)
  self.links[place] = opening
  self.changed()
  // (cut as the mesh closes, it says nothing: `Mesh::close` tells those who wait for this opening; as `drop_link`
  // does where it cuts it. Not cut in time, it finds its opening ended there, and says nothing over that)
  opening.dials = 1
  opening.first = Some(
    self.scope.fork(name="mesh open", () => {
      let made = attempt(() => self.dial_all(place, credentials, fresh, traceparent?=span.traceparent))
      self.dialled(place, opening, false, made)
    }),
  )
  opening
}

///|
/// A dial of `opening` ended (`beside`: the one tried beside its first, wake.mbt), with a link or failing. The
/// first link takes the opening, and the other dial, where one is under way, is given up; a link that comes to an
/// opening ended meanwhile (the other's took it, or its program let go of it) is closed. A failure waits for the
/// other dial where one has not ended; both failed, the opening fails with what its first did. One whose first
/// ran out of time with no connection made leaves the endpoint taken for stuck (`Mesh::rebind`).
fn Mesh::dialled(self : Mesh, place : Place, opening : Opening, beside : Bool, made : Tried[Link]) -> Unit {
  opening.dials -= 1
  match made {
    Did(link) => {
      // (not reached on this runtime, and kept: whoever ends an opening cuts its dials, and an interruption is a
      // fiber's as it next resumes, which for these is inside `Mesh::open`, whose leaving closes what it made.
      // Were one delivered later, a link nobody has would stay open here)
      guard opening.result is None else {
        link.close()
        return
      }
      opening.result = Some(Open(link))
      self.connect_said(place, opening, made, beside)
      // (what the endpoint's own dial says of it: a link on a way's own endpoint says nothing of it, ways.mbt)
      if link.pin is None {
        self.stuck = false
        self.note_dial(place, false)
      }
      if (if beside { opening.first } else { opening.hedge }) is Some(other) {
        other.interrupt()
      }
      // (closed there where its opening is no more its place's)
      self.adopt(place, opening, link)
      ignore(opening.done.succeed(link))
      self.eased()
    }
    Fell(e) => {
      guard opening.result is None else { return }
      if !beside {
        opening.failure = Some(e)
      }
      guard opening.dials == 0 else { return }
      self.connect_said(place, opening, Fell(opening.failure.unwrap_or(e)), beside)
      match opening.failure.unwrap_or(e) {
        OpeningTimeout(connected) => {
          if !connected {
            self.stuck = true
          }
          self.note_dial(place, true)
          let e = failed("no_answer")
          opening.result = Some(Failed(e, true))
          ignore(opening.done.fail(e))
        }
        e => {
          opening.result = Some(Failed(e, false))
          ignore(opening.done.fail(e))
        }
      }
      self.eased()
    }
  }
}

///|
/// `links` changed: whoever waits to be told of a link no more the one at its place looks again.
fn Mesh::changed(self : Mesh) -> Unit {
  let was = self.change
  self.change = @effect.Deferred::new()
  ignore(was.succeed(()))
}

///|
/// The link there is now to `peer` in `scope`, without dialling: the one last opened there, usable or not
/// (`Link::usable`); none where none was opened, one is being opened, or it was let go of.
pub fn Mesh::current(self : Mesh, peer : String, scope? : String = "") -> Link? {
  match self.links.get({ scope, peer }) {
    Some({ result: Some(Open(link)), .. }) => Some(link)
    _ => None
  }
}

///|
/// Whether `link` is the one at its place now.
fn Mesh::is_current(self : Mesh, link : Link) -> Bool {
  self.current(link.peer, scope=link.scope) is Some(now) && physical_equal(now, link)
}

///|
/// Waits until `link` is no more the link at its place: another is being opened in its place (it was no more
/// usable and its peer was asked for again, or it missed its pings), or it was let go of (`drop_link`, `close`). At
/// once where it already is not. Whoever goes on what a link brings (a stream of events, a request under way) waits
/// here beside it, and asks for the link again (`Mesh::link`) to go on. A link that only ended is not replaced
/// until then: its end is `Link::closed`'s to tell.
///
/// It does not say which: a link its program let go of and one another took the place of are told alike, and a
/// holder that asks for the link again as it is told dials anew after a `drop_link` too. A program that lets go of
/// a link to be rid of it stops its holders first.
pub async fn Mesh::replaced(self : Mesh, link : Link) -> Unit {
  // (looked at again after every wait: `links` changed for some place, perhaps not this one)
  while self.is_current(link) {
    self.change.wait()
  }
}

///|
/// Lets go of the link to `peer` in `scope`, open or being opened: taken for gone, so that the next `link` dials
/// anew. One open is closed, the peer told `reason` (its program's to say; "closed" unless said, as `Link::close`);
/// an opening under way is given up, the mesh's own for a link that missed its pings too, and whoever waits for it
/// fails as closed, as does whoever asked for the link and waits before a dial is made (`Mesh::hold`); a new link
/// raced beside it is given up with it. Its links in other scopes stay.
///
/// Nothing is kept of the one let go of: whoever holds it is told as of one replaced (`Mesh::replaced`) and, asking
/// for the link again, dials anew, so a program that wants the place left alone stops its holders before it calls
/// this. And a refusal of its credential is forgotten with it: the next `link` asks its source for the credential it
/// has, not for a new one, which a peer that refused the last may refuse once more.
pub fn Mesh::drop_link(self : Mesh, peer : String, scope? : String = "", reason? : String = "closed") -> Unit {
  let place : Place = { scope, peer }
  // (whoever asked for it and waits before any dial is made: told as of an opening given up)
  for one in self.held.copy() {
    if one.0 == Some(place) {
      ignore(one.1.fail(failed("closed")))
    }
  }
  self.held.retain(one => one.0 != Some(place))
  self.let_go(place, reason)
}

///|
/// What is at `place` is let go of, as `drop_link` says: its half that is of `links`. Whoever waits to dial there
/// is not told by this (the endpoint let go of whole to be bound on other relays leaves them to be dialled on
/// the one that comes: `Mesh::rehome`, bind.mbt).
fn Mesh::let_go(self : Mesh, place : Place, reason : String) -> Unit {
  guard self.links.get(place) is Some(opening) else { return }
  match opening.result {
    None => {
      // Ended here, before it is taken out: its fiber is cut, and one cut says nothing (as at `close`).
      if opening.span is Some(span) {
        opening.span = None
        (span.end)()
      }
      let e = failed("closed")
      opening.result = Some(Failed(e, false))
      ignore(opening.done.fail(e))
      for dial in [opening.first, opening.hedge] {
        if dial is Some(fiber) {
          fiber.interrupt()
        }
      }
    }
    Some(Open(link)) => {
      self.count(place.peer, link)
      link.close(reason~)
    }
    Some(Failed(_, _)) => ()
  }
  self.links.remove(place)
  // (its other ways go with it, and the endpoints of a way's own no way is on any more)
  if self.ways_of.get(place) is Some(ways) {
    for way in ways.all {
      if !(opening.result is Some(Open(link)) && physical_equal(link, way.link)) {
        way.link.close(reason~)
      }
    }
    ways.all.clear()
  }
  self.release_pinned()
  // (a link raced beside the one let go of goes with it: its place is no more to be taken)
  self.end_race(place)
  self.changed()
  self.tell_health(place)
  self.eased()
}

///|
/// Whether the endpoint is on one of its relays (at once with none). A dial given addresses does not ask
/// (`Mesh::open`): it goes on them at once, as the TypeScript mesh's.
fn Mesh::on_a_relay(self : Mesh, endpoint : Json) -> Bool {
  let said = self.shell.ask("iroh.relayStatus", { "id": endpoint }) catch { _ => return true }
  guard said is Array(relays) else { return true }
  if relays.length() == 0 {
    return true
  }
  for relay in relays {
    if relay is { "connected": True, .. } {
      return true
    }
  }
  false
}

///|
/// Connects, presents the first credential, and starts renewing it. The credential is asked for while the connection
/// is being made; the link is handed out as soon as the credential is sent (the peer reads it before any request
/// stream). A refusal closes the connection; the requests on it fail, and the next `link` starts over.
///
/// `on`: dialled on the endpoint of a way's own (ways.mbt) and its handle: through that relay alone, or at the
/// addresses the peer said of that kind alone; not said, on the endpoint.
async fn Mesh::open(
  self : Mesh,
  place : Place,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  on? : (String, Json),
  traceparent? : String,
) -> Link {
  let peer = place.peer
  // (the record's: each dial a line as it ends, while lines are kept; and its stages for its span: trace.mbt)
  self.dials_n += 1
  let n = self.dials_n
  let began = self.shell.rt.now()
  let since = () => (self.shell.rt.now() - began).to_int()
  let stages = Stages::new()
  let outcome = Ref("interrupted")
  self.record_dht(0)
  guard is_id(peer) else {
    raise MeshError(code="invalid_params", message=say("bad_station_id", args={ "id": peer }), cause="")
  }
  let shell = self.shell
  // The handshake, a fiber of the mesh's and not of this opening: the shell finishes it whoever waits, so its answer
  // is taken whatever became of the opening, and the connection closed if the opening has ended. Given up with the
  // opening (`give_up`): left going, it sends to every way to the peer until the connection's idle timeout.
  let abandoned = Ref(false)
  let call : Ref[Int64?] = Ref(None)
  let connection : Ref[Json?] = Ref(None)
  let dialled : @effect.Deferred[Json] = @effect.Deferred::new()
  // (and where the peer said it is dialled straight, where the endpoint may: then its time counts from now)
  let (pin, endpoint, relays, ips) = match on {
    None => (None, self.endpoint, self.relays_for(place), self.ips(place))
    Some((kind, endpoint)) if kind == lan || kind == tailnet => (Some(kind), endpoint, [], self.said_at(place, kind))
    Some((relay, endpoint)) => (Some(relay), endpoint, [relay], [])
  }
  let addr : Map[String, Json] = { "id": Json::string(peer), "relays": strings(relays) }
  if ips.length() > 0 {
    addr["ips"] = strings(ips)
  }
  let addr = Json::object(addr)
  let via = match pin {
    None => if ips.length() > 0 { "main+addresses" } else { "main" }
    Some(kind) if kind == lan || kind == tailnet => kind
    Some(relay) => "relay:\{relay_host(relay)}"
  }
  defer {
    self.record_dht(0)
    self.record("conn dial", () => "#\{n} \{peer_tag(place)} via=\{via} onto=\{ms_of(stages.onto)} credential=\{ms_of(stages.credential)} dialled=\{ms_of(stages.dialled)} openBi=\{ms_of(stages.open_bi)} sent=\{ms_of(stages.sent)} total=\{since()}ms -> \{outcome.val}")
  }
  ignore(
    self.scope.fork(name="mesh dial", () => {
      // (given up before this took its first step: nothing is dialled for it. The opening's own fiber forks this and
      // is cut only at a later step of its own, which on this runtime comes after this one's first)
      guard !abandoned.val else { return }
      let made = attempt(() => shell.call(
        "iroh.connect",
        { "id": endpoint, "addr": addr },
        bytes=@utf8.encode(self.options.alpn),
        called=id => call.val = Some(id),
      ))
      call.val = None
      stages.dialled = since()
      match made {
        Did({ json: { "id": conn, .. }, .. }) =>
          if abandoned.val {
            shell.tell("conn.close", { "id": conn, "code": 0, "reason": "opening ended", "forget": true })
          } else {
            connection.val = Some(conn)
            ignore(dialled.succeed(conn))
          }
        Did(_) => ignore(dialled.fail(failed("unreached")))
        Fell(e) => ignore(dialled.fail(unreached(e)))
      }
    }),
  )
  let opened = Ref(false)
  defer {
    if !opened.val {
      abandoned.val = true
      if call.val is Some(id) {
        shell.give_up(id)
      }
      // (closed to be forgotten: no link came of it, and nothing waits for its end to let go of it then)
      if connection.val is Some(conn) {
        shell.tell("conn.close", { "id": conn, "code": 0, "reason": "opening ended", "forget": true })
      }
    }
  }
  let raced = attempt(() => @effect.race_first(
    () => {
      let presented = credentials(self.id, fresh)
      stages.credential = since()
      let conn = dialled.wait()
      let first = shell.call("conn.openBi", { "id": conn }) catch { e => raise unreached(e) }
      stages.open_bi = since()
      guard first.json is { "id": stream, .. } else { raise failed("unreached") }
      let stream : Stream = { shell, id: stream }
      let control : Control = {
        stream,
        lines: { stream, carry: @wire.Carry::new(), most: max_head },
        says: self.options.says,
        refusal: self.options.refusal,
        named: false,
      }
      control.send(presented.credential, also?=presented.also, traceparent?)
      stages.sent = since()
      let link : Link = {
        peer,
        scope: place.scope,
        shell,
        conn,
        control,
        lock: @effect.Semaphore::new(1),
        credentials,
        credential: presented.credential,
        renewal_failed: false,
        refused: None,
        answer: None,
        answered: @effect.Deferred::new(),
        gone: @effect.Deferred::new(),
        came: 0,
        missed: 0,
        pinging: false,
        pinged_at: 0L,
        rx: 0,
        samples: 0,
        srtt: 0.0,
        dev: 0.0,
        answered_ms: None,
        warm: false,
        counted: (0L, 0L),
        opened: (
          if stages.onto < 0 { 0 } else { stages.onto },
          if stages.dialled < 0 { 0 } else { stages.dialled },
          stages.credential,
        ),
        recorded: (0L, 0L, Map([])),
        lan: [],
        tailnet: [],
        pin,
        fibers: self.scope,
        accepting: Accepting::new(),
      }
      link
    },
    // The opening's time: counted from when the endpoint is on a relay (getting onto one takes several round trips to
    // it), and it covers the whole opening, a handshake made whose credential or first stream never goes too.
    () => {
      for waited = 0; ips.length() == 0 && waited < onto_max_ms && !self.on_a_relay(endpoint); waited = waited + onto_recheck_ms {
        @effect.sleep(onto_recheck_ms)
      }
      stages.onto = since()
      @effect.sleep(connect_timeout_ms)
      raise OpeningTimeout(connection.val is Some(_))
    },
  ))
  let link = match raced {
    Did(link) => link
    Fell(e) => {
      outcome.val = outcome_of(e)
      raise e
    }
  }
  opened.val = true
  outcome.val = "ok"
  // Its answer and its end are said by the two fibers below, or, the mesh closed before they did, by `Mesh::close`:
  // the link is kept for that from here, before either is forked, until both are said.
  self.live.push(link)
  // Its end, waited for once: why it ended.
  ignore(
    self.scope.fork(name="mesh closed", () => {
      let said = attempt(() => shell.call("conn.closed", { "id": link.conn }))
      let closed = match said {
        Did(answer) => closed_of(answer.json).unwrap_or({ kind: "other", reason: "" })
        Fell(e) => { kind: "other", reason: text_of(e) }
      }
      ignore(link.gone.succeed(closed))
      // Its end is kept now, and the link answers from that (`Link::ended`): nothing is asked of the connection at
      // the shell again. Closed once more to be forgotten: both shells let go of it then, its streams with it.
      shell.tell("conn.close", { "id": link.conn, "code": 0, "reason": "closed", "forget": true })
      self.said(link)
    }),
  )
  // The peer's answer to the first credential, while requests already go: a refusal closes the link.
  ignore(
    self.scope.fork(name="mesh answer", () => {
      let answer = attempt(() => link.lock.with_permit(() => link.control.answer()))
      match answer {
        Did(answer) => {
          link.answer = Some(answer)
          link.lan = addrs_of(answer, "lan")
          link.tailnet = addrs_of(answer, "tailnet")
          self.heard(place, link)
        }
        Fell(e) => {
          link.renewal_failed = true
          link.refused = Some(e)
          shell.tell("conn.close", { "id": link.conn, "code": 0, "reason": "credential refused" })
        }
      }
      ignore(link.answered.succeed(()))
      self.said(link)
    }),
  )
  ignore(self.scope.fork(name="mesh renew", () => self.renew(link)))
  link
}

///|
/// A link whose answer and whose end are both said is no more `close`'s to say them of.
fn Mesh::said(self : Mesh, link : Link) -> Unit {
  if link.answered.is_done() && link.gone.is_done() {
    self.live.retain(one => !physical_equal(one, link))
    self.eased()
  }
}

///|
/// Presents a fresh credential every `renew_ms` until the link closes; one not had or refused leaves the link to run
/// out, and the next `link` opens another.
async fn Mesh::renew(self : Mesh, link : Link) -> Unit {
  while true {
    let closed = @effect.race_first(
      () => {
        @effect.sleep(renew_ms, later=true)
        false
      },
      () => {
        ignore(link.closed())
        true
      },
    )
    if closed {
      return
    }
    let renewed = attempt(() => {
      let presented = (link.credentials)(self.id, false)
      ignore(link.exchange(presented.credential))
      link.credential = presented.credential
    })
    if renewed is Fell(_) {
      link.renewal_failed = true
      return
    }
  }
}

///|
/// A link just opened is its place's, pinged from now on, and a way that answers (`Mesh::tell_health`); one opened
/// for a mesh closed meanwhile, or a place let go of, is closed.
fn Mesh::adopt(self : Mesh, place : Place, opening : Opening, link : Link) -> Unit {
  if self.closed || !(self.links.get(place) is Some(current) && physical_equal(current, opening)) {
    link.close()
    return
  }
  self.tell_health(place)
  ignore(self.scope.fork(name="mesh pings", () => self.steer(place, opening, link)))
  self.now_on(place, link)
  self.tally_if()
}

///|
/// The link's pings, every `tick_ms` while it is its place's and usable: how a peer gone from under it is found, and
/// how its place is told to be (`Mesh::tell_health`). After each, a link suspect is raced against a new one
/// (`Mesh::suspect`). One that missed `dead_pings` in a row is let go and its peer dialled anew, if it is its
/// place's still and no race is deciding of it: a ping is waited for, and meanwhile the link may have ended at the
/// shell and its peer been asked for again, whose opening is then the one in `links`, or its program may have let
/// go of it (`drop_link`), or a new link may have taken its place (`Mesh::switch`). That opening is the place's, not
/// this fiber's to take out, and no dial is made beside it; one let go of is not dialled for, nor is one that ended
/// while its ping was out (its peer closed it, with a reason: that is told, and its program asks again or does
/// not). The dial anew is the
/// place's opening in the step the link is let go in (`Mesh::dial`), not a step later: whoever is told the link is
/// no more the one there runs before anything this forks, and a program that lets go of the place then
/// (`drop_link`) must find the opening there to end it, or the mesh would dial on for a link nobody has.
async fn Mesh::steer(self : Mesh, place : Place, opening : Opening, link : Link) -> Unit {
  while true {
    @effect.sleep(tick_ms, later=true)
    guard !self.closed && self.links.get(place) is Some(current) && physical_equal(current, opening) && link.usable() else {
      return
    }
    self.ping(link)
    // (the ping was waited for: what is at its place is looked at anew, by each of these; a mesh closed meanwhile
    // has none there)
    self.tell_health(place)
    // (seen once a tick: here unless the place's ways are steered, which see it then, ways.mbt)
    if !self.closed && !self.ways_at(place).steering && self.links.get(place) is Some(now) && physical_equal(now, opening) {
      self.observe(place)
    }
    guard self.links.get(place) is Some(current) && physical_equal(current, opening) else {
      if link.missed >= dead_pings {
        link.close()
      }
      return
    }
    // Ended, or its renewal refused, while its ping was out: its end is its own to tell (`Link::closed`), and no
    // link is raced beside it nor dialled in its place until its program asks for one (`Mesh::link`). As the
    // TypeScript mesh, whose ways to a place are its usable links alone.
    guard link.usable() else { return }
    self.suspect(place, opening, link)
    // (while it is raced the race says what becomes of it: let go where neither answers, kept where it does)
    if link.missed >= dead_pings && !self.racing.contains(place) {
      // Another way up takes its place at once; else it is let go and the place dialled anew, every way raced
      // where it was the endpoint's (ways.mbt, `Mesh::dial_all`).
      let up = self.live_ways(place).filter(way => !physical_equal(way.link, link) && way.link.missed == 0)
      if self.best_way(place, self.takeable(place, up)) is Some(way) {
        self.promote(place, way, "lost")
        return
      }
      link.close()
      if link.pin is None && self.main_on(place) {
        self.ways_at(place).lost_main = true
      }
      ignore(self.dial(place, link.credentials, false, asker="again"))
      return
    }
  }
}

///|
/// One ping: the credential presented again, waited for `ping_timeout_ms`. One not answered by then is missed, unless
/// the link's replies brought something meanwhile (it waits behind them on the line); its exchange goes on, and no
/// other is sent over it until it ends. How long each took is the link's measure of its way (`Link::note`): one not
/// answered in time counts as that time, and again as what it took if it is answered after; the first answered is
/// not counted (it carried the link's own start).
async fn Mesh::ping(self : Mesh, link : Link) -> Unit {
  // (one under way that is not late yet is another's, a measuring asked meanwhile, ways.mbt `Mesh::sample`: not
  // counted twice)
  if link.pinging && self.shell.rt.now() - link.pinged_at < ping_timeout_ms.to_int64() {
    return
  }
  if link.pinging {
    if !link.brought() {
      link.missed += 1
    }
    link.note(ping_timeout_ms)
    return
  }
  link.pinging = true
  link.pinged_at = self.shell.rt.now()
  ignore(link.brought())
  // (how long it took; none: it failed)
  let answered : @effect.Deferred[Int?] = @effect.Deferred::new()
  let late = Ref(false)
  let rt = self.shell.rt
  ignore(
    self.scope.fork(name="mesh ping", () => {
      let started = rt.now()
      let exchanged = attempt(() => link.exchange(link.credential))
      let took = (rt.now() - started).to_int()
      link.pinging = false
      if late.val && exchanged is Did(_) {
        link.missed = 0
        link.note(took)
        link.answered_ms = Some(took)
      }
      ignore(answered.succeed(if exchanged is Did(_) { Some(took) } else { None }))
    }),
  )
  match @effect.timeout(ping_timeout_ms, () => answered.wait()) {
    Some(Some(took)) => {
      link.missed = 0
      link.answered_ms = Some(took)
      if link.warm {
        link.note(took)
      }
      link.warm = true
    }
    _ => {
      late.val = true
      if !link.brought() {
        link.missed += 1
      }
      link.note(ping_timeout_ms)
    }
  }
}

///|
/// Closes the links, then the endpoint: nothing is asked of it after. Whoever waits on it then is told: a `link`
/// being opened fails as closed, as does one that waits to dial (`Mesh::hold`) and `Link::admitted` of one the
/// peer had not answered, `Link::closed` gives that it was closed here, `Mesh::replaced` that its link is no
/// more the one there (none is), and `Mesh::health_change` fails as closed.
///
/// It says so itself, first, in the step it is called in: the telling needs nothing of the shell and waits for
/// nothing. Its fibers would have said (an opening's fiber its end, a link's two its answer and its end), but the
/// close cuts them, and a fiber cut before its first step runs nothing at all, no `defer` either: one forked in
/// the turn the mesh is closed, as a link is asked for or handed out. One not cut in time says nothing over what
/// was said here.
///
/// Then its fibers are cut and waited for. All end at once but one: an endpoint being bound anew
/// (`Mesh::rebind`), which nothing cuts short, since the shell binds whoever waits and the endpoint that comes is
/// to be closed. So the close itself, and it alone, waits there for the shell's answer to `iroh.bind`, as it
/// waits below for the shell's answers to its closes: for as long as the shell takes, which is the shell's to
/// bound.
///
/// And it is done whole once begun, its caller asked to stop meanwhile too: an interruption does not cut the
/// fibers' ends short (`Scope::close`); then the shell is asked, each connection's close before the endpoint's so
/// that a peer is given the reason, where an interruption waits as well (`@effect.uninterruptible`): its caller
/// stops as the close ends, not half way with a mesh that says it is closed, its fibers going and its endpoint
/// open.
pub async fn Mesh::close(self : Mesh) -> Unit {
  // (what the links carried is counted, and kept as it can be)
  self.count_open()
  self.keep_days()
  self.closed = true
  // (the openings as they are now: none is made from here)
  let openings = self.links.values().to_array()
  self.links.clear()
  for opening in openings {
    if opening.span is Some(span) {
      opening.span = None
      (span.end)()
    }
    if opening.result is None {
      let e = failed("closed")
      opening.result = Some(Failed(e, false))
      ignore(opening.done.fail(e))
    }
  }
  // (every link not ended: those of `links`, one another took the place of and not yet closed, one a race had
  // opened and not yet put anywhere)
  let open = self.live.copy()
  for link in open {
    if !link.answered.is_done() {
      link.renewal_failed = true
      link.refused = Some(failed("closed"))
      ignore(link.answered.succeed(()))
    }
    ignore(link.gone.succeed({ kind: "local", reason: "closed" }))
  }
  self.live.clear()
  self.racing.clear()
  // (the ways' own endpoints, closed below; one still being bound is closed as the shell answers, `pinned_endpoint`)
  let pinned = self.pinned.values().filter_map(one => one.endpoint).to_array()
  self.pinned.clear()
  self.ways_of.clear()
  self.retiring.clear()
  let taken = self.incomings.copy()
  self.incomings.clear()
  for incoming in taken {
    ignore(incoming.gone.succeed({ kind: "local", reason: "closed" }))
  }
  // (those dialled once: each one's own fiber, closing it already, ends as the fibers are waited for below)
  let dialled_once = self.outgoings.filter(one => !one.done)
  self.outgoings.clear()
  for one in dialled_once {
    one.done = true
    ignore(one.gone.succeed({ kind: "local", reason: "closed" }))
  }
  // (the wait for one a peer dials: whoever waits on it looks again, and finds the mesh closed; a connection it
  // had brought that nobody took is let go of)
  self.forget_coming()
  // (whoever waits to dial: for the endpoint to be bound anew, or to have nothing left on it)
  let held = self.held.copy()
  self.held.clear()
  for one in held {
    ignore(one.1.fail(failed("closed")))
  }
  self.changed()
  let waits = self.health_waits.copy()
  self.health_waits.clear()
  for wait in waits {
    ignore(wait.2.fail(failed("closed")))
  }
  // (a bind anew begun is waited for here, to its end: the endpoint is the one to close, whichever. One cut
  // before its first step asked nothing of the shell)
  self.scope.close()
  self.rebinding = false
  @effect.uninterruptible(() => {
    for link in open {
      ignore(attempt(() => self.shell.call("conn.close", { "id": link.conn, "code": 0, "reason": "closed", "forget": true })))
    }
    for incoming in taken {
      ignore(attempt(() => self.shell.call("conn.close", { "id": incoming.conn, "code": 0, "reason": "closed", "forget": true })))
    }
    for one in dialled_once {
      ignore(attempt(() => self.shell.call("conn.close", { "id": one.conn, "code": 0, "reason": "closed", "forget": true })))
      ignore(attempt(() => self.shell.call("iroh.close", { "id": one.endpoint, "forget": true })))
    }
    // (with it go the connections on it nobody took, and the wait for the next: `iroh.close`, in both shells)
    ignore(attempt(() => self.shell.call("iroh.close", { "id": self.endpoint, "forget": true })))
    for endpoint in pinned {
      ignore(attempt(() => self.shell.call("iroh.close", { "id": endpoint, "forget": true })))
    }
  })
}

///|
/// The wait between tries of something that failed (a link that went, a stream that ended): `first` ms, twice as long
/// each time, `most` at most; back to `first` once it went well (`reset`).
pub struct Backoff {
  first : Int
  most : Int
  priv mut wait : Int
}

///|
pub fn Backoff::new(first? : Int = 1_000, most? : Int = 30_000) -> Backoff {
  { first, most, wait: first }
}

///|
pub fn Backoff::reset(self : Backoff) -> Unit {
  self.wait = self.first
}

///|
/// Waits, and the next wait is twice as long.
pub async fn Backoff::pause(self : Backoff) -> Unit {
  @effect.sleep(self.wait)
  self.wait = if self.wait * 2 > self.most { self.most } else { self.wait * 2 }
}

///|
/// How something tried ended: what it gave, or what it failed with.
priv enum Tried[X] {
  Did(X)
  Fell(Error)
}

///|
/// What `f` gave, or what it failed with (a fiber's interruption is neither: it goes on out).
async fn[X] attempt(f : async () -> X) -> Tried[X] {
  try {
    Did(f())
  } catch {
    e => Fell(e)
  }
}
