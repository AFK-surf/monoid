// The relays each other station is not to be reached through, held by the endpoint itself (station/src/mesh/
// peer-relays.ts; iroh's `Endpoint::set_disabled_relays`): one set a station, whoever calls it and whichever workspace a
// request is asked in: those every workspace both stations are in turns off (`station_addr` with no workspace), and
// iroh's public relays too where each of those turned still.fail's off for relays of its own (`public`). Held before
// the station is dialed, in force once that resolves, and held anew as the ways or the rosters change; a station of no
// workspace of this one's any more is let go (its set emptied). Where the endpoint holds none (an endpoint from before:
// no such operation), `supported` turns false and its callers close a connection whose chosen path goes through a
// relay turned off instead (`goes_through`). A front's endpoint started again is given every set anew (`restore`)
// before anything is routed or dialed through it.

///|
/// What one station is held to: the relays it is not reached through, and whether iroh's public relays are among them.
pub(all) struct PeerDisabled {
  relays : Array[String]
  public : Bool
}

///|
pub fn PeerDisabled::to_json(self : PeerDisabled) -> Json {
  { "relays": Json::array(self.relays.map(Json::string)), "public": Json::boolean(self.public) }
}

///|
/// What `peer` is held to now; None where it is a station of no workspace of this one's.
pub fn peer_disabled(ways : Ways, peer : String) -> PeerDisabled? {
  let shared = shared_with(ways.cloud, peer)
  if shared.length() == 0 {
    return None
  }
  let relays = station_addr(ways, peer).disabled_relays
  let no_public = shared
    .iter()
    .all(ws => ways.view(ws).off.contains("ours") && off_relays(ways, ws).length() > 0)
  Some({ relays, public: no_public })
}

///|
/// What a set is compared by: its relays' normal forms sorted, and whether public ones are among them ("" for none).
pub fn disabled_key(d : PeerDisabled?) -> String {
  match d {
    None => ""
    Some(d) => {
      let urls = d.relays.map(same_url)
      // (sorted as JavaScript's default sort does, by UTF-16 units)
      urls.sort_by((a, b) => utf16_compare(a, b))
      Json::array([
        Json::array(urls.map(Json::string)),
        Json::boolean(d.public),
      ]).stringify()
    }
  }
}

///|
fn utf16_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.code_unit_at(i).to_int()
    let y = b.code_unit_at(i).to_int()
    if x != y {
      return x - y
    }
  }
  a.length() - b.length()
}

///|
/// The endpoint's holding of a peer's set (the addon's or the front's `disabledRelays`).
pub(all) struct Holding {
  disabled_relays : async (String, Array[String], Bool) -> Unit
}

///|
/// An endpoint from before, which offers no such operation.
pub fn unsupported(words : String) -> Bool {
  words.contains("no operation") || words.contains("not a function")
}

///|
pub struct PeerRelays {
  priv endpoint : Holding
  priv ways : Ways
  /// Each station held: the key of what the endpoint was told last.
  priv held : Map[String, String]
  /// Each station's changes, one after another (a dial's and the ways' alike).
  priv going : Map[String, @effect.Semaphore]
  /// How many changes of each station's wait or run (its entry in `going` let go at none).
  priv queued : Map[String, Int]
  priv stops : Array[() -> Unit]
  /// Whether the endpoint holds them (false once it answered it has no such operation).
  mut supported : Bool
}

///|
/// Follows the ways and the rosters on `rt` (each change holds every station anew); `log` hears what failed.
pub fn PeerRelays::new(
  endpoint : Holding,
  ways : Ways,
  rt : @effect.Runtime,
  log? : (String) -> Unit = _ => (),
) -> PeerRelays {
  let p = {
    endpoint,
    ways,
    held: Map([]),
    going: Map([]),
    queued: Map([]),
    stops: [],
    supported: true,
  }
  let again = () => ignore(
    rt.fork_daemon("disabled relays", on_error=e => log("disabled relays could not be updated: \{error_words(e)}"), async fn() {
      p.again() catch {
        e => log("disabled relays could not be updated: \{error_words(e)}")
      }
    }),
  )
  p.stops.push(ways.listen(_ => again()))
  p.stops.push((ways.cloud.listen)(again))
  p
}

///|
/// `peer` held to what it is to be held to now, in force once this returns (before it is dialed).
pub async fn PeerRelays::hold(self : PeerRelays, peer : String) -> Unit {
  self.then(peer, () => self.give(peer))
}

///|
/// Every station held, held anew as the ways and rosters are now; one of no workspace of this one's let go. Returns once
/// each is in force.
pub async fn PeerRelays::again(self : PeerRelays) -> Unit {
  let peers : Array[String] = []
  for k, _ in self.held {
    peers.push(k)
  }
  for k, _ in self.going {
    if !peers.contains(k) {
      peers.push(k)
    }
  }
  ignore(@effect.all(peers.map(peer => async fn() { self.hold(peer) })))
}

///|
/// A front's endpoint started anew holds nothing: every station held is told its set again, in force once this returns.
pub async fn PeerRelays::restore(self : PeerRelays) -> Unit {
  let peers : Array[String] = []
  for k, _ in self.held {
    peers.push(k)
  }
  self.held.clear()
  ignore(@effect.all(peers.map(peer => async fn() { self.hold(peer) })))
}

///|
async fn PeerRelays::give(self : PeerRelays, peer : String) -> Unit {
  while true {
    if !self.supported {
      return
    }
    let now = peer_disabled(self.ways, peer)
    let key = disabled_key(now)
    let was = self.held.get(peer)
    if was == Some(key) || (now is None && was is None) {
      return
    }
    let (relays, public) = match now {
      Some(d) => (d.relays, d.public)
      None => ([], false)
    }
    (self.endpoint.disabled_relays)(peer, relays, public) catch {
      e =>
        if unsupported(error_words(e)) {
          self.supported = false
          return
        } else {
          raise e
        }
    }
    if now is None {
      self.held.remove(peer)
    } else {
      self.held[peer] = key
    }
    // A roster or ways event may have come while the endpoint applied the previous set.
    if disabled_key(peer_disabled(self.ways, peer)) == key {
      return
    }
  }
}

///|
async fn PeerRelays::then(self : PeerRelays, peer : String, f : async () -> Unit) -> Unit {
  let lock = match self.going.get(peer) {
    Some(l) => l
    None => {
      let l = @effect.Semaphore::new(1)
      self.going[peer] = l
      l
    }
  }
  self.queued[peer] = self.queued.get(peer).unwrap_or(0) + 1
  defer {
    let left = self.queued.get(peer).unwrap_or(1) - 1
    if left <= 0 {
      self.queued.remove(peer)
      self.going.remove(peer)
    } else {
      self.queued[peer] = left
    }
  }
  lock.with_permit(f)
}

///|
/// What `peer` is held to (its key; tests).
pub fn PeerRelays::held_of(self : PeerRelays, peer : String) -> String? {
  self.held.get(peer)
}

///|
pub fn PeerRelays::close(self : PeerRelays) -> Unit {
  for stop in self.stops {
    stop()
  }
  self.stops.clear()
}
