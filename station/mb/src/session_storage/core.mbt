// What the modules here are given: the station's parts (`Station`), the files (`Files`), and what each keeps in memory
// between calls (cold.ts's links followed and rooms found, clones.ts's clones, agent-home.ts's homes being made, the
// paths said to be left alone), one `Storage` a station.

///|
pub struct Storage {
  st : Station
  fs : Files
  /// archive.ts `reads`: each archived file read out of its archive by a name of its own.
  reads : Ref[Int]
  /// cold.ts `followed`, `rooms`.
  followed : Map[String, (Double, String?)]
  rooms : Map[String, String?]
  /// clones.ts: by workspace (`""` for none), oldest first; and whether the leftovers were swept.
  clones : Map[String, Array[Clone]]
  mut swept : @effect.Deferred[Unit]?
  /// agent-home.ts `leftAlone`.
  left_alone : Set[String]
  /// The tasks started that go on after their call (a clone): awaited by `settled`.
  going : Array[@effect.Fiber[Unit]]
}

///|
pub fn Storage::new(st : Station, fs : Files) -> Storage {
  {
    st,
    fs,
    reads: Ref::new(0),
    followed: {},
    rooms: {},
    clones: {},
    swept: None,
    left_alone: Set::new(),
    going: [],
  }
}

///|
async fn Storage::ask(self : Storage, name : String, args : Array[Json]) -> Json {
  self.st.ask(name, args)
}

///|
/// The station's clock (`hub.now()`, `wall.now()`).
async fn Storage::now(self : Storage) -> Double {
  as_num(Some(self.ask("hub.now", []))).unwrap_or(0.0)
}

///|
/// A line of the station's log (ops/log.ts).
async fn Storage::log(self : Storage, level : String, part : String, message : String, fields : Json) -> Unit {
  self.st.tell("log." + level, [js(part), js(message), fields])
}

///|
/// `hub.store.getSession(key)`: None where there is none.
async fn Storage::session(self : Storage, key : String) -> Json? {
  some_of(self.ask("store.getSession", [js(key)]))
}

///|
async fn Storage::data_dir(self : Storage) -> String {
  str(self.ask("hub.config", []), "dataDir").unwrap_or("")
}
