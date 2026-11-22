// Which of a module's items moved from here, kept across a start (station/src/move/kept.ts; move/AGENTS.md: each
// item's state is its module's, durable): a set of ids, records by key in one JSON file, or records by key kept a
// change a line (`KeptLog`), each read once as it is made and written as it changes, as that TypeScript writes them.

///|
/// What these parts ask of the machine's files (the host's: `host_disk`, over the shell; a test's).
pub(all) struct Disk {
  /// A file's text, read once before the station serves (None: it does not read).
  read : (String) -> String?
  /// `text` written whole at `path`, beside it and renamed into place, its folders made.
  write : async (String, String) -> Unit
  /// `text` appended to the file at `path`, made where it is not, its folders made.
  append : async (String, String) -> Unit
  /// What is at `path` let go (`rm(path, { force: true })`).
  remove : async (String) -> Unit
  /// Work started now, going on by itself (a rewrite asked as a file is read, as the TypeScript starts it).
  spawn : (async () -> Unit) -> Unit
}

///|
/// `[...items]` as a JSON array of strings.
fn strings_j(items : Array[String]) -> J {
  jstrs(items)
}

///|
/// A set of ids in one JSON file (kept.ts `KeptSet`), in the order they were added.
pub struct KeptSet {
  priv disk : Disk
  priv path : String
  priv ids : Array[String]
  priv index : Set[String]
  priv lock : @effect.Semaphore
}

///|
pub fn KeptSet::new(disk : Disk, path : String) -> KeptSet {
  let ids = []
  match (disk.read)(path) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(Arr(xs)) =>
          for x in xs {
            if x is Str(u) {
              let s = @jsjson.sanitize_str(u)
              if !ids.contains(s) {
                ids.push(s)
              }
            }
          }
        _ => ()
      }
    None => ()
  }
  { disk, path, ids, index: Set::from_array(ids), lock: @effect.Semaphore::new(1) }
}

///|
pub fn KeptSet::has(self : KeptSet, id : String) -> Bool {
  self.index.contains(id)
}

///|
pub fn KeptSet::values(self : KeptSet) -> Array[String] {
  self.ids.copy()
}

///|
pub fn KeptSet::size(self : KeptSet) -> Int {
  self.ids.length()
}

///|
pub async fn KeptSet::add(self : KeptSet, id : String) -> Unit {
  if self.index.contains(id) {
    return
  }
  self.index.add(id)
  self.ids.push(id)
  self.save()
}

///|
pub async fn KeptSet::delete(self : KeptSet, id : String) -> Unit {
  if !self.index.contains(id) {
    return
  }
  self.index.remove(id)
  match self.ids.search(id) {
    Some(i) => ignore(self.ids.remove(i))
    None => ()
  }
  self.save()
}

///|
async fn KeptSet::save(self : KeptSet) -> Unit {
  self.lock.with_permit(async fn() {
    (self.disk.write)(self.path, stringify(strings_j(self.ids)))
  })
}

///|
/// Records by key in one JSON file (kept.ts `KeptMap`): an object, its keys in the order they were first set.
pub struct KeptMap {
  priv disk : Disk
  priv path : String
  priv mut map : J
  priv lock : @effect.Semaphore
}

///|
pub fn KeptMap::new(disk : Disk, path : String) -> KeptMap {
  let map = match (disk.read)(path) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(Obj(_) as o) => o
        _ => jo([])
      }
    None => jo([])
  }
  { disk, path, map, lock: @effect.Semaphore::new(1) }
}

///|
pub fn KeptMap::get(self : KeptMap, key : String) -> J? {
  get(Some(self.map), key)
}

///|
pub fn KeptMap::entries(self : KeptMap) -> Array[(String, J)] {
  keys_of(self.map).map(k => (k, get(Some(self.map), k).unwrap()))
}

///|
pub async fn KeptMap::set(self : KeptMap, key : String, value : J) -> Unit {
  self.map = set(self.map, key, value)
  self.save()
}

///|
pub async fn KeptMap::delete(self : KeptMap, key : String) -> Unit {
  if !has_key(self.map, key) {
    return
  }
  self.map = del(self.map, key)
  self.save()
}

