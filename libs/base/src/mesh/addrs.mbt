// Where a peer said a device dials it straight, and where its program says a peer is: as the TypeScript mesh keeps
// them (client/core-ts/src/mesh.ts: `#said`, `#heard`, `addAddr` and `#known`, `#straightAt`, `#unansweredAt`). A
// peer's answer to a link's first line may say its addresses on its LAN and on its tailnet (`lan`, `tailnet`: IPv4
// `a.b.c.d:port` each, 8 of each at most); they are kept by place (under `Mesh::make`'s `addresses`), told to the
// endpoint, and given to every dial of that place on it, which then does not wait to be on a relay first. Where a
// dial given them went unanswered, that is kept (`unanswered_at`): the ways' to go by (another way dialled beside).

///|
/// The key what peers said of where they are dialled straight is kept under, unless its program names another.
pub let addresses_key : String = "peer-addresses"

///|
/// How many addresses of each kind a peer's answer is taken for at most.
let most_addrs : Int = 8

///|
/// What a peer said of where it is dialled straight: on its LAN, on its tailnet.
priv struct Said {
  lan : Array[String]
  tailnet : Array[String]
}

///|
/// Where a program said a peer is (`Mesh::add_addr`): told to the endpoint, and to each bound after it.
priv struct Known {
  peer : String
  relays : Array[String]
  ips : Array[String]
}

///|
/// `a.b.c.d:port`, as the TypeScript mesh takes one: 1 to 3 digits four times, then 1 to 5.
fn is_ip_port(text : String) -> Bool {
  let mut part = 0
  let mut digits = 0
  for c in text {
    if c >= '0' && c <= '9' {
      digits += 1
      if digits > (if part == 4 { 5 } else { 3 }) {
        return false
      }
    } else if (c == '.' && part < 3) || (c == ':' && part == 3) {
      guard digits > 0 else { return false }
      part += 1
      digits = 0
    } else {
      return false
    }
  }
  part == 4 && digits > 0
}

///|
/// The addresses `json` says under `key` (an array of strings), those that are `a.b.c.d:port`, 8 at most; none where
/// it says no array there.
fn addrs_of(json : Json, key : String) -> Array[String] {
  guard json is Object(fields) && fields.get(key) is Some(Array(items)) else { return [] }
  let out = []
  for item in items {
    if item is String(text) && is_ip_port(text) {
      out.push(text)
      if out.length() == most_addrs {
        break
      }
    }
  }
  out
}

///|
/// What a place is kept under: its peer, after its scope and a `/` where it has one.
fn Place::key(self : Place) -> String {
  if self.scope == "" {
    self.peer
  } else {
    "\{self.scope}/\{self.peer}"
  }
}

///|
/// What was kept, read: `{"<place>": {"lan": [...], "tailnet": [...]}}`. What is not that is taken for nothing, and
/// an address that is not `a.b.c.d:port` is dropped.
fn said_of(kept : Bytes?) -> Map[String, Said] {
  let out : Map[String, Said] = Map([])
  guard kept is Some(bytes) else { return out }
  let text = @utf8.decode(bytes) catch { _ => return out }
  let json : Json = @json.parse(text) catch { _ => return out }
  guard json is Object(places) else { return out }
  for key, value in places {
    let said : Said = { lan: addrs_of(value, "lan"), tailnet: addrs_of(value, "tailnet") }
    if said.lan.length() > 0 || said.tailnet.length() > 0 {
      out[key] = said
    }
  }
  out
}

///|
fn strings(items : Array[String]) -> Json {
  Json::array(items.map(item => Json::string(item)))
}

///|
/// What is kept of `said`, written.
fn said_bytes(said : Map[String, Said]) -> Bytes {
  let out : Map[String, Json] = Map([])
  for key, one in said {
    out[key] = { "lan": strings(one.lan), "tailnet": strings(one.tailnet) }
  }
  @utf8.encode(Json::object(out).stringify())
}

///|
/// Where the peer at `place` last said a device dials it straight: its LAN's, then its tailnet's.
fn Mesh::straight(self : Mesh, place : Place) -> Array[String] {
  match self.said.get(place.key()) {
    Some(said) => [..said.lan, ..said.tailnet]
    None => []
  }
}

///|
/// What a dial of `place` on the endpoint is given beside its relays: where it is dialled straight, none on an
/// endpoint that goes through its relays alone.
fn Mesh::ips(self : Mesh, place : Place) -> Array[String] {
  if self.options.relay_only {
    []
  } else {
    self.straight(place)
  }
}

///|
/// Where `peer` in `scope` said it is on its LAN: what its link there said, open; else what was last kept of it.
pub fn Mesh::lan(self : Mesh, peer : String, scope? : String = "") -> Array[String] {
  match self.current(peer, scope~) {
    Some(link) if link.ended() is None && link.answer is Some(_) => link.lan.copy()
    _ =>
      match self.said.get({ scope, peer }.key()) {
        Some(said) => said.lan.copy()
        None => []
      }
  }
}

