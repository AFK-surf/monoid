// The signed records of the workspaces' mesh scopes, checked as station/src/mesh's are (announcements.ts
// `descriptorOf`, `announcementOf`; relay-records.ts `relayRecordOf`, `signRelayRecord`): an address announcement
// a station signs of its own scoped binding, which other stations may pass on but not replace with an older one, and a
// relay's registration its issuing station signs. A signature only proves who made a record: what a scope admits is
// the roster the caller gives (`allowed`, `issuers`), never the record.

///|
/// What the shell's Ed25519 and digests are to this package (station_main gives the shell's: `crypto.verify`,
/// `ed25519.sign` with the station's seed, `crypto.sha256`, `crypto.random`).
pub(all) struct Crypto {
  /// Whether `signature` (hex) is `key`'s (hex) of `message`.
  verify : (String, Bytes, String) -> Bool
  /// This station's signature (hex) of a text's UTF-8.
  sign : (String) -> String raise
  /// SHA-256 of bytes, hex.
  sha256 : (Bytes) -> String
  /// `n` random bytes.
  random : (Int) -> Bytes
}

///|
pub let announcement_domain : String = "mesh-announcement/v1\u{0}"

///|
pub let relay_record_domain : String = "mesh-relay-registration/v1\u{0}"

///|
let binding_domain : String = "mesh-neighbor-binding/v2\u{0}"

///|
/// A record's body at most (announcements.ts `LIMIT`).
let limit : Int = 16 * 1024

