// The workspace's rigs as a part of the station (rigs/module.ts; a station that only runs tasks, 2026-11-10):
// machines that only run what stations send them, each its person's (cloud/state.ts `Rig`; the rig's own side is
// rig.mbt). This station sends them tasks as it sends another station's (jobs/remote.ts, by the rig's name), asks their
// person for a chat's grant (requests.mbt, `station_use`), carries what that person signs to the rig (grants, settings,
// a grant taken back, the rig taken into a workspace in security mode: adds.mbt), and shows how each rig is to the
// agents (`station_list`) and the app.
//
// How a rig is, is the rig's own word: it tells every station as it comes on the mesh and as it changes (`rig.hello`,
// `rig.changed`); this station asks once as it starts or first hears of a rig (`rig.describe`), never on a timer. What
// could not be brought to a rig that was away waits here (`rig_outbox`, a granted request not delivered) until the rig
// is next heard.
//
// Where the TypeScript's RigsLive registers itself (the bus's handlers, the tools, `station_list`'s rigs, the devices'
// source, the routes), this one is given to them by its caller: each is a method here.

///|
let outbox_schema : String = "CREATE TABLE IF NOT EXISTS rig_outbox (\n  n INTEGER PRIMARY KEY AUTOINCREMENT,\n  ws TEXT NOT NULL,\n  rig TEXT NOT NULL,\n  kind TEXT NOT NULL,\n  body TEXT NOT NULL\n);\nCREATE INDEX IF NOT EXISTS rig_outbox_by_rig ON rig_outbox (ws, rig, n);"

///|
/// A rig asked how it is answers within this, or is shown as not reached (as station_list's stations: jobs/remote.ts).
let ask_ms : Double = 5000.0

///|
/// How a rig said a grant ended, in the chat's words.
fn ended_words(why : String) -> String? {
  match why {
    "expired" => Some("授权已到期")
    "idle" => Some("闲置超时")
    "revoked" => Some("所有者已收回")
    "released" => Some("agent 已交还")
    "closed" => Some("所有者已关闭免批准")
    _ => None
  }
}

///|
/// What a rig says of itself (rig.mbt `described`): who may use it; None where it answered as no rig.
fn described_of(answer : Json?) -> Json? {
  let r = get(answer, "rig")
  match r {
    Some(Object(_) | Array(_)) if str_at(r, "owner") is Some(_) && arr_at(r, "grants") is Some(_) => r
    _ => None
  }
}

///|
/// A rig as this station last heard it (`rig`: None, it answered as no rig), and whether it was reached then.
priv struct Heard {
  rig : Json?
  at : Double
  reached : Bool
}

///|
/// Who asks a route (api/request.ts `Request`'s `viewer`).
pub(all) struct Viewer {
  workspace : String
  sub : String
  role : String
  email : String?
  name : String?
}

///|
pub(all) struct RigsDeps {
  cloud : @cloud_lock.Cloud
  db : @sql.Db
  /// The hub, its store and cards (as requests.mbt asks them), the events devices are told (`events.tell`), the tasks'
  /// transport (`remote.ask`: a refusal raised `Refused`), the devices' forwards (`forwards.closeDevice`,
  /// `sources.forward`) and a chat's title (`dep.grantChatTitle`).
  world : World
  card_outcomes : Bool
  crypto : @cloud_lock.Crypto
  /// The machine's own time (ms), and `what` failed with `why` where it is not done within `ms` (fibers.ts `wall`).
  now : () -> Double
  within : async (Double, async () -> Json, String) -> Json
  spawn : (async () -> Unit) -> Unit
  /// A request's id (`r_<now>` and some random letters, where the station makes them).
  id : () -> String
}

///|
pub struct Rigs {
  priv d : RigsDeps
  adds : RigAdds
  requests : RigRequests
  priv heard : Map[String, Heard]
  priv asked : Array[String]
  priv flushing : Map[String, @effect.Deferred[Bool]]
}

///|
fn rig_key(ws : String, rig : String) -> String {
  "\{ws}\u0000\{rig}"
}

///|
/// The id a station or a rig is listed by, its name where it has one (mesh/peer-http.ts `nameOf`).
pub fn name_of(cloud : @cloud_lock.Cloud, id : String) -> String {
  for m in cloud.memberships() {
    for p in arr_at(Some(m), "peers").unwrap_or([]) {
      if str_at(Some(p), "id") == Some(id) {
        return match get(Some(p), "name") {
          Some(String(n)) if n != "" => n
          _ => id
        }
      }
    }
  }
  id
}

///|
/// mesh/credential.ts `managesStation`.
pub fn manages_station(viewer : Viewer) -> Bool {
  viewer.role == "owner" || viewer.role == "admin"
}

