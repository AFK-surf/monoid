// How a workspace's members' devices reach its stations, kept by its stations (station/src/mesh/ways.ts; the root
// AGENTS.md, The cloud is the account system; the user, 2026-11-11: an agent adds a relay itself): the relays it has of
// its own beside still.fail's, and the ways its devices do not take (`off`: a relay's URL, `lan`, `tailnet`, `direct`,
// `ours` for all of still.fail's).
//
// One record a workspace, whole, the newest kept: a change made here is `at` this station's clock (after the record it
// changes), by this station; between two of the same time the larger station id. A station that holds none yet goes by
// what still.fail cloud kept before (`ways_said`). The workspace's stations keep each other level (`ways.get`,
// `ways.put`: follow_ways), devices read it and are told it changed (tell_ways). Nobody approves a relay: it carries
// only the mesh's packets, end to end encrypted; who added each is kept (`by`) and shown.

///|
/// How long a station waits before it tries a peer again that it could not bring level, at first; each failure after
/// doubles it, up to `retry_most_ms`.
pub let retry_ms : Int = 5_000

///|
pub let retry_most_ms : Int = 600_000

///|
/// At most this many relays of a workspace's own.
pub let max_own_relays : Int = 4

///|
/// The ways to a station that are no single relay, which a workspace may turn off as it may a relay.
pub let way_kinds : Array[String] = ["lan", "tailnet", "direct", "ours"]

///|
/// A relay of the workspace's own: its URL, and who added it where that is known.
pub(all) struct OwnRelay {
  url : String
  by : String?
}

///|
pub fn OwnRelay::to_json(self : OwnRelay) -> Json {
  match self.by {
    Some(b) => { "url": Json::string(self.url), "by": Json::string(b) }
    None => { "url": Json::string(self.url) }
  }
}

///|
/// What a workspace's stations keep of its ways (also what a device or a peer is told, `at` 0 and no station where it
/// is as still.fail cloud kept it).
pub(all) struct WaysRecord {
  relays : Array[OwnRelay]
  off : Array[String]
  at : Int64
  station : String
}

///|
pub fn WaysRecord::to_json(self : WaysRecord) -> Json {
  {
    "relays": Json::array(self.relays.map(r => r.to_json())),
    "off": Json::array(self.off.map(Json::string)),
    "at": int_json(self.at),
    "station": Json::string(self.station),
  }
}

///|
fn WaysRecord::word(self : WaysRecord) -> String {
  "\{self.at}:\{self.station}"
}

///|
/// A relay's URL as compared: its normal form without a trailing slash.
pub fn same_url(url : String) -> String {
  strip_slashes(match parse_url(url) {
    Some(u) => u.href()
    None => url
  })
}

///|
fn same(a : String, b : String) -> Bool {
  same_url(a) == same_url(b)
}

///|
fn among(urls : Array[String], url : String) -> Bool {
  let s = same_url(url)
  urls.iter().any(u => same_url(u) == s)
}

///|
fn clean_http_url(s : String, insecure : Bool) -> Url? {
  guard parse_url(s) is Some(u) else { return None }
  if !(u.scheme == "https" || (insecure && u.scheme == "http")) ||
    u.username != "" ||
    u.password != "" ||
    u.search() != "" ||
    u.hash() != "" {
    return None
  }
  Some(u)
}

///|
/// A relay's URL as one is kept: https (http too where `insecure`, a local setup), no account, query or fragment, no
/// trailing slash; None when it is none.
pub fn relay_url(raw : Json, insecure? : Bool = false) -> String? {
  guard raw is String(s) else { return None }
  clean_http_url(js_trim(s), insecure).map(u => strip_slashes(u.href()))
}

///|
fn strip_slashes(h : String) -> String {
  let mut end = h.length()
  while end > 0 && h.code_unit_at(end - 1) == '/'.to_int().to_uint16() {
    end -= 1
  }
  h.unsafe_substring(start=0, end~)
}

///|
fn newer(a : WaysRecord, b : WaysRecord) -> Bool {
  a.at > b.at || (a.at == b.at && a.station > b.station)
}

