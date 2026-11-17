// What a chat platform calls people and channels, kept on disk (connects/names.ts: Slack's <data>/slack-names.json,
// Feishu's feishu-names.json...) so the admin API never waits on the platform for a name: a name not known yet answers
// null at once, is fetched in the background, and `on_learn` tells the pages to read again (once per burst). Failed
// lookups are not tried again for a while. The readers read the same file.

///|
let retry_failed_ms : Double = 600000.0

///|
/// A file of the station's own that it keeps in memory and writes through (ops/files.ts `PrivateFile`): what is asked
/// while a write is on its way is written after it, the latest only.
pub struct PrivateFile {
  path : String
  priv write_whole : async (String, String) -> Unit
  priv mut latest : String?
  priv mut writing : @effect.Deferred[Unit]?
}

///|
pub fn PrivateFile::new(path : String, write_whole : async (String, String) -> Unit) -> PrivateFile {
  { path, write_whole, latest: None, writing: None }
}

///|
/// Asks `data` written: the write it goes in (the one on its way goes on to it; none, one is started).
fn PrivateFile::asked(self : PrivateFile, data : String) -> @effect.Deferred[Unit] {
  self.latest = Some(data)
  match self.writing {
    Some(d) => d
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.writing = Some(d)
      spawn(async fn() {
        let failed : Ref[Error?] = Ref(None)
        while self.latest is Some(next) {
          self.latest = None
          (self.write_whole)(self.path, next) catch {
            e => {
              failed.val = Some(e)
              break
            }
          }
        }
        self.writing = None
        match failed.val {
          Some(e) => ignore(d.fail(e))
          None => ignore(d.succeed(()))
        }
      })
      d
    }
  }
}

///|
/// Asks `data` written: resolves (or raises) once the write it went in is done.
pub async fn PrivateFile::write(self : PrivateFile, data : String) -> Unit {
  self.asked(data).wait()
}

///|
/// Asks `data` written, nothing waiting: what it failed with goes to `failed`.
pub fn PrivateFile::write_soon(self : PrivateFile, data : String, failed : (Error) -> Unit) -> Unit {
  let d = self.asked(data)
  spawn(async fn() { d.wait() catch { e => failed(e) } })
}

