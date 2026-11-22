// The trees of Markdown kept on the device and the logs opened there, one station's of an account's database, as the
// TypeScript core keeps them (client/core-ts/src/data.ts `mdStore`, `flushMd`; src/db/account.ts `keptMd`,
// `keptMdMany`, `flushMd`, `noteOpened`). Reading only reads: a tree read afresh (`put_prepared`), one shown that was
// not noted shown lately (`get`), a log opened (`note_opened`) is pending here, read back at once, and written in one
// transaction once what a page waits for has gone (`flush_turn`), so a chat's page opening writes nothing.
//
//   md_kept (station, key, of, size, used, json)  PRIMARY KEY (station, key)   (schema.ts ensureMdKept)
//   log_use (kind, station, id, opened, evicted)  PRIMARY KEY (kind, station, id)

///|
/// How the trees kept are read: markdown.ts `MD_READING`, its number raised as what reading makes of a text changes.
pub let md_reading : Int = 14

///|
/// The earliest reading whose trees can still be drawn while read again: markdown.ts `MD_DRAWABLE_FROM`.
pub let md_drawable_from : Int = 1

///|
/// A tree shown is noted shown again at most this often (ms): account.ts `MD_SHOWN_EVERY`.
pub let md_shown_every : Int64 = 86_400_000L

///|
/// What the trees kept take at most (characters of their JSON), and what they are let go down to past it: account.ts
/// `MD_KEPT`, `MD_KEPT_TO`.
pub let md_kept_most : Int = 32 * 1024 * 1024

///|
let md_kept_to_percent : Int = 80

///|
/// A text's key among the trees kept: the reading, its length and two FNV-1a hashes of its UTF-16 code units (64
/// bits), written in base 36: markdown.ts `mdKey`, the same key for the same text.
pub fn md_key(text : String) -> String {
  let mut a = 0x811c9dc5U.reinterpret_as_int()
  let mut b = 0x01000193 ^ text.length()
  for i in 0..<text.length() {
    let c = text.code_unit_at(i).to_int()
    a = (a ^ c) * 0x01000193
    b = (b ^ c) * 0x0100019d
  }
  let a36 = a.reinterpret_as_uint().to_string(radix=36)
  let b36 = b.reinterpret_as_uint().to_string(radix=36)
  "\{md_reading}.\{text.length()}.\{a36}.\{b36}"
}

///|
/// The keys the same text had in the drawable older readings, the latest first: markdown.ts `olderMdKeys`.
pub fn older_md_keys(key : String, from? : Int = md_drawable_from) -> Array[String] {
  let out : Array[String] = []
  guard key.find(".") is Some(dot) else { return out }
  let suffix = key.clamped_view(start=dot).to_owned()
  for reading = md_reading - 1; reading >= from; reading = reading - 1 {
    out.push("\{reading}\{suffix}")
  }
  out
}

///|
/// The statements this store runs: the tests' database answers these alone (fake_wbtest.mbt).
let sql_md_one : String = "SELECT used, json FROM md_kept WHERE station = ? AND key = ?"

///|
let sql_md_many_head : String = "SELECT key, used, json FROM md_kept WHERE station = ? AND key IN ("

///|
let sql_opened : String = "SELECT opened FROM log_use WHERE kind = ? AND station = ? AND id = ?"

///|
let sql_note_opened : String = "INSERT INTO log_use (kind, station, id, opened, evicted) VALUES (?, ?, ?, ?, 0) ON CONFLICT (kind, station, id) DO UPDATE SET opened = excluded.opened, evicted = 0"

///|
let sql_md_make : String = "CREATE TABLE IF NOT EXISTS md_kept (station TEXT NOT NULL, key TEXT NOT NULL, of TEXT NOT NULL, size INTEGER NOT NULL, used INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, key)) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS md_kept_used ON md_kept (used); CREATE INDEX IF NOT EXISTS md_kept_of ON md_kept (station, of);"

///|
let sql_md_touch : String = "UPDATE md_kept SET used = ? WHERE station = ? AND key = ?"

///|
let sql_md_total : String = "SELECT coalesce(sum(size), 0) FROM md_kept"

///|
let sql_md_size : String = "SELECT size FROM md_kept WHERE station = ? AND key = ?"

///|
let sql_md_drop : String = "DELETE FROM md_kept WHERE station = ? AND key = ?"

///|
let sql_md_put : String = "INSERT OR REPLACE INTO md_kept (station, key, of, size, used, json) VALUES (?, ?, ?, ?, ?, ?)"

///|
let sql_md_by_use : String = "SELECT station, key, size FROM md_kept ORDER BY used"

///|
/// A tree as kept: when it was last noted shown, and its JSON.
#derive(Eq, Debug)
pub(all) struct Kept {
  used : Int64
  json : String
}

///|
/// A tree read, to be kept (`flush_turn`): for `of` (a chat, `t:<thread>`; an agent, `s:<session>`), in place of the
/// one it `replaces`.
priv struct MdPut {
  of_ : String
  key : String
  json : String
  at : Int64
  replaces : String?
}