///|
/// A record as a file or a peer says it; None when it is none.
pub fn record_of(raw : Json?) -> WaysRecord? {
  guard raw is Some(Object(m)) else { return None }
  guard m.get("relays") is Some(Array(rs)) else { return None }
  guard safe_int(m.get("at")) is Some(at) && at >= 0L else { return None }
  guard m.get("station") is Some(String(station)) else { return None }
  let relays : Array[OwnRelay] = []
  for r in rs {
    let given = match r {
      String(_) => r
      _ => field(r, "url").unwrap_or(Json::null())
    }
    guard relay_url(given, insecure=true) is Some(url) else { continue }
    if relays.iter().any(k => same(k.url, url)) {
      continue
    }
    let by = match field(r, "by") {
      Some(String(b)) if b != "" => Some(js_slice(b, 200))
      _ => None
    }
    relays.push({ url, by })
  }
  let off : Array[String] = []
  for w in strings_of(m.get("off")) {
    if !off.contains(w) {
      off.push(w)
    }
  }
  let kept = if relays.length() > max_own_relays {
    relays[:max_own_relays].to_owned()
  } else {
    relays
  }
  Some({ relays: kept, off, at, station })
}

///|
/// Where what a station keeps is written and read back as it starts (the mesh's `ways.json`, `station-marks.json`).
pub(all) struct Kept {
  read : () -> String?
  /// One write after another, the last one last.
  write : (String) -> Unit
}

///|
/// A file in memory (tests, the harness).
pub fn Kept::memory(text? : String) -> (Kept, Ref[String?]) {
  let r : Ref[String?] = Ref(text)
  ({ read: () => r.val, write: t => r.val = Some(t) }, r)
}

///|
pub struct Ways {
  cloud : CloudView
  priv store : Kept
  priv now : () -> Int64
  priv kept : Map[String, WaysRecord]
  priv told : Told[String]
}

///|
fn[T] load_kept(store : Kept, decode : (String, Json) -> T?) -> Map[String, T] {
  let kept : Map[String, T] = Map([])
  match (store.read)() {
    Some(text) =>
      match (try Some(@json.parse(text)) catch { _ => None }) {
        Some(Object(m)) =>
          for k, raw in m {
            if decode(k, raw) is Some(r) {
              kept[k] = r
            }
          }
        _ => ()
      }
    None => ()
  }
  kept
}

///|
fn[T] save_kept(store : Kept, kept : Map[String, T], encode : (T) -> Json) -> Unit {
  let m : Map[String, Json] = Map([])
  for k, r in kept {
    m[k] = encode(r)
  }
  (store.write)(Json::object(m).stringify(indent=2))
}

///|
fn next_at(now : () -> Int64, prev : Int64) -> Int64 {
  let n = now()
  if n > prev + 1L { n } else { prev + 1L }
}

///|
/// The ways this station keeps, read from `store`; `now` is the wall's clock (ms) a change is made at.
pub fn Ways::new(cloud : CloudView, store : Kept, now : () -> Int64) -> Ways {
  { cloud, store, now, kept: load_kept(store, (_, raw) => record_of(Some(raw))), told: Told::new() }
}

///|
/// What this station keeps of `ws`'s ways: None where it keeps none (it goes by the cloud's then, `view`).
pub fn Ways::record(self : Ways, ws : String) -> WaysRecord? {
  self.kept.get(ws)
}

///|
/// `ws`'s ways as this station goes by them: its record, else as still.fail cloud kept them, else none.
pub fn Ways::view(self : Ways, ws : String) -> WaysRecord {
  match self.kept.get(ws) {
    Some(r) => r
    None => {
      let said = (self.cloud.ways_said)(ws)
      let relays = match said {
        Some(s) =>
          s.relays.filter_map(u => match relay_url(Json::string(u), insecure=true) {
            Some(url) => Some({ url, by: None })
            None => None
          })
        None => []
      }
      {
        relays,
        off: match said {
          Some(s) => s.off
          None => []
        },
        at: 0L,
        station: "",
      }
    }
  }
}

///|
/// Every relay of the workspaces this station is in, of their own.
pub fn Ways::relays(self : Ways) -> Array[String] {
  let out = []
  for m in (self.cloud.memberships)() {
    for r in self.view(m.workspace).relays {
      if !among(out, r.url) {
        out.push(r.url)
      }
    }
  }
  out
}