///|
pub fn Rigs::new(d : RigsDeps) -> Rigs raise {
  d.db.exec(outbox_schema)
  let secs = () => ((d.now)() / 1000.0).floor()
  // Security mode: a rig is the workspace's once its person signed for it (adds.mbt).
  let adds = RigAdds::new(d.db, d.cloud, genesis => d.cloud.person_chains().kept(genesis), secs, d.crypto)
  d.cloud.set_rig_vouched((ws, rig) => adds.holds(ws, rig))
  let cell : Ref[Rigs?] = Ref(None)
  let requests = RigRequests::new({
    db: d.db,
    world: d.world,
    card_outcomes: d.card_outcomes,
    home: () => d.cloud.home(),
    self_: () => self_id(d.cloud),
    title: async fn(session, chat) {
      match d.world.ask("dep.grantChatTitle", [jobj([("session", jstr(session)), ("chat", jstr(chat))])]) {
        Some(String(t)) => Some(t)
        _ => None
      }
    },
    bring: async fn(r) {
      let got = d.world.ask("remote.ask", [
        r.get("rig").unwrap_or(Json::null()),
        jobj([
          ("method", jstr("rig.grant")),
          ("workspace", r.get("ws").unwrap_or(Json::null())),
          ("signed", r.get("signed").unwrap_or(Json::null())),
          ("chain", r.get("chain").unwrap_or(Json::null())),
        ]),
      ])
      match get(got, "until") {
        Some(Number(n, ..)) if safe_int(n) => n
        _ => num_at(get(r.get("signed"), "body"), "exp").unwrap_or(0.0)
      }
    },
    release: (r, revoke) => if cell.val is Some(rigs) {
      let ws = rs(r, "ws")
      let rig = rs(r, "rig")
      match revoke {
        None => rigs.queue(ws, rig, "release", jobj([("request", r.get("id").unwrap_or(Json::null()))]))
        Some(rv) =>
          rigs.queue(
            ws,
            rig,
            "revoke",
            jobj([
              ("signed", get(Some(rv), "signed").unwrap_or(Json::null())),
              (
                "chain",
                match get(Some(rv), "chain") {
                  None => Json::null()
                  Some(c) => c
                },
              ),
            ]),
          )
      }
      (d.spawn)(async fn() { rigs.flush(ws, rig) |> ignore })
    },
    now: d.now,
    told: Some(async fn(r) {
      guard cell.val is Some(rigs) else { return }
      // A chat's grant of a device (or of the rig, with its devices) over: its ports here close.
      let status = rs(r, "status")
      if status == "ended" || status == "denied" {
        match r.get("device") {
          Some(dv) =>
            d.world.ask("forwards.closeDevice", [r.get("session").unwrap_or(Json::null()), dv, jstr("its grant ended")])
            |> ignore
          None => {
            let devices = match rigs.heard.get(rig_key(rs(r, "ws"), rs(r, "rig"))) {
              Some(h) => arr_at(h.rig, "devices").unwrap_or([])
              None => []
            }
            for dev in devices {
              let id = str_at(Some(dev), "id").unwrap_or("")
              if rigs.requests.of(rs(r, "session"), rs(r, "rig"), device=Some(id)).length() == 0 {
                d.world.ask("forwards.closeDevice", [
                  r.get("session").unwrap_or(Json::null()),
                  jstr(id),
                  jstr("its station's grant ended"),
                ])
                |> ignore
              }
            }
          }
        }
      }
      rigs.tell(rs(r, "ws"))
    }),
    id: d.id,
  })
  let rigs : Rigs = { d, adds, requests, heard: Map([]), asked: [], flushing: Map([]) }
  cell.val = Some(rigs)
  rigs
}

///|
/// `cloud.state?.station ?? ""`.
fn self_id(cloud : @cloud_lock.Cloud) -> String {
  match get(cloud_state(cloud), "station") {
    None | Some(Null) => ""
    v => js_string_of(v)
  }
}

///|
/// Its look at the rigs followed as the cloud changes (RigsLive's `cloud.listen(look)`): the function that lets it go.
/// (`look` is also its caller's to call as the bus is attached: `remote.bus.whenAttached(look)`.)
pub fn Rigs::listen(self : Rigs) -> () -> Unit {
  self.d.cloud.listen(_ => self.look())
}

///|
/// Let go (the station closing): no rig is vouched for by what this part kept any more.
pub fn Rigs::close(self : Rigs) -> Unit {
  self.d.cloud.set_rig_vouched((_, _) => false)
}

///|
/// What waits for a rig that was away: brought in order as it is heard, each gone once the rig took or refused it.
fn Rigs::queue(self : Rigs, ws : String, rig : String, kind : String, body : Json) -> Unit raise {
  // The settings are whole each time: only the latest are brought.
  if kind == "settings" {
    let _ = self.d.db.run("DELETE FROM rig_outbox WHERE ws = ? AND rig = ? AND kind = 'settings'", [jstr(ws), jstr(rig)])

  }
  self.d.db.run("INSERT INTO rig_outbox (ws, rig, kind, body) VALUES (?, ?, ?, ?)", [
    jstr(ws),
    jstr(rig),
    jstr(kind),
    jstr(stringify(body)),
  ])
  |> ignore
}

///|
/// Whether everything waiting for the rig got there.
pub async fn Rigs::flush(self : Rigs, ws : String, rig : String) -> Bool {
  let k = rig_key(ws, rig)
  if self.flushing.get(k) is Some(going) {
    return going.wait()
  }
  let going : @effect.Deferred[Bool] = @effect.Deferred::new()
  self.flushing[k] = going
  let through = self.flush_now(ws, rig) catch {
    e => {
      self.flushing.remove(k)
      going.fail(e) |> ignore
      raise e
    }
  }
  self.flushing.remove(k)
  going.succeed(through) |> ignore
  through
}

///|
async fn Rigs::flush_now(self : Rigs, ws : String, rig : String) -> Bool {
  while true {
    let rows = self.d.db.all("SELECT n, kind, body FROM rig_outbox WHERE ws = ? AND rig = ? ORDER BY n LIMIT 1", [
      jstr(ws),
      jstr(rig),
    ])
    guard rows.get(0) is Some(row) else { return true }
    let kind = match row.get("kind") {
      Some(String(k)) => k
      _ => ""
    }
    let body = match row.get("body") {
      Some(String(t)) => parse(t)
      _ => None
    }
    let request = spread(Some(jobj([("method", jstr("rig.\{kind}")), ("workspace", jstr(ws))])), body)
    let reached = try {
      self.d.world.ask("remote.ask", [jstr(rig), request]) |> ignore
      true
    } catch {
      // Refused: it heard, and will not take it however often it is brought.
      Refused(_) => true
      _ => false
    }
    if !reached {
      return false
    }
    self.d.db.run("DELETE FROM rig_outbox WHERE n = ?", [row.get("n").unwrap_or(Json::null())]) |> ignore
  }
  true
}

///|
fn put(out : Array[(String, Json)], k : String, v : Json?) -> Unit {
  if v is Some(x) {
    out.push((k, x))
  }
}

