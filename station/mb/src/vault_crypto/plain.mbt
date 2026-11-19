// The library not locked (station/src/vault/plain.ts, 不加锁的库): in a workspace without security mode, a person's
// secrets kept on this station as they are, in plain text. Nothing here is encrypted: who may read an item is only who
// it is (its owner, by the email the cloud's credential says). The same tables, the same bodies byte for byte, the same
// checks and words as plain.ts.

///|
/// The id a plain library goes by where a vault's would (requests, the core's topics).
pub let plain_id : String = "plain"

///|
pub let kinds : Array[String] = ["token", "ssh_key", "login", "file", "browser"]

///|
pub let modes : Array[String] = ["proxy", "ssh", "env", "file", "browser"]

///|
/// The fields each kind of item holds.
pub fn fields_of(kind : String) -> Array[String] {
  match kind {
    "token" => ["value"]
    "ssh_key" => ["private_key", "public_key"]
    "login" => ["username", "password", "totp"]
    "file" => ["content", "filename"]
    "browser" => ["cookies"]
    _ => []
  }
}

///|
/// The most a file kept in the vault may be (its bytes).
pub let file_most : Int = 64 * 1024

///|
/// The most an item's `about` may be (its characters).
pub let about_most : Int = 2000

///|
let plain_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_plain (
  #|  ws TEXT NOT NULL,
  #|  id TEXT NOT NULL,
  #|  owner TEXT NOT NULL,
  #|  version INTEGER NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, id)
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_plain_lasts (
  #|  ws TEXT NOT NULL,
  #|  owner TEXT NOT NULL,
  #|  lasts TEXT NOT NULL,
  #|  at INTEGER NOT NULL,
  #|  PRIMARY KEY (ws, owner)
  #|);
  #|

///|
fn is_str(v : Json?, max? : Int = 100000) -> Bool {
  match v {
    Some(String(s)) => s.length() <= max
    _ => false
  }
}

///|
/// What JS's `trim` takes away: white space and line ends.
fn js_space(c : Int) -> Bool {
  (c >= 9 && c <= 13) || c == 32 || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 ||
  c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff
}

///|
fn blank(s : String) -> Bool {
  for i in 0..<s.length() {
    if !js_space(s.code_unit_at(i).to_int()) {
      return false
    }
  }
  true
}

///|
fn all_of(s : String, ok : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if !ok(s.code_unit_at(i).to_int()) {
      return false
    }
  }
  true
}

///|
fn b64_char(c : Int) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 43 || c == 47
}

///|
/// `/^[A-Za-z0-9+/]*={0,2}$/`.
fn base64_text(s : String) -> Bool {
  let mut n = s.length()
  let mut pads = 0
  while n > 0 && pads < 2 && s.code_unit_at(n - 1) == '=' {
    n = n - 1
    pads = pads + 1
  }
  all_of(s.unsafe_substring(start=0, end=n), b64_char)
}

///|
/// `Buffer.byteLength(s, "base64")`.
fn base64_length(s : String) -> Int {
  let mut n = s.length()
  if n > 0 && s.code_unit_at(n - 1) == '=' {
    n = n - 1
  }
  if n > 0 && s.code_unit_at(n - 1) == '=' {
    n = n - 1
  }
  n * 3 / 4
}

