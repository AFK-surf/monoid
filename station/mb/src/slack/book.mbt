// What Slack calls people and channels as far as known, without waiting (connects/names.ts `NameBook`, its entries in
// memory: where they are kept on disk is its owner's, `entries` and `on_learn` give it them): a name not known yet
// answers None at once, is fetched in the background, and `on_learn` tells whoever shows it to read again (once per
// burst). Failed lookups are not tried again for a while.

///|
let retry_failed_ms : Double = 600000.0

///|
pub struct NameBook {
  /// Each key's entry: `{person?, channel?, at}`.
  entries : Map[String, J]
  pending : Map[String, Unit]
  failed : Map[String, Double]
  clock : Clock
  learn_after_ms : Int
  save_after_ms : Int
  mut learning : Bool
  mut saving : Bool
  mut closed : Bool
  mut listener : () -> Unit
  /// What is kept (the whole book, as names.ts writes it), each time it should be written.
  saved : Ref[(J) -> Unit]
}

///|
pub fn NameBook::new(clock : Clock, kept? : J = Null, learn_after_ms? : Int = 200, save_after_ms? : Int = 2000) -> NameBook {
  let entries : Map[String, J] = Map([])
  match kept {
    Obj(fs) => for f in fs { entries[@jsjson.sanitize_str(f.0)] = f.1 }
    _ => ()
  }
  {
    entries,
    pending: {},
    failed: {},
    clock,
    learn_after_ms,
    save_after_ms,
    learning: false,
    saving: false,
    closed: false,
    listener: () => (),
    saved: Ref(_ => ()),
  }
}

///|
pub fn NameBook::on_learn(self : NameBook, f : () -> Unit) -> Unit {
  self.listener = f
}

///|
/// The book as it is kept (`Object.fromEntries(entries)`).
pub fn NameBook::to_j(self : NameBook) -> J {
  Obj(self.entries.iter().map(e => (e.0, e.1)).collect())
}

///|
/// A person as far as known; one not known, or known but `stale` (given how long ago they were learned), is looked up
/// (again) in the background.
pub fn NameBook::person(self : NameBook, key : String, fetch : async () -> J?, stale? : (J, Double) -> Bool = (_, _) => false) -> J? {
  let entry = self.entries.get(key)
  let known = match at(entry, "person") {
    None | Some(Null) => None
    p => p
  }
  let age = (self.clock.now)() - (match at(entry, "at") { Some(Num(d)) => d; _ => 0.0 })
  let again = match known {
    None => true
    Some(k) => stale(k, age)
  }
  if again {
    self.learn(key, async fn() {
      match fetch() {
        None => None
        Some(p) => Some(jo([("person", p), ("at", jn((self.clock.now)()))]))
      }
    })
  }
  known
}

///|
/// A channel's name; None for a direct message (known) or not known yet.
pub fn NameBook::channel(self : NameBook, key : String, fetch : async () -> String?) -> String? {
  let known = at(self.entries.get(key), "channel")
  if known is None {
    self.learn(key, async fn() { Some(jo([("channel", jopt(fetch())), ("at", jn((self.clock.now)()))])) })
  }
  str_of(known)
}

///|
pub fn NameBook::close(self : NameBook) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.saving {
    self.save()
  }
}

///|
fn NameBook::learn(self : NameBook, key : String, fetch : async () -> J?) -> Unit {
  if self.closed || self.pending.contains(key) || self.failed.get(key).unwrap_or(0.0) > (self.clock.now)() {
    return
  }
  self.pending[key] = ()
  self.clock.run(async fn() {
    let entry = fetch() catch { _ => None }
    self.pending.remove(key)
    match entry {
      None => self.failed[key] = (self.clock.now)() + retry_failed_ms
      Some(e) => {
        let mut merged = self.entries.get(key).unwrap_or(jo([("at", ji(0))]))
        match at(Some(e), "person") {
          Some(p) => merged = put(merged, "person", p)
          None => ()
        }
        match at(Some(e), "channel") {
          Some(c) => merged = put(merged, "channel", c)
          None => ()
        }
        merged = put(merged, "at", at(Some(e), "at").unwrap_or(ji(0)))
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
    self.clock.run(async fn() {
      (self.clock.sleep)(self.learn_after_ms)
      self.learning = false
      (self.listener)()
    })
  }
  if !self.saving {
    self.saving = true
    self.clock.run(async fn() {
      (self.clock.sleep)(self.save_after_ms)
      self.save()
    })
  }
}

///|
fn NameBook::save(self : NameBook) -> Unit {
  self.saving = false
  (self.saved.val)(self.to_j())
}

///|
/// A names book kept elsewhere (the connects' own, connects/names.ts), as a surface asks it: a person by key (looked
/// up with `fetch` where it is not known or `stale` says so), a channel's name by key.
pub(all) struct Names {
  person : (String, async () -> J?, (J, Double) -> Bool) -> J?
  channel : (String, async () -> String?) -> String?
}
