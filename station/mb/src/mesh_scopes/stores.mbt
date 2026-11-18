// What a station keeps of its workspaces' mesh scopes in its store (store/mesh-schema.ts's tables, made with the
// schema): the relay enrollment tokens it issued and the registrations they became (enrollment.ts `RelayEnrollment`,
// its issuing station's alone: tokens are never copied), the registrations of every issuer as their stations signed
// them (relay-records.ts `RelayRecords`), and the address announcements of the scopes' stations (announcements.ts
// `Announcements`). Each write that decides on a bound is one `BEGIN IMMEDIATE` transaction with its check.

///|
fn[T] write(db : @sql.Db, f : () -> T raise) -> T raise {
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let result = f()
  db.exec("COMMIT")
  result
}

///|
fn first(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  db.all(sql, params).get(0)
}

///|
fn num(row : Map[String, Json], k : String) -> Int64 {
  safe_int(row.get(k).unwrap_or(Json::null())).unwrap_or(0L)
}

///|
fn str(row : Map[String, Json], k : String) -> String {
  match row.get(k) {
    Some(String(s)) => s
    Some(Number(n, ..)) => n.to_int64().to_string()
    _ => ""
  }
}

///|
let token_ttl_ms : Double = 24.0 * 60.0 * 60.0 * 1000.0

///|
let token_most : Int = 32

///|
let active_most : Int = 32

///|
let record_most : Int = 256

///|
/// `bytes` as base64url with no padding (Buffer's `base64url`).
pub fn base64url(bytes : Bytes) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  let out = StringBuilder()
  let n = bytes.length()
  let mut i = 0
  while i + 2 < n {
    let v = (bytes[i].to_int() << 16) | (bytes[i + 1].to_int() << 8) | bytes[i + 2].to_int()
    for s in [18, 12, 6, 0] {
      out.write_char(alphabet.get_char((v >> s) & 63).unwrap())
    }
    i += 3
  }
  if n - i == 1 {
    let v = bytes[i].to_int() << 16
    for s in [18, 12] {
      out.write_char(alphabet.get_char((v >> s) & 63).unwrap())
    }
  } else if n - i == 2 {
    let v = (bytes[i].to_int() << 16) | (bytes[i + 1].to_int() << 8)
    for s in [18, 12, 6] {
      out.write_char(alphabet.get_char((v >> s) & 63).unwrap())
    }
  }
  out.to_string()
}