///|
/// A workspace's rigs as the app shows them: what the control plane names, whether each is taken here (security mode),
/// how it last said it is, and the requests of this station's chats still asked of its person.
pub async fn Rigs::listed(self : Rigs, ws : String) -> Array[Json] {
  let cloud = self.d.cloud
  let out = []
  for rig in cloud.rigs_named(ws) {
    let r = Some(rig)
    let id = str_at(r, "id").unwrap_or("")
    let at_ws = if cloud.home() == Some(ws) { None } else { Some(ws) }
    let vouched = if cloud.locked(ws=at_ws) is None { None } else { Some(self.adds.holds(ws, rig)) }
    let h = self.heard.get(rig_key(ws, id))
    let d = match h {
      Some(x) => x.rig
      None => None
    }
    let row = []
    put(row, "id", get(r, "id"))
    put(row, "name", get(r, "name"))
    put(row, "owner", get(r, "owner"))
    put(row, "owner_email", get(r, "owner_email"))
    put(row, "owner_name", get(r, "owner_name"))
    row.push(("code", jstr(@cloud_lock.short_code(id))))
    if vouched is Some(v) {
      row.push(("vouched", jbool(v)))
    }
    row.push(
      (
        "reached",
        match h {
          None => Json::null()
          Some(x) => jbool(x.reached)
        },
      ),
    )
    row.push(
      (
        "at",
        match h {
          None => Json::null()
          Some(x) => jnum(x.at)
        },
      ),
    )
    if d is Some(_) {
      put(row, "open", get(d, "open"))
      put(row, "settings", get(d, "settings"))
      put(row, "person", get(d, "person"))
      let grants = arr_at(d, "grants")
        .unwrap_or([])
        .map(g => spread(
          Some(g),
          Some(jobj([("stationName", jstr(name_of(cloud, js_string_of(get(Some(g), "station")))))])),
        ))
      row.push(("grants", jarr(grants)))
      row.push(
        (
          "devices",
          match get(d, "devices") {
            None | Some(Null) => jarr([])
            Some(v) => v
          },
        ),
      )
    }
    let requests = []
    for q in self.requests.of_rig(ws, id) {
      if rs(q, "status") == "pending" || !(q.get("delivered") is Some(True)) {
        let one = []
        put(one, "id", q.get("id"))
        one.push(("station", jstr(self_id(cloud))))
        put(one, "session", q.get("session"))
        put(one, "chat", q.get("chat"))
        put(one, "title", q.get("title"))
        put(one, "by", q.get("by"))
        put(one, "reason", q.get("reason"))
        put(one, "timeout", timeout_said(q))
        put(one, "at", q.get("at"))
        put(one, "status", q.get("status"))
        if q.get("device") is Some(dv) {
          one.push(("device", dv))
          one.push(
            (
              "deviceName",
              match q.get("deviceName") {
                None | Some(Null) => jstr("")
                Some(n) => n
              },
            ),
          )
        }
        requests.push(jobj(one))
      }
    }
    row.push(("requests", jarr(requests)))
    out.push(jobj(row))
  }
  out
}

///|
/// Who shows the rigs told how they are now (`events.tell("rigs")`).
pub async fn Rigs::tell(self : Rigs, ws : String) -> Unit {
  let value = jobj([("workspace", jstr(ws)), ("rigs", jarr(self.listed(ws)))])
  self.d.world.ask("events.tell", [jstr("rigs"), value, jstr("rigs\u0000\{ws}"), jobj([("workspace", jstr(ws))])])
  |> ignore
}

///|
/// How a rig says it is (it told, or was asked): kept; what waited for it brought; this station's grants it no longer
/// lists ended, with why when it said.
pub async fn Rigs::take(self : Rigs, ws : String, rig : String, answer : Json) -> Unit {
  let a = Some(answer)
  let d = described_of(a)
  // (what it says of its load besides is kept by the TypeScript and read by nothing)
  self.heard[rig_key(ws, rig)] = { rig: d, at: (self.d.now)(), reached: true }
  let ended = get(a, "ended")
  if is_objectish(ended) &&
    str_at(ended, "request") is Some(request) &&
    str_at(ended, "station") == Some(self_id(self.d.cloud)) {
    let words = ended_words(js_string_of(get(ended, "why"))).unwrap_or("已结束")
    self.requests.ended_there(request, words)
  }
  if d is Some(_) {
    let mine : Map[String, Json] = Map([])
    for g in arr_at(d, "grants").unwrap_or([]) {
      if str_at(Some(g), "station") == Some(self_id(self.d.cloud)) {
        mine[js_string_of(get(Some(g), "request"))] = g
      }
    }
    for r in self.requests.of_rig(ws, rig) {
      if rs(r, "status") != "granted" {
        continue
      }
      let there = mine.get(rs(r, "id"))
      if (r.get("delivered") is Some(True)) && there is None {
        self.requests.ended_there(rs(r, "id"), "已结束")
      } else if (r.get("delivered") is Some(True)) && there is Some(t) {
        self.requests.held_there(rs(r, "id"), num_at(Some(t), "until").unwrap_or(0.0))
      }
    }
  }
  (self.d.spawn)(async fn() {
    let through = self.flush(ws, rig) catch { _ => false }
    if through {
      for r in self.requests.undelivered(ws, rig) {
        self.requests.deliver(r)
      }
    }
  })
  self.tell(ws)
}

///|
/// A rig asked how it is, once: as this station starts, or first hears the control plane name it (the bus attached, the
/// cloud changed). In security mode one not signed for yet is asked what its person signed first (`rig.proof`), and for
/// nothing else until that holds.
pub fn Rigs::look(self : Rigs) -> Unit {
  if !self.d.cloud.peers_current {
    return
  }
  let now : Array[String] = []
  for m in self.d.cloud.memberships() {
    let ws = js_string_of(get(Some(m), "workspace"))
    for rig in self.d.cloud.rigs_named(ws) {
      let k = rig_key(ws, str_at(Some(rig), "id").unwrap_or(""))
      now.push(k)
      if self.asked.contains(k) {
        continue
      }
      self.asked.push(k)
      (self.d.spawn)(async fn() { self.meet(ws, rig) })
    }
  }
  for k in self.asked.copy() {
    if now.contains(k) {
      continue
    }
    if self.asked.search(k) is Some(i) {
      self.asked.remove(i) |> ignore
    }
    self.heard.remove(k)
  }
}

