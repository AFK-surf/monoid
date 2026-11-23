// station/src/devices/: the workspace's devices (设备, 2026-11-10), one list of what agents use that runs no station,
// each its person's, lent to chats one way. Three kinds of where one is: attached to a whole station (the registry,
// kept here when here: open to every chat, as the station is); attached to a station that only runs tasks (its rig
// keeps them: a chat uses one by its owner's grant); a person's phone, lent by its app (`Adb`). An agent finds them
// with device_list and asks with device_use. What it is given is a port of 127.0.0.1 on its own station, which only
// its own processes connect to (door's gate), carried to the device by the station it is attached to.

// ── connect.ts: what a device is reached at from the machine it is attached to ──

///|
/// How long a device's address has to take a connection.
let reach_ms : Double = 10000.0

///|
/// The adb server a machine's own adb starts, where its USB phones are.
pub let adb_port : Int = 5037

///|
/// A serial port's speed when none was given.
pub let baud_default : Int = 115200

///|
/// `host:port` (a bracketed IPv6 address too) split.
pub fn host_port(target : String) -> (String, Double) {
  let at = match target.rev_find(":") {
    Some(i) => i
    None => -1
  }
  let host = js_slice(target, 0, b=at)
  let host = if host.has_prefix("[") &&
    host.has_suffix("]") &&
    host.length() >= 2 {
    js_slice(host, 1, b=host.length() - 1)
  } else {
    host
  }
  (host, js_num(js_slice(target, at + 1)))
}

///|
/// A connection to `host:port`, paused and half-open.
pub async fn reach_tcp(w : World, host : String, port : Double) -> J {
  w.ask("net.connect", [
    jo([
      ("host", js(host)),
      ("port", jn(port)),
      ("allowHalfOpen", jb(true)),
      ("timeout", jn(reach_ms)),
      (
        "why",
        js(
          "\{host}:\{num_text(port)} took no connection within \{num_text(reach_ms / 1000.0)} s",
        ),
      ),
    ]),
  ])
}

///|
/// The serial port at `path` set raw at `baud`, both ways, as one stream (stty: its flag for the device is -F on Linux,
/// -f on a Mac).
async fn reach_serial(w : World, path : String, baud : Double) -> J {
  let os = platform_os()
  if os == "windows" {
    raise fail_("serial ports are not reached on Windows stations yet")
  }
  let flag = if os == "macos" { "-f" } else { "-F" }
  let ran = w.ask("proc.run", [
    jo([
      ("file", js("stty")),
      ("args", jsa([flag, path, "raw", "-echo", num_text(baud)])),
      ("timeout", Null),
    ]),
  ])
  if !(get(ran, "code") is Num(0.0)) {
    let said = js_trim(text_of(at(Some(ran), "err")))
    raise fail_(
      "stty \{path}: \{if said != "" { said } else { "exit \{js_text(get(ran, "code"))}" }}",
    )
  }
  w.ask("serial.open", [js(path)])
}

///|
/// A connection to device `d` from this machine.
pub async fn reach_device(w : World, d : J) -> J {
  match text_of(at(Some(d), "kind")) {
    "tcp" => {
      let (host, port) = host_port(text_of(at(Some(d), "target")))
      reach_tcp(w, host, port)
    }
    "adb" => reach_tcp(w, "127.0.0.1", adb_port.to_double())
    "serial" =>
      reach_serial(
        w,
        text_of(at(Some(d), "target")),
        match at(Some(d), "baud") {
          Some(Num(b)) => b
          _ => baud_default.to_double()
        },
      )
    _ => raise fail_("no such kind of device")
  }
}

// ── rig-form.ts `deviceRefusal`: what a device must be ──

///|
fn text_within(v : J?, max : Int) -> Bool {
  v is Some(Str(u)) && u.length() <= max
}