///|
/// Once what was asked is written (or failed).
pub async fn PrivateFile::written(self : PrivateFile) -> Unit {
  match self.writing {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
}

///|
/// How long its batches wait (`NameBookOptions`).
pub struct NameBookOptions {
  save_after_ms : Double
  learn_after_ms : Double
}

///|
pub fn NameBookOptions::default() -> NameBookOptions {
  { save_after_ms: 2000.0, learn_after_ms: 200.0 }
}

///|
pub struct NameBook {
  path : String
  /// Each key's entry, as kept: `{person?, channel?, at}` (a channel's name null for a direct message, known to have
  /// none).
  priv entries : Map[String, J]
  priv pending : Set[String]
  priv failed : Map[String, Double]
  priv mut saving : Bool
  priv mut learning : Bool
  priv mut listener : () -> Unit
  priv save_after_ms : Double
  priv learn_after_ms : Double
  priv scope : @effect.Scope
  priv mut closed : Bool
  priv clock : Clock
  priv file : PrivateFile
  priv log : Log
}

///|
/// The book kept at `path`: what it holds read once, before the station serves (one that does not read starts empty,
/// said in the log).
pub async fn NameBook::open(path : String, fs : Fs, clock : Clock, log : Log, options? : NameBookOptions = NameBookOptions::default()) -> NameBook {
  let entries : Map[String, J] = Map([])
  let text = (fs.read_text)(path) catch { _ => "\u{0}" }
  if text != "\u{0}" {
    let unreadable = (error : String) => log.warn("connects", "names file unreadable; starting empty", jo([("path", js(path)), ("error", js(error))]))
    match (try Some(parse_js(text)) catch { e => { unreadable(thrown_message(e)); None } }) {
      Some(Obj(_) as kept) => for e in entries_of(Some(kept)) { entries[e.0] = e.1 }
      Some(_) => unreadable("not an object")
      None => ()
    }
  }
  {
    path,
    entries,
    pending: Set([]),
    failed: {},
    saving: false,
    learning: false,
    listener: () => (),
    save_after_ms: options.save_after_ms,
    learn_after_ms: options.learn_after_ms,
    scope: @effect.runtime().root().child(),
    closed: false,
    clock,
    file: PrivateFile::new(path, fs.write_private),
    log,
  }
}

///|
/// Called (once per burst) after names were learned, so pages read what shows them again.
pub fn NameBook::on_learn(self : NameBook, listener : () -> Unit) -> Unit {
  self.listener = listener
}

///|
fn at_of(entry : J?) -> Double {
  match at(entry, "at") {
    Some(Num(d)) => d
    Some(_) => @double.not_a_number
    None => 0.0
  }
}

///|
/// A person as far as known; one not known, or known but `stale` (given how long ago they were learned), is looked up
/// (again) in the background.
pub fn NameBook::person(
  self : NameBook,
  key : String,
  fetch : async () -> J?,
  stale? : (J, Double) -> Bool = (_, _) => false,
) -> J? {
  let entry = self.entries.get(key)
  let known = match at(entry, "person") {
    Some(Null) | None => None
    Some(p) => Some(p)
  }
  let again = match known {
    None => true
    Some(p) => stale(p, (self.clock.now)() - at_of(entry))
  }
  if again {
    self.learn(key, async fn() {
      match fetch() {
        None => None
        Some(person) => Some(jo([("person", person), ("at", jn((self.clock.now)()))]))
      }
    })
  }
  known
}

///|
/// A channel's name; null for a direct message (known) or not known yet.
pub fn NameBook::channel(self : NameBook, key : String, fetch : async () -> J) -> J {
  let known = at(self.entries.get(key), "channel")
  if known is None {
    self.learn(key, async fn() {
      let channel = fetch()
      Some(jo([("channel", channel), ("at", jn((self.clock.now)()))]))
    })
  }
  known.unwrap_or(Null)
}

///|
/// Ends its waits; what was learned and not yet saved is saved now, and resolves once it is written.
pub async fn NameBook::close(self : NameBook) -> Unit {
  if self.closed {
    return self.file.written()
  }
  self.closed = true
  self.scope.close()
  if self.saving {
    self.save()
  }
  self.file.written()
}

///|
fn NameBook::learn(self : NameBook, key : String, fetch : async () -> J?) -> Unit {
  if self.closed || self.pending.contains(key) || self.failed.get(key).unwrap_or(0.0) > (self.clock.now)() {
    return
  }
  self.pending.add(key)
  spawn(async fn() {
    let entry = fetch() catch { _ => None }
    self.pending.remove(key)
    match entry {
      None => self.failed[key] = (self.clock.now)() + retry_failed_ms
      Some(e) => {
        let mut merged = self.entries.get(key).unwrap_or(jo([("at", jn(0.0))]))
        if at(Some(e), "person") is Some(p) {
          merged = set_field(merged, "person", p)
        }
        if at(Some(e), "channel") is Some(c) {
          merged = set_field(merged, "channel", c)
        }
        merged = set_field(merged, "at", at(Some(e), "at").unwrap_or(jn(0.0)))
        self.entries[key] = merged
        self.later()
      }
    }
  })
}

///|
fn NameBook::later(self : NameBook) -> Unit {
  if self.closed {
    return
  }
  if !self.learning {
    self.learning = true
    self.after(self.learn_after_ms, () => {
      self.learning = false
      (self.listener)()
    })
  }
  if !self.saving {
    self.saving = true
    self.after(self.save_after_ms, () => self.save())
  }
}

///|
fn NameBook::after(self : NameBook, ms : Double, f : () -> Unit) -> Unit {
  spawn_in(self.scope, async fn() {
    (self.clock.sleep)(ms)
    f()
  })
}

///|
/// Written off the main thread (a write on its way and those asked meanwhile: the latest only, after it).
fn NameBook::save(self : NameBook) -> Unit {
  self.saving = false
  let text = js_stringify(from_entries(self.entries.to_array()))
  self.file.write_soon(text, e => self.log.warn("connects", "names not saved", jo([("path", js(self.path)), ("error", js(thrown_message(e)))])))
}