///|
async fn KeptMap::save(self : KeptMap) -> Unit {
  self.lock.with_permit(async fn() {
    (self.disk.write)(self.path, stringify(self.map))
  })
}

///|
/// Records by key kept across a start, a change a line appended (kept.ts `KeptLog`: `{"k": key, "v": record}`, `{"k":
/// key}` let go): read once, the lines played in order (one cut short left out), written again whole then where they
/// have grown past twice what they say (and 64) or the last was cut short. `from`: a file of before (one JSON
/// object), taken in and let go as the lines are first written. Each write after those asked before it.
pub struct KeptLog {
  priv disk : Disk
  priv path : String
  /// The records, by key, in the order a JavaScript Map keeps them (a key let go and set again goes last).
  priv keys : Array[String]
  priv map : Map[String, J]
  priv lock : @effect.Semaphore
  /// The rewrite asked as it was read: done before the first line written after it.
  priv mut owed : (async () -> Unit)?
}

///|
/// `later`: start the rewrite before the first append or in `written`. It includes the records present at that time.
pub fn KeptLog::new(
  disk : Disk,
  path : String,
  from? : (String, (J) -> Array[(String, J)]),
  later? : Bool = false,
) -> KeptLog {
  let log = {
    disk,
    path,
    keys: [],
    map: {},
    lock: @effect.Semaphore::new(1),
    owed: None,
  }
  match (disk.read)(path) {
    Some(t) => {
      let mut lines = 0
      for line in t.split("\n") {
        let line = line.to_string()
        if line == "" {
          continue
        }
        let r = match (try Ok(parse(line)) catch { e => Err(e) }) {
          Ok(r) => r
          Err(_) => continue
        }
        let k = match get(Some(r), "k") {
          Some(Str(u)) => @jsjson.sanitize_str(u)
          _ => continue
        }
        lines += 1
        if has_key(r, "v") {
          log.put(k, get(Some(r), "v").unwrap())
        } else {
          ignore(log.take(k))
        }
      }
      if lines > 2 * log.keys.length() + 64 || (t != "" && !t.has_suffix("\n")) {
        log.owed = Some(async fn() { log.rewrite() })
      }
    }
    None =>
      match from {
        Some((before, records)) =>
          match (disk.read)(before) {
            Some(t) =>
              match (try Ok(parse(t)) catch { e => Err(e) }) {
                Ok(raw) if !(raw is Null) => {
                  for p in records(raw) {
                    log.put(p.0, p.1)
                  }
                  log.owed = Some(async fn() {
                    log.rewrite()
                    (disk.remove)(before)
                  })
                }
                _ => ()
              }
            None => ()
          }
        None => ()
      }
  }
  // (begun at once, as the TypeScript's promise is: what is written after it waits for it)
  if log.owed is Some(_) && !later {
    (disk.spawn)(async fn() { log.written() })
  }
  log
}

///|
fn KeptLog::put(self : KeptLog, k : String, v : J) -> Unit {
  if !self.map.contains(k) {
    self.keys.push(k)
  }
  self.map[k] = v
}

///|
fn KeptLog::take(self : KeptLog, k : String) -> Bool {
  if !self.map.contains(k) {
    return false
  }
  self.map.remove(k)
  match self.keys.search(k) {
    Some(i) => ignore(self.keys.remove(i))
    None => ()
  }
  true
}

///|
pub fn KeptLog::get(self : KeptLog, key : String) -> J? {
  self.map.get(key)
}

///|
pub fn KeptLog::has(self : KeptLog, key : String) -> Bool {
  self.map.contains(key)
}

///|
pub fn KeptLog::values(self : KeptLog) -> Array[J] {
  self.keys.map(k => self.map[k])
}

///|
pub fn KeptLog::keys(self : KeptLog) -> Array[String] {
  self.keys.copy()
}

///|
pub fn KeptLog::size(self : KeptLog) -> Int {
  self.keys.length()
}

///|
pub async fn KeptLog::set(self : KeptLog, key : String, value : J) -> Unit {
  self.put(key, value)
  self.append_all([jo([("k", js(key)), ("v", value)])])
}