///|
async fn Rigs::meet(self : Rigs, ws : String, rig : Json) -> Unit {
  let id = str_at(Some(rig), "id").unwrap_or("")
  let at_ws = if self.d.cloud.home() == Some(ws) { None } else { Some(ws) }
  try {
    if self.d.cloud.locked(ws=at_ws) is Some(_) && !self.adds.holds(ws, rig) {
      let got = (self.d.within)(
        ask_ms,
        async fn() {
          self.d.world.ask("remote.ask", [jstr(id), jobj([("method", jstr("rig.proof")), ("workspace", jstr(ws))])]).unwrap_or(
            Json::null(),
          )
        },
        "the rig did not answer",
      )
      let why = match get(Some(got), "add") {
        None | Some(Null) => Some("it has none")
        Some(add) => self.adds.take(ws, rig, Some(add))
      }
      if why is Some(_) {
        // (a rig the control plane names is not taken: its person has not signed for it here)
        return self.tell(ws)
      }
    }
    let answer = (self.d.within)(
      ask_ms,
      async fn() {
        self.d.world.ask("remote.ask", [jstr(id), jobj([("method", jstr("rig.describe")), ("workspace", jstr(ws))])]).unwrap_or(
          Json::null(),
        )
      },
      "the rig did not answer",
    )
    self.take(ws, id, answer)
  } catch {
    _ => {
      let was = self.heard.get(rig_key(ws, id))
      self.heard[rig_key(ws, id)] = { rig: was.bind(w => w.rig), at: was.map(w => w.at).unwrap_or(0.0), reached: false }
      // (a rig was not reached; it tells when it is back)
      self.tell(ws)
    }
  }
}

///|
/// What a rig tells of itself (`rig.hello`, `rig.changed`): taken only from a machine that is a rig of that workspace.
pub async fn Rigs::heard_rig(self : Rigs, peer : String, request : Json, workspace : String?) -> Json {
  let ws = workspace.unwrap_or("")
  if self.d.cloud.rig_of(peer, workspace=Some(ws)) is None {
    raise Thrown("Error", "not a rig of this workspace")
  }
  let k = rig_key(ws, peer)
  if !self.asked.contains(k) {
    self.asked.push(k)
  }
  self.take(ws, peer, request)
  jobj([("ok", jbool(true))])
}

///|
/// The rig an agent or the app names in workspace `ws`: by its id, or its name (as cased anywhere).
pub fn Rigs::named(self : Rigs, ws : String, given : String) -> Json raise Refused {
  let rigs = self.d.cloud.rigs_named(ws)
  let lower = js_lower(given)
  let found = rigs.filter(r => str_at(Some(r), "id") == Some(given))
  let same = if found.length() > 0 {
    found
  } else {
    rigs.filter(r => js_lower(js_string_of(get(Some(r), "name"))) == lower)
  }
  if same.length() > 1 {
    raise Refused("\{same.length()} tasks-only stations are named \{given}: give the id station_list shows for the one meant")
  }
  if same.length() == 0 {
    let those = if rigs.length() > 0 {
      let names = rigs.map(r => {
        let n = js_string_of(get(Some(r), "name"))
        if n != "" && get(Some(r), "name") is Some(String(_)) {
          n
        } else {
          js_string_of(get(Some(r), "id"))
        }
      })
      "; those it has: \{names.join(", ")}"
    } else {
      " (it has none; a whole station needs no grant)"
    }
    raise Refused("no tasks-only station \{given} in this workspace\{those}")
  }
  let one = Some(same[0])
  if self.d.cloud.rig_of(str_at(one, "id").unwrap_or(""), workspace=Some(ws)) is None {
    let whose = match get(one, "owner_email") {
      Some(String(e)) if e != "" => e
      _ => js_string_of(get(one, "owner"))
    }
    raise Refused(
      "the station \{given} is not taken into this workspace yet: its owner \{whose} has to check its security code in still.fail first",
    )
  }
  same[0]
}

///|
async fn Rigs::workspace_of(self : Rigs, session : String) -> String {
  let row = self.d.world.ask("store.getSession", [jstr(session)])
  guard row is Some(Object(_)) else { raise Thrown("Error", "unknown session") }
  match get(row, "ws") {
    Some(String(ws)) => ws
    _ =>
      match self.d.cloud.home() {
        Some(h) => h
        None => raise Refused("this station is in no workspace")
      }
  }
}

///|
/// station_use asked (rigs/tool.ts `ask`): what the agent is told of its request.
pub async fn Rigs::use_ask(self : Rigs, session : String, rig_name : String, reason : String, timeout : Json?) -> String {
  let ws = self.workspace_of(session)
  let rig = self.named(ws, rig_name)
  let id = str_at(Some(rig), "id").unwrap_or("")
  let h = self.heard.get(rig_key(ws, id))
  let open = match h {
    Some(x) => bool_at(x.rig, "open") == Some(true)
    None => false
  }
  if open && self.requests.of(session, id).length() == 0 {
    return "The station \{js_string_of(get(Some(rig), "name"))} takes every chat of this workspace with no grant (免批准 is on): use it as any station, by its name, with station_task, station_file, peer_forward and secret_use's station."
  }
  said(self.requests.ask(session, rig, ws, reason, timeout))
}

///|
/// station_use {done: true} (rigs/tool.ts `done`).
pub async fn Rigs::use_done(self : Rigs, session : String, rig_name : String) -> String {
  let ws = self.workspace_of(session)
  // (the rig's own grants: its devices' are device_use's to hand back)
  let rig = if rig_name == "" { None } else { str_at(Some(self.named(ws, rig_name)), "id") }
  let ended = self.requests.release(session, rig, device=RigItself)
  if ended.length() == 0 {
    "This chat holds no grant of a tasks-only station and asks for none."
  } else {
    let names = ended.map(r => "\{js_string_of(r.get("rigName"))} (\{js_string_of(r.get("id"))})")
    "Handed back: \{names.join(", ")}. What this chat ran there is stopped."
  }
}