///|
/// A peer's record, kept when it is newer than this station's; whether it was.
pub fn Ways::take(self : Ways, ws : String, record : WaysRecord) -> Bool {
  match self.kept.get(ws) {
    Some(mine) if !newer(record, mine) => false
    _ => {
      self.keep(ws, record)
      true
    }
  }
}

///|
/// A change made here: the record as it was, changed by `change`, made the newest.
pub fn Ways::change(
  self : Ways,
  ws : String,
  change : (Array[OwnRelay], Array[String]) -> (Array[OwnRelay], Array[String]) raise WaysRefusal,
) -> WaysRecord raise WaysRefusal {
  let was = self.view(ws)
  let (relays, off) = change(was.relays, was.off)
  let station = (self.cloud.station)().unwrap_or("")
  let at = next_at(self.now, was.at)
  let record = { relays, off, at, station }
  self.keep(ws, record)
  record
}

///|
fn Ways::keep(self : Ways, ws : String, record : WaysRecord) -> Unit {
  self.kept[ws] = record
  save_kept(self.store, self.kept, r => r.to_json())
  self.told.tell(ws)
}

///|
/// Told each time a workspace's ways change here (its id); returns what stops it.
pub fn Ways::listen(self : Ways, f : (String) -> Unit) -> () -> Unit {
  self.told.add(f)
}

// ── changes asked of it ──

///|
/// Why a change of the ways is refused: what was wrong, said to the one who asked.
pub(all) suberror WaysRefusal {
  WaysRefusal(String)
}

///|
pub impl Show for WaysRefusal with output(self, logger) {
  match self {
    WaysRefusal(m) => logger.write_string(m)
  }
}

///|
/// Whether still.fail's cloud is on http (a local setup), where a relay on http is taken too.
fn insecure_cloud(cloud : CloudView) -> Bool {
  (cloud.origin)().unwrap_or("").has_prefix("http:")
}

///|
/// still.fail's own relays: every workspace has these. As the control plane says them apart, else what its relays say
/// but the workspaces' own it puts after them.
pub fn still_fails(cloud : CloudView) -> Array[String] {
  match (cloud.stillfail_relays)() {
    Some(said) if said.length() > 0 => said.filter(can_parse)
    _ => {
      let theirs = []
      for m in (cloud.memberships)() {
        match (cloud.ways_said)(m.workspace) {
          Some(s) => theirs.append(s.relays)
          None => ()
        }
      }
      (cloud.relays)().filter(u => !among(theirs, u))
    }
  }
}

///|
fn relays_of(ways : Ways, ws : String) -> (Array[String], Array[String]) {
  let ours = still_fails(ways.cloud)
  let v = ways.view(ws)
  let all = ours.copy()
  for r in v.relays {
    if !among(ours, r.url) {
      all.push(r.url)
    }
  }
  let off = (u : String) => among(v.off, u) ||
    (v.off.contains("ours") && among(ours, u))
  (all, all.filter(u => !off(u)))
}

///|
/// The relays `ws`'s stations and devices go through: still.fail's, then its own, but those its ways turn off. Never
/// none: a record that would leave none is taken as turning none off.
pub fn workspace_relays(ways : Ways, ws : String) -> Array[String] {
  let (all, on) = relays_of(ways, ws)
  if on.length() > 0 {
    on
  } else {
    all
  }
}

///|
/// The relays `ws`'s ways turn off (none where they would turn off all).
pub fn off_relays(ways : Ways, ws : String) -> Array[String] {
  let (all, on) = relays_of(ways, ws)
  if on.length() > 0 {
    all.filter(u => !on.contains(u))
  } else {
    []
  }
}

///|
let not_a_relay : String = "not a relay's URL: https://host[:port][/path], with no account, query or fragment"

///|
/// `raw` added to `ws`'s own relays, by `by`. One already there stays as it is.
pub fn add_relay(
  ways : Ways,
  ws : String,
  raw : String,
  by : String?,
) -> WaysRecord raise WaysRefusal {
  let url = match relay_url(Json::string(raw), insecure=insecure_cloud(ways.cloud)) {
    Some(u) => u
    None => raise WaysRefusal(not_a_relay)
  }
  if among(still_fails(ways.cloud), url) {
    raise WaysRefusal(
      "that is one of still.fail's own relays, which every workspace has already",
    )
  }
  ways.change(ws, (relays, off) => {
    if relays.iter().any(r => same(r.url, url)) {
      return (relays, off)
    }
    if relays.length() >= max_own_relays {
      raise WaysRefusal(
        "a workspace has at most \{max_own_relays} relays of its own: remove one first",
      )
    }
    let by = match by {
      Some(b) if b != "" => Some(b)
      _ => None
    }
    ([..relays, { url, by }], off)
  })
}

