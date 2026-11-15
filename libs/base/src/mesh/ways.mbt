// The ways to a place and the choice among them: as the TypeScript mesh does (client/core-ts/src/mesh.ts: `Way`,
// `#dialAll`, `#pinnedEndpoint`, `#letGo`, `#adopt`, `#promote`, `#choose`, `#prune`, `#retire`, `#explore`, `#steer`,
// `#turnOff`, `#lostDirect`, `measured`, `remeasure`), with its numbers.
//
// A way is a link to the place: the one on the endpoint (`main`: through the endpoint's relays, the addresses the
// peer said, a path iroh punches), one on an endpoint bound on one relay alone (`pinned`: a relay of the endpoint's,
// or one of the peer's own its program names, `Mesh::link`'s `theirs`), one on an endpoint that dials the addresses
// the peer said on its LAN or its tailnet alone (`lan`, `tailnet`: no relay, no hole punched). The link the place's
// requests go on is the one in `links`; the others open beside it are kept (`KEEP_WAYS` at most), pinged, and moved
// to as they prove clearly better for long enough (`Mesh::choose`), or at once where it is lost.
//
// A place is dialled on the endpoint alone, as before there were ways, unless its program turned the endpoint's ways
// off (`Mesh::link`'s `off`: "direct", or a relay of the endpoint's), its direct ways are held off for being flaky
// (`Mesh::lost_direct`), its last dial there went unanswered given the addresses it would be given again
// (`unanswered_at`, addrs.mbt), or its link there was let go of for its pings: then every way is raced, and the first
// let in is its link (`Mesh::dial_all`).
//
// Where this is not that mesh's: the endpoint on a LAN or tailnet is bound with a key drawn for it (there one made
// over from the device's, as a relay's is); a relay's endpoint's key is made with the prefix its program gives
// (`Mesh::make`'s `pinned_prefix`); a relay's entries are no ways of their own here; and the endpoint's way, gone
// from a place another way reaches, is dialled again every `REDIAL_MAIN_MS` wherever the endpoint's ways are on (that
// mesh's `#steer` skips that branch for every place whose endpoint's ways are on, which is every place it applies
// to), unless its last dial went unanswered given the same addresses, or a LAN way answered within `LAN_RECALL_MS`.

///|
/// The ways kept open to a place: the one its requests go on, and the best of the others.
pub let keep_ways : Int = 2

///|
/// Pings a way needs counted before it is compared with another.
pub let min_samples : Int = 3

///|
/// Ticks in a row a way must be clearly better than the one requests go on before they move to it.
let better_ticks : Int = 6

///|
/// How long requests stay on a way they moved to before they may move again, unless it is lost or a person asks.
pub let min_stay_ms : Int = 180_000

///|
/// What a way must be quicker by, at least, for requests to move to it (`clearly_better`).
pub let move_gain : Double = 0.3

///|
/// How often the ways not open to a place are dialled again (`Mesh::explore`).
pub let explore_ms : Int = 300_000

///|
/// How often the endpoint's way, gone from a place, is dialled again; and the LAN way, while a way direct reached
/// the place within `direct_recall_ms`.
pub let redial_main_ms : Int = 30_000

///|
pub let direct_recall_ms : Int = 600_000

///|
/// While a LAN way answered within this long, requests keep off the endpoint's way unless no other is up.
pub let lan_recall_ms : Int = 600_000

///|
/// A way direct lost within `min_stay_ms` of requests moving to it this many times in a row holds ways direct off
/// for `direct_hold_ms`, twice as long each time again, `direct_hold_max_ms` at most.
let flaky_losses : Int = 2

///|
pub let direct_hold_ms : Int = 120_000

///|
pub let direct_hold_max_ms : Int = 30 * 60_000

///|
/// What a relay's endpoint's key is made with unless its program says another (`Mesh::make`'s `pinned_prefix`).
pub let relay_key_prefix : Bytes = b"mesh/relay-endpoint/1\x00"

///|
/// The kinds of way at an address the peer said, each on an endpoint of its own; and the endpoint's punched path.
let lan : String = "lan"

///|
let tailnet : String = "tailnet"

///|
let direct : String = "direct"

///|
/// A way as compared with another: what a request is expected to take on it at worst (its smoothed round trip and
/// twice its deviation), and its deviation. Where a way's speed comes to count, it goes in `cost`.
#derive(Debug, Eq)
pub(all) struct Score {
  cost : Double
  dev : Double
}

///|
/// Whether `other` is clearly better than `cur`: quicker by `move_gain` at least, and by more than what the two vary
/// by (half their deviations together), so two ways as good as each other are not swapped back and forth.
pub fn clearly_better(cur : Score, other : Score) -> Bool {
  other.cost <= cur.cost * (1.0 - move_gain) && other.cost + (cur.dev + other.dev) / 2.0 < cur.cost
}

///|
/// The key of the endpoint on `relay` alone: SHA-256 of `prefix`, the device's key and the relay as written.
fn pinned_key(prefix : Bytes, secret : Bytes, relay : String) -> Bytes {
  let all : Array[Byte] = []
  for b in prefix {
    all.push(b)
  }
  for b in secret {
    all.push(b)
  }
  for b in @utf8.encode(relay) {
    all.push(b)
  }
  sha256(Bytes::from_array(all))
}

///|
/// A relay as a key: trimmed, and `https://r` one with `https://r/`.
fn relay_key(relay : String) -> String {
  let text = relay.trim().to_owned()
  let mut slashes = 0
  for c in text {
    if c == '/' {
      slashes += 1
    }
  }
  if text.contains("://") && slashes == 2 {
    text + "/"
  } else {
    text
  }
}

///|
/// One way to a place: its link, whose pings are its measure (`Link::note`), and the ticks in a row it was clearly
/// better than the one requests go on.
priv struct Way {
  link : Link
  mut better : Int
  /// Its link's paths as the last tick saw them, and which they were (trace.mbt, `Mesh::watch_paths`).
  mut saw : String?
  mut shape : String?
}

///|
fn Way::new(link : Link) -> Way {
  { link, better: 0, saw: None, shape: None }
}