///|
fn whose_of(rig : Json?) -> String {
  let name = js_string_of(get(rig, "owner_name"))
  let email = js_string_of(get(rig, "owner_email"))
  let has_name = truthy(get(rig, "owner_name"))
  let has_email = truthy(get(rig, "owner_email"))
  let first = if has_name {
    name
  } else if has_email {
    email
  } else {
    js_string_of(get(rig, "owner"))
  }
  if has_name && has_email {
    "\{first} <\{email}>"
  } else {
    first
  }
}

///|
/// station_list: a rig after the stations, with whose it is, whether this chat may use it and who may
/// (`remote.setRigs`). `answer`: what it answered as it was listed, None where it was not asked.
pub async fn Rigs::station_listed(self : Rigs, workspace : String, session : String, rig : Json, answer : Json?) -> Json {
  let r = Some(rig)
  let id = str_at(r, "id").unwrap_or("")
  let d = match answer {
    None => self.heard.get(rig_key(workspace, id)).bind(h => h.rig)
    Some(a) => described_of(Some(a))
  }
  let whose = whose_of(r)
  let mine = self.requests.of(session, id)
  let pending = mine.search_by(q => rs(q, "status") == "pending").map(i => mine[i])
  let granted = mine.search_by(q => rs(q, "status") == "granted").map(i => mine[i])
  let rig_name = js_string_of(get(r, "name"))
  let named_as = if truthy(get(r, "name")) { rig_name } else { id }
  let email_or = if truthy(get(r, "owner_email")) { js_string_of(get(r, "owner_email")) } else { whose }
  let access = if bool_at(d, "open") == Some(true) {
    "open to every chat of the workspace (免批准): use it as a station, by its name"
  } else if granted is Some(g) && (g.get("delivered") is Some(True)) {
    "granted to this chat (\{lasting(timeout_said(g))})"
  } else if granted is Some(_) {
    "approved for this chat; it has not taken the grant yet (it was away): you are told when it has"
  } else if pending is Some(p) {
    "asked: waits for its owner to approve request \{rs(p, "id")} on the card in your chat"
  } else {
    "no grant: ask with station_use {station: \"\{named_as}\", reason}; its card goes to \{email_or}"
  }
  let out = [("mode", jstr("tasks")), ("owner", jstr(whose)), ("thisChat", jstr(access))]
  match d {
    None => out.push(("hasAccess", jstr("unknown: it was not reached")))
    Some(_) =>
      if bool_at(d, "open") == Some(true) {
        out.push(("hasAccess", jstr("every chat of the workspace")))
      } else {
        let holders = arr_at(d, "grants")
          .unwrap_or([])
          .map(g => {
            let g = Some(g)
            let who = if truthy(get(g, "title")) {
              "\"\{js_string_of(get(g, "title"))}\""
            } else {
              js_string_of(get(g, "chat"))
            }
            let by = if truthy(get(g, "by")) { " (started by \{js_string_of(get(g, "by"))})" } else { "" }
            let t = get(g, "timeout")
            let minutes = num_text(num_at(t, "seconds").unwrap_or(0.0) / 60.0)
            jstr(
              "\{who}\{by} on \{name_of(self.d.cloud, js_string_of(get(g, "station")))}, \{js_string_of(get(t, "kind"))} \{minutes} min, until \{iso(num_at(g, "until").unwrap_or(0.0) * 1000.0)}",
            )
          })
        out.push(("hasAccess", jarr(holders)))
      }
  }
  jobj(out)
}

///|
/// The devices attached to the rigs, as device_list shows them and device_use asks for them (devices/module.ts's
/// `DeviceEntry`s).
pub async fn Rigs::device_entries(self : Rigs, ws : String, session : String) -> Array[Json] {
  let out = []
  for rig in self.d.cloud.rigs_named(ws) {
    let r = Some(rig)
    let id = str_at(r, "id").unwrap_or("")
    if self.d.cloud.rig_of(id, workspace=Some(ws)) is None {
      continue
    }
    let h = self.heard.get(rig_key(ws, id))
    let d = h.bind(x => x.rig)
    let whole_list = self.requests.of(session, id)
    let whole = whole_list.search_by(q => rs(q, "status") == "granted" && (q.get("delivered") is Some(True)))
    let devices = match get(d, "devices") {
      Some(Array(xs)) => xs
      _ => []
    }
    for dev in devices {
      let dv = Some(dev)
      let dev_id = str_at(dv, "id").unwrap_or("")
      let mine = self.requests.of(session, id, device=Some(dev_id))
      let pending = mine.search_by(q => rs(q, "status") == "pending").map(i => mine[i])
      let granted = mine.search_by(q => rs(q, "status") == "granted").map(i => mine[i])
      let open_any = bool_at(d, "open") == Some(true) || bool_at(dv, "open") == Some(true)
      let this_chat = if open_any {
        "open to every chat of the workspace (免批准): device_use gives it at once"
      } else if whole is Some(_) {
        "this chat holds a grant of \{js_string_of(get(r, "name"))}, its station: device_use gives it at once"
      } else if granted is Some(g) && (g.get("delivered") is Some(True)) {
        "granted to this chat (\{lasting(timeout_said(g))}): device_use gives it"
      } else if granted is Some(_) {
        "approved for this chat; its station has not taken the grant yet (it was away): you are told when it has"
      } else if pending is Some(p) {
        "asked: waits for its owner to approve request \{rs(p, "id")} on the card in your chat"
      } else {
        let to = if truthy(get(r, "owner_email")) {
          js_string_of(get(r, "owner_email"))
        } else {
          js_string_of(get(r, "owner"))
        }
        "no grant: ask with device_use {device: \"\{js_string_of(get(dv, "name"))}\", reason}; its card goes to \{to}"
      }
      let holders = []
      for g in arr_at(d, "grants").unwrap_or([]) {
        let g = Some(g)
        let gd = get(g, "device")
        if gd is None || js_string_of(gd) == dev_id {
          let who = if truthy(get(g, "title")) {
            "\"\{js_string_of(get(g, "title"))}\""
          } else {
            js_string_of(get(g, "chat"))
          }
          let by = if truthy(get(g, "by")) { " (started by \{js_string_of(get(g, "by"))})" } else { "" }
          let whole_of = if gd is None { " (a grant of the station)" } else { "" }
          holders.push(jstr("\{who}\{by} on \{name_of(self.d.cloud, js_string_of(get(g, "station")))}\{whole_of}"))
        }
      }
      let e = []
      put(e, "id", get(dv, "id"))
      put(e, "name", get(dv, "name"))
      put(e, "kind", get(dv, "kind"))
      put(e, "target", get(dv, "target"))
      put(e, "baud", get(dv, "baud"))
      e.push(("via", jstr("rig")))
      put(e, "station", get(r, "id"))
      put(e, "stationName", get(r, "name"))
      put(e, "owner", get(r, "owner"))
      put(e, "ownerEmail", get(r, "owner_email"))
      put(e, "ownerName", get(r, "owner_name"))
      e.push(("online", jbool(h.map(x => x.reached).unwrap_or(false))))
      e.push(("thisChat", jstr(this_chat)))
      e.push(("hasAccess", if open_any { jstr("every chat of the workspace") } else { jarr(holders) }))
      out.push(jobj(e))
    }
  }
  out
}