///|
fn field_of(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
/// Why a file's fields are not one (its content base64, at most `file_most`, its name a file's), or None.
pub fn file_ok(fields : Json) -> String? {
  let content = match field_of(Some(fields), "content") {
    Some(String(s)) => s
    None | Some(Null) => ""
    Some(v) => js_string(Some(v))
  }
  if content.length() % 4 != 0 || !base64_text(content) {
    return Some("a file's content is its bytes in base64")
  }
  if base64_length(content) > file_most {
    return Some("a file is at most \{file_most / 1024} KB")
  }
  match field_of(Some(fields), "filename") {
    None => ()
    Some(v) => {
      let name = js_string(Some(v))
      if name.length() > 200 || name.contains("/") || name.contains("\\") || name.contains("\u{0}") || name == "." || name == ".." {
        return Some("a file's name is a name, not a path")
      }
    }
  }
  None
}

///|
/// An item as the pages are told it: all but its fields.
pub fn shown(i : Json) -> Json {
  match i {
    Object(m) => {
      let rest : Map[String, Json] = Map([])
      for k, v in m {
        if k != "fields" {
          rest[k] = v
        }
      }
      Json::object(rest)
    }
    _ => i
  }
}

///|
fn item_id(s : String) -> Bool {
  s.length() == 28 && s.has_prefix("i_") &&
  all_of(s.unsafe_substring(start=2, end=28), c => (c >= 48 && c <= 57) || (c >= 65 && c <= 90))
}

///|
/// `/^(\*\.)?[a-z0-9.-]+$/`.
fn host_text(s : String) -> Bool {
  let body = if s.has_prefix("*.") { s.unsafe_substring(start=2, end=s.length()) } else { s }
  body.length() > 0 && all_of(body, c => (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 46 || c == 45)
}

///|
/// `/^[A-Za-z_][A-Za-z0-9_]*$/`.
fn env_text(s : String) -> Bool {
  s.length() > 0 &&
  all_of(s, c => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (c >= 48 && c <= 57)) &&
  !(s.code_unit_at(0).to_int() >= 48 && s.code_unit_at(0).to_int() <= 57)
}

///|
fn in_list(xs : Array[String], v : Json?) -> Bool {
  match v {
    Some(String(s)) => xs.contains(s)
    _ => false
  }
}

///|
/// Whether `next` may follow `prev` (None: a new one) for `owner`; why not, or None.
pub fn plain_ok(prev : Json?, next : Json, owner : String) -> String? {
  let n = Some(next)
  let prev = match prev {
    Some(Null) => None
    p => p
  }
  match field_of(n, "id") {
    Some(String(id)) if next is Object(_) && id.length() <= 64 && item_id(id) => ()
    _ => return Some("an item is {id: i_<ULID>, …}")
  }
  if !(field_of(n, "owner") is Some(String(o)) && o == owner) {
    return Some("an item is its owner's own")
  }
  if prev is Some(_) && !(field_of(prev, "owner") is Some(String(o)) && o == owner) {
    return Some("no such item here, or not yours")
  }
  if truthy(field_of(prev, "deleted")) {
    return Some("the item is deleted")
  }
  if !safe_int(field_of(n, "at")) {
    return Some("at is unix seconds")
  }
  if field_of(n, "deleted") is Some(True) {
    return None
  }
  guard field_of(n, "kind") is Some(String(kind)) && kinds.contains(kind) else {
    return Some("kind is token, ssh_key, login, file or browser")
  }
  if !is_str(field_of(n, "name"), max=200) || blank(str(field_of(n, "name")).unwrap_or("")) {
    return Some("an item has a name")
  }
  if !is_str(field_of(n, "notes"), max=10000) {
    return Some("notes are text")
  }
  let allowed = fields_of(kind)
  let fields_bad = match field_of(n, "fields") {
    Some(Object(fs)) => fs.iter().any(kv => !allowed.contains(kv.0) || !is_str(Some(kv.1)))
    Some(Array(xs)) => !xs.is_empty()
    _ => true
  }
  if fields_bad {
    return Some("a \{kind}'s fields are \{allowed.join(", ")}")
  }
  if kind == "file" {
    if file_ok(field_of(n, "fields").unwrap()) is Some(why) {
      return Some(why)
    }
  }
  match field_of(n, "listing") {
    None => ()
    Some(l) => {
      let l_ = Some(l)
      if !(l is Object(_) || l is Array(_)) || !is_str(field_of(l_, "name"), max=200) || !(field_of(l_, "kind") is Some(String(k)) && k == kind) {
        return Some("a listing names the item and its kind")
      }
      let ms = match field_of(l_, "modes") {
        Some(Array(ms)) if !ms.is_empty() && ms.iter().all(m => in_list(modes, Some(m))) => ms
        _ => return Some("a listing's modes are proxy, ssh, env, file or browser")
      }
      let has = fn(m : String) { ms.iter().any(x => x is String(s) && s == m) }
      if has("file") != (kind == "file") || (kind == "file" && ms.length() > 1) {
        return Some("a file is given as a file, and only a file is")
      }
      let hs = match field_of(l_, "hosts") {
        Some(Array(hs)) if hs.iter().all(h => is_str(Some(h), max=253) && host_text(str(Some(h)).unwrap())) => hs
        _ => return Some("a listing's hosts are host names")
      }
      if has("proxy") && hs.is_empty() {
        return Some("given through the proxy, it names its hosts")
      }
      if browser_listing_ok(l) is Some(why) {
        return Some(why)
      }
      match field_of(l_, "env") {
        None => ()
        Some(e) => if !(is_str(Some(e), max=100) && env_text(str(Some(e)).unwrap())) { return Some("env is a variable's name") }
      }
      match field_of(l_, "lasts") {
        None => ()
        Some(x) => if !in_list(scopes, Some(x)) { return Some("lasts is once, hour or chat") }
      }
      match field_of(l_, "about") {
        None => ()
        Some(a) => if !is_str(Some(a), max=about_most) { return Some("about is at most \{about_most} characters of text") }
      }
    }
  }
  None
}

///|
/// The plain library's tables in a database (station/src/vault/plain.ts `PlainStore`).
pub struct PlainStore {
  db : Db
}

///|
/// The plain store of `db`, its tables made where they are not.
pub fn PlainStore::new(db : Db) -> PlainStore raise DbError {
  db.exec(plain_schema)
  { db, }
}

///|
fn parsed(v : Json) -> Json {
  match v {
    String(s) => parse_js(s) catch { _ => Json::null() }
    _ => Json::null()
  }
}

///|
fn s(v : String) -> Json {
  Json::string(v)
}

///|
/// `owner`'s items in a workspace (deleted ones too: a version saying so).
pub fn PlainStore::items(self : PlainStore, ws : String, owner : String) -> Array[Json] raise DbError {
  self.db.all("SELECT body FROM vault_plain WHERE ws = ? AND owner = ? ORDER BY id", [s(ws), s(owner)]).map(r => parsed(r[0]))
}

///|
/// The first few of the same ordered list, including deleted versions: `(id, item)` each.
pub fn PlainStore::first_items(self : PlainStore, ws : String, owner : String, limit : Int) -> Array[(String, Json)] raise DbError {
  self.db
  .all("SELECT id, body FROM vault_plain WHERE ws = ? AND owner = ? ORDER BY id LIMIT ?", [s(ws), s(owner), Json::number(limit.to_double())])
  .map(r => (str(Some(r[0])).unwrap_or(""), parsed(r[1])))
}

///|
/// The rest of that list after a stored id.
pub fn PlainStore::items_after(self : PlainStore, ws : String, owner : String, id : String) -> Array[Json] raise DbError {
  self.db.all("SELECT body FROM vault_plain WHERE ws = ? AND owner = ? AND id > ? ORDER BY id", [s(ws), s(owner), s(id)]).map(r => parsed(r[0]))
}

///|
pub fn PlainStore::item(self : PlainStore, ws : String, id : String) -> Json? raise DbError {
  self.item_snapshot(ws, id).map(x => x.0)
}

///|
/// The item with the exact body stored, so that a later write can check its decision is still current.
pub fn PlainStore::item_snapshot(self : PlainStore, ws : String, id : String) -> (Json, String)? raise DbError {
  match self.db.get("SELECT body FROM vault_plain WHERE ws = ? AND id = ?", [s(ws), s(id)]) {
    Some([String(body), ..]) => Some((parsed(Json::string(body)), body))
    _ => None
  }
}

///|
/// The longest grant `owner`'s items are given for where an item says none, and when they said so (None: any).
pub fn PlainStore::lasts(self : PlainStore, ws : String, owner : String) -> (Json, Json)? raise DbError {
  match self.db.get("SELECT lasts, at FROM vault_plain_lasts WHERE ws = ? AND owner = ?", [s(ws), s(owner)]) {
    Some([lasts, at, ..]) => Some((lasts, at))
    _ => None
  }
}

///|
/// `owner`'s longest grant, said at `at` (unix seconds): kept unless what is kept was said later. Why not, or None.
pub fn PlainStore::set_lasts(self : PlainStore, ws : String, owner : String, lasts : Json?, at : Json?) -> String? raise DbError {
  if !in_list(scopes, lasts) {
    return Some("lasts is once, hour or chat")
  }
  if !safe_int(at) {
    return Some("at is unix seconds")
  }
  ignore(
    self.db.run(
      "INSERT INTO vault_plain_lasts (ws, owner, lasts, at) VALUES (?, ?, ?, ?) ON CONFLICT (ws, owner) DO UPDATE SET lasts = excluded.lasts, at = excluded.at WHERE excluded.at >= vault_plain_lasts.at",
      [s(ws), s(owner), lasts.unwrap(), at.unwrap()],
    ),
  )
  None
}

///|
/// An item let go of whole, no version kept.
pub fn PlainStore::forget(self : PlainStore, ws : String, id : String) -> Unit raise DbError {
  ignore(self.db.run("DELETE FROM vault_plain WHERE ws = ? AND id = ?", [s(ws), s(id)]))
}

///|
/// A new version in place of the one before; a deleted one keeps nothing of what it held.
pub fn PlainStore::put(self : PlainStore, i : Json) -> Unit raise DbError {
  let f = fn(k : String) { field_of(Some(i), k) }
  let kept = if truthy(f("deleted")) {
    let m : Map[String, Json] = Map([])
    for k in ["ws", "id", "owner", "version", "kind"] {
      if f(k) is Some(v) {
        m[k] = v
      }
    }
    m["name"] = s("")
    m["fields"] = Json::object(Map([]))
    m["notes"] = s("")
    if f("at") is Some(v) {
      m["at"] = v
    }
    m["deleted"] = Json::boolean(true)
    Json::object(m)
  } else {
    i
  }
  ignore(
    self.db.run(
      "INSERT INTO vault_plain (ws, id, owner, version, body) VALUES (?, ?, ?, ?, ?) ON CONFLICT (ws, id) DO UPDATE SET version = excluded.version, body = excluded.body",
      [f("ws").unwrap_or(Json::null()), f("id").unwrap_or(Json::null()), f("owner").unwrap_or(Json::null()), f("version").unwrap_or(Json::null()), s(stringify(kept))],
    ),
  )
}

///|
/// A snapshot as the vault's stores give it to the routes (vault/store.ts `{value, body}`: api_routes vault.mbt reads
/// `value` and `body`), or null where nothing is held.
pub fn snapshot_json(s : (Json, String)?) -> Json {
  match s {
    Some((value, body)) => { "value": value, "body": Json::string(body) }
    None => Json::null()
  }
}