///|
/// Where it goes: "lan", "tailnet", its relay (as a key), "direct" (a path iroh punched), or "main" (the endpoint's
/// way, no path chosen yet).
fn Way::key(self : Way) -> String {
  match self.link.pin {
    Some(pin) => if pin == lan || pin == tailnet { pin } else { relay_key(pin) }
    None =>
      match self.link.via() {
        Some(relay) => relay_key(relay)
        None => if self.link.path() == Some(direct) { direct } else { "main" }
      }
  }
}

///|
/// Whether it goes direct: on the LAN endpoint, or a path iroh punched.
fn Way::is_direct(self : Way) -> Bool {
  self.link.pin == Some(lan) || self.key() == direct
}

///|
/// An endpoint bound on one way alone, by that way: its handle once bound (none while it is being bound).
priv struct Pinned {
  ready : @effect.Deferred[Json?]
  mut endpoint : Json?
}

///|
/// What is kept of a place's ways: those open (the link requests go on among them), what its program said of them,
/// and when each thing last happened.
priv struct Ways {
  all : Array[Way]
  mut theirs : Array[String]
  mut off : Array[String]
  mut steering : Bool
  mut exploring : Bool
  mut explored_at : Int64?
  mut main_dialled_at : Int64?
  /// When requests last moved (the place's link first opened, or another moved to), and whether to a way direct.
  mut moved_at : Int64?
  mut moved_direct : Bool
  /// Ways direct lost soon after requests moved to them, in a row; and until when they are held off.
  mut losses : Int
  mut held_until : Int64?
  /// When a LAN way last answered, and a way direct was last open.
  mut lan_at : Int64?
  mut direct_at : Int64?
  /// Its link on the endpoint let go of for its pings: the next dial races every way.
  mut lost_main : Bool
  /// Requests moved to another way this many times, and where to last (a relay's host, or "direct"); a tailnet way
  /// answered a ping since the last wake.
  mut moves : Int
  mut moved : String?
  mut tailnet_answered : Bool
  /// By kind (lan, tailnet): the addresses last dialled, when, and whether a dial is under way.
  tried : Map[String, String]
  at_dialled_at : Map[String, Int64]
  at_dialling : Map[String, Unit]
}

///|
/// What one way to a place is now, as `Mesh::measured` says it.
#derive(Debug, Eq)
pub(all) struct MeasuredWay {
  /// Where it goes ("main", "direct", "lan", "tailnet", or a relay), and what it is on ("main": the endpoint;
  /// "relay": an endpoint on that relay alone; "lan", "tailnet").
  way : String
  kind : String
  /// Requests go on it; it answers its pings (has not missed `dead_pings` in a row).
  active : Bool
  healthy : Bool
  samples : Int
  srtt : Double
  dev : Double
  missed : Int
}

///|
fn Mesh::now_ms(self : Mesh) -> Int64 {
  self.shell.rt.now()
}

///|
/// How long since `at`; forever where it never was.
fn Mesh::since(self : Mesh, at : Int64?) -> Int64 {
  match at {
    Some(at) => self.now_ms() - at
    None => 9_223_372_036_854_775_807L
  }
}

///|
fn Mesh::ways_at(self : Mesh, place : Place) -> Ways {
  match self.ways_of.get(place) {
    Some(ways) => ways
    None => {
      let ways : Ways = {
        all: [],
        theirs: [],
        off: [],
        steering: false,
        exploring: false,
        explored_at: None,
        main_dialled_at: None,
        moved_at: None,
        moved_direct: false,
        losses: 0,
        held_until: None,
        lan_at: None,
        direct_at: None,
        lost_main: false,
        moves: 0,
        moved: None,
        tailnet_answered: false,
        tried: Map([]),
        at_dialled_at: Map([]),
        at_dialling: Map([]),
      }
      self.ways_of[place] = ways
      ways
    }
  }
}

