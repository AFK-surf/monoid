// What a program asks of the mesh beside its links: the way a slow read is asked on as well and when, a read's
// time counted as a ping (`standby`, `hedgeAfter`, `outran`); what it says signed with the device key (`sign`);
// whether a view's sound may be asked as Opus (`decodesOpus`); and the device key taken over (`migrate`): as the
// TypeScript mesh does them (client/core-ts/src/mesh.ts).

///|
/// The least a read waits for its answer on its way before it is asked on the next best way as well.
pub let hedge_floor_ms : Int = 1_000

///|
/// `link`'s way among its place's, with the place.
fn Mesh::way_of(self : Mesh, link : Link) -> (Place, Way)? {
  let place : Place = { scope: link.scope, peer: link.peer }
  let ways = self.live_ways(place)
  match ways.search_by(way => physical_equal(way.link, link)) {
    Some(i) => Some((place, ways[i]))
    None => None
  }
}

///|
/// The way a read slow on `link` is asked on as well: the best other way open to its place, going another way than
/// `link`'s, whose last ping was answered (one not pinged yet: its handshake was). None where there is none.
pub fn Mesh::standby(self : Mesh, link : Link) -> Link? {
  let place : Place = { scope: link.scope, peer: link.peer }
  let ways = self.live_ways(place)
  let key = match ways.search_by(way => physical_equal(way.link, link)) {
    Some(i) => Some(ways[i].key())
    None => None
  }
  let others = ways.filter(way => !physical_equal(way.link, link) && way.link.missed == 0 && Some(way.key()) != key)
  self.best_way(place, others).map(way => way.link)
}

///|
/// How long a read on `link` waits for its answer before it is asked on another way as well: what its way is
/// expected to take at worst (its score) and twice its deviation more; `hedge_floor_ms` at least.
pub fn Mesh::hedge_after(self : Mesh, link : Link) -> Int {
  guard self.way_of(link) is Some((place, way)) && way.link.samples > 0 else { return hedge_floor_ms }
  let score = self.score_of(place, way)
  let ms = (score.cost + 2.0 * score.dev).round().to_int()
  if ms > hedge_floor_ms {
    ms
  } else {
    hedge_floor_ms
  }
}

///|
/// A read asked on `slow` and on another way as well was answered on the other first, `ms` after it was asked on
/// `slow`: that long counts as a ping of `slow`.
pub fn Mesh::outran(self : Mesh, slow : Link, ms : Int) -> Unit {
  if self.way_of(slow) is Some((_, way)) {
    way.link.note(ms)
  }
}

///|
/// `message` signed with the device key (an Ed25519 seed), and that key's public half (32 bytes; the signature 64):
/// by the shell where it signs (`ed25519.sign`), else here (`ed25519_sign`).
pub fn Mesh::sign(self : Mesh, message : Bytes) -> (Bytes, Bytes) {
  let asked = self.shell.ask("ed25519.sign", {
    "seed": Json::string(hex_bytes(self.secret)),
    "message": Json::string(hex_bytes(message)),
  }) catch {
    _ => Json::null()
  }
  match asked {
    { "publicKey": String(public_key), "signature": String(signature), .. } => {
      let public_key = bytes_of_hex(public_key)
      let signature = bytes_of_hex(signature)
      if public_key.length() == 32 && signature.length() == 64 {
        return (public_key, signature)
      }
      ed25519_sign(self.secret, message)
    }
    _ => ed25519_sign(self.secret, message)
  }
}

///|
/// `text`'s bytes, two hex digits each; what is not hex, none.
fn bytes_of_hex(text : String) -> Bytes {
  let out : Array[Byte] = []
  let digit = (c : Char) => if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    -1
  }
  let chars = text.to_array()
  guard chars.length() % 2 == 0 else { return b"" }
  for i = 0; i < chars.length(); i = i + 2 {
    let hi = digit(chars[i])
    let lo = digit(chars[i + 1])
    guard hi >= 0 && lo >= 0 else { return b"" }
    out.push((hi * 16 + lo).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Whether a view's sound may be asked as Opus: what the shell says the endpoint decodes (`iroh.opus`).
pub fn Mesh::decodes_opus(self : Mesh) -> Bool {
  (self.shell.ask("iroh.opus", { "id": self.endpoint }) catch { _ => Json::boolean(false) }) is True
}

///|
/// Takes over a device key a program kept before (32 bytes): kept, the endpoint bound anew with it (told where
/// its program said peers are), and everything on the one before let go of: every link and opening, each way and
/// its endpoint, a connection a peer dialled, their peers told "device key replaced"; then the endpoint before
/// closed. The same key again changes nothing. Waits for a bind under way to end first.
pub async fn Mesh::migrate(self : Mesh, secret : Bytes) -> Unit {
  guard secret.length() == 32 else {
    raise MeshError(code="invalid_params", message=say("bad_device_key"), cause="")
  }
  guard !self.closed else { raise failed("closed") }
  while self.rebinding {
    self.hold(None)
  }
  if secret == self.secret {
    return
  }
  let endpoint = bind(self.shell, self.relays, self.options.relay_only, self.binding, self.entries, secret)
  // (this waited: closed meanwhile, or taken over by another, the endpoint that came is nobody's)
  guard !self.closed && !self.rebinding else {
    self.shell.tell("iroh.close", { "id": endpoint })
    raise failed("closed")
  }
  (self.store.set)(device_key, secret) catch {
    e => {
      self.shell.tell("iroh.close", { "id": endpoint })
      raise MeshError(code="host", message=text_of(e), cause="")
    }
  }
  guard !self.closed && !self.rebinding else {
    self.shell.tell("iroh.close", { "id": endpoint })
    raise failed("closed")
  }
  let id = match (self.shell.ask("iroh.endpointId", { "id": endpoint }) catch { _ => Json::null() }) {
    String(id) => id
    _ => self.id
  }
  self.replay(endpoint)
  let reason = "device key replaced"
  // (what the links carried counted first; every place let go of, as `drop_link` lets go of one)
  self.count_open()
  for place in self.links.keys().to_array() {
    self.let_go(place, reason)
  }
  for link in self.live.copy() {
    link.close(reason~)
  }
  for link in self.retiring {
    link.close(reason~)
  }
  self.retiring.clear()
  for incoming in self.incomings.copy() {
    incoming.close(reason~)
  }
  self.forget_coming()
  for way in self.pinned.keys().to_array() {
    if self.pinned.get(way) is Some({ endpoint: Some(pinned), .. }) {
      self.shell.tell("iroh.close", { "id": pinned })
    }
  }
  self.pinned.clear()
  let old = self.endpoint
  self.secret = secret
  self.endpoint = endpoint
  self.id = id
  self.stuck = false
  self.changed()
  self.eased()
  self.shell.tell("iroh.close", { "id": old })
}