///|
pub async fn KeptLog::delete(self : KeptLog, key : String) -> Unit {
  if !self.take(key) {
    return
  }
  self.append_all([jo([("k", js(key))])])
}

///|
/// Record `key` set now, its line written by what is given back (in the order asked): what keeps a change it does not
/// wait for (scheduler.ts `StoppedSet`).
pub fn KeptLog::set_soon(self : KeptLog, key : String, value : J) -> async () -> Unit {
  self.put(key, value)
  let line = jo([("k", js(key)), ("v", value)])
  async fn() { self.append_all([line]) }
}

///|
/// Record `key` let go now (None: it was not kept), its line written by what is given back.
pub fn KeptLog::delete_soon(self : KeptLog, key : String) -> (async () -> Unit)? {
  if !self.take(key) {
    return None
  }
  let line = jo([("k", js(key))])
  Some(async fn() { self.append_all([line]) })
}

///|
/// Several changes in one write: each `(key, Some(value))` set, each `(key, None)` let go (one not kept: nothing).
pub async fn KeptLog::many(self : KeptLog, changes : Array[(String, J?)]) -> Unit {
  let lines = []
  for c in changes {
    match c.1 {
      Some(v) => {
        self.put(c.0, v)
        lines.push(jo([("k", js(c.0)), ("v", v)]))
      }
      None => if self.take(c.0) { lines.push(jo([("k", js(c.0))])) }
    }
  }
  if lines.length() > 0 {
    self.append_all(lines)
  }
}

///|
/// Lines appended, after what was asked before them (the rewrite as it was read first: one failing is let go).
async fn KeptLog::append_all(self : KeptLog, lines : Array[J]) -> Unit {
  let buf = StringBuilder::new()
  for l in lines {
    buf.write_string(stringify(l))
    buf.write_char('\n')
  }
  let text = buf.to_string()
  self.lock.with_permit(async fn() {
    match self.owed {
      Some(f) => {
        self.owed = None
        f() catch {
          _ => ()
        }
      }
      None => ()
    }
    (self.disk.append)(self.path, text)
  })
}

///|
/// The rewrite owed as it was read, done now (a start's: what a test waits for).
pub async fn KeptLog::written(self : KeptLog) -> Unit {
  self.lock.with_permit(async fn() {
    match self.owed {
      Some(f) => {
        self.owed = None
        f() catch {
          _ => ()
        }
      }
      None => ()
    }
  })
}

///|
async fn KeptLog::rewrite(self : KeptLog) -> Unit {
  let buf = StringBuilder::new()
  for k in self.keys {
    buf.write_string(stringify(jo([("k", js(k)), ("v", self.map[k])])))
    buf.write_char('\n')
  }
  (self.disk.write)(self.path, buf.to_string())
}

///|
/// The logins lent for what moved (kept.ts `LentLog`): each share's record (`s:<share>`) and a line for each item it
/// is lent for (`f:<share>\n<item>`), so an item that comes back writes its own line alone.
pub struct LentLog {
  priv log : KeptLog
  priv for_ : Map[String, Array[String]]
  priv shares_of : Map[String, Array[String]]
  priv shares : Array[String]
}

///|
/// `from`: the file of before (each share's record whole, its items in `for`).
/// `later`: as `KeptLog::new`'s.
pub fn LentLog::new(
  disk : Disk,
  path : String,
  from : String,
  later? : Bool = false,
) -> LentLog {
  let log = KeptLog::new(disk, path, later~, from=(from, raw => {
    let out = []
    let r = if raw is Obj(_) { raw } else { jo([]) }
    for share in keys_of(r) {
      let l = get(Some(r), share).unwrap()
      let base = del(l, "for")
      out.push(("s:\{share}", base))
      for n in arr(get(Some(l), "for")).unwrap_or([]) {
        out.push(("f:\{share}\n\{text(Some(n)).unwrap_or(stringify(n))}", js(share)))
      }
    }
    out
  }))
  let lent = { log, for_: {}, shares_of: {}, shares: [] }
  for k in log.keys() {
    if k.has_prefix("s:") {
      let s = slice_from(k, 2)
      if !lent.shares.contains(s) {
        lent.shares.push(s)
      }
    }
  }
  for k in log.keys() {
    if k.has_prefix("f:") {
      let nl = index_of(k, "\n")
      lent.index(slice(k, 2, nl), slice_from(k, nl + 1), true)
    }
  }
  lent
}