///|
/// When removing custom relays would leave every relay off, still.fail's come back on.
fn keep_relay_on(
  ours : Array[String],
  relays : Array[OwnRelay],
  off : Array[String],
) -> Array[String] {
  if ours.length() == 0 {
    return off
  }
  let all = [..ours, ..relays.map(r => r.url)]
  let is_off = (u : String) => among(off, u) ||
    (off.contains("ours") && among(ours, u))
  if all.iter().all(is_off) {
    off.filter(w => w != "ours" && !among(ours, w))
  } else {
    off
  }
}

///|
/// `raw` taken out of `ws`'s own relays, and out of the ways turned off.
pub fn remove_relay(
  ways : Ways,
  ws : String,
  raw : String,
) -> WaysRecord raise WaysRefusal {
  let url = relay_url(Json::string(raw), insecure=true).unwrap_or(raw)
  if !ways.view(ws).relays.iter().any(r => same(r.url, url)) {
    raise WaysRefusal("not one of this workspace's own relays")
  }
  let ours = still_fails(ways.cloud)
  ways.change(ws, (relays, off) => {
    let relays = relays.filter(r => !same(r.url, url))
    let off = keep_relay_on(ours, relays, off.filter(w => !same(w, url)))
    (relays, off)
  })
}

///|
/// The whole list of `ws`'s own relays set at once: who added those already there kept, the new ones `by`; those gone
/// taken out of the ways turned off.
pub fn set_relays(
  ways : Ways,
  ws : String,
  raws : Array[Json],
  by : String?,
) -> WaysRecord raise WaysRefusal {
  let urls : Array[String] = []
  let ours = still_fails(ways.cloud)
  for raw in raws {
    let url = match relay_url(raw, insecure=insecure_cloud(ways.cloud)) {
      Some(u) => u
      None => raise WaysRefusal(not_a_relay)
    }
    if !among(ours, url) && !among(urls, url) {
      urls.push(url)
    }
  }
  if urls.length() > max_own_relays {
    raise WaysRefusal("a workspace has at most \{max_own_relays} relays of its own")
  }
  let by = match by {
    Some(b) if b != "" => Some(b)
    _ => None
  }
  ways.change(ws, (now, off) => {
    let relays = urls.map(url => match now.search_by(r => same(r.url, url)) {
      Some(i) => now[i]
      None => { url, by }
    })
    let off = keep_relay_on(
      ours,
      relays,
      off.filter(w => mesh_way(w) || !can_parse(w) || among(urls, w) || among(ours, w)),
    )
    (relays, off)
  })
}

///|
/// One way turned on or off for `ws`'s devices: a relay (still.fail's or its own) or a kind of way. A relay stays on.
pub fn set_way(
  ways : Ways,
  ws : String,
  way : String,
  on : Bool,
) -> WaysRecord raise WaysRefusal {
  let ours = still_fails(ways.cloud)
  let own = ways.view(ws).relays.map(r => r.url)
  let relays = [..ours, ..own]
  let is_kind = way_kinds.contains(way)
  let is_mesh = mesh_way(way) && (ways.cloud.mesh_relays)().iter().any(r =>
    text_of(field(r, "node")) is Some(node) && "mesh:" + node == way)
  let relay = if is_kind {
    None
  } else {
    match relays.search_by(u => same(u, way)) {
      Some(i) => Some(relays[i])
      None => None
    }
  }
  if !is_kind && !is_mesh && relay is None {
    raise WaysRefusal(
      "no such way: a registered relay, or ours, lan, tailnet, direct",
    )
  }
  let id = relay.unwrap_or(way)
  ways.change(ws, (now_relays, now_off) => {
    let legacy = (w : String) => w == "lan" ||
      w == "tailnet" ||
      w == "direct" ||
      among(ours, w)
    let off = now_off.filter(w => if id == "ours" {
      w != "ours" && !(on && legacy(w)) && !among(ours, w)
    } else if is_kind {
      w != id
    } else {
      !same(w, id)
    })
    if !on {
      off.push(id)
    }
    let is_off = (u : String) => among(off, u) ||
      (off.contains("ours") && among(ours, u))
    if relays.iter().all(is_off) {
      raise WaysRefusal(
        "the last relay stays on: the web app and a device new to the workspace reach its stations by relays alone",
      )
    }
    (now_relays, off)
  })
}

