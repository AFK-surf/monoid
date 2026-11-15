// How fast each way brings a peer's replies, and what each peer's links carried today: as the TypeScript mesh keeps
// them (client/core-ts/src/mesh.ts: `speed`, `noteSpeed`, `#forgetSpeeds`, `timed`, `cost`; `today`, `#count`,
// `#keepDays`, `#tally`; `Link.net`), with its numbers. A way's speed weighs in its score (`Mesh::score_of`, ways.mbt):
// a way through a relay seen bringing replies slowly costs what a `typical_bytes` reply takes to come through it.

///|
/// The key what each peer's links carried today is kept under, unless its program names another; how often it is
/// counted while links are open.
pub let net_day_key : String = "net-day"

///|
pub let tally_every_ms : Int = 60_000

///|
/// The key the speeds seen are kept under, unless its program names another.
pub let speed_key : String = "relay-speed"

///|
/// A reply this long or longer tells how fast a way is; a shorter one is mostly its round trip.
pub let speed_min_bytes : Int = 512 * 1024

///|
/// What a way's speed is weighed with its round trip by: the time a reply this long takes.
pub let typical_bytes : Int = 256 * 1024

///|
/// How long a speed seen counts; and how long the fastest seen holds against slower replies after it.
pub let speed_kept_ms : Int = 6 * 3600_000

///|
pub let speed_fresh_ms : Int = 10 * 60_000

///|
/// How often a way's speed is told at most, for each peer and relay (trace.mbt).
pub let speed_said_ms : Int = 60_000

///|
/// The wall's clock, beside the runtime's: what a day and a speed's age go by. A program gives its own (the time,
/// and how far east of UTC its clock is at a moment, in minutes); none: the runtime's, at UTC.
pub(all) struct WallClock {
  now_ms : () -> Int64
  utc_offset_min : (Int64) -> Int
}

///|
pub fn WallClock::of(rt : @effect.Runtime) -> WallClock {
  { now_ms: () => rt.now(), utc_offset_min: _ => 0 }
}

///|
/// The day a moment falls on where the clock is `offset_min` east of UTC, in days since 1970 (before it: below 0).
pub fn local_day(ms : Int64, offset_min : Int) -> Int64 {
  let at = ms + offset_min.to_int64() * 60_000L
  let day = 86_400_000L
  let q = at / day
  if at % day < 0L {
    q - 1L
  } else {
    q
  }
}

///|
/// What a way costs, in ms: its round trip, and what a `typical_bytes` reply takes to come through it at the speed it
/// was seen at (nothing while that is not known).
pub fn cost(ms : Double, bps : Double?) -> Double {
  match bps {
    Some(b) if b > 0.0 => ms + typical_bytes.to_double() / b * 1000.0
    _ => ms
  }
}

///|
/// A speed seen: bytes a second, and when.
priv struct Speed {
  bps : Double
  at : Int64
}

///|
/// What a peer's links carried on a day, both ways.
priv struct Day {
  day : Int64
  mut rx : Int64
  mut tx : Int64
}