///|
fn LentLog::index(self : LentLog, share : String, item : String, on : Bool) -> Unit {
  let items = self.for_.get(share).unwrap_or([])
  let shares = self.shares_of.get(item).unwrap_or([])
  if on {
    if !items.contains(item) {
      items.push(item)
    }
    if !shares.contains(share) {
      shares.push(share)
    }
  } else {
    match items.search(item) {
      Some(i) => ignore(items.remove(i))
      None => ()
    }
    match shares.search(share) {
      Some(i) => ignore(shares.remove(i))
      None => ()
    }
  }
  if items.length() > 0 {
    self.for_[share] = items
  } else {
    self.for_.remove(share)
  }
  if shares.length() > 0 {
    self.shares_of[item] = shares
  } else {
    self.shares_of.remove(item)
  }
}

///|
/// Share `share`'s record, with the items it is lent for (`for`).
pub fn LentLog::get(self : LentLog, share : String) -> J? {
  match self.log.get("s:\{share}") {
    Some(Obj(_) as base) =>
      Some(set(base, "for", jstrs(self.for_.get(share).unwrap_or([]).copy())))
    _ => None
  }
}

///|
/// Every share lent.
pub fn LentLog::entries(self : LentLog) -> Array[(String, J)] {
  self.shares.map(s => (s, self.get(s).unwrap_or(jo([]))))
}

///|
/// The shares lent for item `name`.
pub fn LentLog::shares_for(self : LentLog, name : String) -> Array[String] {
  self.shares_of.get(name).unwrap_or([]).copy()
}

///|
pub fn LentLog::for_count(self : LentLog, share : String) -> Int {
  self.for_.get(share).map(a => a.length()).unwrap_or(0)
}

///|
/// Share `share`'s record but for what it is lent for.
pub fn LentLog::base(self : LentLog, share : String) -> J? {
  match self.log.get("s:\{share}") {
    Some(Obj(_) as b) => Some(b)
    _ => None
  }
}

///|
pub async fn LentLog::set_base(self : LentLog, share : String, base : J) -> Unit {
  if !self.shares.contains(share) {
    self.shares.push(share)
  }
  self.log.set("s:\{share}", base)
}

///|
/// Share `share`'s record (`for` in it: the items it is to be lent for).
pub async fn LentLog::set(self : LentLog, share : String, l : J) -> Unit {
  let items = arr(get(Some(l), "for")).unwrap_or([]).map(x => text(Some(x)).unwrap_or(""))
  let base = del(l, "for")
  if !self.shares.contains(share) {
    self.shares.push(share)
  }
  self.log.set("s:\{share}", base)
  let want = []
  for n in items {
    if !want.contains(n) {
      want.push(n)
    }
  }
  for n in self.for_.get(share).unwrap_or([]).copy() {
    if !want.contains(n) {
      self.unlent(share, n)
    }
  }
  for n in want {
    self.lent_for(share, n)
  }
}

///|
pub async fn LentLog::lent_for(self : LentLog, share : String, name : String) -> Unit {
  if self.for_.get(share).map(a => a.contains(name)).unwrap_or(false) {
    return
  }
  self.index(share, name, true)
  self.log.set("f:\{share}\n\{name}", js(share))
}

///|
pub async fn LentLog::unlent(self : LentLog, share : String, name : String) -> Unit {
  if !self.for_.get(share).map(a => a.contains(name)).unwrap_or(false) {
    return
  }
  self.index(share, name, false)
  self.log.delete("f:\{share}\n\{name}")
}

///|
pub async fn LentLog::delete(self : LentLog, share : String) -> Unit {
  for n in self.for_.get(share).unwrap_or([]).copy() {
    self.unlent(share, n)
  }
  match self.shares.search(share) {
    Some(i) => ignore(self.shares.remove(i))
    None => ()
  }
  self.log.delete("s:\{share}")
}

///|
/// Once what was asked to be written is (a test's).
pub async fn LentLog::written(self : LentLog) -> Unit {
  self.log.written()
}
