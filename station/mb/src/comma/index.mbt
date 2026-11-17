// An index Comma keeps a copy of (the Stats index `stats_index`, the Task index `task_index`), as the TypeScript
// station kept it (station/test/reference/comma-stats.ts RevIndex): rows numbered by `rev` within an `epoch`, a row
// gone leaving a tombstone until every connection's Comma holds it. Which connection holds what is Node's
// (src/comma/stats.ts): this program is let go when idle, and what it is told to prune is the least of them.

///|
/// The index's name, its table's: `stats_index` or `task_index`.
pub fn index_name(name : String) -> String raise {
  match name {
    "stats_index" | "task_index" => name
    _ => raise Failure("no such index: \{name}")
  }
}

///|
/// The tables a build writes and a page reads, made where they are not.
pub fn prepare(db : @sql.Db) -> Unit raise {
  db.exec(
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  )
  for name in ["stats_index", "task_index"] {
    db.exec(
      (
        $|CREATE TABLE IF NOT EXISTS \{name} (key TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, rev INTEGER NOT NULL,
        $|  json TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0);
        $|CREATE INDEX IF NOT EXISTS \{name}_rev ON \{name} (rev);
      ),
    )
  }
}

///|
fn meta(db : @sql.Db, name : String, key : String) -> String? raise {
  match
    db.all("SELECT value FROM meta WHERE key = ?", [
      Json::string("\{name}.\{key}"),
    ]) {
    [row, ..] =>
      match row.get("value") {
        Some(String(s)) => Some(s)
        Some(Number(_, ..) as n) => Some(n.stringify())
        _ => None
      }
    [] => None
  }
}

///|
fn set_meta(
  db : @sql.Db,
  name : String,
  key : String,
  value : String,
) -> Unit raise {
  ignore(
    db.run(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
      [Json::string("\{name}.\{key}"), Json::string(value)],
    ),
  )
}

///|
/// `Number(text)` of a counter kept as text in meta, 0 where it is none.
fn counter(text : String?) -> Int64 {
  match text {
    None => 0L
    Some(t) =>
      @string.parse_int64(t.trim().to_owned()) catch {
        _ =>
          (@string.parse_double(t.trim().to_owned()) catch { _ => 0.0 }).to_int64()
      }
  }
}

///|
/// The index's epoch as Comma is told it (one made where there is none yet).
pub fn epoch(db : @sql.Db, name : String) -> String raise {
  let epoch = match meta(db, name, "epoch") {
    Some(e) => e
    None => {
      let e = match db.all("SELECT lower(hex(randomblob(16))) AS e", []) {
        [row, ..] =>
          match row.get("e") {
            Some(String(s)) => s
            _ => raise Failure("no random epoch")
          }
        [] => raise Failure("no random epoch")
      }
      set_meta(db, name, "epoch", e)
      e
    }
  }
  // Earlier senders truncated the NUL-delimited stats keys: a new wire epoch made Comma rebuild its copy. Earlier
  // versions did not keep the prune floor: their copies were reset once.
  if name == "stats_index" {
    "\{epoch}.keys1.gc1"
  } else {
    "\{epoch}.gc1"
  }
}

///|
pub fn rev(db : @sql.Db, name : String) -> Int64 raise {
  counter(meta(db, name, "rev"))
}

///|
/// Greatest revision of a tombstone already pruned; it survives disconnected senders and process restarts.
pub fn pruned(db : @sql.Db, name : String) -> Int64 raise {
  counter(meta(db, name, "pruned"))
}

///|
/// A row as an index keeps it.
pub(all) struct IndexRow {
  key : Bytes
  source : Json
  kind : Json
  rev : Int64
  removed : Bool
  json : Json
}

///|
/// The rows past `since` in revision order, at most `limit`; a tombstone's old body left out where `omit_removed`.
pub fn rows_since(
  db : @sql.Db,
  name : String,
  after : Int64,
  limit : Int32,
  omit_removed : Bool,
) -> Array[IndexRow] raise {
  let body = if omit_removed {
    "CASE WHEN removed IS NOT 0 THEN '' ELSE json END AS json"
  } else {
    "json"
  }
  db
  .all(
    "SELECT CAST(key AS BLOB) AS key, source, kind, rev, removed, \{body} FROM \{name} WHERE rev > ? ORDER BY rev LIMIT ?",
    [jint(after), Json::number(limit.to_double())],
  )
  .map(r => {
    key: bytes_of(r.get("key")),
    source: r.get("source").unwrap_or(Json::null()),
    kind: r.get("kind").unwrap_or(Json::null()),
    rev: int_or(r.get("rev"), 0),
    removed: int_or(r.get("removed"), 0) != 0L,
    json: r.get("json").unwrap_or(Json::null()),
  })
}