///|
fn number_of(json : Json?) -> Double? {
  match json {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// What was kept of the speeds seen: `{"<peer>": {"<relay>": {"bps": n, "at": n}}}`; what is not that, nothing.
fn speeds_of(kept : Bytes?) -> Map[String, Map[String, Speed]] {
  let out : Map[String, Map[String, Speed]] = Map([])
  guard kept is Some(bytes) else { return out }
  let text = @utf8.decode(bytes) catch { _ => return out }
  let json : Json = @json.parse(text) catch { _ => return out }
  guard json is Object(peers) else { return out }
  for peer, relays in peers {
    guard relays is Object(relays) else { continue }
    let of : Map[String, Speed] = Map([])
    for relay, s in relays {
      guard s is Object(s) && number_of(s.get("bps")) is Some(bps) && number_of(s.get("at")) is Some(at) else {
        continue
      }
      of[relay] = { bps, at: at.to_int64() }
    }
    if of.length() > 0 {
      out[peer] = of
    }
  }
  out
}

///|
fn speeds_bytes(speeds : Map[String, Map[String, Speed]]) -> Bytes {
  let out : Map[String, Json] = Map([])
  for peer, relays in speeds {
    let of : Map[String, Json] = Map([])
    for relay, s in relays {
      of[relay] = { "bps": Json::number(s.bps), "at": Json::number(s.at.to_double()) }
    }
    out[peer] = Json::object(of)
  }
  @utf8.encode(Json::object(out).stringify())
}

///|
/// What was kept of the days: `{"<peer>": {"day": n, "rx": n, "tx": n}}`; what is not that, nothing.
fn days_of(kept : Bytes?) -> Map[String, Day] {
  let out : Map[String, Day] = Map([])
  guard kept is Some(bytes) else { return out }
  let text = @utf8.decode(bytes) catch { _ => return out }
  let json : Json = @json.parse(text) catch { _ => return out }
  guard json is Object(peers) else { return out }
  for peer, d in peers {
    guard d is Object(d) &&
      number_of(d.get("day")) is Some(day) &&
      number_of(d.get("rx")) is Some(rx) &&
      number_of(d.get("tx")) is Some(tx) else {
      continue
    }
    out[peer] = { day: day.to_int64(), rx: rx.to_int64(), tx: tx.to_int64() }
  }
  out
}

///|
fn days_bytes(days : Map[String, Day]) -> Bytes {
  let out : Map[String, Json] = Map([])
  for peer, d in days {
    out[peer] = {
      "day": Json::number(d.day.to_double()),
      "rx": Json::number(d.rx.to_double()),
      "tx": Json::number(d.tx.to_double()),
    }
  }
  @utf8.encode(Json::object(out).stringify())
}

///|
/// `value` written under `key` in the store, one writing at a time, as it is when its turn comes.
fn Mesh::keep(self : Mesh, key : String, value : () -> Bytes) -> Unit {
  ignore(
    self.scope.fork(name="mesh kept", () => self.keeping.with_permit(() => {
      let bytes = value()
      ignore(attempt(() => (self.store.set)(key, bytes)))
    })),
  )
}

///|
/// How fast replies from `peer` came through `relay` lately (bytes a second); none where none long enough did.
pub fn Mesh::speed(self : Mesh, peer : String, relay : String) -> Double? {
  match self.speeds.get(peer).bind(of => of.get(relay_key(relay))) {
    Some(s) if (self.clock.now_ms)() - s.at < speed_kept_ms.to_int64() => Some(s.bps)
    _ => None
  }
}

///|
/// `bytes` from `peer` came through `relay` in `ms`. The fastest seen lately counts (`speed_fresh_ms`): a reply also
/// comes slower than its way could bring it. The way requests go on found slower than it was taken to be: they are
/// moved at once if another is clearly better now (`Mesh::choose`).
pub fn Mesh::note_speed(self : Mesh, peer : String, relay : String, bytes : Int, ms : Int) -> Unit {
  guard bytes >= speed_min_bytes && ms > 0 else { return }
  let bps = bytes.to_double() / ms.to_double() * 1000.0
  let now = (self.clock.now_ms)()
  let key = relay_key(relay)
  let of = match self.speeds.get(peer) {
    Some(of) => of
    None => {
      let of : Map[String, Speed] = Map([])
      self.speeds[peer] = of
      of
    }
  }
  if of.get(key) is Some(was) && now - was.at < speed_fresh_ms.to_int64() && was.bps >= bps {
    return
  }
  let slower = match self.speed(peer, relay) {
    None => true
    Some(prev) => bps < prev
  }
  of[key] = { bps, at: now }
  for id in self.speeds.keys().to_array() {
    guard self.speeds.get(id) is Some(relays) else { continue }
    for r in relays.keys().to_array() {
      if relays.get(r) is Some(s) && now - s.at >= speed_kept_ms.to_int64() {
        relays.remove(r)
      }
    }
    if relays.length() == 0 {
      self.speeds.remove(id)
    }
  }
  self.keep(self.speeds_key, () => speeds_bytes(self.speeds))
  guard slower else { return }
  for place in self.links.keys().to_array() {
    if place.peer == peer &&
      self.current(peer, scope=place.scope) is Some(link) &&
      link.via() is Some(via) &&
      relay_key(via) == key {
      self.choose(place, Some("slow"))
    }
  }
}

///|
/// The speeds seen on every way let go of (the device on another network now).
fn Mesh::forget_speeds(self : Mesh) -> Unit {
  guard self.speeds.length() > 0 else { return }
  self.speeds.clear()
  self.keep(self.speeds_key, () => speeds_bytes(self.speeds))
}

///|
/// `reply`'s body timed as it is read (`Reply::take`, `Reply::rest`): once it brought `speed_min_bytes`, and again as
/// it ends, how fast its way brought bytes meanwhile is noted for `relay` (`Mesh::note_speed`): all that came
/// through it from `peer` since this one began coming, replies side by side sharing the line. The same reply, given
/// back.
pub fn Mesh::timed(self : Mesh, peer : String, relay : String, reply : Reply) -> Reply {
  let key = "\{peer} \{relay_key(relay)}"
  let first : Ref[Int64?] = Ref(None)
  let from = Ref(0)
  let own = Ref(0)
  let told = Ref(false)
  reply.on_piece = Some(chunk => {
    let now = self.shell.rt.now()
    let length = match chunk {
      Some(piece) => piece.length()
      None => 0
    }
    let came = self.came_by.get(key).unwrap_or(0) + length
    self.came_by[key] = came
    match first.val {
      None => if chunk is Some(_) {
        first.val = Some(now)
        from.val = came
      }
      Some(at) => {
        own.val += length
        if own.val >= speed_min_bytes && (chunk is None || !told.val) {
          told.val = true
          self.note_speed(peer, relay, came - from.val, (now - at).to_int())
        }
      }
    }
  })
  reply
}

///|
fn Mesh::local_day_now(self : Mesh) -> Int64 {
  let now = (self.clock.now_ms)()
  local_day(now, (self.clock.utc_offset_min)(now))
}

///|
/// What `link`, to `peer`, carried since it was last counted, added to `peer`'s day.
fn Mesh::count(self : Mesh, peer : String, link : Link) -> Unit {
  let (rx, tx) = link.uncounted()
  guard rx != 0L || tx != 0L else { return }
  let today = self.local_day_now()
  let d = match self.days.get(peer) {
    Some(d) if d.day == today => d
    _ => {
      let d : Day = { day: today, rx: 0L, tx: 0L }
      self.days[peer] = d
      d
    }
  }
  d.rx += rx
  d.tx += tx
  self.days_changed = true
}

///|
/// Every open link of `links` counted.
fn Mesh::count_open(self : Mesh, peer? : String) -> Unit {
  for place, opening in self.links {
    if opening.result is Some(Open(link)) && (peer is None || peer == Some(place.peer)) {
      self.count(place.peer, link)
    }
  }
}

///|
/// The days counted written where they changed, the days before today let go of.
fn Mesh::keep_days(self : Mesh) -> Unit {
  guard self.days_changed else { return }
  self.days_changed = false
  let today = self.local_day_now()
  for peer in self.days.keys().to_array() {
    if self.days.get(peer) is Some(d) && d.day != today {
      self.days.remove(peer)
    }
  }
  self.keep(self.days_key, () => days_bytes(self.days))
}

///|
/// What `peer`'s links carried on this device today, both ways, in every scope.
pub fn Mesh::today(self : Mesh, peer : String) -> (Int64, Int64) {
  self.count_open(peer~)
  match self.days.get(peer) {
    Some(d) if d.day == self.local_day_now() => (d.rx, d.tx)
    _ => (0L, 0L)
  }
}

///|
/// The links counted every `tally_every_ms` while any is open (timer: a sample of what this machine carried), from
/// the first that is; none while none is.
fn Mesh::tally_if(self : Mesh) -> Unit {
  guard !self.tallying && !self.closed else { return }
  self.tallying = true
  ignore(
    self.scope.fork(name="mesh tally", () => {
      defer {
        self.tallying = false
      }
      while true {
        @effect.sleep(tally_every_ms, later=true)
        guard !self.closed && self.links.length() > 0 else { return }
        self.count_open()
        self.keep_days()
      }
    }),
  )
}

///|
/// Packets sent and lost on the way in use (`path` its id) since it opened.
#derive(Debug, Eq)
pub(all) struct Packets {
  path : String
  sent : Int64
  lost : Int64
}

///|
/// How a link runs: the way it goes now ("relay", "direct", or "tailnet" for a tailnet way going straight), the
/// relay's host where through one, its round trip, what it carried both ways, the packets of the way in use.
#derive(Debug, Eq)
pub(all) struct LinkNet {
  path : String?
  relay : String?
  rtt_ms : Double?
  rx_bytes : Int64
  tx_bytes : Int64
  packets : Packets?
}

///|
fn Link::stats(self : Link) -> (Int64, Int64) {
  let said = self.shell.ask("conn.stats", { "id": self.conn }) catch { _ => return (0L, 0L) }
  let of = (key : String) => match said {
    Object(fields) => number_of(fields.get(key)).unwrap_or(0.0).to_int64()
    _ => 0L
  }
  (of("rxBytes"), of("txBytes"))
}

///|
/// What went over it, both ways, since this was last asked.
fn Link::uncounted(self : Link) -> (Int64, Int64) {
  let (rx, tx) = self.stats()
  let (was_rx, was_tx) = self.counted
  self.counted = (rx, tx)
  ((if rx > was_rx { rx - was_rx } else { 0L }), if tx > was_tx { tx - was_tx } else { 0L })
}

///|
pub fn Link::net(self : Link) -> LinkNet {
  let selected = self.paths().search_by(path => path is { "selected": True, .. }).map(i => self.paths()[i])
  let (rx, tx) = self.stats()
  match selected {
    None => { path: None, relay: None, rtt_ms: None, rx_bytes: rx, tx_bytes: tx, packets: None }
    Some(path) => {
      let relay = match path {
        { "relay": String(relay), .. } => Some(relay)
        _ => None
      }
      let field = (key : String) => match path {
        Object(fields) => fields.get(key)
        _ => None
      }
      let id = match field("id") {
        Some(String(id)) => id
        Some(Number(n, ..)) => n.to_int64().to_string()
        _ => ""
      }
      {
        path: Some(
          if relay is Some(_) {
            "relay"
          } else if self.pin == Some(tailnet) {
            tailnet
          } else {
            direct
          },
        ),
        relay: relay.map(relay_host),
        rtt_ms: number_of(field("rttMs")),
        rx_bytes: rx,
        tx_bytes: tx,
        packets: Some({
          path: id,
          sent: number_of(field("txPackets")).unwrap_or(0.0).to_int64(),
          lost: number_of(field("lostPackets")).unwrap_or(0.0).to_int64(),
        }),
      }
    }
  }
}
