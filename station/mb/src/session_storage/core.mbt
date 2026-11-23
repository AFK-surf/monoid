// What the modules here are given: the station's parts (`Station`), the files (`Files`), and what each keeps in memory
// between calls (cold.ts's links followed and rooms found, clones.ts's clones, agent-home.ts's homes being made, the
// paths said to be left alone), one `Storage` a station.

///|
/// Workspaces larger than this after cleaning rebuildable directories are left unpacked on archive (marked `cold` so
/// expiry and low-disk reclamation still apply, and transcripts are still packed).
pub let max_pack_workspace_bytes : Double = 2.0 * 1024.0 * 1024.0 * 1024.0

///|
pub struct Storage {
  st : Station
  fs : Files
  /// archive.ts `reads`: each archived file read out of its archive by a name of its own.
  reads : Ref[Int]
  /// cold.ts `followed`, `rooms`.
  followed : Map[String, (Double, String?)]
  rooms : Map[String, String?]
  /// When each room in `rooms` was found: one found is kept for as long as a followed link (`followed_ms`).
  priv rooms_at : Map[String, Double]
  /// When following each path failed (cold.ts `canonical`'s rejection): not followed again for as long as a followed
  /// link is kept, and taken meanwhile as never followed (in use).
  priv follow_failed : Map[String, Double]
  /// The station's sessions directory, followed: found once, as it is not moved while the station runs.
  priv sessions_real : Ref[String?]
  /// clones.ts: by workspace (`""` for none), oldest first; and whether the leftovers were swept.
  clones : Map[String, Array[Clone]]
  mut swept : @effect.Deferred[Unit]?
  /// agent-home.ts `leftAlone`.
  left_alone : Set[String]
  /// The tasks started that go on after their call (a clone, a link followed): awaited by `settled`. Only those still
  /// running are kept (`track_going`).
  going : Array[@effect.Fiber[Unit]]
  /// The paths being followed in the background (`followed_now`): one fiber a path at once.
  priv following : Set[String]
  /// Upper bound on workspace size eligible for tar.zst compression (defaults to `max_pack_workspace_bytes`).
  max_pack_workspace_bytes : Double
  /// Active `cold_pack` runs by session key: `(aborted_flag, active_workspace_dir)`.
  priv packing : Map[String, Array[(Ref[Bool], Ref[String?])]]
  /// Background `cold_restore_bg` fibers by session key.
  priv restores : Map[String, Array[@effect.Fiber[Unit]]]
}

///|
pub fn Storage::new(
  st : Station,
  fs : Files,
  max_pack_workspace_bytes? : Double = max_pack_workspace_bytes,
) -> Storage {
  {
    st,
    fs,
    reads: Ref::new(0),
    followed: {},
    rooms: {},
    rooms_at: {},
    follow_failed: {},
    sessions_real: Ref::new(None),
    clones: {},
    swept: None,
    left_alone: Set::new(),
    going: [],
    following: Set([]),
    max_pack_workspace_bytes,
    packing: {},
    restores: {},
  }
}

///|
/// A task that goes on after its call kept in `going`, those that ended let go first: `going` holds what still runs,
/// not every task an upkeep round ever started.
fn Storage::track_going(self : Storage, f : @effect.Fiber[Unit]) -> Unit {
  keep_running(self.going, f)
}

///|
fn keep_running(going : Array[@effect.Fiber[Unit]], f : @effect.Fiber[Unit]) -> Unit {
  going.retain(x => !x.is_done())
  // (`retain` leaves what it took out in the slots past the end, still held)
  going.release_unused(placeholder=f)
  going.push(f)
}

///|
async fn Storage::ask(self : Storage, name : String, args : Array[Json]) -> Json {
  self.st.ask(name, args)
}

///|
/// Runs an operation on the threads store with `now` synced and `sent`/`requested` flushed afterwards.
fn[T] Storage::with_threads(self : Storage, f : (@store_threads.Store) -> T raise) -> T raise {
  self.st.threads.set_now(self.st.hub.now())
  errdefer (self.st.flush_threads)()
  let r = f(self.st.threads)
  (self.st.flush_threads)()
  r
}

///|
/// The station's clock (`hub.now()`, `wall.now()`).
fn Storage::now(self : Storage) -> Double {
  self.st.hub.now()
}

///|
/// A line of the station's log (ops/log.ts).
async fn Storage::log(self : Storage, level : String, part : String, message : String, fields : Json) -> Unit {
  self.st.tell("log." + level, [js(part), js(message), fields])
}

///|
/// `hub.store.getSession(key)`: None where there is none.
fn Storage::session(self : Storage, key : String) -> Json? raise {
  some_of(self.st.store.get_session(key))
}

///|
fn Storage::data_dir(self : Storage) -> String {
  str(self.st.hub.config(), "dataDir").unwrap_or("")
}