///|
fn hex_id(s : String) -> Bool {
  s.length() == 16 &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// `/^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+):([1-9][0-9]{0,4})$/`.
fn tcp_target(t : String) -> Bool {
  let port_ok = (p : String) => {
    p.length() >= 1 &&
    p.length() <= 5 &&
    p.iter().all(is_digit) &&
    !p.has_prefix("0")
  }
  if t.has_prefix("[") {
    match t.find("]") {
      Some(e) if e > 1 => {
        let inside = js_slice(t, 1, b=e)
        let rest = js_slice(t, e + 1)
        inside
        .iter()
        .all(c => {
          is_digit(c) ||
          (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F') ||
          c == ':' ||
          c == '.'
        }) &&
        rest.has_prefix(":") &&
        port_ok(js_slice(rest, 1))
      }
      _ => false
    }
  } else {
    match t.find(":") {
      Some(c) if c > 0 =>
        js_slice(t, 0, b=c)
        .iter()
        .all(ch => (word_char(ch) && ch != '_') || ch == '.' || ch == '-') &&
        port_ok(js_slice(t, c + 1))
      _ => false
    }
  }
}

///|
/// Why `d` is no device, or None.
pub fn device_refusal(d : J) -> String? {
  guard d is Obj(_) &&
    text_within(at(Some(d), "id"), 1000000) &&
    hex_id(text_of(at(Some(d), "id"))) else {
    return Some("a device has an id of 16 hex digits")
  }
  if !text_within(at(Some(d), "name"), 80) ||
    js_trim(text_of(at(Some(d), "name"))) == "" {
    return Some("a device has a name, up to 80 characters")
  }
  let kind = at(Some(d), "kind")
  if !(kind is Some(Str(_)) && ["adb", "tcp", "serial"].contains(text_of(kind))) {
    return Some("kind: adb, tcp or serial")
  }
  let kind = text_of(kind)
  let target = text_of(at(Some(d), "target"))
  if !text_within(at(Some(d), "target"), 256) ||
    js_trim(target) == "" ||
    target.iter().any(c => js_space(c) || c == '\u{0}') {
    return Some("target: what it is reached at, with no spaces")
  }
  if kind == "tcp" && !tcp_target(target) {
    return Some("a tcp device's target is host:port")
  }
  if kind == "tcp" {
    let colon = target.rev_find(":").unwrap_or(-1)
    if @session_chats.js_number(js(js_slice(target, colon + 1))).unwrap_or(0.0) >
      65535.0 {
      return Some("a tcp device's port is 1 to 65535")
    }
  }
  if kind == "serial" &&
    !target.has_prefix("/") &&
    !(target.has_prefix("COM") &&
    target.length() > 3 &&
    js_slice(target, 3).iter().all(is_digit)) {
    return Some("a serial device's target is its path (/dev/…) or COMn")
  }
  match at(Some(d), "baud") {
    None => ()
    Some(Num(b)) if is_int(b) &&
      b.abs() <= 9007199254740991.0 &&
      b >= 50.0 &&
      b <= 4000000.0 => ()
    Some(_) => return Some("baud: 50 to 4000000")
  }
  None
}

// ── registry.ts: the devices attached to this station ──

///|
let devices_schema : String =
  #|CREATE TABLE IF NOT EXISTS devices (
  #|  id TEXT PRIMARY KEY,
  #|  ws TEXT NOT NULL,
  #|  body TEXT NOT NULL
  #|);
  #|CREATE INDEX IF NOT EXISTS devices_by_ws ON devices (ws);

///|
/// The most devices one workspace attaches to one station.
pub let devices_max : Int = 200

///|
pub struct DeviceRegistry {
  w : World
  db : @sql.Db
}

///|
pub fn DeviceRegistry::new(w : World, db : @sql.Db) -> DeviceRegistry raise {
  db.exec(devices_schema) catch {
    e => raise sql_err(e)
  }
  { w, db, }
}

///|
fn DeviceRegistry::bodies(
  self : DeviceRegistry,
  sql : String,
  args : Array[Json],
) -> Array[J] raise {
  let rows = self.db.all(sql, args) catch { e => raise sql_err(e) }
  rows.map(row => {
    match row.get("body") {
      Some(String(b)) => @session_chats.parse_js(b)
      _ => J::Null
    }
  })
}

///|
/// The workspace's devices attached here, in the order they were added.
pub fn DeviceRegistry::of(self : DeviceRegistry, ws : String) -> Array[J] raise {
  self.bodies("SELECT body FROM devices WHERE ws = ? ORDER BY rowid LIMIT ?", [
    Json::string(ws),
    Json::number(devices_max.to_double()),
  ])
}

///|
pub fn DeviceRegistry::get(
  self : DeviceRegistry,
  ws : String,
  id : String,
) -> J? raise {
  self
  .bodies("SELECT body FROM devices WHERE id = ? AND ws = ?", [
    Json::string(id),
    Json::string(ws),
  ])
  .get(0)
}

///|
/// A device added by `by` (`{sub, email, name}`): why not (Err), or what was kept.
pub fn DeviceRegistry::add(
  self : DeviceRegistry,
  ws : String,
  by : J,
  given : J,
  at_ : Double,
) -> Result[J, String] raise {
  let id = @drive.hex(@drive.random_bytes(8))
  let fields = [
    ("id", js(id)),
    (
      "name",
      js(
        match at(Some(given), "name") {
          Some(Str(_) as s) => js_trim(js_text(s))
          _ => ""
        },
      ),
    ),
    ("kind", at(Some(given), "kind").unwrap_or(Null)),
    (
      "target",
      js(
        match at(Some(given), "target") {
          Some(Str(_) as s) => js_trim(js_text(s))
          _ => ""
        },
      ),
    ),
  ]
  match at(Some(given), "baud") {
    None | Some(Null) => ()
    Some(Str(u)) if u.length() == 0 => ()
    Some(b) =>
      fields.push(
        (
          "baud",
          jn(
            match b {
              Bool(true) => 1.0
              Bool(false) => 0.0
              Arr([]) => 0.0
              Arr([x]) =>
                @session_chats.js_number(js(js_text(x))).unwrap_or(
                  @double.not_a_number,
                )
              Arr(_) | Obj(_) => @double.not_a_number
              x => @session_chats.js_number(x).unwrap_or(@double.not_a_number)
            },
          ),
        ),
      )
  }
  // (`kind` undefined is left out of the JSON, as JSON leaves it)
  let d = jo(
    fields.filter(f => !(f.0 == "kind" && at(Some(given), "kind") is None)),
  )
  match device_refusal(d) {
    Some(why) => return Err(why)
    None => ()
  }
  let all = self.of(ws)
  if all.length() >= devices_max {
    return Err("a station holds \{devices_max} devices at most")
  }
  let name = text_of(at(Some(d), "name"))
  if all
    .iter()
    .any(x => text_of(at(Some(x), "name")).to_lower() == name.to_lower()) {
    return Err("a device named \{name} is attached here already")
  }
  let kept = spread(
    d,
    jo([
      ("ws", js(ws)),
      ("owner", get(by, "sub")),
      ("owner_email", js(text_of(at(Some(by), "email")).to_lower())),
      ("owner_name", get(by, "name")),
      ("at", jn(at_)),
    ]),
  )
  ignore(
    self.db.run("INSERT INTO devices (id, ws, body) VALUES (?, ?, ?)", [
      Json::string(id),
      Json::string(ws),
      Json::string(stringify(kept)),
    ]),
  ) catch {
    e => raise sql_err(e)
  }
  Ok(kept)
}

///|
pub fn DeviceRegistry::remove(
  self : DeviceRegistry,
  ws : String,
  id : String,
) -> Bool raise {
  let n = self.db.run("DELETE FROM devices WHERE id = ? AND ws = ?", [
    Json::string(id),
    Json::string(ws),
  ]) catch {
    e => raise sql_err(e)
  }
  n > 0
}

// ── tool.ts: device_list and device_use ──

///|
pub let device_list_decl : J = tool_decl(
  "device_list",
  "List the devices of this workspace an agent can use: phones, boards, cameras, routers, printers, serial ports, anything that runs no station but is attached to one (on its USB or its network) or lent by its person's still.fail app (an Android phone with 共享调试 on). Each says its kind (adb, tcp, serial), what it is reached at there, where it is attached, whose it is, whether this chat may use it now (thisChat) and who has access. A device attached to a whole station is open to every chat; one on a station that only runs tasks, and a person's phone, need their owner's approval (device_use).",
  schema_obj([]),
)

///|
pub let device_use_decl : J = tool_decl(
  "device_use",
  "Use a device from device_list. One open to this chat is put at once on a port of 127.0.0.1 here, which only this chat's processes can connect to; one that needs its owner's approval is asked for with a card in your chat, which its owner (not necessarily the person you work for) approves for this chat for a time, or refuses. Asking does not wait: you are told in this session when it is decided, and only a grant counts, not a yes written in the chat. Once granted, call this again: it says where the device is and how it is used. Skill stillfail-jobs (Devices) says more.",
  schema_obj([
    ("device", schema_prop("string", "The device: its name from device_list (any case), or its id; a person's email for their Android phone (lent once they approve). None: the phone of the person you work for.")),
    ("reason", schema_prop("string", "What you will do with it and why (shown on the card to its owner).")),
    (
      "timeout",
      jo([
        ("type", js("object")),
        ("description", js("How long the grant should last (the owner may choose another): idle (ends once this chat has not used the device that long) or fixed, in whole minutes from 1 minute to 30 days. Default: idle, 1 hour.")),
        (
          "properties",
          jo([
            ("kind", jo([("type", js("string")), ("enum", jsa(["idle", "fixed"]))])),
            ("seconds", jo([("type", js("integer"))])),
          ]),
        ),
        ("required", jsa(["kind", "seconds"])),
        ("additionalProperties", jb(false)),
      ]),
    ),
    ("done", schema_prop("boolean", "Hand it back: end this chat's grant of it (or its request still pending), and close its port here. With no device named, every one this chat holds.")),
  ]),
)

///|
/// device_list's answer.
pub fn device_list_said(all : Array[J]) -> String {
  if all.length() == 0 {
    return "No device is attached to this workspace's stations, and no phone is lent to this station. A member adds one on a station's page in the still.fail app (添加设备); a person lends their Android phone by turning on 共享调试 in the app on it."
  }
  pretty(ja(all))
}

///|
/// Where a device is reached here once forwarded (`port` on 127.0.0.1), in words for its kind.
pub fn reached_at(e : J, port : Int) -> String {
  let name = js_text(get(e, "name"))
  let target = js_text(get(e, "target"))
  match text_of(at(Some(e), "kind")) {
    "adb" =>
      "\{name} is reached here through the adb server of the machine it is on: `adb -P \{port} -s \{target} …` (-P on every adb command; never adb kill-server on it). Only this chat's processes connect."
    "serial" => {
      let baud = match at(Some(e), "baud") {
        None | Some(Null) => "115200"
        Some(b) => js_text(b)
      }
      "\{name} (serial \{target}, \{baud} baud, set raw there) is at 127.0.0.1:\{port}: its bytes both ways, e.g. `socat - TCP:127.0.0.1:\{port}` or a socket in a script. Only this chat's processes connect."
    }
    _ =>
      "\{name} (\{target}) is at 127.0.0.1:\{port}: connect to it there as you would to \{target} (http://127.0.0.1:\{port}/, ssh -p \{port} …). Only this chat's processes connect."
  }
}

// ── module.ts: the devices as a part of the station ──

///|
/// Another station asked for its devices answers within this, or is left out of the list.
let ask_ms : Double = 2000.0

///|
pub struct Devices {
  w : World
  registry : DeviceRegistry
  /// The members' phones (adb/), where this station lends them.
  phones : Adb?
  /// Whether the tasks-only stations' devices are asked (`rigs.*`).
  rigs : Bool
}

///|
pub fn Devices::new(
  w : World,
  registry : DeviceRegistry,
  phones? : Adb,
  rigs~ : Bool = false,
) -> Devices {
  { w, registry, phones, rigs, }
}

///|
async fn Devices::self_id(self : Devices) -> String {
  text_of(Some(self.w.ask("cloud.station", [])))
}

///|
async fn Devices::name_of(self : Devices, station : String) -> String {
  text_of(Some(self.w.ask("cloud.nameOf", [js(station)])))
}

///|
async fn Devices::entry_of(self : Devices, k : J, station : String) -> J {
  let fields = [
    ("id", get(k, "id")),
    ("name", get(k, "name")),
    ("kind", get(k, "kind")),
    ("target", get(k, "target")),
  ]
  match at(Some(k), "baud") {
    Some(b) => fields.push(("baud", b))
    None => ()
  }
  fields.append([
    ("via", js("station")),
    ("station", js(station)),
    ("stationName", js(self.name_of(station))),
    ("owner", get(k, "owner")),
    ("ownerEmail", get(k, "owner_email")),
    ("ownerName", get(k, "owner_name")),
    (
      "thisChat",
      js("open to every chat of the workspace: device_use gives it at once"),
    ),
    ("hasAccess", js("every chat of the workspace (it is on a whole station)")),
  ])
  jo(fields)
}

///|
/// What the app is told of this station's devices: as kept, with where.
pub async fn Devices::listed(self : Devices, ws : String) -> Array[J] {
  let me = self.self_id()
  let name = self.name_of(me)
  self.registry
  .of(ws)
  .map(k => spread(k, jo([("station", js(me)), ("stationName", js(name))])))
}

///|
pub async fn Devices::phones(self : Devices, ws : String) -> Array[J] {
  match self.phones {
    Some(a) => a.phones_shown(ws)
    None => []
  }
}

///|
/// What the members' apps are shown changed: told again.
pub async fn Devices::tell(self : Devices, ws : String) -> Unit {
  let devices = self.listed(ws)
  let phones = self.phones(ws)
  ignore(
    self.w.ask("events.tell", [
      js("devices"),
      jo([
        ("workspace", js(ws)),
        ("devices", ja(devices)),
        ("phones", ja(phones)),
      ]),
      js("devices\u{0}\{ws}"),
      jo([("workspace", js(ws))]),
    ]),
  )
}

///|
/// What is shown changed (Null: in every workspace of the station).
pub async fn Devices::changed(self : Devices, ws : J) -> Unit {
  let all = match ws {
    Str(_) => [js_text(ws)]
    _ =>
      list_of(Some(self.w.ask("cloud.memberships", []))).map(m => {
        text_of(at(Some(m), "workspace"))
      })
  }
  for w in all {
    self.tell(w)
  }
}

///|
/// Another station's chat reaching a device here: a whole station's devices are its workspace's every chat's.
/// `probe`: whether it is there (Null), else the connection to it.
pub async fn Devices::side_device(
  self : Devices,
  workspace : String,
  id : String,
  probe : Bool,
) -> J {
  guard self.registry.get(workspace, id) is Some(d) else {
    raise refused("DeviceRefused", "no such device on this station")
  }
  if probe {
    return Null
  }
  reach_device(self.w, d)
}

///|
/// What the other stations ask of what is attached here (device_list there).
pub fn Devices::bus_list(self : Devices, workspace : J) -> J raise {
  jo([("devices", ja(self.registry.of(text_of(Some(workspace)))))])
}

///|
async fn Devices::workspace_of(self : Devices, session : String) -> String {
  let row = self.w.get_session(session)
  if row is Null {
    raise fail_("unknown session")
  }
  match at(Some(row), "ws") {
    Some(Str(_) as ws) => js_text(ws)
    _ =>
      match self.w.ask("cloud.home", []) {
        Str(_) as h => js_text(h)
        _ => raise refused("DeviceAsk", "this station is in no workspace")
      }
  }
}

///|
/// Every device of the workspace this chat's agent can see: this station's, the other whole stations' (asked at once;
/// one that does not answer in time is left out), the tasks-only stations' and the phones.
pub async fn Devices::all(
  self : Devices,
  ws : String,
  session : String,
) -> Array[J] {
  let w = self.w
  let me = self.self_id()
  let own = []
  for k in self.registry.of(ws) {
    own.push(self.entry_of(k, me))
  }
  let peers = list_of(Some(w.ask("cloud.peers", [js(ws)])))
    .filter(p => {
      at(Some(p), "id") is Some(Str(_)) && text_of(at(Some(p), "id")) != me
    })
    .map(p => text_of(at(Some(p), "id")))
  let theirs = @effect.all(
    peers.map(id => {
      async fn() -> Array[J] {
        try {
          let got = w.within(
            ask_ms,
            async fn() {
              w.ask("remote.ask", [
                js(id),
                jo([("method", js("devices.list")), ("workspace", js(ws))]),
              ])
            },
            "no answer",
          )
          let out = []
          for k in list_of(at(Some(got), "devices")) {
            out.push(self.entry_of(k, id))
          }
          out
        } catch {
          _ => []
        }
      }
    }),
  )
  let rigs = if self.rigs {
    list_of(Some(w.ask("rigs.list", [js(ws), js(session)]))) catch {
      _ => []
    }
  } else {
    []
  }
  let phones = match self.phones {
    Some(a) => a.phone_entries(session) catch { _ => [] }
    None => []
  }
  let out = own
  for t in theirs {
    out.append(t)
  }
  out + rigs + phones
}

///|
/// The device an agent names: by its id, or its name (any case).
pub fn named(list : Array[J], given : String) -> J raise {
  let by_id = list.filter(d => text_of(at(Some(d), "id")) == given)
  let lower = given.to_lower()
  let found = if by_id.length() > 0 {
    by_id
  } else {
    list.filter(d => text_of(at(Some(d), "name")).to_lower() == lower)
  }
  if found.length() > 1 {
    raise refused(
      "DeviceAsk",
      "\{found.length()} devices are named \{given}: give the id device_list shows for the one meant",
    )
  }
  if found.length() == 0 {
    let those = if list.length() > 0 {
      "; those it has: \{list.map(d => text_of(at(Some(d), "name"))).join(", ")}"
    } else {
      ""
    }
    raise refused("DeviceAsk", "no device \{given} in this workspace\{those}")
  }
  found[0]
}

///|
/// The device forwarded to a port here for the chat: where it is, in words.
pub async fn Devices::forward(
  self : Devices,
  session : String,
  e : J,
) -> String {
  let w = self.w
  let station = text_of(at(Some(e), "station"))
  let here = station == self.self_id()
  let kept = if here {
    self.registry.get(self.workspace_of(session), text_of(at(Some(e), "id")))
  } else {
    None
  }
  let target = jo([
    ("id", get(e, "id")),
    ("name", get(e, "name")),
    ("here", jb(kept is Some(_))),
    (
      "reach",
      match kept {
        Some(k) => (w.callback)(async fn(_) { reach_device(w, k) })
        None => Null
      },
    ),
    ("session", js(session)),
  ])
  let v = w.ask("forwards.openDevice", [
    js(session),
    js(station),
    target,
    jb(here),
  ])
  let bound = text_of(at(Some(v), "local"))
  let port = match bound.find(":") {
    Some(i) => {
      let rest = js_slice(bound, i + 1)
      let rest = match rest.find(":") {
        Some(j) => js_slice(rest, 0, b=j)
        None => rest
      }
      js_num(rest)
    }
    None => @double.not_a_number
  }
  reached_at(e, port.to_int())
}

///|
/// device_list.
pub async fn Devices::device_list(self : Devices, session : String) -> String {
  device_list_said(self.all(self.workspace_of(session), session))
}

///|
/// device_use: `device`, `reason`, `timeout` as the agent gave them, or `done`.
pub async fn Devices::device_use(
  self : Devices,
  session : String,
  args : J,
) -> String {
  let device = match at(Some(args), "device") {
    Some(Str(_) as d) => js_trim(js_text(d))
    _ => ""
  }
  if at(Some(args), "done") is Some(Bool(true)) {
    return self.done(session, device)
  }
  let reason = str_of(at(Some(args), "reason")).unwrap_or("")
  self.use_(session, device, reason, at(Some(args), "timeout").unwrap_or(Null))
}

///|
async fn Devices::use_(
  self : Devices,
  session : String,
  given : String,
  reason : String,
  timeout : J,
) -> String {
  let w = self.w
  try {
    let ws = self.workspace_of(session)
    let list = self.all(ws, session)
    // A person's phone, by whose (none named: the person the agent works for), lent here now or not yet.
    if given == "" ||
      (
        given.contains("@") &&
        !list
        .iter()
        .any(d => text_of(at(Some(d), "name")).to_lower() == given.to_lower())
      ) {
      let email = (if given == "" {
        w.starter(session).unwrap_or("")
      } else {
        given
      }).to_lower()
      let phone = list.search_by(d => {
        text_of(at(Some(d), "via")) == "phone" &&
        text_of(at(Some(d), "ownerEmail")) == email
      })
      guard self.phones is Some(adb) else {
        return "Phones cannot be asked for on this station."
      }
      let e = match phone {
        Some(i) => list[i]
        None =>
          jo([
            ("id", js("")),
            ("name", js("")),
            ("kind", js("adb")),
            ("target", js("")),
            ("via", js("phone")),
            ("station", js(self.self_id())),
            ("stationName", js("")),
            ("owner", js(email)),
            ("ownerEmail", js(email)),
            ("ownerName", js("")),
            ("thisChat", js("")),
            ("hasAccess", js("")),
          ])
      }
      return adb.phone_device_use(session, e, reason)
    }
    let e = named(list, given)
    let via = text_of(at(Some(e), "via"))
    if via == "station" {
      return self.forward(session, e)
    }
    if via == "rig" {
      if !self.rigs {
        return "Devices of that kind cannot be used from this station."
      }
      return js_text(
        w.ask("rigs.use", [js(ws), js(session), e, js(reason), timeout]),
      )
    }
    guard self.phones is Some(adb) else {
      return "Devices of that kind cannot be used from this station."
    }
    adb.phone_device_use(session, e, reason)
  } catch {
    e =>
      if kind_of(e) == "DeviceAsk" || kind_of(e) == "PeerRefused" {
        message_of(e)
      } else {
        raise e
      }
  }
}

///|
async fn Devices::done(
  self : Devices,
  session : String,
  given : String,
) -> String {
  let w = self.w
  let ws = self.workspace_of(session)
  let mut e : J = Null
  if given != "" {
    e = named(self.all(ws, session), given) catch {
      err =>
        if kind_of(err) == "DeviceAsk" {
          return message_of(err)
        } else {
          raise err
        }
    }
  }
  ignore(
    w.ask("forwards.closeDevice", [
      js(session),
      if e is Null {
        Null
      } else {
        get(e, "id")
      },
      js("handed back"),
    ]),
  )
  let via = text_of(at(Some(e), "via"))
  let names = []
  if e is Null || via == "rig" {
    if self.rigs {
      names.append(
        list_of(Some(w.ask("rigs.done", [js(ws), js(session), e]))).map(x => {
          text_of(Some(x))
        }),
      )
    }
  }
  if e is Null || via == "phone" {
    match self.phones {
      Some(adb) => names.append(adb.phone_done(session, e))
      None => ()
    }
  }
  if !(e is Null) && via == "station" {
    names.push(text_of(at(Some(e), "name")))
  }
  if names.length() == 0 && e is Null {
    "This chat holds no device and asks for none."
  } else {
    "Handed back\{if names.length() > 0 { ": " + names.join(", ") } else { "" }}. Its port here is closed."
  }
}

///|
/// What a member's app asks of the devices attached here (the admin API: a read-only member only reads): `method`,
/// `path` and its body; the answer's status and value.
pub async fn Devices::route(
  self : Devices,
  verb : String,
  path : String,
  viewer : J,
  body : String,
) -> (Int, J)? {
  let w = self.w
  let ws = text_of(at(Some(viewer), "workspace"))
  if verb == "GET" && path == "/devices" {
    let me = self.self_id()
    return Some(
      (
        200,
        jo([
          ("workspace", get(viewer, "workspace")),
          ("station", js(me)),
          ("devices", ja(self.listed(ws))),
          ("phones", ja(self.phones(ws))),
        ]),
      ),
    )
  }
  if verb == "POST" && path == "/devices" {
    // A device attached here by a member: `{name, kind, target, baud?}`, theirs.
    let given = match parse_opt(if body == "" { "{}" } else { body }) {
      Some(Obj(_) as o) => o
      Some(Arr(_) as a) => a
      _ => jo([])
    }
    let now = ((w.now)() / 1000.0).floor()
    match self.registry.add(ws, viewer, given, now) {
      Err(why) => return Some((422, jo([("error", js(why))])))
      Ok(made) => {
        self.tell(ws)
        let me = self.self_id()
        return Some(
          (
            200,
            jo([
              (
                "device",
                spread(
                  made,
                  jo([
                    ("station", js(me)),
                    ("stationName", js(self.name_of(me))),
                  ]),
                ),
              ),
            ]),
          ),
        )
      }
    }
  }
  if verb == "DELETE" &&
    path.has_prefix("/devices/") &&
    hex_id(js_slice(path, 9)) {
    // A device taken off: by its owner, or by a workspace's owner or admin.
    let id = js_slice(path, 9)
    guard self.registry.get(ws, id) is Some(d) else {
      return Some((404, jo([("error", js("no such device on this station"))])))
    }
    let role = text_of(at(Some(viewer), "role"))
    if !jeq(get(d, "owner"), get(viewer, "sub")) &&
      role != "owner" &&
      role != "admin" {
      return Some(
        (
          403,
          jo([
            (
              "error",
              js(
                "only the device's owner, or the workspace's owners and admins, take it off",
              ),
            ),
          ]),
        ),
      )
    }
    ignore(self.registry.remove(ws, id))
    ignore(
      w.ask("forwards.closeDevice", [
        Null,
        js(id),
        js("the device was taken off its station"),
      ]),
    )
    self.tell(ws)
    return Some((200, jo([("ok", jb(true))])))
  }
  None
}