// ── between the workspace's stations ──

///|
/// A peer's `ways.*` request, in the workspace it was asked in (the transport checked the peer is of it).
pub fn answer_ways(ways : Ways, request : Json, ws : String) -> Json raise NetError {
  match text_of(field(request, "method")) {
    Some("ways.get") =>
      {
        "record": match ways.record(ws) {
          Some(r) => r.to_json()
          None => Json::null()
        },
      }
    Some("ways.put") =>
      match record_of(field(request, "record")) {
        Some(record) => { "taken": Json::boolean(ways.take(ws, record)) }
        None => raise NetError("a malformed ways record")
      }
    _ => raise NetError("unknown ways method")
  }
}

///|
/// A call to another station (bus.ts `PeerCall`): the peer, the workspace it is asked in (None: the home one), the
/// request; `done` told its answer or the error's words. Answered later or at once.
pub(all) struct PeerCall {
  call : (String, String?, Json, (Result[Json, String]) -> Unit) -> Unit
}

///|
/// A timer that can be called off (tests: theirs; the station's: the runtime's clock).
pub(all) struct After {
  after : (Int, () -> Unit) -> () -> Unit
}

///|
/// A timer on the effect runtime that runs the program (what calls it off interrupts its fiber).
pub fn After::effect(rt : @effect.Runtime) -> After {
  {
    after: (ms, f) => {
      let fiber = rt.fork(async fn() {
        @effect.sleep(ms)
        f()
      })
      fn() { fiber.interrupt() }
    },
  }
}

///|
/// Brings one peer and this station level in `ws`: the newer record of the two kept by both.
fn level_ways(
  ways : Ways,
  call : PeerCall,
  peer : String,
  ws : String,
  home : Bool,
  done : (Result[Unit, String]) -> Unit,
) -> Unit {
  let asked = if home { None } else { Some(ws) }
  (call.call)(peer, asked, { "method": "ways.get" }, got => match got {
    Err(e) => done(Err(e))
    Ok(got) => {
      let theirs = record_of(field(got, "record"))
      let mine = ways.record(ws)
      match (theirs, mine) {
        (Some(t), None) => {
          ignore(ways.take(ws, t))
          done(Ok(()))
        }
        (Some(t), Some(m)) if newer(t, m) => {
          ignore(ways.take(ws, t))
          done(Ok(()))
        }
        (_, Some(m)) if theirs is None || newer(m, theirs.unwrap()) =>
          (call.call)(
            peer,
            asked,
            { "method": "ways.put", "record": m.to_json() },
            put => match put {
              Err(e) => done(Err(e))
              Ok(_) => done(Ok(()))
            },
          )
        _ => done(Ok(()))
      }
    }
  })
}

///|
/// A station from before (what it answered says it has no such method): nothing to bring level with it.
fn from_before(e : String, kind : String) -> Bool {
  let l = e.to_lower()
  l.contains("unknown method") ||
  l.contains("unknown " + kind + " method") ||
  l.contains("no such method") ||
  l.contains("not found")
}

///|
/// A peer's retries: how long it waits, whether that wait is over, what calls it off.
priv struct Retry {
  wait : Int
  mut due : Bool
  mut cancel : () -> Unit
}