///|
/// One station's trees and logs opened, of an account's database.
pub struct MdStore {
  db : @sql.Sql
  station : String
  /// What it read of the device: found, or not there (`None`).
  priv read : Map[String, Kept?]
  priv puts : Map[String, MdPut]
  priv touches : Map[String, Int64]
  /// When each log was opened this run, by `kind id`: read as it is, its write maybe still to come.
  priv opened_at : Map[String, Int64]
  priv uses : Map[String, (String, String, Int64)]
  /// Whether `md_kept` is there to read: a read that fails takes it for none until a write makes it.
  priv mut kept_there : Bool
  priv mut size : Int?
  /// Told as something comes to be pending, from none: what brings `flush_turn` round after the page's first values.
  priv later : () -> Unit
  priv mut asked_later : Bool
}

///|
/// The store of `station`'s trees in `db`; `later` is told once as something comes to be pending (from none), to call
/// `flush_turn` after what a page waits for.
pub fn MdStore::new(db : @sql.Sql, station : String, later? : () -> Unit = () => ()) -> MdStore {
  {
    db,
    station,
    read: Map([]),
    puts: Map([]),
    touches: Map([]),
    opened_at: Map([]),
    uses: Map([]),
    kept_there: true,
    size: None,
    later,
    asked_later: false,
  }
}

///|
fn MdStore::pending_now(self : MdStore) -> Unit {
  if self.asked_later {
    return
  }
  self.asked_later = true
  (self.later)()
}

///|
/// Whether anything waits to be written.
pub fn MdStore::pending(self : MdStore) -> Bool {
  !self.puts.is_empty() || !self.touches.is_empty() || !self.uses.is_empty()
}

///|
/// A tree as kept on the device, read now: none where it is not kept or `md_kept` cannot be read.
fn MdStore::kept_one(self : MdStore, key : String) -> Kept? {
  if !self.kept_there {
    return None
  }
  let rows = self.db.all(sql_md_one, params=[Json::string(self.station), Json::string(key)]) catch {
    _ => {
      self.kept_there = false
      return None
    }
  }
  match rows.get(0) {
    Some(r) => Some({ used: @sql.col_int64(r, 0), json: @sql.col_text(r, 1) })
    None => None
  }
}

///|
/// The trees of `keys` kept, in one statement for each `@sql.chunk_most` of them.
fn MdStore::kept_many(self : MdStore, keys : Array[String]) -> Map[String, Kept] {
  let out : Map[String, Kept] = Map([])
  if !self.kept_there || keys.is_empty() {
    return out
  }
  let found = @sql.query_in_chunks(
    self.db,
    keys,
    make_sql=ph => sql_md_many_head + ph + ")",
    extra_params=[Json::string(self.station)],
    decode=r => Some((@sql.col_text(r, 0), Kept::{ used: @sql.col_int64(r, 1), json: @sql.col_text(r, 2) })),
  ) catch {
    _ => {
      self.kept_there = false
      return out
    }
  }
  for f in found {
    out.set(f.0, f.1)
  }
  out
}

///|
/// The trees of `keys` read at once, before each is asked for: one statement for a page of them (views.ts `drawn`).
/// Those not kept are looked for as older readings kept them, in one statement too, where `older`.
pub fn MdStore::preload(self : MdStore, keys : Array[String], older? : Bool = true) -> Unit {
  let rest = keys.filter(k => !self.puts.contains(k) && !self.read.contains(k))
  if rest.is_empty() {
    return
  }
  let found = self.kept_many(rest)
  for k in rest {
    self.read.set(k, found.get(k))
  }
  if !older {
    return
  }
  let olders : Array[String] = []
  for k in rest {
    if !found.contains(k) {
      for o in older_md_keys(k) {
        if !self.puts.contains(o) && !self.read.contains(o) {
          olders.push(o)
        }
      }
    }
  }
  if olders.is_empty() {
    return
  }
  let old = self.kept_many(olders)
  for k in olders {
    self.read.set(k, old.get(k))
  }
}

///|
/// Whether a tree of `key` is there: pending, read, or kept.
pub fn MdStore::has(self : MdStore, key : String) -> Bool {
  if self.puts.contains(key) {
    return true
  }
  match self.read.get(key) {
    Some(found) => found is Some(_)
    None => {
      let found = self.kept_one(key)
      self.read.set(key, found)
      found is Some(_)
    }
  }
}

///|
/// The latest drawable older reading's key kept for `key`, if any: markdown.ts `oldMdKey`.
pub fn MdStore::older_kept(self : MdStore, key : String) -> String? {
  for o in older_md_keys(key) {
    if self.has(o) {
      return Some(o)
    }
  }
  None
}

