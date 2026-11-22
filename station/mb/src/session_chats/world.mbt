// What the station is to these parts (src/sessions' `hub`, its store, its chats' surfaces, the actors, and the other
// parts of the station these call: the hub's tools' arguments, the readers, the files, the other stations): direct
// handles to the stores, hub, database, and conversation state (`Live`), plus `call` for cross-slice hooks and the
// `adb_devices` card adapter (which constructs `World` with `live: None`). A function given as an argument (a check
// run inside a write, a listener) is a callback the station may call back while it is asked (`World::callback`).

///|
/// The mutable per-station conversation state owned by `session_chats` (held posts, relayed chat openings,
/// in-flight title regeneration requests).
pub struct ChatState {
  held : Map[String, Map[String, J]]
  openings : Map[String, J]
  titles : Map[String, J]
  mut held_count : Int32
}

///|
pub fn ChatState::new() -> ChatState {
  { held: Map([]), openings: Map([]), titles: Map([]), held_count: 0 }
}

///|
/// Records an opening message for a relayed chat thread (`storage_call` `hub.setOpening`).
pub fn ChatState::set_opening(self : ChatState, thread_key : String, val : J) -> Unit {
  self.openings[thread_key] = val
}

///|
/// Direct handles to the station's stores, hub, SQLite database, and conversation state,
/// bypassing the string-RPC bridge in `station_main`.
pub(all) struct Live {
  store : @store_sessions.Store
  threads : @store_threads.Store
  hub : @session_hub.Hub
  db : @sql.Db
  state : ChatState
  flush_threads : () -> Unit
}

///|
pub(all) struct World {
  /// Asks the station `name` with `args`; what it threw raises `Thrown(kind, message)`.
  call : async (String, Array[J]) -> J
  /// A callback the station may call back with its arguments while asked: what stands for it in an argument.
  callback : (async (Array[J]) -> J) -> J
  /// The station's words, and its own language (`stationLang`).
  words : Words
  lang : Ref[String]
  /// What the last error the station threw carried besides its words (its own fields: a `CcSessionsUnavailable`'s
  /// `sessions`...).
  thrown : Ref[J]
  /// Direct handles to stores, hub, db, and conversation state (`None` for the `adb_devices` adapter / harnesses).
  live : Live?
}

///|
/// Whether an answer is `undefined` (said `{"$u": 1}` or `{"$undefined": true}`).
pub fn is_undefined(v : J) -> Bool {
  match v {
    Obj([(k, Num(_))]) => @jsjson.sanitize_str(k) == "$u"
    Obj([(k, Bool(true))]) => @jsjson.sanitize_str(k) == "$undefined"
    _ => false
  }
}

///|
fn is_json_undefined(j : Json) -> Bool {
  match j {
    Object(m) if m.length() == 1 && (m.contains("$undefined") || m.contains("$u")) => true
    _ => false
  }
}

///|
fn of_json_j(j : Json) -> J {
  if is_json_undefined(j) {
    Null
  } else {
    @jsjson.JValue::of_json(j)
  }
}

///|
fn of_json_opt(j : Json) -> J? {
  if is_json_undefined(j) {
    None
  } else {
    Some(@jsjson.JValue::of_json(j))
  }
}

///|
fn World::map_live_error(self : World, e : Error) -> Error {
  self.thrown.val = Null
  match e {
    Thrown(code, _) => {
      if code != "" {
        self.thrown.val = jo([("code", js(code))])
      }
      e
    }
    _ if @sql.busy(e) => {
      self.thrown.val = jo([("errcode", jn(5.0))])
      Thrown("SqliteError", e.to_string())
    }
    @drive.FsError(f) => {
      self.thrown.val = jo([("code", js(f.code))])
      Thrown(f.code, f.message)
    }
    @store_threads.MessageWriteBusy => Thrown("MessageWriteBusy", "message write is busy")
    @store_threads.CcSessionsUnavailable(ss) => {
      self.thrown.val = jo([("sessions", ja(ss.map(js)))])
      Thrown("CcSessionsUnavailable", "cc sessions unavailable")
    }
    @store_threads.DecisionSessionsUnavailable =>
      Thrown("DecisionSessionsUnavailable", "decision sessions unavailable")
    @store_threads.SessionChatUnavailable => Thrown("SessionChatUnavailable", "session chat unavailable")
    @session_hub.Refused(m) => Thrown("Refused", m)
    @session_storage.Thrown(kind, said) => {
      let msg = match said {
        { "message": String(m), .. } => m
        _ => said.stringify()
      }
      Thrown(kind, msg)
    }
    other => Thrown("", other.to_string())
  }
}

///|
fn[T] World::wrap_live(self : World, f : () -> T raise) -> T raise {
  self.thrown.val = Null
  f() catch {
    e => raise self.map_live_error(e)
  }
}