///|
fn follow_peers(
  cloud : CloudView,
  timers : After,
  kind : String,
  skip_rig : Bool,
  include_rigs : Bool,
  word : (String) -> String,
  level : (String, String, Bool, (Result[Unit, String]) -> Unit) -> Unit,
  listen : (() -> Unit) -> () -> Unit,
  log : (String) -> Unit,
) -> () -> Unit {
  let level_at : Map[String, String] = Map([])
  let going : Map[String, Bool] = Map([])
  let retries : Map[String, Retry] = Map([])
  let stopped = Ref(false)
  letrec bring = fn(peer : String, ws : String, home : Bool) -> Unit {
    let key = "\{ws}|\{peer}"
    let at = word(ws)
    let retry = retries.get(key)
    if level_at.get(key) == Some(at) ||
      going.contains(key) ||
      (retry is Some(r) && !r.due) {
      return
    }
    going[key] = true
    level(peer, ws, home, r => {
      match r {
        Ok(_) => {
          level_at[key] = word(ws)
          retries.remove(key)
        }
        Err(e) =>
          if from_before(e, kind) {
            level_at[key] = at
            retries.remove(key)
          } else {
            log(
              "a station's \{kind} were not brought level: peer=\{js_slice(peer, 12)} workspace=\{ws} error=\{e}",
            )
            if !stopped.val {
              let wait = match retry {
                None => retry_ms
                Some(r) =>
                  if r.wait * 2 < retry_most_ms {
                    r.wait * 2
                  } else {
                    retry_most_ms
                  }
              }
              let next = { wait, due: false, cancel: fn() {  } }
              // timer: a retry after a failure, with a backoff
              next.cancel = (timers.after)(wait, fn() {
                next.due = true
                look()
              })
              retries[key] = next
            }
          }
      }
      going.remove(key)
      if !stopped.val {
        look()
      }
    })
  }
  and look = fn() -> Unit {
    guard (cloud.station)() is Some(me) else { return }
    if stopped.val || !(cloud.peers_current)() {
      return
    }
    for m in (cloud.memberships)() {
      if skip_rig && (cloud.rig_in)(m.workspace) {
        continue
      }
      for p in m.peers {
        match peer_id(p) {
          Some(id) if id != me => bring(id, m.workspace, m.home)
          _ => ()
        }
      }
      if include_rigs {
        // Its rigs too: kept on the relays the workspace keeps on, they answer `ways.*` as a station does.
        for r in (cloud.rigs)(m.workspace) {
          if r != me && !m.peers.iter().any(p => peer_id(p) == Some(r)) {
            bring(r, m.workspace, m.home)
          }
        }
      }
    }
  }
  look()
  let unlisten_cloud = (cloud.listen)(look)
  let unlisten_store = listen(look)
  fn() {
    stopped.val = true
    unlisten_cloud()
    unlisten_store()
    for _, r in retries {
      (r.cancel)()
    }
    retries.clear()
  }
}

///|
/// Whenever a workspace's ways change here, or a roster comes, each of its stations is brought level with this one; one
/// that could not be is tried again, sooner at first, until it is. What it returns stops it.
pub fn follow_ways(
  ways : Ways,
  call : PeerCall,
  timers : After,
  log? : (String) -> Unit = _ => (),
) -> () -> Unit {
  follow_peers(
    ways.cloud,
    timers,
    "ways",
    false,
    true,
    ws => match ways.record(ws) {
      Some(r) => r.word()
      None => ""
    },
    (peer, ws, home, done) => level_ways(ways, call, peer, ws, home, done),
    f => ways.listen(_ => f()),
    log,
  )
}

// ── to the members' devices ──

///|
/// Tells devices of a change (`event`, its data, what it is of, and to whom).
pub(all) struct Tell {
  tell : (String, Json, String, String) -> Unit
}

///|
/// Tells each change of a workspace's ways to its members' devices (`ways`, `{workspace}`): they read `GET /ways` again.
/// Where this station keeps none yet, the ways as still.fail cloud keeps them, changed there.
pub fn tell_ways(ways : Ways, tell : Tell) -> () -> Unit {
  let told = (ws : String) => (tell.tell)(
    "ways",
    { "workspace": Json::string(ws) },
    "ways\u{0}\{ws}",
    ws,
  )
  let said : Map[String, String] = Map([])
  let look = () => for m in (ways.cloud.memberships)() {
    let now = match (ways.cloud.ways_said)(m.workspace) {
      Some(s) => s.to_json().stringify()
      None => "null"
    }
    let was = said.get(m.workspace)
    said[m.workspace] = now
    if was is Some(w) && w != now && ways.record(m.workspace) is None {
      told(m.workspace)
    }
  }
  look()
  let unlisten_cloud = (ways.cloud.listen)(look)
  let unlisten_ways = ways.listen(told)
  fn() {
    unlisten_cloud()
    unlisten_ways()
  }
}
