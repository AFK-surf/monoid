// The reverse lookup of sandbox names (station/src/store/sandbox-index.ts): a sandbox's name is a hash of its
// session's key (agents/sandbox-name.ts), so it is computed here, for an older store's sessions and the keys writers
// changed, in bounded batches, as `enableSandboxIndex`, `disableSandboxIndex` and `sandboxIndexStep` do.

///|
let sandbox_version : Int = 1

///|
/// SHA-256 of `data` (bytes), as lowercase hex.
pub fn sha256_hex(data : Array[Int]) -> String {
  @hash.sha256_hex(Bytes::makei(data.length(), i => data[i].to_byte()))
}

///|
/// A string's UTF-8 bytes as JavaScript encodes it for a hash (a lone surrogate as U+FFFD).
pub fn utf8(s : String) -> Array[Int] {
  let out = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut c = s.unsafe_charcode_at(i)
    i += 1
    if c >= 0xd800 && c <= 0xdbff && i < n && s.unsafe_charcode_at(i) >= 0xdc00 && s.unsafe_charcode_at(i) <= 0xdfff {
      c = 0x10000 + ((c - 0xd800) << 10) + (s.unsafe_charcode_at(i) - 0xdc00)
      i += 1
    } else if c >= 0xd800 && c <= 0xdfff {
      c = 0xfffd
    }
    if c < 0x80 {
      out.push(c)
    } else if c < 0x800 {
      out.push(0xc0 | (c >> 6))
      out.push(0x80 | (c & 0x3f))
    } else if c < 0x10000 {
      out.push(0xe0 | (c >> 12))
      out.push(0x80 | ((c >> 6) & 0x3f))
      out.push(0x80 | (c & 0x3f))
    } else {
      out.push(0xf0 | (c >> 18))
      out.push(0x80 | ((c >> 12) & 0x3f))
      out.push(0x80 | ((c >> 6) & 0x3f))
      out.push(0x80 | (c & 0x3f))
    }
  }
  out
}

///|
fn hash10(s : String) -> String {
  @hash.sha256_utf8_hex(s).view(end_offset=10).to_string()
}