///|
async fn[T] World::wrap_live_async(self : World, f : async () -> T) -> T {
  self.thrown.val = Null
  f() catch {
    e => raise self.map_live_error(e)
  }
}

///|
fn[T] World::with_threads(self : World, live : Live, f : (@store_threads.Store) -> T raise) -> T raise {
  self.wrap_live(() => {
    live.threads.set_now(live.hub.now())
    errdefer (live.flush_threads)()
    let r = f(live.threads)
    (live.flush_threads)()
    r
  })
}

///|
fn World::require_live(self : World) -> Live raise Thrown {
  match self.live {
    Some(l) => l
    None => raise fail_("no live station handles on session_chats World")
  }
}

///|
fn[T] World::with_store(self : World, f : (@store_sessions.Store) -> T raise) -> T raise {
  let l = self.require_live()
  self.wrap_live(() => f(l.store))
}

///|
fn World::with_store_j(self : World, f : (@store_sessions.Store) -> Json raise) -> J raise {
  of_json_j(self.with_store(f))
}

///|
fn World::with_threads_j(self : World, f : (@store_threads.Store) -> Json raise) -> J raise {
  let l = self.require_live()
  of_json_j(self.with_threads(l, f))
}

///|
fn World::with_threads_opt(self : World, f : (@store_threads.Store) -> Json raise) -> J? raise {
  let l = self.require_live()
  of_json_opt(self.with_threads(l, f))
}

///|
fn[T] World::with_hub(self : World, f : (@session_hub.Hub) -> T raise) -> T raise {
  let l = self.require_live()
  self.wrap_live(() => f(l.hub))
}

///|
async fn[T] World::with_hub_async(self : World, f : async (@session_hub.Hub) -> T) -> T {
  let l = self.require_live()
  self.wrap_live_async(async fn() { f(l.hub) })
}

///|
fn World::with_db_j(self : World, f : (@sql.Db) -> Json raise) -> J raise {
  let l = self.require_live()
  of_json_j(self.wrap_live(() => f(l.db)))
}

///|
/// Resolves path segments against `cwd()`, matching Node's `path.resolve(...parts)`.
fn resolve_path(parts : Array[String]) -> String {
  let start = parts
    .rev()
    .search_by(p => p.has_prefix("/") || (p.length() > 1 && p[1:2].to_owned() == ":"))
  let from = match start {
    Some(i) => parts.length() - 1 - i
    None => -1
  }
  let base = if from < 0 {
    [@drive.cwd(), ..parts]
  } else {
    parts[from:].to_owned()
  }
  @nodepath.join(@drive.sep(), base)
}

///|
/// Whether a path is in a folder macOS protects (ops/places.ts `protects`): Documents, Desktop, Downloads, disks.
fn is_protected_place(p : String) -> Bool {
  let home = @drive.homedir()
  let sep = @drive.sep()
  ["Documents", "Desktop", "Downloads"]
  .iter()
  .any(d => p.has_prefix(@nodepath.join(sep, [home, d]))) ||
  p.has_prefix("/Volumes/")
}

///|
/// What the station answers, undefined as null (where the TypeScript does not tell them apart).
pub async fn World::ask(self : World, name : String, args : Array[J]) -> J {
  let v = (self.call)(name, args)
  if is_undefined(v) {
    Null
  } else {
    v
  }
}

///|
/// What the station answers, None where it is undefined (an index not ready yet, `...IfReady`).
pub async fn World::ask_u(self : World, name : String, args : Array[J]) -> J? {
  let v = (self.call)(name, args)
  if is_undefined(v) {
    None
  } else {
    Some(v)
  }
}

///|
/// A function the station gave (`{"$fn": id}`: the call `peersOf` gives, ...) called with `args`.
pub async fn World::call_fn(self : World, f : J, args : Array[J]) -> J {
  self.ask("fn.call", [f, ..args])
}

///|
pub fn World::tr(self : World, key : String, args? : Array[(String, String)] = []) -> String {
  self.words.tr(self.lang.val, key, args~)
}

///|
/// `hub.store.<name>(...args)`.
pub async fn World::store(self : World, name : String, args : Array[J]) -> J {
  self.ask("store." + name, args)
}

///|
pub async fn World::store_u(self : World, name : String, args : Array[J]) -> J? {
  self.ask_u("store." + name, args)
}

///|
/// Whether the hub has `name` (`hub.<name> != null`: a reader it may not have).
pub async fn World::has(self : World, name : String) -> Bool {
  self.ask("hub.has", [js(name)]) is Bool(true)
}

///|
/// Whether the store has `name` (a method a store from before lacks).
pub async fn World::store_has(self : World, name : String) -> Bool {
  match self.live {
    Some(_) => name != "pendingCardHeaderIfReady"
    None => self.ask("hub.storeHas", [js(name)]) is Bool(true)
  }
}