///|
async fn Rigs::may_use(self : Rigs, ws : String, session : String, e : Json) -> Bool {
  let station = js_string_of(get(Some(e), "station"))
  let id = js_string_of(get(Some(e), "id"))
  let d = self.heard.get(rig_key(ws, station)).bind(h => h.rig)
  guard d is Some(_) else { return false }
  let devices = match get(d, "devices") {
    Some(Array(xs)) => xs
    _ => []
  }
  guard devices.search_by(x => get(Some(x), "id") == get(Some(e), "id")) is Some(i) else { return false }
  if bool_at(d, "open") == Some(true) || bool_at(Some(devices[i]), "open") == Some(true) {
    return true
  }
  let all = self.requests.of(session, station) + self.requests.of(session, station, device=Some(id))
  all.search_by(r => rs(r, "status") == "granted" && (r.get("delivered") is Some(True))) is Some(_)
}

///|
/// device_use of a rig's device (devices/module.ts `sources.rigs.use`).
pub async fn Rigs::device_use(self : Rigs, ws : String, session : String, e : Json, reason : String, timeout : Json?) -> String {
  if self.may_use(ws, session, e) {
    if !(self.d.world.ask("sources.hasForward", []) is Some(True)) {
      return "Devices cannot be forwarded on this station yet."
    }
    return js_string_of(self.d.world.ask("sources.forward", [jstr(session), e]))
  }
  let rig = self.named(ws, js_string_of(get(Some(e), "station")))
  let t = if is_objectish(timeout) {
    let out = []
    put(out, "kind", get(timeout, "kind"))
    put(out, "seconds", get(timeout, "seconds"))
    Some(jobj(out))
  } else {
    None
  }
  let device = (js_string_of(get(Some(e), "id")), js_string_of(get(Some(e), "name")))
  said(self.requests.ask(session, rig, ws, reason, t, device=Some(device)))
}

///|
/// device_use {done: true}: the grants of one device of a rig (`e`), or of every one (None), handed back; their
/// devices' names. (a grant of a rig itself is station_use's to hand back)
pub async fn Rigs::device_done(self : Rigs, session : String, e : Json?) -> Array[String] {
  let ended = match e {
    None => self.requests.release(session, None, device=AnyDevice)
    Some(x) =>
      self.requests.release(
        session,
        Some(js_string_of(get(Some(x), "station"))),
        device=OneDevice(js_string_of(get(Some(x), "id"))),
      )
  }
  ended.map(r => match r.get("deviceName") {
    Some(n) if !(n is Null) => js_string_of(Some(n))
    _ =>
      match r.get("device") {
        Some(dv) if !(dv is Null) => js_string_of(Some(dv))
        _ => ""
      }
  })
}

///|
/// A rig its person signed for here is signed for at the workspace's other stations too: each checks it itself.
fn Rigs::vouched_elsewhere(self : Rigs, ws : String, rig : String, signed : Json) -> Unit {
  for p in arr_at(self.d.cloud.membership(ws), "peers").unwrap_or([]) {
    guard str_at(Some(p), "id") is Some(peer) && peer != self_id(self.d.cloud) else { continue }
    (self.d.spawn)(async fn() {
      // Away, or from before rigs: it asks the rig itself as it next starts (`rig.proof`).
      let _ = self.d.world.ask("remote.ask", [
        jstr(peer),
        jobj([("method", jstr("rig.add")), ("workspace", jstr(ws)), ("rig", jstr(rig)), ("signed", signed)]),
      ]) catch {
        _ => None
      }
    })
  }
}

///|
/// A station's word that a rig's person signed for it there (`rig.add`).
pub async fn Rigs::rig_add(self : Rigs, request : Json, workspace : String?) -> Json {
  let ws = workspace.unwrap_or("")
  let q = Some(request)
  let rigs = self.d.cloud.rigs_named(ws)
  guard rigs.search_by(r => get(Some(r), "id") == get(q, "rig")) is Some(i) else {
    raise Thrown("Error", "no such rig in this workspace")
  }
  let rig = rigs[i]
  if self.adds.take(ws, rig, get(q, "signed")) is Some(why) {
    raise Thrown("Error", why)
  }
  self.forget(rig_key(ws, str_at(Some(rig), "id").unwrap_or("")))
  self.look()
  self.tell(ws)
  jobj([("vouched", jbool(true))])
}