///|
/// The tree of `key` (its JSON): pending, or read of the device (once: kept after). Shown at `now`, and not noted
/// shown in `md_shown_every`, it is noted so, pending.
pub fn MdStore::get(self : MdStore, key : String, now : Int64) -> String? {
  if self.puts.get(key) is Some(p) {
    return Some(p.json)
  }
  let found = match self.read.get(key) {
    Some(f) => f
    None => {
      let f = self.kept_one(key)
      self.read.set(key, f)
      f
    }
  }
  guard found is Some(k) else { return None }
  if now - k.used >= md_shown_every && !self.touches.contains(key) {
    self.touches.set(key, now)
    // (read back as noted: once written, it is not noted again within `md_shown_every`)
    self.read.set(key, Some({ ..k, used: now }))
    self.pending_now()
  }
  Some(k.json)
}

///|
/// A tree read here (`json`), for `of`, kept pending: read back at once, written by `flush_turn`, in place of the one
/// it `replaces`.
pub fn MdStore::put_prepared(
  self : MdStore,
  key : String,
  json : String,
  of_~ : String,
  at~ : Int64,
  replaces? : String,
) -> Unit {
  self.puts.set(key, { of_, key, json, at, replaces })
  self.touches.remove(key)
  if replaces is Some(r) {
    self.puts.remove(r)
    self.read.set(r, None)
  }
  // (read back as it is written: once written, asked again it is not read of the device)
  self.read.set(key, Some({ used: at, json }))
  self.pending_now()
}

///|
/// A log (`kind`: `entry` a chat's, `transcript` an agent's; `id` its thread or session) opened at `at`: noted here,
/// written by `flush_turn`.
pub fn MdStore::note_opened(self : MdStore, kind : String, id : String, at : Int64) -> Unit {
  let k = "\{kind}\u{1}\{id}"
  self.opened_at.set(k, at)
  self.uses.set(k, (kind, id, at))
  self.pending_now()
}

///|
/// When a log was last opened: as noted this run, its write maybe still to come, else as kept.
pub fn MdStore::last_opened(self : MdStore, kind : String, id : String) -> Int64? raise @shell.ShellError {
  if self.opened_at.get("\{kind}\u{1}\{id}") is Some(at) {
    return Some(at)
  }
  let rows = self.db.all(sql_opened, params=[
    Json::string(kind),
    Json::string(self.station),
    Json::string(id),
  ])
  match rows.get(0) {
    Some(r) => @sql.col_opt_int64(r, 0)
    None => None
  }
}

///|
/// Writes what is pending, in one transaction (a burst of `burst`, begun by its first write and committed here):
/// the logs opened, the trees shown again, the trees read (each in place of the one it replaces), and past
/// `md_kept_most` the least lately shown let go. Answers whether it wrote anything.
pub fn MdStore::flush_turn(self : MdStore, burst? : @sql.Burst) -> Bool raise {
  self.asked_later = false
  if !self.pending() {
    return false
  }
  let burst = match burst {
    Some(b) => b
    None => @sql.Burst::new(self.db)
  }
  let station = Json::string(self.station)
  let uses = self.uses.values().collect()
  let touches = self.touches.iter().collect()
  let puts = self.puts.values().collect()
  self.uses.clear()
  self.touches.clear()
  self.puts.clear()
  burst.in_tx(b => {
    for u in uses {
      let (kind, id, at) = u
      ignore(
        b.run(sql_note_opened, params=[
          Json::string(kind),
          station,
          Json::string(id),
          Json::number(at.to_double()),
        ]),
      )
    }
    if touches.is_empty() && puts.is_empty() {
      return
    }
    if !self.kept_there {
      b.exec(sql_md_make)
      self.kept_there = true
    }
    let put_keys : Set[String] = Set([])
    for p in puts {
      put_keys.add(p.key)
    }
    for t in touches {
      if !put_keys.contains(t.0) {
        ignore(
          b.run(sql_md_touch, params=[Json::number(t.1.to_double()), station, Json::string(t.0)]),
        )
      }
    }
    if puts.is_empty() {
      return
    }
    let mut size = match self.size {
      Some(s) => s
      None => @sql.col_int(b.all(sql_md_total).get(0).unwrap_or([]), 0)
    }
    let size_of = (key : String) => @sql.col_int(
      b.all(sql_md_size, params=[station, Json::string(key)]).get(0).unwrap_or([]),
      0,
    )
    for p in puts {
      let was = size_of(p.key)
      if p.replaces is Some(r) && r != p.key {
        let old = size_of(r)
        ignore(b.run(sql_md_drop, params=[station, Json::string(r)]))
        size -= old
      }
      ignore(
        b.run(sql_md_put, params=[
          station,
          Json::string(p.key),
          Json::string(p.of_),
          Json::number(p.json.length().to_double()),
          Json::number(p.at.to_double()),
          Json::string(p.json),
        ]),
      )
      size += p.json.length() - was
    }
    if size > md_kept_most {
      for r in b.all(sql_md_by_use) {
        if size.to_int64() * 100L <= md_kept_most.to_int64() * md_kept_to_percent.to_int64() {
          break
        }
        ignore(b.run(sql_md_drop, params=[r[0], r[1]]))
        size -= @sql.col_int(r, 2)
        if @sql.col_text(r, 0) == self.station {
          self.read.remove(@sql.col_text(r, 1))
        }
      }
    }
    self.size = Some(size)
  })
  true
}
