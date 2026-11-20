// Which session opened each tab of the station's browser (src/browser/owners.ts, "Whose a tab is"): learnt from the
// session's own connection to it (proxy.mbt) and from a tab's opener, kept in <data>/browser/owners.json as Chrome
// keeps its tabs, so the next station process that takes the browser up still knows them. A tab gone is forgotten.
// These are the station's own context's tabs: one in a chat's own context (browsers.mbt) is that chat's.

///|
/// A file of the station's own written through (ops/files.ts `PrivateFile`): what is asked while a write is on its way
/// is written after it, the latest only.
pub struct PrivateFile {
  path : String
  priv files : Files
  priv clock : Clock
  priv mut latest : String?
  priv mut writing : Later[Unit]?
}

///|
pub fn PrivateFile::new(path : String, files : Files, clock : Clock) -> PrivateFile {
  { path, files, clock, latest: None, writing: None }
}

///|
/// `data` written (after what is on its way); what it gives raises where the write failed.
pub fn PrivateFile::write(self : PrivateFile, data : String) -> Later[Unit] {
  self.latest = Some(data)
  match self.writing {
    Some(w) => w
    None => {
      let w = Later::start(self.clock, async fn() {
        let r = attempt(async fn() {
          while self.latest is Some(d) {
            self.latest = None
            (self.files.write_private)(self.path, d)
          }
        })
        self.writing = None
        match r {
          Ok(_) => ()
          Err(e) => raise e
        }
      })
      // (one that finished at once has let go of itself already)
      if !w.is_done() {
        self.writing = Some(w)
      }
      w
    }
  }
}

///|
/// Once what was asked is written (or failed).
pub async fn PrivateFile::written(self : PrivateFile) -> Unit {
  match self.writing {
    Some(w) =>
      w.wait() catch {
        _ => ()
      }
    None => ()
  }
}

///|
/// Whether a key is an array index, which a JavaScript object keeps first, in order (`/^(0|[1-9]\d*)$/`, below 2³²−1).
fn index_key(k : String) -> Double? {
  @jsjson.index_key(k)
}

///|
/// An object of `entries` as JavaScript makes one (`Object.fromEntries`): its index keys first, ascending, the rest in
/// the order they came.
pub fn js_object(entries : Array[(String, J)]) -> J {
  let idx = []
  let rest = []
  let seen : Map[String, Int] = {}
  let all : Array[(String, J)] = []
  for e in entries {
    match seen.get(e.0) {
      Some(i) => all[i] = e
      None => {
        seen[e.0] = all.length()
        all.push(e)
      }
    }
  }
  for e in all {
    match index_key(e.0) {
      Some(n) => idx.push((n, e))
      None => rest.push(e)
    }
  }
  idx.sort_by((a, b) => a.0.compare(b.0))
  jo(idx.map(p => p.1) + rest)
}

///|
pub struct Owners {
  priv file : PrivateFile
  priv of_ : Map[String, String]
  /// Tabs said gone before the file was read: not taken from it.
  priv gone : Map[String, Unit]
  priv mut loaded : Bool
  /// Changed before the file was read: written once it is.
  priv mut changed : Bool
  priv mut ready_ : Later[Unit]
  priv files : Files
  priv log : Log
}

///|
pub fn Owners::new(dir : String, files : Files, clock : Clock, log : Log) -> Owners {
  let o : Owners = {
    file: PrivateFile::new(join(dir, "owners.json"), files, clock),
    of_: {},
    gone: {},
    loaded: false,
    changed: false,
    ready_: Later::resolved(()),
    files,
    log,
  }
  o.ready_ = Later::start(clock, async fn() { o.load() })
  o
}

///|
/// Once what the file said is known.
pub async fn Owners::ready(self : Owners) -> Unit {
  self.ready_.wait() catch {
    _ => ()
  }
}

///|
/// Once what was changed is written down (or failed).
pub async fn Owners::written(self : Owners) -> Unit {
  self.ready()
  self.file.written()
}

///|
/// The session that opened tab `target_id`, if one is known.
pub fn Owners::of(self : Owners, target_id : String) -> String? {
  self.of_.get(target_id)
}

///|
/// Tab `target_id` is `session`'s; whether that is news.
pub fn Owners::set(self : Owners, target_id : String, session : String) -> Bool {
  if self.of_.get(target_id) == Some(session) {
    return false
  }
  self.of_[target_id] = session
  self.gone.remove(target_id)
  self.write()
  true
}

///|
/// Tab `target_id` is gone.
pub fn Owners::drop(self : Owners, target_id : String) -> Unit {
  if !self.loaded {
    self.gone[target_id] = ()
    self.of_.remove(target_id)
    self.write()
    return
  }
  if self.of_.contains(target_id) {
    self.of_.remove(target_id)
    self.write()
  }
}

///|
/// Only these tabs are there (the browser as a station process takes it up): the rest are forgotten.
pub fn Owners::keep(self : Owners, target_ids : Array[String]) -> Unit {
  let mut changed = false
  let ids = []
  for id, _ in self.of_ {
    ids.push(id)
  }
  for id in ids {
    if !target_ids.contains(id) {
      self.of_.remove(id)
      changed = true
    }
  }
  if changed {
    self.write()
  }
}

///|
async fn Owners::load(self : Owners) -> Unit {
  let was = match (self.files.read)(self.file.path) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(Obj(_) as v) =>
          entries_of(v).filter(e => e.1 is Str(u) && u.length() > 0).map(e => (e.0, js_str(Some(e.1))))
        _ => []
      }
    None => []
  }
  // (an object's index keys first, as Object.entries gives them)
  let ordered = match js_object(was.map(e => (e.0, js(e.1)))) {
    Obj(fs) => fs.map(f => (@jsjson.sanitize_str(f.0), js_str(Some(f.1))))
    _ => []
  }
  for e in ordered {
    if !self.of_.contains(e.0) && !self.gone.contains(e.0) {
      self.of_[e.0] = e.1
    }
  }
  self.loaded = true
  self.gone.clear()
  // What was learnt meanwhile, written now with what the file had.
  if self.changed {
    self.write()
  }
}

///|
fn Owners::write(self : Owners) -> Unit {
  // Before the file is read, written once it is (with what it had).
  if !self.loaded {
    self.changed = true
    return
  }
  let entries = []
  for k, v in self.of_ {
    entries.push((k, js(v)))
  }
  let w = self.file.write(stringify_pretty(js_object(entries)) + "\n")
  let log = self.log
  (self.file.clock.spawn)(async fn() {
    w.wait() catch {
      e => (log.warn)("browser", "the tabs' owners could not be written", fields([("error", js(message_of(e)))]))
    }
  })
}