///|
/// A key as a runner's id has it (`keyPart`): each UTF-16 unit not a letter, digit, `_` or `-` as `_`, 24 at most,
/// a hash when that changed it.
pub fn key_part(key : String) -> String {
  let clean = StringBuilder::new()
  let n = if key.length() < 24 { key.length() } else { 24 }
  for i in 0..<n {
    let c = key.unsafe_charcode_at(i)
    let ok = (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
      (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
      (c >= '0'.to_int() && c <= '9'.to_int()) ||
      c == '_'.to_int() ||
      c == '-'.to_int()
    clean.write_char(if ok { c.unsafe_to_char() } else { '_' })
  }
  let cleaned = clean.to_string()
  if cleaned == key {
    cleaned
  } else {
    "\{cleaned}-\{hash10(key)}"
  }
}

///|
/// A sandbox's name for a key (`sandboxName`): the key lowercased as JavaScript does where that gives letters (ASCII,
/// the Kelvin sign, İ), its runs of other characters as `-`, trimmed, 16 at most; then a hash.
pub fn sandbox_name(key : String) -> String {
  let lower = StringBuilder::new()
  for c in key {
    let code = c.to_int()
    if code >= 'A'.to_int() && code <= 'Z'.to_int() {
      lower.write_char((code + 32).unsafe_to_char())
    } else if code == 0x212a {
      lower.write_char('k')
    } else if code == 0x130 {
      lower.write_char('i')
      lower.write_char('\u{307}')
    } else {
      lower.write_char(c)
    }
  }
  let dashed = StringBuilder::new()
  let mut run = false
  for c in lower.to_string() {
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
      dashed.write_char(c)
      run = false
    } else if !run {
      dashed.write_char('-')
      run = true
    }
  }
  let mut clean = dashed.to_string()
  // (trimmed of dashes, 16 at most, then of trailing dashes again)
  let mut start = 0
  while start < clean.length() && clean.unsafe_charcode_at(start) == '-'.to_int() {
    start += 1
  }
  let mut end = clean.length()
  while end > start && clean.unsafe_charcode_at(end - 1) == '-'.to_int() {
    end -= 1
  }
  clean = clean.view(start_offset=start, end_offset=end).to_string()
  if clean.length() > 16 {
    clean = clean.view(end_offset=16).to_string()
  }
  let mut cut = clean.length()
  while cut > 0 && clean.unsafe_charcode_at(cut - 1) == '-'.to_int() {
    cut -= 1
  }
  clean = clean.view(end_offset=cut).to_string()
  let hash = hash10(key)
  if clean == "" {
    "s-\{hash}"
  } else {
    "s-\{clean}-\{hash}"
  }
}

///|
fn sandbox_dirty(key : String) -> String {
  "INSERT INTO sandbox_name_dirty (session) SELECT \{key} WHERE \{key} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sandbox_name_dirty d WHERE d.session = \{key});"
}

///|
let sandbox_conflicts : String = "INSERT INTO sandbox_name_dirty (session) SELECT s.key FROM sessions s WHERE (s.token = NEW.token OR s.rowid = NEW.rowid) AND s.key IS NOT NEW.key AND NOT EXISTS (SELECT 1 FROM sandbox_name_dirty d WHERE d.session = s.key);"

///|
let enabled_check : String = "(SELECT enabled FROM sandbox_name_meta WHERE id = 1) = 1"

///|
pub fn sandbox_schema() -> String {
  [
    "CREATE TABLE sandbox_name_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, enabled INTEGER NOT NULL, phase INTEGER NOT NULL, cursor TEXT, prune INTEGER NOT NULL, end_session TEXT, end_prune TEXT) WITHOUT ROWID;",
    "INSERT INTO sandbox_name_meta (id, version, enabled, phase, cursor, prune, end_session, end_prune) VALUES (1, \{sandbox_version}, 1, 0, NULL, 0, (SELECT key FROM sessions WHERE key IS NOT NULL ORDER BY key DESC LIMIT 1), NULL);",
    "CREATE TABLE sandbox_name_rows (session TEXT PRIMARY KEY, name TEXT NOT NULL) WITHOUT ROWID;",
    "CREATE INDEX sandbox_name_lookup ON sandbox_name_rows (name);",
    "CREATE TABLE sandbox_name_dirty (session TEXT PRIMARY KEY) WITHOUT ROWID;",
    "CREATE TRIGGER sandbox_name_before_add BEFORE INSERT ON sessions WHEN \{enabled_check} BEGIN \{sandbox_dirty("NEW.key")} \{sandbox_conflicts} END;",
    "CREATE TRIGGER sandbox_name_before_change BEFORE UPDATE ON sessions WHEN (OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token) AND \{enabled_check} BEGIN \{sandbox_dirty("OLD.key")} \{sandbox_dirty("NEW.key")} \{sandbox_conflicts} END;",
    "CREATE TRIGGER sandbox_name_before_drop BEFORE DELETE ON sessions WHEN \{enabled_check} BEGIN \{sandbox_dirty("OLD.key")} END;",
  ].join("\n")
}

///|
fn sandbox_meta(db : @sql.Db) -> Int? raise {
  if db.first("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sandbox_name_meta'", []) is None {
    return None
  }
  let m = db.first("SELECT version, enabled FROM sandbox_name_meta WHERE id = 1", [])
  let v = match m {
    Some(r) => @sql.row_val(r, "version")
    None => Json::null()
  }
  guard v is Number(n, ..) && n.to_int() == sandbox_version && m is Some(r) else {
    let said = if v is Null { "missing" } else { v.stringify() }
    raise Failure("sandbox name index version \{said} is incompatible with \{sandbox_version}")
  }
  match @sql.row_val(r, "enabled") {
    Number(e, ..) => Some(e.to_int())
    _ => Some(0)
  }
}

///|
/// The lookup made, or switched on again with every key checked anew (`enableSandboxIndex`).
pub fn sandbox_enable(db : @sql.Db) -> Unit raise {
  if sandbox_meta(db) == Some(1) {
    return
  }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  match sandbox_meta(db) {
    None => db.exec(sandbox_schema())
    Some(0) =>
      db.exec(
        "UPDATE sandbox_name_meta SET enabled = 1, phase = 0, cursor = NULL, prune = 1, end_session = (SELECT key FROM sessions WHERE key IS NOT NULL ORDER BY key DESC LIMIT 1), end_prune = (SELECT session FROM sandbox_name_rows ORDER BY session DESC LIMIT 1) WHERE id = 1",
      )
    _ => ()
  }
  db.exec("COMMIT")
}

///|
/// Journaling stopped while sandboxes are off (`disableSandboxIndex`).
pub fn sandbox_disable(db : @sql.Db) -> Unit raise {
  if sandbox_meta(db) == Some(1) {
    db.exec("UPDATE sandbox_name_meta SET enabled = 0 WHERE id = 1")
  }
}

///|
/// At most `limit` keys named, pruned or journaled keys settled (`sandboxIndexStep`): the old sessions by key, then
/// (switched on again) the old rows of keys gone, then the journal. Whether nothing is left then.
pub fn sandbox_step(db : @sql.Db, limit? : Int = 64) -> Bool raise {
  guard limit >= 1 else { raise Failure("sandbox name batch must be positive") }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  guard db.first("SELECT version, enabled, phase, cursor, prune, end_session, end_prune FROM sandbox_name_meta WHERE id = 1", [])
    is Some(meta) &&
    @sql.row_val(meta, "version") is Number(v, ..) &&
    v.to_int() == sandbox_version else {
    raise Failure("sandbox name index version is incompatible with \{sandbox_version}")
  }
  if !(@sql.row_val(meta, "enabled") is Number(1.0, ..)) {
    db.exec("COMMIT")
    return true
  }
  let save = (session : Json) => match session {
    String(key) =>
      ignore(
        db.run(
          "INSERT INTO sandbox_name_rows (session, name) VALUES (?, ?) ON CONFLICT(session) DO UPDATE SET name = excluded.name WHERE name IS NOT excluded.name",
          [session, Json::string(sandbox_name(key_part(key)))],
        ),
      )
    _ => ()
  }
  let present = (session : Json) => db.first("SELECT 1 FROM sessions WHERE key = ?", [session]) is Some(_)
  let prune = @sql.row_val(meta, "prune") is Number(1.0, ..)
  let end_session = @sql.row_val(meta, "end_session")
  let end_prune = @sql.row_val(meta, "end_prune")
  let mut phase = match @sql.row_val(meta, "phase") {
    Number(p, ..) => p.to_int()
    _ => 0
  }
  let mut cursor = @sql.row_val(meta, "cursor")
  let mut visited = 0
  while visited < limit {
    let lim = Json::number((limit - visited).to_double())
    if phase == 0 {
      let rows = if end_session is Null {
        []
      } else if cursor is Null {
        db.all("SELECT key AS session FROM sessions WHERE key <= ? ORDER BY key LIMIT ?", [end_session, lim])
      } else {
        db.all("SELECT key AS session FROM sessions WHERE key > ? AND key <= ? ORDER BY key LIMIT ?", [cursor, end_session, lim])
      }
      if rows.length() == 0 {
        phase = if prune { 1 } else { 2 }
        cursor = Json::null()
        continue
      }
      for row in rows {
        let session = @sql.row_val(row, "session")
        save(session)
        ignore(db.run("DELETE FROM sandbox_name_dirty WHERE session = ?", [session]))
        cursor = session
        visited += 1
      }
    } else if phase == 1 {
      let rows = if end_prune is Null {
        []
      } else if cursor is Null {
        db.all("SELECT session FROM sandbox_name_rows WHERE session <= ? ORDER BY session LIMIT ?", [end_prune, lim])
      } else {
        db.all("SELECT session FROM sandbox_name_rows WHERE session > ? AND session <= ? ORDER BY session LIMIT ?", [cursor, end_prune, lim])
      }
      if rows.length() == 0 {
        phase = 2
        cursor = Json::null()
        continue
      }
      for row in rows {
        let session = @sql.row_val(row, "session")
        if !present(session) {
          ignore(db.run("DELETE FROM sandbox_name_rows WHERE session = ?", [session]))
        }
        cursor = session
        visited += 1
      }
    } else {
      let rows = db.all("SELECT session FROM sandbox_name_dirty ORDER BY session LIMIT ?", [lim])
      if rows.length() == 0 {
        break
      }
      for row in rows {
        let session = @sql.row_val(row, "session")
        if !present(session) {
          ignore(db.run("DELETE FROM sandbox_name_rows WHERE session = ?", [session]))
        } else {
          save(session)
        }
        ignore(db.run("DELETE FROM sandbox_name_dirty WHERE session = ?", [session]))
        visited += 1
      }
    }
  }
  ignore(db.run("UPDATE sandbox_name_meta SET phase = ?, cursor = ? WHERE id = 1", [Json::number(phase.to_double()), cursor]))
  let done = phase == 2 && db.first("SELECT 1 FROM sandbox_name_dirty LIMIT 1", []) is None
  db.exec("COMMIT")
  done
}