///|
/// Where `peer` in `scope` said it is on its tailnet, as `Mesh::lan`.
pub fn Mesh::tailnet(self : Mesh, peer : String, scope? : String = "") -> Array[String] {
  match self.current(peer, scope~) {
    Some(link) if link.ended() is None && link.answer is Some(_) => link.tailnet.copy()
    _ =>
      match self.said.get({ scope, peer }.key()) {
        Some(said) => said.tailnet.copy()
        None => []
      }
  }
}

///|
/// The peer's answer to a link's first line said where it is dialled straight (none said: nowhere): kept where it
/// changed, written to the store (one writing at a time, each of what is kept as it gets its turn), and told to
/// the endpoint. Only of a link at its place: one that lost its opening says nothing for it.
fn Mesh::heard(self : Mesh, place : Place, link : Link) -> Unit {
  guard !self.closed && self.is_current(link) else { return }
  let key = place.key()
  let was = self.said.get(key)
  let same = match was {
    Some(said) => said.lan == link.lan && said.tailnet == link.tailnet
    None => link.lan.length() == 0 && link.tailnet.length() == 0
  }
  if !same {
    if link.lan.length() > 0 || link.tailnet.length() > 0 {
      self.said[key] = { lan: link.lan.copy(), tailnet: link.tailnet.copy() }
    } else {
      self.said.remove(key)
    }
    ignore(
      self.scope.fork(name="mesh said kept", () => self.keeping.with_permit(() => {
        let bytes = said_bytes(self.said)
        ignore(attempt(() => (self.store.set)(self.addresses, bytes)))
      })),
    )
  }
  // (on the endpoint the addresses are iroh's to try on the connection open, paths of it)
  let ips = self.ips(place)
  if ips.length() > 0 && !self.rebinding {
    self.tell_addr(self.endpoint, place.peer, self.relays, ips)
  }
}

///|
/// The endpoint `endpoint` is told where `peer` is: asked at once (`iroh.addAddr`, an op both shells answer at once);
/// a shell that cannot is let be.
fn Mesh::tell_addr(self : Mesh, endpoint : Json, peer : String, relays : Array[String], ips : Array[String]) -> Unit {
  let addr : Map[String, Json] = { "id": Json::string(peer), "relays": strings(relays) }
  if ips.length() > 0 {
    addr["ips"] = strings(ips)
  }
  ignore(self.shell.ask("iroh.addAddr", { "id": endpoint, "addr": Json::object(addr) })) catch {
    _ => ()
  }
}

///|
/// Tells the endpoint, and each bound after it, where `peer` is (its relays, its addresses `a.b.c.d:port`): for a
/// peer no relay or lookup finds (a test, a LAN). Told again of a peer, what was told before of it is replaced. On
/// an endpoint that goes through its relays alone, the addresses are not told.
pub fn Mesh::add_addr(self : Mesh, peer : String, relays? : Array[String] = [], ips? : Array[String] = []) -> Unit {
  guard !self.closed else { return }
  let known : Known = { peer, relays: relays.copy(), ips: ips.copy() }
  match self.known.search_by(one => one.peer == peer) {
    Some(i) => self.known[i] = known
    None => self.known.push(known)
  }
  // (being bound anew, the endpoint that comes is told: `Mesh::replay`)
  if !self.rebinding {
    self.tell_known(self.endpoint, known)
  }
}

///|
fn Mesh::tell_known(self : Mesh, endpoint : Json, known : Known) -> Unit {
  self.tell_addr(endpoint, known.peer, known.relays, if self.options.relay_only { [] } else { known.ips })
}

///|
/// An endpoint just bound is told everything its program said of where peers are.
fn Mesh::replay(self : Mesh, endpoint : Json) -> Unit {
  for known in self.known {
    self.tell_known(endpoint, known)
  }
}

///|
/// A dial of `place` on the endpoint ended: with a link (`answered` none), or for no answer in time. One given
/// addresses that went unanswered is kept, by those addresses; a link made there lets go of it.
fn Mesh::note_dial(self : Mesh, place : Place, unanswered : Bool) -> Unit {
  if !unanswered {
    self.unanswered_at.remove(place)
    return
  }
  let ips = self.ips(place)
  if ips.length() > 0 {
    self.unanswered_at[place] = ips.join(" ")
  }
}

///|
/// Where the peer said it is on its LAN, in its answer to the link's first line (`a.b.c.d:port`, 8 at most): none
/// until it answered, and where it said none.
pub fn Link::lan(self : Link) -> Array[String] {
  self.lan.copy()
}

///|
/// Where the peer said it is on its tailnet, as `Link::lan`.
pub fn Link::tailnet(self : Link) -> Array[String] {
  self.tailnet.copy()
}