///|
/// The trigger recording the highest tombstone removed, by this program or an older station's. Installed only once a
/// connection follows the index, after the old process exits: a schema write lock taken during startup could prevent
/// the handover itself.
pub fn guard_prunes(db : @sql.Db, name : String) -> Unit raise {
  db.exec(
    (
      $|CREATE TRIGGER IF NOT EXISTS \{name}_pruned AFTER DELETE ON \{name}
      $|  WHEN OLD.removed = 1 AND OLD.rev > COALESCE((SELECT CAST(value AS INTEGER) FROM meta WHERE key = '\{name}.pruned'), 0)
      $|  BEGIN
      $|    INSERT INTO meta (key, value) VALUES ('\{name}.pruned', CAST(OLD.rev AS TEXT))
      $|      ON CONFLICT (key) DO UPDATE SET value = excluded.value;
      $|  END;
    ),
  )
}

///|
/// The tombstones every connection's Comma holds (`through_all`, the least of what each holds) gone.
pub fn prune(db : @sql.Db, name : String, through_all : Int64) -> Unit raise {
  guard_prunes(db, name)
  ignore(
    db.run("DELETE FROM \{name} WHERE removed = 1 AND rev <= ?", [
      jint(through_all),
    ]),
  )
}

///|
/// The rows `given` written where they changed; a row not given tombstoned where `drop` says, among `kept` (all rows
/// not removed where none is given). Inside the caller's transaction; how many rows changed.
fn write(
  db : @sql.Db,
  name : String,
  given : Rows,
  drop : (@jsjson.JValue) -> Bool raise,
  kept? : Array[Kept],
) -> Int32 raise {
  let mut rev = rev(db, name)
  let mut changed = 0
  let keys : Map[String, Bool] = Map([])
  given.each((key, row) => {
    let bound = utf8_of(key)
    keys[hex_of(bound)] = true
    let k = Json::string(@utf8.decode_lossy(bound))
    let had = db.all("SELECT json, removed FROM \{name} WHERE key = ?", [k])
    if had is [h, ..] &&
      int_or(h.get("removed"), 1) == 0L &&
      h.get("json") is Some(String(json)) &&
      json == row.json {
      return
    }
    rev += 1L
    ignore(
      db.run(
        "INSERT INTO \{name} (key, source, kind, rev, json, removed) VALUES (?, ?, ?, ?, ?, 0) ON CONFLICT (key) DO UPDATE SET rev = excluded.rev, json = excluded.json, removed = 0",
        [
          k,
          Json::string(SOURCE),
          Json::string(row.kind),
          jint(rev),
          Json::string(row.json),
        ],
      ),
    )
    changed += 1
  })
  let kept = match kept {
    Some(k) => k
    None =>
      kept_rows(
        db.all(
          "SELECT CAST(key AS BLOB) AS key, json FROM \{name} WHERE removed = 0",
          [],
        ),
      )
  }
  for k in kept {
    if keys.contains(hex_of(k.key)) {
      continue
    }
    let (text, _) = body_text(k.json)
    if !drop(@jsjson.parse(text)) {
      continue
    }
    rev += 1L
    ignore(
      db.run(
        "UPDATE \{name} SET removed = 1, rev = ? WHERE key = CAST(? AS TEXT)",
        [
          jint(rev),
          Json::array(
            Array::makei(k.key.length(), i => {
              Json::number(k.key[i].to_int().to_double())
            }),
          ),
        ],
      ),
    )
    changed += 1
  }
  if changed > 0 {
    set_meta(db, name, "rev", rev.to_string())
  }
  changed
}

///|
/// A Task's current title, if it is in the index: Some(None) where its row says none (undefined), None where there is
/// no such Task (a removed one too).
pub fn task_title(
  db : @sql.Db,
  wanted : Array[Int32],
) -> @jsjson.JValue?? raise {
  let rows = db.all(
    "SELECT CAST(key AS BLOB) AS key, json FROM task_index WHERE key = ? AND rev > 0 AND removed = 0",
    [Json::string(@jsjson.text(wanted))],
  )
  guard rows is [row, ..] else { return None }
  // The binding of an unpaired surrogate becomes U+FFFD; the ordered reader compared the decoded key to ref.
  if !equal_units(decoded(bytes_of(row.get("key"))), wanted) {
    return None
  }
  let (text, _) = body_text(row.get("json"))
  match @jsjson.parse(text) {
    Obj(_) as t => Some(t.get("title"))
    Null => raise Failure("Cannot read properties of null (reading 'title')")
    _ => Some(None)
  }
}