///|
pub fn hex64(s : String) -> Bool {
  s.length() == 64 &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn hex128(s : String) -> Bool {
  s.length() == 128 &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

///|
pub fn hex_of(b : BytesView) -> String {
  @codec.hex_encode(b)
}

///|
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
fn byte_length(s : String) -> Int {
  utf8(s).length()
}

///|
pub fn field(o : Json, k : String) -> Json {
  match o {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
pub fn text(o : Json) -> String? {
  match o {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A number that is a safe integer (`Number.isSafeInteger`).
pub fn safe_int(j : Json) -> Int64? {
  match j {
    Number(n, ..) if @jsjson.is_safe_integer(n) => Some(n.to_int64())
    _ => None
  }
}

///|
pub fn int_json(n : Int64) -> Json {
  Json::number(n.to_double())
}

///|
/// `raw` as `length` bytes (an array of 0..255), else None.
fn bytes_of(raw : Json, length : Int) -> Bytes? {
  guard raw is Array(xs) && xs.length() == length else { return None }
  let out : Array[Byte] = Array::make(length, b'\x00')
  for i, x in xs {
    guard safe_int(x) is Some(n) && n >= 0L && n <= 255L else { return None }
    out[i] = n.to_byte()
  }
  Some(Bytes::from_array(out))
}

///|
fn concat(parts : Array[Bytes]) -> Bytes {
  let b = @buffer.Buffer()
  for p in parts {
    b.write_bytes(p)
  }
  b.to_bytes()
}

///|
fn u64_be(n : Int64) -> Bytes {
  let out : Array[Byte] = Array::make(8, b'\x00')
  for i in 0..<8 {
    out[7 - i] = ((n >> (8 * i)) & 0xffL).to_byte()
  }
  Bytes::from_array(out)
}

///|
fn parse(s : String) -> Json raise {
  @json.parse(s) catch {
    _ => fail("invalid mesh record body")
  }
}

///|
/// A scoped binding as announced: its signature by `node` checked, its address within bounds (`descriptorOf`).
pub fn descriptor_of(c : Crypto, raw : Json, scope : String, node : String, minimum_generation? : Int64 = 0L) -> Json raise {
  let b = field(raw, "binding")
  let bad = () => fail("invalid scoped mesh binding")
  guard hex64(scope) && hex64(node) else { bad() }
  guard bytes_of(field(b, "scope"), 32) is Some(b_scope) &&
    bytes_of(field(b, "policy"), 32) is Some(b_policy) &&
    bytes_of(field(b, "endpoint"), 32) is Some(b_endpoint) &&
    bytes_of(field(b, "neighbor"), 32) is Some(b_neighbor) &&
    bytes_of(field(b, "signature"), 64) is Some(b_signature) else {
    bad()
  }
  guard safe_int(field(b, "generation")) is Some(generation) &&
    generation >= minimum_generation &&
    generation >= 1L else {
    bad()
  }
  guard field(b, "transit") is (True | False) else { bad() }
  let transit = field(b, "transit") is True
  guard hex_of(b_scope) == scope && hex_of(b_endpoint) == node && b_neighbor != b_endpoint else {
    bad()
  }
  let message = concat([
    utf8(binding_domain),
    b_scope,
    b_policy,
    b_endpoint,
    b_neighbor,
    u64_be(generation),
    if transit {
      b"\x01"
    } else {
      b"\x00"
    },
  ])
  guard (c.verify)(node, message, hex_of(b_signature)) else {
    fail("invalid mesh binding signature")
  }
  let address = field(raw, "address")
  guard text(field(address, "id")) == Some(hex_of(b_neighbor)) &&
    field(address, "addrs") is Array(addrs) &&
    addrs.length() <= 8 &&
    byte_length(raw.stringify()) <= limit else {
    fail("invalid mesh neighbor address")
  }
  for addr in addrs {
    let one = match addr {
      Object(m) if m.length() == 1 =>
        match (m.get("Ip"), m.get("Relay")) {
          (Some(String(ip)), _) => ip.length() <= 128
          (_, Some(String(relay))) => relay.length() <= 2048
          _ => false
        }
      _ => false
    }
    guard one else { fail("invalid mesh underlay address") }
  }
  raw
}

///|
/// An address announcement of a scope: its body's node one `allowed`, its signature that node's (`announcementOf`).
pub(all) struct Announced {
  scope : String
  node : String
  revision : Int64
  descriptor : Json
}

///|
pub fn announcement_of(c : Crypto, raw : Json, scope : String, allowed : Set[String], minimum_generation? : Int64 = 0L) -> Announced raise {
  guard allowed.length() <= 256 else { fail("too many mesh identities") }
  guard text(field(raw, "body")) is Some(body) &&
    byte_length(body) <= limit &&
    text(field(raw, "signature")) is Some(signature) &&
    hex128(signature) else {
    fail("invalid mesh announcement")
  }
  let value = parse(body)
  guard text(field(value, "scope")) == Some(scope) &&
    text(field(value, "node")) is Some(node) &&
    hex64(node) &&
    allowed.contains(node) &&
    safe_int(field(value, "revision")) is Some(revision) &&
    revision >= 1L else {
    fail("mesh announcement is outside the admitted directory")
  }
  guard (c.verify)(node, utf8(announcement_domain + body), signature.to_lower()) else {
    fail("invalid mesh announcement signature")
  }
  {
    scope,
    node,
    revision,
    descriptor: descriptor_of(c, field(value, "descriptor"), scope, node, minimum_generation~),
  }
}

///|
/// A relay's registration, signed by its issuing station: `issuers` the stations of the scope that may grant one
/// (`relayRecordOf`). The record's body, parsed.
pub fn relay_record_of(c : Crypto, signed : Json, scope : String, issuers : Set[String]) -> Json raise {
  guard issuers.length() <= 256 &&
    text(field(signed, "body")) is Some(body) &&
    byte_length(body) <= 16 * 1024 &&
    text(field(signed, "signature")) is Some(signature) &&
    hex128(signature) else {
    fail("invalid relay record")
  }
  let record = parse(body)
  let name_ok = match field(record, "name") {
    String(n) => n.length() >= 1 && n.length() <= 80
    _ => false
  }
  let made_ok = match field(record, "made_by") {
    String(m) => m.length() <= 200
    _ => false
  }
  guard text(field(record, "scope")) == Some(scope) &&
    hex64(scope) &&
    text(field(record, "node")) is Some(node) &&
    hex64(node) &&
    text(field(record, "issuer")) is Some(issuer) &&
    hex64(issuer) &&
    issuers.contains(issuer) &&
    safe_int(field(record, "generation")) is Some(generation) &&
    generation >= 1L &&
    safe_int(field(record, "revoked")) is Some(revoked) &&
    (revoked == 0L || revoked == 1L) &&
    name_ok &&
    made_ok else {
    fail("relay record is outside the admitted workspace")
  }
  guard (c.verify)(issuer, utf8(relay_record_domain + body), signature.to_lower()) else {
    fail("invalid relay issuer signature")
  }
  ignore(node)
  record
}

///|
/// A registration as the stations keep it (enrollment.ts `RelayRegistration`).
#derive(Eq)
pub(all) struct Registration {
  scope : String
  node : String
  issuer : String
  generation : Int64
  name : String
  made_by : String
  revoked : Int64
}

///|
/// Its body in signRelayRecord's order of fields, which every station verifies as it was written.
pub fn Registration::to_json(self : Registration) -> Json {
  {
    "scope": Json::string(self.scope),
    "node": Json::string(self.node),
    "issuer": Json::string(self.issuer),
    "generation": int_json(self.generation),
    "name": Json::string(self.name),
    "made_by": Json::string(self.made_by),
    "revoked": int_json(self.revoked),
  }
}

///|
/// The registration signed by its issuer (`signRelayRecord`): {body, signature}.
pub fn sign_relay_record(c : Crypto, record : Registration) -> Json raise {
  let body = record.to_json().stringify()
  { "body": Json::string(body), "signature": Json::string((c.sign)(relay_record_domain + body)) }
}