///|
fn token_hash(c : Crypto, token : String) -> String raise {
  guard token.length() == 43 &&
    token.iter().all(ch => (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-') else {
    fail("invalid relay enrollment token")
  }
  (c.sha256)(utf8(token))
}

///|
fn key(value : String) -> String raise {
  guard hex64(value) else { fail("invalid mesh identity or scope") }
  value
}

///|
/// A workspace's relay enrollment at its issuing station (enrollment.ts `RelayEnrollment`).
pub struct Enrollment {
  db : @sql.Db
  issuer : String
  now : () -> Double
  crypto : Crypto
}

///|
pub fn Enrollment::new(db : @sql.Db, issuer : String, now : () -> Double, crypto : Crypto) -> Enrollment raise {
  { db, issuer: key(issuer), now, crypto }
}

///|
/// A one-use token for a relay named `name`, valid a day: {token, expires, issuer, scope}.
pub fn Enrollment::issue(self : Enrollment, scope : String, name : String, by : String) -> Json raise {
  ignore(key(scope))
  let name = name.trim(chars=" \t\n\r").to_owned()
  guard name != "" && name.length() <= 80 && by != "" && by.length() <= 200 else {
    fail("invalid relay enrollment name or issuer attribution")
  }
  let now = (self.now)()
  let token = base64url((self.crypto.random)(32))
  let digest = token_hash(self.crypto, token)
  write(self.db, () => {
    ignore(self.db.run("DELETE FROM mesh_relay_tokens WHERE scope = ?1 AND expires <= ?2", [Json::string(scope), Json::number(now)]))
    let count = match first(self.db, "SELECT COUNT(*) AS n FROM mesh_relay_tokens WHERE scope = ?1", [Json::string(scope)]) {
      Some(row) => num(row, "n")
      None => 0L
    }
    guard count < token_most.to_int64() else { fail("too many pending relay enrollment tokens") }
    let expires = now + token_ttl_ms
    ignore(self.db.run("INSERT INTO mesh_relay_tokens(hash, scope, name, made_by, expires) VALUES (?1, ?2, ?3, ?4, ?5)", [
      Json::string(digest),
      Json::string(scope),
      Json::string(name),
      Json::string(by),
      Json::number(expires),
    ]))
    {
      "token": Json::string(token),
      "expires": Json::number(expires),
      "issuer": Json::string(self.issuer),
      "scope": Json::string(scope),
    }
  })
}

///|
fn registration_of(row : Map[String, Json]) -> Registration {
  {
    scope: str(row, "scope"),
    node: str(row, "node"),
    issuer: str(row, "issuer"),
    generation: num(row, "generation"),
    name: str(row, "name"),
    made_by: str(row, "made_by"),
    revoked: num(row, "revoked"),
  }
}

///|
/// The token redeemed by the relay `node` is (its key, as the transport authenticated it, never a field it claims).
/// A new token enrolls a revoked identity again, at the next generation.
pub fn Enrollment::redeem(self : Enrollment, scope : String, token : String, node : String) -> Registration raise {
  ignore(key(scope))
  ignore(key(node))
  let digest = token_hash(self.crypto, token)
  let now = (self.now)()
  write(self.db, () => {
    guard first(self.db, "SELECT name, made_by FROM mesh_relay_tokens WHERE hash = ?1 AND scope = ?2 AND expires > ?3", [
        Json::string(digest),
        Json::string(scope),
        Json::number(now),
      ])
      is Some(pending) else {
      fail("relay enrollment token is invalid, expired, or already used")
    }
    let old = first(self.db, "SELECT * FROM mesh_relay_registrations WHERE scope = ?1 AND node = ?2", [
      Json::string(scope),
      Json::string(node),
    ])
    if old is Some(o) && str(o, "issuer") != self.issuer {
      fail("relay registration belongs to another issuer")
    }
    let (total, active) = match first(self.db, "SELECT COUNT(*) AS total, SUM(CASE WHEN revoked = 0 THEN 1 ELSE 0 END) AS active FROM mesh_relay_registrations WHERE scope = ?1", [
        Json::string(scope),
      ]) {
      Some(row) => (num(row, "total"), num(row, "active"))
      None => (0L, 0L)
    }
    let revoked_before = match old {
      Some(o) => num(o, "revoked") != 0L
      None => false
    }
    if (old is None && total >= record_most.to_int64()) ||
      ((old is None || revoked_before) && active >= active_most.to_int64()) {
      fail("workspace relay registration limit reached")
    }
    let generation = match old {
      Some(o) => num(o, "generation") + 1L
      None => 1L
    }
    guard generation <= 9007199254740991L else { fail("relay generation exhausted") }
    let name = str(pending, "name")
    let made_by = str(pending, "made_by")
    ignore(self.db.run("INSERT INTO mesh_relay_registrations(scope, node, issuer, generation, name, made_by, revoked) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0) ON CONFLICT(scope, node) DO UPDATE SET generation = excluded.generation, name = excluded.name, made_by = excluded.made_by, revoked = 0", [
      Json::string(scope),
      Json::string(node),
      Json::string(self.issuer),
      int_json(generation),
      Json::string(name),
      Json::string(made_by),
    ]))
    ignore(self.db.run("DELETE FROM mesh_relay_tokens WHERE hash = ?1", [Json::string(digest)]))
    { scope, node, issuer: self.issuer, generation, name, made_by, revoked: 0L }
  })
}

///|
/// The registration this station issued taken back, at its next generation.
pub fn Enrollment::revoke(self : Enrollment, scope : String, node : String) -> Registration raise {
  ignore(key(scope))
  ignore(key(node))
  write(self.db, () => {
    guard first(self.db, "SELECT * FROM mesh_relay_registrations WHERE scope = ?1 AND node = ?2 AND issuer = ?3", [
        Json::string(scope),
        Json::string(node),
        Json::string(self.issuer),
      ])
      is Some(old) else {
      fail("relay registration is not held by this issuer")
    }
    let generation = num(old, "generation") +
      (if num(old, "revoked") != 0L { 0L } else { 1L })
    guard generation <= 9007199254740991L else { fail("relay generation exhausted") }
    ignore(self.db.run("UPDATE mesh_relay_registrations SET revoked = 1, generation = ?1 WHERE scope = ?2 AND node = ?3", [
      int_json(generation),
      Json::string(scope),
      Json::string(node),
    ]))
    { ..registration_of(old), generation, revoked: 1L }
  })
}

///|
/// The registrations of every issuer of a scope as their stations signed them (relay-records.ts `RelayRecords.take`):
/// whether it changed what is kept (a newer generation of the same issuer's).
pub fn take_relay_record(db : @sql.Db, c : Crypto, signed : Json, scope : String, issuers : Set[String]) -> Bool raise {
  let record = relay_record_of(c, signed, scope, issuers)
  let node = text(field(record, "node")).unwrap_or("")
  let issuer = text(field(record, "issuer")).unwrap_or("")
  let generation = safe_int(field(record, "generation")).unwrap_or(0L)
  write(db, () => {
    let old = first(db, "SELECT issuer,generation FROM mesh_relay_records WHERE scope=?1 AND node=?2", [
      Json::string(scope),
      Json::string(node),
    ])
    if old is Some(o) && str(o, "issuer") != issuer {
      fail("relay identity already has another issuer")
    }
    if old is None {
      let n = match first(db, "SELECT COUNT(*) AS n FROM mesh_relay_records WHERE scope=?1", [Json::string(scope)]) {
        Some(row) => num(row, "n")
        None => 0L
      }
      guard n < 256L else { fail("too many relay identities in this scope") }
    }
    let changed = db.run("INSERT INTO mesh_relay_records(scope,node,issuer,generation,body,signature) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(scope,node) DO UPDATE SET generation=excluded.generation,body=excluded.body,signature=excluded.signature WHERE mesh_relay_records.issuer=excluded.issuer AND mesh_relay_records.generation<excluded.generation", [
      Json::string(scope),
      Json::string(node),
      Json::string(issuer),
      int_json(generation),
      field(signed, "body"),
      field(signed, "signature"),
    ])
    changed == 1
  })
}

///|
/// The address announcements of the scopes' stations, kept in the store and the newest of each held in memory
/// (announcements.ts `Announcements`): what was read of the store (`load`) and what came since, none of a node a
/// roster no longer names (`retain`).
pub struct Announcements {
  db : @sql.Db
  crypto : Crypto
  cache : Map[String, Map[String, Json]]
  mut roster_version : Int
  read : async (String, Array[String]) -> Array[Json]
}

///|
pub fn Announcements::new(db : @sql.Db, crypto : Crypto, read : async (String, Array[String]) -> Array[Json]) -> Announcements {
  { db, crypto, cache: Map([]), roster_version: 0, read }
}

///|
fn revision_of(signed : Json) -> Int64 {
  match text(field(signed, "body")) {
    Some(b) => (try { safe_int(field(@json.parse(b), "revision")).unwrap_or(0L) } catch { _ => 0L })
    None => 0L
  }
}

///|
fn node_of(signed : Json) -> String {
  match text(field(signed, "body")) {
    Some(b) => (try { text(field(@json.parse(b), "node")).unwrap_or("") } catch { _ => "" })
    None => ""
  }
}

///|
pub async fn Announcements::load(self : Announcements, scope : String, allowed : Set[String]) -> Unit {
  guard allowed.length() <= 256 else { fail("too many mesh identities") }
  let version = self.roster_version
  let records = (self.read)(scope, allowed.iter().collect())
  if version != self.roster_version {
    return
  }
  guard records.length() <= 256 else { fail("invalid stored mesh directory") }
  for r in records {
    ignore(announcement_of(self.crypto, r, scope, allowed))
  }
  for r in records {
    self.remember(scope, r)
  }
}

///|
pub fn Announcements::retain(self : Announcements, scopes : Map[String, Set[String]]) -> Unit {
  self.roster_version += 1
  for scope in self.cache.keys().collect() {
    match scopes.get(scope) {
      None => self.cache.remove(scope)
      Some(allowed) => {
        let nodes = self.cache[scope]
        for node in nodes.keys().collect() {
          if !allowed.contains(node) {
            nodes.remove(node)
          }
        }
      }
    }
  }
}

///|
fn Announcements::remember(self : Announcements, scope : String, signed : Json) -> Unit raise {
  let node = node_of(signed)
  let nodes = match self.cache.get(scope) {
    Some(n) => n
    None => {
      guard self.cache.length() < 32 else { fail("too many cached mesh scopes") }
      let n = Map([])
      self.cache[scope] = n
      n
    }
  }
  match nodes.get(node) {
    Some(old) => if revision_of(old) >= revision_of(signed) { return }
    None => if nodes.length() >= 256 { fail("too many cached mesh identities") }
  }
  nodes[node] = signed
}

///|
fn Announcements::keep(self : Announcements, scope : String, node : String, revision : Int64, signed : Json) -> Bool raise {
  self.db.run("INSERT INTO mesh_announcements(scope, node, revision, body, signature) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(scope, node) DO UPDATE SET revision = excluded.revision, body = excluded.body, signature = excluded.signature WHERE excluded.revision > mesh_announcements.revision", [
    Json::string(scope),
    Json::string(node),
    int_json(revision),
    field(signed, "body"),
    field(signed, "signature"),
  ]) ==
  1
}

///|
/// This station's announcement of its binding in `scope`: the one kept where its descriptor is the same, else the next
/// revision, signed.
pub fn Announcements::publish(self : Announcements, scope : String, descriptor : Json, signer : String) -> Json raise {
  ignore(descriptor_of(self.crypto, descriptor, scope, signer))
  let signed = write(self.db, () => {
    match first(self.db, "SELECT revision, body, signature FROM mesh_announcements WHERE scope = ?1 AND node = ?2", [
        Json::string(scope),
        Json::string(signer),
      ]) {
      Some(old) if field(@json.parse(str(old, "body")), "descriptor").stringify() == descriptor.stringify() =>
        Json::object({ "body": Json::string(str(old, "body")), "signature": Json::string(str(old, "signature")) })
      old => {
        let revision = match old {
          Some(o) => num(o, "revision") + 1L
          None => 1L
        }
        guard revision <= 9007199254740991L else { fail("mesh announcement revision exhausted") }
        let body : Json = {
          "scope": Json::string(scope),
          "node": Json::string(signer),
          "revision": int_json(revision),
          "descriptor": descriptor,
        }
        let body = body.stringify()
        guard byte_length(body) <= limit else { fail("mesh announcement too large") }
        let signed : Json = Json::object({
          "body": Json::string(body),
          "signature": Json::string((self.crypto.sign)(announcement_domain + body)),
        })
        ignore(announcement_of(self.crypto, signed, scope, Set::from_array([signer])))
        ignore(self.keep(scope, signer, revision, signed))
        signed
      }
    }
  })
  self.remember(scope, signed)
  signed
}

///|
/// Another station's announcement kept where it is newer: whether it changed what is kept.
pub fn Announcements::take(self : Announcements, raw : Json, scope : String, allowed : Set[String]) -> Bool raise {
  let value = announcement_of(self.crypto, raw, scope, allowed)
  let changed = self.keep(scope, value.node, value.revision, raw)
  if changed {
    self.remember(scope, raw)
  }
  changed
}

///|
/// The newest held of each node `allowed`, in its order.
pub fn Announcements::list(self : Announcements, scope : String, allowed : Array[String]) -> Array[Json] raise {
  guard allowed.length() <= 256 else { fail("too many mesh identities") }
  let out = []
  match self.cache.get(scope) {
    Some(nodes) =>
      for node in allowed {
        if nodes.get(node) is Some(r) {
          out.push(r)
        }
      }
    None => ()
  }
  out
}