///|
/// `hub.<name>(...args)`.
pub async fn World::hub(self : World, name : String, args : Array[J]) -> J {
  self.ask("hub." + name, args)
}

///|
/// What another part of the station does (src/sessions/args.ts, src/sessions/others.ts, the readers...): `dep.<name>`.
pub async fn World::dep(self : World, name : String, args : Array[J]) -> J {
  self.ask("dep." + name, args)
}

///|
/// `hub.chat(connect).<method>(...args)`.
pub async fn World::chat(self : World, connect : String, method : String, args : Array[J]) -> J {
  self.ask("chat." + method, [js(connect), ..args])
}

///|
/// `hub.actors.get(key)?.<method>(...args)` (null where it has no actor).
pub async fn World::actor(self : World, key : String, method : String, args : Array[J]) -> J {
  self.ask("actor." + method, [js(key), ..args])
}

///|
/// Whether session `key` has an actor (`hub.actors.get(key) !== undefined`).
pub fn World::has_actor(self : World, key : String) -> Bool {
  match self.live {
    Some(l) => l.hub.actors.contains(key)
    None => false
  }
}

///|
/// The station's clock, in ms (`hub.now()`).
pub fn World::now(self : World) -> Double {
  match self.live {
    Some(l) => l.hub.now()
    None => @drive.wall_clock()
  }
}

///|
/// Waits `ms` of the wall's time (`wall.sleep`).
pub async fn World::sleep(_self : World, ms : Double) -> Unit {
  @effect.sleep(ms.to_int())
}

///|
/// The hub's config (`hub.config()`).
pub fn World::config(self : World) -> J {
  match self.live {
    Some(l) => of_json_j(l.hub.config())
    None => Null
  }
}

///|
/// Logged as the station logs (`log.warn`, `log.info`): its part, its words, its fields.
pub async fn World::log(self : World, level : String, part : String, words : String, fields : J) -> Unit {
  self.ask("log." + level, [js(part), js(words), fields]) |> ignore
}

// ── dual-path helpers (support `live: None` for `adb_devices/card.mbt`) ──

///|
async fn World::store_insert_message(self : World, msg : J, extra? : Array[J] = []) -> J {
  match self.live {
    Some(l) => of_json_j(self.with_threads(l, t => t.insert_message(msg)))
    None => self.store("insertMessage", [msg, ..extra])
  }
}

///|
async fn World::store_pending_card_header(self : World, tid : J) -> J {
  match self.live {
    Some(l) => of_json_j(self.with_threads(l, t => t.pending_card_header(tid.to_json())))
    None => self.store("pendingCardHeader", [tid])
  }
}

///|
async fn World::store_pending_card_header_if_ready(self : World, tid : J) -> J? {
  match self.live {
    Some(l) => of_json_opt(self.with_threads(l, t => t.pending_card_header_if_ready(tid.to_json())))
    None => self.store_u("pendingCardHeaderIfReady", [tid])
  }
}

///|
async fn World::store_session_thread_by_id(self : World, key : String, tid : J) -> J {
  match self.live {
    Some(l) => of_json_j(self.with_threads(l, t => t.session_thread_by_id(Json::string(key), tid.to_json())))
    None => self.store("sessionThreadById", [js(key), tid])
  }
}

///|
async fn World::hub_shared(self : World, tid : J, n : J, key : String, text : String) -> Unit {
  match self.live {
    Some(l) => self.wrap_live(() => l.hub.shared(tid.to_json(), n.to_json(), key, text))
    None => self.hub("shared", [tid, n, js(key), js(text)]) |> ignore
  }
}

// ── high-frequency direct helpers ──

///|
fn World::store_get_session(self : World, key : String) -> J raise {
  self.with_store_j(s => s.get_session(key))
}

///|
fn World::store_manually_archived(self : World, tid : J) -> Bool raise {
  self.with_store(s => s.manually_archived(tid.to_json()))
}

///|
fn World::store_thread_sessions(self : World, tid : J) -> J raise {
  self.with_threads_j(t => t.thread_sessions(tid.to_json()))
}

///|
fn World::hub_link(self : World, key : String) -> String? raise {
  (self.require_live().hub.world.link)(key)
}

///|
fn World::db_exec(self : World, sql : String) -> Unit raise {
  let l = self.require_live()
  self.wrap_live(() => l.db.exec(sql))
}

///|
fn World::db_first(self : World, sql : String, params : Array[Json]) -> J? raise {
  let l = self.require_live()
  self.wrap_live(() => l.db.first(sql, params)).map(row => of_json_j(Json::object(row)))
}

///|
fn World::db_all(self : World, sql : String, params : Array[Json]) -> Array[J] raise {
  let l = self.require_live()
  self.wrap_live(() => l.db.all(sql, params)).map(row => of_json_j(Json::object(row)))
}