///|
/// A relay as people see it named: its host, with its port where one is said.
fn relay_host(relay : String) -> String {
  let text = relay.trim().to_owned()
  let out = StringBuilder()
  // (past "://" where there is one, up to the next "/")
  let start = if text.contains("://") { 0 } else { -1 }
  let mut slashes = if start == 0 { 0 } else { 2 }
  for c in text {
    if slashes < 2 {
      if c == '/' {
        slashes += 1
      }
      continue
    }
    if c == '/' {
      break
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
/// Whether its program turned `way` off at `place` (a relay, "direct", "lan", "tailnet"); the ways at an address
/// are off everywhere for a mesh through relays alone.
fn Mesh::is_off(self : Mesh, place : Place, way : String) -> Bool {
  if self.options.relay_only && (way == lan || way == tailnet) {
    return true
  }
  guard self.ways_of.get(place) is Some(ways) else { return false }
  let key = relay_key(way)
  ways.off.iter().any(off => off == way || off == key)
}

///|
/// The relays `place` is dialled through: the endpoint's, then the peer's own its program named, but those off.
fn Mesh::relays_for(self : Mesh, place : Place) -> Array[String] {
  let out = self.relays.copy()
  if self.ways_of.get(place) is Some(ways) {
    for relay in ways.theirs {
      if !out.iter().any(one => relay_key(one) == relay_key(relay)) {
        out.push(relay)
      }
    }
  }
  out.filter(relay => !self.is_off(place, relay))
}

///|
/// Every way `place` is dialled through: its relays (`relays_for`), then the endpoint's relays' entries, each as a
/// relay of its own; not those while any of the endpoint's relays is off (an entry goes through which is not known
/// here).
fn Mesh::ways_for(self : Mesh, place : Place) -> Array[String] {
  let out = self.relays_for(place)
  if self.relays.iter().any(relay => self.is_off(place, relay)) {
    return out
  }
  for e in self.entries {
    if !out.iter().any(one => relay_key(one) == relay_key(e.entry)) && !self.is_off(place, e.entry) {
      out.push(e.entry)
    }
  }
  out
}

///|
/// Whether the endpoint's ways to `place` are on by what its program turned off: not "direct", and none of the
/// endpoint's relays (it is home on them, and which it goes through is iroh's to choose).
fn Mesh::main_allowed(self : Mesh, place : Place) -> Bool {
  !self.is_off(place, direct) && !self.relays.iter().any(relay => self.is_off(place, relay))
}

///|
/// Whether `place` is dialled on the endpoint: its ways allowed, and ways direct not held off for being flaky.
fn Mesh::main_on(self : Mesh, place : Place) -> Bool {
  self.main_allowed(place) && !self.direct_held(place)
}

///|
fn Mesh::direct_held(self : Mesh, place : Place) -> Bool {
  match self.ways_of.get(place) {
    Some({ held_until: Some(until), .. }) => self.now_ms() < until
    _ => false
  }
}

///|
/// The relays dialled each on an endpoint of its own: with the endpoint's ways on, those but its first relay (the
/// endpoint reaches it), and none while there is one way or none; with them off, every relay left.
fn Mesh::pinnable(self : Mesh, place : Place) -> Array[String] {
  let ways = self.ways_for(place)
  if !self.main_on(place) {
    return ways
  }
  guard ways.length() >= 2 else { return [] }
  match self.relays.get(0) {
    Some(own) => ways.filter(relay => relay_key(relay) != relay_key(own))
    None => ways
  }
}

///|
/// Where the peer at `place` said it is on `kind` ("lan", "tailnet").
fn Mesh::said_at(self : Mesh, place : Place, kind : String) -> Array[String] {
  match self.said.get(place.key()) {
    Some(said) => if kind == lan { said.lan } else { said.tailnet }
    None => []
  }
}

///|
/// Whether `link`, open to `place`, goes a way its program turned off.
fn Mesh::way_off(self : Mesh, place : Place, link : Link) -> Bool {
  match link.pin {
    None => !self.main_allowed(place)
    Some(kind) if kind == lan || kind == tailnet => self.is_off(place, kind)
    Some(relay) => !self.ways_for(place).iter().any(one => relay_key(one) == relay_key(relay))
  }
}

///|
/// Whether requests keep off `way` while another is up: one direct while those are held off, the endpoint's while a
/// LAN way answered lately.
fn Mesh::avoided(self : Mesh, place : Place, way : Way) -> Bool {
  if self.direct_held(place) && way.is_direct() {
    return true
  }
  way.link.pin is None && self.since(self.ways_at(place).lan_at) < lan_recall_ms.to_int64()
}

///|
/// Of `ways`, those requests may move to: those not avoided; all, where every one is.
fn Mesh::takeable(self : Mesh, place : Place, ways : Array[Way]) -> Array[Way] {
  let others = ways.filter(way => !self.avoided(place, way))
  if others.length() > 0 {
    others
  } else {
    ways
  }
}

///|
/// A way as compared with another: its round trip and what a `typical_bytes` reply takes through its relay at the
/// speed seen there (speed.mbt), and twice its deviation.
fn Mesh::score_of(self : Mesh, place : Place, way : Way) -> Score {
  let speed = match way.link.via() {
    Some(via) => self.speed(place.peer, via)
    None => None
  }
  { cost: cost(way.link.srtt, speed) + 2.0 * way.link.dev, dev: way.link.dev }
}

///|
/// Of `ways`, the one scoring best of those pinged; none pinged yet: the first.
fn Mesh::best_way(self : Mesh, place : Place, ways : Array[Way]) -> Way? {
  let mut best : Way? = None
  for way in ways {
    match best {
      None => best = Some(way)
      Some(b) =>
        if way.link.samples > 0 &&
          (b.link.samples == 0 || self.score_of(place, way).cost < self.score_of(place, b).cost) {
          best = Some(way)
        }
    }
  }
  best
}

///|
/// The ways open to `place` that are still up; those that are not are forgotten. Not closed here: one whose renewal
/// was refused runs out as its peer ends it, as the place's link does (mesh.mbt; the TypeScript mesh closes it).
fn Mesh::live_ways(self : Mesh, place : Place) -> Array[Way] {
  guard self.ways_of.get(place) is Some(ways) else { return [] }
  let live = ways.all.filter(way => way.link.usable())
  if live.length() != ways.all.length() {
    ways.all.clear()
    ways.all.append(live)
  }
  live
}

///|
/// The way `link`, the place's link from now (`Mesh::adopt`), is among its ways; requests moved to it now.
fn Mesh::now_on(self : Mesh, place : Place, link : Link) -> Unit {
  let ways = self.ways_at(place)
  if !ways.all.iter().any(way => physical_equal(way.link, link)) {
    ways.all.push(Way::new(link))
  }
  ways.moved_at = Some(self.now_ms())
  ways.moved_direct = Way::new(link).is_direct()
  // (its answer came before it was a way: heard now)
  if link.answer is Some(_) {
    self.heard(place, link)
  }
  self.steer_if(place)
}

///|
/// `link` is a way to `place` as well, if it is still wanted (the place not let go of, the way not turned off
/// meanwhile); pinged from now on. Else closed.
fn Mesh::adopt_way(self : Mesh, place : Place, link : Link) -> Unit {
  if self.closed || !self.links.contains(place) || self.way_off(place, link) {
    link.close()
    self.release_pinned()
    return
  }
  let ways = self.ways_at(place)
  ignore(self.live_ways(place))
  if ways.all.iter().any(way => physical_equal(way.link, link)) {
    return
  }
  ways.all.push(Way::new(link))
  if link.answer is Some(_) {
    self.heard(place, link)
  }
  self.tell_health(place)
  self.steer_if(place)
}

///|
/// Whether `place` has ways to choose among: more than one open, one on an endpoint of its own, or the endpoint's
/// ways off. With one way on the endpoint, its link's own fiber (`Mesh::steer`) is all there is, as before.
fn Mesh::many(self : Mesh, place : Place) -> Bool {
  let live = self.live_ways(place)
  live.length() > 1 || live.iter().any(way => way.link.pin is Some(_)) || !self.main_on(place)
}

///|
/// The ways of `place` steered (`Mesh::steer_ways`), unless they are or there is nothing to choose among.
fn Mesh::steer_if(self : Mesh, place : Place) -> Unit {
  let ways = self.ways_at(place)
  guard !ways.steering && !self.closed && self.links.contains(place) && self.many(place) else { return }
  ways.steering = true
  // (cut, only as the mesh closes: then nothing is steered again)
  ignore(
    self.scope.fork(name="mesh ways", () => {
      defer {
        ways.steering = false
      }
      self.steer_ways(place)
    }),
  )
}

///|
/// While `place` has ways to choose among: every `tick_ms` those requests do not go on are pinged (the one they go on
/// is its own fiber's, `Mesh::steer`), requests moved to the best (`Mesh::choose`), the ways not worth keeping let go
/// (`Mesh::prune`), its ways at an address dialled where new, and every `explore_ms` the ways not open dialled again
/// (`Mesh::explore`); the endpoint's way, gone where it is on again, every `redial_main_ms`.
async fn Mesh::steer_ways(self : Mesh, place : Place) -> Unit {
  let ways = self.ways_at(place)
  while true {
    @effect.sleep(tick_ms, later=true)
    guard !self.closed && self.links.contains(place) else { return }
    let cur = self.current(place.peer, scope=place.scope)
    if self.live_ways(place).length() == 0 && !(cur is Some(link) && link.usable()) {
      return
    }
    self.sample(place, false)
    // (the pings were waited for: the place looked at anew)
    guard !self.closed && self.links.contains(place) else { return }
    self.tell_health(place)
    // (seen once a tick: here while the ways are steered, by the link's own fiber otherwise)
    self.observe(place)
    self.choose(place, None)
    self.prune(place)
    let now = self.now_ms()
    if ways.moved_direct && self.since(ways.moved_at) >= min_stay_ms.to_int64() {
      ways.losses = 0
    }
    let live = self.live_ways(place)
    if live.iter().any(way => way.is_direct()) {
      ways.direct_at = Some(now)
    }
    if live.iter().any(way => way.link.pin == Some(lan) && way.link.missed == 0 && way.link.samples > 0) {
      ways.lan_at = Some(now)
    }
    if live.iter().any(way => way.link.pin == Some(tailnet) && way.link.missed == 0 && way.link.samples > 0) {
      ways.tailnet_answered = true
    }
    let credentials = match self.current(place.peer, scope=place.scope) {
      Some(link) => Some(link.credentials)
      None => live.get(0).map(way => way.link.credentials)
    }
    guard credentials is Some(credentials) else { continue }
    guard self.many(place) else { return }
    if !self.main_on(place) {
      for kind in [lan, tailnet] {
        self.dial_at_if(place, kind, credentials)
      }
    }
    if self.since(ways.explored_at) >= explore_ms.to_int64() {
      ignore(self.scope.fork(name="mesh explore", () => self.explore(place, credentials, false)))
    } else if self.main_on(place) &&
      !live.iter().any(way => way.link.pin is None) &&
      self.since(ways.lan_at) >= lan_recall_ms.to_int64() &&
      !self.unanswered_straight(place) &&
      self.since(ways.main_dialled_at) >= redial_main_ms.to_int64() {
      ignore(self.scope.fork(name="mesh explore", () => self.explore(place, credentials, true)))
    }
  }
}

///|
/// Every way open to `place` pinged at once, and waited for; `every`: the one requests go on as well (one whose
/// ping is out is let be: it is under way).
async fn Mesh::sample(self : Mesh, place : Place, every : Bool) -> Unit {
  let cur = self.current(place.peer, scope=place.scope)
  let links = self
    .live_ways(place)
    .filter(way => !way.link.pinging && (every || !(cur is Some(c) && physical_equal(c, way.link))))
    .map(way => way.link)
  guard links.length() > 0 else { return }
  let left = Ref(links.length())
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  for link in links {
    ignore(
      self.scope.fork(name="mesh way ping", () => {
        defer {
          left.val -= 1
          if left.val == 0 {
            ignore(done.succeed(()))
          }
        }
        self.ping(link)
      }),
    )
  }
  done.wait()
}

///|
/// Moves `place`'s requests to the best way if it is clearly better than theirs `better_ticks` ticks in a row (and
/// they stayed `min_stay_ms` where they are), or at once where `asked` (a person asks); to the best way left at once
/// where theirs is gone or missed `dead_pings`. A way direct (on the LAN, or a path iroh punched) answering clearly
/// quicker is moved to at once, unless those are held off.
fn Mesh::choose(self : Mesh, place : Place, asked : String?) -> Unit {
  guard self.links.get(place) is Some({ result: Some(_), .. }) else { return }
  let cur = self.current(place.peer, scope=place.scope)
  let ways = self.live_ways(place)
  let up = ways.filter(way => way.link.missed < dead_pings)
  let mine = match cur {
    Some(link) => ways.search_by(way => physical_equal(way.link, link)).map(i => ways[i])
    None => None
  }
  guard cur is Some(cur) && cur.usable() && mine is Some(mine) && mine.link.missed < dead_pings else {
    let others = up.filter(way => !(cur is Some(c) && physical_equal(c, way.link)))
    if self.best_way(place, self.takeable(place, others)) is Some(way) {
      self.promote(place, way, "lost")
    }
    return
  }
  if !self.direct_held(place) && mine.link.samples > 0 && mine.link.pin != Some(lan) {
    let found = up.search_by(way => !physical_equal(way.link, cur) &&
      way.link.pin == Some(lan) &&
      way.link.samples > 0 &&
      way.link.missed == 0)
    if found is Some(i) && (mine.key() == direct || clearly_better(self.score_of(place, mine), self.score_of(place, up[i]))) {
      self.promote(place, up[i], lan)
      return
    }
    if mine.key() != direct {
      let directs = up.filter(way => !physical_equal(way.link, cur) &&
        way.link.samples > 0 &&
        way.link.missed == 0 &&
        way.key() == direct &&
        !self.avoided(place, way))
      if self.best_way(place, directs) is Some(way) && clearly_better(self.score_of(place, mine), self.score_of(place, way)) {
        self.promote(place, way, direct)
        return
      }
    }
  }
  guard mine.link.samples >= min_samples else { return }
  guard asked is Some(_) || self.since(self.ways_at(place).moved_at) >= min_stay_ms.to_int64() else { return }
  let challengers = up.filter(way => !physical_equal(way.link, cur) &&
    way.link.samples >= min_samples &&
    !self.avoided(place, way))
  let top = self.best_way(place, challengers)
  for way in ways {
    if !(top is Some(t) && physical_equal(t, way)) {
      way.better = 0
    }
  }
  guard top is Some(top) else { return }
  if !clearly_better(self.score_of(place, mine), self.score_of(place, top)) {
    top.better = 0
    return
  }
  top.better += 1
  if asked is Some(why) {
    self.promote(place, top, why)
  } else if top.better >= better_ticks {
    self.promote(place, top, "better")
  }
}

///|
/// `place`'s requests go on `way` from now: the place's link in this step, whoever holds the one before told
/// (`Mesh::replaced`), which stays open as another way. Not over an opening under way (its waiters are its own).
fn Mesh::promote(self : Mesh, place : Place, way : Way, why : String) -> Unit {
  guard !self.closed && self.links.get(place) is Some({ result: Some(_), .. }) else { return }
  if self.current(place.peer, scope=place.scope) is Some(before) && physical_equal(before, way.link) {
    return
  }
  let ways = self.ways_at(place)
  let held = if why == "lost" && ways.moved_direct { self.lost_direct(place, self.since(ways.moved_at)) } else { None }
  // (told as `mesh.route`: from where, to where, why, how each scored; trace.mbt)
  let span = self.span("mesh.route", place.peer)
  (span.own)("why", Str(why))
  if self.current(place.peer, scope=place.scope) is Some(before) &&
    ways.all.search_by(one => physical_equal(one.link, before)) is Some(i) {
    let was = ways.all[i]
    (span.own)("from", Str(was.key()))
    (span.own)("from.score", Int(self.score_of(place, was).cost.round().to_int64()))
    (span.own)("from.missed", Int(was.link.missed.to_int64()))
    (span.own)("from.paths", Str(was.link.paths_line()))
  }
  (span.own)("to", Str(way.key()))
  (span.own)("to.score", Int(self.score_of(place, way).cost.round().to_int64()))
  (span.own)("to.paths", Str(way.link.paths_line()))
  if held is Some(ms) {
    (span.own)("direct_held_ms", Int(ms))
  }
  (span.end)()
  // (a race of the link before has nothing left to decide; what it carried is counted)
  self.end_race(place)
  if self.current(place.peer, scope=place.scope) is Some(before) {
    self.count(place.peer, before)
  }
  let taken = Opening::new(way.link.credentials, false)
  taken.result = Some(Open(way.link))
  ignore(taken.done.succeed(way.link))
  self.links[place] = taken
  self.changed()
  ways.moved_at = Some(self.now_ms())
  ways.moved_direct = way.is_direct()
  ways.moves += 1
  ways.moved = Some(
    match way.link.via() {
      Some(via) => relay_host(via)
      None => direct
    },
  )
  for one in ways.all {
    one.better = 0
  }
  self.tell_health(place)
  // (its pings are its own fiber's from now, as any place's link's)
  ignore(self.scope.fork(name="mesh pings", () => self.steer(place, taken, way.link)))
}

///|
/// The way direct requests went on was lost, `stayed` ms after they moved to it: lost soon after, `flaky_losses`
/// times in a row, ways direct are held off a while; one that stayed `min_stay_ms` starts the count anew.
fn Mesh::lost_direct(self : Mesh, place : Place, stayed : Int64) -> Int64? {
  let ways = self.ways_at(place)
  if stayed >= min_stay_ms.to_int64() {
    ways.losses = 0
    return None
  }
  ways.losses += 1
  guard ways.losses >= flaky_losses else { return None }
  let mut hold = direct_hold_ms.to_int64()
  for _ in 0..<(ways.losses - flaky_losses) {
    hold = hold * 2L
    if hold >= direct_hold_max_ms.to_int64() {
      break
    }
  }
  if hold > direct_hold_max_ms.to_int64() {
    hold = direct_hold_max_ms.to_int64()
  }
  ways.held_until = Some(self.now_ms() + hold)
  Some(hold)
}

///|
/// No more requests go on `way`: closed `retire_ms` later, unless they went back to it meanwhile, so that replies
/// under way on it still come.
fn Mesh::retire(self : Mesh, place : Place, way : Way) -> Unit {
  let ways = self.ways_at(place)
  ways.all.retain(one => !physical_equal(one, way))
  let link = way.link
  self.retiring.push(link)
  ignore(
    self.scope.fork(name="mesh retire", () => {
      @effect.sleep(retire_ms, later=true)
      // (this waited: requests may have gone back to it)
      self.retiring.retain(one => !physical_equal(one, link))
      if !self.is_current(link) {
        self.count(place.peer, link)
        link.close()
      }
      self.release_pinned()
    }),
  )
}

///|
/// Lets go of the ways not worth keeping: one that missed `dead_pings`, one of two going the same way, and past
/// `keep_ways` the worst of those pinged `min_samples` times, those requests keep off first (never the one they go
/// on).
fn Mesh::prune(self : Mesh, place : Place) -> Unit {
  let cur = self.current(place.peer, scope=place.scope)
  let is_cur = (way : Way) => cur is Some(c) && physical_equal(c, way.link)
  for way in self.live_ways(place) {
    if !is_cur(way) && way.link.missed >= dead_pings {
      self.retire(place, way)
    }
  }
  let by_key : Map[String, Way] = Map([])
  for way in self.live_ways(place) {
    if !is_cur(way) && way.link.samples < min_samples {
      continue
    }
    let key = way.key()
    match by_key.get(key) {
      None => by_key[key] = way
      Some(other) => {
        let keep = if is_cur(other) {
          other
        } else if is_cur(way) {
          way
        } else if self.score_of(place, way).cost < self.score_of(place, other).cost {
          way
        } else {
          other
        }
        self.retire(place, if physical_equal(keep, way) { other } else { way })
        by_key[key] = keep
      }
    }
  }
  let others = self.live_ways(place).filter(way => !is_cur(way) && way.link.samples >= min_samples)
  others.sort_by((a, b) => {
    let avoid = (if self.avoided(place, a) { 1 } else { 0 }) - (if self.avoided(place, b) { 1 } else { 0 })
    if avoid != 0 {
      avoid
    } else {
      self.score_of(place, a).cost.compare(self.score_of(place, b).cost)
    }
  })
  for i in (keep_ways - 1)..<others.length() {
    self.retire(place, others[i])
  }
}

///|
/// Dials `place` on the ways not open to it (the endpoint's, each relay's own; `main_only`: the endpoint's alone),
/// each that comes through a way (`Mesh::adopt_way`).
async fn Mesh::explore(self : Mesh, place : Place, credentials : async (String, Bool) -> Presented, main_only : Bool) -> Unit {
  let ways = self.ways_at(place)
  guard !ways.exploring else { return }
  ways.exploring = true
  defer {
    ways.exploring = false
  }
  let now = self.now_ms()
  ways.main_dialled_at = Some(now)
  if !main_only {
    ways.explored_at = Some(now)
  }
  let have : Map[String, Unit] = Map([])
  for way in self.live_ways(place) {
    have[way.link.pin.unwrap_or("main")] = ()
  }
  let tries : Array[async () -> Link] = []
  let on_lan = self.since(ways.lan_at) < lan_recall_ms.to_int64()
  if !have.contains("main") && !on_lan && self.main_on(place) && !self.rebinding {
    tries.push(() => self.dial_main_way(place, credentials))
  }
  if !main_only {
    for relay in self.pinnable(place) {
      if !have.contains(relay) {
        tries.push(() => self.dial_pinned(place, relay, credentials, false))
      }
    }
  }
  self.each_adopted(place, tries)
}

///|
/// Each of `tries` run at once, each link it brings a way to `place`; waits for all.
async fn Mesh::each_adopted(self : Mesh, place : Place, tries : Array[async () -> Link]) -> Unit {
  guard tries.length() > 0 else { return }
  let left = Ref(tries.length())
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  for dial in tries {
    ignore(
      self.scope.fork(name="mesh way dial", () => {
        defer {
          left.val -= 1
          if left.val == 0 {
            ignore(done.succeed(()))
          }
        }
        // (taken in the step it comes: nothing runs between a link opened and its being a way, or closed)
        if attempt(dial) is Did(link) {
          self.adopt_way(place, link)
        }
      }),
    )
  }
  done.wait()
}

///|
/// The endpoint's way to `place` dialled beside the link there is: counted as on the endpoint while it is
/// (`Mesh::idle`), and never taking the endpoint for stuck.
async fn Mesh::dial_main_way(self : Mesh, place : Place, credentials : async (String, Bool) -> Presented) -> Link {
  self.dialling_main += 1
  defer {
    self.dialling_main -= 1
    self.eased()
  }
  match attempt(() => self.open(place, credentials, false)) {
    Did(link) => link
    Fell(OpeningTimeout(_)) => raise failed("no_answer")
    Fell(e) => raise e
  }
}

///|
/// The endpoint's dial raced beside other ways (`Mesh::dial_all`): counted as on the endpoint while it is, since it
/// may go on after another way won; and what it says of the endpoint said here, whichever won (taken for stuck where
/// it ran out of time unconnected, its addresses kept as unanswered; neither where it answered).
async fn Mesh::dial_main_raced(
  self : Mesh,
  place : Place,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  traceparent? : String,
) -> Link {
  self.dialling_main += 1
  defer {
    self.dialling_main -= 1
    self.eased()
  }
  match attempt(() => self.open(place, credentials, fresh, traceparent?)) {
    Did(link) => {
      self.stuck = false
      self.note_dial(place, false)
      link
    }
    Fell(OpeningTimeout(connected)) => {
      if !connected {
        self.stuck = true
      }
      self.note_dial(place, true)
      raise OpeningTimeout(connected)
    }
    Fell(e) => raise e
  }
}

///|
/// `f`, counted as a dial under way on an endpoint of a way's own: none is let go of meanwhile
/// (`Mesh::release_pinned`).
async fn[X] Mesh::counted(self : Mesh, f : async () -> X) -> Tried[X] {
  self.dialing += 1
  defer {
    self.dialing -= 1
  }
  attempt(f)
}

///|
/// A link to `place` on the endpoint of `way` alone (a relay, "lan", "tailnet"). One that fails lets go of the
/// endpoints no way is on; one that runs out of time fails for no answer (it says nothing of the endpoint).
async fn Mesh::dial_pinned(
  self : Mesh,
  place : Place,
  way : String,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  traceparent? : String,
) -> Link {
  let made = self.counted(() => {
    guard self.pinned_endpoint(way) is Some(endpoint) else { raise failed("unreached") }
    // (the bind was waited for: the place let go of or the mesh closed meanwhile, nothing is dialled)
    guard !self.closed && self.links.contains(place) else { raise failed("closed") }
    self.open(place, credentials, fresh, on=(way, endpoint), traceparent?)
  })
  match made {
    Did(link) => link
    Fell(e) => {
      self.release_pinned()
      match e {
        OpeningTimeout(_) => raise failed("no_answer")
        e => raise e
      }
    }
  }
}

///|
/// The endpoint of `way` alone: on that relay alone, held to it, nothing looked up, its key made over from the
/// device's (`pinned_key`); or, for "lan" and "tailnet", on no relay, dialling addresses alone, its key drawn for
/// it. Bound once, shared by whoever asks meanwhile; none where the bind failed (asked again, bound again), or the
/// mesh closed or let go of it while the shell bound.
async fn Mesh::pinned_endpoint(self : Mesh, way : String) -> Json? {
  if self.pinned.get(way) is Some(one) {
    return one.ready.wait()
  }
  let one : Pinned = { ready: @effect.Deferred::new(), endpoint: None }
  self.pinned[way] = one
  let at_address = way == lan || way == tailnet
  let key = if at_address { self.shell.random(32) } else { pinned_key(self.pinned_prefix, self.secret, way) }
  let relays = if at_address { [] } else { [way] }
  // (the shell binds whoever waits: not cut short, so that an endpoint bound is never left for nobody)
  let bound = @effect.uninterruptible(() => attempt(() => bind(self.shell, relays, !at_address, Binding::none(), [], key)))
  // (this waited: the mesh closed, or the endpoint let go of, meanwhile)
  let ours = !self.closed && self.pinned.get(way) is Some(now) && physical_equal(now, one)
  match bound {
    Did(endpoint) if ours => {
      one.endpoint = Some(endpoint)
      ignore(one.ready.succeed(Some(endpoint)))
      Some(endpoint)
    }
    Did(endpoint) => {
      self.shell.tell("iroh.close", { "id": endpoint, "forget": true })
      ignore(one.ready.succeed(None))
      None
    }
    Fell(_) => {
      if ours {
        self.pinned.remove(way)
      }
      ignore(one.ready.succeed(None))
      None
    }
  }
}

///|
/// Closes the endpoints of a way's own no way is on (a place's, one retiring, a place's link), unless one is being
/// dialled meanwhile; one still being bound is let be. All in the step it is called in.
fn Mesh::release_pinned(self : Mesh) -> Unit {
  guard self.dialing == 0 else { return }
  let used : Map[String, Unit] = Map([])
  let note = (link : Link) => if link.pin is Some(pin) && link.usable() { used[pin] = () }
  for _, ways in self.ways_of {
    for way in ways.all {
      note(way.link)
    }
  }
  for _, opening in self.links {
    if opening.result is Some(Open(link)) {
      note(link)
    }
  }
  for link in self.retiring {
    note(link)
  }
  for way in self.pinned.keys().to_array() {
    guard !used.contains(way) && self.pinned.get(way) is Some({ endpoint: Some(endpoint), .. }) else { continue }
    self.pinned.remove(way)
    self.shell.tell("iroh.close", { "id": endpoint, "forget": true })
  }
}

///|
/// A dial of `place` at the addresses it said of `kind`, on that kind's endpoint: none where it said none, `kind` is
/// off, one is under way or a way there is open. Counted as under way from now: its caller runs it at once.
fn Mesh::dial_at(
  self : Mesh,
  place : Place,
  kind : String,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  traceparent? : String,
) -> (async () -> Link)? {
  let at = self.said_at(place, kind)
  let ways = self.ways_at(place)
  if at.length() == 0 ||
    self.is_off(place, kind) ||
    ways.at_dialling.contains(kind) ||
    self.live_ways(place).iter().any(way => way.link.pin == Some(kind)) {
    return None
  }
  ways.tried[kind] = at.join(" ")
  ways.at_dialled_at[kind] = self.now_ms()
  ways.at_dialling[kind] = ()
  Some(() => {
    defer {
      ways.at_dialling.remove(kind)
    }
    self.dial_pinned(place, kind, credentials, fresh, traceparent?)
  })
}

///|
/// `place` dialled at its addresses of `kind` beside its ways, once for each set of addresses it says; again on the
/// LAN every `redial_main_ms` while a way direct reached it within `direct_recall_ms`, on its tailnet every
/// `explore_ms`.
fn Mesh::dial_at_if(self : Mesh, place : Place, kind : String, credentials : async (String, Bool) -> Presented) -> Unit {
  let at = self.said_at(place, kind)
  guard !self.closed && self.links.contains(place) && at.length() > 0 else { return }
  let ways = self.ways_at(place)
  if ways.tried.get(kind) == Some(at.join(" ")) {
    let last = ways.at_dialled_at.get(kind)
    let again = if kind == lan {
      self.since(ways.direct_at) < direct_recall_ms.to_int64() && self.since(last) >= redial_main_ms.to_int64()
    } else {
      ways.tailnet_answered && self.since(last) >= explore_ms.to_int64()
    }
    guard again else { return }
  }
  guard self.dial_at(place, kind, credentials, false) is Some(dial) else { return }
  ignore(self.scope.fork(name="mesh way dial", () => self.each_adopted(place, [dial])))
}

///|
/// Every way to `place` dialled at once: on the endpoint (through its relays, at the addresses the peer said, or a
/// path punched) and, where that alone will not do, on each relay's own endpoint and at the addresses said, each on
/// its own. The first let in is the link; the others, as they come through, ways beside it. Fails once all have,
/// with what the endpoint's dial failed with where there was one (an opening's time run out on it takes the endpoint
/// for stuck, as before: `Mesh::dialled`).
///
/// `traceparent`: what each dial's first line says it is under (a `mesh.connect`, `mesh.hedge` or `mesh.race`).
async fn Mesh::dial_all(
  self : Mesh,
  place : Place,
  credentials : async (String, Bool) -> Presented,
  fresh : Bool,
  traceparent? : String,
) -> Link {
  let ways = self.ways_at(place)
  let now = self.now_ms()
  ways.explored_at = Some(now)
  let attempts : Array[(Bool, async () -> Link)] = []
  if self.main_on(place) {
    ways.main_dialled_at = Some(now)
    let unanswered = self.unanswered_straight(place)
    let lost = ways.lost_main
    ways.lost_main = false
    if !unanswered && !lost {
      return self.open(place, credentials, fresh, traceparent?)
    }
    attempts.push((true, () => self.dial_main_raced(place, credentials, fresh, traceparent?)))
    for relay in (if unanswered { self.ways_for(place) } else { self.pinnable(place) }) {
      attempts.push((false, () => self.dial_pinned(place, relay, credentials, fresh, traceparent?)))
    }
  } else {
    for relay in self.pinnable(place) {
      attempts.push((false, () => self.dial_pinned(place, relay, credentials, fresh, traceparent?)))
    }
    for kind in [lan, tailnet] {
      if self.dial_at(place, kind, credentials, fresh, traceparent?) is Some(dial) {
        attempts.push((false, dial))
      }
    }
  }
  guard attempts.length() > 0 else { raise failed("all_off") }
  if attempts.length() == 1 {
    return (attempts[0].1)()
  }
  let won : @effect.Deferred[Link] = @effect.Deferred::new()
  let winner : Ref[Link?] = Ref(None)
  let taken = Ref(false)
  let left = Ref(attempts.length())
  let main_failure : Ref[Error?] = Ref(None)
  // What comes after this has given its answer, or after it was cut (its opening ended otherwise), is a way beside
  // whatever is at the place, or closed (`Mesh::adopt_way`): the one it was cut before giving as well.
  defer {
    if !taken.val {
      taken.val = true
      if winner.val is Some(link) {
        self.adopt_way(place, link)
      }
    }
  }
  for one in attempts {
    ignore(
      self.scope.fork(name="mesh way dial", () => {
        match attempt(one.1) {
          Did(link) =>
            if taken.val || winner.val is Some(_) {
              self.adopt_way(place, link)
            } else {
              winner.val = Some(link)
              ignore(won.succeed(link))
            }
          Fell(e) => {
            if one.0 {
              main_failure.val = Some(e)
            }
            left.val -= 1
            if left.val == 0 {
              ignore(won.fail(main_failure.val.unwrap_or(e)))
            }
          }
        }
      }),
    )
  }
  let link = won.wait()
  taken.val = true
  link
}

///|
/// Its program said which ways it turned off at `place`: each way open that goes one of them is closed, the link
/// requests go on too, whose place another way open takes at once, else a new one is dialled there.
fn Mesh::turn_off(self : Mesh, place : Place, off : Array[String]) -> Unit {
  let ways = self.ways_at(place)
  let off = off.map(relay_key)
  guard ways.off != off else { return }
  ways.off = off
  let cur = self.current(place.peer, scope=place.scope)
  for way in ways.all {
    if !(cur is Some(c) && physical_equal(c, way.link)) && self.way_off(place, way.link) {
      way.link.close(reason="way turned off")
    }
  }
  ignore(self.live_ways(place))
  if cur is Some(c) && c.usable() && self.way_off(place, c) {
    c.close(reason="way turned off")
    self.choose(place, None)
    if self.current(place.peer, scope=place.scope) is Some(now) && physical_equal(now, c) {
      ignore(self.dial(place, c.credentials, false, asker="again"))
    }
  }
  self.release_pinned()
  self.steer_if(place)
}

///|
/// Tells the mesh what its program says of the ways to `peer` in `scope`, without dialling (as `Mesh::link`'s):
/// `theirs`, the peer's own relays; `off`, the ways it turns off ("direct", "lan", "tailnet", a relay). Either not
/// said is left as it was.
pub fn Mesh::set_ways(self : Mesh, peer : String, scope? : String = "", theirs? : Array[String], off? : Array[String]) -> Unit {
  guard !self.closed else { return }
  let place : Place = { scope, peer }
  if theirs is Some(theirs) {
    self.ways_at(place).theirs = theirs.map(relay_key)
  }
  if off is Some(off) {
    self.turn_off(place, off)
  }
}

///|
/// Every way open to `peer` in `scope` as pinged, those pinged first by their round trips; then each relay it is
/// dialled through with no way open on it now (nothing counted). None where no way is open.
pub fn Mesh::measured(self : Mesh, peer : String, scope? : String = "") -> Array[MeasuredWay] {
  let place : Place = { scope, peer }
  let cur = self.current(peer, scope~)
  let live = self.live_ways(place)
  guard live.length() > 0 else { return [] }
  let sorted = live.copy()
  sorted.sort_by((a, b) => {
    let pinged = (if a.link.samples > 0 { 0 } else { 1 }) - (if b.link.samples > 0 { 0 } else { 1 })
    if pinged != 0 {
      pinged
    } else {
      a.link.srtt.compare(b.link.srtt)
    }
  })
  let out : Array[MeasuredWay] = []
  let seen : Map[String, Unit] = Map([])
  for way in sorted {
    let link = way.link
    let kind = match link.pin {
      None => "main"
      Some(pin) => if pin == lan || pin == tailnet { pin } else { "relay" }
    }
    let key = way.key()
    seen[key] = ()
    out.push({
      way: key,
      kind,
      active: cur is Some(c) && physical_equal(c, link),
      healthy: link.missed < dead_pings,
      samples: link.samples,
      srtt: link.srtt,
      dev: link.dev,
      missed: link.missed,
    })
  }
  for relay in self.ways_for(place) {
    if !seen.contains(relay_key(relay)) {
      out.push({
        way: relay_key(relay),
        kind: "relay",
        active: false,
        healthy: false,
        samples: 0,
        srtt: 0.0,
        dev: 0.0,
        missed: 0,
      })
    }
  }
  out
}

///|
/// How many times requests to `peer` in `scope` moved from one way to another.
pub fn Mesh::moves(self : Mesh, peer : String, scope? : String = "") -> Int {
  match self.ways_of.get({ scope, peer }) {
    Some(ways) => ways.moves
    None => 0
  }
}

///|
/// Where requests to `peer` in `scope` last moved to: a relay's host, or "direct"; none where they never moved.
pub fn Mesh::moved(self : Mesh, peer : String, scope? : String = "") -> String? {
  self.ways_of.get({ scope, peer }).bind(ways => ways.moved)
}

///|
/// Whether the ways not open to `peer` in `scope` are being dialled now (`Mesh::explore`).
pub fn Mesh::measuring(self : Mesh, peer : String, scope? : String = "") -> Bool {
  self.ways_of.get({ scope, peer }) is Some({ exploring: true, .. })
}

///|
/// The ways to `peer` in `scope` dialled and pinged now, as a person asks, and its requests moved to the best if it
/// is clearly better: the ways not open dialled, every way pinged `min_samples` times and once more. Fails where no
/// link is open there.
pub async fn Mesh::remeasure_peer(self : Mesh, peer : String, scope? : String = "") -> Unit {
  let place : Place = { scope, peer }
  guard !self.closed && self.current(peer, scope~) is Some(link) && link.usable() else {
    raise failed("not_connected")
  }
  self.explore(place, link.credentials, false)
  for _ in 0..=min_samples {
    // (each round was waited for: a place let go of is measured no more)
    guard !self.closed && self.links.contains(place) else { return }
    self.sample(place, true)
  }
  guard !self.closed && self.links.contains(place) else { return }
  self.choose(place, Some("asked"))
  self.prune(place)
}

///|
/// The ways to every place with a link open measured anew, as a person asks: what was counted of them forgotten,
/// ways direct no more held off, the ways not open dialled, every way pinged `min_samples` times and once more,
/// and requests moved to the best at once if it is clearly better. Runs on by itself.
pub fn Mesh::remeasure(self : Mesh) -> Unit {
  guard !self.closed else { return }
  for place, opening in self.links {
    guard opening.result is Some(Open(link)) && link.usable() else { continue }
    let ways = self.ways_at(place)
    ways.held_until = None
    ways.losses = 0
    for way in ways.all {
      way.better = 0
      way.link.samples = 0
      way.link.srtt = 0.0
      way.link.dev = 0.0
    }
    let credentials = link.credentials
    ignore(
      self.scope.fork(name="mesh remeasure", () => {
        self.explore(place, credentials, false)
        for _ in 0..=min_samples {
          // (each round was waited for: a place let go of is measured no more)
          guard !self.closed && self.links.contains(place) else { return }
          self.sample(place, true)
        }
        guard !self.closed && self.links.contains(place) else { return }
        self.choose(place, Some("asked"))
        self.prune(place)
      }),
    )
  }
}