///|
fn Rigs::forget(self : Rigs, k : String) -> Unit {
  if self.asked.search(k) is Some(i) {
    self.asked.remove(i) |> ignore
  }
}

// ── what a member's app asks of the rigs (the admin API: a read-only member reads, and changes nothing) ──────────────

///|
/// A route's answer: its status and its body (api/request.ts `json`, `error`).
pub(all) struct Answer {
  status : Int
  body : String
}

///|
fn answered(v : Json) -> Answer {
  { status: 200, body: stringify(v) }
}

///|
fn error_answer(status : Int, message : String) -> Answer {
  { status, body: stringify(jobj([("error", jstr(message))])) }
}

///|
/// A request's body as an object, `{}` where it is none.
fn body_of(text : String) -> Json {
  let t = if text == "" { "{}" } else { text }
  match parse(t) {
    Some(Object(_) as v) => v
    Some(Array(_) as v) => v
    _ => jobj([])
  }
}

///|
/// `Number(s)` of a query's value.
fn js_number(s : String) -> Double {
  @jsjson.js_number(s)
}

///|
fn hex64(s : String) -> Bool {
  is_hex_text(s, 64)
}

///|
/// A request as its person's app is given it back: without the lock that came with what they signed.
fn public_of(r : RigRequest?) -> Json {
  match r {
    None => Json::null()
    Some(q) => {
      let out : Map[String, Json] = Map([])
      for e in js_entries(q) {
        if e.0 != "chain" && e.0 != "signed" {
          out[e.0] = e.1
        }
      }
      if truthy(q.get("signed")) {
        match get(get(q.get("signed"), "body"), "timeout") {
          Some(t) => out["timeout"] = t
          None => out.remove("timeout")
        }
      }
      Json::object(out)
    }
  }
}

///|
/// The route `method` `path` asked, answered; None where none of the rigs' routes is it. `body`: its text, `size`: its
/// bytes.
pub async fn Rigs::route(
  self : Rigs,
  meth : String,
  path : String,
  query : Array[(String, String)],
  body : String,
  size : Int,
  viewer : Viewer,
) -> Answer? {
  let parts = path.split("/").map(p => p.to_string()).collect()
  // ("", "rigs", ...)
  let n = parts.length()
  let ws = viewer.workspace
  let refusing = async fn(run : async () -> Answer) -> Answer {
    run() catch {
      Refused(m) => error_answer(422, m)
      e => raise e
    }
  }
  if meth == "GET" && path == "/rigs" {
    return Some(answered(jobj([("workspace", jstr(ws)), ("rigs", jarr(self.listed(ws)))])))
  }
  if meth == "GET" && n == 4 && parts[1] == "rigs" && hex64(parts[2]) && parts[3] == "log" {
    let id = parts[2]
    return Some(
      refusing(async fn() {
        let rig = self.named(ws, id)
        let given = match query.search_by(q => q.0 == "limit") {
          Some(i) => js_number(query[i].1)
          None => 50.0
        }
        let limit = if safe_int(given) { given } else { 50.0 }
        let got = (self.d.within)(
          ask_ms,
          async fn() {
            self.d.world.ask("remote.ask", [
                get(Some(rig), "id").unwrap_or(Json::null()),
                jobj([("method", jstr("rig.log")), ("workspace", jstr(ws)), ("limit", jnum(limit))]),
              ])
              .unwrap_or(Json::null())
          },
          "the rig did not answer",
        ) catch {
          e => return error_answer(504, error_message(e))
        }
        let commands = arr_at(Some(got), "commands")
          .unwrap_or([])
          .map(c => {
            let station = match get(Some(c), "station") {
              None | Some(Null) => ""
              v => js_string_of(v)
            }
            spread(Some(c), Some(jobj([("stationName", jstr(name_of(self.d.cloud, station)))])))
          })
        answered(jobj([("commands", jarr(commands))]))
      }),
    )
  }
  if meth == "POST" && n == 5 && parts[1] == "rigs" && parts[2] == "requests" && parts[3] != "" && parts[4] == "decide" {
    let id = parts[3]
    return Some(
      refusing(async fn() {
        let op = Some(body_of(body))
        if size > signed_max {
          return error_answer(413, "too large")
        }
        let signed = if get(op, "allow") is Some(True) { get(op, "signed") } else { None }
        match self.requests.decide(viewer.sub, id, ws, signed, get(op, "chain")) {
          None => answered(jobj([("request", public_of(self.requests.get(id)))]))
          Some(why) => error_answer(422, why)
        }
      }),
    )
  }
  if meth == "POST" && n == 5 && parts[1] == "rigs" && parts[2] == "requests" && parts[3] != "" && parts[4] == "revoke" {
    let id = parts[3]
    return Some(
      refusing(async fn() {
        let op = Some(body_of(body))
        if size > signed_max {
          return error_answer(413, "too large")
        }
        if self.requests.get(id) is Some(here) && rs(here, "ws") == ws {
          return match self.requests.revoke(viewer.sub, id, ws, get(op, "signed"), get(op, "chain")) {
            None => answered(jobj([("request", public_of(self.requests.get(id)))]))
            Some(why) => error_answer(422, why)
          }
        }
        let rig_given = match get(op, "rig") {
          None | Some(Null) => ""
          v => js_string_of(v)
        }
        let rig = self.named(ws, rig_given)
        let rig_id = str_at(Some(rig), "id").unwrap_or("")
        if str_at(Some(rig), "owner") != Some(viewer.sub) {
          return error_answer(403, "only the rig's owner takes a grant of it back")
        }
        let sb = get(get(op, "signed"), "body")
        if !well_formed("revoke", get(op, "signed")) ||
          str_at(sb, "rig") != Some(rig_id) ||
          str_at(sb, "ws") != Some(ws) ||
          str_at(sb, "request") != Some(id) {
          return error_answer(422, "not this grant's revoke")
        }
        self.queue(ws, rig_id, "revoke", jobj([("signed", get(op, "signed").unwrap()), ("chain", chain_or_null(op))]))
        answered(jobj([("delivered", jbool(self.flush(ws, rig_id)))]))
      }),
    )
  }
  if meth == "POST" && n == 4 && parts[1] == "rigs" && hex64(parts[2]) && (parts[3] == "settings" || parts[3] == "devices") {
    let id = parts[2]
    let settings = parts[3] == "settings"
    return Some(
      refusing(async fn() {
        let op = Some(body_of(body))
        if size > signed_max {
          return error_answer(413, "too large")
        }
        let rig = self.named(ws, id)
        let rig_id = str_at(Some(rig), "id").unwrap_or("")
        if str_at(Some(rig), "owner") != Some(viewer.sub) {
          return error_answer(
            403,
            if settings {
              "only the rig's owner changes its settings"
            } else {
              "only the station's owner attaches devices to it"
            },
          )
        }
        let kind = if settings { "settings" } else { "device" }
        let sb = get(get(op, "signed"), "body")
        if !well_formed(kind, get(op, "signed")) ||
          str_at(sb, "rig") != Some(rig_id) ||
          str_at(sb, "ws") != Some(ws) ||
          str_at(sb, "sub") != Some(viewer.sub) {
          return error_answer(422, if settings { "not this rig's settings" } else { "not this station's device" })
        }
        self.queue(ws, rig_id, kind, jobj([("signed", get(op, "signed").unwrap()), ("chain", chain_or_null(op))]))
        answered(jobj([("delivered", jbool(self.flush(ws, rig_id)))]))
      }),
    )
  }
  if meth == "POST" && n == 4 && parts[1] == "rigs" && hex64(parts[2]) && parts[3] == "add" {
    let id = parts[2]
    let op = Some(body_of(body))
    let rigs = self.d.cloud.rigs_named(ws)
    guard rigs.search_by(x => str_at(Some(x), "id") == Some(id)) is Some(i) else {
      return Some(error_answer(404, "no such rig in this workspace"))
    }
    let rig = rigs[i]
    if str_at(Some(rig), "owner") != Some(viewer.sub) {
      return Some(error_answer(403, "only the rig's owner takes it into the workspace"))
    }
    if self.adds.take(ws, rig, get(op, "signed")) is Some(why) {
      return Some(error_answer(422, why))
    }
    let signed = get(op, "signed").unwrap_or(Json::null())
    self.queue(ws, id, "added", jobj([("signed", signed)]))
    self.vouched_elsewhere(ws, id, signed)
    self.forget(rig_key(ws, id))
    self.look()
    self.tell(ws)
    return Some(answered(jobj([("vouched", jbool(true))])))
  }
  if meth == "POST" && n == 4 && parts[1] == "rigs" && hex64(parts[2]) && parts[3] == "full" {
    let id = parts[2]
    return Some(
      refusing(async fn() {
        let op = Some(body_of(body))
        if size > signed_max {
          return error_answer(413, "too large")
        }
        let rig = self.named(ws, id)
        let rig_id = str_at(Some(rig), "id").unwrap_or("")
        if str_at(Some(rig), "owner") != Some(viewer.sub) {
          return error_answer(403, "only its owner makes it a whole station")
        }
        if !manages_station(viewer) {
          return error_answer(403, "only the workspace's owners and admins add a whole station")
        }
        let sb = get(get(op, "signed"), "body")
        if !well_formed("full", get(op, "signed")) ||
          str_at(sb, "rig") != Some(rig_id) ||
          str_at(sb, "ws") != Some(ws) ||
          str_at(sb, "sub") != Some(viewer.sub) {
          return error_answer(422, "not signed for this station")
        }
        let request = jobj([
          ("method", jstr("rig.full")),
          ("workspace", jstr(ws)),
          ("signed", get(op, "signed").unwrap()),
          ("chain", chain_or_null(op)),
        ])
        let _ = (self.d.within)(
          ask_ms,
          async fn() { self.d.world.ask("remote.ask", [jstr(rig_id), request]).unwrap_or(Json::null()) },
          "it did not answer",
        ) catch {
          Refused(m) => raise Refused(m)
          e => return error_answer(504, error_message(e))
        }
        answered(jobj([("ok", jbool(true))]))
      }),
    )
  }
  if meth == "POST" && path == "/mode" {
    // This station to run only tasks from now on (`{mode: "tasks", person}`), asked of it by a member's device:
    // `person` their own lock's hash, which it will pin. Whose a station is (who added it) the machine does not know:
    // the control plane does, and lets only that member list it so (cloud/src/directory.ts `setStationMode`). So the
    // ask is kept as theirs until the control plane lists it as that same person's rig (the app asks that next;
    // cloud/presence.ts): neither alone makes it one. A station in one workspace only, as a rig is.
    let op = Some(body_of(body))
    let person = str_at(op, "person")
    if str_at(op, "mode") != Some("tasks") || !(person is Some(p) && hex64(p)) {
      return Some(error_answer(400, "mode tasks, with its person's own lock"))
    }
    if self.d.cloud.home() != Some(viewer.workspace) || self.d.cloud.memberships().length() != 1 {
      return Some(error_answer(409, "a station in several workspaces stays a whole one: take it out of the others first"))
    }
    let at = ((self.d.now)() / 1000.0).floor()
    let pending = [("owner", jstr(viewer.sub))]
    put(pending, "owner_email", viewer.email.map(jstr))
    pending.push(("owner_name", jstr(viewer.name.unwrap_or(""))))
    pending.push(("person", jstr(person.unwrap())))
    pending.push(("at", jnum(at)))
    self.d.cloud.update(st => {
      st.fields["rig_pending"] = jobj(pending)
      st.fields.remove("rig_due")
    })
    return Some(answered(jobj([("ok", jbool(true))])))
  }
  None
}

///|
fn chain_or_null(op : Json?) -> Json {
  match get(op, "chain") {
    None => Json::null()
    Some(c) => c
  }
}
